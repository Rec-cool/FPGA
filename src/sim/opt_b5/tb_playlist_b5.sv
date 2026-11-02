`timescale 1ns/1ps
// B5 功能仿真：track_playlist + 真实 wav_stream_player + 扇区模型（长按判定在 tb_router_b5 里单独测）。
// 淡入淡出步长、长按时间按比例缩短；增益跨域写法与 top_tf_hdmi_audio.v 相同。
module tb;
    reg clk = 0;  always #5  clk  = ~clk;     // sd_card_clk 100MHz
    reg vclk = 0; always #20 vclk = ~vclk;    // video_clk 25MHz
    reg rst_n = 0;
    localparam integer STEP = 16;             // 每步 16 拍（实机 117647）
    localparam integer HOLD = 2000;           // 长按 2000 拍（实机 1 s）

    // ---------------- 歌曲表模型（读口寄存 1 拍，同扫描器）----------------
    reg [55:0] table_m [0:15];
    reg [4:0]  pcm_count = 0;
    wire [3:0] track_idx;
    reg [31:0] pcm_rd_lba; reg [23:0] pcm_rd_sectors;
    always @(posedge clk) {pcm_rd_sectors, pcm_rd_lba} <= table_m[track_idx];
    wire [31:0] track_lba = (pcm_count != 5'd0) ? pcm_rd_lba : 32'd0;
    wire [31:0] track_sec = {8'd0, pcm_rd_sectors};

    // ---------------- 按键 ----------------
    reg key3_long = 0;      // 即顶层 key_song_event（下一张键长按）
    reg mode_req = 0;

    // ---------------- 播放列表 ----------------
    reg play_enable = 0;
    wire restart, song_event, mode_event; wire [1:0] play_mode; wire [7:0] gain_gray;
    wire wav_stream_end, wav_stream_active;
    reg wav_end_v; always @(posedge vclk or negedge rst_n) if (!rst_n) wav_end_v <= 0; else wav_end_v <= wav_stream_end;
    reg wav_end_s1, wav_end_s2;
    always @(posedge clk or negedge rst_n) if (!rst_n) {wav_end_s2, wav_end_s1} <= 0; else {wav_end_s2, wav_end_s1} <= {wav_end_s1, wav_end_v};
    track_playlist #(.FADE_STEP_CYCLES(STEP)) up (
        .clk(clk), .rst_n(rst_n), .play_enable(play_enable), .pcm_count(pcm_count),
        .next_req(key3_long), .mode_req(mode_req), .stream_end(wav_end_s2),
        .track_idx(track_idx), .restart(restart), .play_mode(play_mode),
        .song_event(song_event), .mode_event(mode_event), .track_gain_gray(gain_gray));

    // ---------------- 增益跨域（同顶层）----------------
    reg [7:0] tg_gray_s1, tg_gray_s2;
    always @(posedge vclk or negedge rst_n)
        if (!rst_n) {tg_gray_s2, tg_gray_s1} <= {8'h80, 8'h80};
        else        {tg_gray_s2, tg_gray_s1} <= {tg_gray_s1, gain_gray};
    wire [7:0] track_gain;
    assign track_gain[7] = tg_gray_s2[7];
    genvar gi;
    generate for (gi = 6; gi >= 0; gi = gi - 1) begin : g_dec
        assign track_gain[gi] = track_gain[gi + 1] ^ tg_gray_s2[gi];
    end endgenerate

    // ---------------- 播放器 + 扇区模型 ----------------
    wire sd_req; wire [31:0] sd_lba;
    reg busy = 0, valid = 0, done = 0; reg [7:0] sbyte = 0; reg [8:0] sidx = 0;
    reg [3:0] tick_div = 0; always @(posedge vclk) tick_div <= tick_div + 1;
    wire sample_tick = (tick_div == 0);   // 每 16 拍一个样本，3 扇区一首约 0.5 ms
    wav_stream_player #(.ADDR_WIDTH(12), .SAMPLES_PER_SECTOR(256)) u (
        .wr_clk(clk), .wr_rst_n(rst_n), .play_enable(play_enable), .restart(restart),
        .start_lba(track_lba), .total_sectors(track_sec),
        .sd_req(sd_req), .sd_lba(sd_lba), .sd_busy(busy), .sd_valid(valid), .sd_byte(sbyte),
        .sd_byte_index(sidx), .sd_done(done), .sd_error(8'd0),
        .rd_clk(vclk), .rd_rst_n(rst_n), .sample_tick(sample_tick), .sample_out(), .sample_valid(),
        .sample_ready(1'b1), .gain(track_gain), .sample_counter(), .stream_active(wav_stream_active),
        .stream_end(wav_stream_end), .buffer_low());
    always @(posedge clk) if (sd_req && !busy) begin : serve
        busy <= 1; repeat (2 + ($urandom & 7)) @(posedge clk);
        for (int i = 0; i < 512; i++) begin valid <= 1; sbyte <= i; sidx <= i; @(posedge clk); valid <= 0; end
        done <= 1; @(posedge clk); done <= 0; busy <= 0;
    end

    // ---------------- 检查器 ----------------
    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 20) $display("ERR t=%0t %s", $time, m); endtask
    // 1) 播放器每次起播锁存的 LBA 必须等于当前 track_idx 的表项
    reg [2:0] ws_d; integer starts = 0; reg [31:0] last_start_lba;
    always @(posedge clk) begin
        ws_d <= u.wstate;
        if (rst_n && ws_d == 3'd0 && u.wstate == 3'd1) begin
            starts++; last_start_lba = u.cur_lba;
            if (u.cur_lba !== table_m[track_idx][31:0]) fail($sformatf("start lba=%0d exp=%0d idx=%0d", u.cur_lba, table_m[track_idx][31:0], track_idx));
        end
    end
    // 2) restart 只能在增益为 0 时发出
    always @(posedge clk) if (restart && up.gain != 0) fail("restart while gain!=0");
    // 3) 增益每次最多变 1（源域与接收域都查）
    reg [7:0] g_src_d = 255, g_dst_d = 255;
    always @(posedge clk) begin
        if (rst_n && (up.gain - g_src_d != 1) && (g_src_d - up.gain != 1) && up.gain != g_src_d) fail("src gain jump");
        g_src_d <= up.gain;
    end
    always @(posedge vclk) begin
        if (rst_n && (track_gain - g_dst_d != 1) && (g_dst_d - track_gain != 1) && track_gain != g_dst_d)
            fail($sformatf("dst gain jump %0d->%0d", g_dst_d, track_gain));
        g_dst_d <= track_gain;
    end
    // 4) 切歌记录
    integer song_n = 0; reg [3:0] prev_idx; reg [3:0] hist_idx [$];
    always @(posedge clk) if (song_event) begin song_n++; hist_idx.push_back(track_idx); end
    // 5) 随机模式：新曲目不等于切歌前的曲目，且不越界；统计每首被抽到的次数
    reg [3:0] idx_before; integer seen [16]; integer manual_acc = 0;
    initial for (int k = 0; k < 16; k++) seen[k] = 0;
    always @(posedge clk) begin
        if (up.state == 3'd0) idx_before <= track_idx;
        if (song_event) begin
            if ({1'b0, track_idx} >= pcm_count) fail($sformatf("idx %0d out of range %0d", track_idx, pcm_count));
            if (play_mode == 2 && pcm_count > 1) begin
                if (track_idx == idx_before) fail("RND repeated current");
                seen[track_idx]++;
            end
        end
        if (up.state == 3'd0 && up.can_switch && key3_long) manual_acc++;   // 被受理的长按
    end

    task automatic press(int cycles);   // cycles >= HOLD 视为长按，产生一拍 next_req
        @(posedge clk); if (cycles >= HOLD) begin key3_long <= 1; @(posedge clk); key3_long <= 0; end
        repeat (5) @(posedge clk);
    endtask
    task automatic chord(); @(posedge clk); mode_req <= 1; @(posedge clk); mode_req <= 0; endtask
    task automatic wait_idle(); repeat (3) @(posedge clk); wait (up.state == 3'd0); repeat (3) @(posedge clk); endtask

    integer longs = 0;
    always @(posedge clk) if (key3_long) longs++;
    // 6) 测试音屏蔽：首次起播后，送给音频桥的 wav_active|stream_end 不能再掉到 0
    reg first_started = 0; integer tone_gaps = 0;
    always @(posedge clk) if (starts > 0) first_started <= 1;
    always @(posedge vclk) if (first_started && u.pe_s2 && !(wav_stream_active | wav_stream_end)) begin
        tone_gaps++; if (tone_gaps < 3) fail("audio mux would fall back to tone");
    end
    integer ended_cnt = 0; reg end_d2 = 0;
    always @(posedge vclk) begin end_d2 <= wav_stream_end; if (wav_stream_end && !end_d2) ended_cnt++; end

    initial begin
        // 表：每首 3~6 扇区（一首约 768~1536 样本）
        for (int i = 0; i < 16; i++) table_m[i] = {24'd3 + (i % 4), 32'd1000 * (i + 1)};
        repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);

        // ---- 无歌：长按无效 ----
        play_enable <= 1; press(HOLD + 10); repeat (2000) @(posedge clk);
        if (up.state != 0 || song_n != 0 || u.wstate != 0) fail("no-song should idle");

        // ---- 3 首，顺序：开机播 0，长按 → 1，放完自动 → 2 → 0 ----
        pcm_count = 3;
        wait (starts == 1); if (last_start_lba != 1000) fail("power-up track");
        press(HOLD + 10); wait_idle();
        if (track_idx != 1) fail($sformatf("seq manual idx=%0d", track_idx));
        wait (song_n == 2); wait_idle(); if (track_idx != 2) fail("seq auto 1->2");
        wait (song_n == 3); wait_idle(); if (track_idx != 0) fail("seq wrap 2->0");
        $display("[seq] songs=%0d starts=%0d idx=%0d", song_n, starts, track_idx);

        // ---- 切到单曲循环：放完重放同一首，长按仍换下一首 ----
        chord(); @(posedge clk); if (play_mode != 1) fail("mode->ONE");
        begin automatic int n0 = song_n; wait (song_n == n0 + 2); wait_idle(); end
        if (track_idx != 0) fail("ONE should repeat idx 0");
        press(HOLD + 10); wait_idle(); if (track_idx != 1) fail("ONE manual next");
        $display("[one] songs=%0d idx=%0d", song_n, track_idx);

        // ---- 随机：不重复当前、不越界、16 首都能抽到 ----
        chord(); @(posedge clk); if (play_mode != 2) fail("mode->RND");
        pcm_count = 16; hist_idx.delete();
        for (int k = 0; k < 80; k++) begin press(HOLD + 10); wait_idle(); end
        for (int k = 0; k < 16; k++) if (seen[k] == 0) fail($sformatf("RND never picked %0d", k));
        pcm_count = 1; press(HOLD + 10); wait_idle(); if (track_idx != 0) fail("RND with 1 song");
        $display("[rnd] songs=%0d seen=%p", song_n, seen);

        // ---- 回到顺序；淡出过程中连按不影响（忙时忽略）----
        chord(); @(posedge clk); if (play_mode != 0) fail("mode->SEQ");
        pcm_count = 4;
        wait_idle();
        begin automatic int m0 = manual_acc; automatic int l0 = longs;
            press(HOLD + 10); repeat (100) @(posedge clk); press(HOLD + 10); wait_idle();
            if (longs != l0 + 2 || manual_acc != m0 + 1) fail($sformatf("busy request not ignored: longs+%0d accepted+%0d", longs - l0, manual_acc - m0));
        end
        $display("DONE songs=%0d starts=%0d ended=%0d tone_gaps=%0d errs=%0d", song_n, starts, ended_cnt, tone_gaps, errs);
        $finish;
    end
    initial begin #60ms; $display("TIMEOUT errs=%0d", errs); $finish; end
endmodule
