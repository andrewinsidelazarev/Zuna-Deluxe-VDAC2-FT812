#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MAIN_LOOP = ROOT / "Source" / "ASM" / "MainLoop.asm"


def block_between(text: str, start: str, end: str) -> str:
    if start not in text:
        raise AssertionError(f"missing block start: {start}")
    tail = text.split(start, 1)[1]
    if end not in tail:
        raise AssertionError(f"missing block end: {end}")
    return tail.split(end, 1)[0]


def main() -> int:
    text = MAIN_LOOP.read_text(encoding="utf-8")
    block = block_between(text, "ZL_BuildActiveChainCache:", "ZL_DrawCachedActiveChain:")
    needle = (
        "LD   A, (VDC_SlotsLen)\n"
        "                LD   (ZL_BallCount), A\n"
        "                OR   A\n"
        "                RET  Z\n"
        "                LD   B, A"
    )
    assert needle in block, "ZL_BuildActiveChainCache loop count must be VDC_SlotsLen"
    assert "LD   A, #FF\n                LD   (VDC_RenderTrackPageIdx), A\n                LD   B, A" not in block, (
        "cache pre-pass loops 255 times and overwrites the ball caches"
    )
    print("PASS: chain render cache pre-pass uses VDC_SlotsLen as loop count")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
