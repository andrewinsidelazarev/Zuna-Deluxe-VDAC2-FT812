#!/usr/bin/env python3
"""Regression: bridge-over-tunnel balls remain hittable through ZBT1 events."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BULLET_TRAJ = ROOT / "Source" / "ASM" / "BulletTraj.asm"


def body(text: str, label: str, next_label: str) -> str:
    start = text.index(label + ":")
    end = text.index(next_label + ":", start + len(label) + 1)
    return text[start:end]


def main() -> int:
    text = BULLET_TRAJ.read_text(encoding="utf-8")
    fails: list[str] = []

    if "BULLET_TRAJ_TRACKF_DRAW_ABOVE EQU #02" not in text:
        fails.append("DRAW_ABOVE track flag is not defined in BulletTraj")

    process = body(text, "BulletTraj_ProcessEvent", "BulletTraj_EventMaskToB")
    hit_tail = process.split("BULLET_TRAJ_EV_HIT", 1)[-1]
    before_select = hit_tail.split("BulletTraj_SelectTrack", 1)[0]
    if "Bullet_NoHitMask" in before_select:
        fails.append("hit event is still rejected by track-wide no-hit before candidate flags are known")
    if "BULLET_TRAJ_EV_TUNNEL" not in hit_tail:
        fails.append("tunnel hit events are no longer explicitly skipped")

    candidate = body(text, "BulletTraj_CheckCandidateA", ".gap_candidate")
    if "BULLET_TRAJ_TRACKF_DRAW_ABOVE" not in candidate:
        fails.append("candidate path does not check DRAW_ABOVE before no-hit")
    if "Bullet_NoHitMask" not in candidate:
        fails.append("candidate path no longer applies tunnel no-hit mask")
    elif candidate.index("BULLET_TRAJ_TRACKF_DRAW_ABOVE") > candidate.index("Bullet_NoHitMask"):
        fails.append("candidate applies no-hit before checking DRAW_ABOVE")

    if fails:
        print("FAIL: " + "; ".join(fails))
        return 1
    print("PASS: ZBT1 bridge-over-tunnel hits bypass lower tunnel no-hit only for DRAW_ABOVE balls")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
