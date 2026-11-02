// brightness_contrast_adjust.v —— 第13课练习骨架（完赛工程未单独实现）
module brightness_contrast_adjust (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_de,
    input  wire [23:0] rgb_in,
    input  wire [7:0]  brightness,   // 帧边界锁存后的亮度
    input  wire [7:0]  contrast,     // 帧边界锁存后的对比度
    output wire         out_de,
    output wire  [23:0] rgb_out
);
    // ---- 亮度通路（已给）：每通道 × brightness 后取高8位，即 /256 ----
    wire [16:0] mul_r = rgb_in[23:16] * ({1'b0 ,brightness} + 9'd1);
    wire [16:0] mul_g = rgb_in[15:8]  * ({1'b0 ,brightness} + 9'd1);
    wire [16:0] mul_b = rgb_in[7:0]   * ({1'b0 ,brightness} + 9'd1);
    wire [7:0] bright_r = mul_r[15:8];
    wire [7:0] bright_g = mul_g[15:8];
    wire [7:0] bright_b = mul_b[15:8];

    wire signed [8:0] center_r =  $signed({1'b0 , bright_r}) - 9'sd128;
    wire signed [8:0] center_g =  $signed({1'b0 , bright_g}) - 9'sd128;
    wire signed [8:0] center_b =  $signed({1'b0 , bright_b}) - 9'sd128;

    wire signed [16:0] scaled_r = center_r * $signed({1'b0 ,contrast}) >>>7;
    wire signed [16:0] scaled_g = center_g * $signed({1'b0 ,contrast}) >>>7;
    wire signed [16:0] scaled_b = center_b * $signed({1'b0 ,contrast}) >>>7;

    wire signed [9:0] y_r = scaled_r + 10'sd128;
    wire signed [9:0] y_g = scaled_g + 10'sd128;
    wire signed [9:0] y_b = scaled_b + 10'sd128;

    function [7:0] saturate;
        input signed [9:0] y;
        begin
        if (y < 0)
            saturate = 8'd0;
        else if (y > 255)
            saturate = 8'd255;
        else
            saturate = y[7:0];     // 0~255 范围内，低 8 位就是原值
    end
endfunction
    // ===== TODO(学员完成)：对比度 + 饱和截断 =====
    // 对 bright_r/g/b 分别做：
    //   center = x - 128;
    //   scaled = center * contrast / 128;   // /128 用算术右移7位 >>>7
    //   y      = scaled + 128;
    //   final  = saturate(y)  即 y<0 取0、y>255 取255，否则取y
    // 注意 center/scaled 是有符号数，请用 signed 声明并给足位宽防止溢出。
    // 下面三行是直通占位，补完后删掉直通、换成你的对比度结果：
    wire [7:0] final_r = saturate(y_r);
    wire [7:0] final_g = saturate(y_g);
    wire [7:0] final_b = saturate(y_b);

    assign out_de = in_de;
    assign rgb_out = {final_r, final_g, final_b};
endmodule
