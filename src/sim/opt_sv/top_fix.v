

module top(
    input                       clk,
    input                       key_list,       // 板上 KEY1（A2，原复位键）：SW4=1 时短按 = 歌单光标上移，长按 1 s = 跳到光标那首
    input                       sw4,            // 拨码 SW4（C5）：1=显示歌单 0=隐藏
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关
    input                       key3,
    input                       sw3,            // 拨码 SW3：1=缩略图 0=全屏
    input                       sw2,//0=调亮度 1=调对比度
    input                       sw1,//1=调参模式 0=原功能
	output [5:0]                seg_sel,
	output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);
  reg player_enable_sd; wire [23:0] disp_rgb; reg adj_toggle; wire key_adj_gated;
// ===================== 信号声明（必须在使用前声明）=====================
  // 参数
  parameter integer AUTO_PLAY_MS = 1500;
localparam [7:0] AUTO_PLAY_SEC = AUTO_PLAY_MS / 1000;
  // 时钟 / 复位
  wire sd_card_clk, ext_mem_clk, ext_mem_clk_sft, video_clk, hdmi_5x_clk;
  wire sys_pll_lock, video_pll_lock;
  wire sys_rst_n, sdcard_rst_n, mem_rst_n, video_rst_n;
  // L2：KEY1 改作歌单键，不再有手动复位；上电后等两个 PLL 锁定再释放复位
  wire ext_rst_n = sys_pll_lock & video_pll_lock;
  // 同步时钟域
  reg pe_pix_s1, player_enable_pix;
  // SDRAM 控制器
  wire        Sdr_init_done, Sdr_init_ref_vld, Sdr_busy;
  wire        App_wr_en;
  wire [20:0] App_wr_addr;
  wire [31:0] App_wr_din;
  wire [3:0]  App_wr_dm;
  wire        App_rd_en;
  wire [20:0] App_rd_addr;
  wire        Sdr_rd_en;
  wire [31:0] Sdr_rd_dout;

  // 最终视频输出（rgb_video_adapter → 音频桥/HDMI）
  wire        hs, vs, de;
  wire [23:0] vout_data;

  // sd_card_bmp → loader
  wire        bmp_load_start;
  wire [1:0]  bmp_load_index;
  wire [51:0] bmp_res_info;           // 当前显示图片的分辨率（sd_card_clk 域）：{有效, 原宽, 原高, 缩放后宽, 缩放后高}
  wire        bmp_pixel_valid;
  wire [23:0] bmp_pixel_rgb;
  wire        bmp_frame_commit;
  wire [7:0]  bmp_decoder_error;
  wire [5:0]  bmp_card_status;        // 卡状态提示（CS）：{msg, 正在加载的图号}，sd_card_clk 域
  wire        cfg_apply;              // CONFIG.TXT（CF）：读完发一拍，sd_card_clk 域
  wire [5:0]  cfg_mask;               // {VOL, MODE, CON, BRI, AUTO, INT}
  wire [48:0] cfg_val;                // {间隔拍数[31:0], 间隔秒[4:0], 自动, 亮度[1:0], 对比度[2:0], 模式[1:0], 音量[3:0]}
  wire        bmp_load_all_done;
  wire        load_error;

  // loader
  wire        loader_app_wr_en;
  wire [20:0] loader_app_wr_addr;
  wire [3:0]  loader_app_wr_mask;
  wire [31:0] loader_app_wr_data;
  wire        loader_load_busy, loader_load_done;
  wire [3:0]  loader_image_complete;
  wire [7:0]  loader_memory_error;

  // 写 CDC
  wire wr_cdc_full, wr_cdc_overflow, wr_cdc_idle;

  // SDRAM 刷新守护
  wire        sdr_refresh_hold, App_ref_req;
  wire [15:0] sdr_refresh_timeout;     // 调试：正常应恒为0

  // 视频时序
  wire        raw_hs, raw_vs, raw_de;
  wire [11:0] raw_x, raw_y;
  wire        frame_start;

  // reader
  wire [23:0] reader_pixel_rgb;
  wire        reader_pixel_valid;
  wire        reader_underflow, reader_busy, reader_frame_read_done;
  wire [1:0]  reader_index;
  wire [7:0]  reader_error;

  // 播放控制
  wire        ctrl_next_event, ctrl_toggle_auto_event;
  wire        ctrl_auto_enabled, ctrl_request_busy;
  wire [1:0]  ctrl_pending_index;
  wire [7:0]  ctrl_control_error;
  wire [1:0]  active_index;            // video_clk 域

  // 按键
  wire key_next_event, key_auto_event, key_prev_event, key_save_event;
  wire cmd_next, cmd_prev, cmd_auto_toggle, cmd_save;
  
  // 数码管
  wire [4:0] num0, num1, num2, num3, num4, num5;
  wire [6:0] dec0, dec1, dec2, dec3, dec4, dec5;

  // 音频
  reg  [9:0] video_x;
  reg        video_de_d;
  // 音量：默认 220；CONFIG.TXT 的 VOLUME=0~10 换成 0~250（CF）。sd 域给数码管，video 域给音频增益和参数栏
  reg  [7:0] volume_sd, volume_pix;
  reg  [7:0] period_sec_sd;           // 轮播间隔（秒），给数码管；默认 AUTO_PLAY_SEC
  reg [15:0] period_ms_pix;           // 轮播间隔（毫秒），给参数栏；默认 AUTO_PLAY_MS
  // 保存参数（11-01 SV）：KEY4+KEY2 同时按住 1 s，把当前 6 项写回 CONFIG.TXT（sd_card_clk 域）
  wire [18:0] save_val;               // {间隔已设, 间隔秒[4:0], 自动, 亮度[1:0], 对比度[2:0], 模式[1:0], 音量已设, 音量[3:0]}
  wire        save_done;
  wire [1:0]  save_result;            // 0 成功，1 卡上没有 CONFIG.TXT，2 失败
  wire [9:0] core_ch0_symbol, core_ch1_symbol, core_ch2_symbol;
  wire       core_sequence_error;
  wire [9:0] clk_symbol = 10'b1111100000;
  // 字幕
  wire [23:0] osd_rgb_out;
  wire osd_de_out;
  wire osd_active;
  // 时间戳
  wire [23:0] ts_rgb_out;
  wire ts_active;
  // 重建line_y (给OSD用)
  reg [11:0] line_y;
  reg        de_q;
  reg        vs_q;
  // 参数 + 字幕条
  // 声明输出信号
wire [23:0] promax_rgb_out;
wire        promax_active;
  // 波形可视化
wire [23:0] wave_form_rgb_out;
wire waveform_active;
  // 进度条（叠加在柱状图之后）
wire [23:0] progress_rgb_out;
wire [23:0] song_time_rgb_out;  // 播放时间（叠加在进度条之后）
wire [23:0] playlist_rgb_out;   // 歌单面板（叠加在播放时间之后）
wire [23:0] card_rgb_out;       // 卡状态提示（CS，加载完成前叠在最后）
wire [31:0] wav_sample_count;   // video_clk 域：当前歌已播放样本数
// 字幕文本（12 字节，96 位）
// 示例："Hello World!" 的 ASCII 码
wire [95:0] subtitle_text;
wire [5:0]  subtitle_length;
wire        subtitle_push;
// 图片转场控制
wire fade_next_event;// 转场模块输出的切换请求
wire        fade_busy;
wire [7:0]  fade_alpha;
wire        fade_active;
wire        wipe_active;
wire [4:0]  wipe_ramp;
wire [1:0]  transition_kind;
wire        index_commit;      // media_player_control → 转场，video_clk 域单拍
wire        manual_next_event; // 手动"下一张"，先经过转场模块淡出
// 缩略图：2x2 铺满全屏，每张 320x240（2:1 最近邻）。
// reader 和 thumbnail_layout 共用这组参数，改尺寸只改这里。
localparam integer THUMB_W = 320;
localparam integer THUMB_H = 240;
wire        thumb_gap;          // 图与图之间的黑色分隔
wire [1:0]  thumb_source_index;
wire [9:0]  thumb_source_x;     // 仅供 ILA 观察，reader 内部自己生成同样的映射
wire [9:0]  thumb_source_y;
wire        focus_border;
wire        thumb_de;           // 在缩略图内且该图已加载
reg         thumb_mode_s1, thumb_mode_s2;
reg         thumb_mode_pix;     // video_clk 域，frame_start 锁存，整帧不变
// =========== 缩略图控制部分 ===========
wire        tc_view_mode;// sd_card_clk域
wire [1:0]  tc_focus_index;// sd_card_clk 域
wire [1:0]  thumbnail_select_index;
wire        thumbnail_select_event;
wire [1:0]  ctrl_current_index;
wire        focus_left, focus_right, key3_left_event;
//----- 用于缩略图转场 ------
reg jump_pending;         //请求跳图转场
reg [1:0] jump_index_hold;//缩略图编号
wire jump_accept = thumbnail_select_event && player_enable_sd &&
                   !fade_busy && !jump_pending;
