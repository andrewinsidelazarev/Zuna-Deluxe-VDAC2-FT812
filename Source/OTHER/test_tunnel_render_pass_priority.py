#!/usr/bin/env python3
"""Check that tunnel samples are never scheduled for the above/top render pass."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Graphics" / "levels" / "Converted" / "pack"
MAINLOOP = ROOT / "Source" / "ASM" / "MainLoop.asm"
REC = 6
TRACKF_TUNNEL = 0x01
TRACKF_DRAW_ABOVE = 0x02

TUNNEL_LEVELS = {
    9: "underover",
    11: "loopy",
    13: "groovefest",
    14: "spaceinvaders",
    16: "coaster",
    18: "tunnellevel",
    20: "overunder",
    21: "inversespiral",
}


def read_flags(path: Path) -> list[int]:
    data = path.read_bytes()
    assert len(data) >= 2, f"{path.name}: too short"
    count = int.from_bytes(data[:2], "little")
    payload = data[2:]
    assert len(payload) == count * REC, f"{path.name}: size mismatch"
    return list(payload[5::REC])


def label_block(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    finish = source.index(end, begin)
    return source[begin:finish]


def main() -> int:
    failures: list[str] = []
    for level_num, name in TUNNEL_LEVELS.items():
        path = ASSETS / f"track_l{level_num:02d}_640.bin"
        flags = read_flags(path)
        tunnel = sum(1 for f in flags if f & TRACKF_TUNNEL)
        above = sum(1 for f in flags if f & TRACKF_DRAW_ABOVE)
        both = sum(1 for f in flags if (f & TRACKF_TUNNEL) and (f & TRACKF_DRAW_ABOVE))
        above_pass = sum(
            1
            for f in flags
            if (f & TRACKF_DRAW_ABOVE) and not (f & TRACKF_TUNNEL)
        )
        print(
            f"L{level_num:02d} {name}: tunnel={tunnel} drawAbove={above} "
            f"both={both} above_pass_after_filter={above_pass}"
        )
        if above_pass + both != above:
            failures.append(f"L{level_num:02d} {name}: internal count mismatch")
    source = MAINLOOP.read_text(encoding="utf-8")
    pass_over = label_block(source, ".PBPassOver:", ".PBPassSkipTunnel:")
    pass_under = label_block(source, ".PBPassUnder:", ".PBPassOk:")
    if "AND  ZL_TRACKF_TUNNEL" not in pass_over or "JP   NZ, .PBSkip" not in pass_over:
        failures.append("MainLoop pass 2 does not skip TUNNEL before DRAW_ABOVE")
    if "AND  ZL_TRACKF_TUNNEL" not in pass_under or "JR   NZ, .PBPassOk" not in pass_under:
        failures.append("MainLoop pass 1 does not give TUNNEL priority")
    if failures:
        print("FAIL: tunnel render-pass priority test")
        for item in failures:
            print(f"- {item}")
        return 1
    print("PASS: renderer gives TUNNEL priority over DRAW_ABOVE for tunnel top masks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
