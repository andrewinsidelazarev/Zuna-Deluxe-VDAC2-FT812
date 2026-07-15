#!/usr/bin/env python3
"""Z80 regression for recoverable SD/SPI session failures.

The public sector reader must retry protocol failures only after returning the
shared FT812/SD bus to a known state.  ZiFi_Init must also report a failed SD
readiness probe instead of unconditionally returning success.
"""

from __future__ import annotations

import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from zuma_full_z80_emulator import ZumaFullZ80Emulator  # noqa: E402


LOADER_PAGE = 0x40
SD_DATA = 0x57
SD_CONF = 0x77
SD_CMD0 = 0x40 + 0
SD_CMD8 = 0x40 + 8
SD_CMD12 = 0x40 + 12
SD_CMD13 = 0x40 + 13
SD_CMD16 = 0x40 + 16
SD_CMD55 = 0x40 + 55
SD_ACMD41 = 0x40 + 41
SD_CMD58 = 0x40 + 58


def ret_from_hook(emu: ZumaFullZ80Emulator, *, carry: bool) -> None:
    sp = emu.reg.SP
    ret = emu.mem.read(sp) | (emu.mem.read((sp + 1) & 0xFFFF) << 8)
    emu.reg.SP = (sp + 2) & 0xFFFF
    emu.reg.PC = ret
    if carry:
        emu.reg.F |= 0x01
    else:
        emu.reg.F &= ~0x01


def fresh() -> ZumaFullZ80Emulator:
    emu = ZumaFullZ80Emulator()
    emu.mem.pages[3] = LOADER_PAGE
    return emu


def set_lba_max(emu: ZumaFullZ80Emulator, value: int) -> None:
    addr = emu.sym["Core.sd_lba_max"]
    for index in range(4):
        emu.set_byte(addr + index, (value >> (8 * index)) & 0xFF)


def call_sector_with_hooks(
    once_results: list[bool], recovery_results: list[bool], *, lba: int = 7, lba_max: int = 0
) -> tuple[bool, int, int]:
    emu = fresh()
    sym = emu.sym
    set_lba_max(emu, lba_max)
    once_addr = sym["Core.sd_read_sector_once"]
    recovery_addr = sym["Core.sd_recover"]
    once_calls = 0
    recovery_calls = 0
    original_step = emu.step

    def hooked_step() -> int:
        nonlocal once_calls, recovery_calls
        if emu.reg.PC == once_addr:
            result = once_results[min(once_calls, len(once_results) - 1)]
            once_calls += 1
            ret_from_hook(emu, carry=result)
            return 0
        if emu.reg.PC == recovery_addr:
            result = recovery_results[min(recovery_calls, len(recovery_results) - 1)]
            recovery_calls += 1
            ret_from_hook(emu, carry=result)
            return 0
        return original_step()

    emu.step = hooked_step
    emu.call(
        sym["Core.sd_read_sector"],
        h=(lba >> 8) & 0xFF,
        l=lba & 0xFF,
        d=(lba >> 24) & 0xFF,
        e=(lba >> 16) & 0xFF,
        max_steps=1_000_000,
    )
    return bool(emu.reg.F & 0x01), once_calls, recovery_calls


def test_sector_retry_contract() -> bool:
    failed, reads, recoveries = call_sector_with_hooks(
        [True, True, False], [False, False]
    )
    ok = not failed and reads == 3 and recoveries == 2
    print(
        f"{'PASS' if ok else 'FAIL'}: transient sector errors recover: "
        f"CF={int(failed)} reads={reads} recoveries={recoveries}"
    )

    failed_all, reads_all, recoveries_all = call_sector_with_hooks(
        [True, True, True], [False, False]
    )
    ok_all = failed_all and reads_all == 3 and recoveries_all == 2
    print(
        f"{'PASS' if ok_all else 'FAIL'}: exhausted sector retries fail cleanly: "
        f"CF={int(failed_all)} reads={reads_all} recoveries={recoveries_all}"
    )

    failed_recovery, reads_recovery, recoveries_recovery = call_sector_with_hooks(
        [True], [True]
    )
    ok_recovery = failed_recovery and reads_recovery == 1 and recoveries_recovery == 1
    print(
        f"{'PASS' if ok_recovery else 'FAIL'}: failed recovery stops retries: "
        f"CF={int(failed_recovery)} reads={reads_recovery} recoveries={recoveries_recovery}"
    )

    failed_range, reads_range, recoveries_range = call_sector_with_hooks(
        [False], [False], lba=100, lba_max=100
    )
    ok_range = failed_range and reads_range == 0 and recoveries_range == 0
    print(
        f"{'PASS' if ok_range else 'FAIL'}: range guard never touches/retries SD: "
        f"CF={int(failed_range)} reads={reads_range} recoveries={recoveries_range}"
    )
    return ok and ok_all and ok_recovery and ok_range


