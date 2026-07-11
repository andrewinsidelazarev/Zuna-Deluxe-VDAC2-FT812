#!/usr/bin/env python3
"""FFT-подстройка AY SFX для SND_POP.

Скрипт не пересобирает общий AY-банк. Он читает текущий
Sounds/AY/ay_sfx_data.bin, оптимизирует только SND_POP по 50-мс кадрам
оригинального pop.wav и добавляет новый payload в свободный хвост страницы.
Payload остальных SFX остается байт-в-байт прежним.
"""

from __future__ import annotations

import math
import multiprocessing as mp
import wave
from dataclasses import dataclass
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[2]
SRC_WAV = ROOT / "Sounds" / "Converted" / "WAV_GS" / "pop.wav"
AY_BIN = ROOT / "Sounds" / "AY" / "ay_sfx_data.bin"
REPORT = ROOT / "Sounds" / "AY" / "ay_sfx_report.txt"
META_INC = ROOT / "Source" / "ASM" / "ay_sfx_meta.inc"

SND_POP = 32
AY_SOUND_COUNT = 39
AY_RECORD_SIZE = 4
AY_ROW_SIZE = 12
AY_TABLE_ADDR = 0x8000
AY_TABLE_PAGE = 0xF4
AY_DATA_PAGE = 0xF4
AY_PAGE_SIZE = 0x4000
AY_CLOCK = 1_773_400
FRAME_RATE = 20
WORKERS = 6

AY_MIXER_SILENT = 0x3F
FFT_MAX_HZ = 5_000.0
EPS = 1.0e-9

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


@dataclass(frozen=True)
class Variant:
    mode: str
    period: int
    volume: int
    wave: np.ndarray


@dataclass(frozen=True)
class FrameResult:
    frame: int
    noise: int
    error: float
    row: bytes
    target_rms: float
    synth_rms: float
    modes: tuple[str, ...]
    periods: tuple[int, int, int]
    volumes: tuple[int, int, int]


def read_pcm_u8(path: Path) -> tuple[int, np.ndarray]:
    with wave.open(str(path), "rb") as wav:
        params = wav.getparams()
        if params.nchannels != 1 or params.sampwidth != 1 or params.comptype != "NONE":
            raise SystemExit(f"unsupported WAV format: {path} {params}")
        raw = np.frombuffer(wav.readframes(params.nframes), dtype=np.uint8).astype(np.float32)
        return params.framerate, (raw - 128.0) / 128.0


def clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


def period_from_freq(freq: float) -> int:
    if freq <= 0.0:
        return 1
    return clamp(int(round(AY_CLOCK / (16.0 * freq))), 1, 0x0FFF)


def tone_wave(period: int, sample_rate: int, start: int, length: int) -> np.ndarray:
    period = clamp(period, 1, 0x0FFF)
    freq = AY_CLOCK / (16.0 * period)
    phase = ((np.arange(start, start + length, dtype=np.float32) * freq / sample_rate) % 1.0)
    return np.where(phase < 0.5, 1.0, -1.0).astype(np.float32)


def noise_wave(period: int, start: int, length: int, sample_rate: int) -> np.ndarray:
    period = clamp(period, 1, 31)
    freq = AY_CLOCK / (16.0 * period)
    hold = max(1, int(round(sample_rate / max(1.0, freq))))
    skip = start // hold
    lfsr = 0x1FFFF
    for _ in range(skip):
        bit = (lfsr ^ (lfsr >> 3)) & 1
        lfsr = ((lfsr >> 1) | (bit << 16)) & 0x1FFFF
    out = np.empty(length, dtype=np.float32)
    pos = 0
    first = start % hold
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
        take = min(length - pos, hold)
        out[pos : pos + take] = value
        pos += take
    return out


def rms(x: np.ndarray) -> float:
    return float(np.sqrt(np.mean(x * x))) if len(x) else 0.0


def fft_mag(x: np.ndarray, sample_rate: int) -> tuple[np.ndarray, np.ndarray]:
    centered = x.astype(np.float32, copy=False) - float(np.mean(x))
    window = np.hanning(len(centered)).astype(np.float32)
    mag = np.abs(np.fft.rfft(centered * window)).astype(np.float32)
    freqs = np.fft.rfftfreq(len(centered), 1.0 / sample_rate).astype(np.float32)
    mask = (freqs >= 40.0) & (freqs <= FFT_MAX_HZ)
    return freqs[mask], mag[mask]


