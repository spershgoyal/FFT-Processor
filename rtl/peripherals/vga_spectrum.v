// ===========================================================================
//  vga_spectrum.v  --  640x480@60 VGA spectrum bar-graph display
// ---------------------------------------------------------------------------
//  The pretty half of the project: it turns the magnitude spectrum into the
//  classic live bar graph, so a whistle slides a peak across the screen and a
//  tuning fork plants one sharp bar. Standard 640x480 timing on a 25.175 MHz
//  pixel clock. Each screen column maps to a spectrum bin; the bin's magnitude
//  sets the bar height (drawn growing up from the bottom). It reads bar heights
//  from an external spectrum RAM (spec_addr -> spec_mag), which the FFT path
//  fills as bins stream out.
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module vga_spectrum #(
    parameter integer NBINS  = 128,     // bins shown (N/2)
    parameter integer BAR_W  = 5,       // pixels per bin (128*5 = 640)
    parameter integer MAGSHR = 7        // mag >> MAGSHR -> bar height (<=480)
)(
    input  wire        clk,             // 25.175 MHz pixel clock
    input  wire        rst,
    // spectrum read port
    output wire [$clog2(NBINS)-1:0] spec_addr,
    input  wire [`SPEC_DW-1:0]      spec_mag,
    // VGA outputs
    output reg         hsync,
    output reg         vsync,
    output reg  [3:0]  red,
    output reg  [3:0]  green,
    output reg  [3:0]  blue
);
    // 640x480@60 timing (VESA): H 640+16+96+48=800, V 480+10+2+33=525
    localparam H_VIS=640, H_FP=16, H_SY=96, H_BP=48, H_TOT=800;
    localparam V_VIS=480, V_FP=10, V_SY=2,  V_BP=33, V_TOT=525;

    reg [9:0] hc, vc;
    always @(posedge clk) begin
        if (rst) begin hc<=0; vc<=0; end
        else if (hc==H_TOT-1) begin hc<=0; vc<=(vc==V_TOT-1)?0:vc+1'b1; end
        else hc <= hc + 1'b1;
    end
    wire visible = (hc < H_VIS) && (vc < V_VIS);

    // column -> bin (constant divide by BAR_W)
    wire [$clog2(NBINS)-1:0] bin = hc / BAR_W;
    assign spec_addr = (bin < NBINS) ? bin : (NBINS-1);

    // bar height from magnitude; spec_mag has 1-cycle read latency so register
    reg [9:0] bar_h;
    always @(posedge clk)
        bar_h <= (spec_mag >> MAGSHR) > 10'd479 ? 10'd479 : (spec_mag >> MAGSHR);

    wire in_bar = visible && ((10'd479 - vc) < bar_h);

    // simple spectral colouring: green bars on black, brighter near the top
    always @(posedge clk) begin
        hsync <= ~((hc >= H_VIS+H_FP) && (hc < H_VIS+H_FP+H_SY));  // active low
        vsync <= ~((vc >= V_VIS+V_FP) && (vc < V_VIS+V_FP+V_SY));
        if (in_bar) begin
            red   <= bar_h[9:6];
            green <= 4'hF;
            blue  <= 4'h2;
        end else begin
            red <= 4'h0; green <= 4'h0; blue <= 4'h0;
        end
    end
endmodule
`default_nettype wire
