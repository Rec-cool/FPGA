`timescale 1ns/1ps
// B1 顶层曲目逻辑：歌曲表(读出晚 1 拍) + track_idx 按 pcm_count 回绕 + restart 延后 2 拍。
// 检查播放器每次 IDLE→REQ 锁存的 cur_lba / 扇区数都等于当前 track_idx 对应的表项。
module tb;
    reg clk = 0, rst_n = 0; always #5 clk = ~clk;      // sd_card_clk
    reg vclk = 0; always #20 vclk = ~vclk;             // video_clk
    // ---- 歌曲表模型（同扫描器：读口每拍寄存）----
    reg [55:0] table_m [0:15];
    reg [4:0]  pcm_count = 0;
    reg [31:0] pcm_rd_lba; reg [23:0] pcm_rd_sectors;
    reg  [3:0]  track_idx;
    always @(posedge clk) {pcm_rd_sectors, pcm_rd_lba} <= table_m[track_idx];
    // ---- 与 top_tf_hdmi_audio.v 相同的写法 ----
    reg fade_next_event = 0, jump_pending = 0;
    wire fade_step_event = fade_next_event & ~jump_pending;
    wire [31:0] track_lba = (pcm_count != 5'd0) ? pcm_rd_lba : 32'd0;
    wire [31:0] track_sec = {8'd0, pcm_rd_sectors};
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)               track_idx <= 4'd0;
        else if (fade_step_event) track_idx <= ({1'b0, track_idx} + 5'd1 >= pcm_count) ? 4'd0 : track_idx + 4'd1;
    end
    reg [1:0] wav_restart_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) wav_restart_d <= 2'b00;
        else        wav_restart_d <= {wav_restart_d[0], fade_next_event};
    end
    // ---- 播放器 + 扇区模型 ----
    wire sd_req; wire [31:0] sd_lba;
    reg busy = 0, valid = 0, done = 0; reg [7:0] sbyte = 0; reg [8:0] sidx = 0;
    reg play_enable = 0;
    wav_stream_player #(.ADDR_WIDTH(12), .SAMPLES_PER_SECTOR(256)) u (
        .wr_clk(clk), .wr_rst_n(rst_n), .play_enable(play_enable), .restart(wav_restart_d[1]),
        .start_lba(track_lba), .total_sectors(track_sec),
        .sd_req(sd_req), .sd_lba(sd_lba), .sd_busy(busy), .sd_valid(valid), .sd_byte(sbyte),
        .sd_byte_index(sidx), .sd_done(done), .sd_error(8'd0),
        .rd_clk(vclk), .rd_rst_n(rst_n), .sample_tick(1'b0), .sample_out(), .sample_valid(),
        .sample_ready(1'b1), .gain(8'd255), .sample_counter(), .stream_active(), .stream_end(), .buffer_low());
    always @(posedge clk) if (sd_req && !busy) begin : serve
        busy <= 1; repeat (2 + ($urandom & 7)) @(posedge clk);
        for (int i = 0; i < 512; i++) begin valid <= 1; sbyte <= i; sidx <= i; @(posedge clk); valid <= 0; end
        done <= 1; @(posedge clk); done <= 0; busy <= 0;
    end
    // ---- 检查 ----
    integer errs = 0, starts = 0, wraps = 0, ends = 0;
    reg [2:0] ws_d;
    always @(posedge clk) begin
        ws_d <= u.wstate;
        if (rst_n && ws_d == 3'd0 && u.wstate == 3'd1) begin
            starts++;
            if (u.cur_lba !== table_m[track_idx][31:0]) begin
                errs++; $display("MISMATCH t=%0t idx=%0d cur_lba=%0d exp=%0d", $time, track_idx, u.cur_lba, table_m[track_idx][31:0]);
            end
        end
    end
    // 结束（WS_END）时扇区数核对
    always @(posedge clk) if (rst_n && ws_d == 3'd2 && u.wstate == 3'd4 &&
                              u.sectors_read != table_m[track_idx][55:32]) begin
        errs++; $display("MISMATCH end t=%0t idx=%0d read=%0d exp=%0d", $time, track_idx, u.sectors_read, table_m[track_idx][55:32]);
    end
    always @(posedge clk) if (rst_n && ws_d == 3'd2 && u.wstate == 3'd4) ends++;
    always @(posedge clk) if (fade_step_event && track_idx + 1 >= pcm_count) wraps++;

    task automatic pulse(bit jump);
        @(posedge clk); jump_pending <= jump; fade_next_event <= 1;
        @(posedge clk); fade_next_event <= 0; jump_pending <= 0;
    endtask
    initial begin
        for (int i = 0; i < 16; i++) table_m[i] = {24'd3 + i, 32'd1000 * (i + 1)};
        repeat (5) @(posedge clk); rst_n = 1;
        // 无歌：播放器应保持空闲
        play_enable <= 1; repeat (200) @(posedge clk);
        if (u.wstate != 3'd0) begin errs++; $display("MISMATCH no-song but wstate=%0d", u.wstate); end
        play_enable <= 0; repeat (20) @(posedge clk);
        pcm_count = 3; play_enable <= 1;
        for (int n = 0; n < 40; n++) begin
            repeat ($urandom_range(5, 6000)) @(posedge clk);  // 覆盖 REQ/FILL/END 各状态时切歌
            pulse(($urandom & 3) == 0);                       // 1/4 概率是跳图（不换歌，仍重启）
        end
        repeat (20000) @(posedge clk);
        pcm_count = 16;
        for (int n = 0; n < 40; n++) begin repeat ($urandom_range(5, 3000)) @(posedge clk); pulse(0); end
        repeat (5000) @(posedge clk);
        $display("DONE starts=%0d ends=%0d wraps=%0d errs=%0d", starts, ends, wraps, errs);
        $finish;
    end
endmodule
