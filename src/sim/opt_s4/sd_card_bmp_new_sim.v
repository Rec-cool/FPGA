// Four-bank interface audit (2026-10-06):
//   4BANK_KEEP   - belongs to the final SD/FAT32/BMP source contract.
//   4BANK_REMOVE - legacy double-buffer/player interface; remove with its logic.
//   4BANK_REWIRE - still required, but its direction/name/owner is currently wrong.
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000, // 4BANK_REMOVE: only legacy autoplay/timeout logic uses this
    parameter [31:0]  AUTO_PLAY_MS = 1500,             // 4BANK_REMOVE: autoplay belongs to media_player_control
    // === 图片参数 ===
    parameter [15:0] BMP_WIDTH = 16'd640,               // 4BANK_KEEP
    parameter [15:0] BMP_HEIGHT = 16'd480,              // 4BANK_KEEP
    // 扩展 3：0 = 只接受 BMP_WIDTH×BMP_HEIGHT（缩放器走 1:1）；1 = 接受其他尺寸
    parameter        SCALE_ENABLE = 0,
    parameter integer SCALE_MAX_W = 4096,
    parameter integer SCALE_FIT   = 1,   // 1 = 整图可见、等比缩小、四周补黑（不放大）；0 = 等比铺满、居中裁剪
    parameter integer SCALE_RATE  = 32,  // 缩放器输出间隔（拍），黑边像素也按这个速率写 SDRAM
    // === 扫描参数 ===
    // Deprecated: FAT32 scanner no longer performs raw physical-sector search.
    parameter [31:0] SCAN_START_SECTOR = 32'd2048, // 4BANK_REMOVE: FAT32 scanner does not use it
    parameter [31:0] SCAN_MAX_SECTOR = 32'd60000,  // 4BANK_REMOVE: FAT32 scanner does not use it
    parameter [2:0] SCAN_TARGET_COUNT = 3'd4,      // 4BANK_REMOVE: FAT32 scanner fixes resource count at four
    // === 稳定性参数 ===
    parameter FRAME_LOAD_TIMEOUT_MS = 32'd5000,   // 4BANK_REMOVE: loader owns write timeout/error handling
    parameter MAX_RETRIES       = 2'd1            // 4BANK_REMOVE: retry policy is not part of the BMP source
)(
    input                       clk,                // 4BANK_KEEP: SD/FAT32/BMP clock domain
    input                       rst,                // 4BANK_KEEP: active-high reset
   //output reg                  display_valid,      // 4BANK_REMOVE: derive display enable from loader image_complete
    output reg [3:0]            state_code,         // 4BANK_REMOVE: derive UI state from controller active_index/errors
    //output                      key_next_press_out, // 4BANK_REMOVE: keys connect directly to media_player_control
    //output                      [1:0] img_idx_out,  // 4BANK_REMOVE: active_index is owned by media_player_control
    input                       Sdr_init_done,       // 4BANK_KEEP: gate the first loader request until SDRAM is ready
    // === 扫描/加载控制 ===
    output                           load_start,       // 4BANK_REWIRE: must be OUTPUT; scheduler -> media_frame_loader
    output  [1:0]                     load_image_index, // 4BANK_REWIRE: must be OUTPUT; scheduler -> loader image_index
    input                            load_busy,        // 4BANK_KEEP: media_frame_loader -> scheduler
    input                            load_done,        // 4BANK_KEEP: media_frame_loader -> scheduler; do not drive internally
    input  [3:0]                     image_complete,    // 4BANK_REMOVE: connect loader image_complete directly to controller/top
    // === BMP 解析输出（给 loader）===
    output                      pixel_valid,         // 4BANK_KEEP: pixel stream -> loader
    output [23:0]               pixel_rgb,           // 4BANK_KEEP: pixel stream -> loader
    output                      frame_commit,        // 4BANK_KEEP: pulse with the final decoded pixel
    // === SD 卡引脚 ===
    output                      SD_nCS,               // 4BANK_KEEP
    output                      SD_DCLK,              // 4BANK_KEEP
    output                      SD_MOSI,              // 4BANK_KEEP
    input                       SD_MISO,              // 4BANK_KEEP
    // === 错误码 ===
    output  [7:0] decoder_error,                          // 4BANK_REWIRE: widen/map to loader decode_error[7:0]
    output  load_error   ,
    output load_all_done,
    // === WAV格式音频端口 ===
  input  wire        aud_sector_req,
  input  wire [31:0] aud_sector_lba,
  output wire        aud_sector_busy, aud_sector_valid, aud_sector_done,
  output wire [7:0]  aud_sector_byte, aud_sector_error,
  output wire [8:0]  aud_sector_byte_index,
  // 扫描器收集的 *.PCM 歌曲表（clk 域，读出延迟 1 拍）
  output wire [4:0]  pcm_count,
  input  wire [3:0]  pcm_rd_idx,
  output wire [31:0] pcm_rd_lba,
  output wire [23:0] pcm_rd_sectors
   
);

// 4BANK_CLEANUP_NOTE: this is currently a mixed declaration region. Legacy
// names include LOAD_TIMEOUT_CYCLES, first_image_committed, auto_play_en,
// auto_cnt, img_idx, pending_buf_idx, next_from_current, auto_play_cycles,
// load_error_seen and retry_count. SD/FAT32/BMP stream signals in this region
// are still required, so do not delete this region as one block.
//wire key_next_press;
//wire key_auto_press;
// localparam integer LOAD_TIMEOUT_CYCLES =
//       (CLK_FREQ_HZ / 1000) * FRAME_LOAD_TIMEOUT_MS;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             scan_done;

reg              scan_start_pulse;
reg              load_start_pulse;
reg              scan_kicked;
reg              first_image_committed;
// reg              auto_play_en;
// reg [31:0]       auto_cnt;
// reg [2:0]        img_found_count;
//reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
//reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
// ----- 武装逻辑 跨时钟域同步-----//
//reg [2:0] wrreq_ack_sync;                       // 修第 10 条：跨时钟域同步
//   always @(posedge clk or posedge rst)
//       if (rst) wrreq_ack_sync <= 3'b0;
//       else     wrreq_ack_sync <= {wrreq_ack_sync[1:0], write_req_ack};
// wire write_req_ack_sync  = wrreq_ack_sync[2];       // 第 649 行武装逻辑也改用这个信号
// ====== 改动结束 ======
// reg              next_req_pending;

// reg [31:0]       load_timeout_cnt;

// reg              load_abort;

//reg              abort_wait;            //正在等待 SDRAM 写状态机完成清理
//reg [2:0]        wrabort_ack_sync;      //把确认信号同步回 100 MHz 的 SD 卡域。
// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
// reg              source_done_seen;
// reg              write_done_seen;
// reg              source_busy_seen;
// 同步 mem_clk 域的 write_finish_toggle
// reg [2:0]        wrfin_tgl_sync;
// reg              write_finish_baseline;
// reg              write_finish_armed;
//wire             write_finish_pulse;
// wire auto_tick;
wire [1:0] next_from_current;
//reg prev_req_pending;        //上一张请求挂起标志位
wire [31:0] auto_play_cycles = (CLK_FREQ_HZ / 1000) * AUTO_PLAY_MS; //转化成MS
reg load_error_seen;//检测到错误
reg [1:0] retry_count;//重试次数
//assign write_en   = bmp_data_wr_en;
//assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
//assign auto_tick  = (auto_cnt == (auto_play_cycles - 1));
//assign next_from_current = next_index_limited(img_idx, scan_resource_valid);
//assign key_next_press_out = next_event;
// assign img_idx_out = img_idx;

//assign state_code_i_out = state_code_i;
//assign state_code = state_code_i;
//assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
//assign state_code = state_code_i;
// 4BANK_KEEP/REWORK: the new four-image load scheduler starts here. It should
// be the sole owner of load_start/load_image_index and consume loader feedback.
// =======加载一张图片执行状态机：=========
localparam LOAD_IDLE      = 2'd0;
localparam LOAD_WAIT_ACK  = 2'd1;
localparam LOAD_STREAMING = 2'd2;

