`timescale 1ns/1ps

// 扩展 3：BMP 流式双线性缩小，输出固定 OUT_W×OUT_H。
// 思路参考 freecores/video_stream_scaler（OpenCores，David Kronstein）：
//   定点坐标累加、只缓存用得到的输入行、4 点双线性。针对本工程的简化：
//   - 只缩小或 1:1，步长 s ≥ 1：每个输入像素最多产生 1 个输出像素，只需 1 行行缓冲。
//   - 输入很慢（SPI 25MHz，每像素约 96 拍），每个像素用 9 拍状态机顺序处理，只用 3 个乘法器。
// 两种模式：
//   FIT=1（默认）：整图可见，等比缩小到放得下，四周补黑；小于 OUT_W×OUT_H 的图 1:1 居中。
//   FIT=0：等比缩小到铺满，居中裁掉多出的部分（要求源图不小于 OUT_W×OUT_H）。
// 坐标映射（Q16 定点，"对齐角点"）：
//   qx = (W-1)/(OUT_W-1)，qy = (H-1)/(OUT_H-1)
//   s  = FIT ? max(qx, qy, 1.0) : min(qx, qy)
//   有效区 cw = min(floor((W-1)/s)+1, OUT_W)，ch 同理；居中：L = (OUT_W-cw)/2，T = (OUT_H-ch)/2
//   有效区第 c 列的源坐标 x = cx0 + c*s，cx0 = ((W-1) - (cw-1)*s)/2；y 同理
//   xa = floor(x)，xb = xa + (x 有小数)，权重取小数高 8 位。1:1 时每个输出像素就是对应的源像素。
// 输出：顺序器按 OUT_W×OUT_H 光栅顺序（与 BMP 文件行序相同）逐点输出，有效区内取内核结果，
//   区外补黑；每 RATE 拍最多输出 1 个像素（下游 SDRAM 写入通路没有反压）。
//   内核结果先进 512 深的 FIFO，fifo_level 用来让上游暂停读卡（以扇区为单位）。
module bmp_scaler_old #(
    parameter integer OUT_W = 640,
    parameter integer OUT_H = 480,
    parameter integer MAX_W = 4096,     // 行缓冲深度（源图最大宽度）
    parameter integer FIT   = 1,
    parameter integer RATE  = 32        // 输出间隔（拍）
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        abort,           // 新文件开始：清空顺序器和 FIFO
    // 头里宽高读齐后给一拍，开始算参数（约 75 拍）
    input  wire        cfg_start,
    input  wire [15:0] src_w,
    input  wire [15:0] src_h,
    output wire        cfg_ready,
    output wire [15:0] fit_w,           // 有效区（缩放后图片）宽高，cfg_ready 之后有效，给 OSD 显示用
    output wire [15:0] fit_h,
    input  wire        go,              // 头校验通过、进入像素区：启动顺序器
    // 源像素流：按文件顺序逐行、行内从左到右，相邻两个像素至少隔 12 拍
    input  wire        in_valid,
    input  wire [23:0] in_rgb,
    output reg         out_valid,
    output reg  [23:0] out_rgb,
    output reg         out_last,        // 与第 OUT_W*OUT_H 个输出像素同拍
    output wire [9:0]  fifo_level,
    output reg         overrun          // 粘滞：内核来不及处理 / FIFO 溢出（仅供仿真检查）
);
    localparam integer AW = (MAX_W <= 1024) ? 10 : (MAX_W <= 2048) ? 11 : (MAX_W <= 4096) ? 12 : 13;
    localparam [32:0] DX = OUT_W - 1;
    localparam [32:0] DY = OUT_H - 1;
    localparam integer RW = (RATE <= 2) ? 1 : $clog2(RATE);

    // ======================= 参数计算 =======================
    localparam [3:0] C_IDLE = 4'd0, C_DIV1 = 4'd1, C_SEL = 4'd2, C_DIV2 = 4'd3, C_CLAMP = 4'd4,
                     C_MUL = 4'd5, C_OFS = 4'd6, C_INIT = 4'd7, C_DONE = 4'd8;
    reg [3:0]  cst;
    reg [5:0]  div_cnt;
    reg [31:0] ax, ay;              // (W-1)<<16, (H-1)<<16
    reg [31:0] nx, ny;              // 被除数移位寄存器
    reg [32:0] rx, ry;              // 余数
    reg [31:0] qx, qy;              // 商
    reg [32:0] dvx, dvy;            // 除数
    reg [31:0] s;                   // 步长 Q16.16
    reg [15:0] cw, ch, ol, ot, orr, ob;   // 有效区宽高、左/上/右/下边界（右、下不含）
    reg [31:0] mx, my;
    reg [31:0] cx0, cy0;
    reg [15:0] sw_m1;
    wire [32:0] rx_sh = {rx[31:0], nx[31]};
    wire [32:0] ry_sh = {ry[31:0], ny[31]};
    wire [31:0] qmax = (qx > qy) ? qx : qy;
    wire [31:0] qmin = (qx < qy) ? qx : qy;
    assign cfg_ready = (cst == C_DONE);
    assign fit_w = cw;
    assign fit_h = ch;

    // ======================= 行缓冲（上一行） =======================
    reg [23:0]   lb [0:MAX_W-1];
    reg [AW-1:0] lb_raddr, lb_waddr;
    reg [23:0]   lb_wdata;
    reg          lb_we;
    reg [23:0]   lb_q;
    always @(posedge clk) begin
        if (lb_we)
            lb[lb_waddr] <= lb_wdata;
        lb_q <= lb[lb_raddr];
    end

    // ======================= 内核结果 FIFO =======================
    reg [23:0] fm [0:511];
    reg [8:0]  f_wp, f_rp;
    reg [9:0]  f_cnt;
    reg        f_we;
    reg [23:0] f_wd;
    reg [23:0] f_q;
    wire       f_pop;
    always @(posedge clk) begin
        if (f_we)
            fm[f_wp] <= f_wd;
        f_q <= fm[f_rp];
    end
    assign fifo_level = f_cnt;

    // ======================= 内核 =======================
    reg [15:0] col, row;
    reg [15:0] oi, oj;
    reg [31:0] x_acc, y_acc;
    reg [15:0] xa, xb, ya, yb;
    reg [7:0]  fx, fy;
    reg        x_same, y_same;
    reg [23:0] cur, prv, old_c, old_p;
    reg        emit;
    localparam [3:0] P_IDLE = 4'd0, P_RD = 4'd1, P_RD2 = 4'd2, P_TOP = 4'd3, P_BOT = 4'd4,
                     P_VER = 4'd5, P_XUPD = 4'd6, P_ADV = 4'd7, P_YUPD = 4'd8;
    reg [3:0] pst;
    wire row_hit = (oj < ch) && (row == yb);

    reg  [23:0] la, lbv;
    reg  [7:0]  lf;
    function [7:0] lerp8;
        input [7:0] a, b, f;
        reg signed [8:0]  d;
        reg signed [17:0] m;
        begin
            d = $signed({1'b0, b}) - $signed({1'b0, a});
            m = d * $signed({1'b0, f});
            lerp8 = a + m[15:8];          // m>>>8 的低 8 位，结果一定落在 a、b 之间
        end
    endfunction
    wire [23:0] lr = {lerp8(la[23:16], lbv[23:16], lf), lerp8(la[15:8], lbv[15:8], lf), lerp8(la[7:0], lbv[7:0], lf)};
    reg  [23:0] top_v, bot_v;
    wire [23:0] p00 = y_same ? (x_same ? cur : prv) : (x_same ? old_c : old_p);
    wire [23:0] p01 = y_same ? cur : old_c;
    wire [23:0] p10 = x_same ? cur : prv;
    wire [23:0] p11 = cur;

    // ======================= 顺序器 =======================
    reg        seq_arm, seq_run;
    reg [15:0] si, sj;
    reg [RW-1:0] rate_cnt;
    reg        out_pend, out_pend_in;
    reg        out_pend_last;
    wire       in_rect = (si >= ol) && (si < orr) && (sj >= ot) && (sj < ob);
    wire       slot    = seq_run && (rate_cnt == {RW{1'b0}});
    wire       take    = slot && (!in_rect || f_cnt != 10'd0);
    assign f_pop = take && in_rect;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cst <= C_IDLE; div_cnt <= 6'd0;
            ax <= 32'd0; ay <= 32'd0; nx <= 32'd0; ny <= 32'd0; rx <= 33'd0; ry <= 33'd0;
            qx <= 32'd0; qy <= 32'd0; dvx <= 33'd0; dvy <= 33'd0; s <= 32'd0;
            cw <= 16'd0; ch <= 16'd0; ol <= 16'd0; ot <= 16'd0; orr <= 16'd0; ob <= 16'd0;
            mx <= 32'd0; my <= 32'd0; cx0 <= 32'd0; cy0 <= 32'd0; sw_m1 <= 16'd0;
            pst <= P_IDLE;
            col <= 16'd0; row <= 16'd0; oi <= 16'd0; oj <= 16'd0;
            x_acc <= 32'd0; y_acc <= 32'd0;
            xa <= 16'd0; xb <= 16'd0; ya <= 16'd0; yb <= 16'd0; fx <= 8'd0; fy <= 8'd0;
            x_same <= 1'b0; y_same <= 1'b0;
            cur <= 24'd0; prv <= 24'd0; old_c <= 24'd0; old_p <= 24'd0; emit <= 1'b0;
            la <= 24'd0; lbv <= 24'd0; lf <= 8'd0; top_v <= 24'd0; bot_v <= 24'd0;
            lb_raddr <= {AW{1'b0}}; lb_waddr <= {AW{1'b0}}; lb_wdata <= 24'd0; lb_we <= 1'b0;
            f_wp <= 9'd0; f_rp <= 9'd0; f_cnt <= 10'd0; f_we <= 1'b0; f_wd <= 24'd0;
            seq_arm <= 1'b0; seq_run <= 1'b0; si <= 16'd0; sj <= 16'd0; rate_cnt <= {RW{1'b0}};
            out_pend <= 1'b0; out_pend_in <= 1'b0; out_pend_last <= 1'b0;
            out_valid <= 1'b0; out_rgb <= 24'd0; out_last <= 1'b0; overrun <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            out_last  <= 1'b0;
            lb_we     <= 1'b0;
            f_we      <= 1'b0;

            // ===== 参数计算 =====
            case (cst)
                C_DIV1, C_DIV2: begin
                    nx <= {nx[30:0], 1'b0};
                    ny <= {ny[30:0], 1'b0};
                    if (rx_sh >= dvx) begin rx <= rx_sh - dvx; qx <= {qx[30:0], 1'b1}; end
                    else              begin rx <= rx_sh;       qx <= {qx[30:0], 1'b0}; end
                    if (ry_sh >= dvy) begin ry <= ry_sh - dvy; qy <= {qy[30:0], 1'b1}; end
                    else              begin ry <= ry_sh;       qy <= {qy[30:0], 1'b0}; end
                    div_cnt <= div_cnt + 6'd1;
                    if (div_cnt == 6'd31) cst <= (cst == C_DIV1) ? C_SEL : C_CLAMP;
                end
                C_SEL: begin
                    if (FIT) s <= (qmax < 32'h0001_0000) ? 32'h0001_0000 : qmax;
                    else     s <= qmin;
                    cst <= C_DIV2;
                end
                default: ;
            endcase
            if (cst == C_SEL) begin                         // 第二次除法：(W-1)<<16 / s
                div_cnt <= 6'd0;
                nx <= ax; ny <= ay; rx <= 33'd0; ry <= 33'd0; qx <= 32'd0; qy <= 32'd0;
                dvx <= {1'b0, FIT ? ((qmax < 32'h0001_0000) ? 32'h0001_0000 : qmax) : qmin};
                dvy <= {1'b0, FIT ? ((qmax < 32'h0001_0000) ? 32'h0001_0000 : qmax) : qmin};
            end
            if (cst == C_CLAMP) begin
                cw  <= (qx >= OUT_W - 1) ? OUT_W[15:0] : qx[15:0] + 16'd1;
                ch  <= (qy >= OUT_H - 1) ? OUT_H[15:0] : qy[15:0] + 16'd1;
                cst <= C_MUL;
            end
            if (cst == C_MUL) begin
                mx  <= s * (cw - 16'd1);
                my  <= s * (ch - 16'd1);
                ol  <= (OUT_W[15:0] - cw) >> 1;
                ot  <= (OUT_H[15:0] - ch) >> 1;
                orr <= ((OUT_W[15:0] - cw) >> 1) + cw;
                ob  <= ((OUT_H[15:0] - ch) >> 1) + ch;
                cst <= C_OFS;
            end
            if (cst == C_OFS) begin
                cx0 <= (ax - mx) >> 1;
                cy0 <= (ay - my) >> 1;
                cst <= C_INIT;
            end
            if (cst == C_INIT) begin
                x_acc <= cx0;
                y_acc <= cy0;
                xa <= cx0[31:16]; xb <= cx0[31:16] + (cx0[15:0] != 16'd0); fx <= cx0[15:8]; x_same <= (cx0[15:0] == 16'd0);
                ya <= cy0[31:16]; yb <= cy0[31:16] + (cy0[15:0] != 16'd0); fy <= cy0[15:8]; y_same <= (cy0[15:0] == 16'd0);
                cst <= C_DONE;
            end
            if (cfg_start) begin
                cst     <= C_DIV1;
                div_cnt <= 6'd0;
                ax <= {src_w - 16'd1, 16'd0};
                ay <= {src_h - 16'd1, 16'd0};
                nx <= {src_w - 16'd1, 16'd0};
                ny <= {src_h - 16'd1, 16'd0};
                rx <= 33'd0; ry <= 33'd0; qx <= 32'd0; qy <= 32'd0;
                dvx <= DX; dvy <= DY;
                sw_m1 <= src_w - 16'd1;
                pst <= P_IDLE;
                col <= 16'd0; row <= 16'd0; oi <= 16'd0; oj <= 16'd0;
            end

            // ===== 内核：逐像素处理 =====
            if (in_valid && (pst != P_IDLE || !cfg_ready))
                overrun <= 1'b1;
            case (pst)
                P_IDLE: if (in_valid && cfg_ready && !cfg_start) begin
                    prv      <= cur;
                    cur      <= in_rgb;
                    old_p    <= old_c;
                    lb_raddr <= col[AW-1:0];
                    emit     <= row_hit && (oi < cw) && (col == xb);
                    pst      <= P_RD;
                end
                P_RD:  pst <= P_RD2;                          // lb_q <= lb[col]
                P_RD2: begin
                    old_c    <= lb_q;                         // 上一行同列
                    lb_we    <= 1'b1;                         // 读完再写：本行像素覆盖上一行
                    lb_waddr <= col[AW-1:0];
                    lb_wdata <= cur;
                    pst      <= emit ? P_TOP : P_ADV;
                end
                P_TOP: begin                                  // 上一行（ya）水平插值
                    la <= p00; lbv <= p01; lf <= fx;
                    pst <= P_BOT;
                end
                P_BOT: begin
                    top_v <= lr;
                    la <= p10; lbv <= p11; lf <= fx;          // 本行（yb）水平插值
                    pst <= P_VER;
                end
                P_VER: begin
                    bot_v <= lr;
                    pst <= P_XUPD;
                end
                P_XUPD: begin
                    la <= top_v; lbv <= bot_v; lf <= fy;      // 竖直插值，下一拍出结果
                    x_acc <= x_acc + s;
                    oi    <= oi + 16'd1;
                    pst   <= P_ADV;
                end
                P_ADV: begin
                    if (emit) begin
                        f_we  <= 1'b1;
                        f_wd  <= lr;
                        emit  <= 1'b0;
                    end
                    xa <= x_acc[31:16]; xb <= x_acc[31:16] + (x_acc[15:0] != 16'd0);
                    fx <= x_acc[15:8];  x_same <= (x_acc[15:0] == 16'd0);
                    if (col == sw_m1) begin                   // 行末
                        col <= 16'd0;
                        row <= row + 16'd1;
                        if (row_hit) begin
                            oj    <= oj + 16'd1;
                            y_acc <= y_acc + s;
                        end
                        oi    <= 16'd0;
                        x_acc <= cx0;
                        pst   <= P_YUPD;
                    end else begin
                        col <= col + 16'd1;
                        pst <= P_IDLE;
                    end
                end
                P_YUPD: begin
                    ya <= y_acc[31:16]; yb <= y_acc[31:16] + (y_acc[15:0] != 16'd0);
                    fy <= y_acc[15:8];  y_same <= (y_acc[15:0] == 16'd0);
                    xa <= cx0[31:16]; xb <= cx0[31:16] + (cx0[15:0] != 16'd0);
                    fx <= cx0[15:8];  x_same <= (cx0[15:0] == 16'd0);
                    pst <= P_IDLE;
                end
                default: pst <= P_IDLE;
            endcase

            // ===== FIFO 指针 =====
            if (f_we) f_wp <= f_wp + 9'd1;
            if (f_pop) f_rp <= f_rp + 9'd1;
            case ({f_we, f_pop})
                2'b10: begin f_cnt <= f_cnt + 10'd1; if (f_cnt == 10'd512) overrun <= 1'b1; end
                2'b01: f_cnt <= f_cnt - 10'd1;
                default: ;
            endcase

            // ===== 顺序器：光栅顺序输出，区外补黑 =====
            if (go) seq_arm <= 1'b1;
            if (seq_arm && cfg_ready && !seq_run) begin
                seq_arm  <= 1'b0;
                seq_run  <= 1'b1;
                si <= 16'd0; sj <= 16'd0;
                rate_cnt <= {RW{1'b0}};
            end
            if (seq_run && rate_cnt != {RW{1'b0}})
                rate_cnt <= rate_cnt - 1'b1;
            out_pend <= 1'b0;
            if (take) begin
                out_pend      <= 1'b1;
                out_pend_in   <= in_rect;
                out_pend_last <= (si == OUT_W - 1) && (sj == OUT_H - 1);
                rate_cnt      <= RATE - 1;
                if (si == OUT_W - 1) begin
                    si <= 16'd0;
                    sj <= sj + 16'd1;
                    if (sj == OUT_H - 1) seq_run <= 1'b0;
                end else begin
                    si <= si + 16'd1;
                end
            end
            if (out_pend) begin                           // f_q 在 take 那拍已读出 fm[f_rp]
                out_valid <= 1'b1;
                out_rgb   <= out_pend_in ? f_q : 24'd0;
                out_last  <= out_pend_last;
            end

            if (abort) begin
                seq_arm <= 1'b0; seq_run <= 1'b0; out_pend <= 1'b0;
                f_wp <= 9'd0; f_rp <= 9'd0; f_cnt <= 10'd0;
                pst <= P_IDLE; emit <= 1'b0;
            end
        end
    end
endmodule
