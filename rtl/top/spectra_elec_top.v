// ===========================================================================
//  spectra_elec_top.v  --  ELECTRICAL DIAGNOSTICS SoC (top level)
// ===========================================================================
//  The complete electrical-fault instrument on one FPGA:
//
//     ADC ─▶ adc_if ─▶ sample_collector(+Hann) ─▶ fft_mag ─▶ elec_diag ─▶ UART
//                                                                      └▶ LEDs
//
//  Sample a voltage/current sensor synchronously to the mains (N samples per
//  line cycle). Every FFT frame, elec_diag reports the fundamental, the
//  harmonic content, the THD, and fault flags. Results stream out the UART as a
//  6-byte packet for a laptop dashboard, and the headline flags drive the
//  board LEDs (green = healthy fundamental, red = high THD).
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module spectra_elec_top #(
    parameter integer N        = 256,
    parameter integer ADC_BITS = 12,
    parameter integer CLK_HZ   = 100_000_000,
    parameter integer BAUD     = 115200
)(
    input  wire                    clk,
    input  wire                    rst,
    // ADC interface
    input  wire                    adc_valid,
    input  wire signed [ADC_BITS-1:0] adc_code,
    // outputs
    output wire                    uart_tx,
    output wire [15:0]             led        // [0] fund_present, [1] high_thd, [15:8]=THD%
);
    // ---- front end : ADC -> Q1.15 ----
    wire                       smp_v;
    wire signed [`SPEC_DW-1:0] smp;
    adc_if #(.ADC_BITS(ADC_BITS)) u_adc (
        .clk(clk), .rst(rst), .adc_valid(adc_valid), .adc_code(adc_code),
        .sample_valid(smp_v), .sample(smp));

    // ---- collector (+ Hann) -> engine load ----
    wire                       f_start, f_invalid, f_inready, f_busy;
    wire signed [`SPEC_DW-1:0] f_indata;
    sample_collector #(.N(N), .WINDOW(1)) u_col (
        .clk(clk), .rst(rst), .s_valid(smp_v), .s_in(smp),
        .fft_start(f_start), .fft_in_valid(f_invalid), .fft_in_re(f_indata),
        .fft_in_ready(f_inready), .fft_busy(f_busy));

    // ---- spectrum + diagnostics ----
    wire                 mvld, mlast;
    wire [$clog2(N)-1:0] midx;
    wire [`SPEC_DW-1:0]  mval;
    fft_mag #(.N(N)) u_spec (
        .clk(clk), .rst(rst),
        .in_valid(f_invalid), .in_ready(f_inready),
        .in_re(f_indata), .in_im({`SPEC_DW{1'b0}}), .start(f_start),
        .mag_valid(mvld), .mag_idx(midx), .mag(mval), .mag_last(mlast),
        .busy(f_busy), .done());

    wire [$clog2(N)-1:0] peak_bin;
    wire [`SPEC_DW-1:0]  peak_mag, fund_mag;
    wire [15:0]          thd_pm;
    wire                 fund_present, high_thd, res_v;
    elec_diag #(.N(N)) u_diag (
        .clk(clk), .rst(rst),
        .mag_valid(mvld), .mag_idx(midx), .mag(mval), .mag_last(mlast),
        .peak_bin(peak_bin), .peak_mag(peak_mag), .fund_mag(fund_mag),
        .harm_rms(), .thd_pm(thd_pm),
        .fund_present(fund_present), .high_thd(high_thd), .result_valid(res_v));

    assign led = {thd_pm[13:6], 6'b0, high_thd, fund_present};

    // ---- UART report : on each result, send 6 bytes ----
    //   B0=0xA5 sync, B1=peak_bin, B2:B3=fund_mag, B4:B5=thd_pm
    reg  [7:0]  pkt [0:5];
    reg  [2:0]  bi;
    reg         sending, send_p;
    wire        u_busy;
    reg  [7:0]  u_data;

    integer ii;
    always @(posedge clk) begin
        if (rst) begin sending<=0; bi<=0; send_p<=0; for(ii=0;ii<6;ii=ii+1) pkt[ii]<=0; end
        else begin
            send_p <= 1'b0;
            if (res_v && !sending) begin
                pkt[0] <= 8'hA5;
                pkt[1] <= {{(8-$clog2(N)){1'b0}}, peak_bin};
                pkt[2] <= fund_mag[15:8]; pkt[3] <= fund_mag[7:0];
                pkt[4] <= thd_pm[15:8];   pkt[5] <= thd_pm[7:0];
                sending <= 1'b1; bi <= 0;
            end else if (sending && !u_busy && !send_p) begin
                u_data <= pkt[bi];
                send_p <= 1'b1;
                if (bi == 5) sending <= 1'b0;
                else         bi <= bi + 1'b1;
            end
        end
    end

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_uart (
        .clk(clk), .rst(rst), .send(send_p), .data(u_data),
        .tx(uart_tx), .busy(u_busy));
endmodule
`default_nettype wire
