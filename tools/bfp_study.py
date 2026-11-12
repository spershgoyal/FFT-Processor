#!/usr/bin/env python3
"""Block floating point study for the SPECTRA FFT engine.

The original engine divides by 2 after every stage. That can never overflow,
but a quiet input loses one bit of precision per stage whether it needed the
headroom or not. With BFP=1 the engine only scales a stage when the data is
large enough to need it and reports the number of scaled stages (out_exp).

This script
  1. models the BFP engine bit-for-bit (same arithmetic as fxp_fft),
  2. measures signal-to-quantization-noise ratio (SQNR) against a float FFT
     for both schemes over a sweep of input levels and three signal types,
  3. writes sim/vectors/tb_bfp_frames.txt for the RTL regression, and
  4. writes docs/bfp_sqnr.csv and docs/bfp_sqnr.png.
"""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from spectra_gen import gen_twiddles, bitrev, fxp_complex_mul, fxp_fft, wrap, W

N = 256
STAGES = 8

def big(v):
    """True when |v| >= 0.25 in Q1.15, i.e. the top three bits are not all equal."""
    return not (-8192 <= v <= 8191)

def fxp_fft_bfp(re_in, im_in, twr, twi):
    """Bit-exact model of fft_engine with BFP=1. Input in bit-reversed order."""
    re, im = list(re_in), list(im_in)
    exp = 0
    for s in range(1, STAGES + 1):
        scale = any(big(v) for v in re) or any(big(v) for v in im)
        m, half, wstep = 1 << s, 1 << (s - 1), N >> s
        for k in range(0, N, m):
            for j in range(half):
                wr, wi = twr[j * wstep], twi[j * wstep]
                p, q = k + j, k + j + half
                pr, pi = fxp_complex_mul(re[q], im[q], wr, wi)
                ar, ai = re[p], im[p]
                outs = (ar + pr, ai + pi, ar - pr, ai - pi)
                if scale:
                    outs = tuple(o >> 1 for o in outs)
                else:
                    assert all(-32768 <= o <= 32767 for o in outs), "guard-bit rule violated"
                re[p], im[p], re[q], im[q] = (wrap(o, W) for o in outs)
        exp += int(scale)
    return re, im, exp

def to_q15(x):
    return [int(v) for v in np.clip(np.rint(np.asarray(x) * 32768), -32768, 32767)]

def run(xq, twr, twi):
    rl = [0] * N
    for n in range(N):
        rl[bitrev(n, STAGES)] = xq[n]
    il = [0] * N
    fr, fi = fxp_fft(rl, il, twr, twi, True)
    br, bi, e = fxp_fft_bfp(rl, il, twr, twi)
    return (fr, fi), (br, bi, e)

def sqnr_db(ref, est):
    err = np.sum(np.abs(ref - est) ** 2)
    return float("inf") if err == 0 else 10 * np.log10(np.sum(np.abs(ref) ** 2) / err)

def signals(level_db, rng):
    a = 0.9 * 10 ** (level_db / 20)
    n = np.arange(N)
    yield "tone", a * np.sin(2 * np.pi * 19 * n / N + 0.3)
    yield "two-tone", a * (np.sin(2 * np.pi * 19 * n / N) + 0.01 * np.sin(2 * np.pi * 67 * n / N + 1.0)) / 1.01
    yield "noise", np.clip(a / 3 * rng.standard_normal(N), -a, a)

def main():
    twr, twi = gen_twiddles(N)
    rng = np.random.default_rng(5)
    levels = list(range(0, -73, -6))
    rows, frames = [], []
    for lv in levels:
        for name, x in signals(lv, rng):
            xq = to_q15(x)
            X = np.fft.fft(np.array(xq) / 32768.0)
            (fr, fi), (br, bi, e) = run(xq, twr, twi)
            fixed = (np.array(fr, float) + 1j * np.array(fi, float)) / 32768.0 * N
            bfp = (np.array(br, float) + 1j * np.array(bi, float)) / 32768.0 * (1 << e)
            rows.append((lv, name, sqnr_db(X, fixed), sqnr_db(X, bfp), e))
            frames.append((xq, e, br, bi))
    os.makedirs("docs", exist_ok=True)
    with open("docs/bfp_sqnr.csv", "w") as f:
        f.write("input_level_dbfs,signal,sqnr_fixed_db,sqnr_bfp_db,gain_db,stages_scaled\n")
        for lv, name, a, b, e in rows:
            f.write(f"{lv},{name},{a:.1f},{b:.1f},{b - a:.1f},{e}\n")
    with open("sim/vectors/tb_bfp_frames.txt", "w") as f:
        f.write(f"{len(frames)}\n")
        for xq, e, br, bi in frames:
            f.write(" ".join(map(str, xq)) + "\n" + f"{e}\n" + " ".join(map(str, br)) + "\n" + " ".join(map(str, bi)) + "\n")
    print(f"{'level':>6} {'signal':>9} {'fixed':>7} {'BFP':>7} {'gain':>6} {'scaled stages':>14}")
    for lv, name, a, b, e in rows:
        print(f"{lv:>6} {name:>9} {a:7.1f} {b:7.1f} {b - a:6.1f} {e:>14}")
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(figsize=(7.5, 4.2), dpi=150)
        for name, c in (("tone", "#1f4e79"), ("two-tone", "#b4441f"), ("noise", "#4d7a3a")):
            r = [x for x in rows if x[1] == name]
            ax.plot([x[0] for x in r], [x[2] for x in r], "--", color=c, label=f"{name}, divide every stage")
            ax.plot([x[0] for x in r], [x[3] for x in r], "-", color=c, label=f"{name}, block floating point")
        ax.set_xlabel("input level (dBFS)"); ax.set_ylabel("SQNR vs float FFT (dB)")
        ax.set_title("256-point Q1.15 FFT: quantization noise vs input level")
        ax.grid(alpha=0.3); ax.legend(fontsize=7); fig.tight_layout()
        fig.savefig("docs/bfp_sqnr.png")
    except ImportError:
        print("matplotlib not installed, skipping plot")
    print(f"wrote {len(frames)} frames to sim/vectors/tb_bfp_frames.txt")

if __name__ == "__main__":
    main()
