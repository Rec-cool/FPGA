module cdc_blk #(parameter integer AUTO_PLAY_MS = 1500) (
  input sd_card_clk, input sdcard_rst_n, input cfg_apply, input [5:0] cfg_mask, input [48:0] cfg_val,
  input video_clk, input video_rst_n, input adj_toggle, input sw1, input sw2, input frame_start);
localparam [7:0] AUTO_PLAY_SEC = AUTO_PLAY_MS / 1000;
reg  [7:0] volume_sd, volume_pix;
reg  [7:0] period_sec_sd;
reg [15:0] period_ms_pix;
wire [7:0] cfg_vol_x25 = {cfg_val[3:0], 4'd0} + {1'b0, cfg_val[3:0], 3'd0} + {4'd0, cfg_val[3:0]};   // 0~10 → 0~250
reg        cfg_tog;
reg [18:0] cfg_bus;                  // {翻转, VOL/CON/BRI/INT 有效[3:0], 音量档[3:0], 对比度[2:0], 亮度[1:0], 间隔秒[4:0]}
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        volume_sd     <= 8'd220;
        period_sec_sd <= AUTO_PLAY_SEC;
        cfg_tog       <= 1'b0;
        cfg_bus       <= 19'd0;
    end else if (cfg_apply) begin
        if (cfg_mask[5]) volume_sd     <= cfg_vol_x25;
        if (cfg_mask[0]) period_sec_sd <= {3'd0, cfg_val[16:12]};
        cfg_tog <= ~cfg_tog;
        cfg_bus <= {~cfg_tog, cfg_mask[5], cfg_mask[3], cfg_mask[2], cfg_mask[0],
                    cfg_val[3:0], cfg_val[8:6], cfg_val[10:9], cfg_val[16:12]};
    end
end
function [7:0] bri_lut;
    input [1:0] level;
    case(level)
        2'd0: bri_lut = 8'd64;
        2'd1: bri_lut = 8'd128;
        2'd2: bri_lut = 8'd192;
        default: bri_lut = 8'd255;
    endcase
endfunction
function [7:0] con_lut;
      input [2:0] level;
      case (level)
          3'd0: con_lut = 8'd64;
          3'd1: con_lut = 8'd96;
          3'd2: con_lut = 8'd128;
          3'd3: con_lut = 8'd160;
          3'd4: con_lut = 8'd192;
          default: con_lut = 8'd224;
      endcase
endfunction
(* ASYNC_REG = "TRUE" *) reg adj_t_s1;
(* ASYNC_REG = "TRUE" *) reg adj_t_s2;
reg adj_t_d;
reg sel_s1,sel_s2;
reg [1:0] bri_level;
reg [2:0] con_level;
reg [7:0] brightness_pix, contrast_pix;
wire adj_step = adj_t_s2 ^ adj_t_d;
reg show_s1, show_s2;
// CONFIG.TXT（CF）：cfg_bus 进 video 域
(* ASYNC_REG = "TRUE" *) reg [18:0] cfg_v1, cfg_v2;
reg [18:0] cfg_v3;
reg        cfg_tog_pix;
wire       cfg_hit = (cfg_v2 == cfg_v3) && (cfg_v3[18] != cfg_tog_pix);
wire [4:0] cfg_sec_pix = cfg_v3[4:0];
wire [3:0] cfg_vol_pix = cfg_v3[13:10];
always @(posedge video_clk or negedge video_rst_n) begin
    if(!video_rst_n)begin
        adj_t_s1 <= 1'b0; adj_t_s2 <= 1'b0; adj_t_d <= 1'b0;
        sel_s1 <= 1'b0; sel_s2 <= 1'b0;
        show_s1 <= 1'b0; show_s2 <= 1'b0;
        bri_level <= 2'd3;  con_level <= 3'd2;
        brightness_pix <= 8'd255; contrast_pix <= 8'd128;
        cfg_v1 <= 19'd0; cfg_v2 <= 19'd0; cfg_v3 <= 19'd0; cfg_tog_pix <= 1'b0;
        volume_pix <= 8'd220; period_ms_pix <= AUTO_PLAY_MS;
    end else begin
        adj_t_s1 <= adj_toggle;
        adj_t_s2 <= adj_t_s1;
        adj_t_d <= adj_t_s2;
        sel_s1 <= sw2;
        sel_s2 <= sel_s1;
        show_s1 <= sw1;
        show_s2 <= show_s1;
        cfg_v1 <= cfg_bus;
        cfg_v2 <= cfg_v1;
        cfg_v3 <= cfg_v2;
        if(adj_step)begin
            if(!sel_s2) bri_level <= bri_level + 1'b1;
            else con_level <= (con_level==3'd5)? 3'b0 : con_level + 3'd1;
        end
        if (cfg_hit) begin                      // 开机读到 CONFIG.TXT：覆盖默认档位（之后按键照常调）
            cfg_tog_pix <= cfg_v3[18];
            if (cfg_v3[16]) con_level <= cfg_v3[9:7];
            if (cfg_v3[15]) bri_level <= cfg_v3[6:5];
            if (cfg_v3[17]) volume_pix <= {cfg_vol_pix, 4'd0} + {1'b0, cfg_vol_pix, 3'd0} + {4'd0, cfg_vol_pix};
            if (cfg_v3[14]) period_ms_pix <= {1'b0, cfg_sec_pix, 10'd0} - {7'd0, cfg_sec_pix, 4'd0} - {8'd0, cfg_sec_pix, 3'd0};   // ×1000
        end
        if(frame_start)begin
            brightness_pix <= bri_lut(bri_level);
            contrast_pix <= con_lut(con_level);
        end
    end
end
endmodule
