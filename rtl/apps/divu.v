// ===========================================================================
//  divu.v  --  sequential unsigned restoring divider
// ---------------------------------------------------------------------------
//  One quotient bit per cycle, adders only. The diagnostics block uses it once
//  per frame to form the THD ratio (harmonic_RMS * 1000) / fundamental, so W
//  cycles of latency is irrelevant. Division-by-zero yields all-ones (clamped),
//  which the caller treats as "no valid fundamental".
// ===========================================================================
`default_nettype none
module divu #(
    parameter integer W = 32
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [W-1:0] num,
    input  wire [W-1:0] den,
    output reg  [W-1:0] quot,
    output reg          done
);
    reg [W-1:0]  q, d;
    reg [W:0]    rem;            // one guard bit
    reg [$clog2(W+1)-1:0] cnt;
    reg          busy;

    wire [W:0] rem_shift = {rem[W-1:0], q[W-1]};   // shift MSB of q into rem

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; done <= 1'b0; quot <= 0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                if (den == 0) begin
                    quot <= {W{1'b1}};   // div-by-zero -> saturate
                    done <= 1'b1;
                end else begin
                    q <= num; d <= den; rem <= 0; cnt <= W[$clog2(W+1)-1:0];
                    busy <= 1'b1;
                end
            end else if (busy) begin
                if (rem_shift >= {1'b0, d}) begin
                    rem <= rem_shift - {1'b0, d};
                    q   <= {q[W-2:0], 1'b1};
                end else begin
                    rem <= rem_shift;
                    q   <= {q[W-2:0], 1'b0};
                end
                cnt <= cnt - 1'b1;
                if (cnt == 1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    quot <= (rem_shift >= {1'b0, d}) ? {q[W-2:0], 1'b1}
                                                     : {q[W-2:0], 1'b0};
                end
            end
        end
    end
endmodule
`default_nettype wire
