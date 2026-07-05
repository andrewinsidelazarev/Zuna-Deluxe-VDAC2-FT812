#!/usr/bin/env python3
"""Build a frame-driven AY SFX page from original WAV effects.

The encoder treats AY as the actual synthesis dictionary: three tone channels
plus one shared noise generator. AY register states change only on the game
audio tick. Every source WAV is optimized independently, so the expensive work
is spread across CPU cores with multiprocessing.
"""
from __future__ import annotations

import math
import multiprocessing as mp
import os
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from make_sound_pack import SOUNDS, SRC_DIR


ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "Sounds" / "AY"
OUT_BIN = OUT_DIR / "ay_sfx_data.bin"
REPORT = OUT_DIR / "ay_sfx_report.txt"
META_INC = ROOT / "Source" / "ASM" / "ay_sfx_meta.inc"
LEGACY_INC = ROOT / "Source" / "ASM" / "ay_sfx_data.inc"

AY_UPDATE_RATE = int(os.environ.get("AY_SFX_RATE", "20"))
AY_CLOCK = 1_773_400
AY_TABLE_PAGE = 0xF4
AY_DATA_PAGE = 0xF4
AY_TABLE_ADDR = 0x8000
AY_SOUND_COUNT = len(SOUNDS)
AY_SFX_RECORD_SIZE = 4
AY_SFX_ROW_SIZE = 12
PAGE_SIZE = 0x4000
MAX_WAVE_RMS_PCT = 50.0
ALLOW_BAD_FITS = os.environ.get("AY_SFX_ALLOW_BAD", "0") == "1"
AY_OUTPUT_GAIN = float(os.environ.get("AY_SFX_GAIN", "4.0"))
AY_MIN_ACTIVE_VOLUME = int(os.environ.get("AY_SFX_MINVOL", "7"))

AY_MIXER_SILENT = 0x3F

AY_VOLUME_LEVELS = np.array(
    [
        0.0,
        0.0078125,
        0.0110485,
        0.0156250,
        0.0220971,
        0.0312500,
        0.0441942,
        0.0625000,
        0.0883883,
        0.1250000,
        0.1767767,
        0.2500000,
        0.3535534,
        0.5000000,
        0.7071068,
        1.0000000,
    ],
    dtype=np.float32,
)

PRIORITY_BY_NAME = {
    "SND_BUTTON1": 20,
    "SND_BUTTON2": 20,
    "SND_BALLCLICK1": 35,
    "SND_BALLCLICK2": 35,
    "SND_FIREBALL1": 50,
    "SND_ROLLING": 45,
    "SND_POP": 80,
    "SND_BALLSDESTROYED1": 90,
    "SND_BALLSDESTROYED2": 90,
    "SND_BALLSDESTROYED3": 90,
    "SND_BALLSDESTROYED4": 90,
    "SND_BALLSDESTROYED5": 90,
    "SND_CHIME1": 95,
    "SND_CHAIN1": 110,
    "SND_GAPBONUS1": 110,
    "SND_CHORAL1": 120,
    "SND_ENDOFLEVELPOP1": 120,
    "SND_EXTRALIFE": 130,
    "SND_EARTHQUAKE": 150,
    "SND_WARNING1": 150,
    "SND_CHANT1": 160,
    "SND_CHANT2": 160,
    "SND_CHANT8": 160,
    "SND_CHANT14": 160,
    "SND_SILENCE": 255,
}


@dataclass(frozen=True)
class Atom:
    mode: str
    period: int
    noise: int
    basis: np.ndarray


@dataclass(frozen=True)
class FrameState:
    periods: tuple[int, int, int]
    noise: int
    mixer: int
    volumes: tuple[int, int, int]


@dataclass(frozen=True)
class SoundResult:
    sound_id: int
    name: str
    priority: int
    payload: bytes
    source_seconds: float
    output_seconds: float
    rows: int
    rmse: float
    rms_pct: float
    active_rms_pct: float
    mode_counts: dict[str, int]


def clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


def read_pcm(path: Path) -> tuple[int, np.ndarray]:
    with wave.open(str(path), "rb") as wav:
        params = wav.getparams()
        if params.nchannels != 1 or params.sampwidth != 1 or params.comptype != "NONE":
            raise SystemExit(f"unsupported WAV format: {path} {params}")
        data = np.frombuffer(wav.readframes(params.nframes), dtype=np.uint8).astype(np.float32)
        return params.framerate, (data - 128.0) / 128.0


def period_from_freq(freq: float) -> int:
    if freq <= 0.0:
        return 256
    return clamp(int(round(AY_CLOCK / (16.0 * freq))), 1, 0x0FFF)


