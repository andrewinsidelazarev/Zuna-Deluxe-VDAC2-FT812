from pathlib import Path

SRC = Path("zuma_new.xm")
OUT = Path("zuma_gs4_1mb_orderfix.mod")
REAL_ORDER_COUNT = 24
NOTE_SHIFT = 0
DOWNSAMPLE = 1
PER_INSTR_DOWNSAMPLE = {
    8: 2,
    9: 2,
    10: 2,
    11: 2,
    12: 2,
    13: 2,
    14: 2,
}

PERIODS = [
    856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
    428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
    214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
    107, 101, 95, 90, 85, 80, 75, 71, 67, 63, 60, 56,
]

COMPOSITES = {
    2: (15, 15, 15),
    3: (16, 16, 16),
    # Extra 700K background composites. These replace common stacks that
    # previously competed for the four MOD channels.
    27: (8, 8, 8, 12, 12),
    28: (8, 9, 12, 12),
    29: (4, 23),
    30: (6, 6, 6),
    31: (21, 21, 21),
}

VOICE = {6, 20, 21, 22, 23, 24}
BASS = {2, 3, 15, 16}
MELODY = {1, 4, 5, 7, 17, 18, 19, 25, 26}
FLUTE_LIKE = {4, 5, 7, 17, 18, 19, 29}
BAD_FLUTE_INTERVALS = {1, 2, 6, 10, 11}


def sx(v):
    return v - 256 if v >= 128 else v


