#!/usr/bin/env python3
"""Regression: ZBT1 track2 hits insert into chain2 and restore chain1."""
from __future__ import annotations

import sys
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Source" / "OTHER"))

from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator  # noqa: E402


def seed_dual_chain_fixture(emu: ZumaFullZ80Emulator) -> None:
    sym = emu.sym

    def sb(name: str, value: int) -> None:
        emu.set_byte(sym[name], value)

    def sw(name: str, value: int) -> None:
        emu.set_word(sym[name], value)

    def page_write(page: int, off: int, data: bytes) -> None:
        start = page * PAGE_SIZE + off
        emu.mem.physical[start : start + len(data)] = data

    sb("Core.VDC_HasSecondChain", 1)
    sb("Core.VDC_SecondActive", 0)
    sb("Core.Bullet_EventTrackState", 0)
    emu.call(sym["Core.VDC_SelectChain1"], max_steps=10_000)

    sb("Core.VDC_TrackPageCount1", 1)
    sb("Core.VDC_TrackPageCount2", 1)
    emu.set_byte(sym["Core.VDC_TrackPages1"], 0x06)
    emu.set_byte(sym["Core.VDC_TrackPages2"], 0x10)
    sw("Core.VDC_TrackSamples1", 512)
    sw("Core.VDC_TrackSamples2", 512)

    # slot 0 at HSA=5,HSub=0 maps to sample t=160. Put that sample at (200,200).
    sample = struct.pack("<hhBBxx", (200 - 26) * 16, (200 - 26) * 16, 0, 0)
    page_write(0x10, 160 * 8, sample)

    sb("Core.VDC_SlotsLen", 3)
    sb("Core.VDC_HSub", 0)
    emu.set_byte(sym["Core.VDC_HSA"], 5)
    for idx, color in enumerate((0, 1, 2)):
        emu.set_byte(sym["Core.VDC_Slots"] + idx, color)
        emu.set_byte(sym["Core.VDC_Offsets"] + idx, 0)
        emu.set_byte(sym["Core.VDC_Shot2"] + idx, 0)
        emu.set_byte(sym["Core.VDC_ExplodeFrame"] + idx, 0)
        emu.set_byte(sym["Core.VDC_ExplodeMarker"] + idx, 0)

    sb("Core.VDC2_SlotsLen", 3)
    sb("Core.VDC2_HSub", 0)
    for idx, color in enumerate((3, 4, 5)):
        emu.set_byte(sym["Core.VDC2_Slots"] + idx, color)
        emu.set_byte(sym["Core.VDC2_Offsets"] + idx, 0)
        emu.set_byte(sym["Core.VDC2_Shot2"] + idx, 0)
        emu.set_byte(sym["Core.VDC2_ExplodeFrame"] + idx, 0)
        emu.set_byte(sym["Core.VDC2_ExplodeMarker"] + idx, 0)

    chain_local = sym["Core.VDC_ChainLocalStart"]
    hsa_off = sym["Core.VDC_HSA"] - chain_local
    emu.set_byte(sym["Core.VDC2_ChainLocal"] + hsa_off, 5)

    sb("Core.Bullet_Active", 1)
    sw("Core.Bullet_X", 200)
    sw("Core.Bullet_Y", 200)
    sb("Core.Bullet_Color", 2)
    sb("Core.Bullet_NoHitMask", 0)
    sb("Core.Bullet_TunnelSeen", 0)

    emu.call(sym["Core.SetCurrentTrackPage"], max_steps=10_000)


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym

    def sb(name: str, value: int) -> None:
        emu.set_byte(sym[name], value)

    def gb(name: str) -> int:
        return emu.get_byte(sym[name])

    def bytes_at(name: str, count: int) -> list[int]:
        base = sym[name]
        return [emu.get_byte(base + i) for i in range(count)]

    seed_dual_chain_fixture(emu)

    emu.call(sym["Core.BulletTraj_SelectTrack"], a=1, max_steps=200_000)
    if gb("Core.VDC_SecondActive") != 1 or gb("Core.Bullet_EventTrackState") != 1:
        print(
            "FAIL: selecting track2 did not leave coherent track state: "
            f"second={gb('Core.VDC_SecondActive')} event={gb('Core.Bullet_EventTrackState')}"
        )
        return 1

    emu.call(sym["Core.VDC_InsertAt"], a=1, b=2, max_steps=500_000)
    emu.call(sym["Core.BulletTraj_RestoreChain1"], max_steps=200_000)

    chain1 = bytes_at("Core.VDC_Slots", 4)
    chain2 = bytes_at("Core.VDC2_Slots", 4)
    fails: list[str] = []
    if gb("Core.VDC_SecondActive") != 0 or gb("Core.Bullet_EventTrackState") != 0:
        fails.append(
            f"restore left second={gb('Core.VDC_SecondActive')} "
            f"event={gb('Core.Bullet_EventTrackState')}"
        )
    if gb("Core.VDC_SlotsLen") != 3 or chain1[:3] != [0, 1, 2]:
        fails.append(f"chain1 was modified: len={gb('Core.VDC_SlotsLen')} slots={chain1}")
    if gb("Core.VDC2_SlotsLen") != 4 or chain2 != [3, 2, 4, 5]:
        fails.append(f"chain2 did not receive insert: len={gb('Core.VDC2_SlotsLen')} slots={chain2}")

    if fails:
        print("FAIL: " + "; ".join(fails))
        return 1

    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    seed_dual_chain_fixture(emu)
    page13 = 0x13 * PAGE_SIZE
    # frame=1, flags=TRACK2|HIT, cell=5, sub=0. This drives the full event reader.
    emu.mem.physical[page13 : page13 + 4] = bytes((1, 0x03, 5, 0))
    sb = lambda name, value: emu.set_byte(sym[name], value)
    sw = lambda name, value: emu.set_word(sym[name], value)
    sb("Core.BulletTrajValid", 1)
    sb("Core.Bullet_Frame", 1)
    sb("Core.Bullet_EventCount", 1)
    sw("Core.Bullet_EventPtr", 0x8000)
    emu.call(sym["Core.Bullet_CheckCollisionEvents"], max_steps=2_000_000)

    chain1 = bytes_at("Core.VDC_Slots", 4)
    chain2 = bytes_at("Core.VDC2_Slots", 4)
    fails = []
    if gb("Core.Bullet_Active") != 0:
        fails.append("full event reader did not consume bullet")
    if gb("Core.VDC_SecondActive") != 0 or gb("Core.Bullet_EventTrackState") != 0:
        fails.append(
            f"full reader restore left second={gb('Core.VDC_SecondActive')} "
            f"event={gb('Core.Bullet_EventTrackState')}"
        )
    if gb("Core.VDC_SlotsLen") != 3 or chain1[:3] != [0, 1, 2]:
        fails.append(f"full reader modified chain1: len={gb('Core.VDC_SlotsLen')} slots={chain1}")
    if gb("Core.VDC2_SlotsLen") != 4 or chain2 != [3, 2, 4, 5]:
        fails.append(f"full reader did not insert into chain2: len={gb('Core.VDC2_SlotsLen')} slots={chain2}")
    if fails:
        print("FAIL: " + "; ".join(fails))
        return 1

    print("PASS: ZBT1 track2 event inserts into chain2 and restores chain1 state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
