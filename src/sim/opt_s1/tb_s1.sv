`timescale 1ns/1ps
// S1：BMP 头 32 位解析 + 行尾填充。新旧 sd_card_bmp 各接一个 SD 卡模型和 loader 模型。
//   vsim -gW=.. -gH=.. -gCASE=..
//   CASE 0：4 张正常图
//   CASE 1：图 1 为 32 位色、图 2 压缩、图 3 宽度低字节不对、图 0 正常（新旧都应拒绝 1~3）
//   CASE 2：图 1 宽度高字节非 0（旧版会接受，新版应拒绝），其余正常
// 检查：新版像素序列 = 按卡内容算出的期望；宽度是 4 的倍数时新旧逐像素相同；新旧拒绝的图片一致（CASE 2 除外）。
module tb;
    parameter integer W = 64, H = 16, CASE = 0;
    localparam integer BYTE_GAP = 2;
    localparam integer STRIDE = W*3 + (W % 4);
    localparam integer IMG_BYTES = 54 + STRIDE*H;
    localparam integer CLUS = (IMG_BYTES + 511) / 512;

    reg clk = 0; always #5 clk = ~clk;
    reg vclk = 0; always #20 vclk = ~vclk;
    reg rst = 1;

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
    function automatic bit bad_img(int k);
        if (CASE == 1) return k != 0;
        return 0;
    endfunction
    function automatic byte unsigned img_byte(int k, int off);
        case (off)
            0: return "B"; 1: return "M";
            10: return 54;
            18: return (CASE == 1 && k == 3) ? (W[7:0] ^ 8'h01) : W[7:0];
            19: return W[15:8];
            21: return (CASE == 2 && k == 1) ? 8'h01 : 8'h00;
            22: return H[7:0]; 23: return H[15:8];
            28: return (CASE == 1 && k == 1) ? 8'd32 : 8'd24;
            30: return (CASE == 1 && k == 2) ? 8'd1 : 8'd0;
            default: begin
                if (off < 54) return 0;
                if ((off - 54) % STRIDE >= W*3) return 8'hA5;           // 填充字节：故意非 0，读错位会立刻暴露
                return (k*37 + off*13 + (off >> 8)) & 8'hff;
            end
        endcase
    endfunction
    function automatic int img_cluster(int k, int n); return 10 + k*(2*CLUS+4) + n*2; endfunction
    initial begin
        wr8(0,0,8'heb); wr16(0,11,512); wr8(0,13,1); wr16(0,14,4); wr8(0,16,2);
        wr32(0,32,1000000); wr32(0,36,64); wr32(0,44,2); wr8(0,510,8'h55); wr8(0,511,8'haa);
        // fat=4（64 扇区）, data=4+128=132，LBA(c) = 130 + c
        fat_set(2, 32'h0fffffff);
        for (int s = 0; s < 16; s++) wr8(132, s*32, 8'he5);
        for (int k = 0; k < 4; k++) dirent(132, k, $sformatf("PIC%0d    BMP", k+1), img_cluster(k,0), IMG_BYTES);
        wr8(132, 4*32, 8'h00);
        for (int k = 0; k < 4; k++) begin
            for (int n = 0; n < CLUS; n++) fat_set(img_cluster(k,n), n == CLUS-1 ? 32'h0fffffff : img_cluster(k,n+1));
            for (int off = 0; off < IMG_BYTES; off++) wr8(130 + img_cluster(k, off/512), off % 512, img_byte(k, off));
        end
    end

    wire pv_o, pv_n, ad_o, ad_n, le_o, le_n; wire [1:0] li_o, li_n; wire [23:0] rgb_o, rgb_n;
    harness #(.NEW(0)) ho (.clk(clk), .rst(rst), .pv(pv_o), .li(li_o), .rgb(rgb_o), .all_done(ad_o), .le(le_o));
    harness #(.NEW(1)) hn (.clk(clk), .rst(rst), .pv(pv_n), .li(li_n), .rgb(rgb_n), .all_done(ad_n), .le(le_n));

    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 20) $display("ERR %s", m); endtask
    reg [25:0] pix_o [$], pix_n [$];
    reg [3:0] rej_o = 0, rej_n = 0;
    always @(posedge clk) begin
        if (pv_o) pix_o.push_back({li_o, rgb_o});
        if (pv_n) pix_n.push_back({li_n, rgb_n});
        if (le_o) rej_o[ho.li] <= 1;
        if (le_n) rej_n[hn.li] <= 1;
    end
    initial begin
        int good, n_exp, first_bad;
        repeat (10) @(posedge clk); rst <= 0;
        wait (ad_o && ad_n); repeat (2000) @(posedge clk);
        // 期望：新版
        n_exp = 0; first_bad = -1;
        for (int k = 0; k < 4; k++) begin
            automatic bit exp_rej = bad_img(k) || (CASE == 2 && k == 1);
            if (rej_n[k] != exp_rej) fail($sformatf("image %0d rejected=%0d exp %0d", k, rej_n[k], exp_rej));
            if (exp_rej) continue;
            for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
                automatic int off = 54 + y*STRIDE + 3*x;
                automatic reg [25:0] e = {k[1:0], img_byte(k, off+2), img_byte(k, off+1), img_byte(k, off)};
                if (n_exp >= pix_n.size()) begin if (first_bad < 0) begin fail("new: too few pixels"); first_bad = n_exp; end end
                else if (pix_n[n_exp] !== e && first_bad < 0) begin
                    first_bad = n_exp; fail($sformatf("new pixel %0d (img %0d x %0d y %0d) = %h exp %h", n_exp, k, x, y, pix_n[n_exp], e));
                end
                n_exp++;
            end
        end
        if (pix_n.size() != n_exp) fail($sformatf("new pixel count %0d exp %0d", pix_n.size(), n_exp));
        // 新旧比较
        if (CASE != 2) begin
            if (rej_o !== rej_n) fail($sformatf("reject mask old %b new %b", rej_o, rej_n));
            if (W % 4 == 0) begin
                if (pix_o.size() != pix_n.size()) fail($sformatf("count old %0d new %0d", pix_o.size(), pix_n.size()));
                for (int i = 0; i < pix_o.size() && i < pix_n.size(); i++)
                    if (pix_o[i] !== pix_n[i]) begin fail($sformatf("old/new differ at %0d", i)); break; end
            end else begin
                automatic int d = 0;
                for (int i = 0; i < pix_o.size() && i < pix_n.size(); i++) if (pix_o[i] !== pix_n[i]) d++;
                $display("  (W%%4!=0: old version differs from new at %0d pixels — expected, old ignores row padding)", d);
            end
        end else begin
            $display("  CASE2: old reject mask %b (old accepts width high byte), new %b", rej_o, rej_n);
        end
        $display("DONE W=%0d H=%0d CASE=%0d pixels new=%0d old=%0d reject new=%b old=%b errs=%0d",
                 W, H, CASE, pix_n.size(), pix_o.size(), rej_n, rej_o, errs);
        $finish;
    end
    initial begin #100ms; $display("TIMEOUT errs=%0d", errs); $finish; end
endmodule

module harness #(parameter NEW = 0) (
    input clk, input rst,
    output pv, output [1:0] li, output [23:0] rgb, output all_done, output le
);
    wire ls, fc; reg lb = 0, ld = 0;
    always @(posedge clk) begin ld <= 0; if (ls) lb <= 1; if (lb && (fc || le)) begin lb <= 0; ld <= 1; end end
    generate if (NEW) begin : g_dut
        sd_card_bmp #(.BMP_WIDTH(tb.W), .BMP_HEIGHT(tb.H)) u (
            .clk(clk), .rst(rst), .state_code(), .Sdr_init_done(1'b1),
            .load_start(ls), .load_image_index(li), .load_busy(lb), .load_done(ld),
            .image_complete(4'd0), .pixel_valid(pv), .pixel_rgb(rgb), .frame_commit(fc),
            .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1), .decoder_error(), .load_error(le),
            .load_all_done(all_done),
            .aud_sector_req(1'b0), .aud_sector_lba(32'd0), .aud_sector_busy(), .aud_sector_valid(), .aud_sector_done(),
            .aud_sector_byte(), .aud_sector_error(), .aud_sector_byte_index(),
            .pcm_count(), .pcm_rd_idx(4'd0), .pcm_rd_lba(), .pcm_rd_sectors());
    end else begin : g_dut
        sd_card_bmp_old #(.BMP_WIDTH(tb.W), .BMP_HEIGHT(tb.H)) u (
            .clk(clk), .rst(rst), .state_code(), .Sdr_init_done(1'b1),
            .load_start(ls), .load_image_index(li), .load_busy(lb), .load_done(ld),
            .image_complete(4'd0), .pixel_valid(pv), .pixel_rgb(rgb), .frame_commit(fc),
            .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1), .decoder_error(), .load_error(le),
            .load_all_done(all_done),
            .aud_sector_req(1'b0), .aud_sector_lba(32'd0), .aud_sector_busy(), .aud_sector_valid(), .aud_sector_done(),
            .aud_sector_byte(), .aud_sector_error(), .aud_sector_byte_index(),
            .pcm_count(), .pcm_rd_idx(4'd0), .pcm_rd_lba(), .pcm_rd_sectors());
    end endgenerate
endmodule
