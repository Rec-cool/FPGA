`timescale 1ns/1ps

module fat32_volume_scanner_old (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        scan_start,
    output wire        scan_busy,
    output reg         scan_done,
    output reg  [7:0]  fs_error,
    output reg  [31:0] partition_lba,
    output reg  [7:0]  sectors_per_cluster,
    output reg  [31:0] fat_start_lba,
    output reg  [31:0] data_start_lba,
    output reg  [31:0] max_cluster,
    output reg  [3:0]  resource_valid,
    output reg  [31:0] resource0_cluster,
    output reg  [31:0] resource1_cluster,
    output reg  [31:0] resource2_cluster,
    output reg  [31:0] resource3_cluster,
    output reg  [31:0] resource0_size,
    output reg  [31:0] resource1_size,
    output reg  [31:0] resource2_size,
    output reg  [31:0] resource3_size,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);

    localparam ERR_NONE            = 8'h00;
    localparam ERR_SECTOR          = 8'h10;
    localparam ERR_BOOT_SIGNATURE  = 8'h20;
    localparam ERR_UNSUPPORTED_BPB = 8'h21;
    localparam ERR_RESOURCE_MISSING= 8'h22;
    localparam ERR_DIR_CHAIN       = 8'h27;   // 根目录FAT链异常（越界/过长）
    localparam [7:0] MAX_DIR_CLUSTERS = 8'd64; // 根目录最多遍历的簇数

    localparam ST_IDLE       = 4'd0;
    localparam ST_READ0_REQ  = 4'd1;
    localparam ST_READ0_WAIT = 4'd2;
    localparam ST_BOOT_PARSE = 4'd3;
    localparam ST_BOOT_REQ   = 4'd4;
    localparam ST_BOOT_WAIT  = 4'd5;
    localparam ST_ROOT_REQ   = 4'd6;
    localparam ST_ROOT_WAIT  = 4'd7;
    localparam ST_DIR_SCAN   = 4'd8;
    localparam ST_FINISH     = 4'd9;
    localparam ST_BOOT_LAYOUT= 4'd10;
    localparam ST_BOOT_ROOT  = 4'd11;
    localparam ST_FAT_REQ    = 4'd12;   // 读根目录当前簇的FAT表项
    localparam ST_FAT_WAIT   = 4'd13;
    localparam ST_FAT_PARSE  = 4'd14;

    reg [3:0] state;
    // 引导扇区/MBR 只用到下面这些字段：字节流入时按下标直接抓取，
    // 不再缓存整个 512 字节扇区（原 sector_buffer 被综合成约千个触发器）。
    reg [7:0]  bs_jump;        // [0]        跳转指令 EB/E9
    reg [15:0] bs_bps;         // [11..12]   每扇区字节数
    reg [7:0]  bs_spc;         // [13]       每簇扇区数
    reg [15:0] bs_rsvd;        // [14..15]   保留扇区数
    reg [7:0]  bs_nfat;        // [16]       FAT 个数
    reg [15:0] bs_root_ent;    // [17..18]   FAT12/16 根目录项数（FAT32 为 0）
    reg [15:0] bs_fatsz16;     // [22..23]   FAT12/16 FAT 大小（FAT32 为 0）
    reg [31:0] bs_totsec32;    // [32..35]
    reg [31:0] bs_fatsz32;     // [36..39]
    reg [31:0] bs_root_clus;   // [44..47]
    reg [7:0]  mbr_type;       // [450]      分区1类型
    reg [31:0] mbr_lba;        // [454..457] 分区1起始 LBA
    reg [7:0]  sig0, sig1;     // [510..511] 55 AA
    reg [4:0] directory_entry_index;
    reg [31:0] root_cluster;
    reg [31:0] total_sectors;
    reg [31:0] fat_sectors;
    reg [7:0] fat_count;
    reg [15:0] reserved_sectors;
    reg [31:0] root_lba;
    reg [31:0] data_sector_count;
    reg [31:0] fat_span;
    reg [2:0] sectors_per_cluster_shift;
    reg [7:0] dir_name0;
    reg [7:0] dir_name1;
    reg [7:0] dir_name2;
    reg [7:0] dir_name3;
    reg [7:0] dir_name4;
    reg [7:0] dir_name5;
    reg [7:0] dir_name6;
    reg [7:0] dir_name7;
    reg [7:0] dir_name8;
    reg [7:0] dir_name9;
    reg [7:0] dir_name10;
    reg       dir_entry_match;
    reg [1:0] dir_resource_index;
    reg [15:0] dir_cluster_high;
    reg [15:0] dir_cluster_low;
    reg [31:0] dir_file_size;
    // 根目录多扇区/多簇遍历
    reg [7:0]  root_sector_index;   // 当前簇内的扇区号
    reg [31:0] dir_cluster;         // 当前正在扫描的根目录簇
    reg [7:0]  dir_cluster_count;   // 已遍历簇数，防止FAT链成环
    reg        dir_end_seen;        // 遇到目录结束标志(首字节0x00)
    reg [8:0]  fat_entry_offset;
    reg [7:0]  fat_byte0, fat_byte1, fat_byte2, fat_byte3;
    wire [31:0] fat_next_cluster = {4'd0, fat_byte3[3:0], fat_byte2, fat_byte1, fat_byte0};

    assign scan_busy = (state != ST_IDLE);

    function valid_spc;
        input [7:0] value;
        begin
            valid_spc = value != 0 && ((value & (value - 1'b1)) == 0);
        end
    endfunction

    function [2:0] spc_shift;
        input [7:0] value;
        begin
            case (value)
                8'd2:   spc_shift = 3'd1;
                8'd4:   spc_shift = 3'd2;
                8'd8:   spc_shift = 3'd3;
                8'd16:  spc_shift = 3'd4;
                8'd32:  spc_shift = 3'd5;
                8'd64:  spc_shift = 3'd6;
                8'd128: spc_shift = 3'd7;
                default: spc_shift = 3'd0;
            endcase
        end
    endfunction

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    // 根目录跟链时的簇号→LBA 基址（data_start_lba - 2*每簇扇区数），提前寄存。
    // ST_FAT_PARSE 距离 ST_BOOT_LAYOUT 很多拍，基址早已稳定；关键路径去掉一个减法器。
    always @(posedge clk) begin
        if (sector_valid && (state == ST_READ0_WAIT || state == ST_BOOT_WAIT)) begin
            case (sector_byte_index)
                9'd0:   bs_jump             <= sector_byte;
                9'd11:  bs_bps[7:0]         <= sector_byte;
                9'd12:  bs_bps[15:8]        <= sector_byte;
                9'd13:  bs_spc              <= sector_byte;
                9'd14:  bs_rsvd[7:0]        <= sector_byte;
                9'd15:  bs_rsvd[15:8]       <= sector_byte;
                9'd16:  bs_nfat             <= sector_byte;
                9'd17:  bs_root_ent[7:0]    <= sector_byte;
                9'd18:  bs_root_ent[15:8]   <= sector_byte;
                9'd22:  bs_fatsz16[7:0]     <= sector_byte;
                9'd23:  bs_fatsz16[15:8]    <= sector_byte;
                9'd32:  bs_totsec32[7:0]    <= sector_byte;
                9'd33:  bs_totsec32[15:8]   <= sector_byte;
                9'd34:  bs_totsec32[23:16]  <= sector_byte;
                9'd35:  bs_totsec32[31:24]  <= sector_byte;
                9'd36:  bs_fatsz32[7:0]     <= sector_byte;
                9'd37:  bs_fatsz32[15:8]    <= sector_byte;
                9'd38:  bs_fatsz32[23:16]   <= sector_byte;
                9'd39:  bs_fatsz32[31:24]   <= sector_byte;
                9'd44:  bs_root_clus[7:0]   <= sector_byte;
                9'd45:  bs_root_clus[15:8]  <= sector_byte;
                9'd46:  bs_root_clus[23:16] <= sector_byte;
                9'd47:  bs_root_clus[31:24] <= sector_byte;
                9'd450: mbr_type            <= sector_byte;
                9'd454: mbr_lba[7:0]        <= sector_byte;
                9'd455: mbr_lba[15:8]       <= sector_byte;
                9'd456: mbr_lba[23:16]      <= sector_byte;
                9'd457: mbr_lba[31:24]      <= sector_byte;
                9'd510: sig0                <= sector_byte;
                9'd511: sig1                <= sector_byte;
                default: ;
            endcase
        end
    end

    reg [31:0] dir_lba_base;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            dir_lba_base <= 32'd0;
        else
            dir_lba_base <= data_start_lba - (32'd2 << sectors_per_cluster_shift);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            scan_done <= 1'b0;
            fs_error <= ERR_NONE;
            partition_lba <= 32'd0;
            sectors_per_cluster <= 8'd0;
            fat_start_lba <= 32'd0;
            data_start_lba <= 32'd0;
            max_cluster <= 32'd0;
            resource_valid <= 4'd0;
            resource0_cluster <= 32'd0;
            resource1_cluster <= 32'd0;
            resource2_cluster <= 32'd0;
            resource3_cluster <= 32'd0;
            resource0_size <= 32'd0;
            resource1_size <= 32'd0;
            resource2_size <= 32'd0;
            resource3_size <= 32'd0;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            directory_entry_index <= 5'd0;
            root_cluster <= 32'd0;
            total_sectors <= 32'd0;
            fat_sectors <= 32'd0;
            fat_count <= 8'd0;
            reserved_sectors <= 16'd0;
            root_lba <= 32'd0;
            data_sector_count <= 32'd0;
            fat_span <= 32'd0;
            sectors_per_cluster_shift <= 3'd0;
            dir_name0 <= 8'd0;
            dir_name1 <= 8'd0;
            dir_name2 <= 8'd0;
            dir_name3 <= 8'd0;
            dir_name4 <= 8'd0;
            dir_name5 <= 8'd0;
            dir_name6 <= 8'd0;
            dir_name7 <= 8'd0;
            dir_name8 <= 8'd0;
            dir_name9 <= 8'd0;
            dir_name10 <= 8'd0;
            dir_entry_match <= 1'b0;
            dir_resource_index <= 2'd3;
            dir_cluster_high <= 16'd0;
            dir_cluster_low <= 16'd0;
            dir_file_size <= 32'd0;
            root_sector_index <= 8'd0;
            dir_cluster <= 32'd0;
            dir_cluster_count <= 8'd0;
            dir_end_seen <= 1'b0;
            fat_entry_offset <= 9'd0;
            fat_byte0 <= 8'd0;
            fat_byte1 <= 8'd0;
            fat_byte2 <= 8'd0;
            fat_byte3 <= 8'd0;
        end else begin
            scan_done <= 1'b0;
            sector_req <= 1'b0;

            // 读FAT扇区时只抓取当前簇对应的4字节表项
            if (sector_valid && state == ST_FAT_WAIT) begin
                if (sector_byte_index == fat_entry_offset)
                    fat_byte0 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 9'd1)
                    fat_byte1 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 9'd2)
                    fat_byte2 <= sector_byte;
                else if (sector_byte_index == fat_entry_offset + 9'd3)
                    fat_byte3 <= sector_byte;
            end

            // 目录项首字节为0x00表示后面再无有效目录项
            if (sector_valid && state == ST_ROOT_WAIT &&
                sector_byte_index[4:0] == 5'd0 && sector_byte == 8'h00)
                dir_end_seen <= 1'b1;

            if (sector_valid && state == ST_ROOT_WAIT) begin
                case (sector_byte_index[4:0])
                    5'd0: begin
                        dir_name0 <= sector_byte;
                        dir_entry_match <= 1'b0;
                    end
                    5'd1:  dir_name1 <= sector_byte;
                    5'd2:  dir_name2 <= sector_byte;
                    5'd3:  dir_name3 <= sector_byte;
                    5'd4:  dir_name4 <= sector_byte;
                    5'd5:  dir_name5 <= sector_byte;
                    5'd6:  dir_name6 <= sector_byte;
                    5'd7:  dir_name7 <= sector_byte;
                    5'd8:  dir_name8 <= sector_byte;
                    5'd9:  dir_name9 <= sector_byte;
                    5'd10: dir_name10 <= sector_byte;
                    5'd11: begin
                        // 属性：排除卷标(0x08)/目录(0x10)/长文件名项(0x0F)，
                        // 只读、隐藏、存档等位不影响匹配
                        if ((sector_byte & 8'h18) == 8'h00 &&
                            dir_name0 == "P" && dir_name1 == "I" &&
                            dir_name2 == "C" && dir_name3 >= "1" &&
                            dir_name3 <= "4" && dir_name4 == " " &&
                            dir_name5 == " " && dir_name6 == " " &&
                            dir_name7 == " " && dir_name8 == "B" &&
                            dir_name9 == "M" && dir_name10 == "P") begin
                            dir_entry_match <= 1'b1;
                            dir_resource_index <= dir_name3 - "1";
                        end
                    end
                    5'd20: dir_cluster_high[7:0] <= sector_byte;
                    5'd21: dir_cluster_high[15:8] <= sector_byte;
                    5'd26: dir_cluster_low[7:0] <= sector_byte;
                    5'd27: dir_cluster_low[15:8] <= sector_byte;
                    5'd28: dir_file_size[7:0] <= sector_byte;
                    5'd29: dir_file_size[15:8] <= sector_byte;
                    5'd30: dir_file_size[23:16] <= sector_byte;
                    5'd31: begin
                        dir_file_size[31:24] <= sector_byte;
                        if (dir_entry_match) begin
                            case (dir_resource_index)
                                2'd0: begin
                                    resource0_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource0_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[0] <= 1'b1;
                                end
                                2'd1: begin
                                    resource1_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource1_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[1] <= 1'b1;
                                end
                                2'd2: begin
                                    resource2_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource2_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[2] <= 1'b1;
                                end
                                default: begin
                                    resource3_cluster <= {dir_cluster_high, dir_cluster_low};
                                    resource3_size <= {sector_byte, dir_file_size[23:0]};
                                    resource_valid[3] <= 1'b1;
                                end
                            endcase
                        end
                    end
                    default: begin end
                endcase
            end

            case (state)
                ST_IDLE: if (scan_start) begin
                    fs_error <= ERR_NONE;
                    partition_lba <= 32'd0;
                    resource_valid <= 4'd0;
                    state <= ST_READ0_REQ;
                end
                ST_READ0_REQ: if (!sector_busy) begin
                    sector_lba <= 32'd0;
                    sector_req <= 1'b1;
                    state <= ST_READ0_WAIT;
                end
                ST_READ0_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sig0 != 8'h55 || sig1 != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else if (bs_jump == 8'heb || bs_jump == 8'he9) begin
                        partition_lba <= 32'd0;
                        state <= ST_BOOT_PARSE;
                    end else if (mbr_type == 8'h0b || mbr_type == 8'h0c) begin
                        partition_lba <= mbr_lba;
                        sector_lba <= mbr_lba;
                        state <= ST_BOOT_REQ;
                    end else begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end
                end
                ST_BOOT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_BOOT_WAIT;
                end
                ST_BOOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else if (sig0 != 8'h55 || sig1 != 8'haa)
                        finish_with_error(ERR_BOOT_SIGNATURE);
                    else
                        state <= ST_BOOT_PARSE;
                end
                ST_BOOT_PARSE: begin
                    if (bs_bps != 16'd512 || !valid_spc(bs_spc) ||
                        bs_rsvd == 0 || (bs_nfat != 1 && bs_nfat != 2) ||
                        bs_root_ent != 0 || bs_fatsz16 != 0 || bs_totsec32 == 0 ||
                        bs_fatsz32 == 0 || bs_root_clus < 2) begin
                        finish_with_error(ERR_UNSUPPORTED_BPB);
                    end else begin
                        sectors_per_cluster <= bs_spc;
                        reserved_sectors <= bs_rsvd;
                        fat_count <= bs_nfat;
                        total_sectors <= bs_totsec32;
                        fat_sectors <= bs_fatsz32;
                        root_cluster <= bs_root_clus;
                        sectors_per_cluster_shift <= spc_shift(bs_spc);
                        fat_span <= bs_nfat == 2 ? (bs_fatsz32 << 1) : bs_fatsz32;
                        fat_start_lba <= partition_lba + bs_rsvd;
                        state <= ST_BOOT_LAYOUT;
                    end
                end
                ST_BOOT_LAYOUT: begin
                    data_start_lba <= partition_lba + reserved_sectors + fat_span;
                    data_sector_count <= total_sectors - reserved_sectors - fat_span;
                    state <= ST_BOOT_ROOT;
                end
                ST_BOOT_ROOT: begin
                    max_cluster <= (data_sector_count >> sectors_per_cluster_shift) + 1'b1;
                    root_lba <= data_start_lba
                                + ((root_cluster - 2) << sectors_per_cluster_shift);
                    sector_lba <= data_start_lba
                                  + ((root_cluster - 2) << sectors_per_cluster_shift);
                    // 根目录遍历初始化：资源表只在整个遍历开始时清一次
                    resource_valid <= 4'd0;
                    dir_cluster <= root_cluster;
                    root_sector_index <= 8'd0;
                    dir_cluster_count <= 8'd1;
                    dir_end_seen <= 1'b0;
                    state <= ST_ROOT_REQ;
                end
                ST_ROOT_REQ: if (!sector_busy) begin
                    dir_entry_match <= 1'b0;
                    sector_req <= 1'b1;
                    state <= ST_ROOT_WAIT;
                end
                ST_ROOT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else begin
                        directory_entry_index <= 5'd0;
                        state <= ST_DIR_SCAN;
                    end
                end
                ST_DIR_SCAN: begin
                    if (resource_valid == 4'hf)
                        state <= ST_FINISH;                       // 4张都找到，提前结束
                    else if (dir_end_seen) begin
                        // 目录已扫完：至少找到1张即成功，由上层跳过缺失的编号
                        if (resource_valid != 4'h0)
                            state <= ST_FINISH;
                        else
                            finish_with_error(ERR_RESOURCE_MISSING);
                    end
                    else if (root_sector_index + 8'd1 < sectors_per_cluster) begin
                        // 同一簇的下一个扇区
                        root_sector_index <= root_sector_index + 8'd1;
                        sector_lba <= sector_lba + 32'd1;
                        state <= ST_ROOT_REQ;
                    end else begin
                        // 当前簇读完，查FAT找根目录下一簇
                        fat_entry_offset <= {dir_cluster[6:0], 2'b00};
                        sector_lba <= fat_start_lba + (dir_cluster >> 7);
                        state <= ST_FAT_REQ;
                    end
                end
                ST_FAT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_FAT_WAIT;
                end
                ST_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_FAT_PARSE;
                end
                ST_FAT_PARSE: begin
                    if (fat_next_cluster >= 32'h0ffffff8) begin
                        // 根目录链结束：至少找到1张即成功
                        if (resource_valid != 4'h0)
                            state <= ST_FINISH;
                        else
                            finish_with_error(ERR_RESOURCE_MISSING);
                    end
                    else if (fat_next_cluster < 2 || fat_next_cluster > max_cluster ||
                             dir_cluster_count >= MAX_DIR_CLUSTERS)
                        finish_with_error(ERR_DIR_CHAIN);
                    else begin
                        dir_cluster <= fat_next_cluster;
                        dir_cluster_count <= dir_cluster_count + 8'd1;
                        root_sector_index <= 8'd0;
                        sector_lba <= dir_lba_base
                                      + (fat_next_cluster << sectors_per_cluster_shift);
                        state <= ST_ROOT_REQ;
                    end
                end
                ST_FINISH: begin
                    scan_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
