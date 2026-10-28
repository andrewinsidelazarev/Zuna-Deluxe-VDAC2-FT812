#!/usr/bin/env python3
"""Клод: сборка закреплённого FAT32-драйвера для загрузчика игры.

Исходники драйвера лежат без изменений в Source/ThirdParty/FAT32 (коммит и
SHA-256 — в upstream.json). Скрипт сверяет их, копирует в Build/FAT32, собирает
штатным build.py драйвера и кладёт в Build/ образы, которые spgbld грузит в
страницы драйвера:
  Build/fat32.bin       — код драйвера (#4000..#7FFF, FAT_CODE_PAGE);
  Build/fat32-work.bin  — рабочая страница (#0000..#3FFF, FAT_WORK_PAGE) с портом
                          SD-ZC с #3900.
Адаптер игры — Source/ASM/fat32_adapter.asm.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "Source" / "ThirdParty" / "FAT32"
STAGE = ROOT / "Build" / "FAT32"
BUILD = ROOT / "Build"


def text_hash(path: Path) -> str:
    # Концы строк приводятся к LF: git с core.autocrlf отдаёт CRLF в рабочем дереве.
    return hashlib.sha256(path.read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def main() -> int:
    upstream = json.loads((VENDOR / "upstream.json").read_text(encoding="utf-8"))
    if STAGE.exists():
        shutil.rmtree(STAGE)
    STAGE.mkdir(parents=True)
    for rel, expected in upstream["sources"].items():
        source = VENDOR / rel
        if text_hash(source) != expected:
            raise SystemExit(f"Изменён закреплённый исходник FAT32-драйвера: {rel}")
        target = STAGE / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    env = os.environ.copy()
    env.setdefault("SJASMPLUS", r"E:\zx\z80\tsconf_project\exe\sjasmplus\sjasmplus.exe")
    result = subprocess.run([sys.executable, "build.py"], cwd=STAGE, env=env)
    if result.returncode:
        raise SystemExit(f"Сборка FAT32-драйвера не прошла: код {result.returncode}")
    for name in ("fat32.bin", "fat32-work.bin"):
        shutil.copy2(STAGE / "build" / name, BUILD / name)
    shutil.copy2(STAGE / "build" / "manifest.json", BUILD / "fat32-manifest.json")
    code = (BUILD / "fat32.bin").stat().st_size
    print(f"FAT32-драйвер {upstream['commit'][:7]}: fat32.bin {code} байт, fat32-work.bin 16384 байт")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
