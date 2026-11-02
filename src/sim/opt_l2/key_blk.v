// 自动从 top_tf_hdmi_audio.v 抽出的 L2 按键块（gen_key.sh 生成，勿手改）；1 s 改成 LONG 拍，消抖 20 ms 改成 1000 拍
module key_blk #(parameter integer LONG = 5000) (input sd_card_clk, input sdcard_rst_n, input key_list, input sw4,
    input bmp_load_all_done, input [4:0] pcm_count, input [3:0] track_idx, output [3:0] cursor, output goto_req);
  // ===================== L2：歌单选歌（sd_card_clk 域）=====================
  // SW4=1 显示歌单；KEY1 短按（1 s 内松开）光标上移（到顶回绕到最后一首），按住满 1 s 跳到光标那首（不用松手，
  // 一次按压只触发一次）。SW4=0 或还没歌时 KEY1 无效。每次打开歌单，光标先对准正在放的那首。
  (* ASYNC_REG = "TRUE" *) reg sw4_s1, sw4_s2;
  reg        sw4_d;
  wire       pl_show_sd = sw4_s2;
  wire       key_list_out;               // 消抖后电平，按下 = 0
  reg        key_list_d;
  reg [26:0] key_list_cnt;               // 按住计时，1 s = 100M 拍
  reg        key_list_long;              // 本次按压已触发长按
  reg [3:0]  pl_cursor;
  reg        pl_goto_req;
  wire       pl_key_ok = pl_show_sd && bmp_load_all_done && (pcm_count != 5'd0);
  ax_debounce #(
      .FREQ     (1),
      .MAX_TIME (1)
  ) u_key_list_debounce (
      .clk            (sd_card_clk),
      .rst            (~sdcard_rst_n),
      .button_in      (key_list),
      .button_posedge (),
      .button_negedge (),
      .button_out     (key_list_out)
  );
  always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
      if (!sdcard_rst_n) begin
          {sw4_s2, sw4_s1} <= 2'b00; sw4_d <= 1'b0;
          key_list_d <= 1'b1; key_list_cnt <= 27'd0; key_list_long <= 1'b0;
          pl_cursor <= 4'd0; pl_goto_req <= 1'b0;
      end else begin
          {sw4_s2, sw4_s1} <= {sw4_s1, sw4};
          sw4_d       <= sw4_s2;
          key_list_d  <= key_list_out;
          pl_goto_req <= 1'b0;
          if (!key_list_out) begin                                   // 按住
              if (key_list_cnt != LONG - 1)
                  key_list_cnt <= key_list_cnt + 27'd1;
              else if (!key_list_long) begin                          // 满 1 s：跳转
                  key_list_long <= 1'b1;
                  pl_goto_req   <= pl_key_ok;
              end
          end else begin
              if (!key_list_d && !key_list_long && pl_key_ok)        // 1 s 内松开：上移
                  pl_cursor <= (pl_cursor == 4'd0 || {1'b0, pl_cursor} >= pcm_count) ? pcm_count[3:0] - 4'd1 : pl_cursor - 4'd1;
              key_list_cnt  <= 27'd0;
              key_list_long <= 1'b0;
          end
          if (pl_show_sd && !sw4_d)                                  // 打开歌单：光标对准正在放的
              pl_cursor <= track_idx;
      end
  end

  assign cursor = pl_cursor; assign goto_req = pl_goto_req;
endmodule
