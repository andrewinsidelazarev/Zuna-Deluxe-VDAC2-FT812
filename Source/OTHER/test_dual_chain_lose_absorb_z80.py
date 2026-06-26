#!/usr/bin/env python3
"""Dual-chain lose-state regression test.

The non-triggering chain must not fade/remove head balls at its current position
when the other chain triggers lose. It must first rush to its own kill-zone,
then absorb, and the retry/game-over dialog must appear only after both chains
are empty.
"""
from __future__ import annotations

from pathlib import Path

from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"
CASES = (5, 12, 19)
MAX_FRAMES = 900
MIN_DIALOG_DELAY_AFTER_EMPTY = 12
MAX_HEAD_KZ_DIST_AT_FIRST_DROP = 6


def load_track_page(emu: ZumaFullZ80Emulator, page: int, path: Path) -> None:
    data = path.read_bytes()
    start = page * PAGE_SIZE
    emu.mem.physical[start : start + PAGE_SIZE] = b"\x00" * PAGE_SIZE
    emu.mem.physical[start : start + len(data)] = data


def gb(emu: ZumaFullZ80Emulator, name: str) -> int:
    return emu.get_byte(emu.sym[name])


def sb(emu: ZumaFullZ80Emulator, name: str, value: int) -> None:
    emu.set_byte(emu.sym[name], value)


def signed16(value: int) -> int:
    return value - 0x10000 if value & 0x8000 else value