reg [1:0] load_state;
wire       load_cmd_pulse;
wire [1:0] load_cmd_idx;
// =======加载4张图片调度状态机：=========
localparam LOAD_CTRL_IDLE      = 2'd0;
localparam LOAD_CTRL_LOADING   = 2'd1;
localparam LOAD_CTRL_WAIT_DONE = 2'd2;
localparam LOAD_CTRL_DONE      = 2'd3;

reg [1:0] load_ctrl_state;
reg [1:0] load_ctrl_idx;
assign load_cmd_idx = load_ctrl_idx;
reg load_ctrl_start;

//=== 新增：FAT32适配层信号 ===
wire  [7:0]  scanner_spc;
wire  [31:0] scanner_fat_start;
wire  [31:0] scanner_data_start;
wire  [31:0] scanner_max_cluster;
wire  [3:0]  scan_resource_valid;
wire  [31:0] img_cluster0, img_cluster1, img_cluster2, img_cluster3;
wire  [31:0] img_size0, img_size1, img_size2, img_size3;
reg  [31:0] load_cluster;
reg  [31:0] load_file_size;
wire         streamer_byte_valid;
wire [7:0]  streamer_byte;
reg  [2:0]  byte_state;       // 0=空闲, 1=读BMP头, 2=拼RGB, 3=校验失败, 4=跳过行尾填充
reg  [15:0] bmp_byte_cnt;     // BMP头字节计数器（16位，足够跳过任何BMP头大小）
reg  [31:0] data_offset;      // 从BMP头偏移10解析出的数据偏移量
reg  [2:0]  rgb_byte_cnt;     // RGB字节计数器（0=B, 1=G, 2=R, 3=输出）
reg  [23:0] rgb_pixel;        // 拼装中的RGB像素
wire        scanner_busy;
wire        streamer_busy;
wire        streamer_done_pulse;
wire        scanner_done_pulse;
wire [7:0]  scanner_fs_error; //synthesis keep
wire [7:0]  streamer_fs_error;

//=== 新增结束 ===
//=== 修改：替换bmp_read为FAT32两个模块+接口适配层 ===

// ---------- 扇区读仲裁：两个FAT32模块都要读SD卡，分时复用 ----------
// 扫描阶段用扫描器，加载阶段用流读器（扫描和加载不会同时进行）

reg         scan_success;          // 扫描成功标志（至少找到1个文件）

// 扫描器的扇区读接口（接到仲裁器）
wire        scanner_sector_req;
wire [31:0] scanner_sector_lba;
wire        scanner_sector_busy;
wire        scanner_sector_valid;
wire [7:0]  scanner_sector_byte;
wire [8:0]  scanner_sector_byte_index;
wire        scanner_sector_done;
wire [7:0]  scanner_sector_error;

// 流读器的扇区读接口（接到仲裁器）
wire        streamer_sector_req;
wire [31:0] streamer_sector_lba;
wire        streamer_sector_busy;
wire        streamer_sector_valid;
wire [7:0]  streamer_sector_byte;
wire [8:0]  streamer_sector_byte_index;
wire        streamer_sector_done;
wire [7:0]  streamer_sector_error;

// 仲裁器输出（接到sd_sector_adapter）
reg         arb_sector_req;
reg [31:0]  arb_sector_lba;
wire        arb_sector_busy;
wire        arb_sector_valid;
wire [7:0]  arb_sector_byte;
wire [8:0]  arb_sector_byte_index;
wire        arb_sector_done;
wire [7:0]  arb_sector_error;
// 新增端口：aud_sector_req/lba 输入，aud_sector_busy/valid/byte/byte_index/done/error 输出
wire use_audio = (load_ctrl_state == LOAD_CTRL_DONE);  // 此时 streamer 已经读完，适配层空闲，切换是安全的
// 仲裁逻辑：use_streamer=0时透传扫描器，=1时透传流读器
reg use_streamer;
always @(*) begin
    if(use_audio) begin
        arb_sector_req = aud_sector_req; 
        arb_sector_lba = aud_sector_lba;
    end
    else if (use_streamer) begin
        arb_sector_req   = streamer_sector_req;
        arb_sector_lba   = streamer_sector_lba;
        // 流读器接收仲裁返回
        // （扫描器的返回信号设为无效）
    end else begin
        arb_sector_req   = scanner_sector_req;
        arb_sector_lba   = scanner_sector_lba;
        // 扫描器接收仲裁返回
        // （流读器的返回信号设为无效）
    end
end
// 注意：上面的仲裁逻辑是简化版。完整的仲裁需要把arb_sector_busy/valid/byte等
// 返回信号按use_streamer分别接到扫描器或流读器。
// 由于扫描和加载不会同时进行（扫描完成后才加载），也可以用更简单的方式：
// 直接把两个模块的sector_req做或运算，sector_lba用use_streamer选择。
// 具体实现请根据你的工程调整，核心原则是：同一时刻只有一个模块读SD卡。
//====== 响应信号最好也按当前所有者进行门控，避免未获得总线的模块误接收数据：
//assign scanner_sector_ready =
//        (!use_streamer) && adapter_sector_ready;

//assign scanner_sector_valid =
//        (!use_streamer) && adapter_sector_valid;

//assign scanner_sector_done =
//        (!use_streamer) && adapter_sector_done;

//assign streamer_sector_ready =
//        use_streamer && adapter_sector_ready;

//assign streamer_sector_valid =
//        use_streamer && adapter_sector_valid;

//assign streamer_sector_done =
//        use_streamer && adapter_sector_done;
// =====数据本身可以共用=======
//assign scanner_sector_data  = adapter_sector_data;
//assign streamer_sector_data = adapter_sector_data;
assign scanner_sector_byte       = arb_sector_byte;
assign scanner_sector_byte_index = arb_sector_byte_index;
assign streamer_sector_byte       = arb_sector_byte;
assign streamer_sector_byte_index = arb_sector_byte_index;
// 适配层返回 → 扫描器输入（只在 use_streamer=0 时有效）
assign scanner_sector_busy       = (use_audio || use_streamer) ? 1'b0 : arb_sector_busy;
assign scanner_sector_valid      = (use_audio || use_streamer) ? 1'b0 : arb_sector_valid;
assign scanner_sector_done       = (use_audio || use_streamer) ? 1'b0 : arb_sector_done;
assign scanner_sector_error      = (use_audio || use_streamer) ? 8'd0 : arb_sector_error;

// 适配层返回 → 流读器输入（只在 use_streamer=1 时有效）
assign streamer_sector_busy       = (!use_audio && use_streamer) ? arb_sector_busy : 1'b0;
assign streamer_sector_valid      = (!use_audio && use_streamer) ? arb_sector_valid : 1'b0;
assign streamer_sector_done       = (!use_audio && use_streamer) ? arb_sector_done : 1'b0;
assign streamer_sector_error      = (!use_audio && use_streamer) ? arb_sector_error : 8'd0;

// wav
 assign aud_sector_busy  = use_audio ? arb_sector_busy  : 1'b1;  // 没拿到总线时让播放器在 WS_REQ 等着
 assign aud_sector_valid = use_audio & arb_sector_valid;
 assign aud_sector_done  = use_audio & arb_sector_done;
 assign aud_sector_error      = use_audio ? arb_sector_error : 8'd0;
 assign aud_sector_byte       = arb_sector_byte;
 assign aud_sector_byte_index = arb_sector_byte_index;

  // 原来 scanner/streamer 的返回信号再多加一个 !use_audio 门控

//=== 新增：BMP头解析（严谨版） + 字节流拼RGB ===
// 内部寄存器
reg              bmp_data_wr_en_r;
reg  [23:0]      bmp_data_r;
// 严谨版：解析偏移10的4字节得到数据偏移量(data_offset)，跳过data_offset字节
// assign bmp_data_wr_en = (byte_state == 2'd2) && (rgb_byte_cnt == 3'd3) && streamer_byte_valid;
// assign bmp_data = rgb_pixel;
assign bmp_data_wr_en = bmp_data_wr_en_r;
assign bmp_data       = bmp_data_r;
// 2) 恢复原语义：bmp_ready 表示"空闲"电平，scan_done 表示"已扫描"电平
reg  write_req_r, file_start_pulse;
reg  scan_complete;
reg  user_streamer;

