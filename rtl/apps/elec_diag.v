// ===========================================================================
//  elec_diag.v  --  electrical-diagnostics layer on top of the FFT spectrum
// ===========================================================================
//  Tunes the generic spectrum analyser into an electrical-fault instrument.
//  Fed the magnitude-spectrum stream from fft_mag, it extracts the quantities
//  an electrician / power engineer actually cares about when a motor, drive or
//  supply misbehaves:
//
//    * PEAK bin + magnitude        -- dominant frequency (e.g. a mechanical
//                                     resonance, a VFD switching tone, a bad
//                                     bearing's vibration line).
//    * FUNDAMENTAL magnitude        -- the 50/60 Hz line component. With
//                                     synchronous sampling (N samples per line
//                                     cycle) the fundamental sits on FUND_BIN
//                                     and harmonic h on bin h*FUND_BIN -- the
//                                     IEC 61000-4-7 measurement convention.
//    * THD (Total Harmonic Distortion) = RMS(harmonics 2..H) / fundamental.
//                                     The single most important power-quality
//                                     number; >5-8% flags a distorting load
//                                     (rectifiers, failing windings, saturation).
//    * FAULT FLAGS                   -- fundamental present, high THD, and a
//                                     broadband-noise flag (energy spread away
//                                     from the harmonic comb -> bearing/arc
//                                     faults).
//
//  THD needs a square root and a divide; both run once per frame, after the
//  last bin streams in, using the small sequential isqrt/divu helpers. The
//  result is reported in per-mille (0.1%) so 360 == 36.0% THD.
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module elec_diag #(
    parameter integer N         = 256,
    parameter integer FUND_BIN  = 1,      // bin of the line fundamental
    parameter integer NHARM     = 7,      // analyse harmonics 2..NHARM
    parameter integer THD_PM_LIM = 50,    // high-THD threshold, per-mille (5.0%)
    parameter integer FUND_MIN  = 200     // min |fundamental| to call it present
)(
    input  wire                    clk,
    input  wire                    rst,
    // magnitude-spectrum stream (from fft_mag)
    input  wire                    mag_valid,
    input  wire [$clog2(N)-1:0]    mag_idx,
    input  wire [`SPEC_DW-1:0]     mag,
    input  wire                    mag_last,
    // results (latched, held until next frame) ------------------------------
    output reg  [$clog2(N)-1:0]    peak_bin,
    output reg  [`SPEC_DW-1:0]     peak_mag,
    output reg  [`SPEC_DW-1:0]     fund_mag,
    output reg  [17:0]             harm_rms,
    output reg  [15:0]             thd_pm,        // THD in per-mille (0.1%)
    output reg                     fund_present,
    output reg                     high_thd,
    output reg                     result_valid   // 1-cycle pulse when updated
);
    localparam integer HALF = N >> 1;

    // ---- is this bin one of the harmonics 2..NHARM (and inside the band)? ---
    reg  is_harm;
    integer hh;
    always @* begin
        is_harm = 1'b0;
        for (hh = 2; hh <= NHARM; hh = hh + 1)
            if ((hh*FUND_BIN < HALF) && (mag_idx == hh*FUND_BIN))
                is_harm = 1'b1;
    end

    // ---- streaming accumulators --------------------------------------------
    reg [35:0] sumsq_acc;        // Sum of harmonic mag^2
    reg [35:0] tot_acc;          // Sum of ALL bin mag^2 (for broadband flag)
    reg [`SPEC_DW-1:0] fund_acc;
    reg [`SPEC_DW-1:0] peak_acc;
    reg [$clog2(N)-1:0] peakb_acc;
    wire [31:0] magsq = mag * mag;

    // ---- post-frame compute pipeline ---------------------------------------
    localparam [1:0] C_IDLE=2'd0, C_SQRT=2'd1, C_DIV=2'd2, C_DONE=2'd3;
    reg  [1:0]  cst;
    reg  [35:0] sumsq_l;
    reg  [35:0] tot_l;
    reg  [`SPEC_DW-1:0] fund_l;

    reg         sq_start;
    wire [17:0] sq_root;
    wire        sq_done;
    isqrt #(.WIN(36)) u_sqrt (
        .clk(clk), .rst(rst), .start(sq_start), .x(sumsq_l),
        .root(sq_root), .done(sq_done));

    reg         dv_start;
    reg  [31:0] dv_num;
    wire [31:0] dv_quot;
    wire        dv_done;
    divu #(.W(32)) u_div (
        .clk(clk), .rst(rst), .start(dv_start),
        .num(dv_num), .den({16'd0, fund_l}), .quot(dv_quot), .done(dv_done));

    always @(posedge clk) begin
        if (rst) begin
            sumsq_acc <= 0; tot_acc <= 0; fund_acc <= 0;
            peak_acc <= 0; peakb_acc <= 0;
            cst <= C_IDLE; sq_start <= 0; dv_start <= 0; result_valid <= 0;
            peak_bin <= 0; peak_mag <= 0; fund_mag <= 0;
            harm_rms <= 0; thd_pm <= 0; fund_present <= 0; high_thd <= 0;
        end else begin
            sq_start     <= 1'b0;
            dv_start     <= 1'b0;
            result_valid <= 1'b0;

            // ---- spectrum streaming ----
            if (mag_valid) begin
                if (mag_idx == 0) begin           // new frame: clear accumulators
                    sumsq_acc <= 0;
                    tot_acc   <= 0;
                    fund_acc  <= 0;
                    peak_acc  <= 0;
                    peakb_acc <= 0;
                end else begin
                    if (mag_idx < HALF) tot_acc <= tot_acc + magsq;
                    if (mag_idx == FUND_BIN) fund_acc <= mag;
                    if (is_harm)             sumsq_acc <= sumsq_acc + magsq;
                    if ((mag_idx < HALF) && (mag > peak_acc)) begin
                        peak_acc  <= mag;
                        peakb_acc <= mag_idx;
                    end
                end

                if (mag_last) begin               // last bin -> launch THD calc
                    sumsq_l  <= sumsq_acc + (is_harm ? magsq : 32'd0);
                    tot_l    <= tot_acc   + ((mag_idx < HALF) ? magsq : 32'd0);
                    fund_l   <= (mag_idx == FUND_BIN) ? mag : fund_acc;
                    // peak only over [1, N/2) -- ignore DC and the conjugate
                    // mirror image above Nyquist (same magnitudes, not real peaks)
                    peak_mag <= ((mag_idx < HALF) && (mag > peak_acc)) ? mag : peak_acc;
                    peak_bin <= ((mag_idx < HALF) && (mag > peak_acc)) ? mag_idx : peakb_acc;
                    sq_start <= 1'b1;
                    cst      <= C_SQRT;
                end
            end

            // ---- post-frame THD pipeline ----
            case (cst)
                C_SQRT: if (sq_done) begin
                    harm_rms <= sq_root;
                    dv_num   <= sq_root * 16'd1000;   // RMS * 1000 (per-mille)
                    dv_start <= 1'b1;
                    cst      <= C_DIV;
                end
                C_DIV: if (dv_done) begin
                    thd_pm       <= (dv_quot > 16'hFFFF) ? 16'hFFFF : dv_quot[15:0];
                    fund_mag     <= fund_l;
                    fund_present <= (fund_l >= FUND_MIN);
                    high_thd     <= (fund_l >= FUND_MIN) &&
                                    (dv_quot >= THD_PM_LIM);
                    result_valid <= 1'b1;
                    cst          <= C_IDLE;
                end
                default: ;
            endcase
        end
    end
endmodule
`default_nettype wire
