# 11-01 SV：从 cfg_saver.tpl.v 生成 SD/cfg_saver.v（模板文本 → case ROM + 字段位置）
# 用法：python -I gen_saver.py <模板> <输出>
import sys
lines = [
    "#CONFIG.TXT  (KEY4+KEY2 hold 1s = save)",
    "#INTERVAL 1~30 s, AUTO ON/OFF, BRIGHT 0~3",
    "#CONTRAST 0~5 (2=1.0x), MODE SEQ/ONE/RND",
    "#VOLUME 0~10. Lines starting with # are off",
    "@INTERVAL=@@",
    "AUTO=@@@",
    "BRIGHT=@",
    "CONTRAST=@",
    "MODE=@@@",
    "@VOLUME=@@",
]
names = ["P_INTC", "P_INT1", "P_INT0", "P_AUTO0", "P_AUTO1", "P_AUTO2", "P_BRI", "P_CON",
         "P_MODE0", "P_MODE1", "P_MODE2", "P_VOLC", "P_VOL1", "P_VOL0"]
t = "".join(l + "\r\n" for l in lines)
pos = [i for i, c in enumerate(t) if c == "@"]
assert len(pos) == len(names) and len(t) <= 512
rom = []
for i, c in enumerate(t):
    if c == "@":
        continue
    rom.append("                9'd%d: tpl = 8'h%02x;" % (i, ord(c)))
text = "\n".join("//   " + l.replace("@", "?") for l in lines)
text += "\n//   （共 %d 字节，后面补空格到 512 字节）" % len(t)
src = open(sys.argv[1], encoding="utf-8").read()
src = src.replace("@@ROM@@", "\n".join(rom)).replace("@@TEXT@@", text)
for n, p in zip(names, pos):
    src = src.replace("@@%s@@" % n, str(p))
assert "@@" not in src
with open(sys.argv[2], "w", encoding="utf-8", newline="") as f:
    f.write(src)
print("len", len(t), dict(zip(names, pos)))
