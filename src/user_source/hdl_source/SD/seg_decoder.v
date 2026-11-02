module seg_decoder
(
	input[4:0]      bin_data,
	output reg[6:0] seg_data
);

always@(*)
begin
	case(bin_data)
		5'd0:seg_data <= 7'b100_0000;
		5'd1:seg_data <= 7'b111_1001;
		5'd2:seg_data <= 7'b010_0100;
		5'd3:seg_data <= 7'b011_0000;
		5'd4:seg_data <= 7'b001_1001;
		5'd5:seg_data <= 7'b001_0010;
		5'd6:seg_data <= 7'b000_0010;
		5'd7:seg_data <= 7'b111_1000;
		5'd8:seg_data <= 7'b000_0000;
		5'd9:seg_data <= 7'b001_0000;
		5'ha:seg_data <= 7'b000_1000;
		5'hb:seg_data <= 7'b000_0011;
		5'hc:seg_data <= 7'b100_0110;
		5'hd:seg_data <= 7'b010_0001;
		5'he:seg_data <= 7'b000_0110;
		5'hf:seg_data <= 7'b111_1111;
		5'd16:seg_data <= 7'b010_1000;//R
		5'd17:seg_data <= 7'b000_1100;//P
		5'd18:seg_data <= 7'b111_0000;//I
		5'd19:seg_data <= 7'b100_0001;//V
		//4'hf:seg_data <= 7'b000_1110;//换成空白
		default:seg_data <= 7'b111_1111;
	endcase
end
endmodule
