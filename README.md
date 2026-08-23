# Hardware FFT Processor

A hardware FFT processor for real-time spectrum analysis.

A fixed-point, radix-2 FFT processor written in synthesizable Verilog for the
Xilinx Artix-7, with two application layers built on the **same** engine:

- **Electrical diagnostics** — fundamental / harmonic / THD analysis of a power
  signal, with on-chip square-root and divide, fault flags, and a UART report.
- **Computer vision** — a 2D FFT (row–column decomposition) that turns a camera
  frame into its frequency-domain magnitude image for texture, blur and
  periodic-pattern analysis.

The whole thing is one idea reused three ways: a butterfly engine that lives in
FPGA fabric, fed by a microphone, an ADC, or a camera, and read out to a VGA bar
graph, a VGA image, or a serial dashboard.

Every arithmetic block is verified **bit-for-bit against a NumPy-validated
golden model** by compiling the actual Verilog to a cycle-accurate simulation —
no hand-waving. `make verify` reproduces it from scratch.

---

## Methodology/reasoning

**Why fixed-point (Q1.15)?** An FPGA has no free floating-point unit, and ADC
samples arrive as integers. Every value here is a signed 16-bit number
interpreted as `value / 2^15`, covering `[-1.0, +0.99997)`. The art of the
design is keeping numbers inside that range as they flow through the transform,
which is why the FFT scales by ½ at every stage — guaranteeing no overflow and
producing the true DFT divided by N.

**Why one butterfly, reused?** The spec offered three points on the speed/area
curve: one butterfly (small, slow), N/2 butterflies (huge, fast), or a pipeline
in between. SPECTRA takes the first, cleanest point. A 256-point transform is
8 stages × 128 butterflies = 1,024 butterfly operations; at ~3 cycles each that
is ~3,100 cycles per frame — microseconds at 100 MHz, far faster than any audio
or power-line frame, while costing only **4 DSP48 multipliers and 4 block RAMs**.

**Why a true dual-port RAM?** A radix-2 butterfly touches two memory locations
at once. A true dual-port BRAM reads both operands in one cycle and writes both
results back, so the engine never stalls shuffling one element at a time.

**Why approximate the magnitude?** `|z| = sqrt(re²+im²)` needs a square root.
The *alpha-max-plus-beta-min* estimate `max + 3/8·min` is within ~4% using only
compares and shifts — invisible for spectrum bars and relative measurements, and
it saves a whole arithmetic core. (A CORDIC drop-in is noted below for exact
magnitudes.)

---

## Architecture

```
                       ┌─────────────────────────────────────────────┐
   mic  ─ pdm_mic ─┐   │              fft_engine  (THE BRAIN)         │
   ADC  ─ adc_if  ─┼─► │  ┌────────┐   ┌──────────┐   ┌────────────┐  │
   cam  ─ cam_if  ─┘   │  │ true   │   │  radix-2 │   │  twiddle   │  │
        sample_collector│ │ dual-  │◄─►│ butterfly│◄─►│   ROM      │  │
            (+Hann)     │ │ port   │   │ (cmul_q15)│   │(cos,-sin) │  │
                        │ │ BRAM   │   └──────────┘   └────────────┘  │
                        │  └────────┘   bit-reversed addressing       │
                        └──────────────────────┬──────────────────────┘
                                               │ complex spectrum
                                     ┌─────────▼──────────┐
                                     │  mag_alpha_beta    │  |X[k]|
                                     └─────────┬──────────┘
              ┌──────────────────────┬─────────┴───────────┬──────────────────┐
              ▼                      ▼                     ▼                  ▼
        elec_diag              spectrum RAM            fft2d              UART
   (fundamental, harmonics,    → vga_spectrum     (row→col passes)   (serial report)
    THD, fault flags)          (live bar graph)   → vga_image
                                                  (2D spectrum image)
```

### Module map

| File | Role |
|------|------|
| `rtl/core/fft_engine.v` | radix-2 DIT in-place FFT — load, butterflies, output |
| `rtl/core/cmul_q15.v` | Q1.15 complex multiply (4 mults, 2 adds → DSP48) |
| `rtl/core/tdp_ram.v` | true dual-port RAM (BRAM-inferred working buffer) |
| `rtl/core/rom.v` | `$readmemh` ROM for twiddle / window tables |
| `rtl/core/mag_alpha_beta.v` | sqrt-free magnitude estimate |
| `rtl/core/window_unit.v` | Hann window (anti-leakage) |
| `rtl/core/fft_mag.v` | engine + magnitude, the turn-key spectrum block |
| `rtl/apps/elec_diag.v` | harmonics / THD / peak / fault flags |
| `rtl/apps/isqrt.v`, `divu.v` | sequential sqrt and divide for the THD ratio |
| `rtl/apps/fft2d.v` | 2D FFT via row–column reuse of the engine |
| `rtl/peripherals/*` | PDM mic, ADC, OV7670, UART, VGA (bars + image), collector |
| `rtl/top/spectra_*_top.v` | three SoCs: electrical, audio, vision |
| `tools/spectra_gen.py` | ROM generator **and** bit-accurate golden model |

---

