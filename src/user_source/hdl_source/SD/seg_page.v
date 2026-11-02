module seg_page(
    input clk,
    input rst_n,
    input [1:0] img_idx,     //图片编号
    input [7:0] volume,      //音量
    input [7:0] period_sec,  //轮播周期
    input event_pic,         //事件：切换图片
    input event_vol,         //事件：调节音量
    input [2:0] bmp_error,         //bmp_read:错误码
    output reg [4:0] seg_data_0,
    output reg [4:0] seg_data_1,
    output reg [4:0] seg_data_2,
    output reg [4:0] seg_data_3,
    output reg [4:0] seg_data_4,
    output reg [4:0] seg_data_5
    
);

localparam PAGE_PIC = 2'd0;
localparam PAGE_VOL = 2'd1;
localparam PAGE_PRD = 2'd2;

parameter PAGE_PERIOD_CYCLES = 50_000_000;  //1秒
parameter HOLD_CYCLES        = 100_000_000; //2秒

reg [31:0] page_cnt;
reg [31:0] hold_cnt;
reg [1:0]  page;
reg        hold_active;
//页面选择函数
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        page_cnt    <= 1'd0;
        page        <= PAGE_PIC;
        hold_cnt    <= 1'd0;
        hold_active <= 1'd0;
    end
    else if(event_pic) begin
        page        <= PAGE_PIC;
        page_cnt    <= 1'd0;
        hold_cnt    <= 1'd0;
        hold_active <= 1'd1;
    end
    else if(event_vol) begin
        page        <= PAGE_VOL;
        page_cnt    <= 1'd0;
        hold_cnt    <= 1'd0;
        hold_active <= 1'd1;
    end
    else if(hold_active) begin
        if(hold_cnt >= HOLD_CYCLES - 1) begin
            hold_active <= 1'd0;
            page        <= PAGE_PIC;
            hold_cnt    <= 1'd0;
            page_cnt    <= 1'd0;
        end
        else begin
            hold_cnt <= hold_cnt + 32'd1;
        end
    end
    else begin
        if(page_cnt >= PAGE_PERIOD_CYCLES - 1) begin
            page_cnt    <= 1'd0;
            if(page == PAGE_PRD) begin
                page <= PAGE_PIC;
            end
            else begin
                page <= page + 2'd1;
            end
        end
        else begin
            page_cnt <= page_cnt + 32'd1;
        end
    end
end

//音量BCD 转换
function [11:0] bin2bcd;
    input [7:0] bin;
    integer i;
    reg [19:0] shift;
    begin
        shift = {12'd0,bin};
        for(i = 0;i < 8;i = i + 1) begin
            if (shift[11:8] >= 5) shift[11:8] = shift[11:8] + 3;
            if (shift[15:12] >= 5) shift[15:12] = shift[15:12] + 3;
            if (shift[19:16] >= 5) shift[19:16] = shift[19:16] + 3;
            shift = shift << 1;
        end
        bin2bcd = shift[19:8];
    end
endfunction

wire [11:0] vol_bcd = bin2bcd(volume);

always @(*) begin
    seg_data_0 = 5'hF;
    seg_data_1 = 5'hF;
    seg_data_2 = 5'hF;
    seg_data_3 = 5'hF;
    seg_data_4 = 5'hF;
    seg_data_5 = 5'hF;
    if(bmp_error != 3'd0) begin
        seg_data_5 = {2'b0 + bmp_error};
        seg_data_4 = 5'd16; //R
        seg_data_3 = 5'd16; //R
        seg_data_2 = 5'he;  //E
    end else begin
        case(page)
        PAGE_PIC: begin
            seg_data_5 = {3'b0 + img_idx} + 5'd1;
            seg_data_4 = 5'hc; //C
            seg_data_3 = 5'd18;//I
            seg_data_2 = 5'd17;//P
        end
        PAGE_VOL: begin
            seg_data_5 = vol_bcd[3:0];
            seg_data_4 = vol_bcd[7:4];
            seg_data_3 = vol_bcd[11:8];
            seg_data_2 = 5'd19;//V
        end
        PAGE_PRD: begin
            seg_data_5 =  period_sec % 8'd10;
            seg_data_4 =  period_sec / 8'd10;
            seg_data_3 =  5'hd; //D
            seg_data_2 =  5'd16;//R
            seg_data_1 =  5'd17;//P
        end
    endcase
     end
    
end
endmodule

// 页面选择模块


