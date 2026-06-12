// ===========================================================================
//  cam_if.v  --  OV7670 camera capture -> grayscale pixel stream
// ---------------------------------------------------------------------------
//  The OV7670 (configured for YUV422) clocks out two bytes per pixel on pclk
//  while href is high: Y (luma), then U/V (chroma). For frequency-domain vision
//  we only need luma, so we grab the Y byte and drop chroma, producing an
//  8-bit grayscale stream with frame/line framing. vsync marks frame start.
//  A downstream subsampler picks the MxM block the 2D FFT consumes.
// ===========================================================================
`default_nettype none
module cam_if (
    input  wire        clk,          // system clock (capture domain)
    input  wire        rst,
    // OV7670 pixel interface
    input  wire        pclk,         // pixel clock from camera
    input  wire        href,         // line valid
    input  wire        vsync,        // frame sync (pulse between frames)
    input  wire [7:0]  cam_d,        // pixel byte
    // grayscale output
    output reg         pix_valid,
    output reg  [7:0]  pix_lum,      // 8-bit luma
    output reg         frame_start
);
    // bring camera signals into the system clock domain (2-FF synchronisers)
    reg [2:0] pclk_s, href_s, vsync_s;
    reg [7:0] d_s;
    always @(posedge clk) begin
        pclk_s  <= {pclk_s[1:0],  pclk};
        href_s  <= {href_s[1:0],  href};
        vsync_s <= {vsync_s[1:0], vsync};
        d_s     <= cam_d;
    end
    wire pclk_rise = (pclk_s[2:1] == 2'b01);
    wire vsync_rise = (vsync_s[2:1] == 2'b01);

    reg byte_sel;   // 0 = Y byte (keep), 1 = chroma (drop)
    always @(posedge clk) begin
        if (rst) begin
            pix_valid <= 1'b0; frame_start <= 1'b0; byte_sel <= 1'b0;
        end else begin
            pix_valid   <= 1'b0;
            frame_start <= 1'b0;
            if (vsync_rise) begin
                byte_sel    <= 1'b0;      // YUV phase resets each frame
                frame_start <= 1'b1;
            end else if (pclk_rise && href_s[2]) begin
                byte_sel <= ~byte_sel;
                if (byte_sel == 1'b0) begin   // this is a Y (luma) byte
                    pix_lum   <= d_s;
                    pix_valid <= 1'b1;
                end
            end
        end
    end
endmodule
`default_nettype wire
