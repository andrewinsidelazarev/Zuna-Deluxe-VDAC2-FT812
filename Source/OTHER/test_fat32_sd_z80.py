#!/usr/bin/env python3
"""Клод: загрузчик игры с настоящим FAT32-драйвером на Z80-стенде.

Исполняется настоящий код игры (переходник fat32_adapter.asm, ts-dos.asm) и
настоящий драйвер из страниц #14/#15 (Build/fat32*.bin). Подменены только
обработчики init/read512 порта SD-ZC (таблица #3900 рабочей страницы): секторы
берутся из образа карты в памяти (fat32_test_image.Card) — MBR, кластер 4 КиБ,
фрагментированные файлы, длинные имена.

Сценарии:
  1. Выход в WC: ProbeBootHobeta находит BOOT.$C в корне и кладёт его целиком
     (31761 байт, фрагментирован) в QUIT_BOOT_PAGE0/1.
  2. Путь панели WC (страница #F7) ведёт в каталог игры, хотя в корне есть
     каталог-приманка с ZUMALVL.PAK того же размера и испорченным TOC.
  3. Без пути WC каталог находится обходом дерева.
Во 2 и 3 сверяются TOC уровня и страница фона, прочитанная Fat_ReadSectors.
Проверка на модели, не замена Unreal и железа.
"""
from __future__ import annotations

import hashlib
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from fat32_test_image import Card  # noqa: E402
from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator  # noqa: E402

BOOT_SIZE = 31761
LEVEL = 5
WORK_PAGE = 0x15


def boot_bytes() -> bytes:
    out = b""
    seed = b"BOOT.$C"
    while len(out) < BOOT_SIZE:
        seed = hashlib.sha256(seed).digest()
        out += seed
    return out[:BOOT_SIZE]


def build_card(pak: bytes, decoy: bool) -> Card:
    card = Card(spc=8, clusters=5000)
    boot = boot_bytes()
    # BOOT.$C — двумя кусками с пропуском между ними.
    chain = [card.alloc() for _ in range(3)]
    card.alloc()
    chain += [card.alloc() for _ in range(5)]
    card.add_file(card.root, "BOOT.$C", boot, chain)
    card.mkdir(card.root, "WC")
    games = card.mkdir(card.root, "Games")
    zuma = card.mkdir(games, "Zuma Deluxe VDAC2")
    size = card.spc * 512
    n = (len(pak) + size - 1) // size
    chain = []
    while len(chain) < n:
        run = min(1 + len(chain) % 5, n - len(chain))
        chain += [card.alloc() for _ in range(run)]
        card.alloc()                                   # пропуск: файл фрагментирован
    card.add_file(zuma, "ZUMALVL.PAK", pak, chain)
    if decoy:
        bad = bytearray(pak)
        bad[512:1024] = b"\xFF" * 512                 # TOC: все уровни «отсутствуют»
        d = card.mkdir(card.root, "Decoy")
        card.add_file(d, "ZUMALVL.PAK", bytes(bad))
    return card.finish()


class Rig:
    def __init__(self, card: Card, wc_path: bytes | None) -> None:
        self.emu = emu = ZumaFullZ80Emulator(ROOT)
        self.sym = emu.sym
        self.card = card
        self.reads = 0
        base = WORK_PAGE * PAGE_SIZE + 0x3900
        self.port_init, self.port_read = struct.unpack_from("<HH", bytes(emu.mem.physical[base:base + 4]))
        orig = emu.step

        def step() -> int:
            pc = emu.reg.PC
            if emu.mem.pages[0] == WORK_PAGE and pc in (self.port_init, self.port_read):
                if pc == self.port_read:
                    r = emu.reg
                    lba = (r.D << 24) | (r.E << 16) | (r.H << 8) | r.L
                    buf = (r.B << 8) | r.C
                    for i, value in enumerate(card.sector(lba)):
                        emu.mem.write((buf + i) & 0xFFFF, value)
                    self.reads += 1
                emu.reg.A = 0
                sp = emu.reg.SP
                emu.reg.PC = emu.mem.read(sp) | (emu.mem.read((sp + 1) & 0xFFFF) << 8)
                emu.reg.SP = (sp + 2) & 0xFFFF
                return 0
            return orig()

        emu.step = step
        emu.call(self.sym["Core.Init_Core"], max_steps=100_000)
        f7 = 0xF7 * PAGE_SIZE
        emu.mem.physical[f7 + 0x1FFC] = 0x42 if wc_path else 0x00
        if wc_path:
            emu.mem.physical[f7 + 0x2000:f7 + 0x2000 + len(wc_path)] = wc_path

    def call(self, name: str, **regs) -> None:
        self.emu.call(self.sym[name], max_steps=40_000_000, **regs)

    def cf(self) -> int:
        return self.emu.reg.F & 1


