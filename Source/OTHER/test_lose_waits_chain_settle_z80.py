#!/usr/bin/env python3
"""Глобальный барьер состояния Lose и локальная независимость двух цепочек.

До защитной границы rem=49 чужая дырка или анимация взрыва не должна
тормозить чистую цепь. На rem=49 она продвигается до rem=48; уже находящаяся
на rem<=48 цепь удерживается без обратного скачка. Общий переход
PLAY -> ABSORB разрешён только
после полного завершения работы обеих цепочек: нет GAP-marker, pending ExplodeFrame
и descending signed offset-щели. Производные флаги GapJunction, GapPosLeft и
ExplodeActive сами по себе Lose не блокируют. В уже начатом ABSORB любая
занятая цепь ставит общий барьер: обе цепи не двигаются и не поглощаются,
но их локальные GAP/explode-анимации продолжают тикать.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_z80_simulator import RETURN_MARKER, ZumaZ80Sim  # noqa: E402


CELL_SIZE = 32
HOLD_REM = 48
HOLD_CHECK_REM = HOLD_REM + 1
HEAD_OFFSETS = (-128, -32, -1, 0, 1, 31, 127)


def max_slots(sim: ZumaZ80Sim) -> int:
    return sim.sym["Core.VDC_Offsets"] - sim.sym["Core.VDC_Slots"]


def sb(sim: ZumaZ80Sim, name: str, value: int) -> None:
    sim.set_byte(sim.sym[name], value)


def sw(sim: ZumaZ80Sim, name: str, value: int) -> None:
    sim.set_byte(sim.sym[name], value & 0xFF)
    sim.set_byte(sim.sym[name] + 1, (value >> 8) & 0xFF)


def set_position_for_rem(sim: ZumaZ80Sim, rem: int) -> tuple[int, int]:
    """Поставить base-head на заданный остаток пути до exact endpoint."""
    endpoint = sim.get_word(sim.sym["Core.VDC_TrackNumSlots"]) * CELL_SIZE
    endpoint += sim.get_byte(sim.sym["Core.VDC_KzEndSub"])
    hsa, hsub = divmod(endpoint - rem, CELL_SIZE)
    sb(sim, "Core.VDC_HSA", hsa)
    sb(sim, "Core.VDC_HSub", hsub)
    return hsa, hsub


def base_rem(sim: ZumaZ80Sim) -> int:
    """Вернуть signed base-rem; offsets не входят в геометрию Lose/hold."""
    endpoint = sim.get_word(sim.sym["Core.VDC_TrackNumSlots"]) * CELL_SIZE
    endpoint += sim.get_byte(sim.sym["Core.VDC_KzEndSub"])
    head = sim.get_byte(sim.sym["Core.VDC_HSA"]) * CELL_SIZE
    head += sim.get_byte(sim.sym["Core.VDC_HSub"])
    return endpoint - head


def expected_kz_frame(rem: int) -> int:
    if rem <= 0:
        return 11
    if rem <= 128:
        return 2 + ((128 - rem) >> 4)
    return 1


def set_uniform_active_offsets(sim: ZumaZ80Sim, value: int) -> None:
    """Задать выбранной цепи uniform offset без изменения её base-rem."""
    base = sim.get_word(sim.sym["Core.VDC_pOffsets"])
    for index in range(sim.get_byte(sim.sym["Core.VDC_SlotsLen"])):
        sim.set_byte(base + index, value & 0xFF)
    sim.call(sim.sym["Core.VDC_MarkTopologyDirty"])
    if value:
        sim.call(sim.sym["Core.VDC_MarkOffsetsMaybe"])


def clear_array(sim: ZumaZ80Sim, name: str) -> None:
    base = sim.sym[name]
    for i in range(max_slots(sim)):
        sim.set_byte(base + i, 0)


def set_chain2_explode_active(sim: ZumaZ80Sim, value: int) -> None:
    off = sim.sym["Core.VDC_ExplodeActive"] - sim.sym["Core.VDC_ChainLocalStart"]
    sim.set_byte(sim.sym["Core.VDC2_ChainLocal"] + off, value)


def set_active_ordinary_offset(sim: ZumaZ80Sim) -> None:
    """Вставочный overlap: signed offsets -16, 0, 0 не создают щель."""
    sim.set_byte(sim.sym["Core.VDC_Offsets"], (-16) & 0xFF)
    sim.call(sim.sym["Core.VDC_MarkTopologyDirty"])
    sim.call(sim.sym["Core.VDC_MarkOffsetsMaybe"])


def set_chain2_ordinary_offset(sim: ZumaZ80Sim) -> None:
    """Тот же неубывающий overlap-профиль во второй цепочке."""
    sim.set_byte(sim.sym["Core.VDC2_Offsets"], (-16) & 0xFF)
    topology_addr = sim.sym["Core.VDC2_Slots"] - 1
    offsets_mask = sim.sym["Core.VDC_TOPO_OFFSETS_MAYBE"]
    sim.set_byte(topology_addr, sim.get_byte(topology_addr) | offsets_mask)


def set_active_real_offset_gap(sim: ZumaZ80Sim) -> None:
    """Реальная signed щель: left=0 > right=-16."""
    sim.set_byte(sim.sym["Core.VDC_Offsets"] + 1, (-16) & 0xFF)
    sim.call(sim.sym["Core.VDC_MarkTopologyDirty"])
    sim.call(sim.sym["Core.VDC_MarkOffsetsMaybe"])


def make_sim() -> ZumaZ80Sim:
    sim = ZumaZ80Sim()
    for name in (
        "Core.VDC_Slots",
        "Core.VDC_Offsets",
        "Core.VDC_Shot2",
        "Core.VDC_ExplodeFrame",
        "Core.VDC_ExplodeMarker",
        "Core.VDC2_Slots",
        "Core.VDC2_Offsets",
        "Core.VDC2_Shot2",
        "Core.VDC2_ExplodeFrame",
        "Core.VDC2_ExplodeMarker",
    ):
        clear_array(sim, name)

    if "Core.VDC_SelectChain1" in sim.sym:
        sim.call(sim.sym["Core.VDC_SelectChain1"])
    sb(sim, "Core.VDC_SecondActive", 0)
    sb(sim, "Core.VDC_HasSecondChain", 0)
    sb(sim, "Core.VDC_GameState", 0)
    sb(sim, "Core.VDC_DialogState", 0)
    sb(sim, "Core.VDC_ChainFreezeCnt", 0)
    sb(sim, "Core.VDC_GapJunction", 0)
    sb(sim, "Core.VDC_GapPosLeft", 0)
    if "Core.VDC_WarnPlayed" in sim.sym:
        sb(sim, "Core.VDC_WarnPlayed", 0)
    if "Core.VDC_LoseShotState" in sim.sym:
        sb(sim, "Core.VDC_LoseShotState", 0)
    if "Core.VDC_LoseHoldArmed" in sim.sym:
        sb(sim, "Core.VDC_LoseHoldArmed", 0)
    if "Core.Bullet_Active" in sim.sym:
        sb(sim, "Core.Bullet_Active", 0)
    sb(sim, "Core.VDC_GameOverTick", 0)
    sb(sim, "Core.VDC_AbsorbPopNote", 0)
    sb(sim, "Core.VDC_KzFrame", 1)
    sb(sim, "Core.VDC_LoseHoldCnt", 0)
    sb(sim, "Core.VDC_HeadAbsorbAlpha", 255)

    sw(sim, "Core.VDC_TrackNumSlots", 10)
    sb(sim, "Core.VDC_KzEndSub", 31)
    sb(sim, "Core.VDC_HSA", 10)
    sb(sim, "Core.VDC_HSub", 31)
    sb(sim, "Core.VDC_SlotsLen", 3)
    for i, color in enumerate((0, 1, 2)):
        sim.set_byte(sim.sym["Core.VDC_Slots"] + i, color)
        sim.set_byte(sim.sym["Core.VDC2_Slots"] + i, color)
    sb(sim, "Core.VDC2_SlotsLen", 3)
    return sim


def configure_active_chain(
    sim: ZumaZ80Sim,
    slots: tuple[int, ...],
    *,
    hsa: int,
    hsub: int,
    explode_index: int | None = None,
    offsets: tuple[int, ...] | None = None,
) -> None:
    """Настроить выбранную через VDC_SwapChains цепочку для полного обновления."""
    s = sim.sym
    slots_base = sim.get_word(s["Core.VDC_pSlots"])
    offsets_base = sim.get_word(s["Core.VDC_pOffsets"])
    shot2_base = sim.get_word(s["Core.VDC_pShot2"])
    frames_base = sim.get_word(s["Core.VDC_pExplodeFrame"])
    markers_base = sim.get_word(s["Core.VDC_pExplodeMarker"])
    if offsets is None:
        offsets = (0,) * len(slots)
    if len(offsets) != len(slots):
        raise AssertionError("число offsets не совпадает с числом slots")
    for index, (color, offset) in enumerate(zip(slots, offsets, strict=True)):
        sim.set_byte(slots_base + index, color)
        sim.set_byte(offsets_base + index, offset & 0xFF)
        sim.set_byte(shot2_base + index, 0)
        sim.set_byte(frames_base + index, 0)
        sim.set_byte(markers_base + index, 0)
    if explode_index is not None:
        sim.set_byte(frames_base + explode_index, 1)
        sim.set_byte(markers_base + explode_index, 0xFE)

    sb(sim, "Core.VDC_HSA", hsa)
    sb(sim, "Core.VDC_HSub", hsub)
    sb(sim, "Core.VDC_SlotsLen", len(slots))
    sb(sim, "Core.VDC_ChainFreezeCnt", 0)
    sb(sim, "Core.VDC_LoseHoldCnt", 0)
    sb(sim, "Core.VDC_GapJunction", 0)
    sb(sim, "Core.VDC_GapPosLeft", 0)
    sw(sim, "Core.VDC_GapAccum", 0)
    sb(sim, "Core.VDC_ExplodeActive", 1 if explode_index is not None else 0)
    sb(sim, "Core.VDC_KzFrame", 1)
    sb(sim, "Core.VDC_KzEndSub", 31)
    sb(sim, "Core.VDC_BallsSpawned", 255)
    sb(sim, "Core.VDC_LevelStart", 35)
    sb(sim, "Core.VDC_LevelSpeed", 100)
    sb(sim, "Core.VDC_SpeedAccum", 0)
    sw(sim, "Core.VDC_TrackNumSlots", 10)
    topology_addr = slots_base - 1
    offset_mask = s["Core.VDC_TOPO_OFFSETS_MAYBE"]
    sim.set_byte(topology_addr, sim.get_byte(topology_addr) & ~offset_mask)
    sim.call(s["Core.VDC_MarkTopologyDirty"])
    if any(offsets):
        sim.call(s["Core.VDC_MarkOffsetsMaybe"])


def setup_dual_play_barrier(
    sim: ZumaZ80Sim,
    *,
    trigger_second: bool,
    blocker: str,
) -> None:
    """Одна цепь у порога Lose, во второй — дырка либо активная анимация взрыва."""
    s = sim.sym
    clean = (0, 1, 2)
    busy_slots = (0, 0xFE, 1) if blocker == "gap" else clean
    busy_explode = 1 if blocker == "explode" else None

    sb(sim, "Core.VDC_HasSecondChain", 1)
    sb(sim, "Core.VDC_GameState", 0)
    sb(sim, "Core.VDC_SecondActive", 0)
    sim.call(s["Core.VDC_SelectChain1"])
    if trigger_second:
        configure_active_chain(
            sim,
            busy_slots,
            hsa=0,
            hsub=0,
            explode_index=busy_explode,
        )
    else:
        configure_active_chain(sim, clean, hsa=9, hsub=14)  # rem=49

    sim.call(s["Core.VDC_SwapChains"])
    if trigger_second:
        configure_active_chain(sim, clean, hsa=9, hsub=14)  # rem=49
    else:
        configure_active_chain(
            sim,
            busy_slots,
            hsa=0,
            hsub=0,
            explode_index=busy_explode,
        )
    sim.call(s["Core.VDC_SwapChains"])


def pointers_restored(sim: ZumaZ80Sim) -> bool:
    s = sim.sym
    return (
        sim.get_byte(s["Core.VDC_SecondActive"]) == 0
        and sim.get_word(s["Core.VDC_pSlots"]) == s["Core.VDC_Slots"]
        and sim.get_word(s["Core.VDC_pExplodeFrame"]) == s["Core.VDC_ExplodeFrame"]
    )


def both_chains_busy(sim: ZumaZ80Sim) -> tuple[bool, bool, bool]:
    """Вернуть занятость цепей 1 и 2 и факт восстановления после переключений."""
    s = sim.sym
    if not pointers_restored(sim):
        return True, True, False
    sim.call(s["Core.VDC_LoseChainBusy"])
    busy1 = bool(sim.cpu.f & 1)
    sim.call(s["Core.VDC_SwapChains"])
    sim.call(s["Core.VDC_LoseChainBusy"])
    busy2 = bool(sim.cpu.f & 1)
    sim.call(s["Core.VDC_SwapChains"])
    return busy1, busy2, pointers_restored(sim)


def trigger_chain_state(sim: ZumaZ80Sim, trigger_second: bool) -> tuple[int, int, int, int]:
    s = sim.sym
    if not trigger_second:
        return (
            sim.get_byte(s["Core.VDC_HSA"]),
            sim.get_byte(s["Core.VDC_HSub"]),
            sim.get_byte(s["Core.VDC_KzFrame"]),
            sim.get_byte(s["Core.VDC_LoseHoldCnt"]),
        )
    local = s["Core.VDC2_ChainLocal"]
    start = s["Core.VDC_ChainLocalStart"]
    return (
        sim.get_byte(local + (s["Core.VDC_HSA"] - start)),
        sim.get_byte(s["Core.VDC2_HSub"]),
        sim.get_byte(s["Core.VDC2_KzFrame"]),
        sim.get_byte(local + (s["Core.VDC_LoseHoldCnt"] - start)),
    )


def check_killzone(sim: ZumaZ80Sim) -> int:
    check_addr = sim.sym.get("Core.VDC_CheckKillzone", sim.sym["VDC_CheckKillzone"])
    sim.call(check_addr, max_steps=5_000_000)
    return sim.get_byte(sim.sym["Core.VDC_GameState"])


def call_observing_remove_slot(sim: ZumaZ80Sim, addr: int) -> tuple[bool, tuple[int, int] | None]:
    """Вызвать routine и снять base прямо перед входом в RemoveSlotAt."""
    cpu = sim.cpu
    remove_addr = sim.sym["Core.VDC_RemoveSlotAt"]
    sp = cpu.sp
    sim.set_byte(sp - 1, (RETURN_MARKER >> 8) & 0xFF)
    sim.set_byte(sp - 2, RETURN_MARKER & 0xFF)
    cpu.sp = (sp - 2) & 0xFFFF
    cpu.pc = addr
    cpu.set_breakpoint(remove_addr)
    cpu.set_breakpoint(RETURN_MARKER)
    steps = 0
    try:
        while cpu.pc not in (remove_addr, RETURN_MARKER):
            cpu.run()
            steps += 1
            if steps > 2_000_000:
                raise RuntimeError(f"routine #{addr:04X} не дошла до RemoveSlotAt/RET")

        hit = cpu.pc == remove_addr
        at_remove = None
        if hit:
            at_remove = (
                sim.get_byte(sim.sym["Core.VDC_HSA"]),
                sim.get_byte(sim.sym["Core.VDC_HSub"]),
            )
            cpu.clear_breakpoint(remove_addr)
            while cpu.pc != RETURN_MARKER:
                cpu.run()
                steps += 1
                if steps > 2_000_000:
                    raise RuntimeError(f"routine #{addr:04X} не вернулась после RemoveSlotAt")
        return hit, at_remove
    finally:
        cpu.clear_breakpoint(remove_addr)
        cpu.clear_breakpoint(RETURN_MARKER)


def run_signed_offset_predicate_boundary_case() -> bool:
    """Два live-slot: signed-сравнение корректно на границах всех диапазонов."""
    sim = make_sim()
    s = sim.sym
    configure_active_chain(sim, (0, 1), hsa=8, hsub=0)
    sb(sim, "Core.VDC_GapJunction", 2)
    sb(sim, "Core.VDC_GapPosLeft", 1)
    sb(sim, "Core.VDC_ExplodeActive", 1)
    sw(sim, "Core.VDC_GapAccum", 0xFFFF)
    failures: list[str] = []
    probes = (-128, -127, -65, -64, -33, -32, -1, 0, 1, 31, 32, 63, 64, 126, 127)
    for left in probes:
        sim.set_byte(s["Core.VDC_Offsets"], left & 0xFF)
        for right in probes:
            sim.set_byte(s["Core.VDC_Offsets"] + 1, right & 0xFF)
            sim.call(s["Core.VDC_LoseChainBusy"])
            actual = bool(sim.cpu.f & 1)
            expected = left > right
            if actual != expected:
                failures.append(
                    f"left={left} right={right}: "
                    f"busy={actual}, expected={expected}"
                )
                if len(failures) >= 8:
                    break
        if len(failures) >= 8:
            break
    ok = not failures
    print(
        f"{'PASS' if ok else 'FAIL'}: signed offset-gap boundary matrix "
        f"({len(probes)}x{len(probes)}, derived flags ignored)"
    )
    for failure in failures:
        print(f"  {failure}")
    return ok


def run_absorb_remove_exact_endpoint_exhaustive_case() -> bool:
    """RemoveSlotAt не вызывается на rem=1 и входит точно на base rem=0."""
    failures: list[str] = []
    for second in (False, True):
        sim = make_sim()
        s = sim.sym
        sb(sim, "Core.VDC_GameState", 1)
        if second:
            sb(sim, "Core.VDC_HasSecondChain", 1)
            sim.call(s["Core.VDC_SwapChains"])
        move_once = s["VDC_UpdateAbsorb.ua_move_once"]
        for kz_end_sub in range(32):
            endpoint = 10 * 32 + kz_end_sub
            hsa, hsub = divmod(endpoint - 2, 32)
            configure_active_chain(sim, (0, 1), hsa=hsa, hsub=hsub)
            sw(sim, "Core.VDC_TrackNumSlots", 10)
            sb(sim, "Core.VDC_KzEndSub", kz_end_sub)
            sb(sim, "Core.VDC_GameState", 1)
            sb(sim, "Core.VDC_KzFrame", 11)
            sb(sim, "Core.VDC_LoseHoldCnt", 255)
            sb(sim, "Core.VDC_HeadAbsorbAlpha", 255)

            hit_before, at_remove_before = call_observing_remove_slot(sim, move_once)
            rem_after_first = (
                (10 - sim.get_byte(s["Core.VDC_HSA"])) * 32
                + kz_end_sub
                - sim.get_byte(s["Core.VDC_HSub"])
            )
            len_after_first = sim.get_byte(s["Core.VDC_SlotsLen"])
            hit_exact, at_remove_exact = call_observing_remove_slot(sim, move_once)
            after_pop = (
                sim.get_byte(s["Core.VDC_HSA"]),
                sim.get_byte(s["Core.VDC_HSub"]),
                sim.get_byte(s["Core.VDC_SlotsLen"]),
            )
            expected_at_remove = (10, kz_end_sub)
            expected_after_pop = (9, kz_end_sub, 1)
            if not (
                not hit_before
                and at_remove_before is None
                and rem_after_first == 1
                and len_after_first == 2
                and hit_exact
                and at_remove_exact == expected_at_remove
                and after_pop == expected_after_pop
            ):
                failures.append(
                    f"chain={2 if second else 1} K={kz_end_sub}: "
                    f"before_hit={hit_before}/{at_remove_before}, rem1={rem_after_first}, "
                    f"len1={len_after_first}, exact_hit={hit_exact}/{at_remove_exact}, "
                    f"after={after_pop}/{expected_after_pop}"
                )

    ok = not failures
    print(
        f"{'PASS' if ok else 'FAIL'}: RemoveSlotAt only at exact base rem=0 "
        f"(KzEndSub=0..31, chain1/chain2)"
    )
    for failure in failures[:8]:
        print(f"  {failure}")
    return ok


def run_case(
    name: str,
    setup,
    expected_state: int,
    expected_hsub: int | None = None,
    expected_hsa: int | None = None,
    move_after_check: bool = False,
    expected_freeze: int | None = None,
    expected_hold: int | None = None,
    expected_kz: int | None = None,
) -> bool:
    sim = make_sim()
    setup(sim)
    state = check_killzone(sim)
    if move_after_check:
        sim.call(sim.sym["Core.VDC_MoveChain"], max_steps=5_000_000)
    hsa = sim.get_byte(sim.sym["Core.VDC_HSA"])
    hsub = sim.get_byte(sim.sym["Core.VDC_HSub"])
    freeze = sim.get_byte(sim.sym["Core.VDC_ChainFreezeCnt"])
    hold = sim.get_byte(sim.sym["Core.VDC_LoseHoldCnt"])
    kz = sim.get_byte(sim.sym["Core.VDC_KzFrame"])
    ok = (
        state == expected_state
        and (expected_hsub is None or hsub == expected_hsub)
        and (expected_hsa is None or hsa == expected_hsa)
        and (expected_freeze is None or freeze == expected_freeze)
        and (expected_hold is None or hold == expected_hold)
        and (expected_kz is None or kz == expected_kz)
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: {name}: "
        f"state={state}, expected={expected_state}; "
        f"hsa={hsa}, expected_hsa={expected_hsa if expected_hsa is not None else '*'}; "
        f"hsub={hsub}, expected_hsub={expected_hsub if expected_hsub is not None else '*'}"
        f"; freeze={freeze}, expected_freeze={expected_freeze if expected_freeze is not None else '*'}"
        f"; hold={hold}, expected_hold={expected_hold if expected_hold is not None else '*'}"
        f"; kz={kz}, expected_kz={expected_kz if expected_kz is not None else '*'}"
        f"{'; after MoveChain' if move_after_check else ''}"
    )
    return ok


def run_absorb_pending_explode_case() -> bool:
    """Actual ExplodeFrame держит ABSORB, но сам тикает через AnimateChain."""
    sim = make_sim()
    s = sim.sym
    sb(sim, "Core.VDC_GameState", 1)
    sb(sim, "Core.VDC_KzFrame", 11)
    sb(sim, "Core.VDC_LoseHoldCnt", 255)
    sb(sim, "Core.VDC_ExplodeActive", 1)
    sim.set_byte(s["Core.VDC_ExplodeMarker"] + 1, 0xFE)
    sim.set_byte(s["Core.VDC_ExplodeFrame"] + 1, 1)
    before_slots = list(sim.get_memory(s["Core.VDC_Slots"], 3))

    sim.call(s["Core.VDC_UpdateAllChains"], max_steps=5_000_000)

    after_slots = list(sim.get_memory(s["Core.VDC_Slots"], 3))
    frames = list(sim.get_memory(s["Core.VDC_ExplodeFrame"], 3))
    state = sim.get_byte(s["Core.VDC_GameState"])
    active = sim.get_byte(s["Core.VDC_ExplodeActive"])
    kz = sim.get_byte(s["Core.VDC_KzFrame"])
    hold = sim.get_byte(s["Core.VDC_LoseHoldCnt"])
    hsa = sim.get_byte(s["Core.VDC_HSA"])
    hsub = sim.get_byte(s["Core.VDC_HSub"])
    slots_len = sim.get_byte(s["Core.VDC_SlotsLen"])
    alpha = sim.get_byte(s["Core.VDC_HeadAbsorbAlpha"])
    ok = (
        state == 1
        and active == 1
        and kz == 11
        and hold == 255
        and hsa == 10
        and hsub == 31
        and slots_len == 3
        and alpha == 255
        and after_slots == before_slots
        and frames == [0, 2, 0]
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: absorb pending explode animates before absorb: "
        f"state={state}, active={active}, kz={kz}, hold={hold}, hsa={hsa}, hsub={hsub}, "
        f"len={slots_len}, alpha={alpha}, slots={after_slots}, frames={frames}"
    )
    return ok


def run_absorb_stale_explode_flag_case() -> bool:
    """ExplodeActive без единого frame — stale hint, а не причина стопорить ABSORB."""
    sim = make_sim()
    s = sim.sym
    sb(sim, "Core.VDC_GameState", 1)
    sb(sim, "Core.VDC_KzFrame", 11)
    sb(sim, "Core.VDC_LoseHoldCnt", 255)
    sb(sim, "Core.VDC_ExplodeActive", 1)

    sim.call(s["Core.VDC_UpdateAllChains"], max_steps=5_000_000)

    active = sim.get_byte(s["Core.VDC_ExplodeActive"])
    state = sim.get_byte(s["Core.VDC_GameState"])
    kz = sim.get_byte(s["Core.VDC_KzFrame"])
    hold = sim.get_byte(s["Core.VDC_LoseHoldCnt"])
    hsa = sim.get_byte(s["Core.VDC_HSA"])
    hsub = sim.get_byte(s["Core.VDC_HSub"])
    slots_len = sim.get_byte(s["Core.VDC_SlotsLen"])
    frames = list(sim.get_memory(s["Core.VDC_ExplodeFrame"], 3))
    alpha = sim.get_byte(s["Core.VDC_HeadAbsorbAlpha"])
    ok = (
        active == 1
        and state == 1
        and kz == 11
        and hold == 255
        and hsa == 10
        and hsub == 6
        and slots_len == 2
        and alpha == 199
        and frames == [0, 0, 0]
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: stale ExplodeActive alone does not block absorb: "
        f"state={state}, active={active}, kz={kz}, hold={hold}, "
        f"hsa={hsa}, hsub={hsub}, len={slots_len}, alpha={alpha}, frames={frames}"
    )
    return ok


def run_dual_absorb_global_gap_barrier_case(gap_in_second: bool) -> bool:
    """GAP любой цепи стопорит absorb обеих, но GAP-анимация тикает."""
    sim = make_sim()
    s = sim.sym
    sb(sim, "Core.VDC_HasSecondChain", 1)
    sb(sim, "Core.VDC_GameState", 1)
    sb(sim, "Core.VDC_SecondActive", 0)
    sim.call(s["Core.VDC_SelectChain1"])

    clean = (2, 3, 4)
    gap = (0, 0xFE, 1)
    configure_active_chain(sim, gap if not gap_in_second else clean, hsa=10, hsub=31)
    sb(sim, "Core.VDC_KzFrame", 11)
    sb(sim, "Core.VDC_LoseHoldCnt", 255)
    if not gap_in_second:
        sw(sim, "Core.VDC_GapAccum", 255)
    sim.call(s["Core.VDC_SwapChains"])
    configure_active_chain(sim, gap if gap_in_second else clean, hsa=10, hsub=23)
    sb(sim, "Core.VDC_KzFrame", 11)
    sb(sim, "Core.VDC_LoseHoldCnt", 255)
    if gap_in_second:
        sw(sim, "Core.VDC_GapAccum", 255)
    sim.call(s["Core.VDC_SwapChains"])

    before_positions = (
        sim.get_byte(s["Core.VDC_HSA"]),
        sim.get_byte(s["Core.VDC_HSub"]),
        sim.get_byte(s["Core.VDC2_ChainLocal"] + (s["Core.VDC_HSA"] - s["Core.VDC_ChainLocalStart"])),
        sim.get_byte(s["Core.VDC2_HSub"]),
    )
    sim.call(s["Core.VDC_UpdateAllChains"], max_steps=5_000_000)

    after_positions = (
        sim.get_byte(s["Core.VDC_HSA"]),
        sim.get_byte(s["Core.VDC_HSub"]),
        sim.get_byte(s["Core.VDC2_ChainLocal"] + (s["Core.VDC_HSA"] - s["Core.VDC_ChainLocalStart"])),
        sim.get_byte(s["Core.VDC2_HSub"]),
    )
    lengths = (
        sim.get_byte(s["Core.VDC_SlotsLen"]),
        sim.get_byte(s["Core.VDC2_SlotsLen"]),
    )
    expected_lengths = (3, 2) if gap_in_second else (2, 3)
    live_counts = (
        sum(
            sim.get_byte(s["Core.VDC_Slots"] + index) < s["Core.VDC_NUM_COLORS"]
            for index in range(lengths[0])
        ),
        sum(
            sim.get_byte(s["Core.VDC2_Slots"] + index) < s["Core.VDC_NUM_COLORS"]
            for index in range(lengths[1])
        ),
    )
    restored = (
        sim.get_byte(s["Core.VDC_SecondActive"]) == 0
        and sim.get_word(s["Core.VDC_pSlots"]) == s["Core.VDC_Slots"]
    )
    state = sim.get_byte(s["Core.VDC_GameState"])
    alpha = (
        sim.get_byte(s["Core.VDC_HeadAbsorbAlpha"]),
        sim.get_byte(s["Core.VDC2_HeadAbsorbAlpha"]),
    )
    ok = (
        after_positions == before_positions
        and lengths == expected_lengths
        and live_counts == (2 if not gap_in_second else 3, 2 if gap_in_second else 3)
        and alpha == (255, 255)
        and restored
        and state == 1
    )
    location = "chain2" if gap_in_second else "chain1"
    print(
        f"{'PASS' if ok else 'FAIL'}: dual ABSORB global GAP barrier {location}: "
        f"position={after_positions}/{before_positions}, len={lengths}/{expected_lengths}, "
        f"live={live_counts}, alpha={alpha}, restored={restored}, state={state}"
    )
    return ok


def run_dual_play_barrier_lifecycle_case(trigger_second: bool, blocker: str) -> bool:
    """Готовая цепь ждёт у KZ, а занятая локально доигрывает GAP/взрыв.

    Чужой global hold не должен попадать в занятую цепь. Lose
    начинается только после settle и доходит до диалога.
    """
    sim = make_sim()
    s = sim.sym
    setup_dual_play_barrier(sim, trigger_second=trigger_second, blocker=blocker)
    # После освобождения rem=48 цепь проходит 48 sample до exact endpoint.
    # В этой изолированной Lose-фикстуре запрещаем штатный spawn: тестовый RNG
    # не проходил VDC_Init, а предмет проверки здесь только GAP/Lose lifecycle.
    sb(sim, "Core.VDC_GaugeFull", 1)
    sb(sim, "Core.Bullet_Active", 1)
    sb(sim, "Core.Frog_IsFire", 1)
    sb(sim, "Core.Frog_RecoilTick", 7)
    sb(sim, "Core.VDC_Lives", 1)
    sb(sim, "Core.VDC_DualLoseMenuDelay", 0)

    blocker_second = not trigger_second
    start = s["Core.VDC_ChainLocalStart"]
    blocker_hold = (
        s["Core.VDC2_ChainLocal"] + (s["Core.VDC_LoseHoldCnt"] - start)
        if blocker_second
        else s["Core.VDC_LoseHoldCnt"]
    )
    if blocker == "explode":
        blocker_probe = (
            s["Core.VDC2_ExplodeFrame"] if blocker_second else s["Core.VDC_ExplodeFrame"]
        ) + 1
        blocker_probe_initial = 1
    else:
        blocker_probe = (
            s["Core.VDC2_ChainLocal"] + (s["Core.VDC_GapJunction"] - start)
            if blocker_second
            else s["Core.VDC_GapJunction"]
        )
        blocker_probe_initial = 0

    saw_ready_play_frame = False
    first_parked = False
    first_progress = False
    parked_pose: tuple[int, int, int] | None = None
    blocker_never_held = True
    transition_frame: int | None = None
    finish_frame: int | None = None
    failure = ""

    for frame in range(600):
        busy1_before, busy2_before, restored_before = both_chains_busy(sim)
        if not restored_before:
            failure = f"кадр {frame}: указатели цепи не восстановлены до update"
            break
        if sim.get_byte(s["Core.VDC_GameState"]) != 0:
            failure = f"кадр {frame}: state покинул PLAY до update"
            break

        sim.call(s["Core.VDC_UpdateAllChains"], max_steps=5_000_000)
        state = sim.get_byte(s["Core.VDC_GameState"])
        busy1_after, busy2_after, restored_after = both_chains_busy(sim)
        if not restored_after:
            failure = f"кадр {frame}: UpdateAllChains не восстановил выбор цепи"
            break

        blocker_busy_before = busy2_before if blocker_second else busy1_before
        if state == 0 and blocker_busy_before and sim.get_byte(blocker_hold) != 0:
            blocker_never_held = False
            failure = (
                f"кадр {frame}: занятая цепь получила чужой global hold; "
                f"LoseHoldCnt={sim.get_byte(blocker_hold)}"
            )
            break

        hsa, hsub, kz, hold = trigger_chain_state(sim, trigger_second)
        if frame == 0:
            parked_pose = (hsa, hsub, kz)
            first_parked = (
                state == 0
                and hold > 0
                and parked_pose == (9, 15, 7)
                and sim.get_byte(s["Core.Bullet_Active"]) == 1
                and sim.get_byte(s["Core.Frog_IsFire"]) == 1
                and (busy1_before or busy2_before)
            )
            first_progress = sim.get_byte(blocker_probe) != blocker_probe_initial

        if state == 1:
            transition_frame = frame
            if busy1_after or busy2_after:
                failure = (
                    f"кадр {frame}: ABSORB начат до settle; "
                    f"цепь1={busy1_after} цепь2={busy2_after}"
                )
            elif not (
                kz == 11
                and hold == 0
                and sim.get_byte(s["Core.Bullet_Active"]) == 0
                and sim.get_byte(s["Core.Frog_IsFire"]) == 0
            ):
                failure = (
                    f"кадр {frame}: неверное начало Lose: "
                    f"kz={kz} hold={hold} bullet={sim.get_byte(s['Core.Bullet_Active'])} "
                    f"fire={sim.get_byte(s['Core.Frog_IsFire'])}"
                )
            break

        if not busy1_after and not busy2_after:
            saw_ready_play_frame = True
            # После settle global hold снимается, и цепь штатно
            # доезжает до точки запуска Lose.
            continue

        if (hsa, hsub, kz) != parked_pose or hold == 0:
            failure = (
                f"кадр {frame}: ожидающая цепь сдвинулась: "
                f"hsa={hsa} hsub={hsub} kz={kz} hold={hold}"
            )
            break

    # Перехода в ABSORB недостаточно: обе цепи обязаны опустеть,
    # а state machine — дойти до GAMEOVER и Lose-диалога без цикла.
    if not failure and transition_frame is not None:
        for absorb_frame in range(1200):
            sim.call(s["Core.VDC_UpdateAllChains"], max_steps=5_000_000)
            if not pointers_restored(sim):
                failure = f"ABSORB кадр {absorb_frame}: не восстановлен выбор цепи"
                break
            state = sim.get_byte(s["Core.VDC_GameState"])
            len1 = sim.get_byte(s["Core.VDC_SlotsLen"])
            len2 = sim.get_byte(s["Core.VDC2_SlotsLen"])
            dialog = sim.get_byte(s["Core.VDC_DialogState"])
            if dialog != 0 and (len1 != 0 or len2 != 0):
                failure = (
                    f"ABSORB кадр {absorb_frame}: диалог до опустошения; "
                    f"len1={len1} len2={len2}"
                )
                break
            if state == 2:
                if len1 == 0 and len2 == 0 and dialog in (1, 2):
                    finish_frame = absorb_frame
                else:
                    failure = (
                        f"ABSORB кадр {absorb_frame}: неполный GAMEOVER; "
                        f"len1={len1} len2={len2} dialog={dialog}"
                    )
                break
        if finish_frame is None and not failure:
            failure = "ABSORB lifecycle не завершился за 1200 кадров"

    side = "цепь2" if trigger_second else "цепь1"
    ok = (
        not failure
        and first_parked
        and first_progress
        and blocker_never_held
        and transition_frame is not None
        and finish_frame is not None
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: dual PLAY-барьер {blocker}, триггер={side}: "
        f"парковка={first_parked}, локальный_прогресс={first_progress}, "
        f"чужого_hold_не_было={blocker_never_held}, "
        f"готовый_PLAY_кадр={saw_ready_play_frame}, "
        f"кадр_ABSORB={transition_frame}, кадр_финала={finish_frame}"
        + (f"; {failure}" if failure else "")
    )
    return ok


def run_terminal_park_exhaustive_case() -> bool:
    """Busy rem=49 паркуется на base-rem=48 независимо от uniform offset."""
    failures: list[str] = []
    for trigger_second in (False, True):
        sim = make_sim()
        s = sim.sym
        for kz_end_sub in range(CELL_SIZE):
            for head_offset in HEAD_OFFSETS:
                setup_dual_play_barrier(
                    sim,
                    trigger_second=trigger_second,
                    blocker="gap",
                )
                if trigger_second:
                    sim.call(s["Core.VDC_SwapChains"])
                sb(sim, "Core.VDC_GameState", 0)
                sb(sim, "Core.VDC_KzEndSub", kz_end_sub)
                set_position_for_rem(sim, HOLD_CHECK_REM)
                set_uniform_active_offsets(sim, head_offset)
                sb(sim, "Core.VDC_KzFrame", 1)
                sb(sim, "Core.VDC_LoseHoldCnt", 0)

                for _ in range(4):
                    check_killzone(sim)

                endpoint = 10 * CELL_SIZE + kz_end_sub
                expected_hsa, expected_hsub = divmod(endpoint - HOLD_REM, CELL_SIZE)
                actual = (
                    sim.get_byte(s["Core.VDC_HSA"]),
                    sim.get_byte(s["Core.VDC_HSub"]),
                    sim.get_byte(s["Core.VDC_KzFrame"]),
                    sim.get_byte(s["Core.VDC_LoseHoldCnt"]),
                    sim.get_byte(s["Core.VDC_GameState"]),
                    sim.get_byte(sim.get_word(s["Core.VDC_pOffsets"])),
                )
                expected = (
                    expected_hsa,
                    expected_hsub,
                    expected_kz_frame(HOLD_REM),
                    255,
                    0,
                    head_offset & 0xFF,
                )
                expected_active = 1 if trigger_second else 0
                expected_slots = (
                    s["Core.VDC2_Slots"] if trigger_second else s["Core.VDC_Slots"]
                )
                selection_ok = (
                    sim.get_byte(s["Core.VDC_SecondActive"]) == expected_active
                    and sim.get_word(s["Core.VDC_pSlots"]) == expected_slots
                )
                if actual != expected or not selection_ok:
                    failures.append(
                        f"chain={2 if trigger_second else 1} K={kz_end_sub} "
                        f"off={head_offset:+d}: actual={actual} expected={expected} "
                        f"selection={selection_ok}"
                    )
                if trigger_second:
                    sim.call(s["Core.VDC_SwapChains"])

    ok = not failures
    print(
        f"{'PASS' if ok else 'FAIL'}: busy rem=49 -> hold rem=48 exhaustive "
        f"(KzEndSub=0..31, uniform offsets, chain1/chain2, 4 repeated checks)"
    )
    for failure in failures[:8]:
        print(f"  {failure}")
    return ok


def run_terminal_smooth_return_exhaustive_case() -> bool:
    """Busy hold возвращает прошедшую цепь к rem=48 ровно на 1 sample/check."""
    failures: list[str] = []
    for trigger_second in (False, True):
        sim = make_sim()
        s = sim.sym
        for kz_end_sub in range(CELL_SIZE):
            for rem in (47, 32, 1, 0, -1):
                for head_offset in HEAD_OFFSETS:
                    setup_dual_play_barrier(
                        sim,
                        trigger_second=trigger_second,
                        blocker="gap",
                    )
                    if trigger_second:
                        sim.call(s["Core.VDC_SwapChains"])
                    sb(sim, "Core.VDC_GameState", 0)
                    sb(sim, "Core.VDC_KzEndSub", kz_end_sub)
                    set_position_for_rem(sim, rem)
                    set_uniform_active_offsets(sim, head_offset)
                    sb(sim, "Core.VDC_KzFrame", 99)
                    sb(sim, "Core.VDC_LoseHoldCnt", 0)

                    for _ in range(4):
                        check_killzone(sim)

                    expected_rem = min(rem + 4, HOLD_REM)
                    endpoint = 10 * CELL_SIZE + kz_end_sub
                    expected_hsa, expected_hsub = divmod(
                        endpoint - expected_rem, CELL_SIZE
                    )
                    actual = (
                        sim.get_byte(s["Core.VDC_HSA"]),
                        sim.get_byte(s["Core.VDC_HSub"]),
                        base_rem(sim),
                        sim.get_byte(s["Core.VDC_KzFrame"]),
                        sim.get_byte(s["Core.VDC_LoseHoldCnt"]),
                        sim.get_byte(s["Core.VDC_GameState"]),
                        sim.get_byte(sim.get_word(s["Core.VDC_pOffsets"])),
                    )
                    expected = (
                        expected_hsa,
                        expected_hsub,
                        expected_rem,
                        expected_kz_frame(expected_rem),
                        255,
                        0,
                        head_offset & 0xFF,
                    )
                    expected_active = 1 if trigger_second else 0
                    expected_slots = (
                        s["Core.VDC2_Slots"] if trigger_second else s["Core.VDC_Slots"]
                    )
                    selection_ok = (
                        sim.get_byte(s["Core.VDC_SecondActive"]) == expected_active
                        and sim.get_word(s["Core.VDC_pSlots"]) == expected_slots
                    )
                    if actual != expected or not selection_ok:
                        failures.append(
                        f"chain={2 if trigger_second else 1} K={kz_end_sub} "
                        f"rem={rem} off={head_offset:+d}: actual={actual} "
                            f"expected={expected} selection={selection_ok}"
                        )
                    if trigger_second:
                        sim.call(s["Core.VDC_SwapChains"])

    ok = not failures
    print(
        f"{'PASS' if ok else 'FAIL'}: busy hold returns smoothly by 1 sample/check "
        f"(4 checks, rem=47/32/1/0/-1, KzEndSub=0..31, offsets, both chains)"
    )
    for failure in failures[:8]:
        print(f"  {failure}")
    return ok


def run_terminal_smooth_return_update_speed_case() -> bool:
    """Чужой GAP: normal/fast MoveChain расходуют hold, не гасят reverse-step."""
    failures: list[str] = []
    for fast_phase, expected_hold in ((False, 253), (True, 231)):
        sim = make_sim()
        s = sim.sym
        # Цепь 1 уже проскочила точку 48, а удержание создаёт GAP в цепи 2.
        # Это воспроизводит реальный dual-chain путь через VDC_LoseAllChainsBusy.
        setup_dual_play_barrier(sim, trigger_second=False, blocker="gap")
        set_position_for_rem(sim, 26)
        sb(sim, "Core.VDC_GaugeFull", 1)  # изолированный тест не должен spawn'ить
        sb(sim, "Core.VDC_BallsSpawned", 0 if fast_phase else 255)
        sb(sim, "Core.VDC_LevelStart", 35)
        sb(sim, "Core.VDC_LevelSpeed", 100)
        sb(sim, "Core.VDC_SpeedAccum", 0)

        sim.call(s["Core.VDC_Update"], max_steps=5_000_000)

        actual = (
            base_rem(sim),
            sim.get_byte(s["Core.VDC_LoseHoldCnt"]),
            sim.get_byte(s["Core.VDC_GameState"]),
        )
        expected = (27, expected_hold, 0)
        if actual != expected:
            failures.append(
                f"phase={'fast' if fast_phase else 'normal'}: "
                f"actual={actual}, expected={expected}"
            )

    ok = not failures
    print(
        f"{'PASS' if ok else 'FAIL'}: dual-chain smooth reverse survives "
        "normal/fast movement (base 26->27; hold 255->253/231)"
    )
    for failure in failures:
        print(f"  {failure}")
    return ok


def run_terminal_smooth_return_far_closed_case() -> bool:
    """Дальний latched hold идёт к 48, но до rem=128 череп остаётся закрыт."""
    failures: list[str] = []
    # Проверяем именно post-step границу: 129->128 уже открывает frame 2,
    # а 130->129 и более дальние позиции обязаны остаться на frame 1.
    cases = (
        (129, 128, expected_kz_frame(128)),
        (130, 129, 1),
        (144, 143, 1),
        (255, 254, 1),
    )
    for trigger_second in (False, True):
        sim = make_sim()
        s = sim.sym
        for kz_end_sub in (0, CELL_SIZE - 1):
            for start_rem, expected_rem, expected_frame in cases:
                setup_dual_play_barrier(
                    sim,
                    trigger_second=trigger_second,
                    blocker="gap",
                )
                if trigger_second:
                    sim.call(s["Core.VDC_SwapChains"])
                sb(sim, "Core.VDC_GameState", 0)
                sb(sim, "Core.VDC_KzEndSub", kz_end_sub)
                set_position_for_rem(sim, start_rem)
                sb(sim, "Core.VDC_KzFrame", 99)
                sb(sim, "Core.VDC_LoseHoldCnt", 255)

                check_killzone(sim)

                actual = (
                    base_rem(sim),
                    sim.get_byte(s["Core.VDC_KzFrame"]),
                    sim.get_byte(s["Core.VDC_LoseHoldCnt"]),
                    sim.get_byte(s["Core.VDC_GameState"]),
                )
                expected = (expected_rem, expected_frame, 255, 0)
                if actual != expected:
                    failures.append(
                        f"chain={2 if trigger_second else 1} K={kz_end_sub} "
                        f"rem={start_rem}: actual={actual}, expected={expected}"
                    )
                if trigger_second:
                    sim.call(s["Core.VDC_SwapChains"])

    ok = not failures
    print(
        f"{'PASS' if ok else 'FAIL'}: far smooth hold keeps KZ closed until "
        "post-step rem<=128 (129/130/144/255, both chains)"
    )
    for failure in failures[:8]:
        print(f"  {failure}")
    return ok


def run_dual_absorb_alpha_independence_case() -> bool:
    """Alpha — per-chain progress: минус 8 за каждый фактический sample к endpoint."""

    def setup_phases(hsub1: int, hsub2: int) -> ZumaZ80Sim:
        sim = make_sim()
        s = sim.sym
        sb(sim, "Core.VDC_HasSecondChain", 1)
        sb(sim, "Core.VDC_GameState", 1)
        sb(sim, "Core.VDC_SecondActive", 0)
        sim.call(s["Core.VDC_SelectChain1"])
        configure_active_chain(sim, (0, 1, 2), hsa=10, hsub=hsub1)
        sb(sim, "Core.VDC_KzFrame", 11)
        sb(sim, "Core.VDC_LoseHoldCnt", 255)
        sim.call(s["Core.VDC_SwapChains"])
        configure_active_chain(sim, (3, 4, 5), hsa=10, hsub=hsub2)
        sb(sim, "Core.VDC_KzFrame", 11)
        sb(sim, "Core.VDC_LoseHoldCnt", 255)
        sim.call(s["Core.VDC_SwapChains"])
        return sim

    phased = setup_phases(0, 16)
    s = phased.sym
    phased.call(s["Core.VDC_UpdateAllChains"], max_steps=5_000_000)
    phased_values = (
        phased.get_byte(s["Core.VDC_HSub"]),
        phased.get_byte(s["Core.VDC2_HSub"]),
        phased.get_byte(s["Core.VDC_HeadAbsorbAlpha"]),
        phased.get_byte(s["Core.VDC2_HeadAbsorbAlpha"]),
    )
    # Обе цепи прошли ровно 8 samples: стартовый HSub не должен
    # подменять фазу прозрачности абсолютным HSub*8.
    phased_expected = (8, 24, 191, 191)
    phased.call(s["Core.VDC_SwapChains"])
    swapped_values = (
        phased.get_byte(s["Core.VDC_HeadAbsorbAlpha"]),
        phased.get_byte(s["Core.VDC2_HeadAbsorbAlpha"]),
    )
    phased.call(s["Core.VDC_SwapChains"])

    popped = setup_phases(24, 8)
    p = popped.sym
    popped.call(p["Core.VDC_UpdateAllChains"], max_steps=5_000_000)
    popped_values = (
        popped.get_byte(p["Core.VDC_HSub"]),
        popped.get_byte(p["Core.VDC_SlotsLen"]),
        popped.get_byte(p["Core.VDC_HeadAbsorbAlpha"]),
        popped.get_byte(p["Core.VDC2_HSub"]),
        popped.get_byte(p["Core.VDC2_HeadAbsorbAlpha"]),
    )
    # Chain1 дошла до endpoint за 7 samples, сменила head на opaque
    # и за оставшийся в loop sample получила alpha=247. Chain2 прошла 8 samples.
    popped_expected = (0, 2, 247, 16, 191)
    ok = (
        phased_values == phased_expected
        and swapped_values == (191, 191)
        and popped_values == popped_expected
        and pointers_restored(phased)
        and pointers_restored(popped)
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: dual absorb alpha is per-chain: "
        f"phased={phased_values}/{phased_expected}, swapped={swapped_values}, "
        f"popped={popped_values}/{popped_expected}"
    )
    return ok


def run_transition_frame_stops_play_case() -> bool:
    """После PLAY -> ABSORB запрещены движение, анимация и spawn того же кадра."""
    sim = make_sim()
    s = sim.sym
    sb(sim, "Core.VDC_BallsSpawned", 0)
    sb(sim, "Core.VDC_LevelStart", 35)
    sb(sim, "Core.VDC_GaugeFull", 0)
    before = (
        sim.get_byte(s["Core.VDC_SlotsLen"]),
        sim.get_byte(s["Core.VDC_HSA"]),
        sim.get_byte(s["Core.VDC_HSub"]),
    )

    sim.call(s["Core.VDC_Update"], max_steps=5_000_000)

    after = (
        sim.get_byte(s["Core.VDC_SlotsLen"]),
        sim.get_byte(s["Core.VDC_HSA"]),
        sim.get_byte(s["Core.VDC_HSub"]),
    )
    state = sim.get_byte(s["Core.VDC_GameState"])
    gaps = any(
        sim.get_byte(s["Core.VDC_Slots"] + index) >= s["Core.VDC_NUM_COLORS"]
        for index in range(sim.get_byte(s["Core.VDC_SlotsLen"]))
    )
    exploding = any(
        sim.get_byte(s["Core.VDC_ExplodeFrame"] + index) != 0
        for index in range(sim.get_byte(s["Core.VDC_SlotsLen"]))
    )
    ok = state == 1 and after == before and not gaps and not exploding
    print(
        f"{'PASS' if ok else 'FAIL'}: кадр входа в Lose не продолжает PLAY: "
        f"state={state}, до={before}, после={after}, gap={gaps}, explode={exploding}"
    )
    return ok


def run_dual_absorb_negative_head_offset_finishes_case() -> bool:
    """Отрицательный offset головы второй цепи не должен зациклить Lose."""
    sim = make_sim()
    s = sim.sym
    sb(sim, "Core.VDC_HasSecondChain", 1)
    sb(sim, "Core.VDC_GameState", 1)
    sb(sim, "Core.VDC_DialogState", 0)
    sb(sim, "Core.VDC_Lives", 1)
    sb(sim, "Core.VDC_DualLoseMenuDelay", 0)
    sb(sim, "Core.VDC_SlotsLen", 0)
    sb(sim, "Core.VDC_KzFrame", 0)
    sb(sim, "Core.VDC_LoseHoldCnt", 0)

    sim.call(s["Core.VDC_SwapChains"])
    configure_active_chain(sim, (0,), hsa=10, hsub=30, offsets=(-32,))
    sb(sim, "Core.VDC_KzFrame", 1)
    sb(sim, "Core.VDC_LoseHoldCnt", 0)
    sim.call(s["Core.VDC_SwapChains"])

    finish_frame: int | None = None
    for frame in range(300):
        sim.call(s["Core.VDC_UpdateAllChains"], max_steps=5_000_000)
        if sim.get_byte(s["Core.VDC_GameState"]) == 2:
            finish_frame = frame
            break

    len1 = sim.get_byte(s["Core.VDC_SlotsLen"])
    len2 = sim.get_byte(s["Core.VDC2_SlotsLen"])
    dialog = sim.get_byte(s["Core.VDC_DialogState"])
    ok = finish_frame is not None and len1 == 0 and len2 == 0 and dialog in (1, 2)
    print(
        f"{'PASS' if ok else 'FAIL'}: dual Lose с offset головы -32 завершается: "
        f"кадр={finish_frame}, len1={len1}, len2={len2}, dialog={dialog}"
    )
    return ok


def main() -> int:
    cases = [
        ("single ready starts absorb", lambda sim: None, 1),
        (
            "ready chain opens KZ frame at rem=64 inside widened window",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 31),
            ),
            0,
            31,
            8,
            False,
            None,
            0,
            6,
        ),
        (
            "ready chain clears stale hold at rem=65 inside widened window",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 30),
                sb(sim, "Core.VDC_LoseHoldCnt", 5),
            ),
            0,
            30,
            8,
            False,
            None,
            0,
            5,
        ),
        (
            "active destroy frame at rem=49 parks on rem=48",
            lambda sim: (
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            15,
            9,
            False,
            None,
            255,
            7,
        ),
        (
            "stale active ExplodeActive flag does not block absorb",
            lambda sim: sb(sim, "Core.VDC_ExplodeActive", 1),
            1,
            31,
            10,
            False,
            None,
            0,
            11,
        ),
        (
            "active internal gap marker parks rem=49 on rem=48",
            lambda sim: (
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC_Slots"] + 1, 0xFE),
            ),
            0,
            15,
            9,
            False,
            None,
            255,
            7,
        ),
        (
            "derived GapJunction without marker does not block absorb",
            lambda sim: sb(sim, "Core.VDC_GapJunction", 2),
            1,
            31,
            10,
            False,
            None,
            0,
            11,
        ),
        (
            "derived GapPosLeft without descending offsets does not block absorb",
            lambda sim: sb(sim, "Core.VDC_GapPosLeft", 1),
            1,
            31,
            10,
            False,
            None,
            0,
            11,
        ),
        (
            "derived GapAccum without marker does not block absorb",
            lambda sim: sw(sim, "Core.VDC_GapAccum", 0xFFFF),
            1,
            31,
            10,
            False,
            None,
            0,
            11,
        ),
        (
            "ordinary non-descending offset profile does not block absorb",
            set_active_ordinary_offset,
            1,
            31,
            10,
            False,
            None,
            0,
            11,
        ),
        (
            "descending signed offset profile parks rem=49 on rem=48",
            lambda sim: (
                set_position_for_rem(sim, 49),
                set_active_real_offset_gap(sim),
            ),
            0,
            15,
            9,
            False,
            None,
            255,
            7,
        ),
        (
            "active destroy frame at rem=32 returns smoothly to rem=33",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 9),
                sb(sim, "Core.VDC_HSub", 31),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            9,
            False,
            None,
            255,
            7,
        ),
        (
            "active destroy frame at rem=1 returns smoothly to rem=2",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 10),
                sb(sim, "Core.VDC_HSub", 30),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            29,
            10,
            False,
            None,
            255,
            9,
        ),
        (
            "active destroy frame at rem=50 remains free",
            lambda sim: (
                set_position_for_rem(sim, 50),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            13,
            9,
            False,
            None,
            0,
            6,
        ),
        (
            "active destroy frame at rem=49 clamps forward to rem=48",
            lambda sim: (
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            15,
            9,
            False,
            None,
            255,
            7,
        ),
        (
            "active destroy frame blocks next move at pre-KZ park",
            lambda sim: (
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            15,
            9,
            True,
            0,
            254,
            7,
        ),
        (
            "active destroy frame parks rem=49 at KzEndSub=1",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 1),
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            17,
            8,
            False,
            None,
            255,
            7,
        ),
        (
            "active destroy frame blocks next wrapped move before KZ",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 1),
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            17,
            8,
            True,
            None,
            254,
            7,
        ),
        (
            "active destroy frame parks rem=49 at KzEndSub=0",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 0),
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            16,
            8,
            False,
            None,
            255,
            7,
        ),
        (
            "dual inactive destroy frame blocks global absorb at trigger",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC2_ExplodeFrame"] + 1, 1),
            ),
            0,
            15,
            9,
            False,
            None,
            255,
            7,
        ),
        (
            "dual inactive stale ExplodeActive does not block global absorb",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                set_chain2_explode_active(sim, 1),
            ),
            1,
            31,
            10,
            False,
            None,
            0,
            11,
        ),
        (
            "dual inactive gap marker blocks global absorb at trigger",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC2_Slots"] + 1, 0xFE),
            ),
            0,
            15,
            9,
            False,
            None,
            255,
            7,
        ),
        (
            "dual inactive ordinary offset does not block global absorb",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                set_chain2_ordinary_offset(sim),
            ),
            1,
            31,
            10,
            False,
            None,
            0,
            11,
        ),
        (
            "dual global gap barrier at KzEndSub=1",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sb(sim, "Core.VDC_KzEndSub", 1),
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC2_Slots"] + 1, 0xFE),
            ),
            0,
            17,
            8,
            False,
            None,
            255,
            7,
        ),
        (
            "dual global explosion barrier at KzEndSub=0",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sb(sim, "Core.VDC_KzEndSub", 0),
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC2_ExplodeFrame"] + 1, 1),
            ),
            0,
            16,
            8,
            False,
            None,
            255,
            7,
        ),
        (
            "already-ABSORB CheckKillzone does not retrigger global PLAY barrier",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sb(sim, "Core.VDC_GameState", 1),
                sim.set_byte(sim.sym["Core.VDC2_Slots"] + 1, 0xFE),
            ),
            1,
            31,
            10,
            False,
            None,
            0,
            11,
        ),
        (
            "dual inactive destroy frame globally parks clean chain at KZ entry",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC2_ExplodeFrame"] + 1, 1),
            ),
            0,
            15,
            9,
            True,
            None,
            254,
            7,
        ),
        (
            "dual inactive gap marker globally parks clean chain at KZ entry",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                set_position_for_rem(sim, 49),
                sim.set_byte(sim.sym["Core.VDC2_Slots"] + 1, 0xFE),
            ),
            0,
            15,
            9,
            True,
            None,
            254,
            7,
        ),
        (
            "dual both ready starts absorb",
            lambda sim: sb(sim, "Core.VDC_HasSecondChain", 1),
            1,
        ),
    ]

    failures = 0
    for case in cases:
        if not run_case(*case):
            failures += 1
    if not run_absorb_pending_explode_case():
        failures += 1
    if not run_absorb_stale_explode_flag_case():
        failures += 1
    if not run_dual_absorb_global_gap_barrier_case(False):
        failures += 1
    if not run_dual_absorb_global_gap_barrier_case(True):
        failures += 1
    for blocker in ("gap", "explode"):
        for trigger_second in (False, True):
            if not run_dual_play_barrier_lifecycle_case(trigger_second, blocker):
                failures += 1
    if not run_terminal_park_exhaustive_case():
        failures += 1
    if not run_terminal_smooth_return_exhaustive_case():
        failures += 1
    if not run_terminal_smooth_return_update_speed_case():
        failures += 1
    if not run_terminal_smooth_return_far_closed_case():
        failures += 1
    if not run_signed_offset_predicate_boundary_case():
        failures += 1
    if not run_absorb_remove_exact_endpoint_exhaustive_case():
        failures += 1
    if not run_dual_absorb_alpha_independence_case():
        failures += 1
    if not run_transition_frame_stops_play_case():
        failures += 1
    if not run_dual_absorb_negative_head_offset_finishes_case():
        failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