def volume_to_level(volume: int) -> float:
    return float(AY_VOLUME_LEVELS[clamp(volume, 0, 15)])


def level_to_volume(level: float) -> int:
    level = max(0.0, min(1.0, level))
    return int(np.argmin(np.abs(AY_VOLUME_LEVELS - level)))


def normalize_basis(basis: np.ndarray) -> np.ndarray:
    basis = basis.astype(np.float32, copy=False)
    basis = basis - float(np.mean(basis))
    rms = float(np.sqrt(np.mean(basis * basis)))
    if rms < 1e-8:
        return basis
    return basis / rms


def tone_basis(period: int, sample_rate: int, start: int, length: int) -> np.ndarray:
    period = clamp(period, 1, 0x0FFF)
    freq = AY_CLOCK / (16.0 * period)
    phase = ((np.arange(start, start + length, dtype=np.float32) * freq / sample_rate) % 1.0)
    return normalize_basis(np.where(phase < 0.5, 1.0, -1.0).astype(np.float32))


def noise_basis(period: int, start: int, length: int, sample_rate: int) -> np.ndarray:
    period = clamp(period, 1, 31)
    freq = AY_CLOCK / (16.0 * period)
    hold = max(1, int(round(sample_rate / max(1.0, freq))))
    skip = start // hold
    lfsr = 0x1FFFF
    for _ in range(skip):
        bit = (lfsr ^ (lfsr >> 3)) & 1
        lfsr = ((lfsr >> 1) | (bit << 16)) & 0x1FFFF
    out = np.empty(length, dtype=np.float32)
    value = 1.0
    first = start % hold
    pos = 0
    if first:
        bit = (lfsr ^ (lfsr >> 3)) & 1
        lfsr = ((lfsr >> 1) | (bit << 16)) & 0x1FFFF
        value = 1.0 if (lfsr & 1) else -1.0
        take = min(length, hold - first)
        out[:take] = value
        pos = take
    while pos < length:
        bit = (lfsr ^ (lfsr >> 3)) & 1
        lfsr = ((lfsr >> 1) | (bit << 16)) & 0x1FFFF
        value = 1.0 if (lfsr & 1) else -1.0
        out[pos : pos + hold] = value
        pos += hold
    return normalize_basis(out)


def frame_rms(chunk: np.ndarray) -> float:
    return float(np.sqrt(np.mean(chunk * chunk))) if len(chunk) else 0.0


def tone_candidates(chunk: np.ndarray, sample_rate: int, previous: tuple[int, int, int]) -> list[int]:
    if len(chunk) < 16:
        return [p for p in previous if p > 0] or [128]
    window = np.hanning(len(chunk)).astype(np.float32)
    spectrum = np.abs(np.fft.rfft((chunk - float(np.mean(chunk))) * window))
    freqs = np.fft.rfftfreq(len(chunk), 1.0 / sample_rate)
    mask = (freqs >= 70.0) & (freqs <= min(5200.0, sample_rate * 0.46))
    periods: set[int] = set()
    if np.any(mask):
        idx = np.where(mask)[0]
        count = min(12, idx.size)
        top = idx[np.argpartition(spectrum[idx], -count)[-count:]]
        for i in top:
            freq = float(freqs[i])
            for divisor in (1.0, 3.0, 5.0):
                p = period_from_freq(freq / divisor)
                for delta in (-8, -4, -2, -1, 0, 1, 2, 4, 8):
                    periods.add(clamp(p + delta, 1, 0x0FFF))
    for p in previous:
        if p > 0:
            for delta in (-16, -8, -4, -2, -1, 0, 1, 2, 4, 8, 16):
                periods.add(clamp(p + delta, 1, 0x0FFF))
    if not periods:
        periods.add(128)
    return sorted(periods)


def noise_candidates(chunk: np.ndarray, sample_rate: int) -> list[int]:
    values = {1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 31}
    if len(chunk) >= 16:
        centered = chunk - float(np.mean(chunk))
        zcr = np.count_nonzero(np.diff(np.signbit(centered))) / max(1, len(centered) - 1)
        freq = max(80.0, min(5000.0, zcr * sample_rate * 0.5))
        p = clamp(period_from_freq(freq), 1, 31)
        for delta in (-4, -2, -1, 0, 1, 2, 4):
            values.add(clamp(p + delta, 1, 31))
    return sorted(values)


