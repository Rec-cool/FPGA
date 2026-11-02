`timescale 1ns/1ps
module tb_wav_e2e;
  reg sd_clk = 0, v_clk = 0;
  always #5  sd_clk = ~sd_clk;   // 100 MHz
  always #20 v_clk  = ~v_clk;    // 25 MHz
  reg rst_n = 0, play = 0;
  initial begin #200 rst_n = 1; #1000 play = 1; end

  localparam [31:0] START = 32'd42080;
  // ---------------- SD 引擎模型（时序仿照 sd_card_sec_read_write） ----------------
  wire        sd_sec_read; wire [31:0] sd_sec_read_addr;
  reg         rd_valid = 0; wire rd_end; reg [7:0] rd_data = 0;
  reg  [1:0]  st = 0; reg [15:0] cnt = 0; reg [9:0] idx = 0; reg [31:0] lba = 0;
  integer     bad_lba = 0, reads = 0;
  assign rd_end = (st == 3);
  always @(posedge sd_clk) begin
    rd_valid <= 0;
    case (st)
      0: if (sd_sec_read) begin lba <= sd_sec_read_addr; cnt <= 0; idx <= 0; st <= 1; reads = reads + 1; end
      1: if (cnt == 300) begin cnt <= 0; st <= 2; end else cnt <= cnt + 1;      // CMD17 开销
      2: if (cnt == 31) begin                                                  // 25MHz SPI：32 拍/字节
           cnt <= 0; rd_valid <= 1;
           rd_data <= idx[0] ? (lba[6:0] + 7'd1) : idx[8:1];
           if (idx == 511) st <= 3; idx <= idx + 1;
         end else cnt <= cnt + 1;
      3: st <= 0;
    endcase
  end

  wire s_req, s_busy, s_valid, s_done; wire [31:0] s_lba; wire [7:0] s_byte, s_err; wire [8:0] s_idx;
  sd_sector_adapter u_ad (.clk(sd_clk), .rst_n(rst_n),
    .sector_req(s_req), .sector_lba(s_lba), .sector_busy(s_busy), .sector_valid(s_valid),
    .sector_byte(s_byte), .sector_byte_index(s_idx), .sector_done(s_done), .sector_error(s_err),
    .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data_valid(rd_valid), .sd_sec_read_data(rd_data), .sd_sec_read_end(rd_end));

  // ---------------- 48k tick ----------------
  reg [24:0] acc = 0; wire tick = (acc >= 25_000_000 - 48_000);
  always @(posedge v_clk) acc <= tick ? acc - (25_000_000 - 48_000) : acc + 48_000;

  wire signed [15:0] smp; wire sv, sr, act;
  wav_stream_player #(.ADDR_WIDTH(12), .SAMPLES_PER_SECTOR(256)) dut (
    .wr_clk(sd_clk), .wr_rst_n(rst_n), .play_enable(play),
    .start_lba(START), .total_sectors(32'd50956),
    .sd_req(s_req), .sd_lba(s_lba), .sd_busy(s_busy), .sd_valid(s_valid), .sd_byte(s_byte),
    .sd_byte_index(s_idx), .sd_done(s_done), .sd_error(s_err),
    .rd_clk(v_clk), .rd_rst_n(rst_n), .sample_tick(tick),
    .sample_out(smp), .sample_valid(sv), .sample_ready(sr),
    .sample_counter(), .stream_active(act), .stream_end(), .buffer_low());

  // ---------------- 下游：真实 media_hdmi_audio_bridge ----------------
  reg [9:0] x = 0, y = 0;
  always @(posedge v_clk) begin x <= (x == 799) ? 0 : x + 1; if (x == 799) y <= (y == 524) ? 0 : y + 1; end
  wire de = (x < 640) && (y < 480);
  wire hs = ~((x >= 656) && (x < 752));
  wire vs = ~((y >= 490) && (y < 492));
  reg de_d = 0; reg [9:0] vx = 0;
  always @(posedge v_clk) begin de_d <= de; vx <= (de && !de_d) ? 10'd1 : (vx == 799 ? 0 : vx + 1); end
  wire mv, mr; wire signed [15:0] ml;
  media_hdmi_audio_bridge u_br (.pixel_clk(v_clk), .pixel_rst_n(rst_n), .audio_enable(1'b1),
    .video_hsync(hs), .video_vsync(vs), .video_de(de), .video_x(vx), .video_rgb(24'h808080),
    .media_id(2'd0), .volume(8'd220),
    .wav_valid(sv), .wav_active(act), .wav_left(smp), .wav_right(smp), .wav_ready(sr),
    .channel0_symbol(), .channel1_symbol(), .channel2_symbol(), .sequence_error(),
    .tone_overflow(), .pcm_contract_error(), .blip_active(), .pcm_tap_valid(mv), .pcm_tap_left(ml));
  assign mr = 1'b1;
  integer ticks = 0, t0 = 0, n0 = 0; reg first = 0;
  always @(posedge v_clk) if (tick) ticks = ticks + 1;
  // ---------------- 检查 ----------------
  integer gap_n = 0, acc_n = 0, zero_n = 0, good = 0, wrong = 0, k = 0;
  reg [15:0] exp;
  always @(posedge v_clk) if (mv && mr) begin
    acc_n = acc_n + 1;
    if (ml == 0) begin zero_n = zero_n + 1; if (k > 0) gap_n = gap_n + 1; end
    else begin
      exp = {((START + k/256) & 32'h7f) + 8'd1, 8'(k % 256)};
      if (ml == exp) good = good + 1;
      else begin wrong = wrong + 1; if (wrong <= 8) $display("[%0t] sample#%0d got %h exp %h", $time, k, ml, exp); end
      k = k + 1;
      if (!first) begin first = 1; t0 = ticks; n0 = acc_n; end
    end
  end
  always @(posedge sd_clk) if (s_req && sd_sec_read_addr !== s_lba && 0) ;
  initial begin
    #200_000_000;
    $display("steady-state: ticks %0d, samples into HDMI %0d  => effective rate %0.1f Hz",
             ticks - t0, acc_n - n0, 48000.0 * (acc_n - n0) / (ticks - t0));
    $display("sd_reads %0d, accepted %0d (silence %0d / good %0d / wrong %0d) midgap_silence %0d, active=%b",
             reads, acc_n, zero_n, good, wrong, gap_n, act);
    $finish;
  end
endmodule
