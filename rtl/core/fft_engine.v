// ===========================================================================
//  fft_engine.v  --  radix-2 DIT in-place FFT  (THE BRAIN ON THE FPGA)
// ===========================================================================
//  Iterative, area-efficient architecture: ONE butterfly datapath reused
//  N/2*log2(N) times, with the whole working set in two true dual-port BRAMs
//  (real and imaginary). The spec offered three points on the speed/area curve
//  -- 1 butterfly (small/slow), N/2 butterflies (huge/fast), or a pipeline in
//  between -- and this takes the first, cleanest point. A 256-point transform
//  is 8 stages x 128 butterflies = 1024 butterflies, 3 cycles each (~3100
//  cycles/frame): trivially real-time for audio or power-line rates while
//  costing two BRAMs and ~4 DSP48 blocks.
//
//  DATA FLOW
//  ---------
//   LOAD :  N streamed samples are written to BIT-REVERSED addresses. Doing the
//           permutation on the way IN means the decimation-in-time recurrence
//           reads naturally-ordered data and emits a naturally-ordered spectrum
//           -- no separate reorder pass.
//   BFLY :  for each stage s and butterfly bf we touch a pair (p, q):
//                 g  = bf >> (s-1)         // which group
//                 j  = bf & (2^(s-1)-1)    // position in group
//                 p  = (g << s) + j        // top element
//                 q  = p + 2^(s-1)         // bottom element
//                 tw = j << (STAGES - s)   // twiddle ROM index
//           then   top    = (X[p] + X[q]*W) / 2
//                  bottom = (X[p] - X[q]*W) / 2
//           The "/2" each stage is block scaling: no value ever leaves [-1,1),
//           so the 16-bit datapath cannot overflow; the net result is the true
//           DFT divided by N.
//   OUT  :  the N natural-order bins are streamed out (re, im, index).
//
//  TIMING.  The RAM/ROM are synchronous-read, so addresses are driven
//  COMBINATIONALLY from the FSM state (the textbook way to pipeline BRAM): an
//  address presented in cycle T yields data in cycle T+1. Each butterfly is a
//  3-phase walk:
//       RD  : present read addresses for X[p], X[q], W[tw]
//       LD  : data valid -> latch X[p], launch the complex multiply X[q]*W
//       MUL : product valid -> write (X[p]+X[q]W)/2 and (X[p]-X[q]W)/2 back
//  This is the same arithmetic, in the same order, as
//  tools/spectra_gen.py:fxp_fft(), so the hardware output is bit-for-bit
//  identical to the golden vectors (verified by sim/tb/tb_fft_cxxrtl.cc).
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module fft_engine #(
    parameter integer N        = 256,
    parameter         TW_RE    = "rtl/generated/twiddle_re_256.mem",
    parameter         TW_IM    = "rtl/generated/twiddle_im_256.mem"
)(
    input  wire                       clk,
    input  wire                       rst,        // synchronous, active high
    // streaming sample input -------------------------------------------------
    input  wire                       in_valid,
    output wire                       in_ready,
    input  wire signed [`SPEC_DW-1:0] in_re,
    input  wire signed [`SPEC_DW-1:0] in_im,      // tie 0 for real signals
    input  wire                       start,      // pulse to begin a new frame
    // streaming spectrum output ----------------------------------------------
    output reg                        out_valid,
    output reg         [$clog2(N)-1:0] out_idx,
    output reg  signed [`SPEC_DW-1:0] out_re,
    output reg  signed [`SPEC_DW-1:0] out_im,
    output reg                        out_last,
    // status -----------------------------------------------------------------
    output reg                        busy,
    output reg                        done        // 1-cycle pulse at frame end
);
    localparam integer AW     = $clog2(N);
    localparam integer STAGES = $clog2(N);
    localparam integer HALF   = N >> 1;

    // ---- bit-reversal of an AW-bit index (combinational) -------------------
    function [AW-1:0] bitrev;
        input [AW-1:0] x;
        integer b;
        begin
            bitrev = {AW{1'b0}};
            for (b = 0; b < AW; b = b + 1)
                bitrev[AW-1-b] = x[b];
        end
    endfunction

    // ======================================================================
    //  Memories : two true-dual-port RAMs (real, imag) + two twiddle ROMs
    // ======================================================================
    reg                        a_we, b_we;        // COMBINATIONAL controls
    reg  [AW-1:0]              a_addr, b_addr;
    reg  signed [`SPEC_DW-1:0] a_wd_re, b_wd_re, a_wd_im, b_wd_im;
    wire signed [`SPEC_DW-1:0] a_rd_re, b_rd_re, a_rd_im, b_rd_im;

    tdp_ram #(.DW(`SPEC_DW), .DEPTH(N), .AW(AW)) u_ram_re (
        .clk(clk),
        .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wd_re), .a_rdata(a_rd_re),
        .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wd_re), .b_rdata(b_rd_re));
    tdp_ram #(.DW(`SPEC_DW), .DEPTH(N), .AW(AW)) u_ram_im (
        .clk(clk),
        .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wd_im), .a_rdata(a_rd_im),
        .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wd_im), .b_rdata(b_rd_im));

    reg  [AW-2:0]              tw_addr;            // COMBINATIONAL, 0..N/2-1
    wire signed [`SPEC_DW-1:0] tw_re, tw_im;
    rom #(.DW(`SPEC_DW), .DEPTH(HALF), .AW(AW-1), .INIT(TW_RE)) u_tw_re (
        .clk(clk), .addr(tw_addr), .data(tw_re));
    rom #(.DW(`SPEC_DW), .DEPTH(HALF), .AW(AW-1), .INIT(TW_IM)) u_tw_im (
        .clk(clk), .addr(tw_addr), .data(tw_im));

    // ======================================================================
    //  FSM state + datapath registers
    // ======================================================================
    localparam [2:0] S_IDLE = 3'd0,
                     S_LOAD = 3'd1,
                     S_RD   = 3'd2,   // present butterfly read addresses
                     S_LD   = 3'd3,   // latch X[p], launch multiply X[q]*W
                     S_MUL  = 3'd4,   // product valid -> write results back
                     S_OUT  = 3'd5,
                     S_DONE = 3'd6;
    reg [2:0] state;

    reg [AW-1:0]   ld_cnt;            // load sample counter
    reg [AW:0]     s;                 // stage 1..STAGES
    reg [AW-1:0]   bf;                // butterfly index 0..HALF-1
    reg [AW:0]     op_cnt;            // output counter 0..N
    reg signed [`SPEC_DW-1:0] top_re, top_im;     // captured X[p]

    // ---- combinational butterfly index maths -------------------------------
    wire [AW-1:0] idx_p  = ((bf >> (s-1)) << s) + (bf & ((1 << (s-1)) - 1));
    wire [AW-1:0] idx_q  = idx_p + (1 << (s-1));
    wire [AW-2:0] idx_tw = (bf & ((1 << (s-1)) - 1)) << (STAGES - s);

    // ---- complex multiply : bottom (X[q]) * twiddle, fed combinationally ---
    wire                      cm_en = (state == S_LD);
    wire signed [`SPEC_DW-1:0] cm_pr, cm_pi;
    wire                      cm_vld;
    cmul_q15 u_cmul (
        .clk(clk), .en(cm_en),
        .ar(b_rd_re), .ai(b_rd_im), .wr(tw_re), .wi(tw_im),
        .pr(cm_pr), .pi(cm_pi), .vld(cm_vld));

    // ---- scaled butterfly outputs (valid in S_MUL) -------------------------
    wire signed [`SPEC_DW:0] sum_re = top_re + cm_pr;   // (X[p]+X[q]W), 17-bit
    wire signed [`SPEC_DW:0] sum_im = top_im + cm_pi;
    wire signed [`SPEC_DW:0] dif_re = top_re - cm_pr;
    wire signed [`SPEC_DW:0] dif_im = top_im - cm_pi;

    // ======================================================================
    //  Combinational RAM / ROM control (synchronous-read => drive addr now)
    // ======================================================================
    always @* begin
        // defaults: read the current butterfly pair
        a_we    = 1'b0;  b_we = 1'b0;
        a_addr  = idx_p; b_addr = idx_q;
        tw_addr = idx_tw;
        a_wd_re = sum_re[`SPEC_DW:1];   a_wd_im = sum_im[`SPEC_DW:1];  // top'/2
        b_wd_re = dif_re[`SPEC_DW:1];   b_wd_im = dif_im[`SPEC_DW:1];  // bot'/2

        case (state)
            S_LOAD: begin                     // write streamed sample
                a_we    = in_valid;
                a_addr  = bitrev(ld_cnt);
                a_wd_re = in_re;
                a_wd_im = in_im;
            end
            S_MUL: begin                      // write both butterfly results
                a_we = 1'b1;  b_we = 1'b1;    // addr already idx_p / idx_q
            end
            S_OUT: begin                      // sequential read-out
                a_addr = op_cnt[AW-1:0];
            end
            default: ;                        // S_RD / S_LD : read idx_p/idx_q
        endcase
    end

    // ======================================================================
    //  Sequential control
    // ======================================================================
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            out_valid <= 1'b0; out_last <= 1'b0;
            ld_cnt <= 0; s <= 1; bf <= 0; op_cnt <= 0;
        end else begin
            done      <= 1'b0;
            out_valid <= 1'b0;
            out_last  <= 1'b0;

            case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin busy <= 1'b1; ld_cnt <= 0; state <= S_LOAD; end
            end

            S_LOAD: if (in_valid) begin
                if (ld_cnt == N-1) begin s <= 1; bf <= 0; state <= S_RD; end
                else                     ld_cnt <= ld_cnt + 1'b1;
            end

            S_RD: state <= S_LD;              // addresses presented this cycle

            S_LD: begin                       // X[p]/X[q]/W valid now
                top_re <= a_rd_re;            // capture top (not multiplied)
                top_im <= a_rd_im;            // X[q]*W launches via cm_en
                state  <= S_MUL;
            end

            S_MUL: begin                      // results written this cycle
                if (bf == HALF-1) begin
                    bf <= 0;
                    if (s == STAGES) begin op_cnt <= 0; state <= S_OUT; end
                    else             begin s <= s + 1'b1; state <= S_RD; end
                end else begin
                    bf <= bf + 1'b1; state <= S_RD;
                end
            end

            // stream natural-order bins; data lags address by one cycle
            S_OUT: begin
                if (op_cnt >= 1) begin
                    out_valid <= 1'b1;
                    out_idx   <= op_cnt[AW-1:0] - 1'b1;
                    out_re    <= a_rd_re;
                    out_im    <= a_rd_im;
                    out_last  <= (op_cnt == N);
                end
                if (op_cnt == N) state <= S_DONE;
                else             op_cnt <= op_cnt + 1'b1;
            end

            S_DONE: begin done <= 1'b1; busy <= 1'b0; state <= S_IDLE; end
            default: state <= S_IDLE;
            endcase
        end
    end

    assign in_ready = (state == S_LOAD);
endmodule
`default_nettype wire