def solve_nonnegative(atoms: list[Atom], target: np.ndarray, max_atoms: int = 3) -> tuple[list[Atom], np.ndarray]:
    if not atoms:
        return [], np.zeros(0, dtype=np.float32)
    residual = target.astype(np.float32, copy=True)
    selected: list[int] = []
    for _ in range(max_atoms):
        best_idx = -1
        best_score = 0.0
        for idx, atom in enumerate(atoms):
            if idx in selected:
                continue
            score = float(np.dot(residual, atom.basis))
            if score > best_score:
                best_score = score
                best_idx = idx
        if best_idx < 0:
            break
        selected.append(best_idx)
        matrix = np.stack([atoms[i].basis for i in selected], axis=1)
        coef, *_ = np.linalg.lstsq(matrix, target, rcond=None)
        coef = np.maximum(coef, 0.0)
        residual = target - matrix @ coef
    if not selected:
        return [], np.zeros(0, dtype=np.float32)
    matrix = np.stack([atoms[i].basis for i in selected], axis=1)
    coef, *_ = np.linalg.lstsq(matrix, target, rcond=None)
    coef = np.maximum(coef, 0.0)
    keep = [i for i, c in zip(selected, coef) if c > 0.002]
    coef = np.array([c for c in coef if c > 0.002], dtype=np.float32)
    return [atoms[i] for i in keep], coef


def mixer_for_modes(modes: list[str]) -> int:
    mixer = 0
    for channel, mode in enumerate(modes):
        tone_disabled = mode not in ("tone", "both")
        noise_disabled = mode not in ("noise", "both")
        if tone_disabled:
            mixer |= 1 << channel
        if noise_disabled:
            mixer |= 1 << (channel + 3)
    return mixer & 0x3F


def fit_frame(
    source: np.ndarray,
    sample_rate: int,
    start: int,
    end: int,
    previous_periods: tuple[int, int, int],
) -> tuple[FrameState, np.ndarray, dict[str, int]]:
    chunk = source[start:end].astype(np.float32, copy=False)
    target = chunk - float(np.mean(chunk))
    target_rms = frame_rms(target)
    length = len(target)
    if length == 0 or target_rms < 0.004:
        state = FrameState((1, 1, 1), 16, AY_MIXER_SILENT, (0, 0, 0))
        return state, np.zeros(length, dtype=np.float32), {"sil": 1}

    periods = tone_candidates(target, sample_rate, previous_periods)
    noises = noise_candidates(target, sample_rate)
    best_error = float("inf")
    best_state: FrameState | None = None
    best_recon = np.zeros(length, dtype=np.float32)
    best_modes: dict[str, int] = {}

    for noise_period in noises:
        noise = noise_basis(noise_period, start, length, sample_rate)
        atoms: list[Atom] = [Atom("noise", 1, noise_period, noise)]
        for period in periods:
            tone = tone_basis(period, sample_rate, start, length)
            atoms.append(Atom("tone", period, noise_period, tone))
            both = normalize_basis(np.where((tone > 0) & (noise > 0), 1.0, -1.0).astype(np.float32))
            atoms.append(Atom("both", period, noise_period, both))

        selected, coef = solve_nonnegative(atoms, target, 3)
        if not selected:
            continue
        quant = np.array([volume_to_level(level_to_volume(float(c))) for c in coef], dtype=np.float32)
        recon = np.zeros(length, dtype=np.float32)
        periods_out = [1, 1, 1]
        volumes_out = [0, 0, 0]
        modes_out: list[str] = []
        mode_counts: dict[str, int] = {}
        for channel, (atom, level) in enumerate(zip(selected[:3], quant[:3])):
            volume = level_to_volume(float(level) * AY_OUTPUT_GAIN)
            if 0 < volume < AY_MIN_ACTIVE_VOLUME:
                volume = AY_MIN_ACTIVE_VOLUME
            if volume == 0:
                mode = "sil"
            else:
                mode = atom.mode
                recon += volume_to_level(volume) * atom.basis
            periods_out[channel] = atom.period if atom.mode != "noise" else (previous_periods[channel] or 1)
            volumes_out[channel] = volume
            modes_out.append(mode)
            mode_counts[mode] = mode_counts.get(mode, 0) + 1
        while len(modes_out) < 3:
            modes_out.append("sil")
            mode_counts["sil"] = mode_counts.get("sil", 0) + 1
        error = float(np.sqrt(np.mean((target - recon) ** 2)))
        if error < best_error:
            best_error = error
            best_state = FrameState(
                tuple(clamp(p, 1, 0x0FFF) for p in periods_out),
                noise_period,
                mixer_for_modes(modes_out),
                tuple(clamp(v, 0, 15) for v in volumes_out),
            )
            best_recon = recon
            best_modes = mode_counts

    if best_state is None:
        state = FrameState((1, 1, 1), 16, AY_MIXER_SILENT, (0, 0, 0))
        return state, np.zeros(length, dtype=np.float32), {"sil": 1}
    return best_state, best_recon, best_modes


