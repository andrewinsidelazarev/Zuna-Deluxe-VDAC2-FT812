#!/usr/bin/env python3
"""Render dual-chain lose absorb diagnostics as contact sheets.

This is intentionally geometry-focused: it draws the second kill-zone sprite
preview plus the chain2 head center sampled from the same Z80 code that the game
uses. The goal is to catch "numeric pass, visual fail" cases.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator

ROOT = Path(__file__).resolve().parents[2]
PACK = ROOT / "Graphics" / "levels" / "Converted" / "pack"
OUT = ROOT / "Diagnostics" / "dual_lose_absorb"
LEVELS = (5, 12, 19)
MAX_FRAMES = 80
TILE = (180, 150)
KZ_SIZE = 88


def load_track_page(emu: ZumaFullZ80Emulator, page: int, path: Path) -> None:
    data = path.read_bytes()
    start = page * PAGE_SIZE
    emu.mem.physical[start : start + PAGE_SIZE] = b"\x00" * PAGE_SIZE
    emu.mem.physical[start : start + len(data)] = data


def gb(emu: ZumaFullZ80Emulator, name: str) -> int:
    return emu.get_byte(emu.sym[name])


def sb(emu: ZumaFullZ80Emulator, name: str, value: int) -> None:
    emu.set_byte(emu.sym[name], value)


def signed16(value: int) -> int:
    return value - 0x10000 if value & 0x8000 else value


def killzone_frames() -> list[Image.Image]:
    preview = Image.open(ROOT / "Diagnostics" / "Scratch" / "RootPreviews" / "_killzone_preview.png").convert("RGBA")
    preview = preview.resize((KZ_SIZE * 12, KZ_SIZE), Image.Resampling.NEAREST)
    return [preview.crop((i * KZ_SIZE, 0, (i + 1) * KZ_SIZE, KZ_SIZE)) for i in range(12)]


def chain2_head(emu: ZumaFullZ80Emulator) -> tuple[int, int] | None:
    if gb(emu, "Core.VDC2_SlotsLen") == 0:
        return None
    sym = emu.sym
    emu.call(sym["Core.VDC_SwapChains"], max_steps=5_000_000)
    emu.call(sym["Core.SetSecondTrackPage"], max_steps=5_000_000)
    emu.call(sym["Core.VDC_SlotPos"], a=0, max_steps=5_000_000)
    cf = emu.reg.F & 0x01
    x = signed16(emu.reg.BC)
    y = signed16(emu.reg.DE)
    emu.call(sym["Core.VDC_SwapChains"], max_steps=5_000_000)
    emu.call(sym["Core.SetCurrentTrackPage"], max_steps=5_000_000)
    if cf:
        return None
    return x, y


def setup(level: int) -> ZumaFullZ80Emulator:
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    load_track_page(emu, 0x06, PACK / f"track_l{level:02d}_640.bin")
    load_track_page(emu, 0x0F, PACK / f"track_l{level:02d}_2_640.bin")
    emu.mem.pages = [0x00, 0x05, 0x06, 0x04]
    sb(emu, "Core.CurrentLevel", level - 1)
    sb(emu, "Core.CurrentDifficulty", 0)
    emu.call(sym["Core.VDC_Init"], max_steps=5_000_000)

    cl_start = sym["Core.VDC_ChainLocalStart"]
    hsa_off = sym["Core.VDC_HSA"] - cl_start
    freeze_off = sym["Core.VDC_ChainFreezeCnt"] - cl_start
    tns_off = sym["Core.VDC_TrackNumSlots"] - cl_start
    tns2 = emu.get_word(sym["Core.VDC2_ChainLocal"] + tns_off)

    sb(emu, "Core.VDC_GameState", 1)
    sb(emu, "Core.VDC_DialogState", 0)
    sb(emu, "Core.VDC_Lives", 1)
    sb(emu, "Core.VDC_SlotsLen", 0)
    sb(emu, "Core.VDC_HSub", 0)
    sb(emu, "Core.VDC_KzFrame", 0)
    sb(emu, "Core.VDC_HasSecondChain", 1)
    sb(emu, "Core.VDC_SecondActive", 0)
    sb(emu, "Core.VDC_HeadAbsorbAlpha", 255)

    for i in range(4):
        emu.set_byte(sym["Core.VDC2_Slots"] + i, i % 6)
        emu.set_byte(sym["Core.VDC2_Offsets"] + i, 0)
        emu.set_byte(sym["Core.VDC2_Shot2"] + i, 0)
        emu.set_byte(sym["Core.VDC2_ExplodeFrame"] + i, 0)
        emu.set_byte(sym["Core.VDC2_ExplodeMarker"] + i, 0)
    sb(emu, "Core.VDC2_SlotsLen", 4)
    sb(emu, "Core.VDC2_HSub", 9)
    sb(emu, "Core.VDC2_KzFrame", 1)
    emu.set_byte(sym["Core.VDC2_ChainLocal"] + hsa_off, max(0, tns2 - 5))
    emu.set_byte(sym["Core.VDC2_ChainLocal"] + hsa_off + 1, 0)
    emu.set_byte(sym["Core.VDC2_ChainLocal"] + freeze_off, 0)
    return emu


def render_level(level: int, frames: list[Image.Image]) -> str:
    emu = setup(level)
    sym = emu.sym
    samples = []
    for frame in range(MAX_FRAMES):
        head = chain2_head(emu)
        samples.append(
            {
                "frame": frame,
                "head": head,
                "kz_frame": gb(emu, "Core.VDC2_KzFrame"),
                "len2": gb(emu, "Core.VDC2_SlotsLen"),
                "hsub2": gb(emu, "Core.VDC2_HSub"),
                "dialog": gb(emu, "Core.VDC_DialogState"),
                "kz_x": emu.get_word(sym["Core.VDC2_KzDrawX16"]) // 16,
                "kz_y": emu.get_word(sym["Core.VDC2_KzDrawY16"]) // 16,
            }
        )
        emu.call(sym["Core.VDC_UpdateAllChains"], max_steps=5_000_000)
        if gb(emu, "Core.VDC_DialogState") != 0:
            break

    cols = 8
    rows = (len(samples) + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * TILE[0], rows * TILE[1]), (24, 24, 24, 255))
    for i, s in enumerate(samples):
        ox = (i % cols) * TILE[0]
        oy = (i // cols) * TILE[1]
        tile = Image.new("RGBA", TILE, (34, 34, 34, 255))
        draw = ImageDraw.Draw(tile)
        kx = 46
        ky = 26
        kzf = min(11, max(0, int(s["kz_frame"])))
        tile.alpha_composite(frames[kzf], (kx, ky))
        draw.rectangle((kx, ky, kx + KZ_SIZE - 1, ky + KZ_SIZE - 1), outline=(90, 90, 90, 255))
        draw.line((kx + 44, ky, kx + 44, ky + KZ_SIZE), fill=(80, 120, 255, 255))
        draw.line((kx, ky + 44, kx + KZ_SIZE, ky + 44), fill=(80, 120, 255, 255))
        draw.line((kx + 44, ky, kx + 44, ky + KZ_SIZE), fill=(80, 120, 255, 255))
        draw.line((kx, ky + 56, kx + KZ_SIZE, ky + 56), fill=(255, 120, 80, 255))
        if s["head"] is not None:
            hx = kx + (s["head"][0] - s["kz_x"])
            hy = ky + (s["head"][1] - s["kz_y"])
            draw.ellipse((hx - 15, hy - 15, hx + 15, hy + 15), outline=(255, 40, 40, 255), width=3)
            draw.line((hx - 4, hy, hx + 4, hy), fill=(255, 255, 255, 255))
            draw.line((hx, hy - 4, hx, hy + 4), fill=(255, 255, 255, 255))
        draw.text((6, 4), f"f{s['frame']} len{s['len2']} kz{s['kz_frame']} hs{s['hsub2']} dlg{s['dialog']}", fill=(240, 240, 240, 255))
        sheet.alpha_composite(tile, (ox, oy))

    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / f"dual_lose_l{level:02d}.png"
    sheet.convert("RGB").save(out)
    last = samples[-1]
    return f"L{level:02d}: frames={len(samples)} last=len{last['len2']} kz{last['kz_frame']} hs{last['hsub2']} dlg{last['dialog']} -> {out}"


def main() -> int:
    frames = killzone_frames()
    for level in LEVELS:
        print(render_level(level, frames))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
