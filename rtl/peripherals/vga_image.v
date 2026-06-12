// ===========================================================================
//  vga_image.v  --  640x480 grayscale display of an MxM magnitude image
// ---------------------------------------------------------------------------
//  Shows the 2D FFT magnitude spectrum as a zoomed grayscale image: a bright
//  central dot (DC) with symmetric off-center dots wherever the scene has
//  periodic structure. Each MxM cell is drawn as a ZOOM x ZOOM block. Reads the
//  magnitude from an external display RAM (addr = row*M + col).
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module vga_image #(
    parameter integer M    = 32,
    parameter integer ZOOM = 14,        // M*ZOOM should be <= 480
    parameter integer MAGSHR = 4        // magnitude -> 4-bit gray
)(
    input  wire        clk,             // 25.175 MHz
    input  wire        rst,
    output wire [2*$clog2(M)-1:0] img_addr,
    input  wire [`SPEC_DW-1:0]    img_mag,
    output reg         hsync,
    output reg         vsync,
    output reg  [3:0]  red, green, blue
);
    localparam H_VIS=640, H_FP=16, H_SY=96, H_BP=48, H_TOT=800;
    localparam V_VIS=480, V_FP=10, V_SY=2,  V_BP=33, V_TOT=525;
    localparam integer LM = $clog2(M);

    reg [9:0] hc, vc;
    always @(posedge clk) begin
        if (rst) begin hc<=0; vc<=0; end
        else if (hc==H_TOT-1) begin hc<=0; vc<=(vc==V_TOT-1)?0:vc+1'b1; end
        else hc <= hc + 1'b1;
    end
    wire visible = (hc < H_VIS) && (vc < V_VIS);

    // screen pixel -> image cell (constant divide by ZOOM)
    wire [9:0] cx = hc / ZOOM;
    wire [9:0] cy = vc / ZOOM;
    wire in_img = (cx < M) && (cy < M);
    assign img_addr = (cy[LM-1:0] << LM) | cx[LM-1:0];

    reg [3:0] gray;
    always @(posedge clk) begin
        gray <= (img_mag >> MAGSHR) > 16'd15 ? 4'hF : img_mag[MAGSHR+3:MAGSHR];
        hsync <= ~((hc >= H_VIS+H_FP) && (hc < H_VIS+H_FP+H_SY));
        vsync <= ~((vc >= V_VIS+V_FP) && (vc < V_VIS+V_FP+V_SY));
        if (visible && in_img) begin red<=gray; green<=gray; blue<=gray; end
        else begin red<=0; green<=0; blue<=0; end
    end
endmodule
`default_nettype wire
