`timescale 1ns/1ps
// 10-29 CS 卡状态提示验证：真实 sd_card_bmp（扫描器/streamer/缩放器/适配层）+ 可插拔的 SD 卡行为模型。
//   卡模型：驱动每次复位后重新初始化；tb.present=0 时初始化永远不完成；tb.dead=1 时读扇区卡死不返回；
//           卡内容由 build(content) 生成：0 正常 4 张图 / 1 引导扇区签名坏 / 2 没有 PIC1~4.BMP /
//           3 四张图都是 32 位色（全部拒绝）/ 4 根目录 FAT 链成环（扫描读错）
//   场景：
//     S1 正常：1 → 6(图 0~3) → 0，中间不出现故障码
//     S2 开机没插好卡：2（看门狗重试）；插好后自动恢复到 0
//     S3 不是 FAT32：3，每 2.5s（缩短）自动重新初始化 + 重新扫描，期间一直显示 3 不闪；修好卡后恢复到 0
//     S4 没有图：4，修好后恢复
//     S5 根目录链成环：5，修好后恢复
//     S6 加载第 2 张时卡死：7，并保持
//     S7 四张图都不能用：8
//     S8 扫描失败后拔卡：2（初始化失败优先），再插好正确的卡：恢复到 0
module tb;
    parameter integer W = 64, H = 16;
    localparam integer BYTE_GAP = 4;    // 同 tb_s2_reg：每像素 12 拍，缩放器每像素要 8~9 拍（2 拍会溢出）
    localparam integer STRIDE = W*3 + (W % 4);
    localparam integer IMG_BYTES = 54 + STRIDE*H;
    localparam integer CLUS = (IMG_BYTES + 511) / 512;
    localparam integer PWR = 100, INIT_TO = 5000, STALL = 20000, RETRY = 30000;

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;
    bit present = 1, dead = 0;
    int content = 0;

    // ---------------- 卡内容 ----------------
    byte unsigned mem [longint];
    function automatic byte unsigned rd(longint lba, int i);
        return mem.exists(lba*512 + i) ? mem[lba*512 + i] : 8'h00;
    endfunction
    task automatic wr8(longint lba, int i, byte unsigned v); mem[lba*512+i] = v; endtask
    task automatic wr16(longint lba, int i, int v); wr8(lba,i,v[7:0]); wr8(lba,i+1,v[15:8]); endtask
    task automatic wr32(longint lba, int i, int v); wr16(lba,i,v[15:0]); wr16(lba,i+2,v[31:16]); endtask
    task automatic dirent(longint lba, int slot, string name11, int clus, int size);
        for (int k = 0; k < 11; k++) wr8(lba, slot*32+k, name11[k]);
        wr8(lba, slot*32+11, 8'h20);
        wr16(lba, slot*32+20, clus[31:16]); wr16(lba, slot*32+26, clus[15:0]);
        wr32(lba, slot*32+28, size);
    endtask
    task automatic fat_set(int c, int v); wr32(4 + (c >> 7), (c & 127) * 4, v); endtask
    function automatic byte unsigned img_byte(int k, int off);
        case (off)
            0: return "B"; 1: return "M";
            10: return 54;
            18: return W[7:0]; 19: return W[15:8];
            22: return H[7:0]; 23: return H[15:8];
            28: return (content == 3) ? 8'd32 : 8'd24;
            default: return (off < 54) ? 8'd0 : ((k*37 + off*13) & 8'hff);
        endcase
    endfunction
    function automatic int img_cluster(int k, int n); return 10 + k*(2*CLUS+4) + n*2; endfunction
    task automatic build(int c);
        content = c;
        mem.delete();
        wr8(0,0,8'heb); wr16(0,11,512); wr8(0,13,1); wr16(0,14,4); wr8(0,16,2);
        wr32(0,32,1000000); wr32(0,36,64); wr32(0,44,2);
        wr8(0,510,8'h55); wr8(0,511,(c == 1) ? 8'h00 : 8'haa);
        fat_set(2, (c == 4) ? 32'd2 : 32'h0fffffff);                // 4：根目录簇指向自己
        for (int s = 0; s < 16; s++) wr8(132, s*32, 8'he5);
        for (int k = 0; k < 4; k++)
            dirent(132, k, $sformatf((c == 2) ? "IMG%0d    BMP" : "PIC%0d    BMP", k+1), img_cluster(k,0), IMG_BYTES);
        if (c != 4) wr8(132, 4*32, 8'h00);                          // 4：没有目录结束项，一直沿链往下读
        for (int k = 0; k < 4; k++) begin
            for (int n = 0; n < CLUS; n++) fat_set(img_cluster(k,n), n == CLUS-1 ? 32'h0fffffff : img_cluster(k,n+1));
            for (int off = 0; off < IMG_BYTES; off++) wr8(130 + img_cluster(k, off/512), off % 512, img_byte(k, off));
        end
    endtask

    // ---------------- DUT + loader 桩 ----------------
    wire ls, fc, pv, le, all_done; wire [1:0] li; wire [23:0] rgb; wire [5:0] cs;
    reg lb = 0, ld = 0; reg [3:0] img_ok = 0;
    always @(posedge clk) begin
        ld <= 0;
        if (rst) begin lb <= 0; img_ok <= 0; end
        else begin
            if (ls) lb <= 1;
            if (lb && (fc || le)) begin lb <= 0; ld <= 1; if (fc) img_ok[li] <= 1; end
        end
    end
    sd_card_bmp #(.BMP_WIDTH(W), .BMP_HEIGHT(H), .SCALE_ENABLE(1), .SCALE_MAX_W(4096), .SCALE_FIT(1), .SCALE_RATE(8),
                  .SD_PWRUP_CYC(PWR), .SD_INIT_TO_CYC(INIT_TO), .SD_STALL_CYC(STALL), .SD_SCAN_RETRY_CYC(RETRY)) u (
        .clk(clk), .rst(rst), .state_code(), .card_status(cs), .Sdr_init_done(1'b1),
        .load_start(ls), .load_image_index(li), .load_busy(lb), .load_done(ld),
        .image_complete(img_ok), .pixel_valid(pv), .pixel_rgb(rgb), .frame_commit(fc),
        .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1), .decoder_error(), .load_error(le),
        .load_all_done(all_done), .info_rd_idx(2'd0), .info_rd_data(),
        .aud_sector_req(1'b0), .aud_sector_lba(32'd0), .aud_sector_busy(), .aud_sector_valid(), .aud_sector_done(),
        .aud_sector_byte(), .aud_sector_error(), .aud_sector_byte_index(),
        .pcm_count(), .pcm_rd_idx(4'd0), .pcm_rd_lba(), .pcm_rd_sectors(), .pl_rd_idx(4'd0), .pl_rd_data());

    // ---------------- 记录 ----------------
    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 40) $display("ERR t=%0t %s", $time, m); endtask
    wire [3:0] msg = cs[5:2];
    reg  [3:0] msg_q = 0;
    reg  [3:0] seen;                       // 本场景出现过的 msg（位图，最多 9 种用 16 位）
    reg  [15:0] seen_m = 0;
    reg  [3:0]  seen_pic = 0;              // msg=6 时出现过的图号
    int  drv_resets = 0, flips = 0;
    reg  drv_rst_q = 0;
    always @(posedge clk) begin
        msg_q <= msg;
        if (!rst) begin
            seen_m[msg] <= 1'b1;
            if (msg == 4'd6) seen_pic[cs[1:0]] <= 1'b1;
            if (msg != msg_q) flips++;
        end
        drv_rst_q <= u.sd_drv_rst;
        if (u.sd_drv_rst && !drv_rst_q && !rst) drv_resets++;
    end
    task automatic clear_log(); seen_m = 0; seen_pic = 0; drv_resets = 0; flips = 0; endtask
    task automatic chk(string what, int got, int exp);
        if (got !== exp) fail($sformatf("%s: got %0d exp %0d", what, got, exp));
        else $display("  ok  %-52s = %0d", what, got);
    endtask
    task automatic wait_msg(int m, int max_cyc, string what);
        int n = 0;
        while (msg != m && n < max_cyc) begin @(posedge clk); n++; end
        if (msg != m) fail($sformatf("%s: msg=%0d, waited %0d cycles for %0d", what, msg, n, m));
        else $display("  ok  %-52s (after %0d cycles)", what, n);
    endtask
    task automatic reboot(int c);
        rst <= 1; dead = 0; build(c); repeat (20) @(posedge clk); clear_log(); rst <= 0;
    endtask

    reg ovr = 0; always @(posedge clk) if (u.u_bmp_scaler.overrun) ovr <= 1;
    initial begin
        int f0;
        // S1
        $display("S1 normal");
        reboot(0);
        wait_msg(0, 2_000_000, "S1 loads to msg 0");
        chk("S1 saw msg 1 (reading)", seen_m[1], 1);
        chk("S1 saw msg 6 with pics 0~3", seen_pic, 4'hf);
        chk("S1 no fault msg (2/3/4/5/7/8)", |{seen_m[2], seen_m[3], seen_m[4], seen_m[5], seen_m[7], seen_m[8]}, 0);
        chk("S1 no driver re-init", drv_resets, 0);
        repeat (RETRY * 2) @(posedge clk);
        chk("S1 stays 0 afterwards", msg, 0);

        // S2
        $display("S2 card not seated at boot");
        present = 0; reboot(0);
        wait_msg(2, PWR + INIT_TO + 1000, "S2 -> msg 2 after init timeout");
        repeat (INIT_TO * 3) @(posedge clk);
        chk("S2 still 2 while absent", msg, 2);
        present = 1;
        wait_msg(0, 2_000_000, "S2 re-seated -> loads to 0");

        // S3 / S4 / S5：扫描失败 → 自动重试 → 修好恢复
        for (int c = 1; c <= 4; c++) begin
            automatic int m = (c == 1) ? 3 : (c == 2) ? 4 : 5;
            if (c == 3) continue;
            $display("S%0d scan fail content=%0d", (c == 1) ? 3 : (c == 2) ? 4 : 5, c);
            reboot(c);
            wait_msg(m, 2_000_000, $sformatf("content %0d -> msg %0d", c, m));
            f0 = flips; drv_resets = 0;
            repeat (RETRY * 3 + 20000 + ((c == 4) ? 600000 : 0)) @(posedge clk);   // 链成环的卡每次扫描要约 27 万拍，扫描期间不计时
            chk($sformatf("content %0d: driver re-inits in 3 retry periods >= 2", c), drv_resets >= 2, 1);
            chk($sformatf("content %0d: msg stays %0d during retries (no flicker)", c, m), flips - f0, 0);
            build(0);
            wait_msg(0, RETRY * 2 + 2_000_000, $sformatf("content %0d fixed -> recovers to 0", c));
            chk($sformatf("content %0d: pics loaded after recovery", c), img_ok, 4'hf);
        end

        // S6：加载途中卡死
        $display("S6 card dies while loading pic 2");
        reboot(0);
        wait (u.load_ctrl_idx == 2'd2 && msg == 6);
        repeat (300) @(posedge clk);
        dead = 1;
        wait_msg(7, STALL + 20000, "S6 -> msg 7 (stall)");
        repeat (RETRY * 2) @(posedge clk);
        chk("S6 stays 7", msg, 7);
        dead = 0;

        // S7：四张图都不能用
        $display("S7 all pictures rejected");
        reboot(3);
        wait_msg(8, 2_000_000, "S7 -> msg 8");
        chk("S7 no pic committed", img_ok, 0);

        // S8：扫描失败后拔卡，再插好正确的卡
        $display("S8 scan fail then card removed, then good card");
        reboot(1);
        wait_msg(3, 2_000_000, "S8 -> msg 3");
        present = 0;
        wait_msg(2, RETRY + INIT_TO * 2 + 5000, "S8 card removed -> msg 2");
        build(0); present = 1;
        wait_msg(0, 2_000_000, "S8 good card -> loads to 0");

        if (ovr) fail("scaler overrun");
        $display("DONE tb_cs errs=%0d", errs);
        $finish;
    end
    initial begin #400ms; $display("TIMEOUT errs=%0d", errs + 1); $finish; end
endmodule

// sd_card_top 行为模型：每次驱动复位后重新初始化；present=0 时永不完成；dead=1 时读扇区卡死
module sd_card_top #(parameter SPI_LOW_SPEED_DIV = 248, parameter SPI_HIGH_SPEED_DIV = 0) (
    input clk, input rst,
    output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO,
    output reg sd_init_done,
    input sd_sec_read, input [31:0] sd_sec_read_addr,
    output reg [7:0] sd_sec_read_data, output reg sd_sec_read_data_valid, output reg sd_sec_read_end,
    input sd_sec_write, input [31:0] sd_sec_write_addr, input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req, output sd_sec_write_end
);
    assign SD_nCS = 1'b1; assign SD_DCLK = 1'b0; assign SD_MOSI = 1'b1;
    assign sd_sec_write_data_req = 1'b0; assign sd_sec_write_end = 1'b0;
    initial begin
        sd_init_done = 0; sd_sec_read_data = 0; sd_sec_read_data_valid = 0; sd_sec_read_end = 0;
        forever begin
            sd_init_done <= 0; sd_sec_read_data_valid <= 0; sd_sec_read_end <= 0;
            wait (!rst);
            repeat (50) @(posedge clk);
            if (!rst && tb.present) sd_init_done <= 1;
            while (!rst) begin
                @(posedge clk);
                if (sd_init_done && sd_sec_read && !rst) begin : rd_sector
                    reg [31:0] L; L = sd_sec_read_addr;
                    repeat (20) @(posedge clk);
                    for (int i = 0; i < 512 && !rst; i++) begin
                        while (tb.dead && !rst) @(posedge clk);
                        sd_sec_read_data <= tb.rd(L, i); sd_sec_read_data_valid <= 1; @(posedge clk);
                        sd_sec_read_data_valid <= 0; repeat (tb.BYTE_GAP - 1) @(posedge clk);
                    end
                    if (!rst) begin sd_sec_read_end <= 1; @(posedge clk); sd_sec_read_end <= 0; end
                end
            end
        end
    end
endmodule
