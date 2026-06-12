// ===========================================================================
//  rom.v  --  Synchronous ROM initialised from a $readmemh file
// ---------------------------------------------------------------------------
//  Used for the twiddle-factor and Hann-window tables. The contents are baked
//  in Python (tools/spectra_gen.py) and dropped in as hex so the constants are
//  provably the same in simulation, on the FPGA, and in the golden model. A
//  registered output lets the synthesizer pack this into a BRAM if it is large
//  (twiddle table) or distributed LUT-ROM if small.
// ===========================================================================
`default_nettype none
module rom #(
    parameter integer DW    = 16,
    parameter integer DEPTH = 128,
    parameter integer AW    = 7,
    parameter         INIT  = ""            // path to .mem file
)(
    input  wire          clk,
    input  wire [AW-1:0] addr,
    output reg  [DW-1:0] data
);
    (* rom_style = "block" *) reg [DW-1:0] mem [0:DEPTH-1];
    initial begin
        if (INIT != "") $readmemh(INIT, mem);
    end
    always @(posedge clk) data <= mem[addr];
endmodule
`default_nettype wire
