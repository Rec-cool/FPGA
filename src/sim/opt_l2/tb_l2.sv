`timescale 1ns/1ps
// L2 选歌验证（sd_card_clk 域）
//   A. 等价：goto_req 恒 0 时，新 track_playlist 和改动前（track_playlist_old）在随机 next/mode/放完 激励下逐拍输出一致
//   B. 功能：顶层抽出的按键块（key_blk.v）+ 新 track_playlist，按真实用法按 KEY1，逐项核对光标和跳转
module tb;
    localparam integer LONG = 5000, DEB = 1000, FADE = 2;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n = 0;
    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 40) $display("ERR t=%0t %s", $time, m); endtask

    // ---------------- A：新旧等价 ----------------
    reg a_en = 0, a_next = 0, a_mode = 0, a_end = 0; reg [4:0] a_cnt = 5'd7;
    wire [3:0] n_idx, o_idx; wire n_rs, o_rs, n_se, o_se, n_me, o_me; wire [1:0] n_pm, o_pm; wire [7:0] n_g, o_g;
    track_playlist #(.FADE_STEP_CYCLES(FADE)) an (.clk(clk), .rst_n(rst_n), .play_enable(a_en), .pcm_count(a_cnt),
        .next_req(a_next), .goto_req(1'b0), .goto_idx(4'd0), .mode_set(1'b0), .mode_set_val(2'd0), .mode_req(a_mode), .stream_end(a_end),
        .track_idx(n_idx), .restart(n_rs), .play_mode(n_pm), .song_event(n_se), .mode_event(n_me), .track_gain_gray(n_g));
    track_playlist_old #(.FADE_STEP_CYCLES(FADE)) ao (.clk(clk), .rst_n(rst_n), .play_enable(a_en), .pcm_count(a_cnt),
        .next_req(a_next), .mode_req(a_mode), .stream_end(a_end),
        .track_idx(o_idx), .restart(o_rs), .play_mode(o_pm), .song_event(o_se), .mode_event(o_me), .track_gain_gray(o_g));
    integer a_diff = 0, a_songs = 0;
    always @(posedge clk) if (rst_n) begin
        if ({n_idx, n_rs, n_pm, n_se, n_me, n_g} !== {o_idx, o_rs, o_pm, o_se, o_me, o_g}) a_diff++;
        if (n_se) a_songs++;
    end

    // ---------------- B：按键块 + 播放列表 ----------------
    reg key = 1, sw4 = 0, ld = 0; reg [4:0] cnt = 5'd5; reg b_end = 0, b_next = 0;
    wire [3:0] cursor, tidx; wire goto, rs, se; wire [1:0] pm; wire [7:0] gg;
    key_blk #(.LONG(LONG)) kb (.sd_card_clk(clk), .sdcard_rst_n(rst_n), .key_list(key), .sw4(sw4),
        .bmp_load_all_done(ld), .pcm_count(cnt), .track_idx(tidx), .cursor(cursor), .goto_req(goto));
    track_playlist #(.FADE_STEP_CYCLES(FADE)) tp (.clk(clk), .rst_n(rst_n), .play_enable(ld), .pcm_count(cnt),
        .next_req(b_next), .goto_req(goto), .goto_idx(cursor), .mode_set(1'b0), .mode_set_val(2'd0), .mode_req(1'b0), .stream_end(b_end),
        .track_idx(tidx), .restart(rs), .play_mode(pm), .song_event(se), .mode_event(), .track_gain_gray(gg));
    integer n_goto = 0;
    always @(posedge clk) if (goto) n_goto++;

    // 按一次：按住 hold 拍，带 30 拍抖动
    task automatic press(int hold);
        repeat (30) begin @(posedge clk); key <= $urandom % 2; end
        key <= 0; repeat (hold) @(posedge clk);
        repeat (30) begin @(posedge clk); key <= $urandom % 2; end
        key <= 1; repeat (DEB + 100) @(posedge clk);
    endtask
    task automatic short_press(); press(DEB + 500); endtask
    task automatic long_press();  press(LONG + DEB + 300); endtask
    // 等切歌完成（淡出 + 换歌 + 淡入）
    task automatic settle(); repeat (255 * FADE * 2 + 2000) @(posedge clk); endtask
    task automatic chk(string what, int got, int exp);
        if (got !== exp) fail($sformatf("%s: got %0d exp %0d", what, got, exp));
        else $display("  ok  %-46s = %0d", what, got);
    endtask

    int g0;
    initial begin
        repeat (5) @(posedge clk); rst_n <= 1;

        // ---- A ----
        a_en <= 1;
        for (int i = 0; i < 400000; i++) begin
            @(posedge clk);
            a_next <= ($urandom % 3000 == 0);
            a_mode <= ($urandom % 5000 == 0);
            if ($urandom % 4000 == 0) a_end <= ~a_end;
            if ($urandom % 50000 == 0) a_cnt <= $urandom % 17;
            if ($urandom % 80000 == 0) a_en <= ~a_en;
        end
        $display("A: 新旧逐拍差异 = %0d（切歌 %0d 次）", a_diff, a_songs);
        if (a_diff != 0 || a_songs < 20) fail("A 等价失败");

        // ---- B ----
        repeat (100) @(posedge clk);
        // 1) 还没加载完：按键无效
        sw4 <= 1; repeat (100) @(posedge clk);
        short_press(); long_press(); settle();
        chk("未加载完时短按+长按：goto 次数", n_goto, 0);
        chk("未加载完时：光标", cursor, 0);
        ld <= 1; repeat (100) @(posedge clk);
        // 2) SW4=0：按键无效
        sw4 <= 0; repeat (100) @(posedge clk);
        short_press(); long_press(); settle();
        chk("SW4=0 短按+长按：goto 次数", n_goto, 0);
        chk("SW4=0：track_idx 不变", tidx, 0);
        // 3) 先切到第 2 首，再打开歌单：光标对准正在放的
        b_next <= 1; @(posedge clk); b_next <= 0; settle();
        b_next <= 1; @(posedge clk); b_next <= 0; settle();
        chk("下一首两次后 track_idx", tidx, 2);
        sw4 <= 1; repeat (100) @(posedge clk);
        chk("打开歌单：光标 = 正在放的", cursor, 2);
        // 4) 短按上移、到顶回绕到最后一首（5 首 → 4）
        short_press(); chk("短按 1 次：光标", cursor, 1);
        short_press(); chk("短按 2 次：光标", cursor, 0);
        short_press(); chk("短按 3 次（回绕）：光标", cursor, 4);
        short_press(); chk("短按 4 次：光标", cursor, 3);
        chk("短按不切歌：track_idx", tidx, 2);
        chk("短按不发 goto", n_goto, 0);
        // 5) 长按：跳到光标那首；按住很久也只触发一次；松手不再上移
        g0 = n_goto;
        press(LONG * 3); settle();
        chk("长按（按住 3 倍时长）：goto 次数", n_goto - g0, 1);
        chk("长按后 track_idx = 光标", tidx, 3);
        chk("长按后光标不动", cursor, 3);
        // 6) 刚好不到 1 s 松手算短按
        press(LONG - DEB - 200); chk("差一点 1 s：算短按，光标", cursor, 2);
        chk("差一点 1 s：不跳转", tidx, 3);
        // 7) 跳到正在放的那首：从头重放（restart）
        short_press(); short_press(); short_press(); short_press(); short_press();   // 2→1→0→4→3→2
        chk("回到 2", cursor, 2);
        long_press(); settle(); chk("跳到 2", tidx, 2);
        g0 = n_goto; long_press(); settle();
        chk("跳到正在放的那首：goto 次数", n_goto - g0, 1);
        chk("跳到正在放的那首：track_idx 不变", tidx, 2);
        // 8) 切歌途中长按：等这次切完再跳
        short_press(); chk("光标 1", cursor, 1);
        b_end <= 1;                                         // 放完 → 自动下一首（开始淡出）
        repeat (20) @(posedge clk); b_end <= 0;
        fork long_press(); join_none
        repeat (LONG + DEB + 500) @(posedge clk);
        settle(); settle();
        chk("切歌途中长按：最终 track_idx = 光标", tidx, 1);
        // 9) 关掉再打开：光标重新对准正在放的
        short_press(); short_press(); chk("光标挪开", cursor, 4);
        sw4 <= 0; repeat (100) @(posedge clk); sw4 <= 1; repeat (100) @(posedge clk);
        chk("重新打开：光标 = 正在放的", cursor, 1);
        // 10) 歌曲数变少，光标越界时短按回到最后一首
        cnt <= 5'd16; repeat (10) @(posedge clk);
        short_press(); short_press(); chk("16 首：光标 1→0→15", cursor, 15);
        cnt <= 5'd3; repeat (10) @(posedge clk);
        short_press(); chk("变成 3 首、光标 15 越界：短按到最后一首", cursor, 2);
        // 11) 没歌：按键无效
        cnt <= 5'd0; g0 = n_goto; repeat (10) @(posedge clk);
        short_press(); long_press(); settle();
        chk("没歌：goto 次数", n_goto - g0, 0);
        chk("没歌：光标不动", cursor, 2);

        $display("DONE tb_l2 errs=%0d", errs);
        $finish;
    end
endmodule