wire fade_jump_event = fade_next_event & jump_pending; // 放行跳图
wire fade_step_event = fade_next_event & ~jump_pending;// 放行普通下一张
reg thumb_view_sd;

// 亮度对比度调节
wire [23:0] brightness_rgb;
// ===================== WAV 音频参数 =====================
// ===================== 曲目表（sd_card_clk 域）=====================
  // 曲目来自扫描器的 *.PCM 歌曲表（按目录顺序），曲目数 = pcm_count
  wire [4:0]  pcm_count;
  wire [31:0] pcm_rd_lba;
  wire [23:0] pcm_rd_sectors;
  wire [3:0]  track_idx;
  wire [31:0] track_lba = (pcm_count != 5'd0) ? pcm_rd_lba : 32'd0;  // 0 = 无歌，播放器保持空闲
  wire [31:0] track_sec = {8'd0, pcm_rd_sectors};
  wire        track_restart, track_song_event, track_mode_event;
  wire [1:0]  track_mode;
  wire [3:0]  pl_rd_idx;               // 歌单表读下标（见下方"歌单数据"）
  wire [87:0] pl_rd_data;              // {文件名前 8 字节, 扇区数}
  wire [7:0]  track_gain_gray;
  wire        key_song_event;     // 下一张键长按 1 s：下一首
  wire        key3_press;         // KEY3 按下（消抖后单拍）
  wire        key_mode_event;     // SW1=0 且全屏时 KEY3：切播放模式
  wire        wav_stream_end;

  // 播完标志：video_clk 域先寄存（源是组合逻辑），再 2FF 到 sd_card_clk 域
  reg wav_end_v;
  always @(posedge video_clk or negedge video_rst_n)
      if (!video_rst_n) wav_end_v <= 1'b0;
      else              wav_end_v <= wav_stream_end;
  (* ASYNC_REG = "TRUE" *) reg wav_end_s1, wav_end_s2;
  always @(posedge sd_card_clk or negedge sdcard_rst_n)
      if (!sdcard_rst_n) {wav_end_s2, wav_end_s1} <= 2'b00;
      else               {wav_end_s2, wav_end_s1} <= {wav_end_s1, wav_end_v};

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
      .FREQ     (100),
      .MAX_TIME (20)
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
              if (key_list_cnt != 27'd99_999_999)
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

  // 播放列表与图片轮播独立：下一张键长按 = 下一首，放完自动下一首，KEY3 切模式
  track_playlist #(
      .FADE_STEP_CYCLES (117_647)        // 0.3 s 淡出 / 0.3 s 淡入
  ) u_track_playlist (
      .clk             (sd_card_clk),
      .rst_n           (sdcard_rst_n),
      .play_enable     (bmp_load_all_done),
      .pcm_count       (pcm_count),
      .next_req        (key_song_event),
      .goto_req        (pl_goto_req),
      .goto_idx        (pl_cursor),
      .mode_req        (key_mode_event),
      .mode_set        (cfg_apply && cfg_mask[4]),   // CONFIG.TXT：MODE
      .mode_set_val    (cfg_val[5:4]),
      .stream_end      (wav_end_s2),
      .track_idx       (track_idx),
      .restart         (track_restart),
      .play_mode       (track_mode),
      .song_event      (track_song_event),
      .mode_event      (track_mode_event),
      .track_gain_gray (track_gain_gray)
  );

  // 音频扇区口（sd_card_clk 域，接 sd_card_bmp 新增的仲裁端口）
  wire        aud_sector_req, aud_sector_busy, aud_sector_valid,
  aud_sector_done;
  wire [31:0] aud_sector_lba;
  wire [7:0]  aud_sector_byte, aud_sector_error;
  wire [8:0]  aud_sector_byte_index;
  // PCM（video_clk 域，接音频桥）
  wire signed [15:0] wav_sample;
  wire        wav_valid, wav_ready, wav_active;

  // 48kHz 采样节拍（video_clk = 25MHz，和 pcm_media_tone 同样的累加器写法）
  reg  [24:0] wav_rate_acc;
  wire        wav_tick = (wav_rate_acc >= 25_000_000 - 48_000);
  

assign subtitle_length = 6'd8;  
 // =====================像素域Alpha乘法代码=====================
 //---- Alpha淡入淡出乘法 ----
// 用/256（右移8位）代替/255，省除法器
// 组合实现，和 raw_x/raw_de 同拍，后级 OSD 不会错位。
wire [23:0] reader_rgb = disp_rgb;       // reader输出的原始像素
wire [15:0] fade_r = reader_rgb[23:16] * fade_alpha;
wire [15:0] fade_g = reader_rgb[15:8]  * fade_alpha;
wire [15:0] fade_b = reader_rgb[7:0]   * fade_alpha;
wire [23:0] faded_rgb = {fade_r[15:8], fade_g[15:8], fade_b[15:8]};

//---- Wipe ----
// 左新右旧已经在 reader 按列选 bank 时拼好，这里直接用 reader 输出。
// 只在淡入淡出期间走乘法，平时 alpha=255 也不会让画面暗 1/256。
wire [23:0] transition_rgb = (fade_active && !wipe_active) ? faded_rgb : reader_rgb;

  assign HDMI_DDC_SCL = 1'b1;
  assign HDMI_DDC_SDA = 1'bz;
 // ===================== 复位：每个时钟域一个同步器 =====================
reset_sync u_sdcard_reset(
    .clk        	(sd_card_clk         ),
    .ext_rst_n  	(ext_rst_n   ),
    .rst_n_sync 	(sdcard_rst_n  )
);
reset_sync u_mem_reset(
    .clk        	(ext_mem_clk         ),
    .ext_rst_n  	(ext_rst_n   ),
    .rst_n_sync 	(mem_rst_n  )
);
reset_sync u_video_reset(
    .clk        	(video_clk         ),
    .ext_rst_n  	(ext_rst_n   ),
    .rst_n_sync 	(video_rst_n  )
);
reset_sync u_sys_reset(
    .clk        	(clk         ),
    .ext_rst_n  	(ext_rst_n   ),
    .rst_n_sync 	(sys_rst_n  )
);

// ===================== PLL =====================
sys_pll sys_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (sys_pll_lock),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk)
);

// ===================== 原图像时序与帧缓存 =====================
//把 Sdr_init_done 同步到 sd 域：
 reg sdr_init_sd_s1, sdr_init_sd;
  always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
      if (!sdcard_rst_n) begin
          sdr_init_sd_s1 <= 1'b0;
          sdr_init_sd    <= 1'b0;
      end else begin
          sdr_init_sd_s1 <= Sdr_init_done;
          sdr_init_sd    <= sdr_init_sd_s1;
      end
  end
// active_index → sd 域（2bit 慢变量，用于数码管显示和查分辨率表；要在 sd_card_bmp 例化之前声明）
  reg [1:0] active_index_sd_s1, active_index_sd;
  always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
      if (!sdcard_rst_n) begin
          active_index_sd_s1 <= 2'd0; active_index_sd <= 2'd0;
      end else begin
          active_index_sd_s1 <= active_index; active_index_sd <=
  active_index_sd_s1;
      end
  end
// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .AUTO_PLAY_MS      (AUTO_PLAY_MS),
    .SCALE_ENABLE      (1),            // 扩展 3：接受任意尺寸的 24 位 BMP
    .SCALE_MAX_W       (4096),         // 源图最大宽度（行缓冲深度）
    .SCALE_FIT         (1),            // 整图可见：等比缩小到放得下、四周补黑；小图不放大、居中
    .SCALE_RATE        (64)            // 黑边像素写 SDRAM 的间隔（拍），原图像素本来就约 96 拍一个
) sd_card_bmp_m0(
     .clk             (sd_card_clk),
      .rst             (~sdcard_rst_n),
      .state_code      (),
      .card_status     (bmp_card_status),
      .Sdr_init_done   (sdr_init_sd),
      .load_start      (bmp_load_start),
      .load_image_index(bmp_load_index),
      .load_busy       (loader_load_busy),
      .load_done       (loader_load_done),
      .image_complete  (loader_image_complete),
      .pixel_valid     (bmp_pixel_valid),
      .pixel_rgb       (bmp_pixel_rgb),
      .frame_commit    (bmp_frame_commit),
      .SD_nCS          (sd_ncs),
      .SD_DCLK         (sd_dclk),
      .SD_MOSI         (sd_mosi),
      .SD_MISO         (sd_miso),
      .decoder_error   (bmp_decoder_error),
      .load_error      (load_error),
      .load_all_done   (bmp_load_all_done),
      .info_rd_idx     (active_index_sd),
      .info_rd_data    (bmp_res_info),
    .aud_sector_req(aud_sector_req),
    .aud_sector_lba(aud_sector_lba),
    .aud_sector_busy(aud_sector_busy),
    .aud_sector_valid(aud_sector_valid),
    .aud_sector_done(aud_sector_done),
    .aud_sector_byte(aud_sector_byte),
    .aud_sector_error(aud_sector_error),
    .aud_sector_byte_index(aud_sector_byte_index),
    .pcm_count(pcm_count),
    .pcm_rd_idx(track_idx),
    .pcm_rd_lba(pcm_rd_lba),
    .pcm_rd_sectors(pcm_rd_sectors),
    .pl_rd_idx(pl_rd_idx),
    .pl_rd_data(pl_rd_data),
    .cfg_apply(cfg_apply),
    .cfg_mask(cfg_mask),
    .cfg_val(cfg_val),
    .save_req(cmd_save),
    .save_val(save_val),
    .save_busy(),
    .save_done(save_done),
    .save_result(save_result)
);

