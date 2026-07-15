#!/usr/bin/env python3
"""Dual-chain lose-state regression test.

The non-triggering chain must not fade/remove head balls at its current position
when the other chain triggers lose. It must first rush to its own kill-zone,
then absorb, and the retry/game-over dialog must appear only after both chains
are empty.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from test_dual_chain_fastfill import install_ret_a, load_track_v2_pair
from zuma_full_z80_emulator import ZumaFullZ80Emulator

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"
CASES = (5, 12, 19)
MAX_FRAMES = 900
MIN_DIALOG_DELAY_AFTER_EMPTY = 12
CELL_SIZE = 32


def gb(emu: ZumaFullZ80Emulator, name: str) -> int:
    return emu.get_byte(emu.sym[name])


def sb(emu: ZumaFullZ80Emulator, name: str, value: int) -> None:
    emu.set_byte(emu.sym[name], value)


@dataclass(frozen=True)
class HeadPopEvent:
    frame: int
    chain: int
    index: int
    slot: int
    length_before: int
    hsa: int
    hsub: int
    endpoint: int
    head_t: int
    rem: int
    kz_frame: int


class HeadPopTrace:
    """Record real ABSORB head removals at the actual RemoveSlotAt entry."""

    def __init__(self, emu: ZumaFullZ80Emulator) -> None:
        self.emu = emu
        self.frame = -1
        self.events: list[HeadPopEvent] = []
        self._raw_step = emu.step
        emu.step = self._step

    def _step(self) -> int:
        emu = self.emu
        sym = emu.sym
        if emu.reg.PC == sym["Core.VDC_RemoveSlotAt"]:
            index = gb(emu, "Core.VDC_TmpGapIdx")
            slots = emu.get_word(sym["Core.VDC_pSlots"])
            slot = emu.get_byte(slots + index)
            state = gb(emu, "Core.VDC_GameState")
            # GAP-marker removal also uses RemoveSlotAt. Only a real ball removed
            # during ABSORB is a kill-zone head pop.
            if state == 1 and slot < sym["Core.VDC_NUM_COLORS"]:
                hsa = gb(emu, "Core.VDC_HSA")
                hsub = gb(emu, "Core.VDC_HSub")
                endpoint = (
                    emu.get_word(sym["Core.VDC_TrackNumSlots"]) * CELL_SIZE
                    + gb(emu, "Core.VDC_KzEndSub")
                )
                head_t = hsa * CELL_SIZE + hsub
                self.events.append(
                    HeadPopEvent(
                        frame=self.frame,
                        chain=2 if gb(emu, "Core.VDC_SecondActive") else 1,
                        index=index,
                        slot=slot,
                        length_before=gb(emu, "Core.VDC_SlotsLen"),
                        hsa=hsa,
                        hsub=hsub,
                        endpoint=endpoint,
                        head_t=head_t,
                        rem=endpoint - head_t,
                        kz_frame=gb(emu, "Core.VDC_KzFrame"),
                    )
                )
        return self._raw_step()


def validate_track_endpoints(emu: ZumaFullZ80Emulator, level: int) -> str | None:
    """Both chain endpoints must be the final baked sample of their own track."""
    sym = emu.sym
    cl_start = sym["Core.VDC_ChainLocalStart"]
    tns_off = sym["Core.VDC_TrackNumSlots"] - cl_start
    kz_off = sym["Core.VDC_KzEndSub"] - cl_start
    endpoint1 = (
        emu.get_word(sym["Core.VDC_TrackNumSlots"]) * CELL_SIZE
        + gb(emu, "Core.VDC_KzEndSub")
    )
    endpoint2 = (
        emu.get_word(sym["Core.VDC2_ChainLocal"] + tns_off) * CELL_SIZE
        + emu.get_byte(sym["Core.VDC2_ChainLocal"] + kz_off)
    )
    samples1 = emu.get_word(sym["Core.VDC_TrackSamples1"])
    samples2 = emu.get_word(sym["Core.VDC_TrackSamples2"])
    if endpoint1 != samples1 - 1 or endpoint2 != samples2 - 1:
        return (
            f"L{level:02d}: bad track endpoint metadata: "
            f"chain1 endpoint={endpoint1} samples={samples1} "
            f"chain2 endpoint={endpoint2} samples={samples2}"
        )
    return None


def validate_new_pops(
    level: int,
    events: list[HeadPopEvent],
    start: int,
) -> str | None:
    for event in events[start:]:
        if event.index != 0 or event.rem != 0:
            return (
                f"L{level:02d}: premature/off-center head pop: "
                f"frame={event.frame} chain={event.chain} idx={event.index} "
                f"len={event.length_before} hsa={event.hsa} hsub={event.hsub} "
                f"head_t={event.head_t} endpoint={event.endpoint} rem={event.rem} "
                f"kz={event.kz_frame}"
            )
    return None


def validate_pop_counts(
    level: int,
    events: list[HeadPopEvent],
    expected: dict[int, int],
) -> str | None:
    actual = Counter(event.chain for event in events)
    expected_counter = Counter(expected)
    if actual != expected_counter:
        return (
            f"L{level:02d}: head-pop count mismatch: "
            f"actual={dict(actual)} expected={dict(expected_counter)}"
        )
    for chain, count in expected.items():
        lengths = [event.length_before for event in events if event.chain == chain]
        expected_lengths = list(range(count, 0, -1))
        if lengths != expected_lengths:
            return (
                f"L{level:02d}: chain{chain} pop order mismatch: "
                f"lengths={lengths} expected={expected_lengths}"
            )
    return None


def run_case(level: int) -> tuple[bool, str]:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    install_ret_a(emu, sym["Core.ReadRTCSeconds"], 17)
    load_track_v2_pair(
        emu,
        PACK / f"track_l{level:02d}_640.bin",
        PACK / f"track_l{level:02d}_2_640.bin",
    )
    sb(emu, "Core.CurrentLevel", level - 1)
    sb(emu, "Core.CurrentDifficulty", 0)
    emu.call(sym["Core.VDC_Init"], max_steps=5_000_000)
    endpoint_error = validate_track_endpoints(emu, level)
    if endpoint_error:
        return False, endpoint_error

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

    trace = HeadPopTrace(emu)
    first_empty_frame: int | None = None
    history: list[str] = []

    for frame in range(MAX_FRAMES):
        trace.frame = frame
        before_len1 = gb(emu, "Core.VDC_SlotsLen")
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

        if (before_len1 > 0 or before_len > 0) and before_dialog != 0:
            return False, "L%02d: dialog opened while a chain still has balls\n%s" % (
                level,
                "\n".join(history),
            )

        event_start = len(trace.events)
        emu.call(sym["Core.VDC_UpdateAllChains"], max_steps=5_000_000)
        pop_error = validate_new_pops(level, trace.events, event_start)
        if pop_error:
            return False, pop_error + "\n" + "\n".join(history)

        after_len1 = gb(emu, "Core.VDC_SlotsLen")
        after_len = gb(emu, "Core.VDC2_SlotsLen")
        new_counts = Counter(event.chain for event in trace.events[event_start:])
        deltas = {1: before_len1 - after_len1, 2: before_len - after_len}
        if deltas != {1: new_counts[1], 2: new_counts[2]}:
            return False, (
                f"L{level:02d}: SlotsLen changed without matching real head-pop: "
                f"frame={frame} deltas={deltas} events={dict(new_counts)}\n"
                + "\n".join(history)
            )
        if after_len == 0 and first_empty_frame is None:
            first_empty_frame = frame

        dialog = gb(emu, "Core.VDC_DialogState")
        if dialog != 0 and (after_len1 != 0 or after_len != 0):
            return False, (
                f"L{level:02d}: dialog opened before both chains emptied: "
                f"len1={after_len1} len2={after_len}\n" + "\n".join(history)
            )
        if after_len1 == 0 and after_len == 0 and dialog != 0:
            if first_empty_frame is None:
                return False, f"L{level:02d}: internal test error: dialog with no first_empty_frame"
            delay = frame - first_empty_frame
            count_error = validate_pop_counts(level, trace.events, {2: chain2_len})
            if count_error:
                return False, count_error + "\n" + "\n".join(history)
            if gb(emu, "Core.VDC_GameState") != 2 or dialog not in (1, 2):
                return False, (
                    f"L{level:02d}: invalid completed lose state: "
                    f"state={gb(emu, 'Core.VDC_GameState')} dialog={dialog}"
                )
            if delay < MIN_DIALOG_DELAY_AFTER_EMPTY:
                return False, (
                    f"L{level:02d}: dialog too soon after chain2 emptied, "
                    f"delay={delay} min={MIN_DIALOG_DELAY_AFTER_EMPTY}\n"
                    + "\n".join(history)
                )
            first_drop_frame = trace.events[0].frame if trace.events else None
            return True, (
                f"L{level:02d}: pops={dict(Counter(e.chain for e in trace.events))} "
                f"first_drop_frame={first_drop_frame} empty_frame={first_empty_frame} "
                f"dialog_frame={frame} delay={delay}"
            )

    return False, (
        f"L{level:02d}: dual-chain lose absorb did not finish; likely infinite loop/state\n"
        + "\n".join(history)
        + "\n"
        + f"final: len2={gb(emu, 'Core.VDC2_SlotsLen')} "
        f"hsub2={gb(emu, 'Core.VDC2_HSub')} "
        f"kz2={gb(emu, 'Core.VDC2_KzFrame')} "
        f"dlg={gb(emu, 'Core.VDC_DialogState')} pops={len(trace.events)}"
    )


def run_primary_after_chain2_trigger_case(level: int) -> tuple[bool, str]:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    install_ret_a(emu, sym["Core.ReadRTCSeconds"], 17)
    load_track_v2_pair(
        emu,
        PACK / f"track_l{level:02d}_640.bin",
        PACK / f"track_l{level:02d}_2_640.bin",
    )
    sb(emu, "Core.CurrentLevel", level - 1)
    sb(emu, "Core.CurrentDifficulty", 0)
    emu.call(sym["Core.VDC_Init"], max_steps=5_000_000)
    endpoint_error = validate_track_endpoints(emu, level)
    if endpoint_error:
        return False, endpoint_error

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

    trace = HeadPopTrace(emu)
    first_both_empty_frame: int | None = None
    history: list[str] = []

    for frame in range(MAX_FRAMES):
        trace.frame = frame
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

        event_start = len(trace.events)
        emu.call(sym["Core.VDC_UpdateAllChains"], max_steps=5_000_000)
        pop_error = validate_new_pops(level, trace.events, event_start)
        if pop_error:
            return False, pop_error + "\n" + "\n".join(history)

        after_len = gb(emu, "Core.VDC_SlotsLen")
        after_len2 = gb(emu, "Core.VDC2_SlotsLen")
        new_counts = Counter(event.chain for event in trace.events[event_start:])
        deltas = {1: before_len - after_len, 2: before_len2 - after_len2}
        if deltas != {1: new_counts[1], 2: new_counts[2]}:
            return False, (
                f"L{level:02d} mirror: SlotsLen changed without matching real head-pop: "
                f"frame={frame} deltas={deltas} events={dict(new_counts)}\n"
                + "\n".join(history)
            )

        if after_len == 0 and after_len2 == 0 and first_both_empty_frame is None:
            first_both_empty_frame = frame

        dialog = gb(emu, "Core.VDC_DialogState")
        if dialog != 0 and (after_len != 0 or after_len2 != 0):
            return False, (
                f"L{level:02d} mirror: dialog opened before both chains emptied: "
                f"len1={after_len} len2={after_len2}\n" + "\n".join(history)
            )
        if dialog != 0:
            if first_both_empty_frame is None:
                return False, f"L{level:02d} mirror: dialog with no empty-frame marker"
            delay = frame - first_both_empty_frame
            count_error = validate_pop_counts(
                level,
                trace.events,
                {1: chain_len, 2: chain_len},
            )
            if count_error:
                return False, count_error + "\n" + "\n".join(history)
            if gb(emu, "Core.VDC_GameState") != 2 or dialog not in (1, 2):
                return False, (
                    f"L{level:02d} mirror: invalid completed lose state: "
                    f"state={gb(emu, 'Core.VDC_GameState')} dialog={dialog}"
                )
            if delay < MIN_DIALOG_DELAY_AFTER_EMPTY:
                return False, (
                    f"L{level:02d} mirror: dialog too soon after both chains emptied, "
                    f"delay={delay} min={MIN_DIALOG_DELAY_AFTER_EMPTY}\n"
                    + "\n".join(history)
                )
            first_drop_frame = min(event.frame for event in trace.events)
            return True, (
                f"L{level:02d} mirror: pops={dict(Counter(e.chain for e in trace.events))} "
                f"first_drop_frame={first_drop_frame} empty_frame={first_both_empty_frame} "
                f"dialog_frame={frame} delay={delay}"
            )

    return False, (
        f"L{level:02d} mirror: dual-chain lose absorb did not finish\n"
        + "\n".join(history)
        + "\n"
        + f"final: len1={gb(emu, 'Core.VDC_SlotsLen')} "
        f"len2={gb(emu, 'Core.VDC2_SlotsLen')} "
        f"state={gb(emu, 'Core.VDC_GameState')} "
        f"dlg={gb(emu, 'Core.VDC_DialogState')} pops={len(trace.events)}"
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
