// ===========================================================================
//  spectra_vision_top.v  --  COMPUTER-VISION 2D-FFT SoC
// ===========================================================================
//  Camera in, frequency-domain image out:
//
//     OV7670 ─▶ cam_if ─▶ MxM crop ─▶ fft2d ─▶ display RAM ─▶ vga_image
//
//  Point the camera at a striped or textured surface and its 2D spectrum --
//  bright dots whose position encodes the pattern's frequency and orientation
//  -- appears on the VGA. This is the front door to frequency-domain vision:
//  texture/periodicity detection, blur/focus measurement, and periodic-noise
//  removal, all driven by the SAME butterfly engine as the audio path.
// ===========================================================================
`include "spectra_defs.vh"
`default_nettype none
module spectra_vision_top #(
    parameter integer M = 32
)(
    input  wire        clk,            // 25.175 MHz pixel/system clock
    input  wire        rst,
    // OV7670 camera
    input  wire        cam_pclk,
    input  wire        cam_href,
    input  wire        cam_vsync,
    input  wire [7:0]  cam_d,
    // VGA out
    output wire        hsync,
    output wire        vsync,
    output wire [3:0]  vga_r, vga_g, vga_b
);
    localparam integer MM  = M*M;
    localparam integer ABW = 2*$clog2(M);

    // ---- camera -> grayscale ----
    wire       pix_v, frame_s;
    wire [7:0] pix_lum;
    cam_if u_cam (
        .clk(clk), .rst(rst),
        .pclk(cam_pclk), .href(cam_href), .vsync(cam_vsync), .cam_d(cam_d),
        .pix_valid(pix_v), .pix_lum(pix_lum), .frame_start(frame_s));

    // ---- crop the first MxM luma pixels of each frame, feed fft2d ----
    //  luma [0,255] -> Q1.15 centred: (lum-128) << 7
    wire signed [`SPEC_DW-1:0] pix_q15 = $signed({1'b0, pix_lum} - 9'd128) <<< 7;
    reg  [ABW:0] cap_cnt;
    reg          img_valid, img_start;
    always @(posedge clk) begin
        if (rst) begin cap_cnt<=0; img_valid<=0; img_start<=0; end
        else begin
            img_valid <= 1'b0; img_start <= 1'b0;
            if (frame_s) begin cap_cnt <= 0; img_start <= 1'b1; end
            else if (pix_v && cap_cnt < MM) begin
                img_valid <= 1'b1;
                cap_cnt   <= cap_cnt + 1'b1;
            end
        end
    end

    // ---- 2D FFT ----
    wire              o_v, fdone, e_busy;
    wire [ABW-1:0]    o_addr;
    wire [`SPEC_DW-1:0] o_mag;
    fft2d #(.M(M)) u_fft2d (
        .clk(clk), .rst(rst),
        .img_valid(img_valid), .img_pix(pix_q15), .img_start(img_start),
        .out_valid(o_v), .out_addr(o_addr), .out_mag(o_mag),
        .frame_done(fdone), .busy(e_busy));

    // ---- display RAM (fft2d writes magnitudes, VGA reads) ----
    wire [ABW-1:0]      vaddr;
    wire [`SPEC_DW-1:0] vmag;
    tdp_ram #(.DW(`SPEC_DW), .DEPTH(MM), .AW(ABW)) u_disp (
        .clk(clk),
        .a_we(o_v), .a_addr(o_addr), .a_wdata(o_mag), .a_rdata(),
        .b_we(1'b0), .b_addr(vaddr), .b_wdata({`SPEC_DW{1'b0}}), .b_rdata(vmag));

    // ---- VGA grayscale image ----
    vga_image #(.M(M), .ZOOM(14), .MAGSHR(4)) u_vga (
        .clk(clk), .rst(rst),
        .img_addr(vaddr), .img_mag(vmag),
        .hsync(hsync), .vsync(vsync),
        .red(vga_r), .green(vga_g), .blue(vga_b));
endmodule
`default_nettype wire
