# FT812 Emulator Setup Guide для отладки Zuma на ZX Evolution

## Использование готовых решений Bridgetek вместо разработки своего эмулятора

---

## 📋 Оглавление

1. [Введение](#введение)
2. [Готовые решения](#готовые-решения-обзор)
3. [Решение #1: EVE Screen Editor](#решение-1-eve-screen-editor-ese)
4. [Решение #2: EveApps MSVC Emulator](#решение-2-eveapps-msvc-emulator)
5. [Решение #3: RudolphRiedel FT800-FT813 library](#решение-3-rudolphriedel-ft800-ft813-library)
6. [Архитектура отладки Zuma](#архитектура-отладки-zuma)
7. [Способы интеграции с Z80 кодом](#способы-интеграции-с-z80-кодом)
8. [Пошаговая инструкция установки](#пошаговая-инструкция-установки)
9. [Шаблоны C кода для Zuma](#шаблоны-c-кода-для-zuma)
10. [Workflow для отладки tail-glitch](#workflow-для-отладки-tail-glitch)
11. [Полезные ссылки](#полезные-ссылки)

---

## Введение

### Зачем нужен эмулятор FT812?

При разработке Zuma для ZX Evolution + VDAC2 (FT812):
- Нужно тестировать графику без реального железа
- Автоматизация регрессионных тестов
- Сравнение результатов с Python reference
- Отладка визуальных багов

### Почему не писать свой эмулятор?

Полный эмулятор FT812 — это:
- 6-10 недель работы
- ~7500 строк кода
- Высокий риск багов
- Постоянная поддержка

### Решение: использовать готовые!

Bridgetek предоставляет официальные эмуляторы **бесплатно**.

---

## Готовые решения (обзор)

| Решение | Платформа | Язык | Лучше всего для |
|---------|-----------|------|-----------------|
| **EVE Screen Editor** | Windows | GUI | Интерактивная отладка |
| **EveApps MSVC Emulator** | Windows | C/C++ | Тестирование приложений |
| **RudolphRiedel library** | Win/Linux/Mac | C | Кросс-платформа, авто-тесты |
| **CircuitPython _eve** | Cross | Python | Python автоматизация |

### Сравнительная таблица:

| Критерий | EVE Editor | MSVC Emulator | RudolphRiedel | CircuitPython |
|----------|-----------|---------------|---------------|---------------|
| **Стоимость** | Бесплатно | Бесплатно | Бесплатно | Бесплатно |
| **Open source** | ❌ | ✅ | ✅ | ✅ |
| **Точность эмуляции** | 100% (от FTDI) | 100% (от FTDI) | Зависит от backend | Через железо |
| **Windows** | ✅ | ✅ | ✅ | ⚠️ |
| **Linux/macOS** | ❌ | ⚠️ Wine | ✅ | ✅ |
| **GUI** | ✅ | ✅ | ❌ | ❌ |
| **Python API** | ❌ | Через bridge | Через ctypes | ✅ |
| **Автотесты** | ❌ | ✅ | ✅ | ✅ |
| **CI/CD** | ❌ | ✅ | ✅ | ✅ |

---

## Решение #1: EVE Screen Editor (ESE)

### Описание

Официальный графический IDE от Bridgetek с встроенным эмулятором FT812.

### Возможности

- ✅ Drag-and-drop редактор
- ✅ Real-time preview
- ✅ Touch simulation
- ✅ Asset management (изображения, шрифты)
- ✅ Экспорт в C код
- ✅ Поддержка всех команд FT81x/BT81x

### Когда использовать

**Идеально для:**
- Прототипирование UI Zuma
- Создание макетов экранов
- Проверка отдельных команд
- Дизайн UI элементов

**Не подходит для:**
- Автоматических тестов
- Интеграции с Z80 кодом
- CI/CD

### Установка

```
1. Перейти: https://brtchip.com/toolchains/
2. Скачать EVE Screen Editor (ESE)
3. Установить (Windows)
4. Запустить
```

### Базовое использование

1. Открыть ESE
2. Выбрать модель FT812
3. Выбрать разрешение 640×480
4. Начать создавать Display List через GUI
5. Видеть результат в реальном времени

### Пример workflow

```
1. Создать макет экрана Zuma в ESE
2. Экспортировать как C код
3. Использовать как референс для Z80 asm
4. Сравнить с реальным выводом
```

---

## Решение #2: EveApps MSVC Emulator

### Описание

Официальный набор демо и эмулятор от Bridgetek.

**URL:** https://github.com/Bridgetek/EveApps

### Структура проекта

```
EveApps/
├── DemoApps/                    ← 28 готовых демо
│   ├── Calculator/
│   ├── Clocks/
│   ├── Audio/
│   └── ...
├── SampleApp/                   ← Учебные примеры
│   └── Project/
│       └── MSVC_Emulator/      ← ⭐ Windows эмулятор
│           ├── SampleApp.sln    ← Открыть в Visual Studio
│           └── ...
├── common/                      ← Общие функции
└── Tools/
    └── EveScreenEditor/         ← Используется эмулятором
```

### Возможности

- ✅ Полная эмуляция FT812
- ✅ Запуск любого C кода
- ✅ Окно с эмулированным экраном
- ✅ Touch input через мышь
- ✅ Поддержка всех команд
- ✅ ASTC для BT815/BT817

### Когда использовать

**Идеально для:**
- Тестирование полных приложений
- Запуск Display List от Z80
- Интеграция через файлы/sockets
- Регрессионные тесты

### Установка

#### Требования:
- Windows 10/11
- Visual Studio 2019 или новее (Community Edition бесплатна)
- EVE Screen Editor (для библиотек эмулятора)

#### Шаги:

```bash
# 1. Клонировать репозиторий
git clone https://github.com/Bridgetek/EveApps.git
cd EveApps

# 2. Установить Visual Studio Community
# https://visualstudio.microsoft.com/
# Выбрать: "Desktop development with C++"

# 3. Установить EVE Screen Editor
# https://brtchip.com/toolchains/
# (содержит библиотеки эмулятора)

# 4. Открыть проект
# EveApps/SampleApp/Project/MSVC_Emulator/SampleApp.sln
```

### Первый запуск

1. Открыть `SampleApp.sln` в Visual Studio
2. Выбрать платформу: **MSVC_Emulator** (не FT9XX)
3. Build → Build Solution (F7)
4. Debug → Start Without Debugging (Ctrl+F5)
5. Должно открыться окно с эмулированным экраном FT812

### Структура SampleApp.c

```c
#include "Common.h"
#include "EVE_Hal.h"
#include "EVE_CoCmd.h"

EVE_HalContext s_halContext;
EVE_HalContext *s_pHalContext;

int main(int argc, char *argv[]) {
    s_pHalContext = &s_halContext;
    
    // Инициализация эмулятора
    Gpu_Init(s_pHalContext);
    
    // Главный цикл
    while (1) {
        render_frame();
        // Sleep, обработка событий и т.д.
    }
    
    return 0;
}

void render_frame(void) {
    // Начало Display List
    EVE_Cmd_wr32(s_pHalContext, CMD_DLSTART);
    EVE_Cmd_wr32(s_pHalContext, CLEAR_COLOR_RGB(0, 0, 0));
    EVE_Cmd_wr32(s_pHalContext, CLEAR(1, 1, 1));
    
    // Рисуем что-то
    EVE_Cmd_wr32(s_pHalContext, COLOR_RGB(255, 255, 0));
    EVE_Cmd_wr32(s_pHalContext, BEGIN(RECTS));
    EVE_Cmd_wr32(s_pHalContext, VERTEX2F(100*16, 100*16));
    EVE_Cmd_wr32(s_pHalContext, VERTEX2F(200*16, 200*16));
    EVE_Cmd_wr32(s_pHalContext, END());
    
    // Завершение
    EVE_Cmd_wr32(s_pHalContext, DISPLAY());
    EVE_CoCmd_swap(s_pHalContext);
    EVE_Cmd_waitflush(s_pHalContext);
}
```

---

## Решение #3: RudolphRiedel FT800-FT813 library

### Описание

Кросс-платформенная C библиотека для всех чипов EVE.

**URL:** https://github.com/RudolphRiedel/FT800-FT813

### Поддерживаемые платформы

- Arduino (Uno, ESP32, STM32)
- Raspberry Pi
- Linux (с FT232H USB-SPI)
- Windows
- ESP8266/ESP32

### Возможности

- ✅ Полный API для FT812
- ✅ Burst mode для скорости
- ✅ Все команды и форматы
- ✅ Готовые драйверы для популярных дисплеев
- ✅ Можно подключить через Python ctypes

### Когда использовать

**Идеально для:**
- Кросс-платформенная разработка
- Использование из Python
- Linux/macOS поддержка
- Реальное железо через USB-SPI адаптер

### Установка для Python через ctypes

```bash
# 1. Скачать
git clone https://github.com/RudolphRiedel/FT800-FT813.git

# 2. Скомпилировать как shared library
gcc -shared -fPIC EVE_commands.c -o libeve.so

# 3. Использовать из Python
python3
```

```python
import ctypes

eve = ctypes.CDLL('./libeve.so')

# Использовать функции
eve.EVE_init()
eve.EVE_cmd_dlstart()
eve.EVE_cmd_text(100, 100, 28, 0, b"Hello FT812!")
eve.EVE_cmd_swap()
```

---

## Архитектура отладки Zuma

### Полная схема

```
┌──────────────────────────────────────────────────┐
│  Среда разработки                                │
│                                                  │
│  ┌────────────────────────────────────────────┐ │
│  │  Z80 asm код (Zuma логика)                 │ │
│  │  - VDC physics (chain, balls)              │ │
│  │  - InsertAt, DoGapStep, CheckMatch3        │ │
│  │  - Display List генерация                  │ │
│  └────────────┬───────────────────────────────┘ │
│               │                                  │
│               │ sjasmplus                        │
│               ▼                                  │
│  ┌────────────────────────────────────────────┐ │
│  │  zuma.sna (Z80 binary)                     │ │
│  └────────────┬───────────────────────────────┘ │
│               │                                  │
│       ┌───────┴────────┐                        │
│       ▼                ▼                         │
│  ┌──────────┐    ┌──────────────┐               │
│  │ Реальный │    │ Python Z80   │               │
│  │ ZX Evo   │    │ Simulator    │               │
│  │ + VDAC2  │    │ (kosarev/z80)│               │
│  └────┬─────┘    └──────┬───────┘               │
│       │                  │                       │
│       │ SPI              │ Display List          │
│       │                  │ commands              │
│       ▼                  ▼                       │
│  ┌──────────┐    ┌────────────────────────────┐ │
│  │ FT812    │    │ Bridgetek MSVC Emulator    │ │
│  │ (железо) │    │ (Windows эмулятор FT812)   │ │
│  └────┬─────┘    └──────┬─────────────────────┘ │
│       │                  │                       │
│       ▼                  ▼                       │
│  ┌──────────┐    ┌────────────────────┐         │
│  │ Монитор  │    │ Окно эмулятора     │         │
│  │ 640×480  │    │ 640×480 (скриншот) │         │
│  └──────────┘    └──────────┬─────────┘         │
│                              │                   │
│                              ▼                   │
│              ┌────────────────────────────┐     │
│              │  Auto-сравнение скриншотов │     │
│              │  с эталоном                │     │
│              └────────────────────────────┘     │
└──────────────────────────────────────────────────┘
```

### Преимущества подхода

1. **Z80 логика** тестируется в Python симуляторе
2. **Графика** проверяется в официальном FT812 эмуляторе
3. **Auto-тесты** через сравнение скриншотов
4. **CI/CD ready** — всё автоматизируется
5. **Без железа** — разработка где угодно

---

## Способы интеграции с Z80 кодом

### Способ 1: Файловый обмен (рекомендуется)

**Самый простой и надёжный.**

#### Z80 симулятор пишет Display List:

```python
# Python код для дампа Display List
def dump_display_list(sim, filename):
    """Дамп RAM_DL после кадра Zuma"""
    dl_bytes = sim.get_memory(RAM_DL_ADDR, 8192)
    with open(filename, 'wb') as f:
        f.write(dl_bytes)

# В тесте
sim.run_frame()
dump_display_list(sim, 'frames/frame_001.dl')
```

#### C код в эмуляторе читает и выполняет:

```c
// load_dl.c
#include "Common.h"
#include "EVE_Hal.h"

void load_and_render_dl(const char* filename) {
    FILE* f = fopen(filename, "rb");
    if (!f) {
        printf("Cannot open %s\n", filename);
        return;
    }
    
    // Начинаем новый Display List
    EVE_Cmd_wr32(s_pHalContext, CMD_DLSTART);
    
    // Читаем команды по 4 байта
    uint32_t cmd;
    int count = 0;
    while (fread(&cmd, 4, 1, f) == 1) {
        EVE_Cmd_wr32(s_pHalContext, cmd);
        count++;
        
        // Если встретили DISPLAY - конец списка
        if (cmd == DISPLAY()) {
            break;
        }
    }
    
    fclose(f);
    
    EVE_CoCmd_swap(s_pHalContext);
    EVE_Cmd_waitflush(s_pHalContext);
    
    printf("Loaded %d commands from %s\n", count, filename);
}
```

### Способ 2: TCP socket (для удалённой отладки)

#### Z80 симулятор как клиент:

```python
import socket

class FT812Client:
    def __init__(self, host='localhost', port=8888):
        self.sock = socket.socket()
        self.sock.connect((host, port))
    
    def send_display_list(self, dl_bytes):
        """Отправить Display List в эмулятор"""
        self.sock.send(len(dl_bytes).to_bytes(4, 'little'))
        self.sock.send(dl_bytes)
    
    def get_screenshot(self):
        """Получить скриншот результата"""
        size_bytes = self.sock.recv(4)
        size = int.from_bytes(size_bytes, 'little')
        screenshot = b''
        while len(screenshot) < size:
            screenshot += self.sock.recv(size - len(screenshot))
        return screenshot

# Использование
client = FT812Client()
sim.run_frame()
dl = sim.get_memory(RAM_DL_ADDR, 8192)
client.send_display_list(dl)
screenshot = client.get_screenshot()
```

#### C эмулятор как сервер:

```c
// tcp_server.c
#include <winsock2.h>

void start_tcp_server(int port) {
    WSADATA wsa;
    SOCKET server, client;
    struct sockaddr_in server_addr;
    
    WSAStartup(MAKEWORD(2,2), &wsa);
    server = socket(AF_INET, SOCK_STREAM, 0);
    
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(port);
    
    bind(server, (struct sockaddr*)&server_addr, sizeof(server_addr));
    listen(server, 3);
    
    printf("Server listening on port %d\n", port);
    
    while (1) {
        client = accept(server, NULL, NULL);
        
        // Получаем размер
        uint32_t size;
        recv(client, (char*)&size, 4, 0);
        
        // Получаем данные
        uint8_t* dl = malloc(size);
        recv(client, (char*)dl, size, 0);
        
        // Выполняем
        EVE_Cmd_wr32(s_pHalContext, CMD_DLSTART);
        for (int i = 0; i < size; i += 4) {
            uint32_t cmd = *(uint32_t*)(dl + i);
            EVE_Cmd_wr32(s_pHalContext, cmd);
        }
        EVE_CoCmd_swap(s_pHalContext);
        EVE_Cmd_waitflush(s_pHalContext);
        
        // Делаем скриншот и отправляем обратно
        send_screenshot(client);
        
        free(dl);
        closesocket(client);
    }
}
```

### Способ 3: Shared memory (самый быстрый)

```c
// Windows shared memory
HANDLE hMap = CreateFileMappingA(
    INVALID_HANDLE_VALUE,
    NULL,
    PAGE_READWRITE,
    0,
    8192,
    "ZumaFrame"
);
uint8_t* shared = MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 8192);

// Эмулятор читает из shared
while (1) {
    // Ждём обновления
    if (shared[0] == 1) {  // Frame ready flag
        // Выполняем DL из shared
        execute_dl(shared + 1);
        shared[0] = 0;  // Подтверждение
    }
}
```

```python
# Python пишет в shared memory
import mmap

shm = mmap.mmap(-1, 8192, "ZumaFrame")

# Записываем DL
shm.seek(1)
shm.write(dl_bytes)

# Устанавливаем флаг
shm.seek(0)
shm.write(b'\x01')

# Ждём подтверждения
while shm[0] != 0:
    time.sleep(0.001)
```

---

## Пошаговая инструкция установки

### Полная установка EveApps MSVC Emulator

#### Шаг 1: Установка Visual Studio (30 минут)

```
1. Скачать Visual Studio Community 2022
   https://visualstudio.microsoft.com/downloads/

2. При установке выбрать:
   ✅ Desktop development with C++
   ✅ Windows 10/11 SDK
   ✅ MSVC v143 build tools

3. Запустить установку
```

#### Шаг 2: Установка EVE Screen Editor (10 минут)

```
1. Скачать EVE Toolchain
   https://brtchip.com/toolchains/

2. Установить EVE Screen Editor
   (он содержит библиотеки эмулятора)

3. Проверить установку:
   C:\Program Files\Bridgetek\EVE Screen Editor\
```

#### Шаг 3: Клонирование EveApps (5 минут)

```bash
cd C:\Projects
git clone https://github.com/Bridgetek/EveApps.git
cd EveApps
```

#### Шаг 4: Открытие проекта

```
1. Открыть Visual Studio

2. File → Open → Project/Solution

3. Выбрать:
   C:\Projects\EveApps\SampleApp\Project\MSVC_Emulator\SampleApp.sln

4. Выбрать конфигурацию:
   - Solution Configuration: Debug
   - Solution Platform: x86 или x64
```

#### Шаг 5: Настройка EVE_GRAPHICS_TARGET

В `EveApps/common/eve_hal/EVE_Config.h` или в Project Properties:

```c
// Выбрать FT812 как target
#define EVE_GRAPHICS_TARGET EVE_GRAPHICS_FT812
```

#### Шаг 6: Первый запуск

```
1. Build → Build Solution (F7)
   Если ошибки - проверить пути к ESE библиотекам

2. Debug → Start Without Debugging (Ctrl+F5)

3. Должно открыться окно:
   ┌─────────────────────────────────┐
   │  FT812 Emulator - SampleApp     │
   ├─────────────────────────────────┤
   │                                 │
   │   [Эмулированный экран 640x480] │
   │                                 │
   └─────────────────────────────────┘
```

#### Шаг 7: Проверка работы

Должна отображаться демо-сцена. Если работает — поздравляю, эмулятор готов! 🎉

---

## Шаблоны C кода для Zuma

### Базовый шаблон для тестирования Zuma

#### zuma_test.c

```c
/**
 * Тестовое приложение для отладки Zuma на FT812 Emulator
 */

#include "Common.h"
#include "EVE_Hal.h"
#include "EVE_CoCmd.h"
#include <stdio.h>
#include <string.h>

EVE_HalContext s_halContext;
EVE_HalContext *s_pHalContext;

// === Константы Zuma ===
#define MAX_BALLS         240
#define BALL_SIZE         32
#define SCREEN_W          640
#define SCREEN_H          480

// === Структуры ===
typedef struct {
    int16_t x, y;
    uint8_t color;     // 0..5
    uint8_t active;
} ball_t;

ball_t balls[MAX_BALLS];
int num_balls = 0;
int16_t frog_x = 320, frog_y = 240;
uint8_t frog_color = 0;

// === Адреса в RAM_G ===
#define RAM_G_BACKGROUND   0x000000  // 75 KB ASTC или 600KB RGB565
#define RAM_G_BALLS_ATLAS  0x100000  // Атлас шаров (6 цветов × 32×32)
#define RAM_G_FROG         0x110000  // Лягушка

// === Bitmap handles ===
#define HANDLE_BACKGROUND  0
#define HANDLE_BALLS       1
#define HANDLE_FROG        2

/**
 * Инициализация графики
 */
void init_graphics(void) {
    // Загрузить ассеты в RAM_G
    // load_background_from_file("level1_bg.bin");
    // load_balls_atlas("balls.bin");
    // load_frog_sprite("frog.bin");
    
    // Настроить bitmap handles
    EVE_Cmd_wr32(s_pHalContext, CMD_DLSTART);
    
    // Фон
    EVE_Cmd_wr32(s_pHalContext, BITMAP_HANDLE(HANDLE_BACKGROUND));
    EVE_Cmd_wr32(s_pHalContext, BITMAP_SOURCE(RAM_G_BACKGROUND));
    EVE_Cmd_wr32(s_pHalContext, BITMAP_LAYOUT(RGB565, 640*2, 480));
    EVE_Cmd_wr32(s_pHalContext, BITMAP_SIZE(NEAREST, BORDER, BORDER, 640, 480));
    
    // Шары
    EVE_Cmd_wr32(s_pHalContext, BITMAP_HANDLE(HANDLE_BALLS));
    EVE_Cmd_wr32(s_pHalContext, BITMAP_SOURCE(RAM_G_BALLS_ATLAS));
    EVE_Cmd_wr32(s_pHalContext, BITMAP_LAYOUT(ARGB4, 32*2, 32));
    EVE_Cmd_wr32(s_pHalContext, BITMAP_SIZE(BILINEAR, BORDER, BORDER, 32, 32));
    
    // Лягушка
    EVE_Cmd_wr32(s_pHalContext, BITMAP_HANDLE(HANDLE_FROG));
    EVE_Cmd_wr32(s_pHalContext, BITMAP_SOURCE(RAM_G_FROG));
    EVE_Cmd_wr32(s_pHalContext, BITMAP_LAYOUT(ARGB4, 96*2, 96));
    EVE_Cmd_wr32(s_pHalContext, BITMAP_SIZE(BILINEAR, BORDER, BORDER, 96, 96));
    
    EVE_CoCmd_swap(s_pHalContext);
    EVE_Cmd_waitflush(s_pHalContext);
}

/**
 * Рендеринг кадра Zuma
 */
void render_zuma_frame(void) {
    EVE_Cmd_wr32(s_pHalContext, CMD_DLSTART);
    EVE_Cmd_wr32(s_pHalContext, CLEAR_COLOR_RGB(0, 0, 0));
    EVE_Cmd_wr32(s_pHalContext, CLEAR(1, 1, 1));
    
    // === Слой 1: Фон ===
    EVE_Cmd_wr32(s_pHalContext, BEGIN(BITMAPS));
    EVE_Cmd_wr32(s_pHalContext, VERTEX2II(0, 0, HANDLE_BACKGROUND, 0));
    EVE_Cmd_wr32(s_pHalContext, END());
    
    // === Слой 2: Шары цепи ===
    EVE_Cmd_wr32(s_pHalContext, BEGIN(BITMAPS));
    for (int i = 0; i < num_balls; i++) {
        if (!balls[i].active) continue;
        
        EVE_Cmd_wr32(s_pHalContext, 
            VERTEX2II(balls[i].x, balls[i].y, HANDLE_BALLS, balls[i].color));
    }
    EVE_Cmd_wr32(s_pHalContext, END());
    
    // === Слой 3: Лягушка ===
    EVE_Cmd_wr32(s_pHalContext, BEGIN(BITMAPS));
    EVE_Cmd_wr32(s_pHalContext, 
        VERTEX2II(frog_x - 48, frog_y - 48, HANDLE_FROG, 0));
    EVE_Cmd_wr32(s_pHalContext, END());
    
    EVE_Cmd_wr32(s_pHalContext, DISPLAY());
    EVE_CoCmd_swap(s_pHalContext);
    EVE_Cmd_waitflush(s_pHalContext);
}

/**
 * Загрузка состояния из файла (от Z80 симулятора)
 */
void load_state_from_file(const char* filename) {
    FILE* f = fopen(filename, "rb");
    if (!f) return;
    
    // Читаем количество шаров
    fread(&num_balls, sizeof(int), 1, f);
    
    // Читаем массив шаров
    fread(balls, sizeof(ball_t), num_balls, f);
    
    // Читаем позицию лягушки
    fread(&frog_x, sizeof(int16_t), 1, f);
    fread(&frog_y, sizeof(int16_t), 1, f);
    fread(&frog_color, sizeof(uint8_t), 1, f);
    
    fclose(f);
    
    printf("Loaded state: %d balls, frog at (%d, %d)\n", 
           num_balls, frog_x, frog_y);
}

/**
 * Главный цикл
 */
int main(int argc, char *argv[]) {
    s_pHalContext = &s_halContext;
    Gpu_Init(s_pHalContext);
    
    init_graphics();
    
    // Загружаем тестовое состояние
    if (argc > 1) {
        load_state_from_file(argv[1]);
    } else {
        // Демо: расставляем шары по кругу
        num_balls = 20;
        for (int i = 0; i < num_balls; i++) {
            float angle = i * 2.0f * 3.14159f / num_balls;
            balls[i].x = 320 + (int)(150 * cosf(angle));
            balls[i].y = 240 + (int)(150 * sinf(angle));
            balls[i].color = i % 6;
            balls[i].active = 1;
        }
    }
    
    // Главный цикл
    while (1) {
        render_zuma_frame();
        Sleep(16);  // 60 FPS
    }
    
    return 0;
}
```

### Шаблон для приёма Display List по сети

#### dl_server.c

```c
/**
 * TCP сервер для приёма Display List от Z80 симулятора
 */

#include "Common.h"
#include "EVE_Hal.h"
#include <winsock2.h>
#include <stdio.h>

#pragma comment(lib, "ws2_32.lib")

EVE_HalContext s_halContext;
EVE_HalContext *s_pHalContext;

#define SERVER_PORT 8888

void execute_display_list(uint8_t* dl, int size) {
    EVE_Cmd_wr32(s_pHalContext, CMD_DLSTART);
    
    for (int i = 0; i < size; i += 4) {
        uint32_t cmd = *(uint32_t*)(dl + i);
        EVE_Cmd_wr32(s_pHalContext, cmd);
        
        // Если встретили DISPLAY - выходим
        if (cmd == 0) break;  // 0 = DISPLAY()
    }
    
    EVE_CoCmd_swap(s_pHalContext);
    EVE_Cmd_waitflush(s_pHalContext);
}

void start_server(void) {
    WSADATA wsa;
    SOCKET server, client;
    struct sockaddr_in server_addr;
    
    WSAStartup(MAKEWORD(2,2), &wsa);
    
    server = socket(AF_INET, SOCK_STREAM, 0);
    
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = INADDR_ANY;
    server_addr.sin_port = htons(SERVER_PORT);
    
    bind(server, (struct sockaddr*)&server_addr, sizeof(server_addr));
    listen(server, 3);
    
    printf("FT812 Emulator listening on port %d\n", SERVER_PORT);
    
    while (1) {
        client = accept(server, NULL, NULL);
        printf("Client connected\n");
        
        // Бесконечный цикл обработки команд
        while (1) {
            uint32_t size;
            int got = recv(client, (char*)&size, 4, 0);
            if (got <= 0) break;
            
            uint8_t* dl = (uint8_t*)malloc(size);
            int total = 0;
            while (total < size) {
                got = recv(client, (char*)(dl + total), size - total, 0);
                if (got <= 0) break;
                total += got;
            }
            
            execute_display_list(dl, total);
            
            // Отправляем подтверждение
            uint32_t ack = 0xCAFEBABE;
            send(client, (char*)&ack, 4, 0);
            
            free(dl);
        }
        
        closesocket(client);
        printf("Client disconnected\n");
    }
    
    closesocket(server);
    WSACleanup();
}

int main(int argc, char *argv[]) {
    s_pHalContext = &s_halContext;
    Gpu_Init(s_pHalContext);
    
    // Базовая инициализация графики
    init_graphics();
    
    // Запускаем сервер в отдельном потоке или прямо здесь
    start_server();
    
    return 0;
}
```

---

## Workflow для отладки tail-glitch

### Полный сценарий тестирования

```python
#!/usr/bin/env python3
"""
test_tail_glitch.py - автоматический тест для отладки tail-glitch
"""

import socket
import struct
from zuma_z80_simulator import ZumaZ80Simulator

def test_tail_glitch_visual():
    """
    Воспроизводит tail-glitch и сравнивает визуальный результат
    с эмулятором FT812 и Python reference.
    """
    
    # === ШАГ 1: Запускаем Z80 симулятор ===
    sim = ZumaZ80Simulator(sna_file='zuma.sna')
    
    # === ШАГ 2: Подключаемся к FT812 эмулятору ===
    ft812 = socket.socket()
    ft812.connect(('localhost', 8888))
    
    # === ШАГ 3: Инициализация ===
    sim.call_routine(VDC_INIT_ADDR)
    
    # === ШАГ 4: Заполнение цепи до HSA == cap ===
    print("Phase 1: Filling chain to cap...")
    for i in range(200):
        sim.call_routine(VDC_UPDATE_ADDR)
        
        # Каждые 10 кадров - сравнение
        if i % 10 == 0:
            # Дамп Display List
            dl = sim.get_memory(RAM_DL_ADDR, 8192)
            
            # Отправляем в эмулятор
            ft812.send(len(dl).to_bytes(4, 'little'))
            ft812.send(dl)
            
            # Ждём подтверждения
            ack = ft812.recv(4)
            
            # Получаем скриншот для сравнения
            screenshot = capture_emulator_screenshot()
            
            # Сохраняем эталон
            screenshot.save(f'frames/frame_{i:03d}.png')
    
    # === ШАГ 5: Проверка HSA == cap ===
    hsa = sim.get_byte(VDC_HSA_ADDR)
    cap = sim.get_word(VDC_TRACKNUMSLOTS_ADDR)
    print(f"HSA={hsa}, cap={cap}")
    
    if hsa != cap:
        print("⚠️ HSA не достиг cap - баг не воспроизведется")
        return
    
    # === ШАГ 6: Снимок ДО insert ===
    print("\nPhase 2: State BEFORE InsertAt...")
    sim.dump_vdc_state()
    
    # Снимок экрана ДО
    dl = sim.get_memory(RAM_DL_ADDR, 8192)
    ft812.send(len(dl).to_bytes(4, 'little'))
    ft812.send(dl)
    ft812.recv(4)
    save_screenshot('before_insert.png')
    
    # === ШАГ 7: Insert в середину ===
    slots_len = sim.get_byte(VDC_SLOTSLEN_ADDR)
    target_idx = slots_len // 2
    color = 1
    
    print(f"\nPhase 3: InsertAt(idx={target_idx}, color={color})...")
    sim.call_routine(VDC_INSERTAT_ADDR, a=target_idx, b=color)
    
    # === ШАГ 8: Снимок ПОСЛЕ insert ===
    print("\nPhase 4: State AFTER InsertAt...")
    sim.dump_vdc_state()
    
    # Снимок экрана ПОСЛЕ
    dl = sim.get_memory(RAM_DL_ADDR, 8192)
    ft812.send(len(dl).to_bytes(4, 'little'))
    ft812.send(dl)
    ft812.recv(4)
    save_screenshot('after_insert.png')
    
    # === ШАГ 9: Сравнение ===
    print("\n=== АНАЛИЗ ===")
    print("Сравните before_insert.png и after_insert.png")
    print("Проверьте появился ли 'лишний шар в хвосте'")
    
    # Авто-сравнение через PIL
    from PIL import Image, ImageChops
    
    before = Image.open('before_insert.png')
    after = Image.open('after_insert.png')
    
    diff = ImageChops.difference(before, after)
    diff.save('diff.png')
    
    # Анализ изменений в области tail
    tail_region = diff.crop((0, 0, 640, 100))  # Верхняя часть = tail
    
    # Считаем количество изменённых пикселей
    changed_pixels = sum(1 for p in tail_region.getdata() if p != (0, 0, 0))
    
    if changed_pixels > 1000:
        print(f"⚠️ БАГ ВОСПРОИЗВЕДЁН: {changed_pixels} пикселей изменилось в tail области")
    else:
        print(f"✓ Tail область не изменилась ({changed_pixels} пикселей)")
    
    ft812.close()


def capture_emulator_screenshot():
    """Захват скриншота эмулятора"""
    # Windows: используем PyAutoGUI или Win32 API
    import pyautogui
    
    # Найти окно эмулятора и сделать скриншот
    # ... код захвата окна ...
    pass


def save_screenshot(filename):
    """Сохранение скриншота"""
    screenshot = capture_emulator_screenshot()
    screenshot.save(filename)


if __name__ == '__main__':
    test_tail_glitch_visual()
```

### Структура файлов проекта

```
zuma_project/
├── src/
│   ├── VDC.asm
│   ├── Bullet.asm
│   ├── Frog.asm
│   └── ...
├── build/
│   ├── zuma.sna
│   ├── zuma.sym
│   └── zuma.lst
├── emulator/
│   ├── ft812_server.c          ← TCP server для приёма DL
│   ├── ft812_server.sln        ← Visual Studio project
│   └── ft812_server.exe        ← Скомпилированный эмулятор
├── tests/
│   ├── zuma_z80_simulator.py   ← Z80 эмулятор
│   ├── test_tail_glitch.py     ← Авто-тест
│   ├── frames/                  ← Эталонные скриншоты
│   └── reference/
│       └── vdc_visual_emulator.py
├── docs/
│   └── ft812_emulator_guide.md  ← Этот документ
└── Makefile
```

### Makefile для автоматизации

```makefile
.PHONY: all build test emulator clean

all: build emulator

build:
	sjasmplus src/main.asm \
		--output=build/zuma.sna \
		--sym=build/zuma.sym \
		--lst=build/zuma.lst

emulator:
	@echo "Запустите вручную emulator/ft812_server.exe"
	@echo "Или используйте скрипт run_emulator.bat"

test: build
	# Запускаем эмулятор в фоне
	start emulator/ft812_server.exe
	# Даём время на запуск
	timeout 3
	# Запускаем тесты
	python tests/test_tail_glitch.py
	# Закрываем эмулятор
	taskkill /F /IM ft812_server.exe

clean:
	rm -rf build/
	rm -f tests/frames/*.png
	rm -f tests/*.png
```

---

## Полезные ссылки

### Официальные ресурсы Bridgetek

- **Главная страница EVE:** https://brtchip.com/eve/
- **EVE Toolchain (ESE):** https://brtchip.com/toolchains/
- **GitHub Bridgetek:** https://github.com/Bridgetek
- **EveApps репо:** https://github.com/Bridgetek/EveApps
- **EVE-MCU-Dev:** https://github.com/Bridgetek/Eve-MCU-Dev

### Документация

- **FT81x Datasheet:** https://brtchip.com/wp-content/uploads/Support/Documentation/Datasheets/ICs/EVE/DS_FT81x.pdf
- **FT81x Programmers Guide:** https://brtchip.com/wp-content/uploads/Support/Documentation/Programming_Guides/ICs/EVE/FT81X_Series_Programmer_Guide.pdf
- **AN_391 EVE Platform Guide:** https://brtchip.com/wp-content/uploads/sites/3/2021/10/AN_391-EVE-Platform-Guide.pdf

### Community библиотеки

- **RudolphRiedel FT800-FT813:** https://github.com/RudolphRiedel/FT800-FT813
- **Skygauge FT8XX:** https://github.com/Skygauge/FT8XX
- **Riverdi EVE:** https://github.com/riverdi/riverdi-eve
- **CircuitPython _eve:** https://docs.circuitpython.org/en/latest/shared-bindings/_eve/index.html

### Инструменты разработки

- **Visual Studio Community:** https://visualstudio.microsoft.com/
- **sjasmplus:** https://github.com/z00m128/sjasmplus
- **kosarev/z80 (Python Z80):** https://github.com/kosarev/z80

### Форумы и поддержка

- **Bridgetek Community:** https://www.brtcommunity.com/
- **TS Labs Forum:** https://forum.tslabs.info/
- **ZX-PK:** https://zx-pk.ru/

---

## Заключение

### Что мы получаем:

✅ **Полноценный эмулятор FT812** от производителя (бесплатно)  
✅ **Не нужно писать свой эмулятор** (экономия 6-10 недель)  
✅ **100% совместимость** с реальным железом  
✅ **Интеграция через файлы/сети/shared memory**  
✅ **Автоматическое тестирование** возможно  
✅ **CI/CD ready**  
✅ **Не требует Python** — любой язык

### Следующие шаги:

1. **Установить Visual Studio Community** (если не установлен)
2. **Скачать EveApps** с GitHub
3. **Установить EVE Screen Editor** (для библиотек эмулятора)
4. **Открыть SampleApp.sln** и запустить эмулятор
5. **Адаптировать под Zuma** (использовать шаблоны выше)
6. **Создать TCP server** для интеграции с Z80 симулятором
7. **Настроить автоматические тесты**

### Принцип решения:

> "Используй готовые решения когда они есть. Изобретай новое только когда нет альтернатив."

Bridgetek предоставляет всё необходимое **бесплатно и с открытым кодом**. Используйте это!

---

**Документ создан:** 2026-05-08  
**Версия:** 1.0  
**Платформа:** ZX Evolution + VDAC2 (FT812)  
**Проект:** Zuma Deluxe port  
**Автор:** Claude (Anthropic)  
**Лицензия:** MIT / CC BY 4.0

---

*Удачи с разработкой Zuma на ZX Evolution! 🎮🚀*