// ===================== CONFIG.TXT 配置（CF）=====================
// sd_card_clk 域：数码管用的音量、间隔直接更新；送 video 域的部分打包成 cfg_bus（apply 时翻转 cfg_tog，
// 其余位此后保持不变），video 域 3 级同步、连续两拍相同且翻转位变了才采用（同 pl_bus 的做法）。
wire [7:0] cfg_vol_x25 = {cfg_val[3:0], 4'd0} + {1'b0, cfg_val[3:0], 3'd0} + {4'd0, cfg_val[3:0]};   // 0~10 → 0~250
reg        cfg_tog;
reg [18:0] cfg_bus;                  // {翻转, VOL/CON/BRI/INT 有效[3:0], 音量档[3:0], 对比度[2:0], 亮度[1:0], 间隔秒[4:0]}
reg  [3:0] vol_lvl_sd;               // 保存参数用（SV）：音量档；间隔、音量是否在 CONFIG.TXT 里设过（没设过的保存成注释行）
reg        vol_set_sd, int_set_sd;
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        volume_sd     <= 8'd220;
        period_sec_sd <= AUTO_PLAY_SEC;
        cfg_tog       <= 1'b0;
        cfg_bus       <= 19'd0;
        vol_lvl_sd    <= 4'd9;
        vol_set_sd    <= 1'b0;
        int_set_sd    <= 1'b0;
    end else if (cfg_apply) begin
        if (cfg_mask[5]) begin volume_sd <= cfg_vol_x25; vol_lvl_sd <= cfg_val[3:0]; vol_set_sd <= 1'b1; end
        if (cfg_mask[0]) begin period_sec_sd <= {3'd0, cfg_val[16:12]}; int_set_sd <= 1'b1; end
        cfg_tog <= ~cfg_tog;
        cfg_bus <= {~cfg_tog, cfg_mask[5], cfg_mask[3], cfg_mask[2], cfg_mask[0],
                    cfg_val[3:0], cfg_val[8:6], cfg_val[10:9], cfg_val[16:12]};
    end
end

// ===================== 歌单数据（sd_card_clk 域）=====================
// 下标 0~15 轮流读歌单表，每个下标保持 256 拍（2.56us），在窗口最后一拍连同选歌光标、歌曲数、当前曲目、
// 播放模式一起锁存到 pl_bus。video_clk 域在 playlist_panel 里同步，连续两拍相同才采用。
reg [11:0]  pl_seq;
assign pl_rd_idx = pl_seq[11:8];
reg [106:0] pl_bus;
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        pl_seq <= 12'd0;
        pl_bus <= 107'd0;
    end else begin
        pl_seq <= pl_seq + 12'd1;
        if (pl_seq[7:0] == 8'hff)          // 下标已稳定 255 拍，读出数据早已到位
            pl_bus <= {pl_cursor, pcm_count, track_idx, track_mode, pl_seq[11:8], pl_rd_data};
    end
end
// ===================== 数码管（sd_card_clk 域）=====================


seg_page #(
    .PAGE_PERIOD_CYCLES (100_000_000),
    .HOLD_CYCLES        (200_000_000)
)
 u_seg_page(
    .clk         (sd_card_clk),
    .rst_n       (sdcard_rst_n),
    .img_idx     (active_index_sd),
    .volume      (volume_sd),
    .period_sec  (period_sec_sd),
    .event_pic   (ctrl_next_event),   // 切图事件
    .event_vol   (1'b0),   // 调音量事件
    .bmp_error   (bmp_decoder_error[2:0]),
    .seg_data_0  (num0),
    .seg_data_1  (num1),
    .seg_data_2  (num2),
    .seg_data_3  (num3),
    .seg_data_4  (num4),
    .seg_data_5  (num5)
);
seg_decoder u_dec0 (.bin_data(num0[4:0]), .seg_data(dec0[6:0]));
seg_decoder u_dec1 (.bin_data(num1[4:0]), .seg_data(dec1[6:0]));
seg_decoder u_dec2 (.bin_data(num2[4:0]), .seg_data(dec2[6:0]));
seg_decoder u_dec3 (.bin_data(num3[4:0]), .seg_data(dec3[6:0]));
seg_decoder u_dec4 (.bin_data(num4[4:0]), .seg_data(dec4[6:0]));
seg_decoder u_dec5 (.bin_data(num5[4:0]), .seg_data(dec5[6:0]));
// seg_scan seg_scan_m0(
//     .clk               (clk),
//     .rst_n             (rst_n),
//     .seg_sel           (seg_sel),
//     .seg_data          (seg_data),
//     .seg_data_0        ({1'b1,7'b1111_111}),
//     .seg_data_1        ({1'b1,7'b1111_111}),
//     .seg_data_2        ({1'b1,7'b1111_111}),
//     .seg_data_3        ({1'b1,7'b1111_111}),
//     .seg_data_4        ({1'b1,7'b1111_111}),
//     .seg_data_5        ({1'b1,seg_data_0})
// );
seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (sys_rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0 ({1'b1, dec0}),
    .seg_data_1 ({1'b1, dec1}),
    .seg_data_2 ({1'b1, dec2}),
    .seg_data_3 ({1'b1, dec3}),
    .seg_data_4 ({1'b1, dec4}),
    .seg_data_5 ({1'b1, dec5})
);

// ===================== 4bank帧缓存 =====================

 // ===================== 输出适配（video_clk 域）=====================
// 缩略图模式：区域内照样 pop（保证与 reader 计数一致），未加载的图显示黑色，
// 当前图叠 2 像素黄色焦点框。
wire [23:0] full_rgb = (player_enable_pix && reader_pixel_valid) ?
                       reader_pixel_rgb : 24'h000000;
assign disp_rgb = !thumb_mode_pix ? full_rgb :
                       !thumb_de       ? 24'h000000 :
                       thumb_gap       ? 24'h000000 :
                       focus_border    ? 24'hffff00 : full_rgb;

rgb_video_adapter u_rgb_video_adapter (
    .pclk     (video_clk),
    .rst_n    (video_rst_n),
    .hs_in    (raw_hs),
    .vs_in    (raw_vs),
    .de_in    (raw_de),          // ← de 只看时序，不和 pixel_valid 相与
    .rgb_in   (card_rgb_out),             // ← 没数据就送黑
    .video_clk(),                // ← 悬空！不要接 video_clk，否则多驱动
    .video_hs (hs),
    .video_vs (vs),
    .video_de (de),
    .video_rgb(vout_data)
);


media_frame_loader #(
    .ADDR_WIDTH    	(21      ),
    .IMAGE_WORDS   	(307200  ),
    .FIFO_DEPTH    	(512     ),
    .BURST_SIZE    	(128     ),
    .STALL_TIMEOUT 	(65535   ))
u_media_frame_loader(
    .clk                  	(sd_card_clk                   ),
    .rst_n                	(sdcard_rst_n                 ),
    .load_start           	(bmp_load_start            ),
    .image_index          	(bmp_load_index           ),
    .pixel_valid          	(bmp_pixel_valid           ),
    .pixel_rgb            	(bmp_pixel_rgb             ),
    .frame_commit         	(bmp_frame_commit          ),
    .decode_error         	(bmp_decoder_error          ),
    .load_busy            	(loader_load_busy             ),
    .load_done            	(loader_load_done             ),
    .image_complete       	(loader_image_complete        ),
    .memory_error         	(loader_memory_error          ),
    .controller_init_done 	(sdr_init_sd  ),
    .controller_busy      	(1'b0       ),
    .refresh_active       	(1'b0        ),
    .app_wr_en            	(loader_app_wr_en             ),
    .app_wr_addr          	(loader_app_wr_addr           ),
    .app_wr_mask          	(loader_app_wr_mask           ),
    .app_wr_data          	(loader_app_wr_data           )
);

  // ===================== 写 CDC：sd_card_clk → ext_mem_clk=====================
media_sdram_write_cdc #(
      .ADDR_WIDTH(21), .FIFO_ADDR_WIDTH(9), .BURST_SIZE(128)
  ) u_wr_cdc (
      .src_clk        (sd_card_clk),
      .src_rst_n      (sdcard_rst_n),
      .src_wr_en      (loader_app_wr_en),
      .src_wr_addr    (loader_app_wr_addr),
      .src_wr_mask    (loader_app_wr_mask),
      .src_wr_data    (loader_app_wr_data),
      .src_full       (wr_cdc_full),
      .src_overflow   (wr_cdc_overflow),    // 调试用：正常应恒为0
      .dst_clk        (ext_mem_clk),
      .dst_rst_n      (mem_rst_n),
      .dst_hold       (sdr_refresh_hold),
      .dst_app_wr_en  (App_wr_en),
      .dst_app_wr_addr(App_wr_addr),
      .dst_app_wr_mask(App_wr_dm),
      .dst_app_wr_data(App_wr_din),
      .dst_idle       (wr_cdc_idle)         // 问题6要用
  );
 // ===================== 启动门控 + 首图跳转（sd_card_clk
  //域）=====================
  reg first_kick_done, first_kick_pulse;
  always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
      if (!sdcard_rst_n) begin
          first_kick_done  <= 1'b0;
          first_kick_pulse <= 1'b0;
          player_enable_sd <= 1'b0;
      end else begin
          first_kick_pulse <= 1'b0;
          if (!first_kick_done && bmp_load_all_done &&
  (loader_image_complete != 4'd0)) begin
              first_kick_done <= 1'b1;
              if (!loader_image_complete[0])
                  first_kick_pulse <= 1'b1;      // bank0
  //无效：先跳到第一张有效图
          end
          if (first_kick_done && !first_kick_pulse && !ctrl_request_busy)
              player_enable_sd <= 1'b1;
      end
  end

  assign ctrl_next_event        = (cmd_next & player_enable_sd) |
  first_kick_pulse;
  assign manual_next_event      = (cmd_next & player_enable_sd) | jump_accept;
  assign ctrl_toggle_auto_event =  cmd_auto_toggle & player_enable_sd;
  assign ctrl_prev_event        = cmd_prev & player_enable_sd;
  // player_enable → mem 域
  reg pe_mem_s1, player_enable_mem;
  always @(posedge ext_mem_clk or negedge mem_rst_n) begin
      if (!mem_rst_n) begin
          pe_mem_s1 <= 1'b0; player_enable_mem <= 1'b0;
      end else begin
          pe_mem_s1 <= player_enable_sd; player_enable_mem <= pe_mem_s1;
      end
  end
  // player_enable → video 域
  
  always @(posedge video_clk or negedge video_rst_n) begin
      if (!video_rst_n) begin
          pe_pix_s1 <= 1'b0; player_enable_pix <= 1'b0;
      end else begin
          pe_pix_s1 <= player_enable_sd; player_enable_pix <= pe_pix_s1;
      end
  end
 // =====================帧读取器（mem=ext_mem_clk，pix=video_clk）=====================

//---- Wipe 参数（video_clk 域）----
// 边界每帧右移 40 像素（640/FADE_FRAMES），ramp 只在 frame_start 更新，整帧统一。
wire [9:0] wipe_boundary = wipe_ramp * (640 / 16);

// index_commit 这一拍 active_index 已经是新图，旧图要从上一拍的值里取。
reg [1:0] active_index_q;
reg [1:0] old_index;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        active_index_q <= 2'd0;
        old_index      <= 2'd0;
    end else begin
        active_index_q <= active_index;
        if (index_commit)
            old_index <= active_index_q;
    end
end

//---- 缩略图/全屏切换：拨码 SW3 ----
// 拨码是电平，直接两级同步到 video_clk；拨动抖动只会让某一帧早/晚切换，
// 因为只在 frame_start 锁存，帧内不会变，reader 和消费侧仍整帧一致。
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        thumb_mode_s1  <= 1'b0;
        thumb_mode_s2  <= 1'b0;
        thumb_mode_pix <= 1'b0;
    end else begin
        thumb_mode_s1 <= thumb_view_sd;
        thumb_mode_s2 <= thumb_mode_s1;
        if (frame_start)
            thumb_mode_pix <= thumb_mode_s2;
    end
end
// 缩略图模式下 pop 的范围必须和 reader 读的 4*THUMB_W*THUMB_H 个字严格一致，
// 所以这里不看 image_complete / thumb_gap（这些像素照常 pop，只在 disp_rgb 里涂黑）。
// tc_focus_index ( sd_card_clk 域 -> video_clk 域 )
wire thumb_region = raw_de && (raw_x < 2*THUMB_W) && (raw_y < 2*THUMB_H);
wire reader_consume = thumb_mode_pix ? thumb_region : raw_de;
 reg [1:0] focus_s1, focus_s2, focus_pix;
  always @(posedge video_clk or negedge video_rst_n) begin
      if (!video_rst_n) begin
          focus_s1 <= 2'd0; focus_s2 <= 2'd0; focus_pix <= 2'd0;
      end else begin
          focus_s1 <= tc_focus_index;
          focus_s2 <= focus_s1;
          if (frame_start) focus_pix <= focus_s2;
      end
  end
  // loader_image_complete（sd_card_clk 域）→ video_clk 域：每位都是慢变电平且彼此独立，
  // 逐位 2FF 后在 frame_start 锁存，缩略图布局整帧不变（原来直接进组合逻辑，跨域违例约 −14ns）
  (* ASYNC_REG = "TRUE" *) reg [3:0] img_done_s1, img_done_s2;
  reg [3:0] img_done_pix;
  always @(posedge video_clk or negedge video_rst_n) begin
      if (!video_rst_n) begin
          img_done_s1 <= 4'd0; img_done_s2 <= 4'd0; img_done_pix <= 4'd0;
      end else begin
          img_done_s1 <= loader_image_complete;
          img_done_s2 <= img_done_s1;
          if (frame_start) img_done_pix <= img_done_s2;
      end
  end
  // 当前图片分辨率（sd_card_clk 域查表，切图时才变）→ video_clk 域给参数栏。
  // 多位一起过 2FF 可能采到新旧混合值，所以只在连续两拍相同时才更新。
  (* ASYNC_REG = "TRUE" *) reg [51:0] res_s1, res_s2;
  reg [51:0] res_s3, res_pix;
  always @(posedge video_clk or negedge video_rst_n) begin
      if (!video_rst_n) begin
          res_s1 <= 52'd0; res_s2 <= 52'd0; res_s3 <= 52'd0; res_pix <= 52'd0;
      end else begin
          res_s1 <= bmp_res_info;
          res_s2 <= res_s1;
          res_s3 <= res_s2;
          if (res_s2 == res_s3) res_pix <= res_s3;
      end
  end

media_frame_reader #(
    .ADDR_WIDTH          	(21      ),
    .IMAGE_WORDS         	(307200  ),
    .FIFO_DEPTH          	(512     ),
    .FIFO_MARGIN         	(8       ),
    .BURST_SIZE          	(128     ),
    .BURST_GAP_CYCLES    	(12      ),
    .MAX_INFLIGHT_BURSTS 	(2       ),
    .DIAG_RETURN_PATTERN 	(0       ),
    .DIAG_SYNTH_STREAM   	(0       ),
    .THUMB_WIDTH         	(THUMB_W ),
    .THUMB_HEIGHT        	(THUMB_H ))
u_media_frame_reader(
    .mem_clk              	(ext_mem_clk               ),
    .mem_rst_n            	(mem_rst_n             ),
    .controller_init_done 	(Sdr_init_done && player_enable_mem && wr_cdc_idle  ),
    .controller_busy      	(Sdr_busy       ),
    .refresh_active       	(sdr_refresh_hold        ),
    .app_rd_en            	(App_rd_en             ),
    .app_rd_addr          	(App_rd_addr           ),
    .sdram_rd_valid       	(Sdr_rd_en        ),
    .sdram_rd_data        	(Sdr_rd_dout         ),
    .pix_clk              	(video_clk               ),
    .pix_rst_n            	(video_rst_n             ),
    .frame_start          	(frame_start && player_enable_pix           ),
    .active_index         	(active_index          ),
    .wipe_active          	(wipe_active           ),
    .wipe_boundary        	(wipe_boundary         ),
    .old_index            	(old_index             ),
    .thumb_mode           	(thumb_mode_pix        ),
    .pixel_consume        	(reader_consume && player_enable_pix   ),
    .pixel_rgb            	(reader_pixel_rgb             ),
    .pixel_valid          	(reader_pixel_valid           ),
    .underflow            	(reader_underflow             ),
    .reader_busy          	(reader_busy           ),
    .frame_read_done      	(reader_frame_read_done       ),
    .reader_index         	(reader_index          ),
    .reader_error         	(reader_error          )
);
// ===================== 亮度/对比度档位（video_clk 域）=====================
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
// 保存参数（SV）：亮度、对比度档在 video 域（按键/CONFIG.TXT 改），带回 sd 域。3 级同步、连续两拍相同才采用
// （档位只在按键时变，按下保存要先按住 1 s，早已稳定）
(* ASYNC_REG = "TRUE" *) reg [4:0] sv_bc_s1, sv_bc_s2;
reg [4:0] sv_bc_s3, sv_bc_sd;
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        sv_bc_s1 <= 5'b11_010; sv_bc_s2 <= 5'b11_010; sv_bc_s3 <= 5'b11_010; sv_bc_sd <= 5'b11_010;
    end else begin
        sv_bc_s1 <= {bri_level, con_level};
        sv_bc_s2 <= sv_bc_s1;
        sv_bc_s3 <= sv_bc_s2;
        if (sv_bc_s2 == sv_bc_s3) sv_bc_sd <= sv_bc_s3;
    end
end
assign save_val = {int_set_sd, period_sec_sd[4:0], ctrl_auto_enabled, sv_bc_sd, track_mode, vol_set_sd, vol_lvl_sd};
// ===================== 亮度对比度调节 =====================
brightness_contrast_adjust u_brightness_contrast_adjust (
    .clk(video_clk),
    .rst_n(video_rst_n),
    .in_de(raw_de),
    .rgb_in(transition_rgb),
    .brightness(brightness_pix),
    .contrast(contrast_pix),
    .out_de( ),
    .rgb_out(brightness_rgb)
    
);
 // =====================播放控制（sys=sd_card_clk，pix=video_clk）=====================

media_player_control #(
    .DEFAULT_PERIOD_CYCLES 	(AUTO_PLAY_MS * 100_000   ),
    .MIN_PERIOD_CYCLES     	(50000000    ),
    .MAX_PERIOD_CYCLES     	(32'd3_000_000_000  ))
u_media_player_control(
    .sys_clk              	(sd_card_clk               ),
    .sys_rst_n            	(sdcard_rst_n             ),
    .next_event           	(fade_step_event | first_kick_pulse),
    .prev_event         (ctrl_prev_event),
    .jump_event             (fade_jump_event),// thumbnail_controller 输出
    .jump_index             (jump_index_hold),// thumbnail_controller 输出
    .toggle_auto_event    	(ctrl_toggle_auto_event     ),
    .media_view_mode              (tc_view_mode),
    .period_cfg_valid     	(cfg_apply && cfg_mask[0]),   // CONFIG.TXT：INTERVAL
    .period_cfg_cycles    	(cfg_val[48:17]  ),
    .auto_cfg_valid       	(cfg_apply && cfg_mask[1]),   // CONFIG.TXT：AUTO
    .auto_cfg_enabled     	(cfg_val[11]     ),
    .image_complete       	(loader_image_complete        ),
    .auto_enabled         	(ctrl_auto_enabled          ),
    .active_period_cycles 	(  ),
    .pending_index        	(ctrl_pending_index         ),
    .control_error        	(ctrl_control_error         ),
    .request_busy         	(ctrl_request_busy          ),
    .pix_clk              	(video_clk               ),
    .pix_rst_n            	(video_rst_n             ),
    .frame_start          	(frame_start           ),
    .active_index         	(active_index          ),
    .current_index          (ctrl_current_index),
    .index_commit         	(index_commit     )
);
// ===================== 图片转场特效=====================
// output declaration of module video_fade_transition


video_fade_transition #(
    .FADE_FRAMES 	(16  ))
u_video_fade_transition(
    //控制域（100MHz）
    .ctrl_clk        	(sd_card_clk         ),
    .ctrl_rst_n      	(sdcard_rst_n       ),
    .next_event_in   	(manual_next_event  ),
    .next_event_out  	(fade_next_event   ),
    .fade_busy       	(fade_busy        ),
    //像素域 (25MHz)
    .pix_clk         	(video_clk          ),
    .pix_rst_n       	(video_rst_n        ),
    .player_active   	(player_enable_pix    ),
    .frame_start     	(frame_start      ),
    .index_commit    	(index_commit     ),
    .active_index    	(active_index     ),
    .alpha_out       	(fade_alpha        ),
    .fade_active     	(fade_active      ),
    .wipe_active     	(wipe_active      ),
    .ramp_out        	(wipe_ramp         ),
    .transition_kind 	(transition_kind  )
);
// ----- 缩略图转场 -----
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
      if (!sdcard_rst_n) begin
          jump_pending    <= 1'b0;
          jump_index_hold <= 2'd0;
      end else if (jump_accept) begin
          jump_pending    <= 1'b1;
          jump_index_hold <= thumbnail_select_index;
      end else if (fade_next_event && jump_pending) begin
          jump_pending    <= 1'b0;          // 全黑帧，放行给播放器
      end
  end
always @(posedge sd_card_clk or negedge sdcard_rst_n)
      if (!sdcard_rst_n) thumb_view_sd <= 1'b0;
      else               thumb_view_sd <= tc_view_mode | jump_accept | jump_pending;

// ===================== 重建 line_y（给 OSD 用）=====================


always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        line_y <= 12'd0;
        de_q   <= 1'b0;
        vs_q   <= 1'b1;
    end else begin
        de_q <= raw_de;
        vs_q <= raw_vs;
        if (!raw_vs)
            line_y <= 12'd0;              // vsync 低电平：清零
        else if (de_q && !raw_de)
            line_y <= line_y + 1'b1;      // de 下降沿：行号 +1
    end
end
// ===================== OSD字幕叠加 =====================
// output declaration of module osd_overlay_24


osd_overlay_24 #(
    .OSD_X 	(8  ),
    .OSD_Y 	(8  ))
u_osd_overlay_24(
    .clk          	(video_clk           ),
    .rst_n        	(video_rst_n         ),
    .vsync        	(raw_vs         ),
    .de           	(raw_de            ),
    .rgb_in       	(brightness_rgb  ),
    .pixel_x      	(raw_x       ),
    .active_index 	(active_index  ),
    .auto_enabled 	(ctrl_auto_enabled  ),
    .error_code   	(1'b0    ),
    .rgb_out      	(osd_rgb_out       ),
    .de_out       	(osd_de_out        ),
    .osd_active   	(osd_active    )
);
// ===================== OSD时间戳 =====================
// output declaration of module timestamp_osd


timestamp_osd #(
    .OSD_X  	(500  ),
    .OSD_Y  	(8    ),
    .CHAR_W 	(8    ),
    .CHAR_H 	(16   ))
u_timestamp_osd(
    .pix_clk   	(video_clk    ),
    .pix_rst_n 	(video_rst_n  ),
    .enable    	(player_enable_pix     ),
    .vsync     	(raw_vs      ),
    .de        	(raw_de         ),
    .pixel_x   	(raw_x    ),
    .pixel_y   	(line_y    ),
    .rgb_in    	(osd_rgb_out     ),
    .rgb_out   	(ts_rgb_out    ),
    .ts_active 	(ts_active  ),
    .sys_rst_n 	(sdcard_rst_n  )
);
// ===================== 参数条 + 滚动字幕 =====================

promax_text_overlay #(
    .PARAM_X    (8),      // 参数条 X=8
    .PARAM_Y    (40),     // 参数条 Y=40
    .BAR_Y      (60),
    .SUBTITLE_Y (400),     // 字幕 Y=300
    .H_ACTIVE   (640)     // 水平 640
) u_promax_text_overlay (
    .clk                (video_clk),           // 像素时钟
    .rst_n              (video_rst_n),
    .vsync              (raw_vs),              // 场同步
    .de                 (raw_de),              // 数据有效
    .rgb_in             (ts_rgb_out),          // ← 接时间戳的输出（叠加）
    .pixel_x            (raw_x[9:0]),          // X 坐标（10 位）
    .enable             (player_enable_pix),   // 参数条使能
    .subtitle_enable    (player_enable_pix),   // 字幕使能
    .subtitle_push      (subtitle_push),
    .subtitle_text      (subtitle_text),       // 字幕文本
    .subtitle_length    (subtitle_length),     // 字幕长度
    .brightness         (brightness_pix),              // 亮度（100%）
    .contrast           (contrast_pix),
    .bar_show           (show_s2),
    .bar_sel            (sel_s2),
    .volume             (volume_pix),          // 音量（CONFIG.TXT 可改）
    .period_ms          ({16'd0, period_ms_pix}),   // 轮播间隔（原来写死 5000，和实际的 AUTO_PLAY_MS 不一致）
    .auto_enabled       (ctrl_auto_enabled),   // 自动/手动
    .source_scale_2x    (1'b0),                // 已不用
    .res_valid          (res_pix[51]),         // 当前图片：原图分辨率 → 缩放后图片区
    .res_src_w          (res_pix[50:35]),
    .res_src_h          (res_pix[34:19]),
    .res_out_w          (res_pix[18:9]),
    .res_out_h          (res_pix[8:0]),
    .rgb_out            (promax_rgb_out),      // → 输出
    .overlay_active     (promax_active)
);
// ===================== OSD日志 =====================
// sd_card_clk 域：每次按键翻转一次。
// 歌曲序号 1~16 的两位 ASCII
wire [7:0] song_no_hi = (track_idx >= 4'd9) ? "1" : "0";
wire [7:0] song_no_lo = (track_idx >= 4'd9) ? ("0" + track_idx - 4'd9) : ("1" + track_idx);
reg log_toggle;
reg [95:0] log_buffer;
reg log_toggle_d;
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if (!sdcard_rst_n) begin
        log_toggle <= 1'b0;
        log_buffer <= 96'd0;
        end
    else if (cmd_next) begin
        log_toggle <= ~log_toggle;
        log_buffer <= {64'd0, "T", "X", "E", "N"};
        end
    else if(cmd_prev) begin
        log_toggle <= ~log_toggle;
        log_buffer <= {64'd0, "V", "E", "R", "P"};
    end
    else if(key_adj_gated) begin
        log_toggle <= ~log_toggle;
        if(!ctrl_auto_enabled) begin
            log_buffer <= {40'd0,"N","O",":", "O", "T", "U", "A"};
        end else begin
            log_buffer <= {32'd0,"F","F","O",":", "O", "T", "U", "A"};
        end
        
    end
    else if (track_song_event) begin                 // "SONG:NN"
        log_toggle <= ~log_toggle;
        log_buffer <= {40'd0, song_no_lo, song_no_hi, ":", "G", "N", "O", "S"};
    end
    else if (save_done) begin                        // "SAVE:OK" / "SAVE:NOFILE" / "SAVE:FAIL"（11-01 SV）
        log_toggle <= ~log_toggle;
        case (save_result)
            2'd0:    log_buffer <= {40'd0, "K", "O", ":", "E", "V", "A", "S"};
            2'd1:    log_buffer <= {8'd0, "E", "L", "I", "F", "O", "N", ":", "E", "V", "A", "S"};
            default: log_buffer <= {24'd0, "L", "I", "A", "F", ":", "E", "V", "A", "S"};
        endcase
    end
    else if (track_mode_event) begin                 // "MODE:SEQ/ONE/RND"
        log_toggle <= ~log_toggle;
        case (track_mode)
            2'd0:    log_buffer <= {32'd0, "Q", "E", "S", ":", "E", "D", "O", "M"};
            2'd1:    log_buffer <= {32'd0, "E", "N", "O", ":", "E", "D", "O", "M"};
            default: log_buffer <= {32'd0, "D", "N", "R", ":", "E", "D", "O", "M"};
        endcase
    end
end

// video_clk 域：只同步 1 位翻转信号；检测到翻转时 log_buffer
// 已在源时钟域稳定至少两拍，此时直接锁存整条 96 位总线（不逐位同步）。
// 按键间隔远大于几个 video_clk 周期，锁存期间 log_buffer 不会再变。
(* ASYNC_REG = "TRUE" *) reg log_toggle_s1;
(* ASYNC_REG = "TRUE" *) reg log_toggle_s2;
reg [95:0] log_text_latched;
reg        log_push_r;
wire       log_event = log_toggle_s2 ^ log_toggle_d;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        log_toggle_s1    <= 1'b0;
        log_toggle_s2    <= 1'b0;
        log_toggle_d     <= 1'b0;
        log_text_latched <= 96'd0;
        log_push_r       <= 1'b0;
    end else begin
        log_toggle_s1 <= log_toggle;
        log_toggle_s2 <= log_toggle_s1;
        log_toggle_d  <= log_toggle_s2;

        if (log_event)
            log_text_latched <= log_buffer;
        // 脉冲晚一拍输出，与锁存后的文字对齐。
        log_push_r <= log_event;
    end
end

assign subtitle_push = log_push_r;
assign subtitle_text = log_text_latched;
// ===================== 视频时序（video_clk 域）=====================

video_timing_ctrl #(
    .H_ACT       	(640  ),
    .H_FP        	(16   ),
    .H_SYNC      	(96   ),
    .H_BP        	(48   ),
    .V_ACT       	(480  ),
    .V_FP        	(10   ),
    .V_SYNC      	(2    ),
    .V_BP        	(33   ),
    .ACTIVE_LAST 	(0    ))
u_video_timing_ctrl(
    .pclk  	(video_clk   ),
    .rst_n 	(video_rst_n  ),
    .hsync 	(raw_hs  ),
    .vsync 	(raw_vs  ),
    .de    	(raw_de     ),
    .x     	(raw_x      ),
    .y     	(raw_y      )
);
reg raw_vs_q;
  always @(posedge video_clk or negedge video_rst_n) begin
      if (!video_rst_n) raw_vs_q <= 1'b1;
      else              raw_vs_q <= raw_vs;
  end
  assign frame_start = raw_vs_q && !raw_vs;   // vsync 下降沿，帧消隐期


// ===================== 缩略图 =====================
// 信号声明已移到文件开头；这里只做显示侧的 thumb_de / focus_border 判定，
// 读地址由 media_frame_reader 在 mem 域按同一映射生成。
thumbnail_layout #(
    .DISPLAY_WIDTH(640),
    .DISPLAY_HEIGHT(480),
    .THUMB_WIDTH(THUMB_W),
    .THUMB_HEIGHT(THUMB_H),
    .GAP(4),
    .BORDER(3)
) u_thumbnail_layout (
    .in_de(raw_de),
    .pixel_x(raw_x),
    .pixel_y(raw_y),           // 和 raw_x/raw_de 同拍，与 thumb_region 对齐
    .focus_index(focus_pix),
    .image_complete(img_done_pix),
    .thumb_de(thumb_de),
    .source_index(thumb_source_index),
    .source_x(thumb_source_x),
    .source_y(thumb_source_y),
    .thumb_gap(thumb_gap),
    .focus_border(focus_border)
);
// ===================== 缩略图控制部分 =====================
thumbnail_controller u_thumbnail_controller(
    .clk(sd_card_clk),
    .rst_n(sdcard_rst_n),
    .sw3(sw3),
    .image_complete(loader_image_complete),
    .view_mode(tc_view_mode),   // 0=全屏 1=缩略图
    .focus_left(focus_left),
    .focus_right(focus_right),
    .focus_index(tc_focus_index),
    .select_index(thumbnail_select_index),
    .select_event(thumbnail_select_event),
    .current_index(ctrl_current_index)
);
// ===================== SDRAM 刷新守护（ext_mem_clk 域）=====================
// 控制器内部自刷新遇到读写会被丢弃；这里定时暂停读写并主动请求刷新，
// 保证四个 bank 的数据在长期不重写的情况下不衰减。
sdram_refresh_guard #(
    .REFRESH_PERIOD (1500),
    .IDLE_CYCLES    (16),
    .ACK_TIMEOUT    (255)
) u_sdram_refresh_guard (
    .clk           (ext_mem_clk),
    .rst_n         (mem_rst_n),
    .init_done     (Sdr_init_done),
    .app_wr_en     (App_wr_en),
    .app_rd_en     (App_rd_en),
    .sdr_rd_valid  (Sdr_rd_en),
    .refresh_vld   (Sdr_init_ref_vld),
    .hold          (sdr_refresh_hold),
    .ref_req       (App_ref_req),
    .timeout_count (sdr_refresh_timeout)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (~mem_rst_n),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_ref_req       (App_ref_req),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频使能（video_clk 域）=====================
reg audio_enable;
reg [1:0] video_start_delay;
always @(posedge video_clk or negedge video_rst_n) begin
    if (!video_rst_n) begin
        video_start_delay <= 2'd0;
        audio_enable <= 1'b0;
    end else begin
        if (!player_enable_pix) begin
            video_start_delay <= 2'd0;
            audio_enable <= 1'b0;
        end else if (video_start_delay != 2'd3) begin
            video_start_delay <= video_start_delay + 1'b1;
        end else begin
            audio_enable <= 1'b1;
        end
    end
end
// ===================== 音画同步增益 =====================
  // B5：图和歌独立后换图不再压音量，sync_fade_gain 停用；改为切歌时的淡入淡出增益
  // wire [7:0] fade_gain;
  // sync_fade_gain u_sync_fade_gain (
  //     .pix_clk     (video_clk),
  //     .pix_rst_n   (video_rst_n),
  //     .frame_start (frame_start),
  //     .alpha_pix   (fade_alpha),
  //     .fade_active (fade_active),
  //     .aud_clk     (video_clk),      // 本工程音频链也在 video_clk 上
  //     .aud_rst_n   (video_rst_n),
  //     .gain_aud    (fade_gain)
  // );
  // 切歌增益：sd_card_clk 域每次只变 1 的格雷码，2FF 后解码
  (* ASYNC_REG = "TRUE" *) reg [7:0] tg_gray_s1, tg_gray_s2;
  always @(posedge video_clk or negedge video_rst_n)
      if (!video_rst_n) {tg_gray_s2, tg_gray_s1} <= {8'h80, 8'h80};   // 255 的格雷码
      else              {tg_gray_s2, tg_gray_s1} <= {tg_gray_s1, track_gain_gray};
  wire [7:0] track_gain;
  assign track_gain[7] = tg_gray_s2[7];
  genvar tg_i;
  generate for (tg_i = 6; tg_i >= 0; tg_i = tg_i - 1) begin : g_tg_dec
      assign track_gain[tg_i] = track_gain[tg_i + 1] ^ tg_gray_s2[tg_i];
  end endgenerate
  // 用户音量 × 切歌增益
  wire [15:0] wav_gain_mul = volume_pix * track_gain;
  wire [7:0]  wav_gain     = wav_gain_mul[15:8];
// ===================== WAV流式播放器 =====================
// 累加器
  always @(posedge video_clk or negedge video_rst_n) begin
      if (!video_rst_n)  wav_rate_acc <= 25'd0;
      else if (wav_tick) wav_rate_acc <= wav_rate_acc - (25_000_000 -
  48_000);
      else               wav_rate_acc <= wav_rate_acc + 48_000;
  end
wav_stream_player #(
    .ADDR_WIDTH(12),
    .SAMPLES_PER_SECTOR(256)
    
) u_wav_stream_player (
    .wr_clk(sd_card_clk),
    .wr_rst_n(sdcard_rst_n),
    .play_enable(bmp_load_all_done),
    .restart(track_restart),
    .start_lba(track_lba),
    .total_sectors(track_sec),
    .sd_req(aud_sector_req),
    .sd_lba(aud_sector_lba),
    .sd_busy(aud_sector_busy),
    .sd_valid(aud_sector_valid),
    .sd_byte(aud_sector_byte),
    .sd_byte_index(aud_sector_byte_index),
    .sd_done(aud_sector_done),
    .sd_error(aud_sector_error),
    .rd_clk(video_clk),
    .rd_rst_n(video_rst_n),
    .sample_tick(wav_tick),
    .sample_out(wav_sample),
    .sample_valid(wav_valid),
    .sample_ready(wav_ready),
    .gain(wav_gain),
    .sample_counter(wav_sample_count),
    .stream_active(wav_active),
    .stream_end(wav_stream_end),
    .buffer_low( )
);
// ===================== 波形可视化 =====================
// promax_audio_waveform #(
//     .WAVE_X(64),
//     .WAVE_Y(400),
//     .WAVE_WIDTH(512),
//     .WAVE_HEIGHT(64),
//     .DECIMATE(12)
    
// ) u_promax_audio_waveform (
//     .clk(video_clk),
//     .rst_n(video_rst_n),
//     .vsync(raw_vs),
//     .de(raw_de),
//     .rgb_in(promax_rgb_out),
//     .pixel_x(raw_x),
//     .enable(wav_active),
//     .pcm_tap_valid(wav_valid && wav_ready),
//     .pcm_tap_left(wav_sample),
//     .rgb_out(wave_form_rgb_out),
//     .waveform_active(waveform_active)
// );
promax_audio_bars #(
      .WAVE_X(64), .WAVE_Y(400), .WAVE_WIDTH(512), .WAVE_HEIGHT(64),
      .DECIMATE(40), .UPDATE_DIV(2),
      .ATTACK_SHIFT(1), .RELEASE_SHIFT(3), .PEAK_HOLD(30)
  ) u_promax_audio_waveform ( .clk(video_clk),
    .rst_n(video_rst_n),
    .vsync(raw_vs),
    .de(raw_de),
    .rgb_in(promax_rgb_out),
    .pixel_x(raw_x),
    .enable(wav_active),
    .pcm_tap_valid(wav_valid && wav_ready),
    .pcm_tap_left(wav_sample),
    .rgb_out(wave_form_rgb_out),
    .waveform_active(waveform_active) );

// ===================== 播放进度条 =====================
// 柱状图下方 y=468~471，x=64~511（宽 448），右侧 x=520~559 显示已播放时间；有歌在放（含放完到下一首之间）才显示
progress_bar_overlay #(
    .BAR_X(64), .BAR_Y(468), .BAR_W(448), .BAR_H(4),
    .BAR_MUL(7), .DIV_SHIFT(2), .W_SHIFT(9)   // 448 = 256 × 7 / 4（每扇区 256 个样本）
) u_progress_bar_overlay (
    .clk          (video_clk),
    .rst_n        (video_rst_n),
    .vsync        (raw_vs),
    .de           (raw_de),
    .pixel_x      (raw_x),
    .pixel_y      (raw_y),
    .rgb_in       (wave_form_rgb_out),
    .enable       (wav_active | wav_stream_end),
    .sample_count (wav_sample_count),
    .total_sectors(pcm_rd_sectors),     // sd_card_clk 域，模块内同步
    .rgb_out      (progress_rgb_out)
);
song_time_osd #(
    .TXT_X(520), .TXT_Y(464), .CHAR_W(8), .SAMPLE_RATE(48000)
) u_song_time_osd (
    .clk          (video_clk),
    .rst_n        (video_rst_n),
    .vsync        (raw_vs),
    .de           (raw_de),
    .pixel_x      (raw_x),
    .pixel_y      (raw_y),
    .rgb_in       (progress_rgb_out),
    .enable       (wav_active | wav_stream_end),
    .sample_count (wav_sample_count),
    .rgb_out      (song_time_rgb_out)
);

// ===================== 歌单面板 =====================
// SW4 进 video_clk 域（2FF），和图片加载完成一起作为面板显示条件
(* ASYNC_REG = "TRUE" *) reg sw4_v1, sw4_v2;
always @(posedge video_clk or negedge video_rst_n)
    if (!video_rst_n) {sw4_v2, sw4_v1} <= 2'b00;
    else              {sw4_v2, sw4_v1} <= {sw4_v1, sw4};
// 画面右侧 x=416~639、y=80 起，高度随歌曲数变化；SW4=1 显示
playlist_panel #(
    .BOX_X(416), .BOX_Y(80), .NCH(18), .CW(12), .PAD(4)
) u_playlist_panel (
    .clk     (video_clk),
    .rst_n   (video_rst_n),
    .vsync   (raw_vs),
    .de      (raw_de),
    .pixel_x (raw_x),
    .pixel_y (raw_y),
    .rgb_in  (song_time_rgb_out),
    .enable  (player_enable_pix && sw4_v2),
    .pl_bus  (pl_bus),               // sd_card_clk 域，模块内同步
    .rgb_out (playlist_rgb_out)
);

// ===================== 卡状态提示（CS）=====================
// 图片加载完成前（player_enable_pix = 0，画面本来是黑的），屏幕中间显示读卡状态或故障原因
card_status_osd #(
    .TXT_X(128), .TXT_Y(228)
) u_card_status_osd (
    .clk     (video_clk),
    .rst_n   (video_rst_n),
    .vsync   (raw_vs),
    .de      (raw_de),
    .pixel_x (raw_x),
    .pixel_y (raw_y),
    .rgb_in  (playlist_rgb_out),
    .enable  (!player_enable_pix),
    .status  (bmp_card_status),        // sd_card_clk 域，模块内同步
    .rgb_out (card_rgb_out)
);

// ===================== HDMI 音频桥 =====================
media_hdmi_audio_bridge u_media_hdmi_audio_bridge(
    .pixel_clk          	(video_clk           ),
    .pixel_rst_n        	(video_rst_n         ),
    .video_hsync        	(hs         ),
    .video_vsync        	(vs         ),
    .video_de           	(de            ),
    .video_x            	(video_x             ),
    .video_rgb          	(vout_data           ),
    .media_id           	(active_index            ),
    .volume             	(8'd220              ),
    .wav_valid(wav_valid),          // ← 接 WAV
    .wav_ready(wav_ready),          // ← 接 WAV
    .wav_left(wav_sample),            // ← 接 WAV
    .wav_right(wav_sample),          // ← 接 WAV
    .wav_active(wav_active | wav_stream_end),   // 放完到下一首起播之间送静音，不切到测试音
    .channel0_symbol    	(core_ch0_symbol     ),
    .channel1_symbol    	(core_ch1_symbol     ),
    .channel2_symbol    	(core_ch2_symbol     ),
    .sequence_error     	(core_sequence_error      ),
    .tone_overflow      	(       ),
    .pcm_contract_error 	(  ),
    .blip_active        	(         ),
    .pcm_tap_valid      	(       ),
    .pcm_tap_left       	(        ),
    .audio_enable           (audio_enable)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (~video_rst_n),
    .I_tmds_channel_0   (core_ch0_symbol),
    .I_tmds_channel_1   (core_ch1_symbol),
    .I_tmds_channel_2   (core_ch2_symbol),
    .I_tmds_channel_clk (clk_symbol),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

// ===================== 按键层 =====================
// output declaration of module dual_key_chord_router

dual_key_chord_router #(
    .CLK_FREQ_HZ  	(100_000_000  ),
    .KEY4_HOLD_MS 	(1000         ))
u_dual_key_chord_router(
    .clk             	(sd_card_clk              ),
    .rst_n           	(sdcard_rst_n            ),
    .key2_in         	(key1          ),
    .key4_in         	(key2          ),
    .save_enabled    	(1'b1     ),
    .key2_event      	(key_next_event       ),
    .key2_long_event 	(key_song_event       ),
    .key4_event      	(key_auto_event       ),
    .key4_long_event 	(key_prev_event  ),
    .save_event      	(key_save_event       ),
    .key2_stable (),
    .key4_stable (),
    .guard_trigger   (),
    .locked          ()       )
;
// 按键3消抖
ax_debounce #(
      .FREQ     (100),     // sd_card_clk = 100 MHz
      .MAX_TIME (20)       // 20 ms
  ) u_key3_debounce (
      .clk            (sd_card_clk),
      .rst            (~sdcard_rst_n),     // 注意：这个模块是高有效复位
      .button_in      (key3),
      .button_posedge (),
      .button_negedge (key3_press),
      .button_out     ()
  );
// KEY3：SW3=1（缩略图）焦点左移；SW3=0 且 SW1=0 切播放模式；SW1=1 全屏时无动作
assign key3_left_event = key3_press;                       // media_policy 内按 view_mode 放行
// SW3 消抖已移入 thumbnail_controller（sd_card_clk 域）
// ===================== 拨码选择 KEY2 短按功能 =====================
reg [1:0] adj_en_sync;
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
    if(!sdcard_rst_n) begin
        adj_en_sync <= 2'b00;
    end else begin
        adj_en_sync <= {adj_en_sync[0], sw1};
    end
end
wire adj_mode = adj_en_sync[1];
assign key_mode_event = key3_press & ~tc_view_mode & ~adj_mode;   // KEY3 切播放模式（见上方 KEY3 说明）
wire key_adj_event = key_auto_event & adj_mode;// 调参模式：KEY2 短按 → 调参
assign key_adj_gated = key_auto_event & ~adj_mode;// 普通模式：KEY2 短按 → 自动播放
// 单拍脉冲跨到 video_clk 前先转成翻转信号（和 OSD 日志 log_toggle 同一套做法）
always @(posedge sd_card_clk or negedge sdcard_rst_n) begin
      if (!sdcard_rst_n)      adj_toggle <= 1'b0;
      else if (key_adj_event) adj_toggle <= ~adj_toggle;
  end

// output declaration of module media_policy

media_policy u_media_policy(
    .key_next_event    	(key_next_event     ),   // 原始按键；淡出在 manual_next_event 之后
    .key_auto_event    	(key_adj_gated     ),
    .key_prev_event    	(key_prev_event     ),
    .key_save_event    	(key_save_event     ),
    .key_left_event     (key3_left_event),
    .view_mode          (tc_view_mode),
    .next_event        	(cmd_next         ),
    .auto_toggle_event 	(cmd_auto_toggle  ),
    .prev_event        	(cmd_prev         ),
    .save_event        	(cmd_save         ),
    .focus_left         (focus_left),
    .focus_right        (focus_right)
);
// ===================== 测试实例音 =====================
// output declaration of module pcm_test_tone
// pcm_test_tone #(
//       .SAMPLE_DIV(521)
//   ) u_pcm_test_tone (
//       .clk             (video_clk),
//       .rst_n           (~rst_all),
//       .enable          (1'b1),

//       .sample_valid    (audio_sample_valid),
//       .sample_ready    (audio_sample_ready),
//       .sample_left     (audio_sample_left),
//       .sample_right    (audio_sample_right),
//       .rom_index       (),
//       .sample_accepted (audio_sample_accepted)
//   );

//定位音频桥数据岛的数据计数器
  always @(posedge video_clk or negedge video_rst_n) begin
      if (!video_rst_n) begin
          video_de_d <= 1'b0;
          video_x    <= 10'd0;
      end else begin
          video_de_d <= de;

          // 每条有效视频行的第一个像素重新校准坐标。
          // 这里装载 1，是为了补偿非阻塞赋值带来的一拍观察延迟。
          if (de && !video_de_d)
              video_x <= 10'd1;
          else if (video_x == 10'd799)
              video_x <= 10'd0;
          else
              video_x <= video_x + 1'b1;
      end
  end
endmodule
