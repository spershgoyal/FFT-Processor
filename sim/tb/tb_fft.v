// ===========================================================================
//  tb_fft.v  --  self-checking Icarus/Verilator testbench for fft_mag
// ---------------------------------------------------------------------------
//  A plain-Verilog twin of sim/tb/tb_fft_cxxrtl.cc, for anyone who would rather
//  run the standard event simulator. Streams the golden input, collects the
//  magnitude spectrum, and checks it bit-for-bit against the golden vectors.
//      iverilog -g2012 -I rtl/core <core .v files> sim/tb/tb_fft.v && vvp a.out
// ===========================================================================
`timescale 1ns/1ps
`include "spectra_defs.vh"
module tb_fft;
    localparam integer N = 256, HALF = 128, PEAK = 19;
    reg clk = 0, rst = 1, start = 0, in_valid = 0;
    reg signed [`SPEC_DW-1:0] in_re = 0;
    wire mag_valid, mag_last, in_ready, busy, done;
    wire [$clog2(N)-1:0] mag_idx;
    wire [`SPEC_DW-1:0] mag;

    always #5 clk = ~clk;   // 100 MHz

    fft_mag #(.N(N)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .in_ready(in_ready),
        .in_re(in_re), .in_im({`SPEC_DW{1'b0}}), .start(start),
        .mag_valid(mag_valid), .mag_idx(mag_idx), .mag(mag),
        .mag_last(mag_last), .busy(busy), .done(done));

    reg signed [`SPEC_DW-1:0] stim [0:N-1];
    reg        [`SPEC_DW-1:0] gold [0:HALF-1];
    reg        [`SPEC_DW-1:0] got  [0:N-1];
    integer i, peak_bin, peak_val, mism;

    initial begin
        $readmemh("sim/vectors/tb_input_256.mem", stim);
        $readmemh("sim/vectors/tb_expected_mag_256.mem", gold);
        for (i = 0; i < N; i = i + 1) got[i] = 16'hFFFF;

        repeat (4) @(posedge clk); rst = 0; @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        for (i = 0; i < N; i = i + 1) begin
            in_valid = 1; in_re = stim[i]; @(posedge clk);
        end
        in_valid = 0;

        // collect
        peak_bin = -1; peak_val = -1;
        for (i = 0; i < 20000; i = i + 1) begin
            @(posedge clk);
            if (mag_valid) begin
                got[mag_idx] = mag;
                if ((mag > peak_val) && (mag_idx < HALF)) begin
                    peak_val = mag; peak_bin = mag_idx;
                end
            end
        end

        mism = 0;
        for (i = 0; i < HALF; i = i + 1)
            if (got[i] !== gold[i]) mism = mism + 1;

        $display("peak bin = %0d (expect %0d), mismatches = %0d", peak_bin, PEAK, mism);
        if (peak_bin == PEAK && mism == 0) $display("RESULT: PASS");
        else                               $display("RESULT: FAIL");
        $finish;
    end
endmodule
