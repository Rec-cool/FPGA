`timescale 1ns/1ps
// B3a：新旧 sd_card_bmp 各接一个 SD 卡模型 + loader 模型 + 真实 wav_stream_player。
//   旧版：音频在 4 张图都加载完后才拿到总线（play_enable = load_all_done）。
//   新版：扫描完就开始放歌（play_enable = scan_ready），图片和音频按扇区交替读。
// 检查：① 新旧送给 loader 的像素序列完全相同，且等于卡里 BMP 的内容；
//       ② 新版写进音频缓冲的字节序列等于卡里 PCM 的内容；
//       ③ 新版音频开始出声后不再欠载；④ 音频在图片加载完之前就开始了。
module tb;
    localparam integer BYTE_GAP = 8;               // 每字节 8 拍（实机约 32 拍）
    localparam [15:0]  W = 16'd64, H = 16'd16;     // 缩小的 BMP，加快仿真
    localparam integer IMG_BYTES = 54 + 64*16*3;   // 3126 字节 = 7 个簇（spc=1）
    localparam integer TICK_DIV = 12;              // video_clk 每 12 拍一个样本，音频约占总线 1/3

    reg clk = 0;  always #5  clk  = ~clk;
    reg vclk = 0; always #20 vclk = ~vclk;
    reg rst = 1;

    // ---------------- 卡镜像 ----------------
    byte unsigned mem [longint];
    function automatic byte unsigned pcm_pat(longint lba, int i);
        return (lba * 7 + i * 3 + (i >> 5)) & 8'hff;
    endfunction
    function automatic byte unsigned rd(longint lba, int i);
        if ((lba >= 1018 && lba < 1218) || (lba >= 2018 && lba < 2168)) return pcm_pat(lba, i);
        return mem.exists(lba*512 + i) ? mem[lba*512 + i] : 8'h00;
    endfunction
    task automatic wr8(longint lba, int i, byte unsigned v); mem[lba*512+i] = v; endtask
    task automatic wr16(longint lba, int i, int v); wr8(lba,i,v[7:0]); wr8(lba,i+1,v[15:8]); endtask
    task automatic wr32(longint lba, int i, int v); wr16(lba,i,v[15:0]); wr16(lba,i+2,v[31:16]); endtask
    task automatic dirent(longint lba, int slot, string name11, byte unsigned attr, int clus, int size);
        for (int k = 0; k < 11; k++) wr8(lba, slot*32+k, name11[k]);
        wr8(lba, slot*32+11, attr);
        wr16(lba, slot*32+20, clus[31:16]); wr16(lba, slot*32+26, clus[15:0]);
        wr32(lba, slot*32+28, size);
    endtask
    task automatic fat_set(int c, int v); wr32(4 + (c >> 7), (c & 127) * 4, v); endtask
    function automatic byte unsigned img_byte(int k, int off);
        case (off)
            0: return "B"; 1: return "M";
            10: return 54;  11, 12, 13: return 0;
            18: return W[7:0]; 19: return W[15:8];
            22: return H[7:0]; 23: return H[15:8];
            28: return 24;
            default: if (off < 54) return 0; else return (k*37 + off*13 + (off >> 8)) & 8'hff;
        endcase
    endfunction
    function automatic int img_cluster(int k, int n); return 10 + k*20 + n*2; endfunction   // 簇之间隔一个，验证跟链
    initial begin
        // spc=1, rsvd=4, 2 个 FAT 各 8 扇区 → fat=4, data=20，LBA(c) = 18 + c
        wr8(0,0,8'heb); wr16(0,11,512); wr8(0,13,1); wr16(0,14,4); wr8(0,16,2);
        wr32(0,32,100000); wr32(0,36,8); wr32(0,44,2); wr8(0,510,8'h55); wr8(0,511,8'haa);
        fat_set(2, 32'h0fffffff);                                   // 根目录 1 个簇
        for (int s = 0; s < 16; s++) wr8(20, s*32, 8'he5);
        dirent(20, 0, "PIC1    BMP", 8'h20, img_cluster(0,0), IMG_BYTES);
        dirent(20, 1, "PIC2    BMP", 8'h20, img_cluster(1,0), IMG_BYTES);
        dirent(20, 2, "SONGA   PCM", 8'h20, 1000, 200*512);
        dirent(20, 3, "PIC3    BMP", 8'h20, img_cluster(2,0), IMG_BYTES);
        dirent(20, 4, "PIC4    BMP", 8'h20, img_cluster(3,0), IMG_BYTES);
        dirent(20, 5, "SONGB   PCM", 8'h20, 2000, 150*512);
        wr8(20, 6*32, 8'h00);
        for (int k = 0; k < 4; k++) begin
            for (int n = 0; n < 7; n++) fat_set(img_cluster(k,n), n == 6 ? 32'h0fffffff : img_cluster(k,n+1));
            for (int off = 0; off < IMG_BYTES; off++) wr8(18 + img_cluster(k, off/512), off % 512, img_byte(k, off));
        end
    end

    // ---------------- 两套 DUT ----------------
    wire pv_o, pv_n, ad_o, ad_n, sr_n; wire [1:0] li_o, li_n; wire [23:0] rgb_o, rgb_n; wire [4:0] pc_o, pc_n;
    harness #(.NEW(0)) ho (.clk(clk), .vclk(vclk), .rst(rst), .pv(pv_o), .li(li_o), .rgb(rgb_o), .all_done(ad_o), .scan_ready(), .pcm_count(pc_o));
    harness #(.NEW(1)) hn (.clk(clk), .vclk(vclk), .rst(rst), .pv(pv_n), .li(li_n), .rgb(rgb_n), .all_done(ad_n), .scan_ready(sr_n), .pcm_count(pc_n));

    // ---------------- 检查 ----------------
    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 20) $display("ERR t=%0t %s", $time, m); endtask
    // ① 像素序列
    reg [25:0] pix_o [$], pix_n [$];
    always @(posedge clk) begin
        if (pv_o) pix_o.push_back({li_o, rgb_o});
        if (pv_n) pix_n.push_back({li_n, rgb_n});
    end
    // ② 音频缓冲写入序列
    integer aw_n = 0;
    always @(posedge clk) if (hn.p.buf_we) begin
        automatic longint L = 1018 + aw_n / 256; automatic int j = aw_n % 256;
        if ({hn.p.sd_byte, hn.p.lo_byte} !== {pcm_pat(L, 2*j+1), pcm_pat(L, 2*j)})
            fail($sformatf("audio word %0d = %h exp %h", aw_n, {hn.p.sd_byte, hn.p.lo_byte}, {pcm_pat(L,2*j+1), pcm_pat(L,2*j)}));
        aw_n++;
    end
    // ③ 欠载：开始出声后，每次发样本时缓冲都要有数据
    reg playing_n = 0; integer underflow_n = 0, played_n = 0;
    always @(posedge vclk) if (hn.p.issue) begin
        if (hn.p.level_rd >= 256) begin if (aw_n >= 1024) playing_n <= 1; played_n++; end   // 播放器只攒 1 扇区就开播，前 4 扇区不算欠载
        else if (playing_n && !hn.p.end_s3 && hn.p.wstate != 3'd4) underflow_n++;   // 整首已读完、只剩尾巴时不算
    end
    // ④ 时间点
    time t_scan_n = 0, t_aud_n = 0, t_done_n = 0, t_done_o = 0, t_aud_o = 0;
    always @(posedge clk) begin
        if (sr_n && t_scan_n == 0) t_scan_n = $time;
        if (hn.p.buf_we && t_aud_n == 0) t_aud_n = $time;
        if (ho.p.buf_we && t_aud_o == 0) t_aud_o = $time;
        if (ad_n && t_done_n == 0) t_done_n = $time;
        if (ad_o && t_done_o == 0) t_done_o = $time;
    end
    // 总线互斥：新版适配层同一时刻只服务一个所有者
    always @(posedge clk) if (!rst && hn.g_dut.u.arb_sector_valid && hn.g_dut.u.arb_owner == 2'd0) fail("byte with no owner");

    initial begin
        repeat (10) @(posedge clk); rst <= 0;
        wait (ad_o && ad_n);
        repeat (300000) @(posedge clk);
        if (pix_o.size() != 4*64*16) fail($sformatf("old pixel count %0d", pix_o.size()));
        if (pix_n.size() != pix_o.size()) fail($sformatf("new pixel count %0d vs old %0d", pix_n.size(), pix_o.size()));
        for (int i = 0; i < pix_o.size() && i < pix_n.size(); i++) begin
            automatic int k = pix_o[i][25:24], p = i % (64*16);
            automatic reg [23:0] e = {img_byte(k, 54+3*p+2), img_byte(k, 54+3*p+1), img_byte(k, 54+3*p)};
            if (pix_n[i] !== pix_o[i]) begin fail($sformatf("pixel %0d new %h old %h", i, pix_n[i], pix_o[i])); break; end
            if (pix_o[i][23:0] !== e || k != i / (64*16)) begin fail($sformatf("pixel %0d = %h exp %h", i, pix_o[i], e)); break; end
        end
        if (pc_n != 2 || pc_o != 2) fail("pcm_count");
        if (!(t_aud_n < t_done_n)) fail("audio did not start before images done");
        if (underflow_n != 0) fail($sformatf("underflow %0d", underflow_n));
        $display("[old] images done %0.3f ms, audio first write %0.3f ms", t_done_o/1.0e6, t_aud_o/1.0e6);
        $display("[new] scan ready %0.3f ms, audio first write %0.3f ms, images done %0.3f ms (x%0.2f)",
                 t_scan_n/1.0e6, t_aud_n/1.0e6, t_done_n/1.0e6, real'(t_done_n)/real'(t_done_o));
        $display("[new] audio words %0d, samples played %0d, underflow %0d", aw_n, played_n, underflow_n);
        $display("DONE pixels=%0d errs=%0d", pix_n.size(), errs);
        $finish;
    end
    initial begin #200ms; $display("TIMEOUT errs=%0d", errs); $finish; end
endmodule

// 一套 DUT：sd_card_bmp + loader 模型 + 播放器（NEW=0 用旧版仲裁，音频等图片加载完；NEW=1 用新版）
module harness #(parameter NEW = 0) (
    input clk, input vclk, input rst,
    output pv, output [1:0] li, output [23:0] rgb, output all_done, output scan_ready, output [4:0] pcm_count
);
    wire ls, fc, le; reg lb = 0, ld = 0;
    always @(posedge clk) begin ld <= 0; if (ls) lb <= 1; if (lb && (fc || le)) begin lb <= 0; ld <= 1; end end
    wire areq, abusy, avalid, adone; wire [31:0] alba; wire [7:0] abyte, aerr; wire [8:0] aidx;
    wire [31:0] plba; wire [23:0] psec;
    generate if (NEW) begin : g_dut
        sd_card_bmp #(.BMP_WIDTH(tb.W), .BMP_HEIGHT(tb.H)) u (
            .clk(clk), .rst(rst), .state_code(), .Sdr_init_done(1'b1),
            .load_start(ls), .load_image_index(li), .load_busy(lb), .load_done(ld),
            .image_complete(4'd0), .pixel_valid(pv), .pixel_rgb(rgb), .frame_commit(fc),
            .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1), .decoder_error(), .load_error(le),
            .load_all_done(all_done),
            .aud_sector_req(areq), .aud_sector_lba(alba), .aud_sector_busy(abusy),
            .aud_sector_valid(avalid), .aud_sector_done(adone), .aud_sector_byte(abyte),
            .aud_sector_error(aerr), .aud_sector_byte_index(aidx),
            .pcm_count(pcm_count), .pcm_rd_idx(4'd0), .pcm_rd_lba(plba), .pcm_rd_sectors(psec),
            .scan_ready(scan_ready));
    end else begin : g_dut
        sd_card_bmp_old #(.BMP_WIDTH(tb.W), .BMP_HEIGHT(tb.H)) u (
            .clk(clk), .rst(rst), .state_code(), .Sdr_init_done(1'b1),
            .load_start(ls), .load_image_index(li), .load_busy(lb), .load_done(ld),
            .image_complete(4'd0), .pixel_valid(pv), .pixel_rgb(rgb), .frame_commit(fc),
            .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1), .decoder_error(), .load_error(le),
            .load_all_done(all_done),
            .aud_sector_req(areq), .aud_sector_lba(alba), .aud_sector_busy(abusy),
            .aud_sector_valid(avalid), .aud_sector_done(adone), .aud_sector_byte(abyte),
            .aud_sector_error(aerr), .aud_sector_byte_index(aidx),
            .pcm_count(pcm_count), .pcm_rd_idx(4'd0), .pcm_rd_lba(plba), .pcm_rd_sectors(psec));
        assign scan_ready = 1'b0;
    end endgenerate
    reg [3:0] td = 0; always @(posedge vclk) td <= (td == tb.TICK_DIV-1) ? 0 : td + 1;
    wav_stream_player #(.ADDR_WIDTH(12), .SAMPLES_PER_SECTOR(256)) p (
        .wr_clk(clk), .wr_rst_n(!rst), .play_enable(NEW ? scan_ready : all_done), .restart(1'b0),
        .start_lba(pcm_count != 0 ? plba : 32'd0), .total_sectors({8'd0, psec}),
        .sd_req(areq), .sd_lba(alba), .sd_busy(abusy), .sd_valid(avalid),
        .sd_byte(abyte), .sd_byte_index(aidx), .sd_done(adone), .sd_error(aerr),
        .rd_clk(vclk), .rd_rst_n(!rst), .sample_tick(td == 0), .sample_out(), .sample_valid(),
        .sample_ready(1'b1), .gain(8'd255), .sample_counter(), .stream_active(), .stream_end(), .buffer_low());
endmodule
