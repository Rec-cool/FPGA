`timescale 1ns/1ps

// R3'-B: timestamp OSD - MM:SS elapsed-time counter rendered in the top
// right corner. The topic's first example for extension 1 is "叠加动态文字
// （如时间戳或标语）" - we have the slogan but not the timestamp. This module
// counts frames at 60 Hz and renders a "MM:SS" overlay.
module timestamp_osd #(
    parameter integer OSD_X = 500,            // right-aligned-ish
    parameter integer OSD_Y = 8,              // top row, same as status OSD
    parameter integer CHAR_W = 8,             // 8x16 pixel characters
    parameter integer CHAR_H = 16
) (
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        enable,
    input  wire        vsync,
    input  wire        de,
    input  wire [9:0]  pixel_x,
    input  wire [11:0] pixel_y,
    input  wire [23:0] rgb_in,
    output wire [23:0] rgb_out,
    output wire        ts_active,
    // sys domain: reset the timer
    input  wire        sys_rst_n
);
    // frame counter -> elapsed seconds
    reg [5:0]  frame_cnt;       // 0..59
    reg [15:0] sec_cnt;         // seconds since boot (or timer reset)
    reg        vs_q;
    wire       frame_start = vs_q && !vsync;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            frame_cnt <= 6'd0;
            sec_cnt   <= 16'd0;
            vs_q      <= 1'b1;
        end else begin
            vs_q <= vsync;
            if (frame_start) begin
                if (frame_cnt == 6'd59) begin
                    frame_cnt <= 6'd0;
                    sec_cnt  <= sec_cnt + 1'b1;
                end else begin
                    frame_cnt <= frame_cnt + 1'b1;
                end
            end
        end
    end

    // reset timer from sys domain (2FF sync of sys_rst_n edge)
    // For now: reset only by pix_rst_n (power-on). Timer reset via UART
    // command can be added later.

    // digit extraction (combinational)
    wire [3:0] mm_tens  = (sec_cnt / 60) / 10;
    wire [3:0] mm_ones = (sec_cnt / 60) % 10;
    wire [3:0] ss_tens  = (sec_cnt % 60) / 10;
    wire [3:0] ss_ones = (sec_cnt % 60) % 10;

    // pixel offset within the character block
    wire [9:0] dx = pixel_x - OSD_X;
    wire [11:0] dy = pixel_y - OSD_Y;

    // active when in the 5-character region
    wire in_region = enable && de &&
                     pixel_x >= OSD_X && pixel_x < OSD_X + 5 * CHAR_W &&
                     pixel_y >= OSD_Y && pixel_y < OSD_Y + CHAR_H;

    assign ts_active = in_region;

    // 4x6 pixel font (doubled to 8x12 effective, leaves 4px padding)
    // Each digit is 4 wide x 6 tall, doubled vertically = 12 rows
    function font_pixel;
        input [3:0] digit;
        input [3:0] col;   // 0..3
        input [3:0] row;   // 0..5 (logical row before doubling)
        begin
            case (digit)
                4'd0: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==0||col==3)) ||
                                   (row==3 && (col==0||col==3)) ||
                                   (row==4 && (col==0||col==3)) ||
                                   (row==5 && (col==1||col==2));
                4'd1: font_pixel = (col==2) ||
                                   (row==0 && col==1) ||
                                   (row==2 && (col==1||col==3)) ||
                                   (row==5 && (col==1||col==2||col==3));
                4'd2: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && col==3) ||
                                   (row==2 && (col==1||col==2)) ||
                                   (row==3 && col==1) ||
                                   (row==4 && col==0) ||
                                   (row==5 && (col==1||col==2||col==3));
                4'd3: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && col==3) ||
                                   (row==2 && (col==1||col==2)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && (col==1||col==2));
                4'd4: font_pixel = (row==0 && (col==0||col==3)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==0||col==1||col==2||col==3)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && col==3);
                4'd5: font_pixel = (row==0 && (col==0||col==1||col==2||col==3)) ||
                                   (row==1 && col==0) ||
                                   (row==2 && (col==0||col==1||col==2)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && (col==1||col==2));
                4'd6: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && col==0) ||
                                   (row==2 && (col==0||col==1||col==2)) ||
                                   (row==3 && (col==0||col==3)) ||
                                   (row==4 && (col==0||col==3)) ||
                                   (row==5 && (col==1||col==2));
                4'd7: font_pixel = (row==0 && (col==0||col==1||col==2||col==3)) ||
                                   (row==1 && col==3) ||
                                   (row==2 && col==2) ||
                                   (row==3 && col==2) ||
                                   (row==4 && col==2) ||
                                   (row==5 && col==2);
                4'd8: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==1||col==2)) ||
                                   (row==3 && (col==0||col==3)) ||
                                   (row==4 && (col==0||col==3)) ||
                                   (row==5 && (col==1||col==2));
                4'd9: font_pixel = (row==0 && (col==1||col==2)) ||
                                   (row==1 && (col==0||col==3)) ||
                                   (row==2 && (col==1||col==2||col==3)) ||
                                   (row==3 && col==3) ||
                                   (row==4 && col==3) ||
                                   (row==5 && (col==1||col==2));
                default: font_pixel = 1'b0;
            endcase
        end
    endfunction

    // colon character (between MM and SS)
    function colon_pixel;
        input [3:0] col;
        input [3:0] row;
        begin
            colon_pixel = (col >= 1 && col <= 2) &&
                          ((row >= 1 && row <= 2) || (row >= 3 && row <= 4));
        end
    endfunction

    // determine which digit this pixel belongs to and render
    reg ts_pixel;
    wire [3:0] fcol = dx % CHAR_W;
    wire [3:0] frow = (dy % CHAR_H) / 2;
    always @* begin
        ts_pixel = 1'b0;
        if (in_region && dx < 5 * CHAR_W && dy < CHAR_H) begin
            if (frow < 6) begin
                case (dx / CHAR_W)
                3'd0: ts_pixel = font_pixel(mm_tens, fcol, frow);
                3'd1: ts_pixel = font_pixel(mm_ones, fcol, frow);
                3'd2: ts_pixel = colon_pixel(fcol, frow);
                3'd3: ts_pixel = font_pixel(ss_tens, fcol, frow);
                3'd4: ts_pixel = font_pixel(ss_ones, fcol, frow);
                default: ts_pixel = 1'b0;
                endcase
            end
        end
    end

    // overlay: white-ish text with dark shadow for readability
    assign rgb_out = ts_pixel ? 24'hE0F0FF : rgb_in;
endmodule
