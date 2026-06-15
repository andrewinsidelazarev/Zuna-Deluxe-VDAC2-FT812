#!/usr/bin/env python3
"""Build ZUMASND.PAK from converted General Sound WAV effects.

The pack stores RIFF-stripped unsigned 8-bit mono PCM. Most effects are
Source WAVs are 22050 Hz, but the current General Sound FX playback path is
calibrated for 8000 Hz unsigned PC samples, so every effect is resampled to
8000 Hz before packing.
Sound IDs match Zuma-Deluxe-HD-ref ResourceStore.h exactly.
"""
from __future__ import annotations

import struct
import subprocess
import wave
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SRC_DIR = ROOT / "Sounds" / "Converted" / "WAV_GS"
FFMPEG = ROOT / "Sounds" / "Converted" / "tools" / "ffmpeg" / "ffmpeg-8.1.1-essentials_build" / "bin" / "ffmpeg.exe"
OUT = ROOT / "Build" / "ZUMASND.PAK"
INC = ROOT / "Source" / "ASM" / "sound_pak_size.inc"
SECTOR = 512
MIN_OUTPUT_SIZE = 1215488  # keep host FAT entry size stable for partial updates
TARGET_RATE = 11025
TRIM_SILENCE_TAIL = {
    "SND_BALLSDESTROYED1": 0,
    "SND_BALLSDESTROYED2": 0,
    "SND_BALLSDESTROYED3": 0,
    "SND_BALLSDESTROYED4": 0,
    "SND_BALLSDESTROYED5": 0,
}
FADE_TAIL_SAMPLES = {
    "SND_BALLSDESTROYED1": 1024,
    "SND_BALLSDESTROYED2": 1024,
    "SND_BALLSDESTROYED3": 1024,
    "SND_BALLSDESTROYED4": 1024,
    "SND_BALLSDESTROYED5": 1024,
}

SOUNDS = [
    ("SND_ACCURACY3", "accuracy3.wav"),
    ("SND_BALLCLICK1", "ballclick1.wav"),
    ("SND_BALLCLICK2", "ballclick2.wav"),
    ("SND_BALLSDESTROYED1", "ballsdestroyed1.wav"),
    ("SND_BALLSDESTROYED2", "ballsdestroyed2.wav"),
    ("SND_BALLSDESTROYED3", "ballsdestroyed3.wav"),
    ("SND_BALLSDESTROYED4", "ballsdestroyed4.wav"),
    ("SND_BALLSDESTROYED5", "ballsdestroyed5.wav"),
    ("SND_BOMBEXPLODE", "bombexplode.wav"),
    ("SND_BUTTON1", "button1.wav"),
    ("SND_BUTTON2", "button2.wav"),
    ("SND_CHAIN1", "chain1.wav"),
    ("SND_CHANT1", "chant1.wav"),
    ("SND_CHANT14", "chant14.wav"),
    ("SND_CHANT2", "chant2.wav"),
    ("SND_CHANT3", "chant3.wav"),
    ("SND_CHANT4", "chant4.wav"),
    ("SND_CHANT5", "chant5.wav"),
    ("SND_CHANT6", "chant6.wav"),
    ("SND_CHANT8", "chant8.wav"),
    ("SND_CHIME1", "chime1.wav"),
    ("SND_CHORAL1", "choral1.wav"),
    ("SND_COINGRAB", "coingrab.wav"),
    ("SND_EARTHQUAKE", "earthquake.wav"),
    ("SND_ENDOFLEVELPOP1", "endoflevelpop1.wav"),
    ("SND_EXTRALIFE", "extralife.wav"),
    ("SND_FIREBALL1", "fireball1.wav"),
    ("SND_FROGLAND2", "frogland2.wav"),
    ("SND_GAPBONUS1", "gapbonus1.wav"),
    ("SND_GEMVANISHES", "gemvanishes.wav"),
    ("SND_JEWELAPPEAR", "jewelappear.wav"),
    ("SND_LIGHTTRAIL2", "lighttrail2.wav"),
    ("SND_POP", "pop.wav"),
    ("SND_REVERSE1", "reverse1.wav"),
    ("SND_ROLLING", "rolling.wav"),
    ("SND_SLOWDOWN1", "slowdown1.wav"),
    ("SND_UFO1", "ufo1.wav"),
    ("SND_WARNING1", "warning1.wav"),
    ("SND_SILENCE", "mute.wav"),
]

# Keep the table in reference IDs. Preload only effects currently wired in the
# game layer, plus a short silence sample used to stop long one-shot FX.
# Win/Lose озвучка (2026-06-13): + earthquake(23) warning1(37) pop(32, всасывание),
# chant2(14, win-конец), chant8(19, game over), chant14(13, потеря жизни).
# Сумма 25 звуков = 353 КБ при GS 1 МБ (запас 687 КБ) — partial-fail исключён.
PRELOAD_IDS = [
    9, 10, 26, 20, 12, 2, 1, 34, 38,
    3, 4, 5, 6, 7, 24, 25, 28, 11, 21,
    23, 37, 32, 14, 19, 13,
]

def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) // alignment * alignment