def test_ready_but_stuck_requires_cmd12() -> bool:
    emu = fresh()
    sym = emu.sym
    once_addr = sym["Core.sd_read_sector_once"]
    probe_addr = sym["Core.sd_probe_command"]
    original_step = emu.step
    original_in = emu.in_port
    attempts: list[tuple[int, int, int]] = []

    emu.set_byte(sym["Core.sd_blkt"], 1)  # SDHC block-addressing must survive recovery.

    def ready_in(port: int) -> int:
        if (port & 0xFF) == SD_DATA:
            return 0xFF  # misleading ready: transfer still rejects CMD17 until CMD12.
        return original_in(port)

    def hooked_step() -> int:
        # Этот тест изолирует retry-контракт sector reader: первый CMD17 падает,
        # recovery обязан реально послать CMD12, после чего command-level probe
        # считается успешным. Электрические варианты probe (#FF/#00/OCR) ниже
        # проверяются отдельными protocol-level тестами без этого hook.
        if emu.reg.PC == probe_addr:
            saw_cmd12 = any(
                (port & 0xFF) == SD_DATA and value == SD_CMD12
                for port, value in emu.ports_out
            )
            ret_from_hook(emu, carry=not saw_cmd12)
            return 0
        if emu.reg.PC == once_addr:
            lba_bytes = bytes(emu.get_memory(sym["Core.sd_lba"], 4))
            lba = int.from_bytes(lba_bytes, "little")
            ix = emu.reg.IX & 0xFFFF if hasattr(emu.reg, "IX") else (
                (emu.reg.IXH << 8) | emu.reg.IXL
            )
            saw_cmd12 = any(
                (port & 0xFF) == SD_DATA and value == SD_CMD12
                for port, value in emu.ports_out
            )
            attempts.append((lba, ix, int(saw_cmd12)))
            ret_from_hook(emu, carry=not saw_cmd12)
            return 0
        return original_step()

    emu.in_port = ready_in
    emu.step = hooked_step
    emu.ports_out.clear()
    lba = 0x00123456
    dest = 0x8120
    emu.reg.IX = dest
    emu.call(
        sym["Core.sd_read_sector"],
        h=(lba >> 8) & 0xFF,
        l=lba & 0xFF,
        d=(lba >> 24) & 0xFF,
        e=(lba >> 16) & 0xFF,
        max_steps=500_000,
    )
    failed = bool(emu.reg.F & 0x01)
    blkt = emu.get_byte(sym["Core.sd_blkt"])
    ok = (
        not failed
        and attempts == [(lba, dest, 0), (lba, dest, 1)]
        and blkt == 1
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: ready-but-stuck sector requires CMD12: "
        f"CF={int(failed)} attempts={attempts} sd_blkt={blkt}"
    )
    return ok


def call_zifi_with_sd_init_result(init_failed: bool) -> bool:
    emu = fresh()
    sym = emu.sym
    sd_init = sym["Core.sd_init"]
    original_step = emu.step

    def hooked_step() -> int:
        if emu.reg.PC == sd_init:
            ret_from_hook(emu, carry=init_failed)
            return 0
        return original_step()

    emu.step = hooked_step
    emu.call(sym["Core.ZiFi_Init"], max_steps=100_000)
    return bool(emu.reg.F & 0x01)