//assign write_req = write_req_r;
reg  hdr_bad;      // 当前文件头校验失败（解析过程中置位），失败时丢弃像素不写SDRAM
reg  [15:0] src_row;     // 本文件已读完的源图行数，用于截断检测
reg  [31:0] bmp_w, bmp_h;  // BMP 头里的宽、高（32 位有符号，高度为负表示自上而下存储）
reg  [15:0] col_cnt;       // 当前行已拼出的像素数
reg  [1:0]  pad_cnt;       // 行尾还要跳过的填充字节数（每行补齐到 4 字节：宽×3 mod 4 → 填充 = 宽 mod 4）
wire        in_pixels = (byte_state == 3'd2) || (byte_state == 3'd4);
// 送给缩放器的源像素（缩放器在下方例化）
reg         scaler_cfg;
reg         scaler_go;          // 头校验通过、进入像素区
reg         scaler_in_valid;
reg  [23:0] scaler_in_rgb;
// ===== 错误码：沿用 bmp_read.v 的定义 =====
localparam ERR_NONE      = 3'd0;     //无错误
localparam ERR_HEADER    = 3'd1;     //BMP头检验失败
localparam ERR_TIMEOUT   = 3'd2;     //SD卡超时
localparam ERR_TRUNCATED = 3'd3;     //像素数据截取
// 尺寸检查（在头读完、进入像素区时判定）
wire size_bad = SCALE_ENABLE ?
                ((bmp_w[31:16] != 16'd0) || (bmp_w[15:0] > SCALE_MAX_W) || (bmp_h[31:16] != 16'd0) ||
                 (SCALE_FIT ? ((bmp_w[15:0] == 16'd0) || (bmp_h[15:0] == 16'd0)) :
                              ((bmp_w[15:0] < BMP_WIDTH) || (bmp_h[15:0] < BMP_HEIGHT)))) :
                ((bmp_w != {16'd0, BMP_WIDTH}) || (bmp_h != {16'd0, BMP_HEIGHT}));
