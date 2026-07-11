#!/usr/bin/env python3
"""Единая точка запуска регрессионных проверок Zuma Deluxe VDAC2."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "Build"


@dataclass(frozen=True)
class Step:
    name: str
    argv: tuple[str, ...]
    timeout: int
    group: str


def py(script: str, timeout: int, group: str = "test") -> Step:
    return Step(
        name=script,
        argv=(sys.executable, str(ROOT / "Source" / "OTHER" / script)),
        timeout=timeout,
        group=group,
    )


BUILD_STEP = Step(
    name="build.cmd",
    argv=("cmd", "/c", str(ROOT / "build.cmd")),
    timeout=900,
    group="build",
)


SMOKE_STEPS: tuple[Step, ...] = (
    BUILD_STEP,
    py("check_memory_map.py", 90, "static"),
    py("audit_ramg_full.py", 90, "static"),
    py("test_page3_inflate_guards.py", 60, "static"),
    py("test_score24_z80.py", 60, "logic"),
    py("test_frog_angle_div_z80.py", 180, "logic"),
    py("test_adventure_gauntlet_chains.py", 180, "flow"),
)


FULL_EXTRA_STEPS: tuple[Step, ...] = (
    py("test_menu_hover_keyboard_focus.py", 90, "menu"),
    py("test_levelsel_preview_stream_z80.py", 240, "sd"),
    py("test_levelsel_transition.py", 120, "menu"),
    py("test_win_transition_z80.py", 240, "flow"),
    py("test_gap_bonus_score_z80.py", 120, "score"),
    py("test_bullet_traj_draw_above_nohit.py", 90, "bullet"),
    py("test_bullet_traj_dual_chain_insert_z80.py", 180, "bullet"),
    py("test_dual_chain_target_z80.py", 120, "chain"),
    py("test_dual_chain_lose_absorb_z80.py", 240, "lose"),
    py("test_dual_chain_win_outro_z80.py", 240, "win"),
    py("test_lose_blocks_shots_z80.py", 120, "lose"),
    py("test_lose_waits_chain_settle_z80.py", 240, "lose"),
    py("test_audio_cache_stream.py", 120, "audio"),
    py("test_space_starfield_static.py", 90, "render"),
    py("test_top_mask_mainpak_delivery.py", 90, "render"),
)


OPTIMIZATION_GATE_STEPS: tuple[Step, ...] = (
    py("test_track_v4_packed_vertex.py", 120, "render"),
    py("test_track_baked_spin_z80.py", 120, "render"),
    py("test_level_pack_second_tracks.py", 120, "render"),
    py("test_track_v4_runtime_z80.py", 120, "render"),
    py("test_cache_builder_l19_fast_z80.py", 120, "render"),
    py("test_draw_cached_chain_fast_path_z80.py", 120, "render"),
    py("test_prepared_chain2_no_swap_z80.py", 120, "chain"),
    py("test_shadow_tunnel_pass_z80.py", 120, "render"),
    py("test_topology_cache_mutators_z80.py", 120, "chain"),
    py("test_offsets_maybe_latch_z80.py", 120, "chain"),
    py("test_insert_animation_continuity_z80.py", 120, "bullet"),
    py("test_bullet_insert_animation_full_z80.py", 120, "bullet"),
    py("test_gap_scan_selection_z80.py", 120, "chain"),
    py("test_gap_boundary_no_kz_drift_z80.py", 120, "chain"),
    py("test_dual_chain_clamp_offsets_z80.py", 120, "chain"),
    py("test_explode_active_guard_z80.py", 120, "chain"),
)


QUARANTINE_STEPS: tuple[Step, ...] = (
    py("test_win_next_level_full_load_z80.py", 240, "quarantine"),
    py("test_gap_pull_z80.py", 240, "quarantine"),
    py("test_rawpak_z80.py", 180, "quarantine"),
    py("test_rawpak_fragmented.py", 180, "quarantine"),
    py("test_rawpak_partitioned.py", 180, "quarantine"),
    py("test_tunnel_pause_dialog_skip.py", 90, "quarantine"),
    py("test_tunnel_render_pass_priority.py", 90, "quarantine"),
    py("test_tunnel_top_overlay_order.py", 90, "quarantine"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Запуск smoke/full регрессии для Zuma Deluxe VDAC2.",
    )
    parser.add_argument(
        "mode",
        nargs="?",
        default="smoke",
        choices=("smoke", "full", "list"),
        help="smoke: короткий шлюз; full: расширенная регрессия; list: показать шаги.",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Не запускать build.cmd и проверять уже собранные Build-артефакты.",
    )
    parser.add_argument(
        "--continue-on-fail",
        action="store_true",
        help="Продолжать следующие шаги после падения, итоговый код всё равно будет 1.",
    )
    parser.add_argument(
        "--include-quarantine",
        action="store_true",
        help="Добавить устаревшие/fixture-зависимые тесты. Штатный full их не запускает.",
    )
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        help="Запустить только шаги, имя которых содержит подстроку. Можно указать несколько раз.",
    )
    parser.add_argument(
        "--timeout-scale",
        type=float,
        default=1.0,
        help="Множитель таймаутов для медленного хоста.",
    )
    return parser.parse_args()


def steps_for(mode: str, skip_build: bool, include_quarantine: bool) -> list[Step]:
    steps = list(
        SMOKE_STEPS
        if mode == "smoke"
        else SMOKE_STEPS + FULL_EXTRA_STEPS + OPTIMIZATION_GATE_STEPS
    )
    if include_quarantine:
        steps.extend(QUARANTINE_STEPS)
    if skip_build:
        steps = [step for step in steps if step.group != "build"]
    return steps


def apply_only_filter(steps: list[Step], needles: list[str]) -> list[Step]:
    if not needles:
        return steps
    lowered = [needle.lower() for needle in needles]
    return [
        step
        for step in steps
        if any(needle in step.name.lower() for needle in lowered)
    ]


def command_text(step: Step) -> str:
    return " ".join(f'"{part}"' if " " in part else part for part in step.argv)


def print_step_list(steps: list[Step]) -> None:
    for index, step in enumerate(steps, 1):
        print(f"{index:02d}. [{step.group}] {step.name} ({step.timeout}s)")


def print_named_step_list(title: str, steps: list[Step]) -> None:
    print(f"{title}:")
    if steps:
        print_step_list(steps)
    else:
        print("  нет шагов")


def run_step(step: Step, log, timeout_scale: float) -> tuple[bool, float]:
    timeout = max(1, int(step.timeout * timeout_scale))
    start = time.monotonic()
    header = f"\n=== {step.name} [{step.group}], timeout={timeout}s ===\n"
    print(header, end="", flush=True)
    log.write(header)
    log.flush()

    env = os.environ.copy()
    env.setdefault("PYTHONIOENCODING", "utf-8")
    env.setdefault("PYTHONUTF8", "1")

    try:
        proc = subprocess.Popen(
            step.argv,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
        )
    except OSError as exc:
        elapsed = time.monotonic() - start
        line = f"FAIL: cannot start {command_text(step)}: {exc}\n"
        print(line, end="", flush=True)
        log.write(line)
        return False, elapsed

    timed_out = False
    try:
        assert proc.stdout is not None
        while True:
            line = proc.stdout.readline()
            if line:
                print(line, end="", flush=True)
                log.write(line)
                log.flush()
            if proc.poll() is not None:
                rest = proc.stdout.read()
                if rest:
                    print(rest, end="", flush=True)
                    log.write(rest)
                break
            if time.monotonic() - start > timeout:
                timed_out = True
                proc.kill()
                break
    finally:
        rc = proc.wait()

    elapsed = time.monotonic() - start
    if timed_out:
        footer = f"FAIL: {step.name} timeout after {elapsed:.1f}s\n"
    elif rc == 0:
        footer = f"OK: {step.name} ({elapsed:.1f}s)\n"
    else:
        footer = f"FAIL: {step.name} exit={rc} ({elapsed:.1f}s)\n"

    print(footer, end="", flush=True)
    log.write(footer)
    log.flush()
    return (not timed_out and rc == 0), elapsed


def main() -> int:
    args = parse_args()
    if args.timeout_scale <= 0:
        print("FAIL: --timeout-scale должен быть больше 0")
        return 2

    if args.mode == "list":
        smoke_steps = apply_only_filter(steps_for("smoke", args.skip_build, False), args.only)
        full_steps = apply_only_filter(steps_for("full", args.skip_build, False), args.only)
        print_named_step_list("smoke", smoke_steps)
        print()
        print_named_step_list("full", full_steps)
        if args.include_quarantine:
            print()
            quarantine_steps = apply_only_filter(list(QUARANTINE_STEPS), args.only)
            print_named_step_list("quarantine", quarantine_steps)
        return 0

    steps = steps_for(args.mode, args.skip_build, args.include_quarantine)
    steps = apply_only_filter(steps, args.only)

    if not steps:
        print("FAIL: нет шагов для запуска")
        return 2

    BUILD.mkdir(exist_ok=True)
    stamp = time.strftime("%Y%m%d_%H%M%S")
    log_path = BUILD / f"regress_{args.mode}_{stamp}.log"

    total_start = time.monotonic()
    failures: list[str] = []

    with log_path.open("w", encoding="utf-8", newline="") as log:
        log.write(f"mode={args.mode}\n")
        log.write(f"skip_build={args.skip_build}\n")
        log.write(f"root={ROOT}\n")
        log.write(f"steps={len(steps)}\n")
        print(f"regress: mode={args.mode}, steps={len(steps)}, log={log_path}")

        for index, step in enumerate(steps, 1):
            print(f"\n--- step {index}/{len(steps)}: {step.name} ---", flush=True)
            ok, _elapsed = run_step(step, log, args.timeout_scale)
            if not ok:
                failures.append(step.name)
                if not args.continue_on_fail:
                    break

        elapsed = time.monotonic() - total_start
        if failures:
            summary = (
                f"\nREGRESS FAIL: {len(failures)} failure(s) in {elapsed:.1f}s\n"
                + "\n".join(f"  - {name}" for name in failures)
                + f"\nlog: {log_path}\n"
            )
            print(summary, end="", flush=True)
            log.write(summary)
            return 1

        summary = f"\nREGRESS PASS: {args.mode} ({elapsed:.1f}s)\nlog: {log_path}\n"
        print(summary, end="", flush=True)
        log.write(summary)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
