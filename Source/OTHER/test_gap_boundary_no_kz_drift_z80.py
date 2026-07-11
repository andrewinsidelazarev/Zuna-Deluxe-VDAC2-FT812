#!/usr/bin/env python3
"""Регресс: передняя граница открытой дырки не едет к kill-zone.

Инвариант VDC: если внутри Slots[] есть живой gap вида
шар -> GAP marker(s) -> шар, marker со стороны kill-zone не должен получать
положительный сдвиг по track-t от обычного HSub++. Иначе визуальная дырка
ползёт по треку.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from zuma_z80_simulator import ZumaZ80Sim  # noqa: E402

GAP_STOP = 0xFE
CELL = 32


def signed(v: int) -> int:
    return v - 256 if v >= 128 else v


class Rig:
    def __init__(self):
        self.sim = ZumaZ80Sim()
        self.s = self.sim.sym

    def gb(self, name: str) -> int:
        return self.sim.get_byte(self.s[name])

    def sb(self, name: str, value: int) -> None:
        self.sim.set_byte(self.s[name], value & 0xFF)

    def sw(self, name: str, value: int) -> None:
        self.sim.set_byte(self.s[name], value & 0xFF)
        self.sim.set_byte(self.s[name] + 1, (value >> 8) & 0xFF)

    def setup_chain(self, chain, *, hsa=100, freeze=0, speed=50):
        z = self.sim
        s = self.s
        z.call(s["Core.VDC_Init"])
        self.sb("Core.VDC_GameState", 0)
        self.sb("Core.VDC_LevelSpeed", speed)
        self.sb("Core.VDC_LevelStart", 0)
        self.sb("Core.VDC_SpeedAccum", 0)
        self.sb("Core.VDC_BallsSpawned", 85)
        self.sb("Core.VDC_GaugeFull", 1)  # чистый тест: доспавн не вмешивается
        self.sw("Core.VDC_TrackNumSlots", 200)
        self.sb("Core.VDC_HSA", hsa)
        self.sb("Core.VDC_HSub", 0)
        self.sb("Core.VDC_SlotsLen", len(chain))
        self.sb("Core.VDC_ChainFreezeCnt", freeze)
        self.sb("Core.VDC_GapPullVp", 10)
        self.sb("Core.VDC_GapJunction", 0)
        z.set_byte(s["Core.VDC_GapAccum"], 0)
        z.set_byte(s["Core.VDC_GapAccum"] + 1, 0)
        for i, c in enumerate(chain):
            z.set_byte(s["Core.VDC_Slots"] + i, c)
            z.set_byte(s["Core.VDC_Offsets"] + i, 0)
            z.set_byte(s["Core.VDC_Shot2"] + i, 0)
            z.set_byte(s["Core.VDC_ExplodeFrame"] + i, 0)
            z.set_byte(s["Core.VDC_ExplodeMarker"] + i, 0)
        # Fixture пишет Slots напрямую, поэтому обязан инвалидировать production-кеш топологии.
        z.call(s["Core.VDC_MarkTopologyDirty"])

    def slots(self):
        n = self.gb("Core.VDC_SlotsLen")
        return [self.sim.get_byte(self.s["Core.VDC_Slots"] + i) for i in range(n)]

    def offsets(self):
        n = self.gb("Core.VDC_SlotsLen")
        return [signed(self.sim.get_byte(self.s["Core.VDC_Offsets"] + i)) for i in range(n)]

    def slot_t(self, idx: int) -> int:
        return ((self.gb("Core.VDC_HSA") - idx) * CELL
                + self.gb("Core.VDC_HSub") + self.offsets()[idx])

    def first_internal_gap_edges(self):
        slots = self.slots()
        seen_live = False
        for i, slot in enumerate(slots):
            if slot < 6:
                seen_live = True
                continue
            if not seen_live:
                continue
            if any(s < 6 for s in slots[i + 1:]):
                left = i - 1
                while left >= 0 and slots[left] >= 6:
                    left -= 1
                right = i + 1
                while right < len(slots) and slots[right] >= 6:
                    right += 1
                return left, i, right
        return None

    def first_internal_gap_boundary(self):
        edges = self.first_internal_gap_edges()
        if edges is None:
            return None
        _, marker, _ = edges
        return marker, self.slot_t(marker)

    def first_visual_gap_front_edge(self):
        """Живая граница дырки со стороны kill-zone.

        Сначала ищем marker-run внутри цепи. После удаления последнего marker'а
        визуальная дырка ещё существует как соседние живые шары с положительным
        offset у переднего сегмента: расстояние между ними больше CELL.
        """
        slots = self.slots()
        offs = self.offsets()
        edges = self.first_internal_gap_edges()
        if edges is not None:
            left, _, _ = edges
            return left, self.slot_t(left)
        for i in range(len(slots) - 1):
            if slots[i] >= 6 or slots[i + 1] >= 6:
                continue
            pixel_dist = CELL + offs[i] - offs[i + 1]
            if pixel_dist > CELL:
                return i, self.slot_t(i)
        return None

    def all_visual_gap_front_edges(self):
        slots = self.slots()
        offs = self.offsets()
        out = []
        i = 0
        while i < len(slots):
            if slots[i] < 6:
                i += 1
                continue
            left = i - 1
            while left >= 0 and slots[left] >= 6:
                left -= 1
            right = i
            while right < len(slots) and slots[right] >= 6:
                right += 1
            if left >= 0 and right < len(slots) and slots[right] < 6:
                out.append(("marker", left, self.slot_t(left)))
            i = right
        for i in range(len(slots) - 1):
            if slots[i] >= 6 or slots[i + 1] >= 6:
                continue
            pixel_dist = CELL + offs[i] - offs[i + 1]
            if pixel_dist > CELL:
                out.append(("offset", i, self.slot_t(i)))
        return out

    def gap_count(self) -> int:
        return sum(1 for slot in self.slots() if slot >= 6)

    def check_no_front_gap_kz_drift(
        self, label: str, frames: int, check_slow_backward: bool = True
    ) -> bool:
        prev = None
        prev_front = None
        prev_fronts = {}
        bad = []
        bad_front = []
        bad_any_front = []
        slow_front = []
        for frame in range(1, frames + 1):
            self.sim.call(self.s["Core.VDC_Update"])
            cur = self.first_internal_gap_boundary()
            if cur is not None and prev is not None:
                prev_i, prev_t = prev
                cur_i, cur_t = cur
                if cur_t > prev_t:
                    bad.append((frame, prev_i, cur_i, prev_t, cur_t,
                                self.gb("Core.VDC_HSA"), self.gb("Core.VDC_HSub"),
                                self.gb("Core.VDC_ChainFreezeCnt"),
                                self.gb("Core.VDC_GapJunction"),
                                self.slots(), self.offsets()))
            prev = cur
            cur_front = self.first_visual_gap_front_edge()
            if cur_front is not None and prev_front is not None:
                prev_i, prev_t = prev_front
                cur_i, cur_t = cur_front
                if cur_i == prev_i and cur_t > prev_t:
                    bad_front.append((frame, prev_i, cur_i, prev_t, cur_t,
                                      self.gb("Core.VDC_HSA"), self.gb("Core.VDC_HSub"),
                                      self.gb("Core.VDC_ChainFreezeCnt"),
                                      self.gb("Core.VDC_GapJunction"),
                                      self.slots(), self.offsets()))
                if cur_i == prev_i and cur_t < prev_t and (prev_t - cur_t) < 4:
                    slow_front.append((frame, prev_i, cur_i, prev_t, cur_t,
                                       self.gb("Core.VDC_HSA"), self.gb("Core.VDC_HSub"),
                                       self.gb("Core.VDC_ChainFreezeCnt"),
                                       self.gb("Core.VDC_GapJunction"),
                                       self.slots(), self.offsets()))
            prev_front = cur_front
            cur_fronts = {
                (kind, idx): t
                for kind, idx, t in self.all_visual_gap_front_edges()
            }
            for key, cur_t in cur_fronts.items():
                if key in prev_fronts and cur_t > prev_fronts[key]:
                    bad_any_front.append((frame, key, prev_fronts[key], cur_t,
                                          self.gb("Core.VDC_HSA"), self.gb("Core.VDC_HSub"),
                                          self.gb("Core.VDC_ChainFreezeCnt"),
                                          self.gb("Core.VDC_GapJunction"),
                                          self.slots(), self.offsets()))
                    break
            prev_fronts = cur_fronts
        if bad:
            frame, old_idx, new_idx, old_t, new_t, hsa, hsub, freeze, junction, slots, offs = bad[0]
            print(
                f"{label}: FAIL frame={frame} gap_idx={old_idx}->{new_idx} t {old_t}->{new_t} "
                f"HSA={hsa}.{hsub:02d} freeze={freeze} junction={junction} "
                f"slots={slots} offsets={offs}"
            )
            return False
        if bad_front:
            frame, old_idx, new_idx, old_t, new_t, hsa, hsub, freeze, junction, slots, offs = bad_front[0]
            print(
                f"{label}: FAIL front edge moved frame={frame} idx={old_idx}->{new_idx} "
                f"t {old_t}->{new_t} HSA={hsa}.{hsub:02d} freeze={freeze} junction={junction} "
                f"slots={slots} offsets={offs}"
            )
            return False
        if bad_any_front:
            frame, key, old_t, new_t, hsa, hsub, freeze, junction, slots, offs = bad_any_front[0]
            print(
                f"{label}: FAIL any front moved frame={frame} key={key} "
                f"t {old_t}->{new_t} HSA={hsa}.{hsub:02d} freeze={freeze} "
                f"junction={junction} slots={slots} offsets={offs}"
            )
            return False
        if check_slow_backward and slow_front:
            frame, old_idx, new_idx, old_t, new_t, hsa, hsub, freeze, junction, slots, offs = slow_front[0]
            print(
                f"{label}: FAIL slow backward pull frame={frame} idx={old_idx}->{new_idx} "
                f"t {old_t}->{new_t} HSA={hsa}.{hsub:02d} freeze={freeze} junction={junction} "
                f"slots={slots} offsets={offs}"
            )
            return False
        print(f"{label}: OK")
        return True

    def trigger_match(self, idx: int) -> None:
        self.sb("Core.VDC_TmpInsIdx", idx)
        self.sim.call(self.s["Core.VDC_CheckMatch3"])

    def insert_at(self, idx: int, color: int) -> None:
        self.sim.call(self.s["Core.VDC_InsertAt"], a=idx, b=color)


def main() -> int:
    rig = Rig()
    ok = True

    # Stale GapJunction=0 не должен разрешать обычное HSub++:
    # наличие внутренней дырки определяется по Slots[], а не по типу стыка.
    rig.setup_chain([0, GAP_STOP, 1], freeze=0, speed=100)
    rig.sb("Core.VDC_GapJunction", 0)
    hsub0 = rig.gb("Core.VDC_HSub")
    rig.sim.call(rig.s["Core.VDC_MoveChain"])
    stale_ok = rig.gb("Core.VDC_HSub") == hsub0
    print(f"stale GapJunction internal gap hold: {'OK' if stale_ok else 'FAIL'}")
    ok &= stale_ok

    # Insert поверх уже открытой внутренней дырки не должен делать обычный
    # глобальный HSA++ push. Иначе вставленный шар оставляет отрицательные
    # offset'ы на переднем сегменте; пока MoveChain удержан дыркой, эти offset'ы
    # тают и тянут дырку/передние шары к kill-zone.
    for speed in (50, 100):
        rig.setup_chain([0, GAP_STOP, 1, 2], freeze=0, speed=speed)
        before = rig.first_visual_gap_front_edge()
        hsa0 = rig.gb("Core.VDC_HSA")
        rig.insert_at(4, 5)  # без match; добавляем за открытой дыркой
        after = rig.first_visual_gap_front_edge()
        hsa_ok = rig.gb("Core.VDC_HSA") == hsa0
        edge_ok = before is not None and after is not None and after[1] <= before[1]
        print(
            f"insert over gap no global push speed={speed}: "
            f"{'OK' if hsa_ok and edge_ok else 'FAIL'} "
            f"HSA {hsa0}->{rig.gb('Core.VDC_HSA')} edge {before}->{after}"
        )
        ok &= hsa_ok and edge_ok
        ok &= rig.check_no_front_gap_kz_drift(f"post-insert gap no KZ drift speed={speed}", 80)

    # Несколько дырок: отдача от закрытия одного PULL-стыка не должна проходить
    # через следующую открытую дырку и двигать её передний край к kill-zone.
    rig.setup_chain([3, 0, GAP_STOP, 0, 1, GAP_STOP, 1, 2], freeze=0, speed=30)
    rig.insert_at(5, 5)
    ok &= rig.check_no_front_gap_kz_drift("изоляция отдачи между несколькими дырками после insert", 120)

    # После исчезновения GAP-marker'ов внутренние дырки остаются как разница
    # offset'ов соседних живых шаров. Если передний шар такой offset-дырки имеет
    # отрицательный offset, обычное таяние к нулю двигало край к kill-zone.
    rig.setup_chain([0, GAP_STOP, 1, GAP_STOP, 1], freeze=0, speed=50)
    ok &= rig.check_no_front_gap_kz_drift(
        "удержание отрицательного края offset-дырки",
        120,
        check_slow_backward=False,
    )

    # Реальный match: 15 кадров взрыва раньше съедали часть freeze, и CATCH-UP
    # успевал начать двигать передний marker к kill-zone до первого DoGapStep.
    for speed in (50, 60, 75, 80, 90, 95, 100):
        rig.setup_chain([0, 0, 1, 1, 1, 2, 2], freeze=0, speed=speed)
        rig.trigger_match(3)
        ok &= rig.check_no_front_gap_kz_drift(f"match STOP/CATCH-UP speed={speed}", 120)

    # Длинная одноцветная подтяжка: STOP marker может закрываться через PULL.
    # При большом gap freeze обязан удерживаться до последнего marker-slot.
    for speed in (50, 75, 100):
        rig.setup_chain([3, 0, 0] + [GAP_STOP] * 10 + [0, 1, 2],
                        freeze=CELL, speed=speed)
        ok &= rig.check_no_front_gap_kz_drift(f"long STOP/PULL speed={speed}", 160)

    # Хвостовые marker'ы без заднего сегмента не являются дыркой между рядами:
    # цепь должна продолжать движение без искусственного freeze.
    rig.setup_chain([0, 1, GAP_STOP, GAP_STOP], freeze=0, speed=100)
    froze = False
    moved = False
    hsub0 = rig.gb("Core.VDC_HSub")
    for _ in range(80):
        rig.sim.call(rig.s["Core.VDC_Update"])
        froze |= rig.gb("Core.VDC_ChainFreezeCnt") > 0
        moved |= rig.gb("Core.VDC_HSub") != hsub0
        if rig.gap_count() == 0:
            break
    tail_ok = (not froze and moved)
    print(f"tail cleanup no rear: {'OK' if tail_ok else 'FAIL'}")
    ok &= tail_ok

    print("\nPASS: gap boundary invariant" if ok else "\nFAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
