// ===========================================================================
//  window_unit.v  --  Hann window applied to the incoming sample stream
// ---------------------------------------------------------------------------
//  A finite FFT implicitly assumes the captured block repeats forever. If a
//  tone doesn't land exactly on a bin, the discontinuity at the block edges
//  smears its energy across neighbours -- "spectral leakage" -- burying small
//  peaks next to large ones. Multiplying the block by a Hann window
//  w[n]=0.5(1-cos(2*pi*n/(N-1))) tapers both ends smoothly to zero and trades a
//  little main-lobe width for ~30 dB lower side-lobes. For a guitar tuner or a
//  harmonic/THD measurement that resolution between close tones is the whole
//  game.
//
//  The block streams samples in order n = 0,1,2,...,N-1 and multiplies each by
//  the matching coefficient from the Hann ROM. A 2-stage pipeline absorbs the
//  ROM's one-cycle read latency; output is one cycle behind input.
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module window_unit #(
    parameter integer N    = 256,
    parameter         INIT = "rtl/generated/hann_256.mem"
)(
    input  wire                       clk,
    input  wire                       rst,
    input  wire                       start,      // reset coefficient index
    input  wire                       s_valid,    // input sample strobe
    input  wire signed [`SPEC_DW-1:0] s_in,
    output reg                        w_valid,
    output reg  signed [`SPEC_DW-1:0] w_out
);
    localparam integer AW = $clog2(N);

    reg  [AW-1:0]            n;                    // coefficient index
    wire signed [`SPEC_DW-1:0] coeff;
    rom #(.DW(`SPEC_DW), .DEPTH(N), .AW(AW), .INIT(INIT)) u_hann (
        .clk(clk), .addr(n), .data(coeff));

    // stage-0 capture (aligned with ROM address issue)
    reg                       v0;
    reg  signed [`SPEC_DW-1:0] samp0;

    // product Q2.30 -> Q1.15
    wire signed [`SPEC_PW-1:0] prod = samp0 * coeff;

    always @(posedge clk) begin
        if (rst) begin
            n <= 0; v0 <= 1'b0; w_valid <= 1'b0;
        end else begin
            if (start) n <= 0;

            // stage 0 : present coefficient address, capture sample
            v0    <= s_valid;
            samp0 <= s_in;
            if (s_valid) n <= (n == N-1) ? {AW{1'b0}} : (n + 1'b1);

            // stage 1 : coeff now valid -> multiply
            w_valid <= v0;
            w_out   <= `Q15_NARROW(prod);
        end
    end
endmodule
`default_nettype wire