def resample_u8_mono(path: Path, dst_rate: int) -> bytes:
    if not FFMPEG.exists():
        raise SystemExit(f"missing ffmpeg: {FFMPEG}")
    cmd = [
        str(FFMPEG),
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(path),
        "-vn",
        "-ac",
        "1",
        "-af",
        f"aresample={dst_rate}:filter_size=64:phase_shift=10:cutoff=0.95:dither_method=triangular",
        "-f",
        "u8",
        "-acodec",
        "pcm_u8",
        "-",
    ]
    try:
        return subprocess.check_output(cmd)
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f"ffmpeg resample failed for {path}: {exc}") from exc


def read_pcm(path: Path) -> tuple[int, bytes]:
    with wave.open(str(path), "rb") as wav:
        params = wav.getparams()
        if params.nchannels != 1 or params.sampwidth != 1 or params.framerate != 22050:
            raise SystemExit(f"unsupported WAV format: {path} {params}")
        if params.comptype != "NONE":
            raise SystemExit(f"compressed WAV is not supported: {path}")
        return params.framerate, wav.readframes(params.nframes)


def trim_u8_silence_tail(pcm: bytes, keep: int) -> bytes:
    end = len(pcm)
    while end > 0 and pcm[end - 1] == 128:
        end -= 1
    return pcm[: min(len(pcm), end + keep)]


def fade_u8_tail_to_silence(pcm: bytes, samples: int) -> bytes:
    if samples <= 0 or not pcm:
        return pcm
    start = max(0, len(pcm) - samples)
    out = bytearray(pcm)
    span = len(out) - start
    for i in range(start, len(out)):
        level = (len(out) - 1 - i) / span
        out[i] = round(128 + (out[i] - 128) * level)
    return bytes(out)


def main() -> int:
    records: list[tuple[int, int, int, bytes]] = []
    payload = bytearray()
    header_size = 16 + len(SOUNDS) * 16
    cursor = align_up(header_size, SECTOR)
    payload.extend(b"\0" * cursor)

    for sound_id, (name, filename) in enumerate(SOUNDS):
        path = SRC_DIR / filename
        if not path.exists():
            raise SystemExit(f"missing sound: {path}")
        rate, pcm = read_pcm(path)
        target_rate = TARGET_RATE
        if target_rate != rate:
            pcm = resample_u8_mono(path, target_rate)
            rate = target_rate
        # НЕ резать и НЕ фейдить хвост сэмпла (это калечит звук — отвергнуто).
        # Вместо этого добиваем сэмпл unsigned-тишиной (0x80) до границы СЕКТОРА
        # (+небольшой запас). GS округляет длину FX-сэмпла вверх и доигрывает
        # «добор» из своей RAM; раньше там был мусор/остаток прошлого сэмпла →
        # шум (битый wav) в конце. Теперь добор всегда попадает в нашу тишину.
        # Выравнивание на 512 покрывает любую гранулярность GS, делящую сектор
        # (32/64/128/256/512) — точное значение из доки знать не требуется.
        target_len = align_up(len(pcm) + 64, SECTOR)
        pcm = pcm + bytes([0x80]) * (target_len - len(pcm))
        cursor = align_up(len(payload), SECTOR)
        if len(payload) < cursor:
            payload.extend(b"\x80" * (cursor - len(payload)))
        offset = len(payload)
        payload.extend(pcm)
        records.append((offset, len(pcm), rate, b"\0\0\0\0"))

    toc = bytearray()
    for offset, size, rate, flags in records:
        toc.extend(struct.pack("<IIHH4s", offset, size, rate, 0, flags))
    header = struct.pack("<4sHHII", b"ZSPD", 1, len(SOUNDS), SECTOR, header_size)
    payload[: len(header)] = header
    payload[len(header) : len(header) + len(toc)] = toc

    if len(payload) < MIN_OUTPUT_SIZE:
        payload.extend(b"\0" * (MIN_OUTPUT_SIZE - len(payload)))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(payload)
    size = len(payload)
    full_sectors, tail = divmod(size, SECTOR)
    total_sectors = full_sectors + (1 if tail else 0)

    lines = [
        "; Auto-generated by Source/OTHER/make_sound_pack.py - do not edit by hand.",
        f"; ZUMASND.PAK stores raw 8-bit mono {TARGET_RATE} Hz GS sound effects.",
        f"EXPECTED_SOUND_PAK_SIZE       EQU {size}",
        f"EXPECTED_SOUND_PAK_SECTORS    EQU {total_sectors}",
        f"EXPECTED_SOUND_PAK_FULL_SECS  EQU {full_sectors}",
        f"EXPECTED_SOUND_PAK_TAIL_BYTES EQU {tail}",
        f"GS_SOUND_COUNT                EQU {len(SOUNDS)}",
        f"GS_SFX_PRELOAD_COUNT          EQU {len(PRELOAD_IDS)}",
    ]
    for sound_id, (name, _) in enumerate(SOUNDS):
        lines.append(f"{name:<24} EQU {sound_id}")
    lines.append("GS_SfxPreloadTable:")
    for sound_id in PRELOAD_IDS:
        offset, pcm_size, _, _ = records[sound_id]
        sector = offset // SECTOR
        full, sample_tail = divmod(pcm_size, SECTOR)
        lines.append(
            f"        DB {sound_id}, {sector & 0xFF}, {(sector >> 8) & 0xFF}, "
            f"{full & 0xFF}, {sample_tail & 0xFF}, {(sample_tail >> 8) & 0xFF}"
        )
    INC.write_text("\n".join(lines) + "\n", encoding="ascii")
    print(f"sound pack: {OUT} ({size:,} bytes, {total_sectors} sectors, tail={tail})")
    print(f"  wrote {INC}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
