#!/usr/bin/env python3
"""Validate that tunnel top cover is emitted after the whole chain on top-mask levels."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAINLOOP = ROOT / "Source" / "ASM" / "MainLoop.asm"


def block_between(text: str, start: str, end: str) -> str:
    a = text.index(start)
    b = text.index(end, a)
    return text[a:b]


def main() -> int:
    text = MAINLOOP.read_text(encoding="utf-8")
    block = block_between(text, "ZL_DrawActiveChainForLevel:", "ZL_GetTopMaskForCurrentLevel:")
    failures: list[str] = []
    if "JP   ZL_DrawTopMaskOverlay" not in block:
        failures.append("top-mask path does not jump to DrawTopMaskOverlay as final layer")
    if "above tunnel top mask" in block:
        failures.append("top-mask path still contains an above-pass after the overlay")
    if "LD   A, 2" in block:
        failures.append("top-mask path still selects chain draw pass 2")
    if "top-mask levels: draw chain, then cover it" not in block:
        failures.append("top-mask path does not document final cover ordering")
    if failures:
        print("FAIL: tunnel top overlay order")
        for item in failures:
            print(f"- {item}")
        return 1
    print("PASS: tunnel top overlay is the final layer over the chain on top-mask levels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
