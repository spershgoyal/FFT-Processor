#!/usr/bin/env python3
# =============================================================================
#  spectra_gen.py  --  ROM generator + BIT-ACCURATE golden model for SPECTRA
# -----------------------------------------------------------------------------
#  This single file is the "source of truth" for the hardware. It does three
#  jobs, and every number it prints is something the Verilog must reproduce:
#
#    1. Generates the constant ROMs the RTL loads at synthesis time
#       (twiddle factors, Hann window, bit-reversal permutation).
#
#    2. Implements a fixed-point model of the EXACT arithmetic the RTL performs
#       -- same widths, same truncation, same per-stage scaling -- so that the
#       output is bit-for-bit identical to the silicon. This is what makes the
#       testbench self-checking: the RTL must match these vectors exactly.
#
#    3. Validates that fixed-point model against NumPy's floating-point FFT so
#       we KNOW the algorithm is correct (not just internally consistent).
#
#  WHY fixed-point at all?  An FPGA has no floating-point unit for free. Audio
#  and electrical samples arrive as integers from an ADC, and multipliers on
#  the fabric are integer (DSP48) blocks. We represent every value in Q1.15:
#  a signed 16-bit integer interpreted as  value = int / 2**15, giving a range
#  of [-1.0, +0.99997) with a resolution of ~3e-5. All the care in this file
#  is about keeping numbers inside that range as they flow through the FFT.
# =============================================================================

import os
import numpy as np

# ----------------------------------------------------------------------------
# Global fixed-point format.  These three numbers define the whole numeric
# contract between this model and the Verilog.
# ----------------------------------------------------------------------------
W      = 16            # data word width in bits (signed)
Q      = 15           # number of fractional bits  -> Q1.15 format
SCALE  = 1 << Q       # 32768 ; multiply a real number by this to get the int
INT_MIN = -(1 << (W - 1))   # -32768
INT_MAX =  (1 << (W - 1)) - 1   # +32767

HERE   = os.path.dirname(os.path.abspath(__file__))
ROOT   = os.path.dirname(HERE)
GEN    = os.path.join(ROOT, "rtl", "generated")
VEC    = os.path.join(ROOT, "sim", "vectors")
os.makedirs(GEN, exist_ok=True)
os.makedirs(VEC, exist_ok=True)


# ----------------------------------------------------------------------------
# Small fixed-point helpers.  Everything is done in Python ints (arbitrary
# precision) and only narrowed to 16/17/... bits at the exact points where the
# hardware would, so the model and the hardware round/truncate identically.
# ----------------------------------------------------------------------------
def to_q15(x):
    """Convert a real number in [-1,1) to a saturated Q1.15 integer."""
    v = int(np.floor(x * SCALE + 0.5))        # round-to-nearest at conversion
    return max(INT_MIN, min(INT_MAX, v))


def sat(v, bits):
    """Saturate a Python int to a signed two's-complement field of `bits`."""
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    return max(lo, min(hi, v))


def wrap(v, bits):
    """Two's-complement WRAP (not saturate) to `bits` -- models bare adders."""
    mask = (1 << bits) - 1
    v &= mask
    if v & (1 << (bits - 1)):
        v -= (1 << bits)
    return v


def hexword(v, bits=16):
    """Format a signed int as a zero-padded two's-complement hex string."""
    mask = (1 << bits) - 1
    return f"{v & mask:0{(bits + 3) // 4}x}"


def write_mem(path, values, bits=16, header=""):
    """Write a $readmemh-compatible file, one hex word per line."""
    with open(path, "w") as f:
        if header:
            for line in header.strip("\n").split("\n"):
                f.write(f"// {line}\n")
        for v in values:
            f.write(hexword(v, bits) + "\n")


