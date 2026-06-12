// ===========================================================================
//  isqrt.v  --  sequential integer square root, floor(sqrt(x))
// ---------------------------------------------------------------------------
//  Used by the electrical-diagnostics block to turn "sum of harmonic energies"
//  into an RMS amplitude for the THD ratio. The classic digit-by-digit
//  (non-restoring) algorithm needs only adders/shifts (no multiplier) and runs
//  once per FFT frame, so its latency is free. WIN must be even.
//
//  Algorithm (Hacker's-Delight style):
//      one = highest power of four <= x      (SHRINK phase, res stays 0)
//      while one != 0:                       (ITER phase)
//          if op >= res + one: op -= res+one; res = res>>1 + one
//          else:                              res = res>>1
//          one >>= 2
//      root = res
// ===========================================================================
`default_nettype none
module isqrt #(
    parameter integer WIN = 36          // radicand width (even)
)(
    input  wire             clk,
    input  wire             rst,
    input  wire             start,
    input  wire [WIN-1:0]   x,
    output reg  [WIN/2-1:0] root,
    output reg              done
);
    localparam [1:0] S_IDLE = 2'd0, S_SHRINK = 2'd1, S_ITER = 2'd2, S_FIN = 2'd3;
    reg [1:0]       st;
    reg [WIN-1:0]   op, res, one;
    wire [WIN-1:0]  res_one = res + one;

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; done <= 1'b0; root <= 0;
        end else begin
            done <= 1'b0;
            case (st)
                S_IDLE: if (start) begin
                    op  <= x;
                    res <= 0;
                    one <= {2'b01, {(WIN-2){1'b0}}};   // 4^(WIN/2-1)
                    st  <= S_SHRINK;
                end
                // bring `one` down to the highest power of four <= x
                S_SHRINK: if (one > op) one <= one >> 2;
                          else          st  <= S_ITER;
                // main digit-by-digit loop
                S_ITER: begin
                    if (one == 0) begin
                        st <= S_FIN;
                    end else begin
                        if (op >= res_one) begin
                            op  <= op - res_one;
                            res <= (res >> 1) + one;
                        end else begin
                            res <= res >> 1;
                        end
                        one <= one >> 2;
                    end
                end
                S_FIN: begin
                    root <= res[WIN/2-1:0];
                    done <= 1'b1;
                    st   <= S_IDLE;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
