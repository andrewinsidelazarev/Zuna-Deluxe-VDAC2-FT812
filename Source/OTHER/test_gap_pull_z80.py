#!/usr/bin/env python3
"""test_gap_pull_z80.py — подтяжка сегментов по референсу Zuma HD (BallChain.c).

Сценарии (полный Z80-эмулятор, прямые поки VDC-состояния):
  A. PULL: цвета по краям гэп-рана СОВПАДАЮТ → закрытие с разгоном
     (быстрее старой константы 1 слот/32 кадра), на слиянии — клик
     стыка и сброс разгона без физической отдачи.
  B. CATCH-UP: цвета РАЗНЫЕ → HSA не убывает (фронт-сегмент стоит на треке),
     зазор закрывается темпом скорости цепи.
  C. Junction-классификация: 0 без гэпов / 1 одноцветный / 2 разноцветный.
"""
import functools
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from profile_dual_chain_perf import Harness  # noqa: E402

print = functools.partial(print, flush=True)

GAP_STOP = 0xFE
CELL = 32
GAP_ACCUM_STEP = 256
MAX_VIS_STEP = 10


class Rig:
    def __init__(self):
        self.h = Harness(0)            # L01 spiral
        self.h.setup()
        for nm in ("Core.CurrentCodePage", "CurrentCodePage"):
            if nm in self.h.S:
                self.h.sb(nm, 0x04)
        self.slots = self.h.gw("Core.VDC_pSlots")
        self.offs = self.h.gw("Core.VDC_pOffsets")
        self.shot2 = self.h.gw("Core.VDC_pShot2")
        self.expl = self.h.gw("Core.VDC_pExplodeFrame")

    def build_chain(self, colors, hsa=200):
        """colors: список значений слотов (цвет 0..5 или GAP_STOP)."""
        h = self.h
        h.sb("Core.VDC_GameState", 0)
        h.sb("Core.VDC_SlotsLen", len(colors))
        h.sb("Core.VDC_HSA", hsa)              # DEFB! (следом VDC_ChainFreezeCnt)
        h.sb("Core.VDC_HSub", 0)
        h.sb("Core.VDC_ChainFreezeCnt", 0)
        h.sb("Core.VDC_GapJunction", 0)
        h.sb("Core.VDC_GapPullVp", 10)
        h.sb("Core.VDC_GaugeFull", 0)
        h.sw("Core.VDC_GaugeScore", 0)
        h.sb("Core.VDC_BallsSpawned", 0)
        h.sb("Core.VDC_LevelColors", 6)
        h.sb("Core.VDC_SpawnClusterColor", 0xFF)
        h.sb("Core.VDC_SpawnClusterRem", 0)
        h.sb("Core.VDC_ScanGapBusy", 0)
        h.sb("Core.VDC_BridgeScanActive", 0)
        h.sb("Core.VDC_RequireGapBridge", 0)
        h.sb("Core.VDC_DetectIgnoreOffsets", 0)
        h.sw("Core.VDC_GapAccum", 0)
        for i, c in enumerate(colors):
            h.e.set_byte(self.slots + i, c)
            h.e.set_byte(self.offs + i, 0)
            h.e.set_byte(self.shot2 + i, 0)
            h.e.set_byte(self.expl + i, 0)
        h.call("Core.VDC_MarkTopologyDirty", max_steps=20_000)

    def gaps(self):
        n = self.h.gb("Core.VDC_SlotsLen")
        return sum(1 for i in range(n)
                   if self.h.e.get_byte(self.slots + i) >= 6)

    def offsets(self):
        n = self.h.gb("Core.VDC_SlotsLen")
        out = []
        for i in range(n):
            v = self.h.e.get_byte(self.offs + i)
            out.append(v - 256 if v >= 128 else v)
        return out

    def frame(self):
        self.h.call("Core.VDC_AnimateChain", max_steps=2_000_000)


