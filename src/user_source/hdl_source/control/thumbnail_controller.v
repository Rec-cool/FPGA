// thumbnail_controller.v —— 第14课练习骨架（完赛工程未实现）
module thumbnail_controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sw3,
    input  wire        focus_left,
    input  wire        focus_right,
    input  wire [3:0]  image_complete,
    input  wire [1:0]  current_index,// 输入media_player_control的当前图号
    output wire         view_mode,   // 0=全屏 1=缩略图
    output reg [1:0]   focus_index,
    output reg [1:0]   select_index,
    output reg         select_event
   

);
    // 复位初值：全屏、焦点0、当前图0
    // TODO(学员完成1)：key_mode 翻转 view_mode，并产生一个周期 transition_req
    // TODO(学员完成2)：只有 view_mode==1（缩略图）时才响应方向键：
    //     key_right -> focus_index+1，到 2'd3 后 wrap 回 2'd0；
    //     key_left  -> focus_index-1，到 2'd0 后 wrap 回 2'd3；
    //     全屏模式下方向键留给上一张/下一张，不动 focus_index。
    // TODO(学员完成3)：key_confirm 时 active_index = focus_index；view_mode=0(全屏)；transition_req=1。
    //     （注意：focus_index 指向的图若未加载，应忽略或提示，可用 image_complete[focus_index] 判断）
    // TODO(学员完成4)：以上寄存器变化在 frame_start 锁存/生效，避免一帧内坐标切换撕裂；
    //     transition_req 是单拍脉冲，拍宽1拍后自动拉低。
    // SW3 消抖：同步 + 20ms 稳定计数，rise/fall 与 sw3_stable 同拍
    wire sw3_stable, enter_thumb, confirm;
    signal_level_debounce #(
        .CLK_FREQ_HZ (100_000_000),
        .DEBOUNCE_MS (20),
        .INIT_LEVEL  (1'b0)          // 复位为全屏
    ) u_sw3_debounce (
        .clk    (clk),
        .rst_n  (rst_n),
        .din    (sw3),
        .stable (sw3_stable),
        .rise   (enter_thumb),       // 0→1：进入缩略图
        .fall   (confirm)            // 1→0：确认
    );
    // view_mode 晚 sw3_stable 一拍，与 select_event 同拍下降，
    // 顶层 thumb_view_sd 用 view_mode | jump_accept | jump_pending 才不会漏出 0
    reg view_mode_r;
    assign view_mode = view_mode_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            view_mode_r  <= 1'b0;
            focus_index  <= 2'd0;
            select_index <= 2'd0;
            select_event <= 1'b0;
        end else begin
            view_mode_r  <= sw3_stable;
            select_event <= 1'b0;
            // 进入缩略图
            if(enter_thumb) 
                focus_index <= current_index;
            else if(focus_right)
                focus_index <= focus_index + 2'd1;
            else if(focus_left)
                focus_index <= focus_index - 2'd1;
            if(confirm && image_complete[focus_index]) begin
                select_event <= 1'b1;
                select_index <= focus_index;
            end

        end
    end
endmodule