## The math, briefly

**Butterfly (decimation-in-time, in place).** For stage `s` and butterfly `bf`:

```
g  = bf >> (s-1)            p  = (g << s) + j         tw = j << (STAGES - s)
j  = bf & (2^(s-1) - 1)     q  = p + 2^(s-1)
top    = (X[p] + X[q]·W[tw]) / 2
bottom = (X[p] - X[q]·W[tw]) / 2
```

The input is written to **bit-reversed addresses** on load so the recurrence
reads naturally-ordered data and emits a naturally-ordered spectrum — no
separate reorder pass.

**Complex multiply.** `(a+bi)(c+di) = (ac−bd) + (ad+bc)i` — four 16×16 signed
multiplies and two adds, each product shifted right 15 to return to Q1.15.

**THD.** With synchronous sampling (N samples per line cycle) the fundamental
lands on bin 1 and harmonic *h* on bin *h* (the IEC 61000-4-7 convention).
`elec_diag` accumulates `Σ mag[h]²` over the harmonics, takes its square root
(`isqrt`), and divides by the fundamental (`divu`) to report THD in per-mille.

**2D FFT.** Transform every row, then every column of the result — the same 1D
engine, driven 2·M times over an M×M frame buffer. A sinusoidal grating becomes
a single bright dot pair whose position encodes the pattern's frequency.

---

## Verification (reproducible, no vendor tools)

`tools/spectra_gen.py` implements the **exact** fixed-point arithmetic the RTL
performs and checks it against NumPy's floating-point FFT (max bin error
`0.0004`). Then `scripts/verify.sh` compiles the **real Verilog** to C++ with
yosys' CXXRTL backend and drives it like hardware, comparing every output to the
golden vectors:

```
$ make verify
[1/4] FFT engine (complex)      complex mismatches = 0          PASS
[2/4] fft_mag spectrum          bit-exact mismatches = 0,
                                peak bin = 19                    PASS
[3/4] electrical diagnostics    THD 35.9% vs golden 36.0%,
                                peak bin 1, flags set            PASS
[4/4] 2D FFT vision             1024/1024 px bit-exact,
                                peak dot (30,28)                 PASS
ALL RTL TESTS PASSED
```

A plain-Verilog testbench (`sim/tb/tb_fft.v`) is included for Icarus/Verilator
users (`make sim-iverilog`).

## Resource usage (Artix-7, `make synth`)

The shared `fft_mag` core maps to:

| Resource | Count | What |
|----------|-------|------|
| DSP48E1 | **4** | the four real multiplies of the complex multiply |
| Block RAM (RAMB18) | **4** | FFT working buffer (re, im) + twiddle ROMs (cos, sin) |
| LUT / FF | low thousands | control FSM, butterfly add/sub, magnitude |

This matches the project's target envelope (2,000–6,000 LUTs, ~4 DSP on
Artix-7). The full SoCs add a VGA timing generator, UART, mic/ADC/camera front
ends and the diagnostics sqrt/divide.

---

## Build & run

```bash
make verify          # regenerate ROMs/vectors + full bit-exact RTL regression
make synth           # Artix-7 resource report for the core
python3 tools/spectra_gen.py 256    # just regenerate ROMs + golden vectors
```

Requirements for `verify`: `python3` + `numpy`, a C++ compiler, and `yosys`
(the script auto-detects the `yowasp-yosys` pip package or a system install).

**On hardware (Vivado):** create a project for `xc7a100tcsg324-1`, add `rtl/**`
and the `rtl/generated/*.mem` files, set the top to one of `spectra_elec_top` /
`spectra_audio_top` / `spectra_vision_top`, add `constraints/nexys_a7.xdc`
(uncomment the block for your top), and derive a 25.175 MHz pixel clock with a
clocking wizard for the audio/vision tops. The `.mem` paths in the RTL are
repo-relative; in Vivado add them to the project and adjust the `INIT` params or
keep the working directory at the repo root.

---

## Demos

- **Audio** (`spectra_audio_top`): whistle and a green bar slides across the
  screen; a tuning fork plants one sharp bar at its frequency; a clap flashes
  the whole spectrum. Hann windowing keeps close tones distinct.
- **Electrical** (`spectra_elec_top`): feed a mains/motor sense signal; the LEDs
  show "fundamental present" and "high THD", and a 6-byte UART packet
  (`0xA5`, peak bin, fundamental, THD) streams to a laptop each frame.
- **Vision** (`spectra_vision_top`): point an OV7670 at a striped or textured
  surface and its 2D spectrum — bright dots at the pattern's spatial frequency —
  appears on the VGA.

## Extending it

- **Exact magnitude:** swap `mag_alpha_beta` for a CORDIC vector-mode core.
- **512-point / other sizes:** the engine is parameterised on `N`; regenerate
  ROMs with `python3 tools/spectra_gen.py 512` and set `N`.
- **Guitar tuner / DTMF:** `elec_diag`'s peak detector already reports the
  dominant bin; map bins to notes / dial-tone pairs.
- **More parallelism:** replace the single butterfly with a pipelined
  feed-forward (SDF) datapath for one-sample-per-clock throughput.
