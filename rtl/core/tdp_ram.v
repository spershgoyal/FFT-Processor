// ===========================================================================
//  tdp_ram.v  --  True Dual-Port RAM (two independent read/write ports)
// ---------------------------------------------------------------------------
//  This is the single most important structural choice in the whole FFT. A
//  radix-2 butterfly touches TWO memory locations at once (X[p] and X[q]); it
//  reads both, and later writes both back. A normal single-port RAM would
//  force us to do that one element at a time and the engine would crawl.
//
//  A *true* dual-port RAM exposes two fully independent ports, each able to
//  read OR write any address every cycle. On a Xilinx 7-series part yosys/
//  Vivado infer this directly into a RAMB36E1 block (one BRAM = up to 1024
//  36-bit words), so the entire 256-point working buffer costs a single BRAM
//  per component (real / imaginary). The coding pattern below -- two clocked
//  always blocks, registered read data, no read-during-write assumptions --
//  is exactly the template the inference engines look for.
// ===========================================================================
`default_nettype none
module tdp_ram #(
    parameter integer DW    = 16,           // data width
    parameter integer DEPTH = 256,          // number of words
    parameter integer AW    = 8             // address width = ceil(log2(DEPTH))
)(
    input  wire           clk,
    // Port A
    input  wire           a_we,             // 1 = write, 0 = read
    input  wire [AW-1:0]  a_addr,
    input  wire [DW-1:0]  a_wdata,
    output reg  [DW-1:0]  a_rdata,
    // Port B
    input  wire           b_we,
    input  wire [AW-1:0]  b_addr,
    input  wire [DW-1:0]  b_wdata,
    output reg  [DW-1:0]  b_rdata
);
    // The storage array. `ram_style="block"` is a hint; inference works without
    // it but it makes intent explicit to the synthesizer.
    (* ram_style = "block" *) reg [DW-1:0] mem [0:DEPTH-1];

    // Port A : registered-read, synchronous write.
    always @(posedge clk) begin
        if (a_we) mem[a_addr] <= a_wdata;
        a_rdata <= mem[a_addr];             // read returns OLD data on write
    end

    // Port B : identical, independent.
    always @(posedge clk) begin
        if (b_we) mem[b_addr] <= b_wdata;
        b_rdata <= mem[b_addr];
    end
endmodule
`default_nettype wire
