#!/usr/bin/env python3
"""Catch wrong-target/remote-match events through the full VDAC2 Z80 harness.

This is diagnostic-only: it does not patch game ASM.  It builds a natural chain,
fires scripted bullets through the real Bullet_Update/Bullet_CheckCollision path,
and reports:

  * wrong_target: inserted slot is far from the geometrically nearest slot.
  * remote_effect: insert is local, but the next VDC update changes/removes
    slots far away from the insert point, which can look like "insert happened
    elsewhere" on video.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path

from zuma_full_z80_emulator import PROJECT_ROOT, ZumaFullZ80Emulator


CELL = 32
VALID_COLORS = 4


def s8(v: int) -> int:
    return v - 256 if v & 0x80 else v


def s16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


@dataclass
class Event:
    kind: str
    phase: int
    aim_idx: int
    frame: int
    bullet: tuple[int, int]
    velocity: tuple[int, int]
    nearest_idx: int | None
    nearest_dist: int | None
    bbox: list[tuple[int, int, int]]
    insert_idx: int | None
    insert_delta: int | None
    aim_delta: int | None
    remote_changes: list[int]
    hsa: int
    hsub: int
    slots_len: int
    slots: str
    offsets: list[int]
    shot2: list[int]


class Catcher:
    def __init__(self) -> None:
        self.emu = ZumaFullZ80Emulator(PROJECT_ROOT)
        self.s = self.emu.sym
        self.track = []

    def gb(self, name_or_addr) -> int:
        addr = self.s[name_or_addr] if isinstance(name_or_addr, str) else name_or_addr
        return self.emu.get_byte(addr)

    def gw(self, name_or_addr) -> int:
        addr = self.s[name_or_addr] if isinstance(name_or_addr, str) else name_or_addr
        return self.emu.get_word(addr)

    def sb(self, name_or_addr, value: int) -> None:
        addr = self.s[name_or_addr] if isinstance(name_or_addr, str) else name_or_addr
        self.emu.set_byte(addr, value & 0xFF)

    def sw(self, name_or_addr, value: int) -> None:
        addr = self.s[name_or_addr] if isinstance(name_or_addr, str) else name_or_addr
        self.emu.set_word(addr, value & 0xFFFF)

    def init(self, build_frames: int) -> None:
        self.emu.game_init()
        self.load_track()
        for _ in range(build_frames):
            self.vdc_frame()
        self.sb("Core.VDC_BallsSpawned", 85)

    def load_track(self) -> None:
        n = self.gw("Core.TrackData")
        self.track = []
        base = self.s["Core.TrackData"] + 2
        for t in range(n):
            addr = base + t * 5
            self.track.append((s16(self.emu.get_word(addr)), s16(self.emu.get_word(addr + 2))))

    def vdc_frame(self) -> None:
        self.emu.call(self.s["Core.VDC_Update"])
        self.sw("Core.ZL_FrameCounter", self.gw("Core.ZL_FrameCounter") + 1)

    def chain_state(self) -> dict:
        n = self.gb("Core.VDC_SlotsLen")
        slots = list(self.emu.get_memory(self.s["Core.VDC_Slots"], n))
        offsets = [s8(v) for v in self.emu.get_memory(self.s["Core.VDC_Offsets"], n)]
        shot2 = list(self.emu.get_memory(self.s["Core.VDC_Shot2"], n))
        return {
            "hsa": self.gb("Core.VDC_HSA"),
            "hsub": self.gb("Core.VDC_HSub"),
            "len": n,
            "slots": slots,
            "offsets": offsets,
            "shot2": shot2,
            "freeze": self.gb("Core.VDC_ChainFreezeCnt"),
            "gapcnt": self.gb("Core.VDC_GapStepCnt"),
            "scan": self.gb("Core.VDC_MatchScanIdx"),
        }

    def snapshot(self) -> dict:
        return {
            "slots": list(self.emu.get_memory(self.s["Core.VDC_Slots"], 240)),
            "offsets": list(self.emu.get_memory(self.s["Core.VDC_Offsets"], 240)),
            "shot2": list(self.emu.get_memory(self.s["Core.VDC_Shot2"], 240)),
            "scalars": {
                name: self.gb(name)
                for name in (
                    "Core.VDC_HSA",
                    "Core.VDC_HSub",
                    "Core.VDC_SlotsLen",
                    "Core.VDC_BallsSpawned",
                    "Core.VDC_ChainFreezeCnt",
                    "Core.VDC_GapStepCnt",
                    "Core.VDC_MatchScanIdx",
                    "Core.Bullet_Active",
                    "Core.Bullet_Color",
                    "Core.Bullet_VX",
                    "Core.Bullet_VY",
                )
            },
            "frame_counter": self.gw("Core.ZL_FrameCounter"),
            "bullet_x": self.gw("Core.Bullet_X"),
            "bullet_y": self.gw("Core.Bullet_Y"),
        }

    def restore(self, snap: dict) -> None:
        for i, v in enumerate(snap["slots"]):
            self.emu.set_byte(self.s["Core.VDC_Slots"] + i, v)
        for i, v in enumerate(snap["offsets"]):
            self.emu.set_byte(self.s["Core.VDC_Offsets"] + i, v)
        for i, v in enumerate(snap["shot2"]):
            self.emu.set_byte(self.s["Core.VDC_Shot2"] + i, v)
        for name, v in snap["scalars"].items():
            self.sb(name, v)
        self.sw("Core.ZL_FrameCounter", snap["frame_counter"])
        self.sw("Core.Bullet_X", snap["bullet_x"])
        self.sw("Core.Bullet_Y", snap["bullet_y"])

    def slot_pos(self, i: int) -> tuple[int, int] | None:
        if self.emu.get_byte(self.s["Core.VDC_Slots"] + i) >= VALID_COLORS:
            return None
        hsa = self.gb("Core.VDC_HSA")
        if i > hsa:
            return None
        t = (hsa - i) * CELL + self.gb("Core.VDC_HSub") + s8(self.emu.get_byte(self.s["Core.VDC_Offsets"] + i))
        if t < 0:
            return None
        if t >= len(self.track):
            t = len(self.track) - 1
        return self.track[t]

    def positions(self) -> list[tuple[int, int, int]]:
        out = []
        for i in range(self.gb("Core.VDC_SlotsLen")):
            p = self.slot_pos(i)
            if p is not None:
                out.append((i, p[0], p[1]))
        return out

    def find_insert_idx(self, before: list[int], after: list[int], color: int) -> int | None:
        if len(after) != len(before) + 1:
            return None
        for idx in range(len(after)):
            if after[idx] == color and after[:idx] == before[:idx] and after[idx + 1 :] == before[idx:]:
                return idx
        for idx in range(len(after)):
            if after[:idx] == before[:idx] and after[idx + 1 :] == before[idx:]:
                return idx
        return None

    def changed_indices(self, before: list[int], after: list[int]) -> list[int]:
        n = max(len(before), len(after))
        out = []
        for i in range(n):
            b = before[i] if i < len(before) else None
            a = after[i] if i < len(after) else None
            if a != b:
                out.append(i)
        return out

    def chain_string(self, slots: list[int]) -> str:
        table = {0: "0", 1: "1", 2: "2", 3: "3", 0xFD: "C", 0xFE: "S"}
        return "".join(table.get(v, "?") for v in slots)

    def event(self, kind: str, phase: int, aim_idx: int, frame: int, bx: int, by: int,
              vx: int, vy: int, nearest, nearest_dist, bbox, insert_idx, insert_delta,
              aim_delta, remote_changes: list[int]) -> Event:
        st = self.chain_state()
        return Event(
            kind=kind,
            phase=phase,
            aim_idx=aim_idx,
            frame=frame,
            bullet=(bx, by),
            velocity=(vx, vy),
            nearest_idx=nearest[0] if nearest else None,
            nearest_dist=nearest_dist,
            bbox=[(i, x, y) for i, x, y in bbox[:8]],
            insert_idx=insert_idx,
            insert_delta=insert_delta,
            aim_delta=aim_delta,
            remote_changes=remote_changes[:20],
            hsa=st["hsa"],
            hsub=st["hsub"],
            slots_len=st["len"],
            slots=self.chain_string(st["slots"]),
            offsets=st["offsets"],
            shot2=st["shot2"],
        )

    def run(self, phases: list[int], max_frames: int, area_only: bool) -> list[Event]:
        base = self.snapshot()
        frog_x = s16(self.gw("Core.Frog_PosStartX"))
        frog_y = s16(self.gw("Core.Frog_PosStartY"))
        events: list[Event] = []
        trials = 0
        hits = 0

        for phase in phases:
            self.restore(base)
            for _ in range(phase):
                self.vdc_frame()
            phase_snap = self.snapshot()
            visible = self.positions()
            if area_only:
                visible = [p for p in visible if 150 <= p[1] <= 280 and 340 <= p[2] <= 430]
            velocities = []
            for i, x, y in visible:
                dx = x - frog_x
                dy = y - frog_y
                dist = math.hypot(dx, dy)
                if dist < 1:
                    continue
                vx = int(round(dx / dist * 12))
                vy = int(round(dy / dist * 12))
                if vx or vy:
                    velocities.append((i, vx, vy))

            # Add coarse free-angle probes.
            for deg in range(0, 360, 15):
                vx = int(round(math.cos(math.radians(deg)) * 12))
                vy = int(round(math.sin(math.radians(deg)) * 12))
                if vx or vy:
                    velocities.append((-1, vx, vy))

            seen = set()
            uniq = []
            for item in velocities:
                key = (item[1], item[2])
                if key not in seen:
                    seen.add(key)
                    uniq.append(item)

            for aim_idx, vx, vy in uniq:
                self.restore(phase_snap)
                trials += 1
                self.sb("Core.Bullet_Active", 1)
                self.sb("Core.Bullet_Color", 2)
                self.sw("Core.Bullet_X", frog_x)
                self.sw("Core.Bullet_Y", frog_y)
                self.sb("Core.Bullet_VX", vx)
                self.sb("Core.Bullet_VY", vy)

                for frame in range(max_frames):
                    self.vdc_frame()
                    self.emu.call(self.s["Core.Bullet_Update"])
                    if not self.gb("Core.Bullet_Active"):
                        break

                    bx = s16(self.gw("Core.Bullet_X"))
                    by = s16(self.gw("Core.Bullet_Y"))
                    pos = self.positions()
                    if not pos:
                        continue
                    nearest = min(pos, key=lambda p: abs(p[1] - bx) + abs(p[2] - by))
                    nearest_dist = abs(nearest[1] - bx) + abs(nearest[2] - by)
                    bbox = [p for p in pos if abs(p[1] - bx) < 16 and abs(p[2] - by) < 16]
                    before_len = self.gb("Core.VDC_SlotsLen")
                    before_slots = list(self.emu.get_memory(self.s["Core.VDC_Slots"], before_len))

                    self.emu.call(self.s["Core.Bullet_CheckCollision"])
                    after_len = self.gb("Core.VDC_SlotsLen")
                    if after_len != before_len + 1:
                        if not self.gb("Core.Bullet_Active"):
                            break
                        continue

                    hits += 1
                    after_slots = list(self.emu.get_memory(self.s["Core.VDC_Slots"], after_len))
                    insert_idx = self.find_insert_idx(before_slots, after_slots, 2)
                    insert_delta = abs(insert_idx - nearest[0]) if insert_idx is not None else None
                    aim_delta = (abs(insert_idx - aim_idx)
                                 if (insert_idx is not None and aim_idx >= 0) else None)
                    wrong_near = insert_delta is None or insert_delta > 3
                    wrong_aim = aim_delta is not None and aim_delta > 5
                    if wrong_near or wrong_aim:
                        kind = ("wrong_target_aim" if (wrong_aim and not wrong_near)
                                else "wrong_target")
                        events.append(self.event(kind, phase, aim_idx, frame, bx, by, vx, vy,
                                                 nearest, nearest_dist, bbox,
                                                 insert_idx, insert_delta, aim_delta, []))
                        break

                    # One subsequent VDC frame: catch remote match/cascade effects.
                    post_insert_slots = after_slots
                    self.vdc_frame()
                    post_len = self.gb("Core.VDC_SlotsLen")
                    post_slots = list(self.emu.get_memory(self.s["Core.VDC_Slots"], post_len))
                    changes = self.changed_indices(post_insert_slots, post_slots)
                    remote = [i for i in changes if insert_idx is not None and abs(i - insert_idx) > 4]
                    if remote:
                        events.append(self.event("remote_effect", phase, aim_idx, frame, bx, by, vx, vy,
                                                 nearest, nearest_dist, bbox,
                                                 insert_idx, insert_delta, aim_delta, remote))
                    break

        print(f"trials={trials} hits={hits} events={len(events)}")
        return events


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", type=int, default=2600)
    ap.add_argument("--frames", type=int, default=80)
    ap.add_argument("--area-only", action="store_true", help="focus on the bottom screenshot area")
    ap.add_argument("--out", default=str(PROJECT_ROOT / "Source" / "OTHER" / "_wrong_target_events.json"))
    ns = ap.parse_args()

    catcher = Catcher()
    catcher.init(ns.build)
    events = catcher.run(phases=[0, 4, 8, 12, 16, 24, 32, 40, 48, 56], max_frames=ns.frames, area_only=ns.area_only)
    data = [event.__dict__ for event in events]
    out = Path(ns.out)
    out.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    for event in events[:20]:
        print(event)
    print(f"wrote {out}")
    return 2 if events else 0


if __name__ == "__main__":
    raise SystemExit(main())
