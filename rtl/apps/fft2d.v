// ===========================================================================
//  fft2d.v  --  2D FFT for computer vision, by row-column decomposition
// ===========================================================================
//  A 2D FFT is "just" 1D FFTs done twice: transform every ROW, then transform
//  every COLUMN of the result. That is the whole trick -- and it means the
//  exact same butterfly brain (fft_engine) that powers the audio/electrical
//  paths also powers image analysis, simply driven M+M times over an MxM
//  frame buffer. The 2D magnitude spectrum it produces is the workhorse of
//  frequency-domain vision: periodic-texture and pattern detection, blur/focus
//  measurement (how much high-frequency energy survives), and periodic-noise
//  removal (notch out a bright off-center dot and inverse-transform).
//
//  ARCHITECTURE
//  ------------
//    * One complex frame buffer (two MxM BRAMs: re, im).
//    * One shared fft_engine (N = M), reused 2*M times.
//    * Orchestrator FSM: LOAD image -> ROW pass (M transforms, in place) ->
//      COLUMN pass (M transforms, in place) -> stream out magnitudes.
//    * Row k lives at addresses base=k*M, stride=1; column k at base=k,
//      stride=M. Feeding in natural order and writing engine outputs back to
//      the same positions keeps the transform fully in place.
//
//  Verified against tools/spectra_gen.py:gen_vision() -- a sinusoidal grating
//  must produce a single bright dot pair at the grating's 2D frequency.
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module fft2d #(
    parameter integer M     = 32,                       // image is M x M
    parameter         TW_RE = "rtl/generated/twiddle_re_32.mem",
    parameter         TW_IM = "rtl/generated/twiddle_im_32.mem"
)(
    input  wire                       clk,
    input  wire                       rst,
    // image input : M*M grayscale pixels, row-major, Q1.15 (im assumed 0) -----
    input  wire                       img_valid,
    input  wire signed [`SPEC_DW-1:0] img_pix,
    input  wire                       img_start,        // begin loading a frame
    // 2D magnitude output stream ---------------------------------------------
    output reg                        out_valid,
    output reg  [2*$clog2(M)-1:0]     out_addr,         // row*M + col
    output reg  [`SPEC_DW-1:0]        out_mag,
    output reg                        frame_done,       // 1-cycle pulse
    output reg                        busy
);
    localparam integer LM  = $clog2(M);     // log2(M)
    localparam integer ABW = 2*LM;          // buffer address width (M*M words)

    // ---- complex frame buffer (port A read, port B write) ------------------
    reg                        ba_we, bb_we;
    reg  [ABW-1:0]             ba_addr, bb_addr;
    reg  signed [`SPEC_DW-1:0] bb_re, bb_im;
    wire signed [`SPEC_DW-1:0] ba_re, ba_im;
    tdp_ram #(.DW(`SPEC_DW), .DEPTH(M*M), .AW(ABW)) u_bre (
        .clk(clk), .a_we(1'b0), .a_addr(ba_addr), .a_wdata({`SPEC_DW{1'b0}}), .a_rdata(ba_re),
        .b_we(bb_we), .b_addr(bb_addr), .b_wdata(bb_re), .b_rdata());
    tdp_ram #(.DW(`SPEC_DW), .DEPTH(M*M), .AW(ABW)) u_bim (
        .clk(clk), .a_we(1'b0), .a_addr(ba_addr), .a_wdata({`SPEC_DW{1'b0}}), .a_rdata(ba_im),
        .b_we(bb_we), .b_addr(bb_addr), .b_wdata(bb_im), .b_rdata());

    // ---- shared 1D engine ---------------------------------------------------
    reg                        e_start, e_in_valid;
    reg  signed [`SPEC_DW-1:0] e_in_re, e_in_im;
    wire                       e_in_ready, e_out_valid, e_out_last, e_busy, e_done;
    wire [LM-1:0]              e_out_idx;
    wire signed [`SPEC_DW-1:0] e_out_re, e_out_im;
    fft_engine #(.N(M), .TW_RE(TW_RE), .TW_IM(TW_IM)) u_eng (
        .clk(clk), .rst(rst),
        .in_valid(e_in_valid), .in_ready(e_in_ready),
        .in_re(e_in_re), .in_im(e_in_im), .start(e_start),
        .out_valid(e_out_valid), .out_idx(e_out_idx),
        .out_re(e_out_re), .out_im(e_out_im), .out_last(e_out_last),
        .busy(e_busy), .done(e_done));

    // ---- addressing : base + index*stride ----------------------------------
    reg [ABW-1:0] base;
    reg [ABW-1:0] stride;       // 1 for rows, M for columns
    reg [LM:0]    line;         // which row/column (0..M-1)
    reg [LM:0]    k;            // sample/bin counter
    wire [ABW-1:0] feed_addr = base + k*stride;

    // ---- orchestrator FSM ---------------------------------------------------
    localparam [3:0]
        T_IDLE=0, T_LOAD=1, T_START=2, T_FEED_A=3, T_FEED_D=4,
        T_COMPUTE=5, T_NEXT=6, T_PASS2=7, T_OUT_A=8, T_OUT_D=9, T_DONE=10;
    reg [3:0]      st;
    reg            pass_col;    // 0 = row pass, 1 = column pass
    reg [ABW-1:0]  ld_cnt;      // image load counter
    reg [ABW-1:0]  out_cnt;

    // Buffer read address (port A) is driven COMBINATIONALLY -- the BRAM is
    // synchronous-read, so an address presented this cycle yields data next
    // cycle. (Registering it would read one location too late.)
    always @* begin
        if (st == T_OUT_A || st == T_OUT_D) ba_addr = out_cnt;
        else                                ba_addr = feed_addr;
    end

    // magnitude of the streamed-out bins (1-cycle latency from cap_v)
    wire [`SPEC_DW-1:0] omag;
    wire               omag_v;
    reg                cap_v;
    reg  [ABW-1:0]     cap_addr;
    reg signed [`SPEC_DW-1:0] cap_re, cap_im;
    mag_alpha_beta u_omag (.clk(clk), .en(cap_v), .re(cap_re), .im(cap_im),
                           .mag(omag), .vld(omag_v));

    always @(posedge clk) begin
        if (rst) begin
            st <= T_IDLE; busy <= 0; frame_done <= 0; out_valid <= 0;
            e_start <= 0; e_in_valid <= 0; bb_we <= 0; cap_v <= 0;
            ld_cnt <= 0; out_cnt <= 0; line <= 0; k <= 0; pass_col <= 0;
        end else begin
            // one-shot / default deassertions
            e_start    <= 1'b0;
            e_in_valid <= 1'b0;
            bb_we      <= 1'b0;
            frame_done <= 1'b0;
            out_valid  <= 1'b0;
            cap_v      <= 1'b0;

            case (st)
            // ---------- wait, then load the image into the buffer ----------
            T_IDLE: begin
                busy <= 1'b0;
                if (img_start) begin ld_cnt <= 0; busy <= 1'b1; st <= T_LOAD; end
            end
            T_LOAD: if (img_valid) begin
                bb_we   <= 1'b1;          // write port B
                bb_addr <= ld_cnt;
                bb_re   <= img_pix;       // real image
                bb_im   <= {`SPEC_DW{1'b0}};
                if (ld_cnt == M*M-1) begin
                    pass_col <= 1'b0; line <= 0;
                    base <= 0; stride <= 1; st <= T_START;
                end else ld_cnt <= ld_cnt + 1'b1;
            end

            // ---------- per-line: start engine, feed M samples ----------
            T_START: begin
                e_start <= 1'b1;
                k       <= 0;
                st      <= T_FEED_A;
            end
            T_FEED_A: begin                 // address presented (combinational)
                st <= T_FEED_D;             // data ready next cycle
            end
            T_FEED_D: begin                 // buffer data valid -> hand to engine
                if (e_in_ready) begin
                    e_in_valid <= 1'b1;
                    e_in_re    <= ba_re;
                    e_in_im    <= ba_im;
                    if (k == M-1) begin k <= 0; st <= T_COMPUTE; end
                    else          begin k <= k + 1'b1; st <= T_FEED_A; end
                end
                // else: engine not ready yet, hold (re-present next cycle)
                else st <= T_FEED_A;
            end

            // ---------- capture engine outputs back into the buffer ----------
            T_COMPUTE: begin
                if (e_out_valid) begin
                    bb_we   <= 1'b1;        // write result to base + idx*stride
                    bb_addr <= base + e_out_idx*stride;
                    bb_re   <= e_out_re;
                    bb_im   <= e_out_im;
                end
                if (e_done) st <= T_NEXT;
            end

            // ---------- advance to next line / pass ----------
            T_NEXT: begin
                if (line == M-1) begin
                    if (!pass_col) begin                 // rows done -> columns
                        pass_col <= 1'b1; line <= 0;
                        base <= 0; stride <= M[ABW-1:0]; st <= T_START;
                    end else begin                       // both passes done
                        out_cnt <= 0; st <= T_OUT_A;
                    end
                end else begin
                    line <= line + 1'b1;
                    base <= pass_col ? (line + 1'b1)             // column base
                                     : ((line + 1'b1) << LM);    // row base = *M
                    st   <= T_START;
                end
            end

            // ---------- stream out 2D magnitudes ----------
            T_OUT_A: begin                  // address presented (combinational)
                st <= T_OUT_D;              // data ready next cycle
            end
            T_OUT_D: begin                  // pixel valid -> launch magnitude
                cap_v    <= 1'b1;
                cap_re   <= ba_re;
                cap_im   <= ba_im;
                cap_addr <= out_cnt;        // address of this pixel
                if (out_cnt == M*M-1) st <= T_DONE;
                else begin out_cnt <= out_cnt + 1'b1; st <= T_OUT_A; end
            end
            T_DONE: begin                   // last magnitude drains this cycle
                frame_done <= 1'b1;
                busy <= 1'b0;
                st   <= T_IDLE;
            end
            default: st <= T_IDLE;
            endcase

            // magnitude pops one cycle after cap_v; emit with its saved address
            if (omag_v) begin
                out_valid <= 1'b1;
                out_mag   <= omag;
                out_addr  <= cap_addr;
            end
        end
    end
endmodule
`default_nettype wire
