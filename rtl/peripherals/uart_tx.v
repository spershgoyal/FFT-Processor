// ===========================================================================
//  uart_tx.v  --  8-N-1 UART transmitter
// ---------------------------------------------------------------------------
//  The simplest real-world escape hatch: stream the spectrum or the diagnostic
//  numbers out a serial line so a laptop can plot them. One start bit, 8 data
//  bits LSB-first, one stop bit, no parity. CLK_HZ/BAUD sets the bit period.
// ===========================================================================
`default_nettype none
module uart_tx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       send,        // pulse to transmit `data`
    input  wire [7:0] data,
    output reg        tx,          // serial line (idle high)
    output reg        busy
);
    localparam integer DIV = CLK_HZ / BAUD;
    reg [$clog2(DIV)-1:0] cnt;
    reg [3:0]  bit_idx;
    reg [9:0]  shifter;            // {stop, data[7:0], start}

    always @(posedge clk) begin
        if (rst) begin
            tx <= 1'b1; busy <= 1'b0; cnt <= 0; bit_idx <= 0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (send) begin
                shifter <= {1'b1, data, 1'b0};   // stop + data + start
                busy    <= 1'b1;
                cnt     <= 0;
                bit_idx <= 0;
            end
        end else begin
            if (cnt == DIV-1) begin
                cnt <= 0;
                tx  <= shifter[0];
                shifter <= {1'b1, shifter[9:1]};
                if (bit_idx == 9) busy <= 1'b0;
                else              bit_idx <= bit_idx + 1'b1;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
