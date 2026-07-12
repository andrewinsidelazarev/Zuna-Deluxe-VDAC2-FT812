#!/usr/bin/env python3
"""zuma_z80_simulator.py — Z80 sandbox для отладки VDC chain logic.

Загружает TSLib.bin (#1000) + Core.bin/main0 (#5C00), main1_play.bin (#C000)
и AY fallback data page (#8000 для flat-вызовов) в flat 64KB,
парсит zuma.sym для адресов VDC_*, даёт API:

  sim = ZumaZ80Sim(project_root)
  sim.call(sim.sym['Core.VDC_Init'])
  sim.call(sim.sym['Core.VDC_Update'])
  hsa = sim.get_byte(sim.sym['Core.VDC_HSA'])
  slots = sim.get_memory(sim.sym['Core.VDC_Slots'], sim.get_byte(sim.sym['Core.VDC_SlotsLen']))

FT812 SPI и TS-Config порты заглушены (IN всегда 0x00, OUT молча игнорируется),
чтобы VDC-только-логика не зависала на ожидании реального железа.
Init_Video, MainLoop, любые FT_WR/FT_RD вызывать НЕ нужно — это сразу повиснет.

Зависимости: `pip install z80` (kosarev/z80).
"""
import os
import re
import struct

try:
    import z80
except ImportError as e:
    raise SystemExit(
        "Требуется kosarev/z80. Установи через: py -3.12 -m pip install z80\n"
        f"(оригинальная ошибка: {e})"
    )


HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))


def parse_sym(path):
    """Парсер sjasmplus .sym. Формат: `<name>: EQU 0x<hex>` или `<name>: EQU <dec>`."""
    syms = {}
    rx = re.compile(r'^\s*([\w.]+):\s+EQU\s+(0x[0-9A-Fa-f]+|#[0-9A-Fa-f]+|\d+)\s*$')
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            m = rx.match(line)
            if not m:
                continue
            name, val = m.group(1), m.group(2)
            if val.startswith('0x'):
                syms[name] = int(val[2:], 16)
            elif val.startswith('#'):
                syms[name] = int(val[1:], 16)
            else:
                syms[name] = int(val)
    return syms


RETURN_MARKER = 0x0FFE  # сторож возврата в незагруженном окне перед TSLib (#1000)


