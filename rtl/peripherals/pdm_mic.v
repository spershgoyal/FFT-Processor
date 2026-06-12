// ===========================================================================
//  pdm_mic.v  --  PDM MEMS microphone front-end (1-bit stream -> PCM)
// ---------------------------------------------------------------------------
//  A PDM MEMS mic (e.g. on the Nexys/PYNQ boards) outputs a 1-bit, heavily
//  oversampled sigma-delta stream: the LOCAL DENSITY of 1s encodes the audio
//  amplitude. To recover a PCM sample we low-pass and decimate. This is a
//  first-order CIC (sinc) decimator: sum (bit*2-1) over DECIM PDM clocks, which
//  both removes the carrier and centres the result around zero, then scale into
//  Q1.15. Increase to a higher-order CIC for sharper roll-off; sinc1 is plenty
//  to see speech/whistle/clap spectra.
//
//  Drive `pdm_clk` out to the mic and sample `pdm_data` on the matching edge;
//  here we accept a `pdm_tick` enable (one per PDM bit) so the host can set the
//  oversample clock.
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module pdm_mic #(
    parameter integer DECIM = 64        // PDM bits per PCM sample (OSR)
)(
    input  wire                       clk,
    input  wire                       rst,
    input  wire                       pdm_tick,    // 1-cycle enable per PDM bit
    input  wire                       pdm_data,    // 1-bit mic stream
    output reg                        sample_valid,
    output reg  signed [`SPEC_DW-1:0] sample       // Q1.15 PCM
);
    localparam integer CW  = $clog2(DECIM) + 1;
    localparam integer SHL = `SPEC_DW - CW;         // scale sum up into Q1.15
    reg  signed [CW:0]  acc;        // running sum of +/-1
    reg  [$clog2(DECIM)-1:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            acc <= 0; cnt <= 0; sample_valid <= 1'b0; sample <= 0;
        end else begin
            sample_valid <= 1'b0;
            if (pdm_tick) begin
                acc <= acc + (pdm_data ? 1 : -1);    // +/-1 per bit
                if (cnt == DECIM-1) begin
                    cnt          <= 0;
                    // acc in [-DECIM, +DECIM]; left-align into Q1.15
                    sample       <= (SHL >= 0) ? (acc <<< SHL) : (acc >>> (-SHL));
                    sample_valid <= 1'b1;
                    acc          <= (pdm_data ? 1 : -1);   // restart accumulation
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
