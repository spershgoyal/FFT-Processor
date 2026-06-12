// ===========================================================================
//  mag_alpha_beta.v  --  complex magnitude WITHOUT a square root
// ---------------------------------------------------------------------------
//  The spectrum we display/analyse is |X[k]| = sqrt(re^2 + im^2). A real sqrt
//  is expensive in hardware. The "alpha-max plus beta-min" estimate gets
//  within ~4% using only compares, shifts and an add:
//
//       |z| ~= max(|re|,|im|) + (3/8) * min(|re|,|im|)
//
//  and 3/8 = 1/4 + 1/8 is just two right-shifts summed. For spectrum bars,
//  peak detection and THD ratios -- all of which care about RELATIVE size --
//  a 4% amplitude error is invisible, and we trade a DSP/sqrt core for a
//  handful of LUTs. (A CORDIC sqrt drop-in is documented in the README for
//  anyone who needs exact magnitudes.)
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module mag_alpha_beta (
    input  wire                       clk,
    input  wire                       en,
    input  wire signed [`SPEC_DW-1:0] re,
    input  wire signed [`SPEC_DW-1:0] im,
    output reg         [`SPEC_DW-1:0] mag,    // unsigned magnitude
    output reg                        vld
);
    // Sign-extend to one extra bit so |-32768| = 32768 is representable, then
    // negate cleanly. Explicit width control avoids the signed/unsigned pitfalls
    // of doing abs() inside a ternary.
    wire signed [`SPEC_DW:0] re_x = re;       // 17-bit sign-extended
    wire signed [`SPEC_DW:0] im_x = im;
    wire [`SPEC_DW:0] are = re_x[`SPEC_DW] ? (-re_x) : re_x;   // |re|
    wire [`SPEC_DW:0] aim = im_x[`SPEC_DW] ? (-im_x) : im_x;   // |im|

    wire [`SPEC_DW:0] mx = (are >= aim) ? are : aim;
    wire [`SPEC_DW:0] mn = (are >= aim) ? aim : are;

    // mx + mn/4 + mn/8, computed wide then saturated to 16-bit unsigned.
    wire [`SPEC_DW+2:0] est = mx + (mn >> 2) + (mn >> 3);
    localparam [`SPEC_DW-1:0] UMAX = {`SPEC_DW{1'b1}};

    always @(posedge clk) begin
        mag <= (est > {{3{1'b0}}, UMAX}) ? UMAX : est[`SPEC_DW-1:0];
        vld <= en;
    end
endmodule
`default_nettype wire
