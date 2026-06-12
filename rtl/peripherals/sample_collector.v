// ===========================================================================
//  sample_collector.v  --  decouple slow sample input from fast FFT bursts
// ---------------------------------------------------------------------------
//  Audio/electrical samples trickle in at tens of kHz; the FFT consumes a whole
//  N-sample block in a fast burst and then chews on it for a few thousand
//  cycles. This block bridges the two: it fills an N-deep buffer at the input
//  rate, and when full bursts the block into the engine and pulses `start`.
//  (Samples arriving during the compute window are dropped -- harmless, since a
//  256-pt FFT finishes in microseconds versus a multi-millisecond audio frame.)
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module sample_collector #(
    parameter integer N      = 256,
    parameter integer WINDOW = 1,                 // 1 = apply Hann window
    parameter         HANN   = "rtl/generated/hann_256.mem"
)(
    input  wire                       clk,
    input  wire                       rst,
    // streamed input samples (Q1.15)
    input  wire                       s_valid,
    input  wire signed [`SPEC_DW-1:0] s_in,
    // engine load interface
    output reg                        fft_start,
    output reg                        fft_in_valid,
    output reg  signed [`SPEC_DW-1:0] fft_in_re,
    input  wire                       fft_in_ready,
    input  wire                       fft_busy
);
    localparam integer AW = $clog2(N);

    reg                 wr_we;
    reg  [AW-1:0]       wr_addr;
    reg  signed [`SPEC_DW-1:0] wr_data;
    reg  [AW-1:0]       rp;          // read pointer
    wire [AW-1:0]       rd_addr = rp; // combinational read addr (sync BRAM)
    wire signed [`SPEC_DW-1:0] rd_data;

    tdp_ram #(.DW(`SPEC_DW), .DEPTH(N), .AW(AW)) u_buf (
        .clk(clk),
        .a_we(wr_we), .a_addr(wr_addr), .a_wdata(wr_data), .a_rdata(),
        .b_we(1'b0),  .b_addr(rd_addr), .b_wdata({`SPEC_DW{1'b0}}), .b_rdata(rd_data));

    // Hann coefficient ROM, read with the SAME combinational pointer as the
    // buffer, so coeff and sample share a 1-cycle latency and stay aligned.
    wire signed [`SPEC_DW-1:0] coeff;
    generate if (WINDOW) begin : g_win
        rom #(.DW(`SPEC_DW), .DEPTH(N), .AW(AW), .INIT(HANN)) u_hann (
            .clk(clk), .addr(rd_addr), .data(coeff));
    end else begin : g_nowin
        assign coeff = {1'b0, {(`SPEC_QF){1'b1}}};   // ~1.0 in Q1.15
    end endgenerate
    wire signed [`SPEC_PW-1:0] win_prod = rd_data * coeff;
    wire signed [`SPEC_DW-1:0] win_samp = WINDOW ? `Q15_NARROW(win_prod) : rd_data;

    localparam [1:0] C_FILL=0, C_START=1, C_FEED_A=2, C_FEED_D=3;
    reg [1:0]   st;
    reg [AW-1:0] wp;

    always @(posedge clk) begin
        if (rst) begin
            st <= C_FILL; wp <= 0; rp <= 0;
            wr_we <= 0; fft_start <= 0; fft_in_valid <= 0;
        end else begin
            wr_we        <= 1'b0;
            fft_start    <= 1'b0;
            fft_in_valid <= 1'b0;

            case (st)
            C_FILL: if (s_valid) begin     // accumulate a block at input rate
                wr_we   <= 1'b1;
                wr_addr <= wp;
                wr_data <= s_in;
                if (wp == N-1) begin wp <= 0; st <= C_START; end
                else                 wp <= wp + 1'b1;
            end
            C_START: if (!fft_busy) begin  // engine idle -> kick off a transform
                fft_start <= 1'b1;
                rp        <= 0;
                st        <= C_FEED_A;
            end
            C_FEED_A: st <= C_FEED_D;       // read address presented
            C_FEED_D: if (fft_in_ready) begin
                fft_in_valid <= 1'b1;
                fft_in_re    <= win_samp;        // windowed (or raw) sample
                if (rp == N-1) begin rp <= 0; st <= C_FILL; end
                else          begin rp <= rp + 1'b1; st <= C_FEED_A; end
            end else st <= C_FEED_A;
            endcase
        end
    end
endmodule
`default_nettype wire