reg  [2:0] bmp_error_r;
assign decoder_error =  {5'd0, bmp_error_r};
// 文件流结束时的结果判定（byte_state 在完成脉冲当拍仍保持原值）
wire file_hdr_fail  = streamer_done_pulse && !in_pixels;     // 头校验失败或文件短于头
wire file_truncated = streamer_done_pulse && in_pixels &&
                      (src_row < bmp_h[15:0]);
assign load_error = streamer_done_pulse &&
                    ((streamer_fs_error != 8'd0) || file_hdr_fail || file_truncated);
// =====将扫描完成状态的脉冲转化为电平信号=====
always @(posedge clk or posedge rst) begin
    if (rst) begin
        scan_complete <= 1'b0;
        use_streamer  <= 1'b0;
    end
    else begin
        // 每次重新扫描，先把状态和总线所有权复位
        if (scan_start_pulse) begin
            scan_complete <= 1'b0;
            use_streamer  <= 1'b0;
        end

        if (scanner_done_pulse) begin
            // 支持1~4张图：至少找到一张即可，缺失编号在切换时跳过
            if ((scanner_fs_error == 8'h00) &&
                (scan_resource_valid != 4'h0)) begin
                scan_complete <= 1'b1;
                use_streamer  <= 1'b1;
            end
            else begin
                scan_complete <= 1'b0;
                use_streamer  <= 1'b0;
            end
        end
    end
end
// ====BMP头解析（严谨版） + 字节流拼RGB====

reg frame_commit_r;// 4BANK_KEEP/REWORK: must reset and default low so this is a one-cycle pulse
// byte_state: 0=空闲 1=读BMP头 2=拼RGB 3=头校验失败(丢弃字节) 4=跳过行尾填充
wire [15:0] hdr_cnt_nxt = bmp_byte_cnt + 16'd1;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        byte_state       <= 3'd0;
        bmp_byte_cnt     <= 16'd0;
        data_offset      <= 32'd54;  // 默认54字节（标准BMP头）
        rgb_byte_cnt     <= 3'd0;
        rgb_pixel        <= 24'd0;
        hdr_bad          <= 1'b0;
        src_row          <= 16'd0;
        scaler_cfg       <= 1'b0;
        scaler_go        <= 1'b0;
        scaler_in_valid  <= 1'b0;
        scaler_in_rgb    <= 24'd0;
        bmp_w            <= 32'd0;
        bmp_h            <= 32'd0;
        col_cnt          <= 16'd0;
        pad_cnt          <= 2'd0;
    end else begin
        // 写使能默认只保持一个时钟
        scaler_cfg       <= 1'b0;
        scaler_go        <= 1'b0;
        scaler_in_valid  <= 1'b0;
        if (load_start_pulse) begin
            byte_state    <= 3'd1;  // 开始读BMP头
            bmp_byte_cnt  <= 16'd0;
            data_offset   <= 32'd54;
            rgb_byte_cnt  <= 3'd0;
            hdr_bad       <= 1'b0;
            src_row       <= 16'd0;
            col_cnt       <= 16'd0;
        end else if (streamer_done_pulse) begin
            byte_state    <= 3'd0;  // 文件结束回空闲
        end else if (streamer_byte_valid) begin
            case (byte_state)
                3'd1: begin  // 读BMP头：校验关键字段并解析像素偏移（小端序）
                    bmp_byte_cnt <= hdr_cnt_nxt;
                    case (bmp_byte_cnt)
                        16'd0 : if (streamer_byte != 8'h42) hdr_bad <= 1'b1;            // 'B'
                        16'd1 : if (streamer_byte != 8'h4D) hdr_bad <= 1'b1;            // 'M'
                        16'd10: data_offset[7:0]   <= streamer_byte;
                        16'd11: data_offset[15:8]  <= streamer_byte;
                        16'd12: data_offset[23:16] <= streamer_byte;
                        16'd13: data_offset[31:24] <= streamer_byte;
                        // 宽、高按 32 位解析，进入像素区时由 size_bad 判定是否接受
                        16'd18: bmp_w[7:0]   <= streamer_byte;
                        16'd19: bmp_w[15:8]  <= streamer_byte;
                        16'd20: bmp_w[23:16] <= streamer_byte;
                        16'd21: bmp_w[31:24] <= streamer_byte;
                        16'd22: bmp_h[7:0]   <= streamer_byte;
                        16'd23: bmp_h[15:8]  <= streamer_byte;
                        16'd24: bmp_h[23:16] <= streamer_byte;
                        16'd25: bmp_h[31:24] <= streamer_byte;
                        16'd26: scaler_cfg   <= 1'b1;     // 宽高已齐，缩放器开始算参数（像素最早在第 54 字节后才来）
                        16'd28: if (streamer_byte != 8'd24) hdr_bad <= 1'b1;             // 24位色（低字节）
                        16'd29: if (streamer_byte != 8'd0)  hdr_bad <= 1'b1;             // 24位色（高字节）
                        16'd30, 16'd31, 16'd32, 16'd33:
                                if (streamer_byte != 8'd0)  hdr_bad <= 1'b1;             // BI_RGB不压缩（4 字节）
                        default: ;
                    endcase
                    // 读满 data_offset 字节后进入像素区；>=53 保证 offset 已拼完
                    if ((bmp_byte_cnt >= 16'd53) && ({16'd0, hdr_cnt_nxt} == data_offset)) begin
                        byte_state   <= (hdr_bad || size_bad) ? 3'd3 : 3'd2;
                        scaler_go    <= !(hdr_bad || size_bad);
                        rgb_byte_cnt <= 3'd0;
                    end
                end
                3'd2: begin  // 拼RGB：BMP字节顺序为 B → G → R
                    case (rgb_byte_cnt)
                        3'd0: begin rgb_pixel[7:0]  <= streamer_byte; rgb_byte_cnt <= 3'd1; end  // B
                        3'd1: begin rgb_pixel[15:8] <= streamer_byte; rgb_byte_cnt <= 3'd2; end  // G
                        default: begin                                                          // R：当拍输出
                            scaler_in_rgb    <= {streamer_byte, rgb_pixel[15:0]};
                            scaler_in_valid  <= 1'b1;
                            rgb_byte_cnt     <= 3'd0;
                            // 行末：宽度不是 4 的倍数时跳过填充字节
                            if (col_cnt == bmp_w[15:0] - 16'd1) begin
                                col_cnt <= 16'd0;
                                src_row <= src_row + 16'd1;
                                if (bmp_w[1:0] != 2'd0) begin
                                    byte_state <= 3'd4;
                                    pad_cnt    <= bmp_w[1:0];
                                end
                            end else begin
                                col_cnt <= col_cnt + 16'd1;
                            end
                        end
                    endcase
                end
                3'd4: begin  // 行尾填充：丢弃 pad_cnt 个字节后回到拼RGB
                    pad_cnt <= pad_cnt - 2'd1;
                    if (pad_cnt == 2'd1)
                        byte_state <= 3'd2;
                end
                default: ;  // 空闲/校验失败：丢弃字节，不写SDRAM
            endcase
            
            
        end
    end
end
// 缩放器：源像素 → 固定 BMP_WIDTH×BMP_HEIGHT 输出（1:1 时原样通过）
wire        scaler_out_valid, scaler_out_last;
wire [23:0] scaler_out_rgb;
wire [9:0]  scaler_fifo_level;
bmp_scaler #(
    .OUT_W (BMP_WIDTH),
    .OUT_H (BMP_HEIGHT),
    .MAX_W (SCALE_ENABLE ? SCALE_MAX_W : BMP_WIDTH),
    .FIT   (SCALE_FIT),
    .RATE  (SCALE_RATE)
) u_bmp_scaler (
    .clk       (clk),
    .rst_n     (~rst),
    .abort     (load_start_pulse),
    .cfg_start (scaler_cfg),
    .src_w     (bmp_w[15:0]),
    .src_h     (bmp_h[15:0]),
    .cfg_ready (),
    .go        (scaler_go),
    .in_valid  (scaler_in_valid),
    .in_rgb    (scaler_in_rgb),
    .out_valid (scaler_out_valid),
    .out_rgb   (scaler_out_rgb),
    .out_last  (scaler_out_last),
    .fifo_level(scaler_fifo_level),
    .overrun   ()
);
always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_r       <= 24'd0;
        bmp_data_wr_en_r <= 1'b0;
        frame_commit_r   <= 1'b0;
    end else begin
        bmp_data_wr_en_r <= scaler_out_valid;
        frame_commit_r   <= scaler_out_last;
        if (scaler_out_valid)
            bmp_data_r <= scaler_out_rgb;
    end
end
assign frame_commit = frame_commit_r;
assign pixel_valid = bmp_data_wr_en;
assign pixel_rgb   = bmp_data[23:0];
// 4BANK_REMOVE: duplicate "assign frame_commit = frame_commit_r" was here.
//=== 新增结束 ===

// 4BANK_REMOVE/REWORK_BEGIN: the following error latch still depends on the
// removed double-buffer completion/abort handshake (abort_wait,
// source_done_seen, write_done_seen and load_abort). Replace it with a pure
// decoder error latch before deleting those legacy signals.
// ===== 错误码锁存：保持到重新扫描或下一张图成功提交 =====
//   ERR_HEADER    : 扫描未找到合法资源 / FAT32引导扇区不合法 / BMP头校验失败
//   ERR_TIMEOUT   : 扇区读错误 / 整帧加载超时
//   ERR_TRUNCATED : FAT链异常提前结束 / 像素数不足一帧
// wire commit_ok = 
always @(posedge clk or posedge rst) begin
      if (rst) begin
          bmp_error_r <= ERR_NONE;
      end else begin
          if (scan_start_pulse || load_start_pulse)      // ← 加load_start_pulse:错误码只代表"当前文件"
              bmp_error_r <= ERR_NONE;

          if (scanner_done_pulse && (scanner_fs_error != 8'h00))
              bmp_error_r <= (scanner_fs_error == 8'h10) ? ERR_TIMEOUT :
  ERR_HEADER;

          if (streamer_done_pulse) begin
              if (streamer_fs_error == 8'h10)
                  bmp_error_r <= ERR_TIMEOUT;
              else if (streamer_fs_error != 8'h00)
                  bmp_error_r <= ERR_TRUNCATED;
              else if (file_hdr_fail)
                  bmp_error_r <= ERR_HEADER;
              else if (file_truncated)
                  bmp_error_r <= ERR_TRUNCATED;
          end
      end          // ← 恢复
  end
// 4BANK_REMOVE/REWORK_END

// // 在always块里控制use_streamer和scan_success
// always @(posedge clk or posedge rst) begin
//     if (rst) begin
//         use_streamer <= 1'b0;
//         scan_success <= 1'b0;
//     end else if (scan_done) begin
//         // 扫描完成：如果至少找到1个文件（resource_valid != 0），标记成功并切换到流读器
//         scan_success <= (scan_resource_valid != 4'd0);
//         use_streamer <= (scan_resource_valid != 4'd0);  // 只有扫描成功才切换
//     end
// end
// ---------- 卷扫描器 ----------
fat32_volume_scanner u_scanner (
    .clk                 (clk),
    .rst_n               (~rst),            // 官方是高有效复位，新模块是低有效
    .scan_start          (scan_start_pulse),
    .scan_busy           (scanner_busy),
    .scan_done           (scanner_done_pulse),
    .fs_error            (scanner_fs_error),
    .partition_lba       (),
    .sectors_per_cluster (scanner_spc),
    .fat_start_lba       (scanner_fat_start),
    .data_start_lba      (scanner_data_start),
    .max_cluster         (scanner_max_cluster),
    .resource_valid      (scan_resource_valid),
    .resource0_cluster   (img_cluster0),
    .resource1_cluster   (img_cluster1),
    .resource2_cluster   (img_cluster2),
    .resource3_cluster   (img_cluster3),
    .resource0_size      (img_size0),
    .resource1_size      (img_size1),
    .resource2_size      (img_size2),
    .resource3_size      (img_size3),
    .pcm_count           (pcm_count),
    .pcm_rd_idx          (pcm_rd_idx),
    .pcm_rd_lba          (pcm_rd_lba),
    .pcm_rd_sectors      (pcm_rd_sectors),
    .sector_req          (scanner_sector_req),
    .sector_lba          (scanner_sector_lba),
    .sector_busy         (scanner_sector_busy),
    .sector_valid        (scanner_sector_valid),
    .sector_byte         (scanner_sector_byte),
    .sector_byte_index   (scanner_sector_byte_index),
    .sector_done         (scanner_sector_done),
    .sector_error        (scanner_sector_error)
);
// -------文件流读取器部分实例定义----
// ---------- 文件流读取器 ----------
// 簇数上限只是防环的保险：读满 file_size 字节一定会停。默认 8192 簇在小簇卡上只够 4MB，
// 装不下高分辨率 BMP（1920×1080 约 6MB），这里放大到 2^20
fat32_file_streamer #(
    .MAX_VISITED_CLUSTERS (1048576)
) u_streamer (
    .clk                 (clk),
    .rst_n               (~rst),
    .file_start          (load_start_pulse),
    .hold                (scaler_fifo_level >= 10'd256),   // 缩放器 FIFO 过半：暂停读下一个扇区（一个扇区最多 171 像素）
    .first_cluster       (load_cluster),
    .file_size           (load_file_size),
    .sectors_per_cluster (scanner_spc),
    .fat_start_lba       (scanner_fat_start),
    .data_start_lba      (scanner_data_start),
    .max_cluster         (scanner_max_cluster),
    .file_busy           (streamer_busy),
    .file_done           (streamer_done_pulse),       // 注意：见下方语义说明
    .file_valid          (streamer_byte_valid),
    .file_byte           (streamer_byte),
    .file_byte_offset    (),
    .fs_error            (streamer_fs_error),
    .sector_req          (streamer_sector_req),
    .sector_lba          (streamer_sector_lba),
    .sector_busy         (streamer_sector_busy),
    .sector_valid        (streamer_sector_valid),
    .sector_byte         (streamer_sector_byte),
    .sector_byte_index   (streamer_sector_byte_index),
    .sector_done         (streamer_sector_done),
    .sector_error        (streamer_sector_error)
);

// ---------- SD卡接口适配层（对接官方sd_card_top）----------
sd_sector_adapter u_adapter (
    .clk                    (clk),
    .rst_n                  (~rst),
    // 新模块侧（接仲裁器输出）
    .sector_req             (arb_sector_req),
    .sector_lba             (arb_sector_lba),
    .sector_busy            (arb_sector_busy),
    .sector_valid           (arb_sector_valid),
    .sector_byte            (arb_sector_byte),
    .sector_byte_index      (arb_sector_byte_index),
    .sector_done            (arb_sector_done),
    .sector_error           (arb_sector_error),
    // 官方sd_card_top侧
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_end        (sd_sec_read_end)
);
//=== 修改结束 ===
// key_press_debounce #(
//     .CLK_FREQ_HZ (CLK_FREQ_HZ),
//     .DEBOUNCE_MS (50),
//     .LONG_PRESS_MS (1000)
// ) u_key_next (
//     .clk        (clk),
//     .rst        (rst),
//     .button_in  (key_next),
//     .press_pulse(key_next_press),
//     .button_stable (),
//     .long_pulse()
// );

// key_press_debounce #(
//     .CLK_FREQ_HZ (CLK_FREQ_HZ),
//     .DEBOUNCE_MS (50),
//     .LONG_PRESS_MS (1000)
// ) u_key_auto (
//     .clk        (clk),
//     .rst        (rst),
//     .button_in  (key_auto),
//     .press_pulse(key_auto_press),
//     .button_stable (key_auto_stable),
//     .long_pulse(key_auto_long)
// );
//计算上一张图片编号：按有效位掩码循环向前查找，跳过缺失的图片
// function [1:0] prev_index_limited;
//     input [1:0] cur;
//     input [3:0] mask;      // scan_resource_valid
//     begin
//         if      (mask[cur - 2'd1]) prev_index_limited = cur - 2'd1;
//         else if (mask[cur - 2'd2]) prev_index_limited = cur - 2'd2;
//         else if (mask[cur - 2'd3]) prev_index_limited = cur - 2'd3;
//         else                       prev_index_limited = cur;   // 只有一张
//     end
// endfunction
// //计算下一张图片编号：按有效位掩码循环向后查找，跳过缺失的图片
// function [1:0] next_index_limited;
//     input [1:0] cur;
//     input [3:0] mask;
//     begin
//         if      (mask[cur + 2'd1]) next_index_limited = cur + 2'd1;
//         else if (mask[cur + 2'd2]) next_index_limited = cur + 2'd2;
//         else if (mask[cur + 2'd3]) next_index_limited = cur + 2'd3;
//         else                       next_index_limited = cur;   // 只有一张
//     end
// endfunction
//首张有效图片编号（PIC1缺失时从后面第一张开始）
function [1:0] first_valid_index;
    input [3:0] mask;
    begin
        if      (mask[0]) first_valid_index = 2'd0;
        else if (mask[1]) first_valid_index = 2'd1;
        else if (mask[2]) first_valid_index = 2'd2;
        else              first_valid_index = 2'd3;
    end
endfunction

//function [31:0] sector_lut;
//    input [1:0] idx;
//    begin
//        case (idx)
//            2'd0: sector_lut = img_sector0;
//            2'd1: sector_lut = img_sector1;
//            2'd2: sector_lut = img_sector2;
//            2'd3: sector_lut = img_sector3;
//            default: sector_lut = img_sector0;
//        endcase
//    end
//endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction
//=== 新增：cluster_lut和size_lut函数 ===
function [31:0] cluster_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: cluster_lut = img_cluster0;
            2'd1: cluster_lut = img_cluster1;
            2'd2: cluster_lut = img_cluster2;
            default: cluster_lut = img_cluster3;
        endcase
    end
endfunction

function [31:0] size_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: size_lut = img_size0;
            2'd1: size_lut = img_size1;
            2'd2: size_lut = img_size2;
            default: size_lut = img_size3;
        endcase
    end
endfunction
//=== 新增结束 ===
//======== 新增：统计文件数量函数 ==========
function [2:0] popcount4;
    input [3:0] value;
    begin
        popcount4 = value[0] +
                    value[1] +
                    value[2] +
                    value[3];
    end
endfunction
//=============== 扫描启动逻辑 =================
always @(posedge clk or posedge rst) begin
if (rst) begin
    scan_start_pulse <= 1'b0;
    scan_kicked      <= 1'b0;
end else begin
    scan_start_pulse <= 1'b0;
    if (!sd_init_done)
        scan_kicked <= 1'b0;
    else if (!scan_kicked && !scanner_busy) begin
        scan_start_pulse <= 1'b1;
        scan_kicked      <= 1'b1;
    end
end
end
//=============== 仲裁loader和reader =================

//wire [2:0] img_found_count;

// assign img_found_count = popcount4(scan_resource_valid);
//  // 4BANK_REMOVE_BEGIN: old on-demand/double-buffer load policy. The sequential
//  // four-image scheduler below replaces this policy. Preserve only a small
//  // scan_start generator when this block is removed.
//  // ---- 组合逻辑：发令条件，优先级 首图 > 下一张 > 上一张 > 自动播放 ----
//   wire load_slot_free = scan_complete && !load_busy && !abort_wait
//                      && (load_state == LOAD_IDLE) && !streamer_busy;
//   wire req_first = !first_image_committed;
//   wire req_next  = display_valid && next_req_pending;
//   wire req_prev  = display_valid && prev_req_pending;
//   wire req_auto  = display_valid && auto_play_en && auto_tick && (img_found_count > 3'd1);
//   wire [1:0] cmd_idx_sel = req_first ? first_valid_index(scan_resource_valid) :
//                            req_next  ? next_from_current :
//                            req_prev  ? prev_index_limited(img_idx, scan_resource_valid) :
//                                        next_from_current;
//   wire cmd_ok     = scan_resource_valid[cmd_idx_sel] && (size_lut(cmd_idx_sel) != 32'd0);
//   wire issue_load = load_slot_free && cmd_ok && (req_first | req_next | req_prev | req_auto);
//=============== 新增结束 =================
// always @(posedge clk or posedge rst) begin
//     if (rst) begin
//         wrfin_tgl_sync        <= 3'b000;
//         scan_start_pulse      <= 1'b0;
//         //load_start_pulse      <= 1'b0;
//         //load_sector           <= 32'd0;
//         scan_kicked           <= 1'b0;
//         first_image_committed <= 1'b0;
//         auto_play_en          <= 1'b0;
//         auto_cnt              <= 32'd0;
//        // img_found_count       <= 3'd0;
//         img_idx               <= 2'd0;
//         //load_idx              <= 2'd0;
//         pending_buf_idx       <= 2'd0;
//         write_buf_idx         <= 2'd0;
//         disp_buf_idx          <= 2'd0;
//         // img_cluster0           <= 32'd0;
//         // img_cluster1           <= 32'd0;
//         // img_cluster2           <= 32'd0;
//         // img_cluster3           <= 32'd0;
//         next_req_pending      <= 1'b0;
//         prev_req_pending      <= 1'b0;
//         load_busy             <= 1'b0;
//         load_timeout_cnt      <= 32'd0;
//         load_abort            <= 1'b0;
//         source_done_seen      <= 1'b0;
//         write_done_seen       <= 1'b0;
//         display_valid         <= 1'b0;
//         state_code            <= 4'd0;

//         write_abort_req  <= 1'b0;
//         abort_wait       <= 1'b0;
//         wrabort_ack_sync <= 3'b000;
//         source_busy_seen <= 1'b0;

//         write_finish_armed    <= 1'b0;
//         write_finish_baseline <= 1'b0;
//         load_error_seen       <= 1'b0;
//         retry_count          <= 1'b0;
//     end else begin
//         wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
//         wrabort_ack_sync <= {wrabort_ack_sync[1:0], write_abort_ack};
//         state_code       <= {2'b0 , img_idx} + 4'd1;
//         scan_start_pulse <= 1'b0;
//         //load_cmd_pulse <= 1'b0;
//         //load_abort       <= 1'b0;
//         if(load_error && !load_error_seen) begin
//               load_error_seen <= 1'b1;

//               if (retry_count < MAX_RETRIES) begin
//                   retry_count <= retry_count + 1'b1;

//                   // 清理上一次加载状态
//                   load_busy          <= 1'b1;
//                   source_done_seen   <= 1'b0;
//                   write_done_seen    <= 1'b0;
//                   source_busy_seen   <= 1'b0;
//                   write_finish_armed <= 1'b0;

//                   // 下一次采样时重新启动 bmp_read
//                   //load_cmd_pulse <= 1'b1;
//                   //load_cmd_idx   <= load_idx;
//               end
//               else begin
//                   // 重试次数用完，放弃当前图片
//                   load_busy       <= 1'b0;
//                   retry_count     <= 2'd0;
//                   load_error_seen <= 1'b0;

//                   // 这里保持当前显示 buffer，不切换到失败 buffer
//               end
//           end

//         if (!sd_init_done) begin
//             scan_kicked           <= 1'b0;
//             first_image_committed <= 1'b0;
//             auto_play_en          <= 1'b0;
//             auto_cnt              <= 32'd0;
//             //img_found_count       <= 3'd0;
//             img_idx               <= 2'd0;
//             //load_idx              <= 2'd0;
//             pending_buf_idx       <= 2'd0;
//             write_buf_idx         <= 2'd0;
//             disp_buf_idx          <= 2'd0;
//             // img_sector0           <= 32'd0;
//             // img_sector1           <= 32'd0;
//             // img_sector2           <= 32'd0;
//             // img_sector3           <= 32'd0;
//            // next_req_pending      <= 1'b0;
//             //prev_req_pending      <= 1'b0;
//             load_busy             <= 1'b0;
//             load_timeout_cnt      <= 32'd0;
//             //load_abort            <= 1'b0;
//             //source_done_seen      <= 1'b0;
//             //write_done_seen       <= 1'b0;
//             display_valid         <= 1'b0;
//             state_code            <= 4'd0;
//             write_abort_req       <= 1'b0;
//             //abort_wait            <= 1'b0;
//             source_busy_seen      <= 1'b0;
//            // write_finish_armed    <= 1'b0;
//         end else begin
//             // 扫描阶段缓存前 4 张图的起始 sector
//             // if (scan_found_valid) begin
//             //     case (img_found_count)
//             //         3'd0: img_sector0 <= scan_found_sector;
//             //         3'd1: img_sector1 <= scan_found_sector;
//             //         3'd2: img_sector2 <= scan_found_sector;
//             //         3'd3: img_sector3 <= scan_found_sector;
//             //         default: ;
//             //     endcase

//             //     if (img_found_count < 3'd4)
//             //         img_found_count <= img_found_count + 3'd1;
//             // end

//             // 源图读取完成：直接使用流读器的完成脉冲，且无文件系统错误、头校验通过
//             if (load_busy && streamer_done_pulse &&
//                 (streamer_fs_error == 8'h00) && (byte_state == 2'd2))
//                 source_done_seen <= 1'b1;

//             // // 当前加载的写请求被 SDRAM 域接受后，记录完成 toggle 基线。
//             // if (load_busy && write_req_ack_sync && !write_finish_armed) begin
//             //     write_finish_baseline <= wrfin_tgl_sync[2];
//             //     write_finish_armed    <= 1'b1;
//             // end

//             // // 只接受武装之后发生的 toggle 变化。
//             // if (load_busy && write_finish_armed &&
//             //     (wrfin_tgl_sync[2] != write_finish_baseline)) begin
//             //     write_done_seen    <= 1'b1;
//             //     write_finish_armed <= 1'b0;
//             // end

//             // 只有“源图送完 + 整帧写完”都满足，才提交新图并切换显示缓冲区
// //             if (abort_wait) begin
// //       // 等待 SDRAM 写状态机和 FIFO 完成清理
// //       load_timeout_cnt <= 32'd0;
// //       source_done_seen <= 1'b0;
// //       write_done_seen  <= 1'b0;
// //       source_busy_seen <= 1'b0;
// //       write_finish_armed    <= 1'b0;
// //       write_finish_baseline <= wrfin_tgl_sync[2];
// //       if (wrabort_ack_sync[2]) begin
// //           write_abort_req <= 1'b0;
// //           abort_wait      <= 1'b0;
// //           load_busy       <= 1'b0;
// //       end
// //   end
//   else if (load_busy && source_done_seen && write_done_seen) begin
//       // 图片源读取和 SDRAM 写入均完成，提交显示缓冲区
//       load_busy             <= 1'b0;
//       load_timeout_cnt      <= 32'd0;
//       source_done_seen      <= 1'b0;
//       write_done_seen       <= 1'b0;
//       disp_buf_idx          <= pending_buf_idx;
//       img_idx               <= load_idx;
//       display_valid         <= 1'b1;
//       first_image_committed <= 1'b1;
//       source_busy_seen      <= 1'b0;
//       //write_finish_armed    <= 1'b0;
//   end
//   else if (load_busy) begin
//       if (load_timeout_cnt >= LOAD_TIMEOUT_CYCLES - 1) begin
//           load_timeout_cnt <= 32'd0;
//           source_done_seen <= 1'b0;
//           write_done_seen  <= 1'b0;
//           source_busy_seen <= 1'b0;
//           // load_abort 是给 bmp_read 的单周期脉冲
//           //load_abort      <= 1'b1;
//           // write_abort_req 必须保持到收到 write_abort_ack
//           write_abort_req <= 1'b1;
//           abort_wait      <= 1'b1;

//          // write_finish_armed    <= 1'b0;
//       end
//       else begin
//           load_timeout_cnt <= load_timeout_cnt + 32'd1;
//       end
//   end
//   else begin
//       load_timeout_cnt <= 32'd0;
//   end

//             // 上电后自动发起一次“扫描前 4 张 BMP”
//             if (!scan_kicked && !streamer_busy && Sdr_init_done) begin
//                 scan_start_pulse      <= 1'b1;
//                 scan_kicked           <= 1'b1;
//                 first_image_committed <= 1'b0;
//                 auto_play_en          <= 1'b0;
//                 auto_cnt              <= 32'd0;
//                // img_found_count       <= 3'd0;
//                 img_idx               <= 2'd0;
//                 //load_idx              <= 2'd0;
//                 pending_buf_idx       <= 2'd0;
//                 write_buf_idx         <= 2'd0;
//                 disp_buf_idx          <= 2'd0;
//                 next_req_pending      <= 1'b0;
//                 prev_req_pending      <= 1'b0;
//                 display_valid         <= 1'b0;
//                 load_busy             <= 1'b0;
//                 source_done_seen      <= 1'b0;
//                 write_done_seen       <= 1'b0;
//                 source_busy_seen      <= 1'b0;
//                 //write_finish_armed    <= 1'b0;
//             end else begin
                // // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                // if (next_event && scan_complete && (img_found_count > 3'd0))
                //     next_req_pending <= 1'b1;
                // // 忙的时候也只记 1 次“上一张”请求，不会累积成连跳两张
                // if (prev_event && scan_complete && (img_found_count > 3'd0))
                //     prev_req_pending <= 1'b1;
                // // 自动播放开/关
                // if (auto_toggle_event && scan_complete && (img_found_count > 3'd1)) begin
                //     auto_play_en <= ~auto_play_en;
                //     auto_cnt     <= 32'd0;
                // end

                // // 自动播放 1s 计数：只有当前没有写图任务时才计时
                // if (scan_complete && auto_play_en && display_valid && !load_busy && first_image_committed && (img_found_count > 3'd1)) begin
                //     if (auto_tick)
                //         auto_cnt <= 32'd0;
                //     else
                //         auto_cnt <= auto_cnt + 32'd1;
                // end else begin
                //     auto_cnt <= 32'd0;
                // end


                // if (issue_load) begin
                //     load_cmd_pulse     <= 1'b1;
                //     load_cmd_idx       <= cmd_idx_sel;
                //     pending_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);  // display_valid=0 时返回 0，首图也适用
                //     write_buf_idx      <= next_buf_lut(disp_buf_idx, display_valid);
                //     load_busy          <= 1'b1;
                //     source_done_seen   <= 1'b0;
                //     write_done_seen    <= 1'b0;
                //     write_finish_armed <= 1'b0;
                //     auto_cnt           <= 32'd0;
                //     retry_count        <= 2'd0;
                //     load_error_seen    <= 1'b0;
                //     if (req_first | req_next) next_req_pending <= 1'b0;
                //     else if (req_prev)        prev_req_pending <= 1'b0;
                // end
                // // 目标图片无效（大小为0等）：丢弃该请求，保持当前显示，避免请求永久挂起
                // else if (load_slot_free && !cmd_ok && !req_first) begin
                //     if (req_next)      next_req_pending <= 1'b0;
                //     else if (req_prev) prev_req_pending <= 1'b0;
                // end
                // // 首图自动加载到 buffer0
                // if (scan_complete && !first_image_committed && !streamer_busy && !load_busy && (img_found_count != 3'd0)) begin
                //     //load_idx         <= 2'd0;
                //     // load_cluster      <= cluster_lut(load_idx);
                //     // load_file_size    <= size_lut(load_idx);
                //     load_cmd_pulse   <= 1'b1;              
                //     load_cmd_idx     <= 2'd0;
                //     pending_buf_idx  <= 2'd0;
                //     write_buf_idx    <= 2'd0;
                //     //load_start_pulse <= 1'b1;
                //     load_busy        <= 1'b1;
                //     source_done_seen <= 1'b0;
                //     write_done_seen  <= 1'b0;
                //     next_req_pending <= 1'b0;
                //     auto_cnt         <= 32'd0;
                //     source_busy_seen <= 1'b0;
                //     write_finish_armed    <= 1'b0;
                //     load_error_seen         <= 1'b0;
                //     retry_count          <= 1'b0;
                // end
                // // 手动下一张优先：写到“非当前显示”的另一块 buffer
                // else if (scan_complete && !streamer_busy && display_valid && !load_busy && next_req_pending && (img_found_count != 3'd0)) begin
                //     // load_idx         <= next_from_current;
                //     // load_cluster      <= cluster_lut(load_idx);
                //     // load_file_size    <= size_lut(load_idx);
                //     load_cmd_pulse   <= 1'b1;              
                //     load_cmd_idx     <= 2'd0;
                //     pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                //     write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                //     //load_start_pulse <= 1'b1;
                //     load_busy        <= 1'b1;
                //     source_done_seen <= 1'b0;
                //     write_done_seen  <= 1'b0;
                //     next_req_pending <= 1'b0;
                //     auto_cnt         <= 32'd0;
                //     source_busy_seen <= 1'b0;
                //     write_finish_armed    <= 1'b0;
                //     load_error_seen         <= 1'b0;
                //     retry_count          <= 1'b0;
                // end
                // // 手动上一张优先：
                // else if(scan_complete && !streamer_busy && display_valid && !load_busy && prev_req_pending && (img_found_count != 3'd0)) begin
                //     // load_idx         <= prev_index_limited(img_idx, img_found_count);
                //     // load_cluster      <= cluster_lut(load_idx);
                //     // load_file_size    <= size_lut(load_idx);
                //     load_cmd_pulse   <= 1'b1;              
                //     load_cmd_idx     <= 2'd0;
                //     pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                //     write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                //     //load_start_pulse <= 1'b1;
                //     load_busy        <= 1'b1;
                //     source_done_seen <= 1'b0;
                //     write_done_seen  <= 1'b0;
                //     prev_req_pending <= 1'b0;
                //     auto_cnt         <= 32'd0;
                //     source_busy_seen <= 1'b0;
                //     write_finish_armed    <= 1'b0;
                //     load_error_seen         <= 1'b0;
                //     retry_count          <= 1'b0;
                // end
                // // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                // else if (scan_complete && !streamer_busy && display_valid && !load_busy && auto_play_en && auto_tick && (img_found_count > 3'd1)) begin
                //     // load_idx         <= next_from_current;
                //     // load_cluster      <= cluster_lut(load_idx);
                //     // load_file_size    <= size_lut(load_idx);
                //     load_cmd_pulse   <= 1'b1;              
                //     load_cmd_idx     <= 2'd0;
                //     pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                //     write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                //     //load_start_pulse <= 1'b1;
                //     load_busy        <= 1'b1;
                //     source_done_seen <= 1'b0;
                //     write_done_seen  <= 1'b0;
                //     auto_cnt         <= 32'd0;
                //     source_busy_seen <= 1'b0;
                //     write_finish_armed    <= 1'b0;
                //     load_error_seen         <= 1'b0;
                //     retry_count          <= 1'b0;
                // end
//             end
//         end
//     end
// end
// 4BANK_REMOVE_END: old on-demand/double-buffer load policy.
//=== 加载图片调度状态机（上电自动加载 4 张图片）===
reg loader_done_seen;   // loader 写完（成功或失败都会给 load_done 脉冲）
  reg source_done_seen;   // streamer 读完文件（load_done_r 脉冲）
reg load_done_r; // 4BANK_REWIRE: rename to source_done; it is not loader load_done
always @(posedge clk or posedge rst) begin
    if(rst) begin
        load_ctrl_state <= 2'd0;
        load_ctrl_idx   <= 2'd0;
        load_ctrl_start <= 1'b0;
        loader_done_seen <= 1'b0;
        source_done_seen <= 1'b0;
    end else begin
        load_ctrl_start <= 1'b0;

          // 两个完成信号先后顺序不固定，分别锁存
          if (load_done)   loader_done_seen <= 1'b1;
          if (load_done_r) source_done_seen <= 1'b1;
        case(load_ctrl_state) 
        LOAD_CTRL_IDLE: begin// IDLE：扫描完成后开始加载第 0 张
             load_ctrl_start <= 1'b0;
                if (scan_complete) begin
                    load_ctrl_state <= LOAD_CTRL_LOADING;
                    load_ctrl_idx   <= 2'd0;
                end
        end
        LOAD_CTRL_LOADING: begin// LOADING：发起加载
            if(!scan_resource_valid[load_ctrl_idx] || size_lut(load_ctrl_idx) == 0) begin
            if (load_ctrl_idx == 2'd3)
                    load_ctrl_state <= LOAD_CTRL_DONE;
                else begin
                    load_ctrl_idx   <= load_ctrl_idx + 2'd1;
                    //load_ctrl_state <= LOAD_CTRL_LOADING;
                end
            end
            else if(load_state == LOAD_IDLE && !load_busy && !load_ctrl_start)begin
                load_ctrl_start <= 1'b1;
                loader_done_seen <= 1'b0;
                source_done_seen <= 1'b0;
                load_ctrl_state <= LOAD_CTRL_WAIT_DONE;
            end 
            end
        LOAD_CTRL_WAIT_DONE: begin // WAIT_DONE：等当前图片加载完成
            load_ctrl_start <= 1'b0;
                 if (loader_done_seen && source_done_seen) begin
                    if(load_ctrl_idx == 2'd3)begin
                        load_ctrl_state <= LOAD_CTRL_DONE;
                    end else begin
                        load_ctrl_idx   <= load_ctrl_idx + 2'd1;
                        load_ctrl_state <= LOAD_CTRL_LOADING;
                    end
                    
                 end
        end
        LOAD_CTRL_DONE: begin
            //load_ctrl_start <= 1'b0;
        end
        endcase
    end
end
// 调度层输出 -> 执行层输入
assign load_cmd_pulse = load_ctrl_start; // 4BANK_REWIRE: reg has a procedural driver elsewhere; choose one owner
assign load_image_index = load_idx;     // 4BANK_REWIRE: reg has a procedural driver elsewhere; choose one owner
assign load_start = load_start_pulse;
// =====加载一张图片 执行状态机
// =====协调"申请写缓冲区 
//→ 等 SDRAM 准备好 
//→ 启动流读器读文件" 这个时序。

always @(posedge clk or posedge rst) begin
    if(rst) begin
        load_state <= LOAD_IDLE;
        load_idx   <= 2'd0;
        load_done_r <=1'b0;
        load_start_pulse <= 1'b0;
       
    end
    else begin
        load_start_pulse <= 1'b0;
        
         case(load_state) // 4BANK_REWIRE: orphan "else" is a syntax error after load_abort if-block was commented
            LOAD_IDLE: begin
                load_done_r <= 1'b0;
                //条件1: load_cmd_pulse              ← "有人要加载"
                //条件2: scan_complete               ← "扫描完了，信息可用"
                // 条件3: scan_resource_valid[idx]    ← "这张图存在"
                // 条件4: size_lut(idx) != 0          ← "这张图不是空的"
                // ───────────────────────────────────
                // 全部满足 → 开始加载
                if(load_cmd_pulse && scan_complete && scan_resource_valid[load_cmd_idx] && size_lut(load_cmd_idx)!=32'd0) begin
                    //write_req_r <= 1'b1;//开始请求切换/清空写缓冲区
                    load_start_pulse <= 1'b1;
                    load_state  <= LOAD_STREAMING;
                    //先锁存本次文件参数
                    load_idx <= load_cmd_idx;
                    load_cluster <= cluster_lut(load_cmd_idx);
                    load_file_size <= size_lut(load_cmd_idx);
                end 
            end
            // LOAD_WAIT_ACK: begin
            //     // write_req 必须保持到 ACK 到来
            //     write_req_r <= 1'b1;
            //     if(write_req_ack_sync) begin
            //         write_req_r <= 1'b0;
            //         load_start_pulse <= 1'b1;
            //         load_state       <= LOAD_STREAMING;
            //     end
            // end
            LOAD_STREAMING: begin
               // write_req_r <= 1'b0;
                if (streamer_done_pulse) begin
                    load_state <= LOAD_IDLE;
                    load_done_r <= 1'b1; // ← 新增：告诉调度层"这张读完了"
                end 

            end
            default: begin
                load_state <= LOAD_IDLE;
                //write_req_r <= 1'b0;
                load_start_pulse <= 1'b0;
                load_done_r <= 1'b0;
            end
        endcase
    end

end
assign load_all_done = (load_ctrl_state == LOAD_CTRL_DONE);

//assign load_done = load_done_r; // 4BANK_REMOVE: load_done is an INPUT from loader; never drive it here
// bmp_read bmp_read_m0(
//     .clk                    (clk),
//     .rst                    (rst),
//     .ready                  (bmp_ready),

//     .scan_start             (scan_start_pulse),
//     .scan_start_sector      (SCAN_START_SECTOR),
//     .scan_max_sector        (SCAN_MAX_SECTOR),
//     .scan_target_count      (SCAN_TARGET_COUNT),
//     .scan_done              (scan_done),
//     .scan_found_valid       (scan_found_valid),
//     .scan_found_sector      (scan_found_sector),
//     .scan_found_total       (scan_found_total),

//     .load_start             (load_start_pulse),
//     .load_abort             (load_abort),
//     .load_sector            (load_sector),

//     .sd_init_done           (sd_init_done),
//     .state_code             (state_code_i),
//     .write_req              (write_req),
//     .write_req_ack          (write_req_ack),
//     .sd_sec_read            (sd_sec_read),
//     .sd_sec_read_addr       (sd_sec_read_addr),
//     .sd_sec_read_data       (sd_sec_read_data),
//     .sd_sec_read_data_valid (sd_sec_read_data_valid),
//     .sd_sec_read_end        (sd_sec_read_end),
//     .bmp_data_wr_en         (bmp_data_wr_en),
//     .bmp_data               (bmp_data),
//     .bmp_error              (bmp_error),
//     .load_error             (load_error),
//     .bmp_width              ({16'd0, BMP_WIDTH}),
//     .bmp_height             ({16'd0, BMP_HEIGHT})
// );

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

// module key_press_debounce #(
//     parameter integer CLK_FREQ_HZ = 100_000_000,
//     parameter integer DEBOUNCE_MS = 20,
//     parameter integer LONG_PRESS_MS = 1000
// )(
//     input  wire clk,
//     input  wire rst,
//     input  wire button_in,    // 默认：松开=1，按下=0
//     output reg  press_pulse,
//     output reg long_pulse,     //长按到达脉冲（新增）
//     output reg button_stable   //发送按键稳定信号
// );

// localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
// localparam integer LONG_PRESS_CYCLES = (CLK_FREQ_HZ / 1000) * LONG_PRESS_MS;

// reg button_sync0;
// reg button_sync1;
// reg [31:0] cnt;
// reg [31:0] long_press_cnt;//长按计数器（新增）
// reg long_press_marked;
// //reg key_auto_stable;      //保存消抖后的稳定状态 （1=松开 0=按下）

// always @(posedge clk or posedge rst) begin
//     if (rst) begin
//         button_sync0  <= 1'b1;
//         button_sync1  <= 1'b1;
//         button_stable <= 1'b1;
//         cnt           <= 32'd0;
//         press_pulse   <= 1'b0;
//         long_pulse    <= 1'b0;
//         long_press_cnt<= 32'd0;
//         long_press_marked <= 1'b0;
//     end else begin
//         button_sync0 <= button_in;
//         button_sync1 <= button_sync0;
//         press_pulse  <= 1'b0;
//         long_pulse  <= 1'b0;
//         //电平信号稳定
//         if (button_sync1 == button_stable) begin
//             cnt <= 32'd0;

//             /* 长按检测 */
//         //稳定按下
//         if(!button_stable) begin
//             if(!long_press_marked) begin
//             if (long_press_cnt == LONG_PRESS_CYCLES - 1) begin//记录是否到达长按的标准 只输出一个周期的脉冲信号
//                     long_pulse <= 1'b1;         //触发长按脉冲信号
//                     long_press_marked <= 1'b1;  //长按结束
//                     long_press_cnt <= LONG_PRESS_CYCLES;    //长按有效后锁住 防止触发下一次功能
//             end else if(long_press_cnt < LONG_PRESS_CYCLES)begin
//                 long_press_cnt <= long_press_cnt + 32'd1;
//             end
        
//             end
        
//         end
//         else long_press_cnt <=32'd0;

//         //电平信号发生变化
//         end else begin
//             if (cnt >= DEBOUNCE_CYCLES - 1) begin               //已消抖
//                 button_stable <= button_sync1;                  //进入稳定状态
//                 cnt           <= 32'd0;                         //重新计数消抖
//                  if(button_stable && !button_sync1) begin       //只检测到下降沿 先给个标志位 看看是不是长按
//                     long_press_cnt    <= 32'd0;                 //计数清零 开始计数
//                     long_press_marked <= 1'b0;                  //进入长按
//                  end
//                  else if (!button_stable && button_sync1) begin //检测上升沿才会触发短按信号
//                      if(!long_press_marked)                     //确认不是长按 触发短按逻辑
//                      press_pulse <= 1'b1;
                    
//                      long_press_marked <= 1'b1;
//                      long_press_cnt    <= 32'd0;
//                  end
//         end
//         else begin      //持续记录消抖计数
//                  cnt <= cnt + 32'd1;
                 
//              end

        
        
//     end
// end
// end

// endmodule