def test_zifi_init_contract() -> bool:
    success_cf = call_zifi_with_sd_init_result(False)
    failure_cf = call_zifi_with_sd_init_result(True)
    ok = success_cf and not failure_cf
    print(
        f"{'PASS' if ok else 'FAIL'}: ZiFi_Init propagates SD readiness: "
        f"success_CF={int(success_cf)} failure_CF={int(failure_cf)}"
    )
    return ok


def call_sd_resp(response: int) -> tuple[bool, bool]:
    emu = fresh()
    sym = emu.sym

    def response_in(port: int) -> int:
        if (port & 0xFF) == SD_DATA:
            return response
        return 0xFF

    emu.in_port = response_in
    emu.call(sym["Core.sd_resp"], max_steps=200_000)
    return bool(emu.reg.F & 0x01), bool(emu.reg.F & 0x40)


def test_r1_contract() -> bool:
    ok_cf, ok_z = call_sd_resp(0x00)
    idle_cf, idle_z = call_sd_resp(0x01)
    no_response_cf, no_response_z = call_sd_resp(0xFF)
    ok = (
        not ok_cf
        and ok_z
        and not idle_cf
        and not idle_z
        and no_response_cf
        # При CF=1 флаг Z намеренно не является частью sd_resp-контракта.
    )
    print(
        f"{'PASS' if ok else 'FAIL'}: R1 contract distinguishes #00/#01/no-response: "
        f"r1_00=(CF={int(ok_cf)},Z={int(ok_z)}) "
        f"r1_01=(CF={int(idle_cf)},Z={int(idle_z)}) "
        f"none=(CF={int(no_response_cf)},Z={int(no_response_z)})"
    )
    return ok


def test_recovery_bus_sequence() -> bool:
    """Recovery must abort the inherited transfer, but #FF is not success.

    A permanently high MISO line is ambiguous: it can mean either ``ready`` or
    no card/no SPI response at all.  The old regression accidentally treated
    that electrical idle level as proof that recovery succeeded.  Keep the
    checks for deselect clocks, card selection and CMD12, but require CF=1
    until a real command response proves that the card is present.
    """

    emu = fresh()
    sym = emu.sym
    original_in = emu.in_port

    def ready_in(port: int) -> int:
        if (port & 0xFF) == SD_DATA:
            return 0xFF
        return original_in(port)

    emu.in_port = ready_in
    emu.ports_out.clear()
    emu.call(sym["Core.sd_recover"], max_steps=200_000)
    ready_failed = bool(emu.reg.F & 0x01)
    writes = [(port & 0xFF, value) for port, value in emu.ports_out]
    idle_ff = sum(1 for port, value in writes if port == SD_DATA and value == 0xFF)
    selected = (SD_CONF, 0x01) in writes
    aborted = (SD_DATA, SD_CMD12) in writes
    floating_ok = ready_failed and idle_ff >= 18 and selected and aborted
    print(
        f"{'PASS' if floating_ok else 'FAIL'}: post-error recovery aborts but rejects all-#FF: "
        f"CF={int(ready_failed)} ff_clocks={idle_ff} selected={selected} abort={aborted}"
    )

    emu = fresh()
    sym = emu.sym
    emu.in_port = ready_in
    emu.ports_out.clear()
    emu.call(sym["Core.sd_init"], max_steps=200_000)
    session_failed = bool(emu.reg.F & 0x01)
    writes = [(port & 0xFF, value) for port, value in emu.ports_out]
    session_aborted = (SD_DATA, SD_CMD12) in writes
    session_ok = session_failed and session_aborted
    print(
        f"{'PASS' if session_ok else 'FAIL'}: new SD session rejects all-#FF after CMD12: "
        f"CF={int(session_failed)} CMD12={session_aborted}"
    )

    emu = fresh()
    sym = emu.sym

    def busy_in(port: int) -> int:
        if (port & 0xFF) == SD_DATA:
            return 0x00
        return 0xFF

    emu.in_port = busy_in
    emu.ports_out.clear()
    emu.call(sym["Core.sd_recover"], max_steps=1_500_000)
    busy_failed = bool(emu.reg.F & 0x01)
    writes = [(port & 0xFF, value) for port, value in emu.ports_out]
    aborted = (SD_DATA, SD_CMD12) in writes
    busy_ok = busy_failed and aborted
    print(
        f"{'PASS' if busy_ok else 'FAIL'}: stuck-card recovery aborts then reports failure: "
        f"CF={int(busy_failed)} CMD12={aborted}"
    )
    return floating_ok and session_ok and busy_ok