class ZumaZ80Sim:
    def __init__(self, project_root=PROJECT_ROOT):
        self.root = project_root
        self.cpu = z80.Z80Machine()
        # kosarev/z80: память адресуется через .memory или прямые методы. API ниже
        # допускает оба варианта — финализируем после первого smoke-теста.
        self.sym = parse_sym(os.path.join(project_root, 'Build', 'zuma.sym'))

        # IN/OUT перехват: всё FT812/TS-Config заглушено.
        self.cpu.set_input_callback(self._on_in)
        self.cpu.set_output_callback(self._on_out)

        self._load_bin(os.path.join(project_root, 'Build', 'TSLib.bin'),       0x1000)
        self._load_bin(os.path.join(project_root, 'Build', 'Core.bin'),        0x5C00)
        # main1_play.bin = slot 3 page #04, ORG #C000. Симулятор плоский, оба
        # сегмента одновременно видны. Real Z80 видит main1 через slot 3 mapping
        # после Init_Core (SetPage3 #04).
        self._load_bin(os.path.join(project_root, 'Build', 'main1_play.bin'), 0xC000)
        self._load_bin_optional(os.path.join(project_root, 'Sounds', 'AY', 'ay_sfx_data.bin'), 0x8000)

        # Stack как в spgbld_vdac2.ini: Stack=0x40F2
        self.cpu.sp = 0x40F2

    # ---- memory helpers ----
    def _load_bin(self, path, addr):
        with open(path, 'rb') as f:
            data = f.read()
        for i, b in enumerate(data):
            self.set_byte(addr + i, b)
        print(f'loaded {os.path.basename(path)}: {len(data)} bytes @ #{addr:04X}')

    def _load_bin_optional(self, path, addr):
        if os.path.exists(path):
            self._load_bin(path, addr)

    def set_byte(self, addr, value):
        self.cpu.memory[addr & 0xFFFF] = value & 0xFF

    def get_byte(self, addr):
        return self.cpu.memory[addr & 0xFFFF]

    def get_word(self, addr):
        return self.get_byte(addr) | (self.get_byte(addr + 1) << 8)

    def get_memory(self, addr, length):
        return bytes(self.get_byte(addr + i) for i in range(length))

    # ---- port stubs ----
    def _on_in(self, port):
        # FT812 status / TS-Conf reads → 0 (никакой кнопки/входа). Безопасно для VDC.
        return 0

    def _on_out(self, port, value):
        # FT812 / TS-Conf писание → noop. Безопасно для VDC.
        pass

    # ---- execution ----
    def call(self, addr, a=0, b=0, c=0, d=0, e=0, h=0, l=0, max_steps=2_000_000):
        """Вызвать подпрограмму с регистрами. Возвращается через RET → PC=RETURN_MARKER."""
        self.cpu.a = a
        self.cpu.bc = ((b & 0xFF) << 8) | (c & 0xFF)
        self.cpu.de = ((d & 0xFF) << 8) | (e & 0xFF)
        self.cpu.hl = ((h & 0xFF) << 8) | (l & 0xFF)

        sp = self.cpu.sp
        self.set_byte(sp - 1, (RETURN_MARKER >> 8) & 0xFF)
        self.set_byte(sp - 2, RETURN_MARKER & 0xFF)
        self.cpu.sp = (sp - 2) & 0xFFFF
        self.cpu.pc = addr

        # Set breakpoint на RETURN_MARKER чтобы run() остановился.
        self.cpu.set_breakpoint(RETURN_MARKER)
        steps = 0
        while self.cpu.pc != RETURN_MARKER:
            self.cpu.run()
            steps += 1
            if steps > max_steps:
                self.cpu.clear_breakpoint(RETURN_MARKER)
                raise RuntimeError(
                    f'call({addr:#06x}) timeout at PC={self.cpu.pc:#06x} '
                    f'after {steps} run() iters'
                )
        self.cpu.clear_breakpoint(RETURN_MARKER)
        return steps

    # ---- VDC convenience ----
    def vdc_state(self):
        """Снимок VDC — для diff'а между фреймами."""
        hsa = self.get_byte(self.sym['Core.VDC_HSA'])
        hsub = self.get_byte(self.sym['Core.VDC_HSub'])
        slots_len = self.get_byte(self.sym['Core.VDC_SlotsLen'])
        balls = self.get_byte(self.sym['Core.VDC_BallsSpawned'])
        slots = list(self.get_memory(self.sym['Core.VDC_Slots'], slots_len))
        offsets_raw = self.get_memory(self.sym['Core.VDC_Offsets'], slots_len)
        offsets = [b - 256 if b >= 128 else b for b in offsets_raw]
        return {
            'hsa': hsa, 'hsub': hsub, 'slots_len': slots_len, 'balls_spawned': balls,
            'slots': slots, 'offsets': offsets,
        }

    @staticmethod
    def format_slots(slots):
        out = []
        for s in slots:
            if s == 0xFE: out.append('S')
            elif s == 0xFD: out.append('C')
            elif s == 0xFF: out.append('.')
            else: out.append(str(s))
        return ''.join(out)


# ---- smoke test ----
if __name__ == '__main__':
    sim = ZumaZ80Sim()
    print('=== sym entries (VDC subset) ===')
    for k in sorted(sim.sym):
        if 'VDC_' in k and not k.endswith('.End'):
            print(f'  {k} = #{sim.sym[k]:04X}')

    print('\n=== call VDC_Init ===')
    t = sim.call(sim.sym['Core.VDC_Init'])
    print(f'  ticks={t}')
    s = sim.vdc_state()
    print(f'  hsa={s["hsa"]} hsub={s["hsub"]} slots_len={s["slots_len"]} balls={s["balls_spawned"]}')
    print(f'  slots={sim.format_slots(s["slots"])[:60]}')

    print('\n=== run 5 VDC_Update frames ===')
    for f in range(5):
        sim.call(sim.sym['Core.VDC_Update'])
        s = sim.vdc_state()
        print(f'  frame {f}: hsa={s["hsa"]} hsub={s["hsub"]} '
              f'len={s["slots_len"]} balls={s["balls_spawned"]} '
              f'slots={sim.format_slots(s["slots"])[:40]}')
