#!/usr/bin/env python3
import argparse
import re
from pathlib import Path


NAMES = [
    "Core.VDC_AssertCode",
    "Core.VDC_AssertCtx",
    "Core.VDC_AssertLen",
    "Core.VDC_AssertHSA",
    "Core.VDC_AssertValue",
    "Core.VDC_AssertFrame",
]

CODE_TEXT = {
    0: "OK",
    1: "SlotsLen > VDC_MAX_SLOTS",
    2: "HSA > TrackNumSlots",
    3: "Slots[i] is neither color nor GAP marker",
    4: "Offsets[i] outside [-CELL_SIZE..CELL_SIZE]",
    5: "ExplodeFrame[i] has invalid ExplodeMarker",
    6: "Shot2[i] is not 0/1",
}


def load_symbols(path: Path) -> dict[str, int]:
    rx = re.compile(r"^(Core\.VDC_Assert(?:Code|Ctx|Len|HSA|Value|Frame)):\s+EQU\s+0x([0-9A-Fa-f]+)")
    out: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = rx.match(line.strip())
        if m:
            out[m.group(1)] = int(m.group(2), 16)
    missing = [name for name in NAMES if name not in out]
    if missing:
        raise SystemExit(f"missing symbols: {', '.join(missing)}")
    return out


def read_byte(data: bytes, addr: int) -> int:
    if addr >= len(data):
        raise SystemExit(f"dump too small for address 0x{addr:04X}: size={len(data)}")
    return data[addr]


def main() -> None:
    ap = argparse.ArgumentParser(description="Decode VDC_Assert* bytes from a Zuma memory dump.")
    ap.add_argument("dump", type=Path, help="raw memory dump, for example 111")
    ap.add_argument("--sym", type=Path, default=Path("Build/zuma.sym"))
    args = ap.parse_args()

    sym = load_symbols(args.sym)
    data = args.dump.read_bytes()

    code = read_byte(data, sym["Core.VDC_AssertCode"])
    ctx = read_byte(data, sym["Core.VDC_AssertCtx"])
    length = read_byte(data, sym["Core.VDC_AssertLen"])
    hsa = read_byte(data, sym["Core.VDC_AssertHSA"])
    value = read_byte(data, sym["Core.VDC_AssertValue"])
    frame_addr = sym["Core.VDC_AssertFrame"]
    frame = read_byte(data, frame_addr) | (read_byte(data, frame_addr + 1) << 8)

    print(f"code={code} ({CODE_TEXT.get(code, 'unknown')})")
    print(f"ctx={ctx} len={length} hsa={hsa} value=0x{value:02X} frame={frame}")
    print(
        "addresses: "
        f"code=0x{sym['Core.VDC_AssertCode']:04X} "
        f"ctx=0x{sym['Core.VDC_AssertCtx']:04X} "
        f"len=0x{sym['Core.VDC_AssertLen']:04X} "
        f"hsa=0x{sym['Core.VDC_AssertHSA']:04X} "
        f"value=0x{sym['Core.VDC_AssertValue']:04X} "
        f"frame=0x{sym['Core.VDC_AssertFrame']:04X}"
    )


if __name__ == "__main__":
    main()
