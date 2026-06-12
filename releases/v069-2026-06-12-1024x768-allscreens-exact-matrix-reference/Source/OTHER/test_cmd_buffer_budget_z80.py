#!/usr/bin/env python3
"""Замер пика Z80 CMD-буфера кадра (#4CB0..#5C00 = 3920 байт) на реальном коде.

Сценарии:
  A) L05 blackswirley — dual-chain, без top-mask, полное вращение (гейта нет).
  B) L13 groovefest — top-mask уровень, rotation-гейт активен (текущий код).
  C) L13 с NOP-патчем гейта — «полная анимация» на тоннельном уровне:
     воспроизводит переполнение буфера, ради которого делается midframe-flush.

Каждый сценарий: полная загрузка уровня (LoadGameplayAssets), прогрев цепей,
несколько кадров ZL_DrawFrame с замером пика BufferPtr и вотчдогом на
затирание начала Core-кода (#5C00..#5C40).

FAIL-критерии (до midframe-flush — документирующие):
  - corrupt Core в сценариях A/B (текущий код обязан жить в бюджете);
  - peak A/B > BUDGET.
Сценарий C ОЖИДАЕМО превышает бюджет — печатается требуемый размер для
проектирования flush-точек; FAIL только если C внезапно corrupt-ит Core при
peak < BUDGET (значит, модель неверна).
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from profile_dual_chain_perf import Harness  # noqa: E402
from zuma_full_z80_emulator import PAGE_SIZE  # noqa: E402

ROOT = HERE.parent.parent
LST = ROOT / "Build" / "main.lst"

# Реальная база кадрового CMD-буфера (main.asm define CMD_ADDRESS_PTR #4CB0).
# НЕ импортируем CMD из profile_dual_chain_perf — там устаревший 0x5E00.
CMD = 0x4CB0
BUDGET = 0x5C00 - CMD          # 3056: буфер упирается в Core-код
CORE_GUARD_ADDR = 0x5C00
CORE_GUARD_LEN = 0x40
WARM_FRAMES = 420
MEASURE_FRAMES = 8


def find_topmask_gate_addr() -> int:
    """Адрес 3-байтного JP NZ,.PBNoMatrix тоннельного rotation-гейта из main.lst.

    Ищем строку с "JP   NZ, .PBNoMatrix", у которой в пределах 3 строк выше
    есть "LD   A, (ZL_HasTopMaskLevel)" (отличает от других гейтов с JR).
    """
    lines = LST.read_text(encoding="utf-8", errors="replace").splitlines()
    rx = re.compile(r"^\s*\d+\+?\s+([0-9A-F]{4})\s+((?:[0-9A-F]{2}\s?)+)")
    for i, ln in enumerate(lines):
        if "JP   NZ, .PBNoMatrix" not in ln:
            continue
        ctx = "\n".join(lines[max(0, i - 5):i])
        if "ZL_HasTopMaskLevel" not in ctx:
            continue
        m = rx.match(ln)
        if not m:
            continue
        addr = int(m.group(1), 16)
        first_byte = m.group(2).split()[0]
        if first_byte != "C2":
            raise RuntimeError(f"gate at #{addr:04X}: ожидался JP NZ (C2), найден {first_byte}")
        return addr
    raise RuntimeError("тоннельный rotation-гейт (JP NZ,.PBNoMatrix) не найден в main.lst")


def patch_out_gate(h: Harness, addr: int) -> None:
    """NOP-им JP NZ (3 байта) в физической странице #04."""
    assert 0xC000 <= addr <= 0xFFFD, hex(addr)
    phys = 0x04 * PAGE_SIZE + (addr - 0xC000)
    assert h.e.mem.physical[phys] == 0xC2, f"#{addr:04X}: не C2 (уже патчено/сдвиг?)"
    h.e.mem.physical[phys:phys + 3] = b"\x00\x00\x00"


def big_call(h: Harness, name: str) -> None:
    h.e.call(h.S[name], max_steps=80_000_000)


def load_track2(h: Harness, level_n: int) -> None:
    track2 = ROOT / "Graphics" / "levels" / "Converted" / "pack" / f"track_l{level_n:02d}_2_640.bin"
    data = track2.read_bytes()
    start = 0x0F * PAGE_SIZE
    h.e.mem.physical[start:start + PAGE_SIZE] = b"\x00" * PAGE_SIZE
    h.e.mem.physical[start:start + len(data)] = data


def synth_fill_chain(h: Harness, prefix: str, length: int) -> None:
    """Набить цепь синтетическими шарами до length (после warm)."""
    for i in range(length):
        h.e.set_byte(h.S[f"Core.{prefix}Slots"] + i, i % 6)
        h.e.set_byte(h.S[f"Core.{prefix}Offsets"] + i, 0)
        h.e.set_byte(h.S[f"Core.{prefix}Shot2"] + i, 0)
        h.e.set_byte(h.S[f"Core.{prefix}ExplodeFrame"] + i, 0)
        h.e.set_byte(h.S[f"Core.{prefix}ExplodeMarker"] + i, 0)
    h.sb(f"Core.{prefix}SlotsLen", length)


