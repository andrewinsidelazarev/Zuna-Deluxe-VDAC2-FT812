#!/usr/bin/env python3
"""Дубль-цепочки: проверка lead-in каждой цепочки.

Дизайн (2026-05-30): полный fast-fill всего трека (LevelStart=TrackNumSlots)
УБРАН — из-за него вся цепочка улетала на быстрой фазе прямо в килл-зону.
Lead-in из настроек уровня теперь применяется СИММЕТРИЧНО и БЕЗ /2 к обеим
цепочкам (клон ChainLocal после VDC_LoadLevelSettings). Тест фиксирует именно
это: has2, валидные пер-цепочечные длины треков, lead-in одинаковый у обеих
цепочек, равен таблице уровня и остаётся меньше TrackNumSlots."""
from __future__ import annotations

from pathlib import Path

from make_level_pack import encode_track_v2_pages, scale_track_samples
from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator


ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"
CASES = (5, 12, 19)
TRACK_RUNTIME_PAGES = (0x06, 0x0F, 0x10, 0x12)


def install_ret_a(emu: ZumaFullZ80Emulator, addr: int, value: int) -> None:
    emu.mem.write(addr, 0x3E)      # LD A,n
    emu.mem.write(addr + 1, value & 0xFF)
    emu.mem.write(addr + 2, 0xC9)  # RET


def load_page_bytes(emu: ZumaFullZ80Emulator, page: int, data: bytes) -> None:
    start = page * PAGE_SIZE
    emu.mem.physical[start : start + PAGE_SIZE] = b"\x00" * PAGE_SIZE
    emu.mem.physical[start : start + len(data)] = data


def write_page_table(emu: ZumaFullZ80Emulator, addr: int, pages: list[int]) -> None:
    for idx in range(4):
        emu.set_byte(addr + idx, pages[idx] if idx < len(pages) else 0)


def load_track_v2_pair(emu: ZumaFullZ80Emulator, track1: Path, track2: Path) -> None:
    first = scale_track_samples(track1.read_bytes())
    second = scale_track_samples(track2.read_bytes())
    assert first is not None and second is not None
    count1, pages1 = encode_track_v2_pages(first)
    count2, pages2 = encode_track_v2_pages(second)
    all_pages = pages1 + pages2
    if len(all_pages) > len(TRACK_RUNTIME_PAGES):
        raise AssertionError(f"test runtime page overflow: {len(all_pages)} pages")

    for page_id, data in zip(TRACK_RUNTIME_PAGES, all_pages):
        load_page_bytes(emu, page_id, data)

    sym = emu.sym
    write_page_table(emu, sym["Core.VDC_TrackPages1"], list(TRACK_RUNTIME_PAGES[: len(pages1)]))
    write_page_table(
        emu,
        sym["Core.VDC_TrackPages2"],
        list(TRACK_RUNTIME_PAGES[len(pages1) : len(pages1) + len(pages2)]),
    )
    emu.set_word(sym["Core.VDC_TrackSamples1"], count1)
    emu.set_word(sym["Core.VDC_TrackSamples2"], count2)
    emu.set_byte(sym["Core.VDC_TrackPageCount1"], len(pages1))
    emu.set_byte(sym["Core.VDC_TrackPageCount2"], len(pages2))
    emu.call(sym["Core.SetCurrentTrackPage"], max_steps=200_000)


def main() -> int:
    failures: list[str] = []
    for level in CASES:
        emu = ZumaFullZ80Emulator(ROOT)
        sym = emu.sym
        install_ret_a(emu, sym["Core.ReadRTCSeconds"], 17)
        load_track_v2_pair(
            emu,
            PACK / f"track_l{level:02d}_640.bin",
            PACK / f"track_l{level:02d}_2_640.bin",
        )
        emu.set_byte(sym["Core.CurrentLevel"], level - 1)
        emu.set_byte(sym["Core.CurrentDifficulty"], 0)
        emu.call(sym["Core.GetCurrentStart"], max_steps=200_000)
        expected_start = emu.reg.A
        emu.call(sym["Core.VDC_Init"], max_steps=5_000_000)

        local_off = sym["Core.VDC_TrackNumSlots"] - sym["Core.VDC_ChainLocalStart"]
        start_off = sym["Core.VDC_LevelStart"] - sym["Core.VDC_ChainLocalStart"]
        tns1 = emu.get_word(sym["Core.VDC_TrackNumSlots"])
        tns2 = emu.get_word(sym["Core.VDC2_ChainLocal"] + local_off)
        start1 = emu.get_byte(sym["Core.VDC_LevelStart"])
        start2 = emu.get_byte(sym["Core.VDC2_ChainLocal"] + start_off)
        has2 = emu.get_byte(sym["Core.VDC_HasSecondChain"])
        print(
            f"L{level:02d}: has2={has2} tns=({tns1},{tns2}) "
            f"lead-in=({start1},{start2}) expected={expected_start}"
        )
        if has2 != 1:
            failures.append(f"L{level:02d}: вторая цепочка не включена")
        if not (0 < tns1 <= 240) or not (0 < tns2 <= 240):
            failures.append(f"L{level:02d}: длины треков невменяемы tns=({tns1},{tns2})")
        if start1 != start2:
            failures.append(f"L{level:02d}: lead-in асимметричен {start1} != {start2}")
        if start1 != expected_start:
            failures.append(
                f"L{level:02d}: lead-in {start1} != настройке уровня {expected_start}"
            )
        if not (1 <= start1 < (tns1 & 0xFF)):
            failures.append(
                f"L{level:02d}: lead-in {start1} вне [1, tns={tns1}) — либо ноль, либо full-rush"
            )

    if failures:
        for item in failures:
            print(f"FAIL: {item}")
        return 1
    print("PASS: дубль-цепочки — lead-in из настроек симметричен, без /2 и без full-track rush")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