def state_to_row(count: int, state: FrameState) -> bytes:
    pa, pb, pc = state.periods
    va, vb, vc = state.volumes
    return bytes(
        [
            count,
            pa & 0xFF,
            (pa >> 8) & 0x0F,
            pb & 0xFF,
            (pb >> 8) & 0x0F,
            pc & 0xFF,
            (pc >> 8) & 0x0F,
            state.noise & 0x1F,
            state.mixer & 0x3F,
            va & 0x0F,
            vb & 0x0F,
            vc & 0x0F,
        ]
    )


def encode_sound(sound_id: int, name: str, filename: str) -> SoundResult | None:
    if name == "SND_SILENCE":
        return None
    sample_rate, pcm = read_pcm(SRC_DIR / filename)
    source_seconds = len(pcm) / sample_rate
    frame_count = max(1, int(round(source_seconds * AY_UPDATE_RATE)))
    recon = np.zeros(len(pcm), dtype=np.float32)
    states: list[FrameState] = []
    previous = (1, 1, 1)
    mode_counts: dict[str, int] = {}

    for frame in range(frame_count):
        start = int(round(frame * sample_rate / AY_UPDATE_RATE))
        end = min(len(pcm), int(round((frame + 1) * sample_rate / AY_UPDATE_RATE)))
        if end <= start:
            end = min(len(pcm), start + 1)
        state, frame_recon, modes = fit_frame(pcm, sample_rate, start, end, previous)
        states.append(state)
        previous = state.periods
        recon[start:end] = frame_recon[: end - start]
        for mode, count in modes.items():
            mode_counts[mode] = mode_counts.get(mode, 0) + count

    rows = bytearray()
    row_count = 0
    last: FrameState | None = None
    run = 0
    for state in states:
        if last is not None and state == last and run < 255:
            run += 1
            continue
        if last is not None:
            rows.extend(state_to_row(run, last))
            row_count += 1
        last = state
        run = 1
    if last is not None:
        rows.extend(state_to_row(run, last))
        row_count += 1
    rows.append(0)

    centered = pcm - float(np.mean(pcm))
    rmse = float(np.sqrt(np.mean((centered - recon) ** 2)))
    source_rms = frame_rms(centered)
    rms_pct = 100.0 * rmse / max(source_rms, 1e-9)
    frame_rms_values = []
    frame_err_values = []
    for frame in range(frame_count):
        start = int(round(frame * sample_rate / AY_UPDATE_RATE))
        end = min(len(pcm), int(round((frame + 1) * sample_rate / AY_UPDATE_RATE)))
        if end <= start:
            continue
        target = centered[start:end]
        rr = frame_rms(target)
        if rr >= 0.008:
            frame_rms_values.append(rr * rr * len(target))
            err = target - recon[start:end]
            frame_err_values.append(float(np.sum(err * err)))
    if frame_rms_values:
        active_rms_pct = 100.0 * math.sqrt(sum(frame_err_values) / max(1e-12, sum(frame_rms_values)))
    else:
        active_rms_pct = rms_pct

    return SoundResult(
        sound_id=sound_id,
        name=name,
        priority=PRIORITY_BY_NAME.get(name, 64),
        payload=bytes(rows),
        source_seconds=source_seconds,
        output_seconds=frame_count / AY_UPDATE_RATE,
        rows=row_count,
        rmse=rmse,
        rms_pct=rms_pct,
        active_rms_pct=active_rms_pct,
        mode_counts=mode_counts,
    )


def encode_sound_task(task: tuple[int, str, str]) -> SoundResult | None:
    return encode_sound(*task)


def mode_summary(counts: dict[str, int]) -> str:
    return ",".join(f"{key}:{counts[key]}" for key in sorted(counts))


