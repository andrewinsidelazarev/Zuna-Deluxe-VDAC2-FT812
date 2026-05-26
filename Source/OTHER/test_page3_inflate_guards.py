#!/usr/bin/env python3
"""Regression harness for PAGE3 safety around FT812 zlib inflate paths.

TSLib Inflate maps the compressed source stream into slot 3 while it feeds
FT812. That is unsafe for this program because slot 3 is main1_play code.
Menu/level-select loaders must use SafeInflatePage2 instead, which streams the
compressed source from PAGE2 and keeps PAGE3 on main1_play page #04.

This test covers the paths that load menu/level-select zlib streams:
  * static check: no direct CALL FT.Coprocessor.Inflate in those callers;
  * level-select previews are no longer zlib/SPG-resident, so that loader must
    not call any FT812 inflate routine at all.
"""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

RET = 0xC9


def code_blob_for_symbol(sym: dict[str, int], name: str) -> tuple[Path, int]:
    addr = sym[name]
    if 0xC000 <= addr <= 0xFFFF:
        return ROOT / "Build" / "main1_play.bin", addr - 0xC000
    if 0x5C00 <= addr < 0x8000:
        return ROOT / "Build" / "Core.bin", addr - 0x5C00
    return ROOT / "Build" / "TSLib.bin", addr - 0x1000


def assert_static_safe_inflate(sym: dict[str, int], func: str, size: int = 128) -> None:
    path, off = code_blob_for_symbol(sym, func)
    blob = path.read_bytes()[off : off + size]
    unsafe = bytes([0xCD, sym["FT.Coprocessor.Inflate"] & 0xFF, sym["FT.Coprocessor.Inflate"] >> 8])
    safe = bytes([0xCD, sym["SafeInflatePage2"] & 0xFF, sym["SafeInflatePage2"] >> 8])
    if unsafe in blob:
        raise AssertionError(f"{func}: still calls unsafe FT.Coprocessor.Inflate")
    if safe not in blob:
        raise AssertionError(f"{func}: no CALL SafeInflatePage2")


def assert_static_no_inflate(sym: dict[str, int], func: str, size: int = 512) -> None:
    path, off = code_blob_for_symbol(sym, func)
    blob = path.read_bytes()[off : off + size]
    unsafe = bytes([0xCD, sym["FT.Coprocessor.Inflate"] & 0xFF, sym["FT.Coprocessor.Inflate"] >> 8])
    safe = bytes([0xCD, sym["SafeInflatePage2"] & 0xFF, sym["SafeInflatePage2"] >> 8])
    if unsafe in blob:
        raise AssertionError(f"{func}: still calls unsafe FT.Coprocessor.Inflate")
    if safe in blob:
        raise AssertionError(f"{func}: still calls SafeInflatePage2; previews should come from PAK")


def ret_from_hook(emu: ZumaFullZ80Emulator) -> None:
    sp = emu.reg.SP
    ret = emu.mem.read(sp) | (emu.mem.read((sp + 1) & 0xFFFF) << 8)
    emu.reg.SP = (sp + 2) & 0xFFFF
    emu.reg.PC = ret
    emu.reg.F &= ~0x01


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    needed = [
        "Core.Init_Core",
        "Core.LoadLevelSelectPreviewAssets",
        "LoadLevelSelectPreviewMarkers",
        "Core.LoadMainMenuAssets",
        "SafeInflatePage2",
        "FT.Coprocessor.Inflate",
    ]
    missing = [name for name in needed if name not in sym]
    if missing:
        print(f"FAIL: missing symbols: {', '.join(missing)}")
        return 1

    for func in ("LoadLevelSelectPreviewMarkers", "Core.MenuInflateAssetsFromTable"):
        assert_static_safe_inflate(sym, func)
        print(f"[static] {func}: uses SafeInflatePage2, no unsafe PAGE3 inflate")

    assert_static_no_inflate(sym, "Core.LoadLevelSelectPreviewAssets")
    print("[static] Core.LoadLevelSelectPreviewAssets: no FT inflate; preview streams from PAK")

    print("PASS: preview/menu inflate paths keep PAGE3 on main1_play")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
