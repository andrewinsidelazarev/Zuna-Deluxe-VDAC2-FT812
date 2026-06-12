#!/usr/bin/env python3
"""One-off: scale frog/killzone positions in level_runtime_table.inc x8/5
(640 -> 1024 space) for the 1024x768 port. Targets only the 4-value DW lines
inside the LevelRuntimeTable block. The generator (make_level_runtime_table.py)
applies the same scale, so a future regen stays consistent.
"""
import io
import re
from pathlib import Path

P = Path(__file__).resolve().parent.parent / "ASM" / "level_runtime_table.inc"
text = io.open(P, encoding="utf-8").read()
lines = text.split("\n")
out = []
in_tab = False
n = 0
pat = re.compile(r"^(\s*DW\s+)(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*$")
for ln in lines:
    st = ln.strip()
    if st.startswith("LevelRuntimeTable:"):
        in_tab = True
        out.append(ln)
        continue
    if in_tab and st.endswith(":") and not st.startswith(";"):
        in_tab = False
    if in_tab:
        m = pat.match(ln)
        if m:
            v = [int(round(int(m.group(i)) * 8 / 5)) for i in (2, 3, 4, 5)]
            out.append("%s%d, %d, %d, %d" % (m.group(1), v[0], v[1], v[2], v[3]))
            n += 1
            continue
    out.append(ln)
io.open(P, "w", encoding="utf-8", newline="\n").write("\n".join(out))
print("scaled DW position lines:", n)
