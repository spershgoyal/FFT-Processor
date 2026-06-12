// ===========================================================================
//  cmul_q15.v  --  Q1.15 complex multiplier  (the butterfly's heavy lifter)
// ---------------------------------------------------------------------------
//  Computes  (ar + j*ai) * (wr + j*wi)  in signed Q1.15:
//
//       real = ar*wr - ai*wi
//       imag = ar*wi + ai*wr
//
//  That is FOUR 16x16 signed multiplies and TWO 32-bit adds -- the canonical
//  cost of a complex multiply, and the reason this project leans on the FPGA's
//  hardware DSP48 blocks instead of LUT-built multipliers. Each 16x16 product
//  is Q2.30; we arithmetic-shift-right by 15 (`Q15_NARROW) to return to Q1.15.
//
//  One pipeline register stage (`p_*`) is inserted so the multipliers can be
//  retimed into the DSP48's internal registers and the path closes timing at a
//  comfortable clock. `vld` simply tracks that latency so the controller knows
//  when the result is ready.
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module cmul_q15 (
    input  wire                      clk,
    input  wire                      en,        // assert to start a multiply
    input  wire signed [`SPEC_DW-1:0] ar,
    input  wire signed [`SPEC_DW-1:0] ai,
    input  wire signed [`SPEC_DW-1:0] wr,
    input  wire signed [`SPEC_DW-1:0] wi,
    output reg  signed [`SPEC_DW-1:0] pr,        // result real  (Q1.15)
    output reg  signed [`SPEC_DW-1:0] pi,        // result imag  (Q1.15)
    output reg                       vld         // 1 one cycle after `en`
);
    // Full-width signed products (Q2.30).
    wire signed [`SPEC_PW-1:0] m_arwr = ar * wr;
    wire signed [`SPEC_PW-1:0] m_aiwi = ai * wi;
    wire signed [`SPEC_PW-1:0] m_arwi = ar * wi;
    wire signed [`SPEC_PW-1:0] m_aiwr = ai * wr;

    // Sum/difference still in Q2.30, one extra guard bit.
    wire signed [`SPEC_PW:0] sum_re = m_arwr - m_aiwi;
    wire signed [`SPEC_PW:0] sum_im = m_arwi + m_aiwr;

    always @(posedge clk) begin
        pr  <= `Q15_NARROW(sum_re);    // >>>15 back to Q1.15
        pi  <= `Q15_NARROW(sum_im);
        vld <= en;
    end
endmodule
`default_nettype wire
