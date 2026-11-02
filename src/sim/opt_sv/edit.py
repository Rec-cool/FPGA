# 用法：python -I edit.py 文件 —— 从 stdin 读取 "<<<旧\n===\n新>>>" 块，按文件原换行风格替换（每块必须恰好匹配一次）
import sys
fn = sys.argv[1]
raw = open(fn, encoding="utf-8", newline="").read()
crlf = "\r\n" in raw
txt = raw.replace("\r\n", "\n")
spec = sys.stdin.buffer.read().decode("utf-8")
blocks = spec.split("<<<\n")[1:]
for b in blocks:
    old, new = b.split("\n===\n")
    new = new.rsplit("\n>>>", 1)[0]
    n = txt.count(old)
    if n != 1:
        sys.exit("match count %d for block:\n%s" % (n, old[:200]))
    txt = txt.replace(old, new)
if crlf:
    txt = txt.replace("\n", "\r\n")
open(fn, "w", encoding="utf-8", newline="").write(txt)
print(fn, "ok", "CRLF" if crlf else "LF", len(blocks), "blocks")
