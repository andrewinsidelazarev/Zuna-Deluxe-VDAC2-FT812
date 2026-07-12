#!/usr/bin/env python3
"""Глобальный барьер состояния Lose и локальная независимость двух цепочек.

До фактического достижения зоны уничтожения чужая дырка или анимация взрыва
не должна тормозить чистую цепь. Но общий переход PLAY -> ABSORB разрешён только
после полного завершения работы обеих цепочек: все дырки закрыты, все кадры
разрушения и смещения завершены. Уже начатый защитный ABSORB по-прежнему
доигрывает анимацию каждой цепочки независимо.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zuma_z80_simulator import ZumaZ80Sim  # noqa: E402


def max_slots(sim: ZumaZ80Sim) -> int:
    return sim.sym["Core.VDC_Offsets"] - sim.sym["Core.VDC_Slots"]


def sb(sim: ZumaZ80Sim, name: str, value: int) -> None:
    sim.set_byte(sim.sym[name], value)


def sw(sim: ZumaZ80Sim, name: str, value: int) -> None:
    sim.set_byte(sim.sym[name], value & 0xFF)
    sim.set_byte(sim.sym[name] + 1, (value >> 8) & 0xFF)


def clear_array(sim: ZumaZ80Sim, name: str) -> None:
    base = sim.sym[name]
    for i in range(max_slots(sim)):
        sim.set_byte(base + i, 0)


def set_chain2_explode_active(sim: ZumaZ80Sim, value: int) -> None:
    off = sim.sym["Core.VDC_ExplodeActive"] - sim.sym["Core.VDC_ChainLocalStart"]
    sim.set_byte(sim.sym["Core.VDC2_ChainLocal"] + off, value)


def set_active_offset_blocker(sim: ZumaZ80Sim, index: int, value: int) -> None:
    """Создать незавершённое смещение и установить его быстрый флаг топологии."""
    sim.set_byte(sim.sym["Core.VDC_Offsets"] + index, value & 0xFF)
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
    busy_offsets = (0, 0, -16) if blocker == "offset" else None

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
            offsets=busy_offsets,
        )
    else:
        configure_active_chain(sim, clean, hsa=10, hsub=31)

    sim.call(s["Core.VDC_SwapChains"])
    if trigger_second:
        configure_active_chain(sim, clean, hsa=10, hsub=31)
    else:
        configure_active_chain(
            sim,
            busy_slots,
            hsa=0,
            hsub=0,
            explode_index=busy_explode,
            offsets=busy_offsets,
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
    ok = (
        state == 1
        and active == 1
        and kz == 1
        and hold == 25
        and hsa == 8
        and hsub == 30
        and slots_len == 3
        and after_slots == before_slots
        and frames == [0, 2, 0]
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: absorb pending explode animates before absorb: "
        f"state={state}, active={active}, kz={kz}, hold={hold}, hsa={hsa}, hsub={hsub}, "
        f"len={slots_len}, slots={after_slots}, frames={frames}"
    )
    return ok


def run_absorb_stale_explode_flag_case() -> bool:
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
    ok = (
        active == 0
        and state == 1
        and kz == 1
        and hold == 25
        and hsa == 8
        and hsub == 30
        and slots_len == 3
        and frames == [0, 0, 0]
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: absorb stale explode-active flag is cleared: "
        f"state={state}, active={active}, kz={kz}, hold={hold}, "
        f"hsa={hsa}, hsub={hsub}, len={slots_len}, frames={frames}"
    )
    return ok


def run_dual_absorb_gap_isolation_case(gap_in_second: bool) -> bool:
    """Проверить независимое обновление обеих цепочек в полном ABSORB-пути."""
    sim = make_sim()
    s = sim.sym
    sb(sim, "Core.VDC_HasSecondChain", 1)
    sb(sim, "Core.VDC_GameState", 1)
    sb(sim, "Core.VDC_SecondActive", 0)
    sim.call(s["Core.VDC_SelectChain1"])

    def configure_active(slots: tuple[int, int, int], hsub: int) -> None:
        slots_base = sim.get_word(s["Core.VDC_pSlots"])
        for index, value in enumerate(slots):
            sim.set_byte(slots_base + index, value)
        sb(sim, "Core.VDC_HSA", 0)
        sb(sim, "Core.VDC_HSub", hsub)
        sb(sim, "Core.VDC_SlotsLen", len(slots))
        sb(sim, "Core.VDC_ChainFreezeCnt", 0)
        sb(sim, "Core.VDC_LoseHoldCnt", 0)
        sb(sim, "Core.VDC_GapJunction", 0)
        sb(sim, "Core.VDC_GapPosLeft", 0)
        sb(sim, "Core.VDC_ExplodeActive", 0)
        sb(sim, "Core.VDC_KzFrame", 1)
        sb(sim, "Core.VDC_KzEndSub", 31)
        sw(sim, "Core.VDC_TrackNumSlots", 20)
        sim.call(s["Core.VDC_MarkTopologyDirty"])

    clean = (0, 1, 2)
    gap = (0, 0xFE, 1)
    configure_active(gap if not gap_in_second else clean, 3)
    sim.call(s["Core.VDC_SwapChains"])
    configure_active(gap if gap_in_second else clean, 11)
    sim.call(s["Core.VDC_SwapChains"])

    sim.call(s["Core.VDC_UpdateAllChains"], max_steps=5_000_000)

    actual = (
        sim.get_byte(s["Core.VDC_HSub"]),
        sim.get_byte(s["Core.VDC2_HSub"]),
    )
    expected = (11, 30) if gap_in_second else (30, 19)
    restored = (
        sim.get_byte(s["Core.VDC_SecondActive"]) == 0
        and sim.get_word(s["Core.VDC_pSlots"]) == s["Core.VDC_Slots"]
    )
    state = sim.get_byte(s["Core.VDC_GameState"])
    ok = actual == expected and restored and state == 1
    location = "chain2" if gap_in_second else "chain1"
    print(
        f"{'PASS' if ok else 'FAIL'}: dual ABSORB gap isolation {location}: "
        f"hsub={actual}, expected={expected}; restored={restored}; state={state}"
    )
    return ok


def run_dual_play_barrier_lifecycle_case(trigger_second: bool, blocker: str) -> bool:
    """PLAY обязан дождаться завершения всех анимаций и перейти в ABSORB один раз."""
    sim = make_sim()
    s = sim.sym
    setup_dual_play_barrier(sim, trigger_second=trigger_second, blocker=blocker)
    # Здесь проверяется только полный жизненный цикл барьера Lose. Отключаем
    # штатную выдачу новых шаров, чтобы переход HSub 31->0 после отпускания
    # rem=65 не менял состав цепочки и не примешивал генератор цветов.
    sb(sim, "Core.VDC_GaugeFull", 1)
    sb(sim, "Core.Bullet_Active", 1)
    sb(sim, "Core.Frog_IsFire", 1)
    sb(sim, "Core.Frog_RecoilTick", 7)

    blocker_second = not trigger_second
    if blocker == "explode":
        blocker_probe = (
            s["Core.VDC2_ExplodeFrame"] if blocker_second else s["Core.VDC_ExplodeFrame"]
        ) + 1
        blocker_probe_initial = 1
    elif blocker == "offset":
        blocker_probe = (
            s["Core.VDC2_Offsets"] if blocker_second else s["Core.VDC_Offsets"]
        ) + 2
        blocker_probe_initial = 0xF0
    else:
        start = s["Core.VDC_ChainLocalStart"]
        blocker_probe = (
            s["Core.VDC2_ChainLocal"] + (s["Core.VDC_GapJunction"] - start)
            if blocker_second
            else s["Core.VDC_GapJunction"]
        )
        blocker_probe_initial = 0

    saw_ready_play_frame = False
    first_parked = False
    first_progress = False
    transition_frame: int | None = None
    failure = ""

    for frame in range(600):
        busy1_before, busy2_before, restored_before = both_chains_busy(sim)
        if not restored_before:
            failure = f"frame {frame}: pointers not restored before update"
            break
        if sim.get_byte(s["Core.VDC_GameState"]) != 0:
            failure = f"frame {frame}: state left PLAY before update"
            break

        sim.call(s["Core.VDC_UpdateAllChains"], max_steps=5_000_000)
        state = sim.get_byte(s["Core.VDC_GameState"])
        busy1_after, busy2_after, restored_after = both_chains_busy(sim)
        if not restored_after:
            failure = f"frame {frame}: UpdateAllChains leaked active-chain swap"
            break

        hsa, hsub, kz, hold = trigger_chain_state(sim, trigger_second)
        if frame == 0:
            first_parked = (
                state == 0
                and hsa == 8
                and hsub == 30
                and kz == 1
                and hold > 0
                and sim.get_byte(s["Core.Bullet_Active"]) == 1
                and sim.get_byte(s["Core.Frog_IsFire"]) == 1
                and (busy1_before or busy2_before)
            )
            first_progress = sim.get_byte(blocker_probe) != blocker_probe_initial

        if state == 1:
            transition_frame = frame
            if busy1_after or busy2_after:
                failure = (
                    f"frame {frame}: ABSORB started while busy remains "
                    f"chain1={busy1_after} chain2={busy2_after}"
                )
            elif not (
                kz == 11
                and hold == 0
                and sim.get_byte(s["Core.Bullet_Active"]) == 0
                and sim.get_byte(s["Core.Frog_IsFire"]) == 0
            ):
                failure = (
                    f"frame {frame}: begin-Lose side effects wrong: "
                    f"kz={kz} hold={hold} bullet={sim.get_byte(s['Core.Bullet_Active'])} "
                    f"fire={sim.get_byte(s['Core.Frog_IsFire'])}"
                )
            break

        if not busy1_after and not busy2_after:
            saw_ready_play_frame = True
            # Завершение могло произойти после проверки triggering chain. Тогда
            # один кадр она ещё стоит на rem=65 с hold, а со следующего кадра
            # штатно проходит окно KZ к ABSORB.
            if hsa == 8 and hsub == 30 and kz == 1 and hold > 0:
                continue
            rem = (10 - hsa) * 32 + 31 - hsub
            # CheckKillzone выполняется до двух normal-speed шагов. Поэтому в
            # последнем PLAY-кадре голова может закончить уже на rem=0/-1;
            # сам переход в ABSORB штатно произойдёт в начале следующего кадра.
            if hold == 0 and -1 <= rem <= 65:
                continue

        if not (hsa == 8 and hsub == 30 and kz == 1 and hold > 0):
            failure = (
                f"frame {frame}: terminal wait drifted: "
                f"hsa={hsa} hsub={hsub} kz={kz} hold={hold}"
            )
            break

    side = "chain2" if trigger_second else "chain1"
    ok = (
        not failure
        and first_parked
        and first_progress
        and transition_frame is not None
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: dual PLAY barrier {blocker}, trigger={side}: "
        f"first_parked={first_parked}, blocker_progress={first_progress}, "
        f"ready_play_frame={saw_ready_play_frame}, transition_frame={transition_frame}"
        + (f"; {failure}" if failure else "")
    )
    return ok


def run_terminal_park_exhaustive_case() -> bool:
    """Для всех KzEndSub обе цепи должны стабильно стоять до KZ на rem=65."""
    failures: list[str] = []
    for trigger_second in (False, True):
        sim = make_sim()
        s = sim.sym
        for kz_end_sub in range(32):
            setup_dual_play_barrier(
                sim,
                trigger_second=trigger_second,
                blocker="gap",
            )
            if trigger_second:
                sim.call(s["Core.VDC_SwapChains"])
            sb(sim, "Core.VDC_GameState", 0)
            sb(sim, "Core.VDC_KzEndSub", kz_end_sub)
            sb(sim, "Core.VDC_HSA", 10)
            sb(sim, "Core.VDC_HSub", kz_end_sub)
            sb(sim, "Core.VDC_KzFrame", 1)
            sb(sim, "Core.VDC_LoseHoldCnt", 0)

            for _ in range(4):
                check_killzone(sim)

            expected_hsa = 7 if kz_end_sub == 0 else 8
            expected_hsub = 31 if kz_end_sub == 0 else kz_end_sub - 1
            actual = (
                sim.get_byte(s["Core.VDC_HSA"]),
                sim.get_byte(s["Core.VDC_HSub"]),
                sim.get_byte(s["Core.VDC_KzFrame"]),
                sim.get_byte(s["Core.VDC_LoseHoldCnt"]),
                sim.get_byte(s["Core.VDC_GameState"]),
            )
            expected = (expected_hsa, expected_hsub, 1, 25, 0)
            expected_active = 1 if trigger_second else 0
            expected_slots = s["Core.VDC2_Slots"] if trigger_second else s["Core.VDC_Slots"]
            selection_ok = (
                sim.get_byte(s["Core.VDC_SecondActive"]) == expected_active
                and sim.get_word(s["Core.VDC_pSlots"]) == expected_slots
            )
            if actual != expected or not selection_ok:
                failures.append(
                    f"chain={2 if trigger_second else 1} K={kz_end_sub}: "
                    f"actual={actual} expected={expected} selection={selection_ok}"
                )
            if trigger_second:
                sim.call(s["Core.VDC_SwapChains"])

    ok = not failures
    print(
        f"{'PASS' if ok else 'FAIL'}: pre-KZ rem=65 exhaustive "
        f"(KzEndSub=0..31, chain1/chain2, 4 repeated checks)"
    )
    for failure in failures[:8]:
        print(f"  {failure}")
    return ok


def run_dual_absorb_alpha_independence_case() -> bool:
    """Фаза прозрачности головы обязана принадлежать своей цепочке."""

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
    phased_expected = (8, 24, 191, 63)
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
    popped_expected = (0, 2, 255, 16, 127)
    ok = (
        phased_values == phased_expected
        and swapped_values == (63, 191)
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


def main() -> int:
    cases = [
        ("single ready starts absorb", lambda sim: None, 1),
        (
            "ready chain opens KZ frame at rem=64",
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
            2,
        ),
        (
            "ready chain clears stale hold at rem=65",
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
            1,
        ),
        (
            "active destroy frame blocks absorb",
            lambda sim: sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            0,
            30,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "active explode-active flag blocks absorb after gap closure",
            lambda sim: sb(sim, "Core.VDC_ExplodeActive", 1),
            0,
            30,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "active internal gap marker holds before KZ",
            lambda sim: sim.set_byte(sim.sym["Core.VDC_Slots"] + 1, 0xFE),
            0,
            30,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "active nonzero offset blocks absorb",
            lambda sim: set_active_offset_blocker(sim, 1, -16),
            0,
            30,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "active destroy frame holds current rem=32 inside KZ window",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 9),
                sb(sim, "Core.VDC_HSub", 31),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "active destroy frame holds current rem=1 inside KZ window",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 10),
                sb(sim, "Core.VDC_HSub", 30),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "active destroy frame holds at rem=66 before KZ opening",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 29),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "active destroy frame at rem=67 is not held yet",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 28),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            28,
            8,
            False,
            None,
            0,
        ),
        (
            "active destroy frame blocks next move before KZ opening",
            lambda sim: (
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 29),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            8,
            True,
            0,
            24,
            1,
        ),
        (
            "active destroy frame wraps pre-KZ hold at KzEndSub=1",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 1),
                sb(sim, "Core.VDC_HSub", 1),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            0,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "active destroy frame blocks next wrapped move before KZ",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 1),
                sb(sim, "Core.VDC_HSA", 9),
                sb(sim, "Core.VDC_HSub", 31),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            0,
            8,
            True,
            None,
            24,
            1,
        ),
        (
            "active destroy frame wraps pre-KZ hold at KzEndSub=0",
            lambda sim: (
                sb(sim, "Core.VDC_KzEndSub", 0),
                sb(sim, "Core.VDC_HSub", 0),
                sim.set_byte(sim.sym["Core.VDC_ExplodeFrame"] + 1, 1),
            ),
            0,
            31,
            7,
            False,
            None,
            25,
            1,
        ),
        (
            "dual inactive destroy frame blocks global absorb at trigger",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sim.set_byte(sim.sym["Core.VDC2_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "dual inactive explode-active flag blocks global absorb at trigger",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                set_chain2_explode_active(sim, 1),
            ),
            0,
            30,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "dual inactive gap marker blocks global absorb at trigger",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sim.set_byte(sim.sym["Core.VDC2_Slots"] + 1, 0xFE),
            ),
            0,
            30,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "dual global gap barrier at KzEndSub=1",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sb(sim, "Core.VDC_KzEndSub", 1),
                sb(sim, "Core.VDC_HSA", 10),
                sb(sim, "Core.VDC_HSub", 1),
                sim.set_byte(sim.sym["Core.VDC2_Slots"] + 1, 0xFE),
            ),
            0,
            0,
            8,
            False,
            None,
            25,
            1,
        ),
        (
            "dual global explosion barrier at KzEndSub=0",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sb(sim, "Core.VDC_KzEndSub", 0),
                sb(sim, "Core.VDC_HSA", 10),
                sb(sim, "Core.VDC_HSub", 0),
                sim.set_byte(sim.sym["Core.VDC2_ExplodeFrame"] + 1, 1),
            ),
            0,
            31,
            7,
            False,
            None,
            25,
            1,
        ),
        (
            "already-ABSORB trigger bypasses global PLAY barrier",
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
            "dual inactive destroy frame blocks clean chain at rem=66",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 29),
                sim.set_byte(sim.sym["Core.VDC2_ExplodeFrame"] + 1, 1),
            ),
            0,
            30,
            8,
            True,
            None,
            24,
            1,
        ),
        (
            "dual inactive gap marker leaves clean active movement independent",
            lambda sim: (
                sb(sim, "Core.VDC_HasSecondChain", 1),
                sb(sim, "Core.VDC_HSA", 8),
                sb(sim, "Core.VDC_HSub", 28),
                sim.set_byte(sim.sym["Core.VDC2_Slots"] + 1, 0xFE),
            ),
            0,
            29,
            8,
            True,
            None,
            0,
            1,
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
    if not run_dual_absorb_gap_isolation_case(False):
        failures += 1
    if not run_dual_absorb_gap_isolation_case(True):
        failures += 1
    for blocker in ("gap", "explode", "offset"):
        for trigger_second in (False, True):
            if not run_dual_play_barrier_lifecycle_case(trigger_second, blocker):
                failures += 1
    if not run_terminal_park_exhaustive_case():
        failures += 1
    if not run_dual_absorb_alpha_independence_case():
        failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
