#!/usr/bin/env python3
"""Побайтовая проверка быстрого сборщика кеша стабильной цепочки L19."""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from make_level_pack import encode_track_v4_record  # noqa: E402
from zuma_full_z80_emulator import PAGE_SIZE, ZumaFullZ80Emulator  # noqa: E402

ROOT = HERE.parent.parent
CACHE = 0x4100
CACHE2 = 0x4640
CACHE_FILL = 0xCC
CMD = 0x4CB0
SPLIT_LANE_BYTES = 96 * 6
TRACK_PAGES = (0x09, 0x06, 0x0B, 0x07)


def make_record(sample: int, *, invisible: bool = False) -> bytes:
    """Создать различимую запись Track V4 для заданного абсолютного сэмпла."""
    vx = 20000 if invisible else 320 + (sample % 500)
    vy = 240 + (sample % 300)
    tangent = (sample * 37 + 11) & 0xFF
    flags = (sample >> 5) & 0x83
    spin = (sample * 61 // 256) % 12
    return encode_track_v4_record(vx, vy, tangent, flags, spin)


def install_records(
    emu: ZumaFullZ80Emulator, records: dict[int, bytes]
) -> None:
    """Разложить абсолютные сэмплы по четырём реальным страницам трека."""
    sym = emu.sym
    for page in TRACK_PAGES:
        start = page * PAGE_SIZE
        emu.mem.physical[start : start + PAGE_SIZE] = bytes(PAGE_SIZE)
    for sample, record in records.items():
        page_index, local_sample = divmod(sample, PAGE_SIZE // 8)
        page = TRACK_PAGES[page_index]
        start = page * PAGE_SIZE + local_sample * 8
        emu.mem.physical[start : start + 8] = record
    for index, page in enumerate(TRACK_PAGES):
        emu.set_byte(sym["Core.VDC_TrackPages1"] + index, page)
    emu.set_word(sym["Core.VDC_pTrackPages"], sym["Core.VDC_TrackPages1"])
    emu.mem.pages = [0x00, 0x05, TRACK_PAGES[0], 0x04]


def expected_entry(color: int, record: bytes) -> bytes:
    """Вычислить семибайтную запись кеша без обращения к Z80-коду."""
    if not (record[7] & 1):
        return bytes((0, 0xFF)) + bytes((CACHE_FILL,)) * 5
    tangent = (record[4] + 0x20) & 0xC0
    cell = color * 12 + record[6]
    return bytes((tangent, cell)) + record[:4] + bytes((record[5],))


def expected_split_entry(color: int, record: bytes) -> bytes | None:
    """Вернуть компактную запись либо None для заранее отсечённой точки."""
    if not (record[7] & 1):
        return None
    tangent = (record[4] + 0x20) & 0xC0
    cell = color * 12 + record[6]
    return bytes((tangent, cell)) + record[:4]


def render_pass(
    source: ZumaFullZ80Emulator,
    *,
    cache: int,
    ball_count: int,
    pass_id: int,
    start_ptr: int = CMD,
) -> tuple[bytes, int, int]:
    """Отрисовать одну полосу и вернуть точный CMD, касательную и carry."""
    emu = ZumaFullZ80Emulator(ROOT)
    emu.mem.physical[:] = source.mem.physical
    emu.mem.pages[:] = source.mem.pages
    sym = emu.sym
    emu.set_word(sym["FT.Coprocessor.BufferPtr"], start_ptr)
    emu.set_word(sym["Core.ZL_CacheBasePtr"], cache)
    emu.set_byte(sym["Core.ZL_BallCount"], ball_count)
    emu.set_byte(sym["Core.ZL_ChainDrawPass"], pass_id)
    emu.set_byte(sym["Core.VDC_ExplodeActive"], 0)
    emu.set_byte(sym["Core.ZL_BallRotationDisabled"], 0)
    emu.set_byte(sym["Core.VDC_GameState"], 0)
    target = (
        "Core.ZL_DrawCachedActiveChainTopMaskFastUnder"
        if pass_id == 1
        else "Core.ZL_DrawCachedActiveChainTopMaskFastOver"
    )
    emu.call(sym[target], max_steps=1_000_000)
    end = emu.get_word(sym["FT.Coprocessor.BufferPtr"])
    size = (end - CMD) & 0xFFFF
    return (
        bytes(emu.get_memory(CMD, size)),
        emu.get_byte(sym["Core.ZL_TmpLastTangent"]),
        emu.reg.F & 1,
    )


def run_case(name: str, *, hsa: int, hsub: int, second_active: int) -> None:
    """Проверить кеш, WIN-снимок и переход между страницами одной цепочки."""
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    cache = CACHE2 if second_active else CACHE
    slots_len = hsa + 1
    first_sample = hsa * 32 + hsub
    samples = [first_sample - index * 32 for index in range(slots_len)]
    records = {
        sample: make_record(sample, invisible=index in (9, 37, 68))
        for index, sample in enumerate(samples)
    }
    install_records(emu, records)

    slots = [index % 6 for index in range(slots_len)]
    emu.set_word(sym["Core.VDC_pSlots"], sym["Core.VDC_Slots"])
    emu.set_word(sym["Core.VDC_pOffsets"], sym["Core.VDC_Offsets"])
    emu.set_byte(sym["Core.VDC_SlotsLen"], slots_len)
    emu.set_byte(sym["Core.VDC_HSA"], hsa)
    emu.set_byte(sym["Core.VDC_HSub"], hsub)
    emu.set_word(sym["Core.VDC_ActiveTrackSamples"], first_sample + 1)
    emu.set_byte(sym["Core.VDC_HasSecondChain"], 1)
    emu.set_byte(sym["Core.VDC_GameState"], 0)
    emu.set_byte(sym["Core.VDC_SecondActive"], second_active)
    emu.set_byte(sym["Core.CurrentLevel"], 18)
    emu.set_word(sym["Core.ZL_CacheBasePtr"], cache)
    emu.set_byte(sym["Core.ZL_L19SplitBuildMode"], 1)
    emu.set_byte(sym["Core.VDC_RenderTrackPageIdx"], 0xFF)
    for index, color in enumerate(slots):
        emu.set_byte(sym["Core.VDC_Slots"] + index, color)
        emu.set_byte(sym["Core.VDC_Offsets"] + index, 0)
    for index in range(slots_len * 7):
        emu.mem.write(cache + index, CACHE_FILL)

    expected = b"".join(
        expected_entry(color, records[sample])
        for color, sample in zip(slots, samples, strict=True)
    )
    expected_under_parts: list[bytes] = []
    expected_over_parts: list[bytes] = []
    for color, sample in zip(slots, samples, strict=True):
        record = records[sample]
        entry = expected_split_entry(color, record)
        if entry is None:
            continue
        flags_class = record[5] & 3
        if flags_class == 2:
            expected_over_parts.append(entry)
        else:
            expected_under_parts.append(entry)
    expected_under = b"".join(expected_under_parts)
    expected_over = b"".join(expected_over_parts)

    generic = ZumaFullZ80Emulator(ROOT)
    generic.mem.physical[:] = emu.mem.physical
    generic.mem.pages[:] = emu.mem.pages
    generic.set_byte(sym["Core.ZL_BallCount"], slots_len)
    generic_start = generic.tstates
    generic.call(
        sym["Core.ZL_BuildActiveChainCacheGenericNonEmpty"],
        a=slots_len,
        max_steps=1_000_000,
    )
    generic_elapsed = generic.tstates - generic_start
    generic_cache = bytes(generic.get_memory(cache, len(expected)))
    if generic_cache != expected:
        raise AssertionError(f"{name}: общий сборщик не совпал с независимым oracle")

    start_tstates = emu.tstates
    emu.call(sym["Core.ZL_BuildActiveChainCache"], max_steps=1_000_000)
    elapsed = emu.tstates - start_tstates
    actual_under = bytes(emu.get_memory(cache, len(expected_under)))
    actual_over = bytes(
        emu.get_memory(cache + SPLIT_LANE_BYTES, len(expected_over))
    )
    if actual_under != expected_under:
        raise AssertionError(f"{name}: нижняя компактная полоса отличается")
    if actual_over != expected_over:
        raise AssertionError(f"{name}: верхняя компактная полоса отличается")
    if not (emu.reg.F & 1):
        raise AssertionError(f"{name}: быстрый путь не подтвердил обработку")
    suffix = "2" if second_active else "1"
    if emu.get_byte(sym[f"Core.ZL_L19CacheSplit{suffix}"]) != 1:
        raise AssertionError(f"{name}: не установлен признак компактного кеша")
    if emu.get_byte(sym[f"Core.ZL_L19CacheUnder{suffix}"]) != len(expected_under_parts):
        raise AssertionError(f"{name}: неверно число нижних записей")
    if emu.get_byte(sym[f"Core.ZL_L19CacheOver{suffix}"]) != len(expected_over_parts):
        raise AssertionError(f"{name}: неверно число верхних записей")
    head_name = "Core.VDC_WinHeadS2" if second_active else "Core.VDC_WinHeadS1"
    if emu.get_word(sym[head_name]) != first_sample:
        raise AssertionError(
            f"{name}: WIN head={emu.get_word(sym[head_name]):#06x}, "
            f"ожидалось {first_sample:#06x}"
        )
    final_page_index = samples[-1] // (PAGE_SIZE // 8)
    if emu.get_byte(sym["Core.VDC_RenderTrackPageIdx"]) != final_page_index:
        raise AssertionError(f"{name}: неверный итоговый индекс страницы")
    if emu.mem.pages[2] != TRACK_PAGES[final_page_index]:
        raise AssertionError(f"{name}: неверная физическая страница в окне #8000")
    if generic.get_word(sym[head_name]) != first_sample:
        raise AssertionError(f"{name}: общий сборщик дал другой WIN head")
    if generic.get_byte(sym["Core.VDC_RenderTrackPageIdx"]) != final_page_index:
        raise AssertionError(f"{name}: общий сборщик завершился на другой странице")
    generic.set_byte(
        sym["Core.ZL_L19CacheSplit2" if second_active else "Core.ZL_L19CacheSplit1"],
        0,
    )
    for pass_id in (1, 2):
        generic_draw = render_pass(
            generic, cache=cache, ball_count=slots_len, pass_id=pass_id
        )
        split_draw = render_pass(
            emu, cache=cache, ball_count=slots_len, pass_id=pass_id
        )
        if split_draw != generic_draw:
            raise AssertionError(
                f"{name}: CMD/касательная/carry прохода {pass_id} отличаются"
            )
    generic_pressure = render_pass(
        generic, cache=cache, ball_count=slots_len, pass_id=1, start_ptr=0x5800
    )
    split_pressure = render_pass(
        emu, cache=cache, ball_count=slots_len, pass_id=1, start_ptr=0x5800
    )
    if split_pressure != generic_pressure:
        raise AssertionError(f"{name}: CMD после pressure flush отличается")
    print(
        f"PASS: {name}: fast={elapsed} T, generic={generic_elapsed} T, "
        "кеш/WIN/page/CMD точны"
    )


def check_reject(name: str, mutation: str) -> None:
    """Доказать, что неподходящее состояние отклоняется до записи результата."""
    emu = ZumaFullZ80Emulator(ROOT)
    sym = emu.sym
    hsa = 3
    hsub = 0
    slots_len = hsa + 1
    first_sample = hsa * 32 + hsub
    samples = [first_sample - index * 32 for index in range(slots_len)]
    install_records(emu, {sample: make_record(sample) for sample in samples})
    emu.set_word(sym["Core.VDC_pSlots"], sym["Core.VDC_Slots"])
    emu.set_word(sym["Core.VDC_pOffsets"], sym["Core.VDC_Offsets"])
    emu.set_byte(sym["Core.VDC_SlotsLen"], slots_len)
    emu.set_byte(sym["Core.VDC_HSA"], hsa)
    emu.set_byte(sym["Core.VDC_HSub"], hsub)
    emu.set_word(sym["Core.VDC_ActiveTrackSamples"], first_sample + 1)
    emu.set_byte(sym["Core.VDC_HasSecondChain"], 1)
    emu.set_byte(sym["Core.VDC_GameState"], 0)
    emu.set_byte(sym["Core.VDC_SecondActive"], 0)
    emu.set_byte(sym["Core.CurrentLevel"], 18)
    emu.set_word(sym["Core.ZL_CacheBasePtr"], CACHE)
    emu.set_byte(sym["Core.ZL_L19SplitBuildMode"], 1)
    emu.set_word(sym["Core.VDC_WinHeadS1"], 0xA55A)
    emu.set_word(sym["Core.VDC_WinHeadS2"], 0x5AA5)
    emu.set_byte(sym["Core.VDC_RenderTrackPageIdx"], 0xA5)
    for index in range(slots_len):
        emu.set_byte(sym["Core.VDC_Slots"] + index, index % 6)
        emu.set_byte(sym["Core.VDC_Offsets"] + index, 0)
    for index in range(slots_len * 7):
        emu.mem.write(CACHE + index, (0x80 + index) & 0xFF)

    if mutation == "gap":
        emu.set_byte(sym["Core.VDC_Slots"] + 1, 0xFE)
    elif mutation.startswith("offset="):
        emu.set_byte(sym["Core.VDC_Offsets"] + 2, int(mutation[7:]) & 0xFF)
    elif mutation == "length":
        emu.set_byte(sym["Core.VDC_HSA"], hsa - 1)
    elif mutation == "capacity":
        emu.set_byte(sym["Core.VDC_HSA"], 96)
        emu.set_byte(sym["Core.VDC_SlotsLen"], 97)
    elif mutation == "state":
        emu.set_byte(sym["Core.VDC_GameState"], 1)
    elif mutation == "explode1":
        emu.set_byte(sym["Core.VDC_ExplodeActive"], 1)
    elif mutation == "explode2":
        emu.set_byte(sym["Core.VDC_SecondActive"], 1)
        explode2 = sym["Core.VDC2_ChainLocal"] + (
            sym["Core.VDC_ExplodeActive"] - sym["Core.VDC_ChainLocalStart"]
        )
        emu.set_byte(explode2, 1)
    elif mutation == "level":
        emu.set_byte(sym["Core.CurrentLevel"], 17)
    elif mutation == "single":
        emu.set_byte(sym["Core.VDC_HasSecondChain"], 0)
    elif mutation == "clamp":
        emu.set_word(sym["Core.VDC_ActiveTrackSamples"], first_sample)
    elif mutation == "topmask":
        emu.call(sym["Core.ZL_GetTopMaskForCurrentLevel"], max_steps=100_000)
        table_entry = (emu.reg.H << 8) | emu.reg.L
        emu.mem.write(table_entry, 0)
    else:
        raise AssertionError(f"неизвестная мутация {mutation}")

    before = (
        bytes(emu.get_memory(CACHE, slots_len * 7)),
        emu.get_word(sym["Core.VDC_WinHeadS1"]),
        emu.get_word(sym["Core.VDC_WinHeadS2"]),
        emu.get_byte(sym["Core.VDC_RenderTrackPageIdx"]),
        emu.mem.pages[2],
    )
    emu.call(sym["Core.ZL_BuildActiveChainCacheFastL19Maybe"], max_steps=100_000)
    after = (
        bytes(emu.get_memory(CACHE, slots_len * 7)),
        emu.get_word(sym["Core.VDC_WinHeadS1"]),
        emu.get_word(sym["Core.VDC_WinHeadS2"]),
        emu.get_byte(sym["Core.VDC_RenderTrackPageIdx"]),
        emu.mem.pages[2],
    )
    if emu.reg.F & 1:
        raise AssertionError(f"{name}: быстрый путь ошибочно принял состояние")
    if after != before:
        raise AssertionError(f"{name}: отказ изменил кеш, WIN или страницу")
    print(f"PASS: отказ без побочных эффектов — {name}")


def main() -> int:
    run_case("t0=2047, младший байт #F8", hsa=63, hsub=31, second_active=0)
    run_case("t0=2048, точная граница", hsa=64, hsub=0, second_active=1)
    run_case("t0=2079, младший байт #F8", hsa=64, hsub=31, second_active=0)
    run_case("профильные 70 шаров", hsa=69, hsub=17, second_active=0)
    for name, mutation in (
        ("разрыв", "gap"),
        ("offset +1", "offset=1"),
        ("offset -1", "offset=-1"),
        ("offset -128", "offset=-128"),
        ("offset +127", "offset=127"),
        ("длина не равна HSA+1", "length"),
        ("превышена ёмкость полосы", "capacity"),
        ("состояние не PLAY", "state"),
        ("анимация взрыва цепочки 1", "explode1"),
        ("анимация взрыва цепочки 2", "explode2"),
        ("другой уровень", "level"),
        ("одна цепочка", "single"),
        ("требуется clamp", "clamp"),
        ("нет верхней маски", "topmask"),
    ):
        check_reject(name, mutation)
    print("PASS: быстрый сборщик L19 побайтово совпадает с форматом кеша")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