def check_boot(pak: bytes) -> list[str]:
    rig = Rig(build_card(pak, decoy=False), None)
    rig.call("Core.ProbeBootHobeta")
    errors = []
    if rig.emu.mem.read(rig.sym["Core.Boot_Found"]) != 1:
        errors.append("ProbeBootHobeta: Boot_Found != 1")
    p0, p1 = rig.sym["Core.QUIT_BOOT_PAGE0"], rig.sym["Core.QUIT_BOOT_PAGE1"]
    got = bytes(rig.emu.mem.physical[p0 * PAGE_SIZE:p0 * PAGE_SIZE + PAGE_SIZE]) + \
        bytes(rig.emu.mem.physical[p1 * PAGE_SIZE:p1 * PAGE_SIZE + BOOT_SIZE - PAGE_SIZE])
    if got != boot_bytes():
        errors.append("BOOT.$C в QUIT_BOOT_PAGE0/1 не совпал с файлом")
    print(f"boot: found={rig.emu.mem.read(rig.sym['Core.Boot_Found'])} "
          f"same={got == boot_bytes()} sector_reads={rig.reads}")
    return errors


def check_level(pak: bytes, decoy: bool, wc_path: bytes | None, label: str) -> list[str]:
    rig = Rig(build_card(pak, decoy), wc_path)
    emu, sym = rig.emu, rig.sym
    emu.mem.pages[3] = sym.get("Core.LOADER_OVL_PAGE", 0x40)
    errors = []
    rig.call("Core.ZiFi_Init")
    if not rig.cf():
        return [f"{label}: ZiFi_Init CF=0"]
    rig.call("Core.ZiFi_PakOpen")
    if not rig.cf():
        return [f"{label}: ZiFi_PakOpen CF=0"]
    rig.call("Core.ZiFi_PakReadToc", a=LEVEL)
    toc = bytes(emu.mem.read(sym["Core.ZiFi_LevelTOC"] + i) for i in range(20))
    want = pak[512 + LEVEL * 20:512 + LEVEL * 20 + 20]
    if not rig.cf() or toc != want:
        errors.append(f"{label}: TOC уровня {LEVEL + 1} не совпал (CF={rig.cf()})")
    bg_off = struct.unpack_from("<H", want, 0)[0]
    log = sym["Core.RawPak_LogCur"]
    emu.mem.write(log, bg_off & 0xFF)
    emu.mem.write(log + 1, bg_off >> 8)
    rig.call("Core.Fat_ReadSectors", b=32, c=0x07, h=0, l=0)
    page = bytes(emu.mem.physical[0x07 * PAGE_SIZE:0x08 * PAGE_SIZE])
    if rig.cf() or page != pak[bg_off * 512:bg_off * 512 + PAGE_SIZE]:
        errors.append(f"{label}: страница фона (Fat_ReadSectors) не совпала (CF={rig.cf()})")
    rig.call("Core.ZiFi_Done")
    print(f"{label}: toc_ok={toc == want} page_ok={page == pak[bg_off * 512:bg_off * 512 + PAGE_SIZE]} "
          f"sector_reads={rig.reads}")
    return errors


def main() -> int:
    pak = (ROOT / "Build" / "ZUMALVL.PAK").read_bytes()
    errors = check_boot(pak)
    errors += check_level(pak, True, b"1:\\Games\\Zuma Deluxe VDAC2\\\xFF", "путь WC + приманка")
    errors += check_level(pak, False, None, "обход дерева")
    for e in errors:
        print("FAIL:", e)
    if errors:
        return 1
    print("PASS: FAT32-драйвер: BOOT.$C для выхода в WC, путь WC, обход дерева, READ_AT")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
