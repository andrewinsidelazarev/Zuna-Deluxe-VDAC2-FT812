#!/usr/bin/env python3
"""Validate tunnel levels use under-chain -> top cover -> above-chain ordering."""
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
    block = block_between(text, "ZL_DrawActiveChainsUnified:", "ZL_GetTopMaskForCurrentLevel:")
    failures: list[str] = []
    gameplay = block.split(".gameplay_top_mask:", 1)[1]
    required = [
        "CALL ZL_UploadTopMasksMaybe",
        "CALL ZL_BuildTopMaskChainCaches",
        "LD   A, 1",
        "CALL ZL_DrawPreparedChain1",
        "CALL ZL_DrawPreparedChain2Maybe",
        "CALL ZL_DrawTopMaskOverlay",
        "LD   A, 2",
        "CALL ZL_DrawPreparedChain1",
        "JP   ZL_DrawPreparedChain2Maybe",
    ]
    pos = -1
    for token in required:
        nxt = gameplay.find(token, pos + 1)
        if nxt < 0:
            failures.append(f"top-mask path missing ordered token: {token}")
            break
        pos = nxt
    if failures:
        print("FAIL: tunnel top overlay order")
        for item in failures:
            print(f"- {item}")
        return 1
    print("PASS: tunnel top overlay sits between under-chain and draw-above chain")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
