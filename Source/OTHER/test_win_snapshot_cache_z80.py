#!/usr/bin/env python3
"""Compare cache-derived WIN heads with the original Z80 snapshot routine."""
from __future__ import annotations

from pathlib import Path

from test_dual_chain_win_outro_z80 import load_track_v2_pair
from zuma_full_z80_emulator import ZumaFullZ80Emulator

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"
SENTINEL_1 = 0xA55A
SENTINEL_2 = 0x5AA5


def set_active_chain(
    emu: ZumaFullZ80Emulator,
    slots: list[int],
    offsets: list[int],
    *,
    hsa: int,
    hsub: int,
) -> None:
    sym = emu.sym
    slots_ptr = emu.get_word(sym["Core.VDC_pSlots"])
    offsets_ptr = emu.get_word(sym["Core.VDC_pOffsets"])
    emu.set_byte(sym["Core.VDC_SlotsLen"], len(slots))
    emu.set_word(sym["Core.VDC_HSA"], hsa)
    emu.set_byte(sym["Core.VDC_HSub"], hsub)
    for idx, color in enumerate(slots):
        emu.set_byte(slots_ptr + idx, color)
        emu.set_byte(offsets_ptr + idx, offsets[idx] & 0xFF)


def oracle_head(emu: ZumaFullZ80Emulator) -> int | None:
    sym = emu.sym
    slots_len = emu.get_byte(sym["Core.VDC_SlotsLen"])
    slots_ptr = emu.get_word(sym["Core.VDC_pSlots"])
    samples = emu.get_word(sym["Core.VDC_ActiveTrackSamples"])
    found: list[int] = []
    for idx in range(slots_len):
        if emu.get_byte(slots_ptr + idx) >= 6:
            continue
        emu.call(sym["Core.VDC_SlotT"], a=idx, max_steps=500_000)
        track_t = ((emu.reg.H & 0xFF) << 8) | (emu.reg.L & 0xFF)
        if track_t & 0x8000:
            continue
        found.append(min(track_t, samples - 1))
    return max(found) if found else None


def cache_head(emu: ZumaFullZ80Emulator, chain: int) -> tuple[int, int]:
    sym = emu.sym
    emu.set_word(sym["Core.VDC_WinHeadS1"], SENTINEL_1)
    emu.set_word(sym["Core.VDC_WinHeadS2"], SENTINEL_2)
    emu.call(sym["Core.ZL_SelectPrimaryBallCache"], max_steps=200_000)
    emu.call(sym["Core.ZL_BuildActiveChainCache"], max_steps=5_000_000)
    return (
        emu.get_word(sym["Core.VDC_WinHeadS1"]),
        emu.get_word(sym["Core.VDC_WinHeadS2"]),
    )


def check_case(
    emu: ZumaFullZ80Emulator,
    chain: int,
    name: str,
    slots: list[int],
    offsets: list[int],
    *,
    hsa: int,
    hsub: int,
) -> None:
    sym = emu.sym
    if chain == 2:
        emu.call(sym["Core.VDC_SwapChains"], max_steps=500_000)
        emu.call(sym["Core.SetSecondTrackPage"], max_steps=200_000)
    try:
        set_active_chain(emu, slots, offsets, hsa=hsa, hsub=hsub)
        expected = oracle_head(emu)
        head1, head2 = cache_head(emu, chain)
        actual = head1 if chain == 1 else head2
        untouched = head2 if chain == 1 else head1
        expected_untouched = SENTINEL_2 if chain == 1 else SENTINEL_1
        expected_actual = expected if expected is not None else (SENTINEL_1 if chain == 1 else SENTINEL_2)
        assert actual == expected_actual, (
            f"chain{chain} {name}: cache head={actual:#06x}, oracle={expected}"
        )
        assert untouched == expected_untouched, (
            f"chain{chain} {name}: inactive WIN head changed to {untouched:#06x}"
        )
        print(f"PASS: chain{chain} {name}: head={actual:#06x}")
    finally:
        if chain == 2:
            emu.call(sym["Core.VDC_SwapChains"], max_steps=500_000)
            emu.call(sym["Core.SetCurrentTrackPage"], max_steps=200_000)


def check_disabled_and_empty(emu: ZumaFullZ80Emulator) -> None:
    sym = emu.sym
    set_active_chain(emu, [0, 1, 2], [0, 0, 0], hsa=8, hsub=5)
    emu.set_byte(sym["Core.VDC_GameState"], 1)
    head1, head2 = cache_head(emu, 1)
    assert (head1, head2) == (SENTINEL_1, SENTINEL_2), "non-PLAY cache changed WIN heads"

    emu.set_byte(sym["Core.VDC_GameState"], 0)
    set_active_chain(emu, [], [], hsa=0, hsub=0)
    head1, head2 = cache_head(emu, 1)
    assert (head1, head2) == (SENTINEL_1, SENTINEL_2), "empty cache changed WIN heads"
    print("PASS: non-PLAY and empty cache keep prior WIN heads")


def main() -> int:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    load_track_v2_pair(
        emu,
        PACK / "track_l19_640.bin",
        PACK / "track_l19_2_640.bin",
    )
    emu.set_byte(sym["Core.CurrentLevel"], 18)
    emu.set_byte(sym["Core.CurrentDifficulty"], 0)
    emu.call(sym["Core.VDC_Init"], max_steps=5_000_000)
    emu.set_byte(sym["Core.VDC_GameState"], 0)
    emu.set_byte(sym["Core.VDC_HasSecondChain"], 1)
    emu.set_byte(sym["Core.VDC_SecondActive"], 0)
    emu.call(sym["Core.SetCurrentTrackPage"], max_steps=200_000)

    cases = (
        ("normal", [0, 1, 2, 3], [0, 0, 0, 0], 8, 5),
        ("leading-gap", [0xFF, 1, 2, 3], [0, 0, 0, 0], 8, 3),
        ("all-gap", [0xFF, 0xFE, 0xFF], [0, 0, 0], 8, 0),
        ("all-negative", [0, 1, 2], [-20, 0, 0], 0, 0),
        ("track-clamp", [0, 1], [100, 0], 255, 31),
        ("non-monotonic", [0, 1, 2], [-100, 80, 0], 8, 0),
        ("beyond-hsa-positive-offset", [0, 1, 2], [0, 0, 127], 1, 0),
    )
    for chain in (1, 2):
        for name, slots, offsets, hsa, hsub in cases:
            check_case(
                emu,
                chain,
                name,
                slots,
                offsets,
                hsa=hsa,
                hsub=hsub,
            )
    check_disabled_and_empty(emu)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
