// ===========================================================================
//  adc_if.v  --  ADC sample front-end for the electrical path
// ---------------------------------------------------------------------------
//  Normalises a signed ADC code (e.g. a 12-bit bipolar SAR ADC sampling a
//  voltage/current sense) into the processor's Q1.15 format by left-aligning
//  it into the top bits. A handshake pulse marks each new sample. Sampling the
//  electrical signal synchronously to the line (N samples per 50/60 Hz cycle)
//  is what puts the fundamental on bin 1 -- do that with your ADC trigger.
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module adc_if #(
    parameter integer ADC_BITS = 12
)(
    input  wire                       clk,
    input  wire                       rst,
    input  wire                       adc_valid,           // new code strobe
    input  wire signed [ADC_BITS-1:0] adc_code,            // bipolar, signed
    output reg                        sample_valid,
    output reg  signed [`SPEC_DW-1:0] sample               // Q1.15
);
    localparam integer SHL = `SPEC_DW - ADC_BITS;          // left-align
    always @(posedge clk) begin
        if (rst) begin
            sample_valid <= 1'b0; sample <= 0;
        end else begin
            sample_valid <= adc_valid;
            if (adc_valid)
                sample <= {adc_code, {SHL{1'b0}}};          // sign preserved
        end
    end
endmodule
`default_nettype wire
