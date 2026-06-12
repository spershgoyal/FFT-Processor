# ===========================================================================
#  SPECTRA  --  Makefile
# ===========================================================================
#  make gen       regenerate twiddle/window/bit-reversal ROMs + golden vectors
#  make verify    full bit-exact RTL regression (yosys CXXRTL + g++)  [default]
#  make synth     Artix-7 resource report for the shared FFT core (yosys)
#  make sim-iverilog  run the Icarus testbenches (if iverilog is installed)
#  make clean     remove build artifacts
# ===========================================================================
YOSYS ?= yowasp-yosys
PY    ?= python3

CORE = rtl/core/tdp_ram.v rtl/core/rom.v rtl/core/cmul_q15.v \
       rtl/core/mag_alpha_beta.v rtl/core/window_unit.v \
       rtl/core/fft_engine.v rtl/core/fft_mag.v
APPS = rtl/apps/isqrt.v rtl/apps/divu.v rtl/apps/elec_diag.v \
       rtl/apps/spectrum_elec.v rtl/apps/fft2d.v

.PHONY: verify gen synth clean sim-iverilog

verify:
	@bash scripts/verify.sh

gen:
	@$(PY) tools/spectra_gen.py 256

synth:
	@$(YOSYS) -p "read_verilog -sv -I rtl/core $(CORE); \
	  synth_xilinx -family xc7 -top fft_mag -run begin:map_luts; stat"

# Optional: run the same testbenches under Icarus Verilog if available.
sim-iverilog:
	@command -v iverilog >/dev/null || { echo "iverilog not installed"; exit 1; }
	iverilog -g2012 -I rtl/core -o /tmp/tb_fft.vvp $(CORE) sim/tb/tb_fft.v
	vvp /tmp/tb_fft.vvp

clean:
	rm -rf sim/build/*.cc sim/build/*_sim sim/build/obj_dir
