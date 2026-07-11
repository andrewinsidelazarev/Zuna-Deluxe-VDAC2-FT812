#!/usr/bin/env python3
"""Synchronize derived per-chain VDC cache bits after manual state restores."""
from __future__ import annotations


TOPOLOGY_DIRTY_MASK = 0xC0
SHOT2_MAYBE = 0x20


def sync_active_vdc_caches(sim) -> None:
    """Invalidate topology and exactly synchronize Shot2-maybe for the active chain."""
    sym = sim.sym
    slots_len = sim.get_byte(sym["Core.VDC_SlotsLen"])
    state_addr = sim.get_word(sym["Core.VDC_pSlots"]) - 1
    shot2_addr = sim.get_word(sym["Core.VDC_pShot2"])
    state = sim.get_byte(state_addr) | TOPOLOGY_DIRTY_MASK
    if any(sim.get_memory(shot2_addr, slots_len)):
        state |= SHOT2_MAYBE
    else:
        state &= ~SHOT2_MAYBE
    sim.set_byte(state_addr, state)