def xm_string(raw):
    text = raw.split(b"\0", 1)[0].decode("cp1251", "replace").strip()
    table = str.maketrans({
        "А": "A", "Б": "B", "В": "V", "Г": "G", "Д": "D", "Е": "E", "Ё": "E", "Ж": "Zh", "З": "Z",
        "И": "I", "Й": "Y", "К": "K", "Л": "L", "М": "M", "Н": "N", "О": "O", "П": "P", "Р": "R",
        "С": "S", "Т": "T", "У": "U", "Ф": "F", "Х": "Kh", "Ц": "Ts", "Ч": "Ch", "Ш": "Sh",
        "Щ": "Sch", "Ъ": "", "Ы": "Y", "Ь": "", "Э": "E", "Ю": "Yu", "Я": "Ya",
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z",
        "и": "i", "й": "y", "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh",
        "щ": "sch", "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    })
    return text.translate(table).encode("ascii", "ignore")[:22]


def decode_xm_sample(raw, is16):
    out = []
    acc = 0
    if is16:
        for i in range(0, len(raw), 2):
            acc = (acc + int.from_bytes(raw[i:i + 2], "little", signed=True)) & 0xFFFF
            v = acc - 0x10000 if acc & 0x8000 else acc
            out.append(v)
    else:
        for x in raw:
            acc = (acc + sx(x)) & 0xFF
            out.append((acc - 256 if acc >= 128 else acc) << 8)
    return out


def downsample_to_s8(pcm16, factor=2):
    out = bytearray()
    for i in range(0, len(pcm16), factor):
        block = pcm16[i:i + factor]
        if not block:
            break
        out.append((sum(block) // len(block) >> 8) & 0xFF)
    if len(out) & 1:
        out.append(0)
    return bytes(out)


def downsample_pitch_compensation(factor):
    # Halving sample data length must be compensated by playing it an octave lower.
    if factor == 1:
        return 0
    if factor == 2:
        return -12
    if factor == 4:
        return -24
    return 0


def s8_to_i16(data):
    return [sx(v) << 8 for v in data]


def mix_s8_samples(parts):
    decoded = [s8_to_i16(p) for p in parts if p]
    if not decoded:
        return b""
    length = max(len(p) for p in decoded)
    out = bytearray()
    # Keep a little headroom: these composites replace stacked channels.
    gain = 0.85 / max(1, len(decoded) ** 0.5)
    for i in range(length):
        v = 0
        for p in decoded:
            if i < len(p):
                v += p[i]
        v = max(-32768, min(32767, int(v * gain)))
        out.append((v >> 8) & 0xFF)
    if len(out) & 1:
        out.append(0)
    return bytes(out)


def read_xm():
    b = SRC.read_bytes()
    if b[:17] != b"Extended Module: ":
        raise SystemExit("not XM")
    hsize = int.from_bytes(b[60:64], "little")
    song_len = int.from_bytes(b[64:66], "little")
    channels = int.from_bytes(b[68:70], "little")
    pat_count = int.from_bytes(b[70:72], "little")
    inst_count = int.from_bytes(b[72:74], "little")
    speed = int.from_bytes(b[76:78], "little") or 6
    orders = list(b[80:80 + song_len])

    pos = 60 + hsize
    patterns = []
    for _ in range(pat_count):
        ph = int.from_bytes(b[pos:pos + 4], "little")
        rows = int.from_bytes(b[pos + 5:pos + 7], "little")
        plen = int.from_bytes(b[pos + 7:pos + 9], "little")
        data = b[pos + ph:pos + ph + plen]
        pos += ph + plen
        k = 0
        rows_events = [[] for _ in range(64)]
        for row in range(rows):
            for ch in range(channels):
                first = data[k]
                k += 1
                note = ins = vol = 0
                if first & 0x80:
                    if first & 1:
                        note = data[k]
                        k += 1
                    if first & 2:
                        ins = data[k]
                        k += 1
                    if first & 4:
                        vol = data[k]
                        k += 1
                    if first & 8:
                        k += 1
                    if first & 16:
                        k += 1
                else:
                    note = first
                    ins = data[k]
                    vol = data[k + 1]
                    k += 4
                if row < 64 and ins and note and note < 97:
                    rows_events[row].append((ch, note, ins, vol))
        patterns.append(rows_events)

    instruments = []
    sample_data = []
    for ii in range(1, 32):
        if ii > inst_count:
            instruments.append((b"", 0, 0, 0, 1, 0, 1))
            sample_data.append(b"")
            continue
        ih = int.from_bytes(b[pos:pos + 4], "little")
        name = xm_string(b[pos + 4:pos + 26])
        ns = int.from_bytes(b[pos + 27:pos + 29], "little")
        pos += ih
        if not ns:
            instruments.append((name, 0, 0, 0, 1, 0, 1))
            sample_data.append(b"")
            continue
        sh = pos
        slen = int.from_bytes(b[sh:sh + 4], "little")
        loop_start = int.from_bytes(b[sh + 4:sh + 8], "little")
        loop_len = int.from_bytes(b[sh + 8:sh + 12], "little")
        volume = min(b[sh + 12], 64)
        typ = b[sh + 14]
        rel_note = sx(b[sh + 16])
        is16 = bool(typ & 0x10)
        pos += ns * 40
        raw = b[pos:pos + slen]
        pos += slen
        pcm = decode_xm_sample(raw, is16)
        ds = PER_INSTR_DOWNSAMPLE.get(ii, DOWNSAMPLE)
        data8 = downsample_to_s8(pcm, ds)
        frame_div = (2 if is16 else 1) * ds
        ls = loop_start // frame_div
        ll = loop_len // frame_div
        if not (typ & 3) or ll < 2:
            ls, ll = 0, 2
        instruments.append((name, len(data8), volume, ls, max(1, ll), rel_note, ds))
        sample_data.append(data8)
    for slot, source_slots in COMPOSITES.items():
        parts = [sample_data[i - 1] for i in source_slots]
        data = mix_s8_samples(parts)
        source_rels = [instruments[i - 1][5] for i in source_slots]
        source_ds = [instruments[i - 1][6] for i in source_slots]
        instruments[slot - 1] = (
            f"C{source_slots[0]:02d}x{len(source_slots)}".encode("ascii"),
            len(data),
            64,
            0,
            1,
            round(sum(source_rels) / len(source_rels)),
            max(source_ds),
        )
        sample_data[slot - 1] = data

    bpm = int.from_bytes(b[78:80], "little") or 125
    return song_len, orders, speed, bpm, patterns, instruments, sample_data


def apply_composites(evs):
    remaining = list(evs)
    added = []
    for slot, source_slots in COMPOSITES.items():
        needed = list(source_slots)
        by_note = {}
        for idx, ev in enumerate(remaining):
            _ch, note, ins, _vol = ev
            if ins in needed:
                by_note.setdefault(note, []).append(idx)
        for note, idxs in by_note.items():
            selected = []
            used = set()
            for src in needed:
                for idx in idxs:
                    if idx not in used and remaining[idx][2] == src:
                        selected.append(idx)
                        used.add(idx)
                        break
            if len(selected) == len(needed):
                vols = [remaining[i][3] or 64 for i in selected]
                added.append((min(remaining[i][0] for i in selected), note, slot, max(vols)))
                for i in selected:
                    remaining[i] = None
        remaining = [ev for ev in remaining if ev is not None]
    return remaining + added


def priority(ev):
    ch, _note, ins, vol = ev
    if ins in VOICE:
        base = 1000
    elif ins in BASS:
        base = 850
    elif ins in MELODY:
        base = 700
    else:
        base = 500
    return base + (vol or 64) - ch


def preferred_lane(ins):
    if ins in VOICE:
        return 0
    if ins in BASS:
        return 1
    if ins in MELODY:
        return 2
    return 3


def sustain_weight(ins):
    if ins in VOICE:
        return 6
    if ins in MELODY:
        return 5
    if ins in BASS:
        return 3
    return 2


def event_rows(instruments, sample_data, ev, speed, bpm):
    _ch, note, ins, _vol = ev
    if not (1 <= ins <= len(sample_data)) or not sample_data[ins - 1]:
        return 1
    rel = instruments[ins - 1][5]
    ds = instruments[ins - 1][6]
    semis = note - 37 + rel + downsample_pitch_compensation(ds) + NOTE_SHIFT
    pitch = 2 ** (semis / 12.0)
    base_rate = 22046.0 / max(1, ds)
    seconds = (len(sample_data[ins - 1]) / max(1.0, base_rate * pitch))
    row_seconds = max(0.02, speed * 2.5 / max(1, bpm))
    return max(1, min(64, int(seconds / row_seconds + 0.5)))


def pitch_index(instruments, ev):
    _ch, note, ins, _vol = ev
    rel = instruments[ins - 1][5] if 1 <= ins <= len(instruments) else 0
    ds = instruments[ins - 1][6] if 1 <= ins <= len(instruments) else 1
    return note - 37 + rel + downsample_pitch_compensation(ds) + NOTE_SHIFT


def flute_conflict(instruments, ev, lane, lanes, active):
    ins = ev[2]
    if ins not in FLUTE_LIKE:
        return False
    p = pitch_index(instruments, ev)
    others = []
    for other_lane, other in enumerate(lanes):
        if other_lane != lane and other and other[2] in FLUTE_LIKE:
            others.append(pitch_index(instruments, other))
    for other_lane, other in enumerate(active):
        if other_lane != lane and other.get("until", 0) > 0 and other.get("ins") in FLUTE_LIKE:
            others.append(other["pitch"])
    for q in others:
        interval = abs(p - q) % 12
        if interval in BAD_FLUTE_INTERVALS:
            return True
    return False


def choose_legato_events(instruments, sample_data, evs, active, speed, bpm):
    lanes = [None] * 4
    used = set()
    candidates = sorted(enumerate(evs), key=lambda item: priority(item[1]), reverse=True)

    for idx, ev in candidates:
        ins = ev[2]
        pref = preferred_lane(ins)
        lane_order = [pref] + [i for i in range(4) if i != pref]
        best_lane = None
        best_cost = None
        for lane in lane_order:
            cur = active[lane]
            remaining = cur["until"] if cur else 0
            if remaining <= 0:
                cost = 0
            else:
                cur_prio = cur["priority"]
                cut_penalty = remaining * cur["weight"]
                # Stronger events may cut weaker tails; weaker events should not.
                cost = cut_penalty + max(0, cur_prio - priority(ev)) // 30
            if lanes[lane] is not None:
                cost += 9999
            if flute_conflict(instruments, ev, lane, lanes, active):
                cost += 9999
            if best_cost is None or cost < best_cost:
                best_lane = lane
                best_cost = cost
        if best_lane is not None and best_cost is not None and best_cost <= 18:
            lanes[best_lane] = ev
            used.add(idx)

    return lanes, len(evs) - len(used)


def cell(instruments, note=0, ins=0, eff=0, param=0):
    period = 0
    if note:
        rel = instruments[ins - 1][5] if 1 <= ins <= len(instruments) else 0
        ds = instruments[ins - 1][6] if 1 <= ins <= len(instruments) else 1
        idx = max(0, min(len(PERIODS) - 1, note - 37 + rel + downsample_pitch_compensation(ds) + NOTE_SHIFT))
        period = PERIODS[idx]
    return bytes([
        (ins & 0xF0) | ((period >> 8) & 0x0F),
        period & 0xFF,
        ((ins & 0x0F) << 4) | (eff & 0x0F),
        param & 0xFF,
    ])


def build():
    song_len, orders, speed, bpm, patterns, instruments, sample_data = read_xm()
    # The source XM does not play the full 41-entry order list linearly.
    # Pattern 23 ends with B00, so the audible loop is the first 24 orders.
    orders = orders[:REAL_ORDER_COUNT]
    song_len = len(orders)
    mod_patterns = []
    dropped = 0
    first_order = orders[0]
    for pi, rows in enumerate(patterns):
        pdata = bytearray()
        active = [{"until": 0, "priority": 0, "weight": 0, "ins": 0, "pitch": None} for _ in range(4)]
        for row, evs in enumerate(rows):
            for lane in range(4):
                if active[lane]["until"] > 0:
                    active[lane]["until"] -= 1
            evs = apply_composites(evs)
            lanes, lost = choose_legato_events(instruments, sample_data, evs, active, speed, bpm)
            dropped += lost
            for lane, ev in enumerate(lanes):
                if ev:
                    _ch, note, ins, _vol = ev
                    if pi == first_order and row == 0 and lane == 0:
                        eff, param = 0x0F, speed
                    elif pi == first_order and row == 0 and lane == 1:
                        eff, param = 0x0F, bpm
                    else:
                        eff, param = 0, 0
                    pdata += cell(instruments, note, ins, eff, param)
                    active[lane] = {
                        "until": event_rows(instruments, sample_data, ev, speed, bpm),
                        "priority": priority(ev),
                        "weight": sustain_weight(ins),
                        "ins": ins,
                        "pitch": pitch_index(instruments, ev),
                    }
                else:
                    if pi == first_order and row == 0 and lane == 0:
                        eff, param = 0x0F, speed
                    elif pi == first_order and row == 0 and lane == 1:
                        eff, param = 0x0F, bpm
                    else:
                        eff, param = 0, 0
                    pdata += cell(instruments, 0, 0, eff, param)
        mod_patterns.append(bytes(pdata))

    out = bytearray(b"Zuma GS4 compact"[:20].ljust(20, b"\0"))
    for name, length, vol, loop_start, loop_len, _rel_note, _ds in instruments[:31]:
        out += name.ljust(22, b"\0")[:22]
        out += (length // 2).to_bytes(2, "big")
        out += b"\0"
        out += bytes([vol])
        out += (loop_start // 2).to_bytes(2, "big")
        out += (max(1, loop_len // 2)).to_bytes(2, "big")
    out += bytes([min(song_len, 128), 0x7F])
    out += bytes((orders + [0] * 128)[:128])
    out += b"M.K."
    for i in range(max(orders) + 1):
        out += mod_patterns[i]
    for data in sample_data[:31]:
        out += data
    OUT.write_bytes(out)
    print(f"wrote {OUT} bytes={len(out)} dropped_note_events={dropped}")


if __name__ == "__main__":
    build()