def test_late_data_token_is_accepted() -> bool:
    """A valid data token arriving after 5000 idle bytes is still on time.

    CMD17 may answer with an arbitrary run of #FF bytes before its #FE start
    token.  Five thousand polls are deliberately beyond the current 4*256
    loop, but still represent only tens of milliseconds on the target and are
    comfortably inside the bounded timeout recovery is expected to provide.

    Calling ``sd_wait_token`` directly isolates the timeout contract from
    command framing, sector copying and CRC.  The first 5000 reads return #FF;
    the next read supplies the valid #FE token.  Success therefore requires
    CF=0 and proves the routine did not give up at the old 1024-poll limit.
    """

    emu = fresh()
    sym = emu.sym
    reads = 0

    def delayed_token(port: int) -> int:
        nonlocal reads
        if (port & 0xFF) != SD_DATA:
            return 0xFF
        reads += 1
        if reads <= 5000:
            return 0xFF
        return 0xFE

    emu.in_port = delayed_token
    emu.call(sym["Core.sd_wait_token"], max_steps=500_000)
    failed = bool(emu.reg.F & 0x01)
    ok = not failed and reads >= 5001
    print(
        f"{'PASS' if ok else 'FAIL'}: late CMD17 data token remains valid: "
        f"CF={int(failed)} reads={reads} token_after=5000"
    )
    return ok


def test_floating_bus_is_not_ready_card() -> bool:
    """A pulled-up/no-response MISO line must not pass as a recovered card.

    In SPI mode both a genuinely ready card and an absent/unresponsive card can
    yield 0xFF while no command response is being driven.  Therefore a plain
    busy-tail poll is insufficient proof of card presence: recovery must obtain
    a real R1 response to a harmless command before returning CF=0.
    """

    emu = fresh()
    sym = emu.sym

    def floating_miso(port: int) -> int:
        if (port & 0xFF) == SD_DATA:
            return 0xFF
        return 0xFF

    emu.in_port = floating_miso
    emu.ports_out.clear()
    emu.call(sym["Core.sd_recover"], max_steps=500_000)
    failed = bool(emu.reg.F & 0x01)
    commands = [
        value
        for port, value in emu.ports_out
        if (port & 0xFF) == SD_DATA and 0x40 <= value <= 0x7F
    ]
    ok = failed
    print(
        f"{'PASS' if ok else 'FAIL'}: all-#FF floating bus is not card-ready: "
        f"CF={int(failed)} command_bytes={[hex(value) for value in commands]}"
    )
    return ok


def _contains_subsequence(values: list[int], required: list[int]) -> bool:
    """Return True when required occurs in values in order, with retries allowed."""

    pos = 0
    for value in values:
        if pos < len(required) and value == required[pos]:
            pos += 1
    return pos == len(required)


