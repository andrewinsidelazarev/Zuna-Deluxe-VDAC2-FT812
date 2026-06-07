from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PAK = ROOT / "Build" / "ZUMAAUD.PAK"
PAGE_BASE = 0xA8
FULL_SECS = 1566
TAIL_BYTES = 344
SECTOR = 512
PAGE_SIZE = 16 * 1024
SECTORS_PER_PAGE = 32


def emulate_cache_current_bug(data: bytes) -> bytearray:
    """Model the current asm intent, but with B clobbered by RawPak_ReadOneLogicalIX.

    In the current asm, B is used as a 32-sector page counter. RawPak_ReadOneLogicalIX
    also uses B internally for RawPak_RunCount and does not preserve it. The exact
    final B depends on the run table; with a single contiguous run it becomes 0 after
    the scan DJNZ. That makes the caller's DJNZ run 256 iterations instead of 32.
    """
    ram = bytearray(PAGE_SIZE * 80)
    lost_writes = 0
    left = (len(data) + SECTOR - 1) // SECTOR
    log = 0
    page = PAGE_BASE
    while left:
        ix = 0x8000
        b = SECTORS_PER_PAGE
        while True:
            if left == 0:
                break
            start = log * SECTOR
            chunk = data[start:start + SECTOR]
            if 0x8000 <= ix <= 0xBE00:
                page_off = (page - PAGE_BASE) * PAGE_SIZE
                dst = page_off + (ix - 0x8000)
                ram[dst:dst + len(chunk)] = chunk
            else:
                lost_writes += 1
            log += 1
            ix = (ix + SECTOR) & 0xFFFF
            left -= 1

            b = 0  # RawPak_ReadOneLogicalIX clobbers B to 0 for a one-run file.
            b = (b - 1) & 0xFF  # caller DJNZ
            if b != 0:
                continue
            break
        page += 1
    print(f"current_bug_lost_or_wrong_slot_sectors={lost_writes}")
    return ram


def emulate_cache_fixed(data: bytes) -> bytearray:
    ram = bytearray(PAGE_SIZE * 80)
    left = (len(data) + SECTOR - 1) // SECTOR
    log = 0
    page = PAGE_BASE
    while left:
        page_off = (page - PAGE_BASE) * PAGE_SIZE
        ix = 0x8000
        for _ in range(SECTORS_PER_PAGE):
            if left == 0:
                break
            start = log * SECTOR
            chunk = data[start:start + SECTOR]
            dst = page_off + (ix - 0x8000)
            ram[dst:dst + len(chunk)] = chunk
            log += 1
            ix = (ix + SECTOR) & 0xFFFF
            left -= 1
        page += 1
    return ram


def stream_from_cache(ram: bytearray) -> bytes:
    out = bytearray()
    page = PAGE_BASE
    pos = 0
    for _ in range(FULL_SECS):
        off = (page - PAGE_BASE) * PAGE_SIZE + pos
        out += ram[off:off + SECTOR]
        pos += SECTOR
        if pos == PAGE_SIZE:
            page += 1
            pos = 0
    off = (page - PAGE_BASE) * PAGE_SIZE + pos
    out += ram[off:off + TAIL_BYTES]
    return bytes(out)


def first_diff(a: bytes, b: bytes) -> int | None:
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return None if len(a) == len(b) else n


def main() -> int:
    data = PAK.read_bytes()
    assert len(data) == FULL_SECS * SECTOR + TAIL_BYTES

    bug_stream = stream_from_cache(emulate_cache_current_bug(data))
    bug_diff = first_diff(data, bug_stream)
    print(f"current_bug_stream_len={len(bug_stream)} diff={bug_diff}")
    if bug_diff is not None:
        print(f"expected[{bug_diff}:{bug_diff+16}]={data[bug_diff:bug_diff+16].hex()}")
        print(f"actual  [{bug_diff}:{bug_diff+16}]={bug_stream[bug_diff:bug_diff+16].hex()}")

    fixed_stream = stream_from_cache(emulate_cache_fixed(data))
    fixed_diff = first_diff(data, fixed_stream)
    print(f"fixed_stream_len={len(fixed_stream)} diff={fixed_diff}")
    return 0 if fixed_diff is None and bug_diff is not None else 1


if __name__ == "__main__":
    raise SystemExit(main())
