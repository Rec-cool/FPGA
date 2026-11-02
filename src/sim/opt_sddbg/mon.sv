module mon; integer n = 0;
  always @(posedge tb.clk) if (tb.u.sd_card_cmd_m0.spi_wr_ack && n < 60) begin n = n + 1;
    $display("t=%0t cmdst=%0d bc=%0d ncs=%b sent=%02h recv=%02h", $time, tb.u.sd_card_cmd_m0.state, tb.u.sd_card_cmd_m0.byte_cnt, tb.ncs, tb.u.sd_card_cmd_m0.send_data, tb.u.sd_card_cmd_m0.data_recv); end
endmodule