def chain2_head_distance_to_kz(emu: ZumaFullZ80Emulator) -> int | None:
    sym = emu.sym
    if gb(emu, "Core.VDC2_SlotsLen") == 0:
        return None
    emu.call(sym["Core.VDC_SwapChains"], max_steps=5_000_000)
    emu.call(sym["Core.SetSecondTrackPage"], max_steps=5_000_000)
    emu.call(sym["Core.VDC_SlotPos"], a=0, max_steps=5_000_000)
    cf = emu.reg.F & 0x01
    x = signed16(emu.reg.BC)
    y = signed16(emu.reg.DE)
    emu.call(sym["Core.VDC_SwapChains"], max_steps=5_000_000)
    emu.call(sym["Core.SetCurrentTrackPage"], max_steps=5_000_000)
    if cf:
        return None
    # 1024×768: KZ_SPR_HALF = 70 (draw 141, scale-about-origin); было 44 (88 native)
    kz_x = (emu.get_word(sym["Core.VDC2_KzDrawX16"]) // 16) + 70
    kz_y = (emu.get_word(sym["Core.VDC2_KzDrawY16"]) // 16) + 70
    return abs(x - kz_x) + abs(y - kz_y)


def run_case(level: int) -> tuple[bool, str]:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    load_track_page(emu, 0x06, PACK / f"track_l{level:02d}_640.bin")
    load_track_page(emu, 0x0F, PACK / f"track_l{level:02d}_2_640.bin")
    emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
    sb(emu, "Core.CurrentLevel", level - 1)
    sb(emu, "Core.CurrentDifficulty", 0)
    emu.call(sym["Core.VDC_Init"], max_steps=5_000_000)

    cl_start = sym["Core.VDC_ChainLocalStart"]
    hsa_off = sym["Core.VDC_HSA"] - cl_start
    freeze_off = sym["Core.VDC_ChainFreezeCnt"] - cl_start
    tns_off = sym["Core.VDC_TrackNumSlots"] - cl_start
    tns2 = emu.get_word(sym["Core.VDC2_ChainLocal"] + tns_off)
    if not (8 <= tns2 <= 240):
        return False, f"L{level:02d}: bad chain2 TrackNumSlots={tns2}"

    # Chain1 has already lost and is empty. Chain2 is still several cells before
    # its own kill-zone; this reproduces the visual bug reported on hardware.
    sb(emu, "Core.VDC_GameState", 1)  # ABSORB
    sb(emu, "Core.VDC_DialogState", 0)
    sb(emu, "Core.VDC_Lives", 1)
    sb(emu, "Core.VDC_SlotsLen", 0)
    sb(emu, "Core.VDC_HSub", 0)
    sb(emu, "Core.VDC_KzFrame", 0)
    sb(emu, "Core.VDC_HasSecondChain", 1)
    sb(emu, "Core.VDC_SecondActive", 0)
    sb(emu, "Core.VDC_HeadAbsorbAlpha", 255)

    chain2_len = 4
    for i in range(chain2_len):
        emu.set_byte(sym["Core.VDC2_Slots"] + i, i % 6)
        emu.set_byte(sym["Core.VDC2_Offsets"] + i, 0)
        emu.set_byte(sym["Core.VDC2_Shot2"] + i, 0)
        emu.set_byte(sym["Core.VDC2_ExplodeFrame"] + i, 0)
        emu.set_byte(sym["Core.VDC2_ExplodeMarker"] + i, 0)
    sb(emu, "Core.VDC2_SlotsLen", chain2_len)
    sb(emu, "Core.VDC2_HSub", 9)
    sb(emu, "Core.VDC2_KzFrame", 1)
    emu.set_byte(sym["Core.VDC2_ChainLocal"] + hsa_off, max(0, tns2 - 5))
    emu.set_byte(sym["Core.VDC2_ChainLocal"] + hsa_off + 1, 0)
    emu.set_byte(sym["Core.VDC2_ChainLocal"] + freeze_off, 0)

    boundary_reached = False
    prev_len = chain2_len
    first_boundary_frame: int | None = None
    first_drop_frame: int | None = None
    first_drop_dist: int | None = None
    first_empty_frame: int | None = None
    history: list[str] = []

    for frame in range(MAX_FRAMES):
        before_len = gb(emu, "Core.VDC2_SlotsLen")
        before_hsa = emu.get_byte(sym["Core.VDC2_ChainLocal"] + hsa_off)
        before_hsub = gb(emu, "Core.VDC2_HSub")
        before_kz = gb(emu, "Core.VDC2_KzFrame")
        before_dialog = gb(emu, "Core.VDC_DialogState")
        before_delay = gb(emu, "Core.VDC_DualLoseMenuDelay")
        history.append(
            f"f={frame:03d} len2={before_len} hsa2={before_hsa} "
            f"hsub2={before_hsub} kz2={before_kz} delay={before_delay} dlg={before_dialog}"
        )
        history = history[-24:]

        if before_len > 0 and before_dialog != 0:
            return False, "L%02d: dialog opened while chain2 still has balls\n%s" % (
                level,
                "\n".join(history),
            )
        if before_len > 0 and before_kz == 11 and before_hsub == 0:
            boundary_reached = True
            if first_boundary_frame is None:
                first_boundary_frame = frame

        emu.call(sym["Core.VDC_UpdateAllChains"], max_steps=5_000_000)

        after_len = gb(emu, "Core.VDC2_SlotsLen")
        if after_len == 0 and first_empty_frame is None:
            first_empty_frame = frame
        if after_len < prev_len and first_drop_frame is None:
            first_drop_frame = frame
            first_drop_dist = chain2_head_distance_to_kz(emu)
            if first_drop_dist is None or first_drop_dist > MAX_HEAD_KZ_DIST_AT_FIRST_DROP:
                return False, (
                    f"L{level:02d}: first drop before head reached KZ center, "
                    f"dist={first_drop_dist} max={MAX_HEAD_KZ_DIST_AT_FIRST_DROP}\n"
                    + "\n".join(history)
                )
        if after_len < prev_len and not boundary_reached:
            print("FAIL: chain2 length decreased before reaching kill-zone boundary")
            print("\n".join(history))
            print(
                f"after frame {frame}: len2 {prev_len}->{after_len}, "
                f"kz2={gb(emu, 'Core.VDC2_KzFrame')} hsub2={gb(emu, 'Core.VDC2_HSub')}"
            )
            return 1
        prev_len = after_len

        if after_len == 0 and gb(emu, "Core.VDC_DialogState") != 0:
            if first_empty_frame is None:
                return False, f"L{level:02d}: internal test error: dialog with no first_empty_frame"
            delay = frame - first_empty_frame
            if delay < MIN_DIALOG_DELAY_AFTER_EMPTY:
                return False, (
                    f"L{level:02d}: dialog too soon after chain2 emptied, "
                    f"delay={delay} min={MIN_DIALOG_DELAY_AFTER_EMPTY}\n"
                    + "\n".join(history)
                )
            return True, (
                f"L{level:02d}: boundary_frame={first_boundary_frame} first_drop_frame={first_drop_frame} "
                f"first_drop_dist={first_drop_dist} empty_frame={first_empty_frame} "
                f"dialog_frame={frame} delay={delay}"
            )

    return False, (
        f"L{level:02d}: dual-chain lose absorb did not finish; likely infinite loop/state\n"
        + "\n".join(history)
        + "\n"
        + f"final: len2={gb(emu, 'Core.VDC2_SlotsLen')} "
        f"hsub2={gb(emu, 'Core.VDC2_HSub')} "
        f"kz2={gb(emu, 'Core.VDC2_KzFrame')} "
        f"dlg={gb(emu, 'Core.VDC_DialogState')}"
    )


def run_primary_after_chain2_trigger_case(level: int) -> tuple[bool, str]:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    load_track_page(emu, 0x06, PACK / f"track_l{level:02d}_640.bin")
    load_track_page(emu, 0x0F, PACK / f"track_l{level:02d}_2_640.bin")
    emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
    sb(emu, "Core.CurrentLevel", level - 1)
    sb(emu, "Core.CurrentDifficulty", 0)
    emu.call(sym["Core.VDC_Init"], max_steps=5_000_000)

    cl_start = sym["Core.VDC_ChainLocalStart"]
    hsa_off = sym["Core.VDC_HSA"] - cl_start
    freeze_off = sym["Core.VDC_ChainFreezeCnt"] - cl_start
    tns_off = sym["Core.VDC_TrackNumSlots"] - cl_start
    tns1 = emu.get_word(sym["Core.VDC_TrackNumSlots"])
    tns2 = emu.get_word(sym["Core.VDC2_ChainLocal"] + tns_off)
    if not (8 <= tns1 <= 240 and 8 <= tns2 <= 240):
        return False, f"L{level:02d}: bad TrackNumSlots chain1={tns1} chain2={tns2}"

    # Mirror scenario: chain2 triggered lose and is already absorbing at its KZ.
    # Primary chain1 is still before its own KZ and must use the same rush path
    # before any head ball is removed.
    sb(emu, "Core.VDC_GameState", 1)  # ABSORB
    sb(emu, "Core.VDC_DialogState", 0)
    sb(emu, "Core.VDC_Lives", 1)
    sb(emu, "Core.VDC_HasSecondChain", 1)
    sb(emu, "Core.VDC_SecondActive", 0)
    sb(emu, "Core.VDC_HeadAbsorbAlpha", 255)
    sb(emu, "Core.VDC_DualLoseMenuDelay", 0)

    chain_len = 4
    sb(emu, "Core.VDC_SlotsLen", chain_len)
    sb(emu, "Core.VDC_HSub", 9)
    sb(emu, "Core.VDC_KzFrame", 1)
    sb(emu, "Core.VDC_HSA", max(0, tns1 - 5))
    sb(emu, "Core.VDC_ChainFreezeCnt", 0)
    sb(emu, "Core.VDC_LoseHoldCnt", 0)

    for i in range(chain_len):
        emu.set_byte(sym["Core.VDC_Slots"] + i, i % 6)
        emu.set_byte(sym["Core.VDC_Offsets"] + i, 0)
        emu.set_byte(sym["Core.VDC_Shot2"] + i, 0)
        emu.set_byte(sym["Core.VDC_ExplodeFrame"] + i, 0)
        emu.set_byte(sym["Core.VDC_ExplodeMarker"] + i, 0)

        emu.set_byte(sym["Core.VDC2_Slots"] + i, (i + 1) % 6)
        emu.set_byte(sym["Core.VDC2_Offsets"] + i, 0)
        emu.set_byte(sym["Core.VDC2_Shot2"] + i, 0)
        emu.set_byte(sym["Core.VDC2_ExplodeFrame"] + i, 0)
        emu.set_byte(sym["Core.VDC2_ExplodeMarker"] + i, 0)

    sb(emu, "Core.VDC2_SlotsLen", chain_len)
    sb(emu, "Core.VDC2_HSub", 0)
    sb(emu, "Core.VDC2_KzFrame", 11)
    emu.set_byte(sym["Core.VDC2_ChainLocal"] + hsa_off, min(tns2, 255))
    emu.set_byte(sym["Core.VDC2_ChainLocal"] + hsa_off + 1, 0)
    emu.set_byte(sym["Core.VDC2_ChainLocal"] + freeze_off, 0)

    boundary_reached = False
    prev_len = chain_len
    first_boundary_frame: int | None = None
    first_drop_frame: int | None = None
    history: list[str] = []

    for frame in range(MAX_FRAMES):
        before_len = gb(emu, "Core.VDC_SlotsLen")
        before_hsa = gb(emu, "Core.VDC_HSA")
        before_hsub = gb(emu, "Core.VDC_HSub")
        before_kz = gb(emu, "Core.VDC_KzFrame")
        before_len2 = gb(emu, "Core.VDC2_SlotsLen")
        before_dialog = gb(emu, "Core.VDC_DialogState")
        history.append(
            f"f={frame:03d} len1={before_len} hsa1={before_hsa} "
            f"hsub1={before_hsub} kz1={before_kz} len2={before_len2} dlg={before_dialog}"
        )
        history = history[-24:]

        if (before_len > 0 or before_len2 > 0) and before_dialog != 0:
            return False, "L%02d mirror: dialog opened before both chains emptied\n%s" % (
                level,
                "\n".join(history),
            )
        if before_len > 0 and before_kz == 11 and before_hsub == 0:
            boundary_reached = True
            if first_boundary_frame is None:
                first_boundary_frame = frame

        emu.call(sym["Core.VDC_UpdateAllChains"], max_steps=5_000_000)

        after_len = gb(emu, "Core.VDC_SlotsLen")
        if after_len < prev_len and first_drop_frame is None:
            first_drop_frame = frame
        if after_len < prev_len and not boundary_reached:
            return False, (
                f"L{level:02d} mirror: chain1 length decreased before KZ boundary\n"
                + "\n".join(history)
                + "\n"
                + f"after frame {frame}: len1 {prev_len}->{after_len}, "
                f"kz1={gb(emu, 'Core.VDC_KzFrame')} hsub1={gb(emu, 'Core.VDC_HSub')}"
            )
        prev_len = after_len

        if after_len == 0 and gb(emu, "Core.VDC2_SlotsLen") == 0:
            return True, (
                f"L{level:02d} mirror: boundary_frame={first_boundary_frame} "
                f"first_drop_frame={first_drop_frame}"
            )

    return False, (
        f"L{level:02d} mirror: dual-chain lose absorb did not finish\n"
        + "\n".join(history)
    )


def main() -> int:
    failures: list[str] = []
    for level in CASES:
        ok, msg = run_case(level)
        print(("PASS: " if ok else "FAIL: ") + msg)
        if not ok:
            failures.append(msg)
        ok, msg = run_primary_after_chain2_trigger_case(level)
        print(("PASS: " if ok else "FAIL: ") + msg)
        if not ok:
            failures.append(msg)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
