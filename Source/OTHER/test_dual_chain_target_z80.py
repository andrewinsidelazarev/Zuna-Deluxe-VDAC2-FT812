#!/usr/bin/env python3
"""Regression: dual-chain levels must not double the Zuma bar target."""
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    required = [
        "Core.GetCurrentTargetScore",
        "Core.VDC_HasSecondChain",
        "CurrentLevel",
        "CurrentSettingIndex",
    ]
    missing = [name for name in required if name not in sym]
    if missing:
        print("FAIL: missing symbols: " + ", ".join(missing))
        return 1

    # Level Select / Gauntlet L19: serpents, Rabbit rank -> lvl35 setting.
    emu.set_byte(sym["CurrentLevel"], 18)
    emu.set_byte(sym["CurrentSettingIndex"], 14)

    failures: list[str] = []
    for has_second in (0, 1):
        emu.set_byte(sym["Core.VDC_HasSecondChain"], has_second)
        emu.call(sym["Core.GetCurrentTargetScore"])
        target = emu.reg.E | (emu.reg.D << 8)
        print(f"L19/Rabbit has_second={has_second}: target={target}")
        if target != 4500:
            failures.append(f"has_second={has_second} target={target}")

    if failures:
        print("FAIL: " + ", ".join(failures))
        return 1

    print("PASS: L19/Rabbit target remains 4500 on dual-chain levels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
