# 从 promax_text_overlay.v 抽出 glyph_row 函数（去掉 CR），在 default 前加 "~" 字形，输出到 STDOUT
my ($src) = @ARGV;
open(my $fh, '<', $src) or die $!;
my $on = 0;
while (my $l = <$fh>) {
    $l =~ s/\r//g;
    $on = 1 if $l =~ /^\s*function \[4:0\] glyph_row;/;
    next unless $on;
    if ($l =~ /^(\s+)default: glyph_row = 5'b00000;/) {
        print "$1\"~\": case(row) 2:glyph_row=5'b01000;3:glyph_row=5'b10101;4:glyph_row=5'b00010;default:glyph_row=0;endcase   // 歌单新增：短文件名里的 ~（如 LONGFI~1）\n";
    }
    print $l;
    last if $l =~ /^\s*endfunction/;
}