def spectral_error(target: np.ndarray, synth: np.ndarray, sample_rate: int) -> float:
    tr = rms(target - float(np.mean(target)))
    sr = rms(synth - float(np.mean(synth)))
    if tr < 0.004:
        return sr * 10.0
    _, tmag = fft_mag(target, sample_rate)
    _, smag = fft_mag(synth, sample_rate)
    if float(np.max(tmag)) < EPS:
        return sr * 10.0
    tnorm = tmag / (float(np.max(tmag)) + EPS)
    snorm = smag / (float(np.max(smag)) + EPS)
    weights = 0.20 + 0.80 * tnorm
    spec = math.sqrt(float(np.sum(weights * (tnorm - snorm) ** 2) / np.sum(weights)))
    energy = abs(math.log((sr + 0.002) / (tr + 0.002)))
    return spec + 0.22 * energy


def mixer_for_modes(modes: list[str]) -> int:
    mixer = 0
    for channel, mode in enumerate(modes):
        if mode not in ("tone", "both"):
            mixer |= 1 << channel
        if mode not in ("noise", "both"):
            mixer |= 1 << (channel + 3)
    return mixer & 0x3F


def row_bytes(periods: tuple[int, int, int], noise: int, modes: list[str], volumes: tuple[int, int, int]) -> bytes:
    pa, pb, pc = periods
    va, vb, vc = volumes
    return bytes(
        [
            1,
            pa & 0xFF,
            (pa >> 8) & 0x0F,
            pb & 0xFF,
            (pb >> 8) & 0x0F,
            pc & 0xFF,
            (pc >> 8) & 0x0F,
            noise & 0x1F,
            mixer_for_modes(modes),
            va & 0x0F,
            vb & 0x0F,
            vc & 0x0F,
        ]
    )


def period_candidates(target: np.ndarray, sample_rate: int) -> list[int]:
    freqs, mag = fft_mag(target, sample_rate)
    periods: set[int] = set()
    if len(freqs):
        count = min(14, len(freqs))
        top = np.argpartition(mag, -count)[-count:]
        for idx in top:
            freq = float(freqs[idx])
            for mul in (0.5, 1.0, 1.5, 2.0, 3.0):
                p = period_from_freq(freq * mul)
                for delta in range(-18, 19):
                    periods.add(clamp(p + delta, 1, 0x0FFF))
    # Грубая сетка нужна, чтобы FFT-пики не заперли поиск в локальном минимуме.
    for p in range(24, 260, 2):
        periods.add(p)
    for p in range(260, 900, 8):
        periods.add(p)
    return sorted(periods)


def make_variants(
    target: np.ndarray,
    sample_rate: int,
    start: int,
    noise_period: int,
) -> list[Variant]:
    length = len(target)
    n = noise_wave(noise_period, start, length, sample_rate)
    periods = period_candidates(target, sample_rate)
    base: list[tuple[float, str, int, np.ndarray]] = []
    for period in periods:
        t = tone_wave(period, sample_rate, start, length)
        both = np.where((t > 0) & (n > 0), 1.0, -1.0).astype(np.float32)
        base.append((spectral_error(target, t, sample_rate), "tone", period, t))
        base.append((spectral_error(target, both, sample_rate), "both", period, both))
    base.append((spectral_error(target, n, sample_rate), "noise", 1, n))
    base.sort(key=lambda item: item[0])

    variants: list[tuple[float, Variant]] = []
    for _, mode, period, unit in base[:96]:
        for volume in range(1, 16):
            wave = unit * float(AY_VOLUME_LEVELS[volume])
            variants.append((spectral_error(target, wave, sample_rate), Variant(mode, period, volume, wave)))
    variants.sort(key=lambda item: item[0])
    return [variant for _, variant in variants[:96]]