def main() -> int:
    rig = Rig()
    ok = True

    # --- C0: без гэпов junction = 0, аккум не копится -----------------------
    rig.build_chain([0, 1, 2, 3])
    rig.frame()
    j = rig.h.gb("Core.VDC_GapJunction")
    print(f"C0: junction без гэпов = {j} (ожид. 0)")
    ok &= j == 0

    # --- A: PULL одноцветный стык -------------------------------------------
    rig = Rig()
    # [кр(3), кр(0), кр(0), GAP×3, 0, 1, 2] — края рана цвет 0 → PULL.
    # Слот 0 (цвет 3) переживает слияние и каскадный матч нулей — метрика
    # плавности по НЕМУ (настоящий видимый шар, не взрыв и не маркер).
    rig.build_chain([3, 0, 0, GAP_STOP, GAP_STOP, GAP_STOP, 0, 1, 2])
    frames = 0
    vp_seen = []
    head_deltas = []

    def head_vis():
        off0 = rig.offsets()[0]
        return rig.h.gb("Core.VDC_HSA") * CELL + off0  # HSA = DEFB!

    prev_head = head_vis()
    while rig.gaps() > 0 and frames < 200:
        rig.frame()
        frames += 1
        vp_seen.append(rig.h.gb("Core.VDC_GapPullVp"))
        cur = head_vis()
        head_deltas.append(cur - prev_head)
        prev_head = cur
    print(f"A: PULL 3 гэп-слота закрыты за {frames} кадров "
          f"(старый темп был бы 96); vp max={max(vp_seen)}")
    ok &= rig.gaps() == 0
    ok &= frames < 60                      # с разгоном сильно быстрее 3×32
    ok &= max(vp_seen) > 10                # разгон работал
    # Плавность: голова едет назад БЕЗ рывков. Декей ≤ 10px/кадр; шаг
    # (HSA-- + comp) сам по себе нейтрален. Срезанный кампом остаток дал бы
    # разовый скачок < -12. Вперёд голова не движется вовсе.
    print(f"A: head deltas min={min(head_deltas)} max={max(head_deltas)} "
          f"(ожид. в [-12..0])")
    ok &= min(head_deltas) >= -12
    ok &= max(head_deltas) <= 0
    # Физическую отдачу отключили: звук стыка остаётся, но тыл не получает
    # отдельный микросдвиг поверх закрытия gap.
    rear_neg = any(v < 0 for v in rig.offsets())
    print(f"A: физическая отдача отключена, отрицательные offsets тыла = {rear_neg} "
          f"(ожид. False)")
    ok &= not rear_neg
    vp_after = rig.h.gb("Core.VDC_GapPullVp")
    print(f"A: vp после слияния = {vp_after} (ожид. 10 — сброс)")
    ok &= vp_after == 10

    # Доезд финальной клетки: темп удерживается после слияния (не падает в
    # 1px/кадр), остаток +32 последнего шага дотаивает за ~4 кадра плавно.
    for _ in range(8):
        rig.frame()
        cur = head_vis()
        head_deltas.append(cur - prev_head)
        prev_head = cur
    resid = max(rig.offsets()[:2] + [0])
    print(f"A: остаток комп. через 8 кадров после слияния = {resid} "
          f"(ожид. <= 16: новый стык 3|0 разноцветный → дрейф 1px/кадр); "
          f"хвостовые дельты "
          f"[{min(head_deltas[-8:])}..{max(head_deltas[-8:])}]")
    ok &= resid <= 16
    ok &= min(head_deltas[-8:]) >= -12 and max(head_deltas[-8:]) <= 0

    # --- B: CATCH-UP разноцветный стык --------------------------------------
    rig = Rig()
    rig.build_chain([0, 0, GAP_STOP, GAP_STOP, 1, 1, 2], hsa=150)
    hsa0 = rig.h.gb("Core.VDC_HSA")
    frames = 0
    while rig.gaps() > 0 and frames < 400:
        rig.frame()
        frames += 1
        j = rig.h.gb("Core.VDC_GapJunction")
        if rig.gaps() > 0 and j != 2:
            print(f"B: FAIL junction={j} на разноцветном стыке")
            ok = False
            break
    hsa1 = rig.h.gb("Core.VDC_HSA")
    # Темп догона = ТОЧНО темп цепи: speed_x100/5 x10-сэмпл/кадр (уже с
    # глобальным ×2). 2 гэп-слота = 2×GAP_ACCUM_STEP аккума.
    speed = rig.h.gb("Core.VDC_LevelSpeed")
    tempo = speed // 5
    expected = -(-2 * GAP_ACCUM_STEP // tempo)
    print(f"B: CATCH-UP 2 гэп-слота закрыты за {frames} кадров "
          f"(ожид. ~{expected} при speed={speed}); "
          f"HSA {hsa0}→{hsa1} (ожид. без изменений — фронт стоит)")
    ok &= rig.gaps() == 0
    ok &= hsa0 == hsa1                     # без HsaDec — фронт не уехал
    ok &= abs(frames - expected) <= 2      # догон ровно темпом цепи, не ×2
    # Выдача НЕ обрывается: каждый шаг догона (gaugeFull=0) доспавнивает шар у
    # жерла — 2 удаления + 2 доспавна = длина сохраняется (7), новые встык.
    final_len = rig.h.gb("Core.VDC_SlotsLen")
    print(f"B: SlotsLen после закрытия = {final_len} (ожид. 7: 2 удаления "
          f"+ 2 доспавна); offsets: {rig.offsets()}")
    ok &= final_len == 7
    ok &= all(v <= 0 for v in rig.offsets()[2:])   # хвост скользит вперёд встык

    # --- D: гэпы НА КОНЦЕ цепи (зелёная фаза) -------------------------------
    rig = Rig()
    # Спавн выключен (GaugeFull), хвостовые группы взорваны → маркеры на конце.
    # Уборка БЕЗ заморозки цепи (раньше каждый шаг стопил цепь на 32 кадра =
    # рывки в зелёной фазе) и без доспавна.
    rig.build_chain([0, 1, GAP_STOP, GAP_STOP], hsa=150)
    rig.h.sb("Core.VDC_GaugeFull", 1)
    frames = 0
    froze = False
    while rig.gaps() > 0 and frames < 400:
        rig.frame()
        frames += 1
        if rig.h.gb("Core.VDC_ChainFreezeCnt") > 0:
            froze = True
    speed = rig.h.gb("Core.VDC_LevelSpeed")
    expected = -(-2 * GAP_ACCUM_STEP // (speed // 5))
    final_len = rig.h.gb("Core.VDC_SlotsLen")
    hsa_d = rig.h.gb("Core.VDC_HSA")
    print(f"D: 2 концевых маркера убраны за {frames} кадров (ожид. ~{expected}); "
          f"freeze был={froze} (ожид. False); SlotsLen={final_len} (ожид. 2); "
          f"HSA={hsa_d} (ожид. 150)")
    ok &= rig.gaps() == 0 and not froze and final_len == 2 and hsa_d == 150
    ok &= abs(frames - expected) <= 2
    rig.h.sb("Core.VDC_GaugeFull", 0)

    # --- F: PULL не пересекает другую открытую дырку -------------------------
    rig = Rig()
    rig.build_chain([0, GAP_STOP, 0, 1, GAP_STOP, 1, 2], hsa=150)
    rig.h.sb("Core.VDC_GaugeFull", 1)
    rig.frame()
    j = rig.h.gb("Core.VDC_GapJunction")
    hsa0 = rig.h.gb("Core.VDC_HSA")
    frames = 1
    while rig.gaps() > 1 and frames < 120:
        rig.frame()
        frames += 1
    hsa1 = rig.h.gb("Core.VDC_HSA")
    print(f"F: одноцветный задний gap за передним gap: junction={j}, "
          f"HSA {hsa0}->{hsa1} после первого закрытия "
          f"(ожид. junction=2 и HSA без изменений)")
    ok &= j == 2 and hsa0 == hsa1 and rig.gaps() == 1
    rig.h.sb("Core.VDC_GaugeFull", 0)

    # --- E: НЕСКОЛЬКО гэпов одновременно (зелёная фаза) ----------------------
    rig = Rig()
    # Инвариант плавности ВСЕХ шаров: ни один не прыгает вперёд быстрее
    # оригинального предела подтяжки (>+10px/кадр) и не дёргается назад (<-12).
    # Ловит телепорт +32 дальних сегментов
    # (rear-комп обязан идти до КОНЦА цепи, не до первого маркера).
    rig.build_chain([0, 0, GAP_STOP, GAP_STOP, 1, 1, GAP_STOP, 2, 2], hsa=150)
    rig.h.sb("Core.VDC_GaugeFull", 1)

    def ball_positions():
        n = rig.h.gb("Core.VDC_SlotsLen")
        hsa = rig.h.gb("Core.VDC_HSA")
        offs = rig.offsets()
        out = []
        for i in range(n):
            if rig.h.e.get_byte(rig.slots + i) < 6:
                out.append((hsa - i) * CELL + offs[i])
        return out

    prev = ball_positions()
    worst_fwd = 0
    worst_back = 0
    frames = 0
    while frames < 600:
        rig.frame()
        frames += 1
        cur = ball_positions()
        if len(cur) == len(prev):
            for a, b in zip(prev, cur):
                d = b - a
                worst_fwd = max(worst_fwd, d)
                worst_back = min(worst_back, d)
        prev = cur
        if rig.gaps() == 0 and all(v == 0 for v in rig.offsets()):
            break
    print(f"E: мультигэп закрыт+дотаял за {frames} кадров; шаров={len(prev)} "
          f"(ожид. 6); дельты всех шаров [{worst_back}..{worst_fwd}] "
          f"(ожид. в [-12..+{MAX_VIS_STEP}])")
    ok &= rig.gaps() == 0 and len(prev) == 6
    ok &= worst_fwd <= MAX_VIS_STEP and worst_back >= -12
    rig.h.sb("Core.VDC_GaugeFull", 0)

    # --- M: матч в win-фазе (gaugeFull=1) опустошает цепь корректно ----------
    # При полной шкале спавн выключен (доспавн no-op), уничтожение последней
    # группы ДОЛЖНО довести цепь до SlotsLen=0 (изолированная тройка) или
    # убрать только тройку (с живым хвостом). Стережёт win-условие SlotsLen==0.
    def drain(colors, shot2_idx, expect, hsa=120):
        rig = Rig()
        rig.build_chain(colors, hsa=hsa)
        rig.h.e.set_byte(rig.shot2 + shot2_idx, 1)
        rig.h.call("Core.VDC_MarkShot2Maybe", max_steps=20_000)
        rig.h.sb("Core.VDC_LevelSpeed", 50)
        rig.h.sb("Core.VDC_GaugeFull", 1)       # win-фаза: спавн off, доспавн no-op
        f = 0
        while f < 400:
            rig.frame(); f += 1
            if rig.h.gb("Core.VDC_SlotsLen") == expect:
                break
        n = rig.h.gb("Core.VDC_SlotsLen")
        sl = ['%02X' % rig.h.e.get_byte(rig.slots + i) for i in range(n)]
        good = (n == expect)
        print(f"M[{colors}]: SlotsLen={n} {sl} (ожид {expect}) "
              f"{'OK' if good else 'ЗАВИС — win не наступит'}")
        rig.h.sb("Core.VDC_GaugeFull", 0)
        return good

    ok &= drain([0, 0, 0], 1, 0)            # изолированная тройка → пусто (win)
    ok &= drain([0, 0, 0, 1, 2], 1, 2)      # тройка+хвост → [1,2]
    ok &= drain([3, 0, 0, 0], 2, 1)         # шар+тройка → [3]

    print("\nPASS: подтяжка по референсу" if ok else "\nFAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