def test_unresponsive_card_gets_full_spi_reinit() -> bool:
    """Recovery escalates from ignored abort/probe to bounded SD SPI init.

    The model starts with a floating MISO line: CMD12 and any pre-init presence
    probe receive no R1 at all.  It begins answering only to the standard reset
    sequence.  CMD0 enters idle, CMD8 validates the v2 voltage/check pattern,
    CMD55+ACMD41 leaves idle, and CMD58 reports OCR.CCS=1 (SDHC block mode).

    This is intentionally a protocol-level model rather than a hook on
    sd_read_sector_once.  Merely writing CMD12 is not accepted as recovery; the
    production code must observe real command responses and set sd_blkt from
    CMD58 before it may return CF=0.
    """

    emu = fresh()
    sym = emu.sym
    selected = False
    command_bytes: list[int] = []
    commands: list[int] = []
    response: list[int] = []
    initialized = False

    def queue_command_response(command_byte: int) -> None:
        nonlocal initialized
        command = command_byte & 0x3F
        commands.append(command)

        # The inherited transfer/card state ignores both CMD12 and any normal
        # pre-init probe.  A pulled-up MISO line therefore supplies only #FF.
        if command == (SD_CMD12 & 0x3F):
            return
        if command == (SD_CMD0 & 0x3F):
            response.append(0x01)  # entered SPI idle state
            initialized = False
            return
        if command == (SD_CMD8 & 0x3F):
            response.extend((0x01, 0x00, 0x00, 0x01, 0xAA))
            return
        if command == (SD_CMD55 & 0x3F):
            response.append(0x01 if not initialized else 0x00)
            return
        if command == (SD_ACMD41 & 0x3F):
            initialized = True
            response.append(0x00)
            return
        if command == (SD_CMD58 & 0x3F):
            if initialized:
                # R1=0 followed by OCR, transmitted MSB first.  OCR bit31
                # confirms power-up complete; bit30 (CCS) selects block mode.
                response.extend((0x00, 0xC0, 0x00, 0x00, 0x00))
            return
        if command == (SD_CMD13 & 0x3F) and initialized:
            response.extend((0x00, 0x00))  # R1 + second R2 status byte
            return
        if command == (SD_CMD16 & 0x3F) and initialized:
            response.append(0x00)

    def sd_out(port: int, value: int) -> None:
        nonlocal selected
        low = port & 0xFF
        value &= 0xFF
        if low == SD_CONF:
            selected = value == 0x01
            if not selected:
                command_bytes.clear()
            return
        if low != SD_DATA or not selected:
            return
        if not command_bytes:
            if value & 0xC0 != 0x40:
                return  # dummy clocks/data while no command is being framed
            command_bytes.append(value)
            return
        command_bytes.append(value)
        if len(command_bytes) == 6:
            queue_command_response(command_bytes[0])
            command_bytes.clear()

    def sd_in(port: int) -> int:
        if (port & 0xFF) != SD_DATA:
            return 0xFF
        if response:
            return response.pop(0)
        return 0xFF

    emu.out_port = sd_out
    emu.in_port = sd_in
    emu.set_byte(sym["Core.sd_blkt"], 0)
    emu.ports_out.clear()
    emu.call(sym["Core.sd_recover"], max_steps=2_000_000)

    failed = bool(emu.reg.F & 0x01)
    blkt = emu.get_byte(sym["Core.sd_blkt"])
    required = [0, 8, 55, 41, 58]
    sequence_ok = _contains_subsequence(commands, required)
    ok = not failed and initialized and blkt == 1 and sequence_ok
    print(
        f"{'PASS' if ok else 'FAIL'}: ignored abort escalates to full SD SPI init: "
        f"CF={int(failed)} initialized={int(initialized)} sd_blkt={blkt} "
        f"commands={commands} required={required}"
    )
    return ok


def main() -> int:
    required = {
        "Core.sd_read_sector_once",
        "Core.sd_recover",
        "Core.sd_read_sector",
        "Core.sd_wait_token",
        "Core.ZiFi_Init",
    }
    probe = fresh()
    missing = sorted(required.difference(probe.sym))
    if missing:
        print("FAIL: recovery symbols missing: " + ", ".join(missing))
        return 1

    # Build the tuple first so every independent contract reports its result;
    # short-circuiting with a chain of ``and`` would hide the second RED case.
    checks = (
        test_sector_retry_contract(),
        test_ready_but_stuck_requires_cmd12(),
        test_zifi_init_contract(),
        test_r1_contract(),
        test_recovery_bus_sequence(),
        test_late_data_token_is_accepted(),
        test_floating_bus_is_not_ready_card(),
        test_unresponsive_card_gets_full_spi_reinit(),
    )
    ok = all(checks)
    if ok:
        print("PASS: SD/SPI session recovery contract")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
