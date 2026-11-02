`timescale 1ns/1ps
// S2/S3 缩放验证：SCALE_ENABLE=1，输出缩小到 OW×OH 以加快仿真，4 张图各用不同的源尺寸。
//   vsim -gCASE=.. -gPAT=..
//   PAT 0：伪随机像素，只和定点黄金模型逐像素比较（必须完全相同）
//   PAT 1：线性渐变，另外和浮点双线性比较（误差 ≤ 2）
// 另外检查：输出像素数 = OW×OH、frame_commit 恰好 1 次、尺寸不合格的图被拒绝、缩放器无 overrun。
module tb;
    parameter integer CASE = 0, PAT = 0;
    parameter integer OW = 64, OH = 16, MAXW = 1024;   // CASE 4 用真实尺寸：-gOW=640 -gOH=480 -gMAXW=4096
    localparam integer BYTE_GAP = 4;

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    int sw [4], sh [4]; bit exp_rej [4];
    initial begin
        case (CASE)
            0: begin sw = '{64, 65, 100, 64};    sh = '{16, 17, 16, 40};   end
            1: begin sw = '{200, 257, 1000, 67}; sh = '{50, 33, 17, 300};  end
            2: begin sw = '{63, 64, 1025, 128};  sh = '{16, 15, 20, 32};   end   // 前 3 张应拒绝
            4: begin sw = '{1920, 640, 1280, 4096}; sh = '{1080, 480, 720, 482}; end  // 真实尺寸（OW=640, OH=480）
            default: begin sw = '{640, 1024, 641, 900}; sh = '{160, 37, 481, 16}; end
        endcase
        for (int k = 0; k < 4; k++) exp_rej[k] = (sw[k] < OW) || (sh[k] < OH) || (sw[k] > MAXW);
    end
    function automatic int stride(int k); return sw[k]*3 + (sw[k] % 4); endfunction
    function automatic int fbytes(int k); return 54 + stride(k)*sh[k]; endfunction
    function automatic byte unsigned src_c(int k, int x, int y, int c);   // c: 0=B 1=G 2=R
        if (PAT == 0) return (k*37 + x*13 + y*101 + c*59 + ((x*y) >> 3)) & 8'hff;
        case (c)
            0: return (x * 255) / (sw[k] - 1);
            1: return (y * 255) / (sh[k] - 1);
            default: return ((x + y) * 255) / (sw[k] + sh[k] - 2);
        endcase
    endfunction
    function automatic byte unsigned file_byte(int k, int off);
        case (off)
            0: return "B"; 1: return "M"; 10: return 54;
            18: return sw[k] & 255; 19: return (sw[k] >> 8) & 255;
            22: return sh[k] & 255; 23: return (sh[k] >> 8) & 255;
            28: return 24;
            default: begin
                int r, x;
                if (off < 54) return 0;
                r = (off - 54) / stride(k); x = (off - 54) % stride(k);
                if (x >= sw[k]*3) return 8'h5A;
                return src_c(k, x / 3, r, x % 3);
            end
        endcase
    endfunction

    // ---------------- 卡镜像 ----------------
    byte unsigned mem [longint];
    longint img_lba0 [4]; longint img_nsec [4];      // 图片数据所在扇区（连续簇，FAT 链仍逐簇登记）
    function automatic byte unsigned rd(longint lba, int i);
        for (int k = 0; k < 4; k++)
            if (lba >= img_lba0[k] && lba < img_lba0[k] + img_nsec[k]) begin
                automatic longint off = (lba - img_lba0[k]) * 512 + i;
                return (off < fbytes(k)) ? file_byte(k, off) : 8'h00;
            end
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
    initial begin
        int next_c; #1;
        wr8(0,0,8'heb); wr16(0,11,512); wr8(0,13,1); wr16(0,14,4); wr8(0,16,2);
        wr32(0,32,40000000); wr32(0,36,1024); wr32(0,44,2); wr8(0,510,8'h55); wr8(0,511,8'haa);
        // fat=4（1024 扇区）, data=4+2048=2052，LBA(c) = 2050 + c
        fat_set(2, 32'h0fffffff);
        for (int s = 0; s < 16; s++) wr8(2052, s*32, 8'he5);
        next_c = 10;
        for (int k = 0; k < 4; k++) begin
            automatic int n = (fbytes(k) + 511) / 512;
            dirent(2052, k, $sformatf("PIC%0d    BMP", k+1), next_c, fbytes(k));
            for (int q = 0; q < n; q++) fat_set(next_c + q, q == n-1 ? 32'h0fffffff : next_c + q + 1);
            img_lba0[k] = 2050 + next_c; img_nsec[k] = n;
            next_c += n + 3;
        end
        wr8(2052, 4*32, 8'h00);
    end

    // ---------------- DUT ----------------
    wire ls, fc, le, pv, ad; wire [1:0] li; wire [23:0] rgb; reg lb = 0, ld = 0;
    always @(posedge clk) begin ld <= 0; if (ls) lb <= 1; if (lb && (fc || le)) begin lb <= 0; ld <= 1; end end
    sd_card_bmp #(.BMP_WIDTH(OW), .BMP_HEIGHT(OH), .SCALE_ENABLE(1), .SCALE_MAX_W(MAXW)) u (
        .clk(clk), .rst(rst), .state_code(), .Sdr_init_done(1'b1),
        .load_start(ls), .load_image_index(li), .load_busy(lb), .load_done(ld),
        .image_complete(4'd0), .pixel_valid(pv), .pixel_rgb(rgb), .frame_commit(fc),
        .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1), .decoder_error(), .load_error(le),
        .load_all_done(ad),
        .aud_sector_req(1'b0), .aud_sector_lba(32'd0), .aud_sector_busy(), .aud_sector_valid(), .aud_sector_done(),
        .aud_sector_byte(), .aud_sector_error(), .aud_sector_byte_index(),
        .pcm_count(), .pcm_rd_idx(4'd0), .pcm_rd_lba(), .pcm_rd_sectors());

    // ---------------- 黄金模型（与 RTL 相同的定点算法）----------------
    function automatic byte unsigned lerp8(byte unsigned a, byte unsigned b, byte unsigned f);
        int d = int'(b) - int'(a); int m = d * int'(f);
        return (int'(a) + (m >>> 8)) & 255;
    endfunction
    function automatic [23:0] golden(int k, int i, int j);
        longint unsigned qx, qy, s, cx0, cy0, x, y; int xa, xb, ya, yb; byte unsigned fx, fy; reg [23:0] o;
        qx = (longint'(sw[k]-1) << 16) / (OW-1);
        qy = (longint'(sh[k]-1) << 16) / (OH-1);
        s = (qx < qy) ? qx : qy;
        cx0 = ((longint'(sw[k]-1) << 16) - s*(OW-1)) >> 1;
        cy0 = ((longint'(sh[k]-1) << 16) - s*(OH-1)) >> 1;
        x = cx0 + i*s; y = cy0 + j*s;
        xa = x >> 16; xb = xa + ((x & 16'hffff) != 0); fx = (x >> 8) & 255;
        ya = y >> 16; yb = ya + ((y & 16'hffff) != 0); fy = (y >> 8) & 255;
        for (int c = 0; c < 3; c++) begin
            byte unsigned t, b;
            t = lerp8(src_c(k, xa, ya, c), src_c(k, xb, ya, c), fx);
            b = lerp8(src_c(k, xa, yb, c), src_c(k, xb, yb, c), fx);
            o[c*8 +: 8] = lerp8(t, b, fy);
        end
        return o;
    endfunction
    function automatic real ideal(int k, int i, int j, int c);
        real s, x, y, fx, fy, v00, v01, v10, v11; int xa, ya, xb, yb;
        s = (real'(sw[k]-1)/(OW-1) < real'(sh[k]-1)/(OH-1)) ? real'(sw[k]-1)/(OW-1) : real'(sh[k]-1)/(OH-1);
        x = (real'(sw[k]-1) - s*(OW-1))/2.0 + i*s; y = (real'(sh[k]-1) - s*(OH-1))/2.0 + j*s;
        xa = $floor(x); ya = $floor(y); xb = (xa + 1 < sw[k]) ? xa + 1 : xa; yb = (ya + 1 < sh[k]) ? ya + 1 : ya;
        fx = x - xa; fy = y - ya;
        v00 = src_c(k, xa, ya, c); v01 = src_c(k, xb, ya, c); v10 = src_c(k, xa, yb, c); v11 = src_c(k, xb, yb, c);
        return (v00*(1-fx) + v01*fx)*(1-fy) + (v10*(1-fx) + v11*fx)*fy;
    endfunction

    // ---------------- 检查 ----------------
    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 20) $display("ERR %s", m); endtask
    reg [25:0] pix [$]; reg [3:0] rej = 0; integer commits [4] = '{0,0,0,0}; reg ovr = 0;
    always @(posedge clk) begin
        if (pv) pix.push_back({li, rgb});
        if (le) rej[li] <= 1;
        if (fc) commits[li]++;
        if (u.u_bmp_scaler.overrun) ovr <= 1;
    end
    initial begin
        int n; real maxe; maxe = 0;
        repeat (10) @(posedge clk); rst <= 0;
        wait (ad); repeat (3000) @(posedge clk);
        n = 0;
        for (int k = 0; k < 4; k++) begin
            if (rej[k] != exp_rej[k]) fail($sformatf("image %0d (%0dx%0d) rejected=%0d exp %0d", k, sw[k], sh[k], rej[k], exp_rej[k]));
            if (commits[k] != (exp_rej[k] ? 0 : 1)) fail($sformatf("image %0d commits=%0d", k, commits[k]));
            if (exp_rej[k]) continue;
            for (int j = 0; j < OH; j++) for (int i = 0; i < OW; i++) begin
                automatic reg [25:0] e = {k[1:0], golden(k, i, j)};
                if (n >= pix.size()) begin fail("too few pixels"); break; end
                if (pix[n] !== e) begin fail($sformatf("img %0d (%0dx%0d) out(%0d,%0d) = %h exp %h", k, sw[k], sh[k], i, j, pix[n][23:0], e[23:0])); end
                if (PAT == 1) for (int c = 0; c < 3; c++) begin
                    automatic real d = $sqrt((real'(pix[n][c*8 +: 8]) - ideal(k, i, j, c)) ** 2);
                    if (d > maxe) maxe = d;
                end
                n++;
            end
        end
        if (pix.size() != n) fail($sformatf("pixel count %0d exp %0d", pix.size(), n));
        if (PAT == 1 && maxe > 2.0) fail($sformatf("max error vs float bilinear %f", maxe));
        if (ovr) fail("scaler overrun");
        $display("DONE CASE=%0d PAT=%0d sizes %0dx%0d %0dx%0d %0dx%0d %0dx%0d reject=%b pixels=%0d maxerr=%0.2f errs=%0d",
                 CASE, PAT, sw[0], sh[0], sw[1], sh[1], sw[2], sh[2], sw[3], sh[3], rej, pix.size(), maxe, errs);
        $finish;
    end
    initial begin #3000ms; $display("TIMEOUT errs=%0d", errs); $finish; end
endmodule
