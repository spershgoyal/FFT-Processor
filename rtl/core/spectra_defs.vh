// ===========================================================================
//  spectra_defs.vh  --  shared fixed-point format definitions
// ---------------------------------------------------------------------------
//  The whole processor speaks one numeric language: Q1.15 signed fixed point.
//  A 16-bit signed integer V represents the real number  V / 2^15, covering
//  [-1.0, +0.99997) with ~3e-5 resolution.  Keeping these as `define macros
//  (rather than a SystemVerilog package) keeps every file compatible with
//  plain Verilog-2001 tools -- Icarus, Verilator, Vivado, Quartus, yosys.
// ===========================================================================
`ifndef SPECTRA_DEFS_VH
`define SPECTRA_DEFS_VH

`define SPEC_DW   16          // data word width (bits)
`define SPEC_QF   15          // fractional bits  -> Q1.15
`define SPEC_PW   32          // product width (DW*2)

// Arithmetic-shift-right a signed product back into Q1.15.
// (ac - bd) is Q2.30; >>>15 lands it back in Q1.15. We slice [30:15], which
// for a two's-complement value equals floor(x / 2^15) truncated to 16 bits.
// NOTE: the argument must be a signal name (a part-select cannot be applied to
// a parenthesised expression in Verilog).
`define Q15_NARROW(p) (p[`SPEC_QF+`SPEC_DW-1:`SPEC_QF])

`endif