def run_scenario(name: str, level_idx0: int, patch_gate: bool,
                 track2_level: int | None = None,
                 synth_len: int | None = None) -> tuple[int, bool, list[int]]:
    h = Harness(level_idx0)
    if track2_level is not None:
        load_track2(h, track2_level)
    h.setup()
    if "Core.CurrentCodePage" in h.S:
        h.sb("Core.CurrentCodePage", 0x04)
    if patch_gate:
        patch_out_gate(h, find_topmask_gate_addr())
    for _ in range(WARM_FRAMES):
        h.sb("Core.VDC_GameState", 0)
        big_call(h, "Core.VDC_UpdateAllChains")
    if synth_len is not None:
        synth_fill_chain(h, "VDC_", synth_len)
        if "Core.VDC2_Slots" in h.S:
            synth_fill_chain(h, "VDC2_", synth_len)
            h.e.set_byte(h.S["Core.VDC_HSA"], 0)  # цепь от начала трека (вмещает 120)
        h.sb("Core.VDC_HSub", 0)

    guard_before = bytes(h.e.get_memory(CORE_GUARD_ADDR, CORE_GUARD_LEN))
    peaks: list[int] = []
    for _ in range(MEASURE_FRAMES):
        h.sb("Core.VDC_GameState", 0)
        big_call(h, "Core.VDC_UpdateAllChains")
        h.sw("FT.Coprocessor.BufferPtr", CMD)
        big_call(h, "Core.ZL_DrawFrame")
        peaks.append((h.gw("FT.Coprocessor.BufferPtr") - CMD) & 0xFFFF)
    corrupt = bytes(h.e.get_memory(CORE_GUARD_ADDR, CORE_GUARD_LEN)) != guard_before

    peak = max(peaks)
    len1 = h.gb("Core.VDC_SlotsLen")
    len2 = h.gb("Core.VDC2_SlotsLen") if "Core.VDC2_SlotsLen" in h.S else 0
    print(f"{name}: peak={peak}b budget={BUDGET}b "
          f"({100 * peak // BUDGET}%) frames={peaks} len1={len1} len2={len2} "
          f"corrupt_core={corrupt}", flush=True)
    return peak, corrupt, peaks


def main() -> int:
    failures: list[str] = []

    peak_a, corrupt_a, _ = run_scenario("A L05 dual full-rotation", 4, False)
    if corrupt_a:
        failures.append("A: dual-кадр затирает Core — текущий код уже за бюджетом")
    if peak_a > BUDGET:
        failures.append(f"A: peak {peak_a} > budget {BUDGET}")

    peak_b, corrupt_b, _ = run_scenario("B L13 tunnel gated   ", 12, False)
    if corrupt_b:
        failures.append("B: tunnel-кадр с гейтом затирает Core")
    if peak_b > BUDGET:
        failures.append(f"B: peak {peak_b} > budget {BUDGET}")

    # Гейт удалён из кода (полная анимация — дефолт; вместо него двухступенчатый
    # BufferPtr-предохранитель #5800/#5B00) → сценарии C/D без патча.
    peak_c, corrupt_c, _ = run_scenario("C L13 tunnel full-anim", 12, False)
    if corrupt_c:
        failures.append("C: tunnel-кадр затирает Core")
    if peak_c > BUDGET:
        failures.append(f"C: peak {peak_c} > budget {BUDGET}")

    # D: snakepit L12 = dual + top-mask — истинный worst case полной анимации.
    peak_d, corrupt_d, _ = run_scenario("D L12 dual+tunnel full", 11, False, track2_level=12)
    if corrupt_d:
        failures.append("D: dual+tunnel кадр затирает Core")
    if peak_d > BUDGET:
        failures.append(f"D: peak {peak_d} > budget {BUDGET}")

    # E: синтетический апокалипсис — обе цепи под завязку (120+120). Проверка
    # ступеней предохранителя: Core не затёрт, буфер в бюджете (часть шаров
    # деградирует/скипается — это и есть контракт ступеней).
    peak_e, corrupt_e, _ = run_scenario("E L12 synth 120+120  ", 11, False,
                                        track2_level=12, synth_len=120)
    if corrupt_e:
        failures.append("E: предохранитель не удержал Core")
    if peak_e > BUDGET:
        failures.append(f"E: peak {peak_e} > budget {BUDGET} — ступени не сработали")

    if failures:
        print("FAIL:\n  " + "\n  ".join(failures))
        return 1
    print("PASS: бюджет CMD-буфера подтверждён; цифры для flush-точек получены")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
