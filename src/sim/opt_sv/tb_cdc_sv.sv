`timescale 1ns/1ps
// 10-30 CF 顶层跨域：cdc_blk.v 由 gen_cdc.sh 从顶层原样抽出（sd 域 cfg_bus 打包 + video 域档位块）。
//   A. 300 次随机 cfg_apply（随机 mask/值，间隔随机，sd 100MHz / video 39.7ns 非整数倍）：
//      sd 域 volume_sd / period_sec_sd 立即按 mask 更新；video 域在 ≤ 10 拍内一次性更新到期望值，
//      无效项保持原值；每次 apply 各寄存器最多变一次、只会变成期望值（没有中间值）；cfg_hit 恰好一次。
//   B. 不发 apply：调节键（adj_toggle 翻转）照常步进亮度/对比度，和改动前的规则一致。
//   C. apply 后再按键：按键从配置值继续步进。
module tb;
    reg sclk = 0; always #5     sclk = ~sclk;
    reg vclk = 0; always #19.85 vclk = ~vclk;
    reg srst_n = 0, vrst_n = 0;
    reg ap = 0; reg [5:0] m = 0; reg [48:0] v = 0;
    reg adj = 0, sw1 = 0, sw2 = 0, fs = 0;
    reg sv_auto = 0; reg [1:0] sv_mode = 0;
    cdc_blk u (.sd_card_clk(sclk), .sdcard_rst_n(srst_n), .cfg_apply(ap), .cfg_mask(m), .cfg_val(v),
               .video_clk(vclk), .video_rst_n(vrst_n), .adj_toggle(adj), .sw1(sw1), .sw2(sw2), .frame_start(fs), .ctrl_auto_enabled(sv_auto), .track_mode(sv_mode));
    always @(posedge vclk) fs <= ($urandom % 50 == 0);

    integer errs = 0, n_hit = 0, n_chg = 0;
    // ---- 11-01 SV：save_val ----
    // 亮度/对比度档在 video 域稳定 30 个 sd 拍后，sv_bc_sd 要等于它；中途不会出现别的值（只会是新值或旧值）
    // 音量档 / 音量已设 / 间隔已设：apply 带对应 mask 位时更新，之后不变；save_val 的打包顺序
    int n_bc = 0, n_fl = 0, bc_stable = 0;
    reg [4:0] bc_prev, bc_old;
    int e_vl = 9; bit e_vs = 0, e_is = 0;
    always @(posedge sclk) sv_auto <= $urandom; 
    always @(posedge sclk) if (sv_mode != 2 && $urandom % 997 == 0) sv_mode <= $urandom % 3;
    always @(posedge sclk) if (srst_n) begin
        if ({u.bri_level, u.con_level} === bc_prev) bc_stable++; else begin bc_stable = 0; bc_old = bc_prev; end
        bc_prev = {u.bri_level, u.con_level};
        if (bc_stable == 30) begin n_bc++; if (u.sv_bc_sd !== bc_prev) fail($sformatf("sv_bc_sd %b exp %b", u.sv_bc_sd, bc_prev)); end
        if (u.sv_bc_sd !== bc_prev && u.sv_bc_sd !== bc_old && bc_stable > 0) fail($sformatf("sv_bc_sd glitch %b (cur %b old %b)", u.sv_bc_sd, bc_prev, bc_old));
        if (ap) begin
            if (m[5]) begin e_vl = v[3:0]; e_vs = 1; end
            if (m[0]) e_is = 1;
        end else begin
            n_fl++;
            if (u.vol_lvl_sd !== e_vl[3:0] || u.vol_set_sd !== e_vs || u.int_set_sd !== e_is)
                fail($sformatf("vol_lvl %0d/%0d vol_set %0d/%0d int_set %0d/%0d", u.vol_lvl_sd, e_vl, u.vol_set_sd, e_vs, u.int_set_sd, e_is));
            if (u.save_val !== {u.int_set_sd, u.period_sec_sd[4:0], sv_auto, u.sv_bc_sd, sv_mode, u.vol_set_sd, u.vol_lvl_sd})
                fail("save_val packing");
        end
    end
    task automatic fail(string s); errs++; if (errs < 40) $display("ERR t=%0t %s", $time, s); endtask

    // 期望值（video 域）
    int e_bri = 3, e_con = 2, e_vol = 220, e_ms = 1500, e_vsd = 220, e_ssd = 1;
    // 每个寄存器在一个观察窗内的变化次数
    int c_bri, c_con, c_vol, c_ms;
    reg [1:0] p_bri; reg [2:0] p_con; reg [7:0] p_vol; reg [15:0] p_ms;
    always @(posedge vclk) if (vrst_n) begin
        if (u.cfg_hit) n_hit++;
        if (u.bri_level !== p_bri) begin c_bri++; if (u.bri_level !== e_bri[1:0]) fail($sformatf("bri -> %0d exp %0d", u.bri_level, e_bri)); end
        if (u.con_level !== p_con) begin c_con++; if (u.con_level !== e_con[2:0]) fail($sformatf("con -> %0d exp %0d", u.con_level, e_con)); end
        if (u.volume_pix !== p_vol) begin c_vol++; if (u.volume_pix !== e_vol[7:0]) fail($sformatf("vol -> %0d exp %0d", u.volume_pix, e_vol)); end
        if (u.period_ms_pix !== p_ms) begin c_ms++; if (u.period_ms_pix !== e_ms[15:0]) fail($sformatf("ms -> %0d exp %0d", u.period_ms_pix, e_ms)); end
        p_bri <= u.bri_level; p_con <= u.con_level; p_vol <= u.volume_pix; p_ms <= u.period_ms_pix;
    end

    task automatic apply_one(bit [5:0] mm, int sec, int aon, int bri, int con, int mode, int vol);
        int h0;
        @(posedge sclk);
        m <= mm; v <= {32'(sec * 100_000_000), 5'(sec), 1'(aon), 2'(bri), 3'(con), 2'(mode), 4'(vol)};
        ap <= 1;
        // 期望先更新（观察器只在值变化时比较）
        if (mm[2]) e_bri = bri; if (mm[3]) e_con = con; if (mm[5]) begin e_vol = vol * 25; e_vsd = vol * 25; end
        if (mm[0]) begin e_ms = sec * 1000; e_ssd = sec; end
        c_bri = 0; c_con = 0; c_vol = 0; c_ms = 0; h0 = n_hit;
        @(posedge sclk); ap <= 0; m <= $urandom; v <= {$urandom, $urandom};   // apply 之后输入随便变
        #1;
        if (u.volume_sd !== e_vsd[7:0]) fail($sformatf("volume_sd %0d exp %0d", u.volume_sd, e_vsd));
        if (u.period_sec_sd !== e_ssd[7:0]) fail($sformatf("period_sec_sd %0d exp %0d", u.period_sec_sd, e_ssd));
        repeat (10) @(posedge vclk);
        #1;
        if (u.bri_level !== e_bri[1:0] || u.con_level !== e_con[2:0] || u.volume_pix !== e_vol[7:0] || u.period_ms_pix !== e_ms[15:0])
            fail($sformatf("final bri %0d/%0d con %0d/%0d vol %0d/%0d ms %0d/%0d", u.bri_level, e_bri, u.con_level, e_con,
                           u.volume_pix, e_vol, u.period_ms_pix, e_ms));
        if (c_bri > 1 || c_con > 1 || c_vol > 1 || c_ms > 1) fail($sformatf("multiple changes %0d %0d %0d %0d", c_bri, c_con, c_vol, c_ms));
        if (n_hit - h0 != 1) fail($sformatf("cfg_hit %0d times", n_hit - h0));
        n_chg += c_bri + c_con + c_vol + c_ms;
        repeat ($urandom % 40) @(posedge sclk);
    endtask

    task automatic key_step(int n_steps, bit con_sel);
        sw2 = con_sel; repeat (10) @(posedge vclk);
        for (int k = 0; k < n_steps; k++) begin
            if (!con_sel) e_bri = (e_bri + 1) % 4; else e_con = (e_con == 5) ? 0 : e_con + 1;
            c_bri = 0; c_con = 0;
            @(posedge sclk) adj <= ~adj;
            repeat (8) @(posedge vclk); #1;
            if (u.bri_level !== e_bri[1:0] || u.con_level !== e_con[2:0])
                fail($sformatf("key step bri %0d/%0d con %0d/%0d", u.bri_level, e_bri, u.con_level, e_con));
            if (c_bri + c_con != 1) fail("key step not exactly one change");
        end
    endtask

    initial begin
        repeat (5) @(posedge vclk); srst_n = 1; vrst_n = 1;
        repeat (20) @(posedge vclk);
        // 复位默认值
        if (u.bri_level !== 3 || u.con_level !== 2 || u.volume_pix !== 220 || u.period_ms_pix !== 1500 ||
            u.volume_sd !== 220 || u.period_sec_sd !== 1)
            fail("reset defaults");
        // B：只按键
        key_step(9, 0); key_step(13, 1);
        $display("B key steps done errs=%0d", errs);
        // 固定：全部有效、最大值、全无效
        apply_one(6'b111111, 30, 1, 0, 5, 2, 10);
        apply_one(6'b111111, 1, 0, 3, 0, 0, 0);
        apply_one(6'b000000, 7, 1, 1, 1, 1, 1);
        // A：随机
        for (int k = 0; k < 300; k++)
            apply_one($urandom, 1 + $urandom % 30, $urandom % 2, $urandom % 4, $urandom % 6, $urandom % 3, $urandom % 11);
        $display("A random applies done errs=%0d value_changes=%0d", errs, n_chg);
        // C：配置之后按键继续步进
        apply_one(6'b001100, 5, 0, 1, 4, 0, 0);
        key_step(3, 0); key_step(4, 1);
        $display("  save_val checks: bri/con %0d, flags %0d", n_bc, n_fl);
        $display("DONE tb_cdc hits=%0d errs=%0d", n_hit, errs);
        $finish;
    end
endmodule