def optimize_frame_noise(args: tuple[int, int, int, bytes, int, int]) -> FrameResult:
    frame, noise_period, sample_rate, frame_bytes, global_start, frame_len = args
    target = np.frombuffer(frame_bytes, dtype=np.float32).copy()
    variants = make_variants(target, sample_rate, global_start, noise_period)

    zero = np.zeros(frame_len, dtype=np.float32)
    beam: list[tuple[float, list[Variant], np.ndarray, int]] = [(spectral_error(target, zero, sample_rate), [], zero, -1)]
    best = beam[0]
    for _ in range(3):
        expanded: list[tuple[float, list[Variant], np.ndarray, int]] = []
        for _, selected, wave, last_idx in beam:
            for idx in range(last_idx + 1, len(variants)):
                variant = variants[idx]
                new_wave = wave + variant.wave
                score = spectral_error(target, new_wave, sample_rate)
                expanded.append((score, selected + [variant], new_wave, idx))
        expanded.sort(key=lambda item: item[0])
        beam = expanded[:160]
        if beam and beam[0][0] < best[0]:
            best = beam[0]

    score, selected, synth, _ = best
    modes = [variant.mode for variant in selected[:3]]
    periods = [variant.period if variant.mode != "noise" else 1 for variant in selected[:3]]
    volumes = [variant.volume for variant in selected[:3]]
    while len(modes) < 3:
        modes.append("sil")
        periods.append(1)
        volumes.append(0)
    return FrameResult(
        frame=frame,
        noise=noise_period,
        error=score,
        row=row_bytes(tuple(periods), noise_period, modes, tuple(volumes)),
        target_rms=rms(target - float(np.mean(target))),
        synth_rms=rms(synth - float(np.mean(synth))),
        modes=tuple(modes),
        periods=tuple(periods),
        volumes=tuple(volumes),
    )


def build_payload() -> tuple[bytes, list[FrameResult]]:
    sample_rate, pcm = read_pcm_u8(SRC_WAV)
    frame_len = int(round(sample_rate / FRAME_RATE))
    frame_count = int(math.ceil(len(pcm) / frame_len))
    tasks: list[tuple[int, int, int, bytes, int, int]] = []
    for frame in range(frame_count):
        start = frame * frame_len
        chunk = pcm[start : min(len(pcm), start + frame_len)]
        if len(chunk) < frame_len:
            chunk = np.pad(chunk, (0, frame_len - len(chunk)), mode="constant")
        frame_bytes = chunk.astype(np.float32, copy=False).tobytes()
        for noise in range(1, 32):
            tasks.append((frame, noise, sample_rate, frame_bytes, start, frame_len))

    with mp.Pool(processes=WORKERS) as pool:
        results = pool.map(optimize_frame_noise, tasks)

    best_by_frame: list[FrameResult] = []
    for frame in range(frame_count):
        candidates = [result for result in results if result.frame == frame]
        best_by_frame.append(min(candidates, key=lambda result: result.error))

    payload = bytearray()
    for result in best_by_frame:
        payload.extend(result.row)
    payload.append(0)
    return bytes(payload), best_by_frame


def record_offset(data: bytes, sound_id: int) -> tuple[int, int, int, int]:
    rec = sound_id * AY_RECORD_SIZE
    ptr = data[rec] | (data[rec + 1] << 8)
    page = data[rec + 2]
    priority = data[rec + 3]
    offset = (page - AY_DATA_PAGE) * AY_PAGE_SIZE + (ptr - AY_TABLE_ADDR)
    return rec, offset, page, priority


def read_payload(data: bytes, offset: int) -> bytes:
    pos = offset
    while data[pos] != 0:
        pos += AY_ROW_SIZE
    return data[offset : pos + 1]


def payload_end(data: bytes, sound_id: int) -> int:
    rec, offset, page, _ = record_offset(data, sound_id)
    ptr = data[rec] | (data[rec + 1] << 8)
    if ptr == 0 or page == 0:
        return AY_SOUND_COUNT * AY_RECORD_SIZE
    pos = offset
    while pos < len(data) and data[pos] != 0:
        pos += AY_ROW_SIZE
    return min(len(data), pos + 1)


def bank_base_len_without_pop(data: bytes) -> int:
    end = AY_SOUND_COUNT * AY_RECORD_SIZE
    for sound_id in range(AY_SOUND_COUNT):
        if sound_id == SND_POP:
            continue
        end = max(end, payload_end(data, sound_id))
    return end


