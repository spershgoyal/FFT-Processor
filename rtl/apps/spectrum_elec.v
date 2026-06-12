// ===========================================================================
//  spectrum_elec.v  --  electrical-diagnostics application (FFT + analyser)
// ---------------------------------------------------------------------------
//  Turn-key block: stream real ADC samples of a voltage/current signal in,
//  get power-quality diagnostics out. Internally it is just the shared
//  spectrum engine (fft_mag) feeding the elec_diag analyser -- the same brain,
//  tuned for electrical work. Drop a window_unit in front for leakage control.
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module spectrum_elec #(
    parameter integer N        = 256,
    parameter integer FUND_BIN = 1,
    parameter integer NHARM    = 7,
    parameter         TW_RE    = "rtl/generated/twiddle_re_256.mem",
    parameter         TW_IM    = "rtl/generated/twiddle_im_256.mem"
)(
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    in_valid,
    output wire                    in_ready,
    input  wire signed [`SPEC_DW-1:0] in_re,
    input  wire                    start,
    output wire [$clog2(N)-1:0]    peak_bin,
    output wire [`SPEC_DW-1:0]     peak_mag,
    output wire [`SPEC_DW-1:0]     fund_mag,
    output wire [15:0]             thd_pm,
    output wire                    fund_present,
    output wire                    high_thd,
    output wire                    result_valid,
    output wire                    busy
);
    wire                 mvld, mlast;
    wire [$clog2(N)-1:0] midx;
    wire [`SPEC_DW-1:0]  mval;

    fft_mag #(.N(N), .TW_RE(TW_RE), .TW_IM(TW_IM)) u_spec (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_re(in_re), .in_im({`SPEC_DW{1'b0}}), .start(start),
        .mag_valid(mvld), .mag_idx(midx), .mag(mval), .mag_last(mlast),
        .busy(busy), .done());

    elec_diag #(.N(N), .FUND_BIN(FUND_BIN), .NHARM(NHARM)) u_diag (
        .clk(clk), .rst(rst),
        .mag_valid(mvld), .mag_idx(midx), .mag(mval), .mag_last(mlast),
        .peak_bin(peak_bin), .peak_mag(peak_mag), .fund_mag(fund_mag),
        .harm_rms(), .thd_pm(thd_pm),
        .fund_present(fund_present), .high_thd(high_thd),
        .result_valid(result_valid));
endmodule
`default_nettype wire