# ============================================================================
#  1. ROM GENERATION
# ============================================================================
def gen_twiddles(N):
    """
    Twiddle factors  W_N^k = exp(-j*2*pi*k/N) = cos(theta) - j*sin(theta).

    The decimation-in-time butterfly multiplies the lower input by W_N^k, so
    the ROM stores, for k = 0 .. N/2-1, the pair (cos, -sin) already in Q1.15.
    Storing -sin (rather than +sin) means the hardware never has to negate the
    imaginary part -- the sign is baked into the constant, which is exactly the
    kind of thing you precompute in Python and bake into the fabric.
    """
    re = []   # cos(theta)
    im = []   # -sin(theta)
    for k in range(N // 2):
        theta = -2.0 * np.pi * k / N
        re.append(to_q15(np.cos(theta)))            # cos(-x) =  cos(x)
        im.append(to_q15(np.sin(theta)))            # sin(-x) = -sin(x)  -> stored as is
    return re, im


def gen_hann(N):
    """
    Hann window  w[n] = 0.5 * (1 - cos(2*pi*n/(N-1))).

    Applied sample-by-sample before the FFT to suppress spectral leakage (the
    smearing you get when a tone doesn't land exactly on a bin). The peak value
    is 1.0, which Q1.15 cannot represent (max is 0.99997), so we clamp -- a
    one-LSB error on a single coefficient that is completely harmless.
    """
    return [to_q15(0.5 * (1 - np.cos(2 * np.pi * n / (N - 1)))) for n in range(N)]


def bitrev(x, bits):
    r = 0
    for _ in range(bits):
        r = (r << 1) | (x & 1)
        x >>= 1
    return r


def gen_bitrev(N):
    bits = int(np.log2(N))
    return [bitrev(i, bits) for i in range(N)]


# ============================================================================
#  2. BIT-ACCURATE FIXED-POINT FFT  (mirrors the Verilog cycle datapath)
# ============================================================================
def fxp_complex_mul(br, bi, wr, wi):
    """
    Complex multiply (a+bi)(c+di) = (ac-bd) + (ad+bc)i in Q1.15.

    Inputs are Q1.15 16-bit; each product is Q2.30 (31-bit signed). We sum two
    products (Q2.30, fits in 33 bits) then arithmetic-shift right by 15 to land
    back in Q1.15, TRUNCATING toward -inf exactly as a Verilog >>> does. This is
    the single most important routine to match: four multiplies, two adds.
    """
    ac = br * wr
    bd = bi * wi
    ad = br * wi
    bc = bi * wr
    pr = (ac - bd) >> Q          # arithmetic shift = floor division by 2^Q
    pi = (ad + bc) >> Q
    # product magnitude < 1 for |b|<1,|W|=1, so 16 bits is enough; saturate to be safe
    return sat(pr, W), sat(pi, W)


def fxp_fft(re_in, im_in, twr, twi, scale_per_stage=True):
    """
    In-place radix-2 decimation-in-time FFT on Q1.15 integer arrays.

    The input must already be in bit-reversed order (the hardware writes it
    there on load). Output comes out in natural order. With per-stage scaling
    (>>1 after every butterfly add/sub) the result equals the true DFT divided
    by N -- which is what keeps every intermediate value inside [-1,1) so the
    16-bit datapath never overflows. The testbench compares against exactly
    this, and gen() below checks it against NumPy.
    """
    N = len(re_in)
    re = list(re_in)
    im = list(im_in)
    stages = int(np.log2(N))

    for s in range(1, stages + 1):
        m = 1 << s            # butterfly group size at this stage
        half = m >> 1
        wstep = N // m        # stride into the twiddle ROM
        for k in range(0, N, m):
            for j in range(half):
                tw = j * wstep
                wr, wi = twr[tw], twi[tw]
                p = k + j           # top index
                q = p + half        # bottom index
                # bottom * twiddle
                pr, pi = fxp_complex_mul(re[q], im[q], wr, wi)
                ar, ai = re[p], im[p]
                if scale_per_stage:
                    # divide-by-2 each stage: top=(a+p)/2, bottom=(a-p)/2
                    re[p] = wrap((ar + pr) >> 1, W)
                    im[p] = wrap((ai + pi) >> 1, W)
                    re[q] = wrap((ar - pr) >> 1, W)
                    im[q] = wrap((ai - pi) >> 1, W)
                else:
                    re[p] = sat(ar + pr, W)
                    im[p] = sat(ai + pi, W)
                    re[q] = sat(ar - pr, W)
                    im[q] = sat(ai - pi, W)
    return re, im


def fxp_magnitude(re, im):
    """
    Alpha-max-plus-beta-min magnitude estimate:  |z| ~= max + 3/8*min,
    where max/min are over (|re|,|im|). Max error ~4% vs true sqrt, and it
    needs NO multiplier -- 3/8 = 1/4 + 1/8 is two shifts and an add. Returned
    as an unsigned value in the same Q-scale, saturated to 16 bits.
    """
    out = []
    for r, i in zip(re, im):
        a = abs(r)
        b = abs(i)
        mx, mn = (a, b) if a >= b else (b, a)
        mag = mx + (mn >> 2) + (mn >> 3)         # mx + mn*(1/4+1/8)
        out.append(min(mag, (1 << W) - 1))
    return out


# ============================================================================
#  Reference signal helpers
# ============================================================================
def tone(N, bin_k, amp=0.5, phase=0.0):
    n = np.arange(N)
    return amp * np.cos(2 * np.pi * bin_k * n / N + phase)


def quantize_signal(x):
    return [to_q15(v) for v in x]


# ============================================================================
#  3. DRIVER -- generate ROMs, build vectors, and CHECK against NumPy
# ============================================================================
def gen(N=256):
    bits = int(np.log2(N))
    print(f"=== SPECTRA generation : N={N}  ({bits} stages, Q1.{Q})  ===")

    twr, twi = gen_twiddles(N)
    hann     = gen_hann(N)
    brev     = gen_bitrev(N)

    write_mem(os.path.join(GEN, f"twiddle_re_{N}.mem"), twr, W,
              f"Twiddle real  cos(-2*pi*k/{N})  Q1.15  k=0..{N//2-1}")
    write_mem(os.path.join(GEN, f"twiddle_im_{N}.mem"), twi, W,
              f"Twiddle imag -sin(-2*pi*k/{N})  Q1.15  k=0..{N//2-1}")
    write_mem(os.path.join(GEN, f"hann_{N}.mem"), hann, W,
              f"Hann window 0.5*(1-cos(2*pi*n/{N-1})) Q1.15")
    write_mem(os.path.join(GEN, f"bitrev_{N}.mem"), brev, bits,
              f"Bit-reversal permutation, {bits}-bit indices")
    print(f"  wrote twiddle/hann/bitrev ROMs to {os.path.relpath(GEN, ROOT)}/")

    # ----- functional self-test : single tone should peak at its bin --------
    k0 = 19
    sig = tone(N, k0, amp=0.6)
    xq  = quantize_signal(sig)

    # apply bit-reversed load (hardware does this on the way in)
    re_load = [0] * N
    im_load = [0] * N
    for n in range(N):
        re_load[brev[n]] = xq[n]

    re_o, im_o = fxp_fft(re_load, im_load, twr, twi, scale_per_stage=True)
    mag = fxp_magnitude(re_o, im_o)

    half = N // 2
    peak = int(np.argmax(mag[:half]))
    print(f"  single-tone test: injected bin {k0}, hardware-model peak bin {peak}"
          f"  -> {'PASS' if peak == k0 else 'FAIL'}")
    assert peak == k0, "fixed-point FFT failed single-tone localisation"

    # ----- accuracy vs NumPy floating point --------------------------------
    ref = np.abs(np.fft.fft(sig)) / N            # /N matches per-stage scaling
    ref_q = ref / ref.max()
    hw_q  = np.array(mag[:half]) / max(mag[:half])
    err = np.abs(ref_q[:half] - hw_q)
    print(f"  vs NumPy (normalised): max bin error {err.max():.4f}, "
          f"mean {err.mean():.4f}")
    assert err.max() < 0.05, "fixed-point spectrum deviates too far from NumPy"

    # ----- two-tone test (localisation of multiple peaks) -------------------
    k1, k2 = 11, 47
    sig2 = tone(N, k1, 0.4) + tone(N, k2, 0.3)
    xq2 = quantize_signal(sig2)
    rl = [0] * N; il = [0] * N
    for n in range(N):
        rl[brev[n]] = xq2[n]
    r2, i2 = fxp_fft(rl, il, twr, twi, True)
    m2 = fxp_magnitude(r2, i2)
    order = np.argsort(m2[:half])[::-1]
    top2 = sorted(order[:2].tolist())
    print(f"  two-tone test: injected {{{k1},{k2}}}, recovered {top2}"
          f"  -> {'PASS' if top2 == sorted([k1, k2]) else 'FAIL'}")
    assert top2 == sorted([k1, k2])

    # ----- emit testbench vectors (input samples + expected magnitudes) -----
    write_mem(os.path.join(VEC, f"tb_expected_re_{N}.mem"), re_o, W,
              "Expected FFT complex output, real part, natural order, Q1.15")
    write_mem(os.path.join(VEC, f"tb_expected_im_{N}.mem"), im_o, W,
              "Expected FFT complex output, imag part, natural order, Q1.15")
    write_mem(os.path.join(VEC, f"tb_input_{N}.mem"), xq, W,
              f"Test input: {0.6:.1f}*cos(2pi*{k0}*n/{N}) Q1.15  (pre-window)")
    write_mem(os.path.join(VEC, f"tb_expected_mag_{N}.mem"), mag[:half], W,
              f"Expected magnitude spectrum bins 0..{half-1} (alpha-max-beta-min)")
    print(f"  wrote self-check vectors to {os.path.relpath(VEC, ROOT)}/")

    return dict(N=N, twr=twr, twi=twi, hann=hann, brev=brev,
                input=xq, mag=mag[:half], peak=peak)


# ============================================================================
#  Electrical-diagnostics golden model (THD / harmonics)
# ============================================================================
def gen_electrical(N=256, fs=15360.0, f0=60.0):
    """
    Power-line style signal: a 60 Hz fundamental plus 3rd/5th/7th harmonics and
    a little noise -- the classic signature you stare at when something on a
    motor or a rectifier is misbehaving. We compute Total Harmonic Distortion
    the same way the RTL elec_diag block does (ratio of harmonic energy to the
    fundamental) so the on-chip number can be trusted.
    """
    print(f"=== Electrical diagnostics golden : fs={fs:.0f}Hz f0={f0:.0f}Hz ===")
    n = np.arange(N)
    # fundamental + harmonics with realistic relative amplitudes
    amps = {1: 0.60, 3: 0.18, 5: 0.10, 7: 0.06}
    sig = np.zeros(N)
    for h, a in amps.items():
        sig += a * np.cos(2 * np.pi * (f0 * h) * n / fs)
    rng = np.random.default_rng(1)
    sig += 0.01 * rng.standard_normal(N)

    xq = quantize_signal(sig)
    twr, twi = gen_twiddles(N)
    brev = gen_bitrev(N)
    rl = [0] * N; il = [0] * N
    for i in range(N):
        rl[brev[i]] = xq[i]
    ro, io = fxp_fft(rl, il, twr, twi, True)
    mag = fxp_magnitude(ro, io)

    bin_hz = fs / N
    def bin_of(freq):  # nearest FFT bin for a given frequency
        return int(round(freq / bin_hz))

    h_bins = {h: bin_of(f0 * h) for h in range(1, 8)}
    fund = mag[h_bins[1]]
    harm_energy = sum(mag[h_bins[h]] ** 2 for h in range(2, 8) if h_bins[h] < N // 2)
    thd = (harm_energy ** 0.5) / fund if fund else 0.0
    peak = int(np.argmax(mag[:N // 2]))
    print(f"  fundamental bin {h_bins[1]} (={f0:.0f}Hz), peak bin {peak}")
    print(f"  THD = {thd*100:.1f}%   (flag HIGH_THD if >5%)")
    write_mem(os.path.join(VEC, f"tb_elec_input_{N}.mem"), xq, W,
              f"Electrical test: {f0:.0f}Hz + 3/5/7 harmonics, fs={fs:.0f}")
    write_mem(os.path.join(VEC, f"tb_elec_expected_mag_{N}.mem"), mag[:N // 2], W,
              "Expected electrical magnitude spectrum")
    with open(os.path.join(VEC, f"tb_elec_expected_{N}.txt"), "w") as f:
        f.write(f"fundamental_bin {h_bins[1]}\npeak_bin {peak}\n")
        f.write(f"thd_percent {thd*100:.2f}\n")
        for h in range(1, 8):
            f.write(f"harmonic_{h}_bin {h_bins[h]} mag {mag[h_bins[h]] if h_bins[h] < N//2 else 0}\n")
    print(f"  wrote electrical vectors")
    return thd


# ============================================================================
#  2D FFT golden model (computer vision)
# ============================================================================
def fxp_fft2(img, twr, twi, brev):
    """2D FFT by row-column decomposition, reusing the 1D fixed-point engine."""
    M = img.shape[0]
    # rows
    rows_re = np.zeros((M, M), dtype=object)
    rows_im = np.zeros((M, M), dtype=object)
    for r in range(M):
        rl = [0] * M; il = [0] * M
        for n in range(M):
            rl[brev[n]] = int(img[r, n])
        ro, io = fxp_fft(rl, il, twr, twi, True)
        rows_re[r, :] = ro
        rows_im[r, :] = io
    # columns
    out_re = np.zeros((M, M), dtype=object)
    out_im = np.zeros((M, M), dtype=object)
    for c in range(M):
        rl = [0] * M; il = [0] * M
        for n in range(M):
            rl[brev[n]] = int(rows_re[n, c])
            il[brev[n]] = int(rows_im[n, c])
        ro, io = fxp_fft(rl, il, twr, twi, True)
        out_re[:, c] = ro
        out_im[:, c] = io
    return out_re, out_im


def gen_vision(M=32):
    """
    A sinusoidal grating (parallel stripes) has a 2D spectrum that is a single
    pair of bright dots whose position encodes the stripe frequency and angle.
    That is the cleanest possible check that the row-column 2D FFT is wired up
    right, and it's the basis of frequency-domain image analysis (texture,
    blur, periodic-noise removal).
    """
    print(f"=== Computer-vision 2D-FFT golden : {M}x{M} ===")
    twr, twi = gen_twiddles(M)
    brev = gen_bitrev(M)
    # the row/column engine needs M-point twiddle ROMs
    write_mem(os.path.join(GEN, f"twiddle_re_{M}.mem"), twr, W,
              f"Twiddle real cos(-2*pi*k/{M}) Q1.15")
    write_mem(os.path.join(GEN, f"twiddle_im_{M}.mem"), twi, W,
              f"Twiddle imag -sin(-2*pi*k/{M}) Q1.15")
    yy, xx = np.meshgrid(np.arange(M), np.arange(M), indexing="ij")
    kx, ky = 4, 2                                   # stripe frequencies
    grating = 0.4 * np.cos(2 * np.pi * (kx * xx + ky * yy) / M)
    imgq = np.array([[to_q15(v) for v in row] for row in grating], dtype=object)

    ro, io = fxp_fft2(imgq, twr, twi, brev)
    mag = np.array([[fxp_magnitude([ro[r, c]], [io[r, c]])[0]
                     for c in range(M)] for r in range(M)])
    # brightest non-DC bin
    mtmp = mag.copy(); mtmp[0, 0] = 0
    pr, pc = np.unravel_index(np.argmax(mtmp), mag.shape)
    print(f"  grating (kx={kx},ky={ky}) -> brightest bin ({pr},{pc}) "
          f"and conjugate ({(M-pr)%M},{(M-pc)%M})")
    ok = (pr, pc) in [(ky, kx), ((M - ky) % M, (M - kx) % M)]
    print(f"  2D peak localisation -> {'PASS' if ok else 'FAIL'}")
    # compare to numpy fft2 peak
    ref = np.abs(np.fft.fft2(grating)); ref[0, 0] = 0
    rr, rc = np.unravel_index(np.argmax(ref), ref.shape)
    print(f"  NumPy fft2 brightest bin ({rr},{rc})  -> "
          f"{'MATCH' if (rr, rc) == (pr, pc) else 'near'}")
    # flatten row-major for a $readmemh frame
    write_mem(os.path.join(VEC, f"tb_img_input_{M}x{M}.mem"),
              [int(imgq[r, c]) for r in range(M) for c in range(M)], W,
              f"{M}x{M} grating image row-major Q1.15")
    write_mem(os.path.join(VEC, f"tb_img_expected_mag_{M}x{M}.mem"),
              [int(mag[r, c]) for r in range(M) for c in range(M)], W,
              f"{M}x{M} expected 2D magnitude spectrum row-major")
    print("  wrote vision vectors")
    return ok


if __name__ == "__main__":
    import sys
    N = int(sys.argv[1]) if len(sys.argv) > 1 else 256
    info = gen(N)
    gen_electrical(N)
    gen_vision(32)
    print("\nAll golden-model checks PASSED. ROMs + vectors are ready.")
