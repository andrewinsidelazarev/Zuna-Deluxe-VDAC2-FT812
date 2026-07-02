#!/usr/bin/env python3
"""Regression: gap bonus is awarded only for a through-gap shot that destroys balls."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
BULLET = ROOT / "Source" / "ASM" / "Bullet.asm"
BULLET_TRAJ = ROOT / "Source" / "ASM" / "BulletTraj.asm"
VDC = ROOT / "Source" / "ASM" / "VDC.asm"
MAIN = ROOT / "Source" / "ASM" / "main.asm"


def body(text: str, label: str, next_label: str | None = None) -> str:
    start = text.index(label + ":")
    if next_label is None:
        return text[start:]
    end = text.index(next_label + ":", start + len(label) + 1)
    return text[start:end]


def main() -> int:
    bullet = BULLET.read_text(encoding="utf-8")
    bullet_traj = BULLET_TRAJ.read_text(encoding="utf-8")
    vdc = VDC.read_text(encoding="utf-8")
    main_asm = MAIN.read_text(encoding="utf-8")
    fails: list[str] = []

    update = body(bullet, "Bullet_Update", "Bullet_CheckCollisionAllChains")
    if "JP   VDC_AwardGapBonus" in update or "CALL VDC_AwardGapBonus" in update:
        fails.append("offscreen Bullet_Update still awards gap bonus")
    if "CALL VDC_BreakShotStats" not in update:
        fails.append("offscreen Bullet_Update does not break shot stats")

    collision = body(bullet_traj, "Bullet_CheckCollisionEvents", "BulletTraj_ProcessEvent")
    if not re.search(r"CALL VDC_InsertAt(?:\s*;[^\n]*)?\n\s*OR\s+A\s*\n\s*CALL NZ, VDC_AwardGapBonus", collision):
        fails.append("collision path does not award gap bonus only after matched insert")

    insert_at = body(vdc, "VDC_InsertAt", "VDC_ShiftRight_Slots")
    if "LD   (VDC_BulletGapCount), A" not in insert_at:
        fails.append("shot without match does not reset consecutive gap-shot streak")

    award = body(main_asm, "VDC_AwardGapBonusSlot0", "LoadLevelSelectFontNative")
    done = award.split(".done:", 1)[1].split(".no_gap:", 1)[0]
    if "VDC_StatChainCount" in done:
        fails.append("successful gap bonus still breaks chain count")

    if fails:
        print("FAIL: " + "; ".join(fails))
        return 1
    print("PASS: gap bonus event rule is wired to through-gap destroy, not miss/expire")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
