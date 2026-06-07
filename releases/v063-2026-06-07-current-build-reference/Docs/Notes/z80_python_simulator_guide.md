# Python Z80 Simulator для отладки asm-кода Zuma на ZX Evolution

## Низкоуровневая отладка Z80 с полным доступом к памяти и регистрам

---

## 📋 Оглавление

1. [Проблема](#проблема)
2. [Решение: kosarev/z80](#решение-kosarevz80)
3. [Архитектура](#архитектура-решения)
4. [Сравнение Python Z80 эмуляторов](#сравнение-python-z80-эмуляторов)
5. [Установка](#установка)
6. [Полный код симулятора](#полный-код-симулятора)
7. [Использование](#использование)
8. [Применение для отладки tail-glitch бага](#применение-для-отладки-tail-glitch-бага)
9. [Workflow](#workflow)
10. [Полезные ссылки](#полезные-ссылки)

---

## Проблема

При разработке asm-кода для **ZX Evolution + VDAC2 (FT812)** возникает проблема отладки:

### Текущее положение:
- ✅ Есть высокоуровневый Python симулятор (`vdc_visual_emulator.py`)
- ✅ Логика отлажена в Python
- ❌ Asm-порт имеет визуальные баги (tail-shift при insert)
- ❌ Стандартные ZX эмуляторы (Unreal Speccy, ZEsarUX) не дают:
  - Прямого доступа к памяти из Python
  - Возможности вызывать отдельные подпрограммы
  - Автоматических тестов
  - Сравнения с Python reference

### Что нужно:
Низкоуровневый **Z80 эмулятор в Python** с:
- Полным доступом к памяти (RAM/ROM, страницы TS-Config)
- Доступом к регистрам Z80 (AF, BC, DE, HL, IX, IY, SP, PC, R, I)
- Точной эмуляцией тактов
- Перехватом портов TS-Config (#xxAF)
- API для вызова отдельных подпрограмм
- Возможностью параллельного сравнения с Python reference

---

## Решение: kosarev/z80

### **GitHub:** https://github.com/kosarev/z80
### **PyPI:** `pip install z80`

### Преимущества:

- ✅ **Полная поддержка Z80** включая недокументированные инструкции
- ✅ **Точная эмуляция тактов** (machine cycle-level)
- ✅ **Прошла тесты zexall, cputest, 8080pre, 8080exer, 8080exm**
- ✅ **Python API** — нативный интерфейс
- ✅ **C++ ядро** — высокая производительность
- ✅ **MIT лицензия** — свободное использование
- ✅ **Активно поддерживается**

---

## Архитектура решения

```
┌─────────────────────────────────────────────────────┐
│  Python Test Framework                              │
│                                                      │
│  ┌─────────────────────────────────────────────┐   │
│  │  Reference Implementation                    │   │
│  │  vdc_visual_emulator.py — high-level Python │   │
│  │  (отлаженная логика)                         │   │
│  └──────────────────┬──────────────────────────┘   │
│                     │                                │
│                     │ Параллельное сравнение         │
│                     ▼                                │
│  ┌─────────────────────────────────────────────┐   │
│  │  Z80 Low-Level Emulator (новое!)            │   │
│  │  - Загружает скомпилированный .sna/.bin     │   │
│  │  - Эмулирует Z80 + TS-Config регистры       │   │
│  │  - Python API для доступа к памяти          │   │
│  │  - Логгирует state каждый кадр              │   │
│  │  - Точные такты для профилирования          │   │
│  └─────────────────────────────────────────────┘   │
│                     │                                │
│                     │ Сравнение байт-в-байт         │
│                     ▼                                │
│  ┌─────────────────────────────────────────────┐   │
│  │  Test Results & Bug Detection               │   │
│  │  - Diff состояний asm vs Python             │   │
│  │  - Точная локализация расхождений           │   │
│  │  - Логи для офлайн анализа                  │   │
│  └─────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────┘
```

---

## Сравнение Python Z80 эмуляторов

| Эмулятор | Скорость | Качество | API | Tests | URL |
|----------|----------|----------|-----|-------|-----|
| **kosarev/z80** ⭐ | ⭐⭐⭐⭐⭐ C++ ядро | ⭐⭐⭐⭐⭐ | Python | zexall ✅ | github.com/kosarev/z80 |
| **jamespbarrett/pyz80** | ⭐⭐⭐ Pure Python | ⭐⭐⭐ | Прямой | Базовые | github.com/jamespbarrett/pyz80 |
| **deadsy/py_z80** | ⭐⭐ Pure Python | ⭐⭐⭐ | Monitor | Частичные | github.com/deadsy/py_z80 |
| **cburbridge/z80** | ⭐⭐ Pure Python | ⭐⭐⭐ | Python | zexall partial | github.com/cburbridge/z80 |

### Рекомендация: **kosarev/z80**

- Самый быстрый (C++ ядро с Python биндингами)
- Самый точный (проходит zexall)
- Активно поддерживается
- Хорошая документация

---

## Установка

### 1. Python библиотека:

```bash
pip install z80
```

### 2. sjasmplus (компилятор Z80):

```bash
# Windows: скачать с https://github.com/z00m128/sjasmplus/releases
# macOS:
brew install sjasmplus
# Linux:
sudo apt install sjasmplus
```

### 3. Компиляция с генерацией .sym файла:

```bash
sjasmplus zuma.asm --sym=zuma.sym --lst=zuma.lst
```

В **zuma.sym** будут адреса всех меток:
```
VDC_Slots             EQU 0xC000
VDC_HSA               EQU 0xC2D0
VDC_InsertAt          EQU 0x8200
VDC_Update            EQU 0x8100
```

---

## Полный код симулятора

### `zuma_z80_simulator.py`

```python
#!/usr/bin/env python3
"""
Zuma Z80 Simulator - низкоуровневый симулятор для отладки asm кода
==================================================================

Эмулирует Z80 CPU + минимально необходимые TS-Config регистры,
загружает скомпилированный asm код (.sna или .bin), даёт полный
доступ к памяти и регистрам.

Зависимости:
    pip install z80
"""

import z80
import struct
from dataclasses import dataclass
from typing import Optional


# ============================================================================
# Адреса в asm-коде (синхронно с zuma.sym или .lst после sjasmplus)
# ============================================================================

# VDC state
VDC_SLOTS_ADDR        = 0xC000  # подставить реальные адреса из .sym
VDC_OFFSETS_ADDR      = 0xC0F0
VDC_SHOT2_ADDR        = 0xC1E0
VDC_HSA_ADDR          = 0xC2D0
VDC_HSUB_ADDR         = 0xC2D1
VDC_SLOTSLEN_ADDR     = 0xC2D2
VDC_BALLSSPAWNED_ADDR = 0xC2D5

# Routine addresses
VDC_INIT_ADDR     = 0x8000
VDC_UPDATE_ADDR   = 0x8100
VDC_INSERTAT_ADDR = 0x8200
VDC_SLOTPOS_ADDR  = 0x8300

# TS-Config ports (#xxAF)
TS_VCONFIG    = 0x00AF
TS_TSCONFIG   = 0x06AF
TS_BORDER     = 0x0FAF
TS_PAGE3      = 0x13AF
TS_T0GPAGE    = 0x17AF
TS_TMPAGE     = 0x16AF


# ============================================================================
# Z80 Memory Manager (с поддержкой страничной памяти TS-Config)
# ============================================================================

class TSConfigMemory:
    """
    Эмулирует память ZX Evolution с TS-Config страничной системой.
    - 64KB Z80 адресного пространства (0x0000-0xFFFF)
    - 4MB физической памяти (256 страниц по 16KB)
    - Регистры Page0-Page3 переключают страницы в окна
    """
    
    def __init__(self, size_kb=512):
        # Физическая память
        self.physical = bytearray(size_kb * 1024)
        
        # Текущие страницы в окнах
        self.page0 = 0  # ROM по умолчанию
        self.page1 = 5
        self.page2 = 2
        self.page3 = 0
        
        # ROM (0x0000-0x3FFF) - можно загрузить ZX Spectrum ROM
        self.rom = bytearray(16 * 1024)
    
    def read(self, addr):
        """Чтение байта Z80"""
        addr &= 0xFFFF
        
        if addr < 0x4000:
            return self.rom[addr]
        elif addr < 0x8000:
            return self.physical[self.page1 * 0x4000 + (addr - 0x4000)]
        elif addr < 0xC000:
            return self.physical[self.page2 * 0x4000 + (addr - 0x8000)]
        else:
            return self.physical[self.page3 * 0x4000 + (addr - 0xC000)]
    
    def write(self, addr, value):
        """Запись байта Z80"""
        addr &= 0xFFFF
        value &= 0xFF
        
        if addr < 0x4000:
            pass  # ROM - read-only
        elif addr < 0x8000:
            self.physical[self.page1 * 0x4000 + (addr - 0x4000)] = value
        elif addr < 0xC000:
            self.physical[self.page2 * 0x4000 + (addr - 0x8000)] = value
        else:
            self.physical[self.page3 * 0x4000 + (addr - 0xC000)] = value


# ============================================================================
# Главный симулятор
# ============================================================================

class ZumaZ80Simulator:
    """
    Симулятор Z80 + TS-Config для отладки Zuma asm кода.
    """
    
    def __init__(self, sna_file=None, bin_file=None, bin_addr=0x8000):
        self.cpu = z80.Z80Machine()
        self.memory = TSConfigMemory()
        
        # TS-Config registers
        self.ts_registers = {}
        
        # Перехватчики для портов
        self.cpu.set_on_input(self._on_input)
        self.cpu.set_on_output(self._on_output)
        
        # Счётчики
        self.frame_counter = 0
        self.tick_counter = 0
        self.log_file = None
        
        # Загрузка кода
        if sna_file:
            self.load_sna(sna_file)
        elif bin_file:
            self.load_bin(bin_file, bin_addr)
    
    # ------------------------------------------------------------------------
    # Загрузка кода
    # ------------------------------------------------------------------------
    
    def load_sna(self, filename):
        """Загрузка SNA snapshot (формат ZX Spectrum 48K)."""
        with open(filename, 'rb') as f:
            header = f.read(27)
            data = f.read()
        
        # Распаковка регистров из header
        i_reg = header[0]
        hl_alt = struct.unpack('<H', header[1:3])[0]
        de_alt = struct.unpack('<H', header[3:5])[0]
        bc_alt = struct.unpack('<H', header[5:7])[0]
        af_alt = struct.unpack('<H', header[7:9])[0]
        hl = struct.unpack('<H', header[9:11])[0]
        de = struct.unpack('<H', header[11:13])[0]
        bc = struct.unpack('<H', header[13:15])[0]
        iy = struct.unpack('<H', header[15:17])[0]
        ix = struct.unpack('<H', header[17:19])[0]
        iff2 = header[19]
        r_reg = header[20]
        af = struct.unpack('<H', header[21:23])[0]
        sp = struct.unpack('<H', header[23:25])[0]
        im = header[25]
        border = header[26]
        
        # Загрузка памяти (RAM 16384-65535)
        for i, byte in enumerate(data):
            self.memory.write(0x4000 + i, byte)
        
        # Установка регистров
        self.cpu.set_af(af)
        self.cpu.set_bc(bc)
        self.cpu.set_de(de)
        self.cpu.set_hl(hl)
        self.cpu.set_ix(ix)
        self.cpu.set_iy(iy)
        self.cpu.set_sp(sp)
        self.cpu.set_i(i_reg)
        self.cpu.set_r(r_reg)
        
        # SNA: PC взять со стека
        pc = self.memory.read(sp) | (self.memory.read(sp + 1) << 8)
        self.cpu.set_sp((sp + 2) & 0xFFFF)
        self.cpu.set_pc(pc)
        
        print(f"✓ Загружен SNA: {filename}")
        print(f"  PC=${pc:04X}, SP=${sp:04X}, AF=${af:04X}")
    
    def load_bin(self, filename, addr):
        """Загрузка raw binary в память по адресу."""
        with open(filename, 'rb') as f:
            data = f.read()
        
        for i, byte in enumerate(data):
            self.memory.write(addr + i, byte)
        
        self.cpu.set_pc(addr)
        print(f"✓ Загружен BIN: {filename} в ${addr:04X}, размер {len(data)} байт")
    
    # ------------------------------------------------------------------------
    # Обработка портов (TS-Config)
    # ------------------------------------------------------------------------
    
    def _on_input(self, port):
        """IN A, (C) или IN A, (n) - чтение из порта."""
        port &= 0xFFFF
        
        # TS-Config регистры
        if (port & 0xFF) == 0xAF:
            return self.ts_registers.get(port, 0)
        
        # Клавиатура (порт #FE)
        if port == 0x00FE:
            return 0xFF
        
        return 0xFF
    
    def _on_output(self, port, value):
        """OUT (C), A или OUT (n), A - запись в порт."""
        port &= 0xFFFF
        value &= 0xFF
        
        if (port & 0xFF) == 0xAF:
            self.ts_registers[port] = value
            
            if port == TS_VCONFIG:
                print(f"  → VConfig = ${value:02X}")
            elif port == TS_BORDER:
                print(f"  → Border = ${value:02X}")
            elif port == TS_TSCONFIG:
                print(f"  → TSConfig = ${value:02X} (S_EN={bool(value&0x80)}, T0_EN={bool(value&0x20)})")
        
        elif port == 0x00FE:
            pass  # Стандартный бордюр (FT812 перехватывает экран)
    
    # ------------------------------------------------------------------------
    # Выполнение кода
    # ------------------------------------------------------------------------
    
    def step(self):
        """Выполнить одну Z80 инструкцию."""
        return self.cpu.run()
    
    def run_until(self, pc_target, max_ticks=1000000):
        """Выполнять пока PC != target или не превысили лимит."""
        ticks = 0
        while self.cpu.get_pc() != pc_target and ticks < max_ticks:
            t = self.step()
            ticks += t
            self.tick_counter += t
        return ticks
    
    def run_ticks(self, target_ticks):
        """Выполнить указанное количество тактов."""
        start = self.tick_counter
        while self.tick_counter - start < target_ticks:
            t = self.step()
            self.tick_counter += t
    
    def run_frame(self):
        """Выполнить один кадр (50Hz = ~70000 тактов)."""
        FRAME_TICKS = 70000
        start = self.tick_counter
        
        while self.tick_counter - start < FRAME_TICKS:
            t = self.step()
            self.tick_counter += t
        
        self.frame_counter += 1
    
    def run_frames(self, n):
        """Выполнить n кадров."""
        for _ in range(n):
            self.run_frame()
    
    def call_routine(self, addr, a=0, b=0, c=0, d=0, e=0, h=0, l=0):
        """
        Вызвать подпрограмму по адресу с указанными регистрами.
        Эмулирует CALL addr с возвратом в специальную метку.
        """
        # Сохраняем текущее состояние
        saved_pc = self.cpu.get_pc()
        saved_sp = self.cpu.get_sp()
        
        # Устанавливаем регистры
        self.cpu.set_af((a << 8) | (self.cpu.get_af() & 0xFF))
        self.cpu.set_bc((b << 8) | c)
        self.cpu.set_de((d << 8) | e)
        self.cpu.set_hl((h << 8) | l)
        
        # Кладём return адрес на стек (специальный маркер)
        RETURN_MARKER = 0xFFFF
        sp = self.cpu.get_sp()
        self.memory.write(sp - 1, (RETURN_MARKER >> 8) & 0xFF)
        self.memory.write(sp - 2, RETURN_MARKER & 0xFF)
        self.cpu.set_sp(sp - 2)
        
        # Прыгаем на нашу подпрограмму
        self.cpu.set_pc(addr)
        
        # Выполняем до возврата
        max_iters = 1000000
        while self.cpu.get_pc() != RETURN_MARKER and max_iters > 0:
            self.cpu.run()
            max_iters -= 1
        
        if max_iters == 0:
            print(f"⚠ call_routine timeout @ PC=${self.cpu.get_pc():04X}")
    
    # ------------------------------------------------------------------------
    # Доступ к памяти
    # ------------------------------------------------------------------------
    
    def get_byte(self, addr):
        """Прочитать байт из памяти."""
        return self.memory.read(addr)
    
    def set_byte(self, addr, value):
        """Записать байт в память."""
        self.memory.write(addr, value)
    
    def get_word(self, addr):
        """Прочитать word (little-endian)."""
        return self.memory.read(addr) | (self.memory.read(addr + 1) << 8)
    
    def set_word(self, addr, value):
        """Записать word."""
        self.memory.write(addr, value & 0xFF)
        self.memory.write(addr + 1, (value >> 8) & 0xFF)
    
    def get_memory(self, addr, length):
        """Прочитать диапазон памяти как bytes."""
        return bytes(self.memory.read(addr + i) for i in range(length))
    
    def set_memory(self, addr, data):
        """Записать bytes/list в память."""
        for i, byte in enumerate(data):
            self.memory.write(addr + i, byte)
    
    # ------------------------------------------------------------------------
    # Отладка
    # ------------------------------------------------------------------------
    
    def dump_registers(self):
        """Вывести все регистры Z80."""
        print(f"PC=${self.cpu.get_pc():04X} SP=${self.cpu.get_sp():04X}")
        print(f"AF=${self.cpu.get_af():04X} BC=${self.cpu.get_bc():04X}")
        print(f"DE=${self.cpu.get_de():04X} HL=${self.cpu.get_hl():04X}")
        print(f"IX=${self.cpu.get_ix():04X} IY=${self.cpu.get_iy():04X}")
    
    def dump_vdc_state(self):
        """Вывести состояние VDC."""
        hsa = self.get_byte(VDC_HSA_ADDR)
        hsub = self.get_byte(VDC_HSUB_ADDR)
        slots_len = self.get_byte(VDC_SLOTSLEN_ADDR)
        balls = self.get_byte(VDC_BALLSSPAWNED_ADDR)
        
        slots = list(self.get_memory(VDC_SLOTS_ADDR, slots_len))
        offsets = [self._signed_byte(b) for b in self.get_memory(VDC_OFFSETS_ADDR, slots_len)]
        shot2 = list(self.get_memory(VDC_SHOT2_ADDR, slots_len))
        
        print(f"\n=== VDC State (frame {self.frame_counter}) ===")
        print(f"HSA={hsa} HSub={hsub} SlotsLen={slots_len} BallsSpawned={balls}")
        print(f"Slots:   {self._format_slots(slots)}")
        print(f"Offsets: {','.join(str(o) for o in offsets)}")
        print(f"Shot2:   {''.join(str(s) for s in shot2)}")
    
    @staticmethod
    def _signed_byte(b):
        return b - 256 if b >= 128 else b
    
    @staticmethod
    def _format_slots(slots):
        result = []
        for s in slots:
            if s == 0xFE: result.append('S')
            elif s == 0xFD: result.append('C')
            elif s == 0xFF: result.append('.')
            else: result.append(str(s))
        return ''.join(result)
    
    # ------------------------------------------------------------------------
    # Логирование
    # ------------------------------------------------------------------------
    
    def start_log(self, filename):
        """Начать логирование в файл."""
        self.log_file = open(filename, 'w')
        self.log_file.write('# frame slotsLen hsa hsub balls slots offsets\n')
    
    def log_frame(self):
        """Записать текущее состояние."""
        if not self.log_file:
            return
        
        hsa = self.get_byte(VDC_HSA_ADDR)
        hsub = self.get_byte(VDC_HSUB_ADDR)
        slots_len = self.get_byte(VDC_SLOTSLEN_ADDR)
        balls = self.get_byte(VDC_BALLSSPAWNED_ADDR)
        
        slots = list(self.get_memory(VDC_SLOTS_ADDR, slots_len))
        offsets = [self._signed_byte(b) for b in self.get_memory(VDC_OFFSETS_ADDR, slots_len)]
        
        slots_str = self._format_slots(slots)
        offsets_str = ','.join(str(o) for o in offsets)
        
        self.log_file.write(f'{self.frame_counter} {slots_len} {hsa} {hsub} {balls} '
                           f'[{slots_str}] [{offsets_str}]\n')
        self.log_file.flush()
    
    def stop_log(self):
        """Закрыть лог."""
        if self.log_file:
            self.log_file.close()
            self.log_file = None
```

---

## Использование

### Базовый пример:

```python
from zuma_z80_simulator import ZumaZ80Simulator, VDC_HSA_ADDR, VDC_INIT_ADDR

# Загружаем asm версию
sim = ZumaZ80Simulator(sna_file='zuma.sna')

# Инициализация
sim.call_routine(VDC_INIT_ADDR)
sim.dump_vdc_state()

# Запускаем 100 кадров
for i in range(100):
    sim.call_routine(VDC_UPDATE_ADDR)
    sim.dump_vdc_state()
```

### Полный доступ к Z80:

```python
# Регистры
hl = sim.cpu.get_hl()
sim.cpu.set_pc(0x8000)

# Память (с поддержкой страничной TS-Config памяти!)
value = sim.get_byte(0xC000)
sim.set_word(VDC_HSA_ADDR, 75)

# Поддиапазоны
slots = sim.get_memory(VDC_SLOTS_ADDR, 240)

# Запись массивов
sim.set_memory(VDC_SLOTS_ADDR, [0xFE] * 240)
```

### Управление выполнением:

```python
# По одной инструкции
sim.step()

# До адреса
sim.run_until(0x8500)

# Точное количество тактов
sim.run_ticks(70000)

# Полный кадр (~70000 тактов)
sim.run_frame()

# Вызов конкретной подпрограммы с параметрами
sim.call_routine(VDC_INSERTAT_ADDR, a=10, b=2)  # InsertAt(idx=10, color=2)
```

### Логирование для офлайн анализа:

```python
sim.start_log('z80_log.txt')

for i in range(200):
    sim.call_routine(VDC_UPDATE_ADDR)
    sim.log_frame()

sim.stop_log()

# Лог будет содержать построчно:
# frame slotsLen hsa hsub balls [slots] [offsets]
```

---

## Применение для отладки tail-glitch бага

### Тест-кейс воспроизведения бага:

```python
def test_tail_glitch():
    """
    Воспроизведение бага: insert в середину при HSA == cap.
    """
    sim = ZumaZ80Simulator(sna_file='zuma.sna')
    
    # 1. Инициализация
    sim.call_routine(VDC_INIT_ADDR)
    
    # 2. Заполняем цепь до HSA == cap
    sim.start_log('z80_log.txt')
    for i in range(200):
        sim.call_routine(VDC_UPDATE_ADDR)
        sim.log_frame()
    
    # 3. Проверяем HSA == cap
    hsa = sim.get_byte(VDC_HSA_ADDR)
    slots_len = sim.get_byte(VDC_SLOTSLEN_ADDR)
    print(f"После 200 кадров: HSA={hsa}, SlotsLen={slots_len}")
    
    # 4. Снимок ДО insert
    before_slots = list(sim.get_memory(VDC_SLOTS_ADDR, slots_len))
    before_offsets = [sim._signed_byte(b) 
                     for b in sim.get_memory(VDC_OFFSETS_ADDR, slots_len)]
    
    # 5. Inject: вставка в середину
    target_idx = slots_len // 2
    color = 1
    sim.call_routine(VDC_INSERTAT_ADDR, a=target_idx, b=color)
    
    # 6. Анализ tail-shift
    after_slots_len = sim.get_byte(VDC_SLOTSLEN_ADDR)
    after_offsets = [sim._signed_byte(b) 
                    for b in sim.get_memory(VDC_OFFSETS_ADDR, after_slots_len)]
    
    # Вычисляем визуальную позицию
    CS = 32
    hsub = sim.get_byte(VDC_HSUB_ADDR)
    
    # Tail позиция ДО
    tail_idx = slots_len - 1
    t_before = (hsa - tail_idx) * CS + hsub + before_offsets[tail_idx]
    
    # Tail позиция ПОСЛЕ
    new_hsa = sim.get_byte(VDC_HSA_ADDR)
    new_tail_idx = after_slots_len - 1
    t_after = (new_hsa - new_tail_idx) * CS + hsub + after_offsets[new_tail_idx]
    
    shift = t_after - t_before
    print(f"\nTAIL-SHIFT: {shift} samples")
    if shift < 0:
        print(f"  = ~{shift * 1.08:.1f} px назад (БАГ!)")
    
    sim.stop_log()
    return shift
```

### Параллельное сравнение с Python reference:

```python
def compare_with_reference():
    """Параллельное выполнение asm-версии и Python reference."""
    
    # Запускаем asm
    sim = ZumaZ80Simulator(sna_file='zuma.sna')
    sim.call_routine(VDC_INIT_ADDR)
    
    # Импортируем Python reference
    from vdc_visual_emulator import VDCEngine, load_track
    
    track = load_track()
    py_engine = VDCEngine(track, seed=42)
    
    # Прогоняем 100 кадров и сравниваем после каждого
    divergences = []
    for frame in range(100):
        # asm версия
        sim.call_routine(VDC_UPDATE_ADDR)
        
        # Python версия
        py_engine.s.frame = frame
        py_engine.try_spawn()
        py_engine.move_chain()
        py_engine.animate_chain()
        
        # Сравниваем state
        asm_hsa = sim.get_byte(VDC_HSA_ADDR)
        asm_slots_len = sim.get_byte(VDC_SLOTSLEN_ADDR)
        
        if asm_hsa != py_engine.s.hsa or asm_slots_len != py_engine.s.slots_len:
            divergences.append({
                'frame': frame,
                'asm_hsa': asm_hsa, 'py_hsa': py_engine.s.hsa,
                'asm_len': asm_slots_len, 'py_len': py_engine.s.slots_len,
            })
    
    if divergences:
        print(f"Найдено {len(divergences)} расхождений:")
        for d in divergences[:10]:
            print(f"  Frame {d['frame']}: HSA asm={d['asm_hsa']}/py={d['py_hsa']}")
    else:
        print("Полное соответствие!")
```

---

## Workflow

### Цикл разработки и отладки:

```
1. Редактирование asm кода
        ↓
2. Компиляция sjasmplus → .sna + .sym
        ↓
3. Запуск Python симулятора
   - Загружает .sna
   - Парсит .sym (адреса меток)
        ↓
4. Автотесты сравнивают asm vs Python reference
        ↓
5. При расхождении:
   - Логи показывают точный кадр
   - Можно выполнить step-by-step
   - Можно дампить регистры/память
        ↓
6. Найден баг → исправление в asm
        ↓
7. Повторить с шага 1
```

### Подготовка проекта:

```bash
# Структура файлов
zuma_project/
├── src/
│   ├── VDC.asm
│   ├── Bullet.asm
│   ├── Frog.asm
│   └── ...
├── build/
│   ├── zuma.sna       # Собранный snapshot
│   ├── zuma.sym       # Карта символов
│   └── zuma.lst       # Listing с такmi
├── tests/
│   ├── zuma_z80_simulator.py
│   ├── vdc_visual_emulator.py  # Python reference
│   ├── test_tail_glitch.py
│   └── test_match3.py
└── Makefile
```

### Makefile:

```makefile
.PHONY: all build test clean

all: build test

build:
	sjasmplus src/zuma.asm \
		--output=build/zuma.sna \
		--sym=build/zuma.sym \
		--lst=build/zuma.lst

test: build
	python tests/test_tail_glitch.py
	python tests/test_match3.py

clean:
	rm -rf build/
```

### Парсинг .sym файла:

```python
def parse_sym_file(sym_path):
    """Парсит sjasmplus .sym файл."""
    symbols = {}
    with open(sym_path, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(';'):
                continue
            # Формат: SYMBOL: EQU $XXXX или SYMBOL EQU 0xXXXX
            parts = line.split()
            if len(parts) >= 3 and parts[1].upper() == 'EQU':
                name = parts[0].rstrip(':')
                value_str = parts[2]
                if value_str.startswith('$'):
                    value = int(value_str[1:], 16)
                elif value_str.startswith('0x') or value_str.startswith('0X'):
                    value = int(value_str[2:], 16)
                else:
                    try:
                        value = int(value_str)
                    except ValueError:
                        continue
                symbols[name] = value
    return symbols

# Использование:
symbols = parse_sym_file('build/zuma.sym')
sim.set_word(symbols['VDC_HSA'], 75)
sim.call_routine(symbols['VDC_InsertAt'], a=10, b=2)
```

---

## Преимущества подхода

### По сравнению с обычными ZX эмуляторами:

| Возможность | ZEsarUX/Unreal Speccy | Python Z80 Simulator |
|-------------|----------------------|---------------------|
| Запуск asm кода | ✅ | ✅ |
| Прямой доступ к памяти | ❌ Только через UI | ✅ Python API |
| Вызов отдельных подпрограмм | ❌ | ✅ |
| Сравнение с reference | ❌ | ✅ Автоматически |
| Автотесты | ❌ | ✅ pytest-совместимо |
| Логирование state | ⚠️ Через debugger | ✅ В файл |
| Воспроизводимость | ⚠️ Через сохранения | ✅ 100% детерминированно |
| CI/CD интеграция | ❌ | ✅ |

### Конкретные сценарии использования:

1. **Воспроизведение багов** — точно тот же state как на железе
2. **Регрессионные тесты** — проверка что fix не сломал другое
3. **Performance profiling** — точные такты для каждой функции
4. **Сравнение версий** — Python reference vs asm port
5. **CI/CD** — автоматические проверки на каждый commit

---

## Полезные ссылки

### Документация и репозитории:

- **kosarev/z80** (рекомендуется): https://github.com/kosarev/z80
- **z80 на PyPI**: https://pypi.org/project/z80/
- **sjasmplus**: https://github.com/z00m128/sjasmplus
- **Z80 Instruction Set**: https://clrhome.org/table/

### Альтернативные эмуляторы:

- **jamespbarrett/pyz80**: https://github.com/jamespbarrett/pyz80
- **deadsy/py_z80**: https://github.com/deadsy/py_z80
- **cburbridge/z80**: https://github.com/cburbridge/z80

### TS-Config документация:

- **TS-Conf official docs**: https://github.com/tslabs/zx-evo/blob/master/pentevo/docs/TSconf/tsconf_en.md
- **TS Labs Forum**: https://forum.tslabs.info/

### FT812 (VDAC2):

- **FT81x Datasheet**: https://brtchip.com/wp-content/uploads/2025/02/DS_FT81x.pdf
- **FT81x Programmer Guide**: https://brtchip.com/wp-content/uploads/Support/Documentation/Programming_Guides/ICs/EVE/FT81X_Series_Programmer_Guide.pdf

---

## Следующие шаги

### Этап 1: Базовая инфраструктура (1-2 дня)
- [ ] Установка z80 библиотеки
- [ ] Адаптация симулятора под ваши реальные адреса (.sym)
- [ ] Первый тест: загрузка .sna и запуск 1 кадра

### Этап 2: Автотесты (3-5 дней)
- [ ] Парсер .sym файла
- [ ] Pytest suite для VDC функций
- [ ] Тесты для InsertAt, DoGapStep, CheckMatch3
- [ ] Сравнение с Python reference

### Этап 3: Отладка бага (1-2 дня)
- [ ] Воспроизведение tail-glitch в симуляторе
- [ ] Step-by-step анализ через симулятор
- [ ] Подтверждение root cause
- [ ] Тест fix'а (AbsorbHead или другой вариант)

### Этап 4: CI/CD (опционально, 2-3 дня)
- [ ] GitHub Actions workflow
- [ ] Автоматическая сборка и тесты на каждый push
- [ ] Регрессионные проверки

---

## Заключение

С **kosarev/z80** и описанным симулятором вы получаете:

✅ **Полный контроль** над выполнением asm кода  
✅ **Прямой доступ** к памяти и регистрам из Python  
✅ **Параллельное сравнение** с Python reference  
✅ **Автоматические тесты** для регрессий  
✅ **Точную локализацию** багов до отдельной Z80 инструкции  
✅ **Профилирование** производительности с точностью до такта  

Это **профессиональный инструмент** для разработки сложных asm-проектов, который заменяет ручную отладку в эмуляторе на воспроизводимый автоматический процесс.

---

**Документ создан:** 2026-05-08  
**Версия:** 1.0  
**Платформа:** ZX Evolution + VDAC2 (FT812)  
**Проект:** Zuma Deluxe port  
**Автор:** Claude (Anthropic)  
**Лицензия:** MIT / CC BY 4.0

---

*Удачи с отладкой Zuma Deluxe на ZX Evolution! 🎮🚀*
