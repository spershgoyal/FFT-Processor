// ===========================================================================
//  spectra_audio_top.v  --  REAL-TIME AUDIO SPECTRUM ANALYSER SoC
// ===========================================================================
//  The headline demo: a PDM MEMS mic in, a live VGA bar graph out.
//
//     PDM mic ─▶ pdm_mic ─▶ collector(+Hann) ─▶ fft_mag ─▶ spectrum RAM ─▶ VGA
//
//  Whistle and a green bar slides; clap and the whole spectrum flashes; hold a
//  tuning fork near the mic and a single sharp bar stands at its frequency.
//  Everything runs on the 25.175 MHz VGA pixel clock (the FFT is far faster
//  than the audio frame rate, so one clock domain keeps it simple).
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module spectra_audio_top #(
    parameter integer N        = 256,
    parameter integer NBINS    = 128,    // N/2 displayed
    parameter integer PDM_DIV  = 8       // pixclk/PDM_DIV = mic oversample clk
)(
    input  wire        clk,              // 25.175 MHz pixel clock
    input  wire        rst,
    // PDM microphone
    input  wire        pdm_data,
    output reg         pdm_clk,
    // VGA out
    output wire        hsync,
    output wire        vsync,
    output wire [3:0]  vga_r, vga_g, vga_b
);
    // ---- PDM oversample clock + tick ----
    reg [$clog2(PDM_DIV)-1:0] pdiv;
    reg pdm_tick;
    always @(posedge clk) begin
        if (rst) begin pdiv<=0; pdm_tick<=0; pdm_clk<=0; end
        else if (pdiv == PDM_DIV-1) begin pdiv<=0; pdm_tick<=1'b1; pdm_clk<=~pdm_clk; end
        else begin pdiv<=pdiv+1'b1; pdm_tick<=1'b0; end
    end

    // ---- mic -> PCM ----
    wire                       smp_v;
    wire signed [`SPEC_DW-1:0] smp;
    pdm_mic #(.DECIM(64)) u_mic (
        .clk(clk), .rst(rst), .pdm_tick(pdm_tick), .pdm_data(pdm_data),
        .sample_valid(smp_v), .sample(smp));

    // ---- collect a block (+Hann), feed the FFT ----
    wire                       f_start, f_invalid, f_inready, f_busy;
    wire signed [`SPEC_DW-1:0] f_indata;
    sample_collector #(.N(N), .WINDOW(1)) u_col (
        .clk(clk), .rst(rst), .s_valid(smp_v), .s_in(smp),
        .fft_start(f_start), .fft_in_valid(f_invalid), .fft_in_re(f_indata),
        .fft_in_ready(f_inready), .fft_busy(f_busy));

    // ---- spectrum engine ----
    wire                 mvld;
    wire [$clog2(N)-1:0] midx;
    wire [`SPEC_DW-1:0]  mval;
    fft_mag #(.N(N)) u_spec (
        .clk(clk), .rst(rst),
        .in_valid(f_invalid), .in_ready(f_inready),
        .in_re(f_indata), .in_im({`SPEC_DW{1'b0}}), .start(f_start),
        .mag_valid(mvld), .mag_idx(midx), .mag(mval), .mag_last(),
        .busy(f_busy), .done());

    // ---- spectrum RAM (FFT writes bins 0..N/2-1; VGA reads) ----
    wire [$clog2(NBINS)-1:0] vga_addr;
    wire [`SPEC_DW-1:0]      vga_mag;
    wire write_bin = mvld && (midx < NBINS);
    tdp_ram #(.DW(`SPEC_DW), .DEPTH(NBINS), .AW($clog2(NBINS))) u_spram (
        .clk(clk),
        .a_we(write_bin), .a_addr(midx[$clog2(NBINS)-1:0]), .a_wdata(mval), .a_rdata(),
        .b_we(1'b0), .b_addr(vga_addr), .b_wdata({`SPEC_DW{1'b0}}), .b_rdata(vga_mag));

    // ---- VGA bar graph ----
    vga_spectrum #(.NBINS(NBINS), .BAR_W(640/NBINS), .MAGSHR(7)) u_vga (
        .clk(clk), .rst(rst),
        .spec_addr(vga_addr), .spec_mag(vga_mag),
        .hsync(hsync), .vsync(vsync),
        .red(vga_r), .green(vga_g), .blue(vga_b));
endmodule
`default_nettype wire
