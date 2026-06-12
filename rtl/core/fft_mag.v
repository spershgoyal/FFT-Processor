// ===========================================================================
//  fft_mag.v  --  FFT engine + magnitude, the turn-key spectrum block
// ---------------------------------------------------------------------------
//  Wraps fft_engine and runs every complex output bin through the sqrt-free
//  magnitude estimator. Downstream blocks (VGA bars, UART, electrical
//  diagnostics, 2D vision) consume the magnitude stream and never have to
//  think about real/imag parts. The valid/idx/last side-band is delayed one
//  cycle to stay aligned with the magnitude pipeline.
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module fft_mag #(
    parameter integer N     = 256,
    parameter         TW_RE = "rtl/generated/twiddle_re_256.mem",
    parameter         TW_IM = "rtl/generated/twiddle_im_256.mem"
)(
    input  wire                       clk,
    input  wire                       rst,
    input  wire                       in_valid,
    output wire                       in_ready,
    input  wire signed [`SPEC_DW-1:0] in_re,
    input  wire signed [`SPEC_DW-1:0] in_im,
    input  wire                       start,
    output reg                        mag_valid,
    output reg         [$clog2(N)-1:0] mag_idx,
    output reg         [`SPEC_DW-1:0] mag,
    output reg                        mag_last,
    output wire                       busy,
    output wire                       done
);
    wire                       o_valid, o_last;
    wire [$clog2(N)-1:0]       o_idx;
    wire signed [`SPEC_DW-1:0] o_re, o_im;

    fft_engine #(.N(N), .TW_RE(TW_RE), .TW_IM(TW_IM)) u_fft (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_re(in_re), .in_im(in_im), .start(start),
        .out_valid(o_valid), .out_idx(o_idx),
        .out_re(o_re), .out_im(o_im), .out_last(o_last),
        .busy(busy), .done(done));

    // Magnitude: 1 register inside u_mag (mag_int), then 1 more here, so the
    // value lands two cycles after the engine presents a bin.
    wire [`SPEC_DW-1:0] mag_int;
    wire                mvld;
    mag_alpha_beta u_mag (
        .clk(clk), .en(o_valid), .re(o_re), .im(o_im),
        .mag(mag_int), .vld(mvld));

    // Drive the ENTIRE output side-band through the SAME 2-stage delay as the
    // magnitude, so {mag_valid, mag_idx, mag, mag_last} are aligned by
    // construction. Downstream blocks (elec_diag, VGA, UART) can trust them.
    reg                 v1;
    reg [$clog2(N)-1:0] idx1;
    reg                 last1;
    always @(posedge clk) begin
        v1        <= o_valid; idx1    <= o_idx;  last1    <= o_last;   // stage 1
        mag_valid <= v1;      mag_idx <= idx1;   mag_last <= last1;    // stage 2
        mag       <= mag_int;                                          // +1 reg
    end
endmodule
`default_nettype wire
