#!/usr/bin/env bash
# ===========================================================================
#  verify.sh  --  full RTL regression for SPECTRA
# ---------------------------------------------------------------------------
#  Compiles the ACTUAL Verilog to a cycle-accurate C++ model with yosys'
#  CXXRTL backend, then drives each block like real hardware and compares the
#  result, bit-for-bit, against the NumPy-validated golden vectors. No vendor
#  tools required -- just yosys (yowasp), g++ and python3+numpy.
#
#  Verifies:   FFT engine (complex)     bit-exact vs golden
#              fft_mag spectrum         bit-exact vs golden
#              electrical THD/harmonics vs golden (~36% THD)
#              2D FFT image spectrum     bit-exact vs golden
#              block floating point      bins + exponent bit-exact, 39 frames
# ===========================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

YOSYS="${YOSYS:-yowasp-yosys}"
# locate the CXXRTL runtime headers shipped with yowasp-yosys (or system yosys)
RT="$(python3 - <<'PY'
import os,glob,sys
try:
    import yowasp_yosys as y
    base=os.path.join(os.path.dirname(y.__file__),"share","include","backends","cxxrtl","runtime")
    if os.path.isdir(base): print(base); sys.exit()
except Exception: pass
for c in ["/usr/share/yosys/include/backends/cxxrtl/runtime",
          "/usr/local/share/yosys/include/backends/cxxrtl/runtime"]:
    if os.path.isdir(c): print(c); sys.exit()
PY
)"
[ -z "${RT:-}" ] && { echo "ERROR: CXXRTL runtime headers not found"; exit 1; }

CORE="rtl/core/tdp_ram.v rtl/core/rom.v rtl/core/cmul_q15.v rtl/core/mag_alpha_beta.v rtl/core/window_unit.v rtl/core/fft_engine.v rtl/core/fft_mag.v"
APPS="rtl/apps/isqrt.v rtl/apps/divu.v rtl/apps/elec_diag.v rtl/apps/spectrum_elec.v rtl/apps/fft2d.v"
mkdir -p sim/build

echo "==> generating ROMs + golden vectors"
python3 tools/spectra_gen.py 256 | sed 's/^/    /'

cxx () { # $1 top, $2 files, $3 out.cc
  $YOSYS -p "read_verilog -sv -I rtl/core -I rtl/apps $2; hierarchy -check -top $1; proc; write_cxxrtl $3" >/dev/null 2>&1
}
build_run () { # $1 tb.cc  $2 sim.cc  $3 exe
  g++ -std=c++14 -O2 -I"$RT" -I sim/build "$1" -o "$3"
  "$3" sim/vectors
}

fail=0
echo "==> [1/5] FFT engine (complex, bit-exact)"
cxx fft_engine "$CORE" sim/build/fft_engine.cc
build_run sim/tb/tb_engine_cxxrtl.cc sim/build/fft_engine.cc sim/build/eng_sim || fail=1

echo "==> [2/5] fft_mag spectrum (bit-exact)"
cxx fft_mag "$CORE" sim/build/fft_mag.cc
build_run sim/tb/tb_fft_cxxrtl.cc sim/build/fft_mag.cc sim/build/fft_sim || fail=1

echo "==> [3/5] electrical diagnostics (THD / harmonics)"
cxx spectrum_elec "$CORE $APPS" sim/build/spectrum_elec.cc
build_run sim/tb/tb_elec_cxxrtl.cc sim/build/spectrum_elec.cc sim/build/elec_sim || fail=1

echo "==> [4/5] 2D FFT vision (bit-exact image spectrum)"
cxx fft2d "$CORE $APPS" sim/build/fft2d.cc
build_run sim/tb/tb_fft2d_cxxrtl.cc sim/build/fft2d.cc sim/build/fft2d_sim || fail=1

echo "==> [5/5] FFT engine, block floating point (39 frames, bins + exponent bit-exact)"
python3 tools/bfp_study.py > sim/build/bfp_study.log
$YOSYS -p "read_verilog -sv -I rtl/core $CORE; chparam -set BFP 1 fft_engine; hierarchy -check -top fft_engine; proc; write_cxxrtl sim/build/fft_engine_bfp.cc" >/dev/null 2>&1
build_run sim/tb/tb_bfp_cxxrtl.cc sim/build/fft_engine_bfp.cc sim/build/bfp_sim || fail=1

echo
[ "$fail" = 0 ] && echo "ALL RTL TESTS PASSED" || { echo "SOME TESTS FAILED"; exit 1; }
