#!/usr/bin/env python3
"""Regression: ZBT1 hit events cover every HSub phase inside a VDC cell."""
from __future__ import annotations

import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Source" / "OTHER"))

from make_level_pack import PACK_ASSETS, scale_track_samples  # noqa: E402
from make_bullet_trajectory_tables import (  # noqa: E402
    ANGLE_COUNT,
    BULLET_HIT_THR,
    BULLET_MANHATTAN_THR,
    BULLET_SPEED,
    EV_HIT,
    EV_TUNNEL,
    EV_TUNNEL_ENTER,
    EV_TUNNEL_EXIT,
    TRACKF_TUNNEL,
    VDC_CELL_SIZE,
    coalesce_events,
    emit_hit_events_for_track,
    emit_tunnel_range_events_for_track,
    exit_distance_full_sprite,
    load_frog_positions,
    parse_old_track,
)

TRACKF_DRAW_ABOVE = 0x02


def signed_scale_div128(value: int, scale: int) -> int:
    sign = -1 if value < 0 else 1
    return sign * ((abs(value) * scale) // 128)


SIN127 = tuple(int(round(127 * math.sin(i * math.tau / ANGLE_COUNT))) for i in range(ANGLE_COUNT))


def bullet_velocity(angle: int) -> tuple[int, int]:
    vx = signed_scale_div128(SIN127[(angle + 64) & 0xFF], BULLET_SPEED)
    vy = signed_scale_div128(SIN127[angle & 0xFF], BULLET_SPEED)
    return vx, vy


def hit_distance(bullet_x: int, bullet_y: int, sample) -> int | None:
    dx = abs(bullet_x - sample.x)
    if dx >= BULLET_HIT_THR:
        return None
    dy = abs(bullet_y - sample.y)
    if dy >= BULLET_HIT_THR:
        return None
    dist = dx + dy
    if dist >= BULLET_MANHATTAN_THR:
        return None
    return dist


def degree_range_to_brads(first_deg: int, last_deg: int) -> list[int]:
    return sorted(
        {int(round(deg * ANGLE_COUNT / 360)) & 0xFF for deg in range(first_deg, last_deg + 1)}
    )


def full_scan_first_hits(samples, fx: int, fy: int, vx: int, vy: int, exit_frame: int, hsub: int):
    cells = (len(samples) + VDC_CELL_SIZE - 1) // VDC_CELL_SIZE
    cell_hits: list[tuple[int, int, int] | None] = [None] * cells
    for cell in range(cells):
        t = cell * VDC_CELL_SIZE + hsub
        if t >= len(samples):
            continue
        sample = samples[t]
        if sample.flags & TRACKF_TUNNEL:
            continue
        for frame in range(1, exit_frame):
            dist = hit_distance(fx + vx * frame, fy + vy * frame, sample)
            if dist is not None:
                cell_hits[cell] = (frame, dist, t)
                break

    best_by_hsa: list[tuple[int, int, int] | None] = []
    best: tuple[int, int, int] | None = None
    for hit in cell_hits:
        if hit is not None and (best is None or (hit[0], hit[1]) < (best[0], best[1])):
            best = hit
        best_by_hsa.append(best)
    return best_by_hsa


def zbt1_event_hits(samples, events, hsa: int, hsub: int, fx: int, fy: int, vx: int, vy: int, exit_frame: int) -> bool:
    no_hit_mask = 0
    idx = 0
    while idx < len(events):
        frame = events[idx].frame
        bullet_x = fx + vx * frame
        bullet_y = fy + vy * frame
        frame_best: int | None = None
        while idx < len(events) and events[idx].frame == frame:
            ev = events[idx]
            idx += 1
            if ev.flags & EV_TUNNEL_ENTER:
                no_hit_mask |= 1
            if ev.flags & EV_TUNNEL_EXIT:
                no_hit_mask &= ~1
            if frame <= 0 or frame >= exit_frame:
                continue
            if not (ev.flags & EV_HIT):
                continue
            if ev.flags & EV_TUNNEL:
                continue

            base = (hsa - ev.cell) & 0xFF
            if hsub >= ev.sub:
                base = (base + 1) & 0xFF

            candidates: list[int] = []
            if base >= 2:
                candidates.append((base - 2) & 0xFF)
            if base != 0:
                candidates.append((base - 1) & 0xFF)
            candidates.extend([base, (base + 1) & 0xFF, (base + 2) & 0xFF])

            for slot in candidates:
                if slot > hsa:
                    continue
                t = (hsa - slot) * VDC_CELL_SIZE + hsub
                if t < 0:
                    continue
                if t >= len(samples):
                    t = len(samples) - 1
                sample = samples[t]
                if sample.flags & TRACKF_TUNNEL:
                    continue
                if no_hit_mask and not (sample.flags & TRACKF_DRAW_ABOVE):
                    continue
                dist = hit_distance(bullet_x, bullet_y, sample)
                if dist is not None and (frame_best is None or dist < frame_best):
                    frame_best = dist
        if frame_best is not None:
            return True
    return False


def check_level(level_num: int) -> list[str]:
    fx, fy = load_frog_positions()[level_num - 1]
    raw = (PACK_ASSETS / f"track_l{level_num:02d}_640.bin").read_bytes()
    samples = parse_old_track(scale_track_samples(raw))
    cells = (len(samples) + VDC_CELL_SIZE - 1) // VDC_CELL_SIZE
    failures: list[str] = []
    full_hit_states = 0

    for angle in degree_range_to_brads(180, 270):
        rad = angle * math.tau / ANGLE_COUNT
        dx = math.cos(rad)
        dy = math.sin(rad)
        exit_s = exit_distance_full_sprite(fx, fy, dx, dy)
        exit_frame = max(1, min(255, int(round(exit_s / BULLET_SPEED))))
        vx, vy = bullet_velocity(angle)
        events = coalesce_events(
            emit_hit_events_for_track(samples, 0, fx, fy, angle, dx, dy, exit_s)
            + emit_tunnel_range_events_for_track(samples, 0, fx, fy, dx, dy, exit_s)
        )

        for hsub in range(VDC_CELL_SIZE):
            full_hits = full_scan_first_hits(samples, fx, fy, vx, vy, exit_frame, hsub)
            for hsa in range(cells):
                if full_hits[hsa] is None:
                    continue
                full_hit_states += 1
                if not zbt1_event_hits(samples, events, hsa, hsub, fx, fy, vx, vy, exit_frame):
                    frame, dist, t = full_hits[hsa]
                    failures.append(
                        f"L{level_num:02d} angle={angle} HSA={hsa} HSub={hsub} "
                        f"full_frame={frame} full_dist={dist} t={t}"
                    )
                    if len(failures) >= 12:
                        return failures

    print(f"L{level_num:02d}: checked {full_hit_states} full-scan hit states")
    return failures


def main() -> int:
    failures: list[str] = []
    for level_num in (2, 21):
        failures.extend(check_level(level_num))
    if failures:
        print("FAIL: ZBT1 missed full-scan hits:")
        for failure in failures:
            print("  " + failure)
        return 1
    print("PASS: ZBT1 cell events recall L02/L21 180..270 degree full-scan hits")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
