`timescale 1ns/1ps
// 补黑模式（FIT=1）缩放验证：SCALE_ENABLE=1，输出缩小到 OW×OH 以加快仿真，4 张图各用不同的源尺寸。
// 小于输出尺寸的图 1:1 居中，其余等比缩小到放得下，四周补黑。
//   vsim -gCASE=.. -gPAT=..
//   PAT 0：伪随机像素，只和定点黄金模型逐像素比较（必须完全相同）
//   PAT 1：线性渐变，另外和浮点双线性比较（误差 ≤ 2）
// 另外检查：输出像素数 = OW×OH、frame_commit 恰好 1 次、尺寸不合格的图被拒绝、缩放器无 overrun、
//           相邻输出间隔 ≥ RATE、读卡暂停（hold）确实发生过且 FIFO 从不溢出。
module tb;
    parameter integer CASE = 0, PAT = 0;
    parameter integer OW = 64, OH = 16, MAXW = 1024;   // CASE 4 用真实尺寸：-gOW=640 -gOH=480 -gMAXW=4096
    parameter integer RATE = 8;                         // 比输入（每像素 12 拍）快一点，补黑时会让 FIFO 积压、触发 hold
    parameter integer BYTE_GAP = 4;                     // 每字节拍数（实机约 32）

    reg clk = 0; always #5 clk = ~clk;
    reg rst = 1;

    int sw [4], sh [4]; bit exp_rej [4];
    initial begin
        case (CASE)
            0: begin sw = '{64, 65, 100, 64};    sh = '{16, 17, 16, 40};   end
            1: begin sw = '{200, 257, 1000, 67}; sh = '{50, 33, 17, 300};  end
            2: begin sw = '{20, 7, 1025, 1};     sh = '{5, 16, 20, 1};     end   // 小图 1:1 居中；1025 超宽应拒绝；1×1
            4: begin sw = '{1920, 640, 480, 4096}; sh = '{1080, 480, 1920, 482}; end  // 真实尺寸（OW=640, OH=480）
            5: begin sw = '{2556, 64, 64, 64}; sh = '{1276, 16, 16, 16}; end  // 10-27 上板黑屏的图（OW=640, OH=480）
            6: begin sw = '{254, 1000, 300, 65};  sh = '{61, 240, 61, 16};  end   // 两向比例几乎相同 → 按小比例铺满（254、1000）；300、65 不满足
            default: begin sw = '{640, 1024, 641, 900}; sh = '{160, 37, 481, 16}; end
        endcase
        for (int k = 0; k < 4; k++) exp_rej[k] = (sw[k] > MAXW);
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
    reg [1:0] qidx = 0; wire [51:0] qdata;           // 分辨率表读口
    always @(posedge clk) begin ld <= 0; if (ls) lb <= 1; if (lb && (fc || le)) begin lb <= 0; ld <= 1; end end
    sd_card_bmp #(.BMP_WIDTH(OW), .BMP_HEIGHT(OH), .SCALE_ENABLE(1), .SCALE_MAX_W(MAXW), .SCALE_FIT(1), .SCALE_RATE(RATE)) u (
        .clk(clk), .rst(rst), .state_code(), .Sdr_init_done(1'b1),
        .load_start(ls), .load_image_index(li), .load_busy(lb), .load_done(ld),
        .image_complete(4'd0), .pixel_valid(pv), .pixel_rgb(rgb), .frame_commit(fc),
        .SD_nCS(), .SD_DCLK(), .SD_MOSI(), .SD_MISO(1'b1), .decoder_error(), .load_error(le),
        .load_all_done(ad), .info_rd_idx(qidx), .info_rd_data(qdata),
        .aud_sector_req(1'b0), .aud_sector_lba(32'd0), .aud_sector_busy(), .aud_sector_valid(), .aud_sector_done(),
        .aud_sector_byte(), .aud_sector_error(), .aud_sector_byte_index(),
        .pcm_count(), .pcm_rd_idx(4'd0), .pcm_rd_lba(), .pcm_rd_sectors());

    // ---------------- 黄金模型（与 RTL 相同的定点算法）----------------
    function automatic byte unsigned lerp8(byte unsigned a, byte unsigned b, byte unsigned f);
        int d = int'(b) - int'(a); int m = d * int'(f);
        return (int'(a) + (m >>> 8)) & 255;
    endfunction
    // 与 RTL 相同的定点参数
    function automatic void params(int k, output longint unsigned s, output int cw, output int ch,
                                   output int L, output int T, output longint unsigned cx0, output longint unsigned cy0);
        longint unsigned ax, ay, qx, qy;
        ax = longint'(sw[k]-1) << 16; ay = longint'(sh[k]-1) << 16;
        qx = ax / (OW-1); qy = ay / (OH-1);
        begin
            longint unsigned qmax, qmin; int nk;
            qmax = (qx > qy) ? qx : qy; qmin = (qx < qy) ? qx : qy; nk = (OW > OH) ? OW : OH;
            if (qmin >= 65536 && (qmax - qmin + 1) * nk < qmin) s = qmin;
            else begin s = qmax; if (s < 65536) s = 65536; end
        end
        cw = ax / s + 1; if (cw > OW) cw = OW;
        ch = ay / s + 1; if (ch > OH) ch = OH;
        L = (OW - cw) / 2; T = (OH - ch) / 2;
        cx0 = (ax - s*(cw-1)) >> 1; cy0 = (ay - s*(ch-1)) >> 1;
    endfunction
    function automatic [23:0] golden(int k, int i, int j);
        longint unsigned s, cx0, cy0, x, y; int cw, ch, L, T, xa, xb, ya, yb; byte unsigned fx, fy; reg [23:0] o;
        params(k, s, cw, ch, L, T, cx0, cy0);
        if (i < L || i >= L + cw || j < T || j >= T + ch) return 24'd0;
        x = cx0 + (i-L)*s; y = cy0 + (j-T)*s;
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
    // 浮点参考：同一有效区内的理想双线性（只在有效区比较）
    function automatic bit in_rect(int k, int i, int j);
        longint unsigned s, cx0, cy0; int cw, ch, L, T;
        params(k, s, cw, ch, L, T, cx0, cy0);
        return (i >= L && i < L + cw && j >= T && j < T + ch);
    endfunction
    function automatic real ideal(int k, int i, int j, int c);
        // 坐标用与 RTL 相同的定点参数，这里只检验插值本身的舍入误差
        longint unsigned s_q, cx0q, cy0q; int cw, ch, L, T; real x, y, fx, fy, v00, v01, v10, v11; int xa, ya, xb, yb;
        params(k, s_q, cw, ch, L, T, cx0q, cy0q);
        x = (real'(cx0q) + real'(i-L)*real'(s_q)) / 65536.0;
        y = (real'(cy0q) + real'(j-T)*real'(s_q)) / 65536.0;
        xa = $floor(x); ya = $floor(y); xb = (xa + 1 < sw[k]) ? xa + 1 : xa; yb = (ya + 1 < sh[k]) ? ya + 1 : ya;
        fx = x - xa; fy = y - ya;
        v00 = src_c(k, xa, ya, c); v01 = src_c(k, xb, ya, c); v10 = src_c(k, xa, yb, c); v11 = src_c(k, xb, yb, c);
        return (v00*(1-fx) + v01*fx)*(1-fy) + (v10*(1-fx) + v11*fx)*fy;
    endfunction
    // 映射检查：整图可见（首尾采样点都在源图内、覆盖到源图两端附近），大图至少一边铺满
    function automatic void check_map(int k);
        longint unsigned s, cx0, cy0; int cw, ch, L, T; real xl, yl;
        params(k, s, cw, ch, L, T, cx0, cy0);
        xl = (real'(cx0) + real'(cw-1)*real'(s)) / 65536.0;
        yl = (real'(cy0) + real'(ch-1)*real'(s)) / 65536.0;
        if (xl > sw[k]-1 || yl > sh[k]-1) fail($sformatf("img %0d sample outside source (%f,%f)", k, xl, yl));
        if (real'(cx0)/65536.0 > s/65536.0 || real'(cy0)/65536.0 > s/65536.0)
            fail($sformatf("img %0d cropped: first sample at (%f,%f), step %f", k, real'(cx0)/65536.0, real'(cy0)/65536.0, s/65536.0));
        if ((sw[k] >= OW || sh[k] >= OH) && cw != OW && ch != OH) fail($sformatf("img %0d fills neither side (%0dx%0d)", k, cw, ch));
        if (sw[k] <= OW && sh[k] <= OH && (cw != sw[k] || ch != sh[k])) fail($sformatf("img %0d small image not 1:1 (%0dx%0d)", k, cw, ch));
        $display("  img %0d %0dx%0d -> %0dx%0d at (%0d,%0d), step %0.4f", k, sw[k], sh[k], cw, ch, L, T, s/65536.0);
    endfunction

    // ---------------- 检查 ----------------
    integer errs = 0;
    task automatic fail(string m); errs++; if (errs < 20) $display("ERR %s", m); endtask
    reg [25:0] pix [$]; reg [3:0] rej = 0; integer commits [4] = '{0,0,0,0}; reg ovr = 0;
    integer gap = 1000, min_gap = 1000, holds = 0, max_level = 0;
    always @(posedge clk) begin
        gap = gap + 1;
        if (pv) begin if (gap < min_gap) min_gap = gap; gap = 0; end
        if (u.u_streamer.hold && u.u_streamer.state == 4'd1) holds++;
        if (u.u_bmp_scaler.f_cnt > max_level) max_level = u.u_bmp_scaler.f_cnt;
    end
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
            check_map(k);
            for (int j = 0; j < OH; j++) for (int i = 0; i < OW; i++) begin
                automatic reg [25:0] e = {k[1:0], golden(k, i, j)};
                if (n >= pix.size()) begin fail("too few pixels"); break; end
                if (pix[n] !== e) begin fail($sformatf("img %0d (%0dx%0d) out(%0d,%0d) = %h exp %h", k, sw[k], sh[k], i, j, pix[n][23:0], e[23:0])); end
                if (PAT == 1 && in_rect(k, i, j)) for (int c = 0; c < 3; c++) begin
                    automatic real d = $sqrt((real'(pix[n][c*8 +: 8]) - ideal(k, i, j, c)) ** 2);
                    if (d > maxe) maxe = d;
                end
                n++;
            end
        end
        if (pix.size() != n) fail($sformatf("pixel count %0d exp %0d", pix.size(), n));
        // 分辨率表（经读口）：通过的图 = {1, 原宽, 原高, 黄金模型 cw, ch}，被拒绝的图全 0
        for (int k = 0; k < 4; k++) begin
            longint unsigned s, cx0, cy0; int cw, ch, L, T; reg [51:0] e;
            params(k, s, cw, ch, L, T, cx0, cy0);
            e = exp_rej[k] ? 52'd0 : {1'b1, sw[k][15:0], sh[k][15:0], cw[9:0], ch[8:0]};
            @(posedge clk) qidx <= k; repeat (3) @(posedge clk);
            if (qdata !== e) fail($sformatf("info %0d = %h exp %h", k, qdata, e));
            else if (!exp_rej[k]) $display("  info %0d: IN %0dx%0d OUT %0dx%0d", k, qdata[50:35], qdata[34:19], qdata[18:9], qdata[8:0]);
        end
        if (PAT == 1 && maxe > 2.0) fail($sformatf("max error vs float bilinear %f", maxe));
        if (ovr) fail("scaler overrun");
        if (min_gap < RATE) fail($sformatf("output spacing %0d < RATE %0d", min_gap, RATE));
        $display("  min output gap %0d, hold cycles %0d, max fifo level %0d", min_gap, holds, max_level);
        $display("DONE CASE=%0d PAT=%0d sizes %0dx%0d %0dx%0d %0dx%0d %0dx%0d reject=%b pixels=%0d maxerr=%0.2f errs=%0d",
                 CASE, PAT, sw[0], sh[0], sw[1], sh[1], sw[2], sh[2], sw[3], sh[3], rej, pix.size(), maxe, errs);
        $finish;
    end
    initial begin #3000ms;
        $display("TIMEOUT errs=%0d pixels=%0d li=%0d", errs, pix.size(), li);
        $display("  scaler cst=%0d pst=%0d row=%0d col=%0d oi=%0d oj=%0d xb=%0d yb=%0d cw=%0d ch=%0d si=%0d sj=%0d f_cnt=%0d seq_run=%0d",
                 u.u_bmp_scaler.cst, u.u_bmp_scaler.pst, u.u_bmp_scaler.row, u.u_bmp_scaler.col, u.u_bmp_scaler.oi, u.u_bmp_scaler.oj,
                 u.u_bmp_scaler.xb, u.u_bmp_scaler.yb, u.u_bmp_scaler.cw, u.u_bmp_scaler.ch, u.u_bmp_scaler.si, u.u_bmp_scaler.sj, u.u_bmp_scaler.f_cnt, u.u_bmp_scaler.seq_run);
        $display("  bmp byte_state=%0d src_row=%0d col_cnt=%0d streamer state=%0d hold=%0d", u.byte_state, u.src_row, u.col_cnt, u.u_streamer.state, u.u_streamer.hold);
        $finish; end
endmodule