def pack_payloads(results: list[SoundResult]) -> bytes:
    table_size = AY_SOUND_COUNT * AY_SFX_RECORD_SIZE
    data = bytearray(b"\x00" * table_size)
    for result in results:
        current_page_offset = len(data) % PAGE_SIZE
        if current_page_offset and current_page_offset + len(result.payload) > PAGE_SIZE:
            data.extend(b"\x00" * (PAGE_SIZE - current_page_offset))
        offset = len(data)
        page = AY_DATA_PAGE + (offset // PAGE_SIZE)
        ptr = AY_TABLE_ADDR + (offset % PAGE_SIZE)
        rec = result.sound_id * AY_SFX_RECORD_SIZE
        data[rec + 0] = ptr & 0xFF
        data[rec + 1] = (ptr >> 8) & 0xFF
        data[rec + 2] = page & 0xFF
        data[rec + 3] = result.priority & 0xFF
        data.extend(result.payload)
    return bytes(data)


def write_meta(data_size: int) -> None:
    pages = max(1, (data_size + PAGE_SIZE - 1) // PAGE_SIZE)
    META_INC.write_text(
        "\n".join(
            [
                "; Auto-generated by Source/OTHER/make_ay_sfx.py - do not edit by hand.",
                f"AY_TABLE_PAGE         EQU #{AY_TABLE_PAGE:02X}",
                f"AY_DATA_PAGE          EQU #{AY_DATA_PAGE:02X}",
                f"AY_DATA_PAGE_COUNT    EQU {pages}",
                f"AY_TABLE_ADDR         EQU #{AY_TABLE_ADDR:04X}",
                f"AY_SOUND_COUNT        EQU {AY_SOUND_COUNT}",
                f"AY_SFX_RECORD_SIZE   EQU {AY_SFX_RECORD_SIZE}",
                f"AY_SFX_ROW_SIZE      EQU {AY_SFX_ROW_SIZE}",
                f"AY_SFX_FRAME_RATE    EQU {AY_UPDATE_RATE}",
                f"AY_SFX_DATA_SIZE     EQU {data_size}",
                "",
            ]
        ),
        encoding="ascii",
    )
    LEGACY_INC.write_text(
        "; Auto-generated placeholder. AY SFX data is packed into Sounds/AY/ay_sfx_data.bin.\n",
        encoding="ascii",
    )


def write_report(results: list[SoundResult], workers: int) -> list[SoundResult]:
    lines = [
        f"workers={workers} frame_rate={AY_UPDATE_RATE} max_wave_rms_pct={MAX_WAVE_RMS_PCT:.1f}",
        "id name                  src_s  out_s rows  rmse  rms% act% modes",
        "-- --------------------- ------ ----- ----- ----- ----- ---- ----------------",
    ]
    failed = []
    for result in results:
        lines.append(
            f"{result.sound_id:02d} {result.name:<21} {result.source_seconds:6.3f} "
            f"{result.output_seconds:5.3f} {result.rows:5d} {result.rmse:5.3f} "
            f"{result.rms_pct:5.1f} {result.active_rms_pct:4.0f} "
            f"{mode_summary(result.mode_counts)}"
        )
        if result.rms_pct > MAX_WAVE_RMS_PCT:
            failed.append(result)
    REPORT.write_text("\n".join(lines) + "\n", encoding="ascii")
    return failed


def main() -> int:
    tasks = [(sound_id, name, filename) for sound_id, (name, filename) in enumerate(SOUNDS)]
    tasks = [task for task in tasks if task[1] != "SND_SILENCE"]
    workers = max(1, min(len(tasks), os.cpu_count() or 1))
    try:
        with mp.Pool(processes=workers) as pool:
            raw_results = pool.map(encode_sound_task, tasks)
    except PermissionError as exc:
        print(f"multiprocessing unavailable ({exc}); falling back to one worker")
        workers = 1
        raw_results = [encode_sound_task(task) for task in tasks]
    results = sorted((r for r in raw_results if r is not None), key=lambda r: r.sound_id)
    data = pack_payloads(results)
    if len(data) > PAGE_SIZE * 4:
        raise SystemExit(f"AY SFX data is too large: {len(data)} bytes")

    OUT_BIN.parent.mkdir(parents=True, exist_ok=True)
    OUT_BIN.write_bytes(data)
    write_meta(len(data))
    failed = write_report(results, workers)
    row_count = sum(result.rows for result in results)
    print(f"ay sfx page: {OUT_BIN} ({len(results)} sounds, {row_count} rows, {len(data)} bytes, workers={workers})")
    print(f"ay sfx fit report: {REPORT}")
    if failed:
        print(f"AY SFX wave-fit failed: {len(failed)} sounds exceed {MAX_WAVE_RMS_PCT:.1f}% RMSE/RMS")
        for result in sorted(failed, key=lambda item: item.rms_pct, reverse=True):
            print(f"  {result.name}: {result.rms_pct:.1f}%")
        if not ALLOW_BAD_FITS:
            return 1
        print("AY_SFX_ALLOW_BAD=1: keeping generated AY SFX data for this build")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