def update_meta(data_size: int) -> None:
    lines = META_INC.read_text(encoding="ascii").splitlines()
    out = []
    for line in lines:
        if line.startswith("AY_DATA_PAGE_COUNT"):
            pages = max(1, (data_size + AY_PAGE_SIZE - 1) // AY_PAGE_SIZE)
            out.append(f"AY_DATA_PAGE_COUNT    EQU {pages}")
        elif line.startswith("AY_SFX_DATA_SIZE"):
            out.append(f"AY_SFX_DATA_SIZE     EQU {data_size}")
        else:
            out.append(line)
    META_INC.write_text("\n".join(out) + "\n", encoding="ascii")


def update_report(frame_results: list[FrameResult], payload: bytes) -> None:
    if not REPORT.exists():
        return
    lines = REPORT.read_text(encoding="ascii", errors="replace").splitlines()
    out = []
    mode_counts: dict[str, int] = {}
    for result in frame_results:
        for mode in result.modes:
            mode_counts[mode] = mode_counts.get(mode, 0) + 1
    modes = ",".join(f"{key}:{mode_counts[key]}" for key in sorted(mode_counts))
    avg_err = sum(result.error for result in frame_results) / len(frame_results)
    active = 100.0 * avg_err
    row = (
        f"32 SND_POP                {4736 / 22050:6.3f} "
        f"{len(frame_results) / FRAME_RATE:5.3f} {len(frame_results):5d} "
        f"{avg_err:5.3f} {active:5.1f} {active:4.0f} {modes}"
    )
    replaced = False
    for line in lines:
        if line.startswith("32 SND_POP"):
            out.append(row)
            replaced = True
        else:
            out.append(line)
    if not replaced:
        out.append(row)
    REPORT.write_text("\n".join(out) + "\n", encoding="ascii")


def main() -> int:
    original = AY_BIN.read_bytes()
    data = bytearray(original)
    base_len = bank_base_len_without_pop(data)
    if len(data) > base_len:
        data = data[:base_len]
    old_table = bytes(data[: AY_SOUND_COUNT * AY_RECORD_SIZE])
    rec, old_offset, old_page, old_priority = record_offset(data, SND_POP)
    old_payload = read_payload(data, old_offset) if 0 <= old_offset < len(data) else b""

    payload, frame_results = build_payload()
    if len(data) + len(payload) > AY_PAGE_SIZE:
        raise SystemExit("not enough room in AY page for tuned SND_POP payload")

    new_offset = len(data)
    new_ptr = AY_TABLE_ADDR + new_offset
    data[rec + 0] = new_ptr & 0xFF
    data[rec + 1] = (new_ptr >> 8) & 0xFF
    data[rec + 2] = AY_DATA_PAGE
    data[rec + 3] = old_priority
    data.extend(payload)
    AY_BIN.write_bytes(bytes(data))
    update_meta(len(data))
    update_report(frame_results, payload)

    new_table = bytes(data[: AY_SOUND_COUNT * AY_RECORD_SIZE])
    changed_non_pop = [
        sound_id
        for sound_id in range(AY_SOUND_COUNT)
        if sound_id != SND_POP
        if old_table[sound_id * AY_RECORD_SIZE : sound_id * AY_RECORD_SIZE + AY_RECORD_SIZE]
        != new_table[sound_id * AY_RECORD_SIZE : sound_id * AY_RECORD_SIZE + AY_RECORD_SIZE]
    ]
    if changed_non_pop:
        raise SystemExit(f"unexpected AY table changes outside SND_POP: {changed_non_pop}")

    print(f"old SND_POP payload: offset={old_offset} bytes={len(old_payload)}")
    print(f"new SND_POP payload: offset={new_offset} bytes={len(payload)}")
    for result in frame_results:
        print(
            "frame {frame}: noise={noise:02d} err={err:.4f} "
            "target_rms={tr:.4f} synth_rms={sr:.4f} "
            "modes={modes} periods={periods} volumes={vols}".format(
                frame=result.frame,
                noise=result.noise,
                err=result.error,
                tr=result.target_rms,
                sr=result.synth_rms,
                modes="/".join(result.modes),
                periods="/".join(str(p) for p in result.periods),
                vols="/".join(str(v) for v in result.volumes),
            )
        )
    print("PASS: only SND_POP table record was redirected; other AY payload bytes were not rewritten")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
