# ZX Evolution VDAC2 (FT812) Background Optimization Guide

## Руководство по оптимизации фоновых изображений для игры Zuma на ZX Evolution с VDAC2

---

## 📋 Оглавление

1. [Введение](#введение)
2. [Проблема Bilinear Upscale](#проблема-bilinear-upscale)
3. [Технические характеристики](#технические-характеристики)
4. [Решения для оптимизации](#решения-для-оптимизации)
5. [ASTC Compression](#astc-compression)
6. [Практические примеры кода](#практические-примеры-кода)
7. [Workflow и инструменты](#workflow-и-инструменты)
8. [Сравнительная таблица методов](#сравнительная-таблица-методов)

---

## Введение

При разработке Zuma Deluxe для ZX Evolution с VDAC2 (FT812) на разрешении **640×480** возникает проблема оптимизации использования видеопамяти для фоновых изображений.

### Текущая ситуация:
- **Разрешение экрана**: 640×480 (VDAC2/FT812)
- **Фоны**: Upscale с низкого разрешения (320×240) с bilinear фильтрацией
- **Проблема**: Размытое изображение, потеря качества
- **RAM_G (FT812)**: 1 МБ доступной памяти

---

## Проблема Bilinear Upscale

### Текущий подход:

```
Фон: 320×240 RGB565
Размер: 320 × 240 × 2 = 153,600 байт = 150 КБ
        ↓
    Bilinear Upscale
        ↓
Экран: 640×480
Результат: Размытая картинка 😞
```

### Почему это плохо:

1. **Потеря четкости**: Bilinear интерполяция создает размытие
2. **Артефакты**: Видны переходы между пикселями
3. **Непрофессиональный вид**: Игра выглядит "мыльной"

### Альтернатива Nearest Neighbor:

```c
// Вместо размытия
FT81x_Cmd_DL(BITMAP_SIZE(BILINEAR, BORDER, BORDER, 640, 480));

// Используйте четкие пиксели
FT81x_Cmd_DL(BITMAP_SIZE(NEAREST, BORDER, BORDER, 640, 480));
```

**Результат**: Pixel-art стиль, четкие границы, ретро-вид (подходит для Zuma!)

---

## Технические характеристики

### FT812 (VDAC2) Спецификации:

- **RAM_G**: 1,048,576 байт (1 МБ) для графических данных
- **Display List**: 8 КБ команд отрисовки
- **Command FIFO**: 4 КБ буфер команд
- **Разрешения**: до 1024×768 (и выше нестандартные)
- **Аппаратная декомпрессия**: ASTC форматы

### Поддерживаемые форматы текстур:

#### Несжатые:
- **RGB565** - 16 бит/пиксель (65,536 цветов)
- **ARGB1555** - 16 бит/пиксель (1-bit альфа)
- **ARGB4** - 16 бит/пиксель (4-bit альфа)
- **L8** - 8 бит/пиксель (grayscale)

#### Сжатые (ASTC):
- **ASTC 4×4** - ~8 бит/пиксель (лучшее качество)
- **ASTC 6×6** - ~3.56 бит/пиксель (баланс)
- **ASTC 8×8** - ~2 бит/пиксель (макс. сжатие)
- **ASTC 10×10, 12×12** - экстремальное сжатие

#### Паллетные:
- **PALETTED565** - 8-bit индекс + RGB565 палитра (256 цветов)
- **PALETTED4444** - 4-bit + ARGB4444 палитра

---

## Решения для оптимизации

### Решение 1: Nearest Neighbor Upscale

**Сложность**: ⭐ (5 минут)  
**Улучшение качества**: ⭐⭐⭐  
**Экономия памяти**: 150 КБ (как было)

#### Преимущества:
- ✅ Быстрое внедрение (одна строка кода)
- ✅ Четкие пиксели (pixel-art стиль)
- ✅ Никакого размытия
- ✅ Подходит для ретро-игр

#### Код:
```c
FT81x_Cmd_DL(BITMAP_SIZE(NEAREST, BORDER, BORDER, 640, 480));
```

---

### Решение 2: ASTC Compression (РЕКОМЕНДУЕТСЯ)

**Сложность**: ⭐⭐ (1-2 часа)  
**Улучшение качества**: ⭐⭐⭐⭐⭐  
**Экономия памяти**: 75 КБ (вдвое лучше!)

#### Сравнение:

```
БЫЛО:
320×240 RGB565 = 150 КБ
  ↓ Bilinear upscale
640×480 размытый фон

СТАНЕТ:
640×480 ASTC 8×8 = 75 КБ
  ↓ Аппаратная декомпрессия
640×480 четкий фон в нативном разрешении!
```

#### Преимущества:
- ✅ **Вдвое меньше памяти** (75 КБ vs 150 КБ)
- ✅ **Нативное разрешение** 640×480
- ✅ **Отличное качество** (почти как оригинал)
- ✅ **Аппаратная декомпрессия** (не тратит CPU)
- ✅ **Поддержка FT812** из коробки

#### Расчет памяти:

| Формат | Размер | Качество |
|--------|--------|----------|
| RGB565 (640×480) | 600 КБ | ⭐⭐⭐⭐⭐ |
| RGB565 (320×240) | 150 КБ | ⭐⭐ (upscale) |
| ASTC 4×4 (640×480) | 300 КБ | ⭐⭐⭐⭐⭐ |
| ASTC 6×6 (640×480) | 135 КБ | ⭐⭐⭐⭐ |
| **ASTC 8×8 (640×480)** | **75 КБ** | **⭐⭐⭐⭐** ✅ |

---

### Решение 3: Гибридный подход

**Сложность**: ⭐⭐⭐  
**Качество**: ⭐⭐⭐⭐⭐  

Разделите фон на слои:

```
Слой 1: Статичный декоративный фон
  → ASTC 8×8 (640×480, 75 КБ)

Слой 2: Игровой путь (где катятся шары)
  → RGB565 или векторная отрисовка
  → Высокая четкость для важных элементов

Слой 3: Декорации
  → Процедурная генерация (0 байт памяти!)
```

---

### Решение 4: Процедурная генерация

**Сложность**: ⭐⭐⭐⭐  
**Экономия памяти**: **0 байт!**

FT812 поддерживает векторную графику:

```c
// Градиентный фон
FT81x_Cmd_Gradient(0, 0, 0x404040, 0, 480, 0x101010);

// Каменные текстуры точками
FT81x_Cmd_DL(POINT_SIZE(16*50));
FT81x_Cmd_DL(BEGIN(POINTS));
for (int i = 0; i < 100; i++) {
    FT81x_Cmd_DL(VERTEX2F(random_x * 16, random_y * 16));
}
FT81x_Cmd_DL(END());
```

---

## ASTC Compression

### Что такое ASTC?

**ASTC** (Adaptive Scalable Texture Compression) - современный формат сжатия текстур с:
- Гибким размером блоков (4×4 до 12×12)
- Отличным качеством при высокой степени сжатия
- Аппаратной декомпрессией в GPU
- Поддержкой альфа-канала

### Формула расчета размера:

```
Размер = (Ширина × Высота × Биты_на_пиксель) / 8

Для ASTC 8×8:
640 × 480 × 2 / 8 = 76,800 байт ≈ 75 КБ
```

### Выбор блока ASTC:

| Блок | Бит/пиксель | Качество | Применение |
|------|-------------|----------|------------|
| 4×4 | 8.00 | Отличное | Детальные текстуры |
| 6×6 | 3.56 | Хорошее | **Баланс** ✅ |
| 8×8 | 2.00 | Среднее | **Фоны** ✅ |
| 10×10 | 1.28 | Низкое | Размытые фоны |
| 12×12 | 0.89 | Очень низкое | Экстремальная экономия |

### Рекомендации для Zuma:

- **Фоны уровней**: ASTC 8×8 (75 КБ)
- **Детальные элементы**: ASTC 6×6 (135 КБ)
- **Если память критична**: ASTC 10×10 (40 КБ)

---

## Практические примеры кода

### 1. Загрузка ASTC текстуры

```c
#include <stdint.h>
#include "ft81x.h"
#include "level1_bg.h"  // Сгенерировано xxd

#define RAM_G_BACKGROUND 0x0000
#define RAM_G_SPRITES    0x20000

/**
 * Загрузка ASTC фона в RAM_G
 * @param astc_data - указатель на ASTC данные
 * @param size - размер данных в байтах
 */
void load_astc_background(const uint8_t* astc_data, uint32_t size) {
    // Загружаем сжатые данные в начало RAM_G
    FT81x_Write_RAM_G(RAM_G_BACKGROUND, astc_data, size);
    
    // Настраиваем bitmap handle 0 для фона
    FT81x_Cmd_DL(BITMAP_HANDLE(0));
    FT81x_Cmd_DL(BITMAP_SOURCE(RAM_G_BACKGROUND));
    
    // ASTC 8×8, размер 640×480
    FT81x_Cmd_DL(BITMAP_LAYOUT(COMPRESSED_RGBA_ASTC_8x8_KHR, 
                                 640/8*16,  // Stride: ширина/8 × 16 байт
                                 480));     // Высота
    
    // Настройка размера и фильтрации
    FT81x_Cmd_DL(BITMAP_SIZE(NEAREST,  // Или BILINEAR для сглаживания
                             BORDER,    // Wrap mode X
                             BORDER,    // Wrap mode Y
                             640,       // Ширина
                             480));     // Высота
}

/**
 * Отрисовка фона
 */
void draw_background(void) {
    FT81x_Cmd_DL(BEGIN(BITMAPS));
    FT81x_Cmd_DL(VERTEX2II(0, 0, 0, 0));  // X=0, Y=0, Handle=0, Cell=0
    FT81x_Cmd_DL(END());
}
```

### 2. Полный цикл отрисовки кадра

```c
/**
 * Отрисовка игровой сцены
 */
void draw_game_scene(Ball* balls, int num_balls, Frog* frog) {
    // Начало Display List
    FT81x_Cmd_DL_Start();
    
    // Очистка экрана
    FT81x_Cmd_DL(CLEAR_COLOR_RGB(0, 0, 0));
    FT81x_Cmd_DL(CLEAR(1, 1, 1));
    
    // === СЛОЙ 1: ФОН ===
    FT81x_Cmd_DL(BEGIN(BITMAPS));
    FT81x_Cmd_DL(VERTEX2II(0, 0, 0, 0));  // Handle 0 = фон
    FT81x_Cmd_DL(END());
    
    // === СЛОЙ 2: ШАРЫ ===
    FT81x_Cmd_DL(BEGIN(BITMAPS));
    for (int i = 0; i < num_balls; i++) {
        // Handle 1-6 = шары разных цветов
        FT81x_Cmd_DL(VERTEX2II(balls[i].x, 
                               balls[i].y, 
                               balls[i].color + 1,  // Handles 1-6
                               0));
    }
    FT81x_Cmd_DL(END());
    
    // === СЛОЙ 3: ЛЯГУШКА ===
    FT81x_Cmd_DL(BEGIN(BITMAPS));
    FT81x_Cmd_DL(VERTEX2II(frog->x, frog->y, 7, 0));  // Handle 7 = лягушка
    FT81x_Cmd_DL(END());
    
    // === СЛОЙ 4: UI ===
    // ... отрисовка счета, жизней и т.д.
    
    // Завершение
    FT81x_Cmd_DL(DISPLAY());
    FT81x_Cmd_Swap();
    FT81x_Cmd_DL_End();
}
```

### 3. Управление памятью RAM_G

```c
// Карта распределения памяти RAM_G (1 МБ)
#define RAM_G_SIZE          0x100000  // 1 МБ

// Адреса в RAM_G
#define RAM_G_BACKGROUND    0x000000  // 0-75 КБ: фон
#define RAM_G_BALL_RED      0x012C00  // 75 КБ: красный шар
#define RAM_G_BALL_BLUE     0x013200  // 76.5 КБ: синий шар
#define RAM_G_BALL_GREEN    0x013800  // 78 КБ: зеленый шар
#define RAM_G_BALL_YELLOW   0x013E00  // 79.5 КБ: желтый шар
#define RAM_G_BALL_PURPLE   0x014400  // 81 КБ: фиолетовый шар
#define RAM_G_BALL_WHITE    0x014A00  // 82.5 КБ: белый шар
#define RAM_G_FROG          0x015000  // 84 КБ: лягушка
#define RAM_G_UI_ELEMENTS   0x020000  // 128 КБ: UI элементы

/**
 * Инициализация всех графических ресурсов
 */
void init_graphics(void) {
    // Загружаем фон
    load_astc_background(level1_astc_data, level1_astc_size);
    
    // Загружаем спрайты шаров (32×32, PALETTED565)
    load_ball_sprite(1, ball_red_data,    RAM_G_BALL_RED);
    load_ball_sprite(2, ball_blue_data,   RAM_G_BALL_BLUE);
    load_ball_sprite(3, ball_green_data,  RAM_G_BALL_GREEN);
    load_ball_sprite(4, ball_yellow_data, RAM_G_BALL_YELLOW);
    load_ball_sprite(5, ball_purple_data, RAM_G_BALL_PURPLE);
    load_ball_sprite(6, ball_white_data,  RAM_G_BALL_WHITE);
    
    // Загружаем лягушку (100×100, ARGB4)
    load_frog_sprite(7, frog_data, RAM_G_FROG);
}

/**
 * Смена уровня (загрузка нового фона)
 */
void change_level(const uint8_t* new_bg_data, uint32_t size) {
    // Просто перезаписываем начало RAM_G новым фоном
    load_astc_background(new_bg_data, size);
    // Спрайты остаются на своих местах!
}
```

### 4. Загрузка спрайта шара

```c
/**
 * Загрузка спрайта шара в RAM_G
 * @param handle - номер bitmap handle (1-6)
 * @param data - пиксельные данные (32×32, PALETTED565)
 * @param addr - адрес в RAM_G
 */
void load_ball_sprite(uint8_t handle, 
                      const uint8_t* data, 
                      uint32_t addr) {
    // Загружаем данные (32×32 = 1024 байта)
    FT81x_Write_RAM_G(addr, data, 32*32);
    
    // Настраиваем bitmap
    FT81x_Cmd_DL(BITMAP_HANDLE(handle));
    FT81x_Cmd_DL(BITMAP_SOURCE(addr));
    FT81x_Cmd_DL(BITMAP_LAYOUT(PALETTED565, 32, 32));
    FT81x_Cmd_DL(BITMAP_SIZE(BILINEAR, BORDER, BORDER, 32, 32));
}
```

---

## Workflow и инструменты

### Установка ARM ASTC Encoder

#### Windows:
```bash
# Скачайте с GitHub
https://github.com/ARM-software/astc-encoder/releases

# Распакуйте astcenc-avx2.exe в PATH
```

#### macOS:
```bash
brew install astc-encoder
```

#### Linux:
```bash
# Скачайте бинарник или соберите из исходников
git clone https://github.com/ARM-software/astc-encoder.git
cd astc-encoder
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j4
sudo make install
```

### Конвертация изображений

#### Одиночная конвертация:
```bash
# Базовая конвертация (ASTC 8×8)
astcenc-avx2 -cl background.png background.astc 8x8 -medium

# Высокое качество (ASTC 6×6)
astcenc-avx2 -cl background.png background_hq.astc 6x6 -thorough

# Максимальное сжатие (ASTC 10×10)
astcenc-avx2 -cl background.png background_tiny.astc 10x10 -fast
```

#### Batch конвертация:

**convert_backgrounds.sh:**
```bash
#!/bin/bash
# Batch конвертация всех фонов в ASTC

INPUT_DIR="assets/backgrounds"
OUTPUT_DIR="build/astc"
BLOCK_SIZE="8x8"      # Измените на 6x6 для лучшего качества
QUALITY="-medium"     # Опции: -fast, -medium, -thorough, -exhaustive

mkdir -p "$OUTPUT_DIR"

echo "=== ASTC Batch Converter ==="
echo "Input:  $INPUT_DIR"
echo "Output: $OUTPUT_DIR"
echo "Block:  $BLOCK_SIZE"
echo "Quality: $QUALITY"
echo ""

for file in "$INPUT_DIR"/*.png; do
    if [ -f "$file" ]; then
        basename=$(basename "$file" .png)
        echo "Converting: $basename..."
        
        # Конвертация в ASTC
        astcenc-avx2 -cl "$file" \
                     "$OUTPUT_DIR/${basename}.astc" \
                     "$BLOCK_SIZE" \
                     "$QUALITY"
        
        # Создаем .h файл для включения в код
        xxd -i "$OUTPUT_DIR/${basename}.astc" \
            > "$OUTPUT_DIR/${basename}.h"
        
        # Показываем размер
        original_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file")
        astc_size=$(stat -f%z "$OUTPUT_DIR/${basename}.astc" 2>/dev/null || stat -c%s "$OUTPUT_DIR/${basename}.astc")
        ratio=$(echo "scale=2; $astc_size * 100 / $original_size" | bc)
        
        echo "  Original: $(numfmt --to=iec $original_size 2>/dev/null || echo $original_size bytes)"
        echo "  ASTC:     $(numfmt --to=iec $astc_size 2>/dev/null || echo $astc_size bytes)"
        echo "  Ratio:    ${ratio}%"
        echo ""
    fi
done

echo "=== Conversion Complete ==="
echo "Files saved to: $OUTPUT_DIR/"
```

**Использование:**
```bash
chmod +x convert_backgrounds.sh
./convert_backgrounds.sh
```

### Просмотр ASTC файлов

```bash
# Конвертация обратно в PNG для проверки
astcenc-avx2 -dl background.astc background_check.png

# Открыть в просмотрщике
open background_check.png   # macOS
xdg-open background_check.png   # Linux
start background_check.png  # Windows
```

### Интеграция в Makefile

```makefile
# Makefile для проекта Zuma

ASTC_ENCODER = astcenc-avx2
ASTC_BLOCK = 8x8
ASTC_QUALITY = -medium

BACKGROUND_SRCS = $(wildcard assets/backgrounds/*.png)
BACKGROUND_ASTC = $(patsubst assets/backgrounds/%.png,build/astc/%.astc,$(BACKGROUND_SRCS))
BACKGROUND_HEADERS = $(patsubst assets/backgrounds/%.png,build/astc/%.h,$(BACKGROUND_SRCS))

.PHONY: all backgrounds clean

all: backgrounds game.bin

backgrounds: $(BACKGROUND_ASTC) $(BACKGROUND_HEADERS)

build/astc/%.astc: assets/backgrounds/%.png
	@mkdir -p build/astc
	$(ASTC_ENCODER) -cl $< $@ $(ASTC_BLOCK) $(ASTC_QUALITY)

build/astc/%.h: build/astc/%.astc
	xxd -i $< > $@

clean:
	rm -rf build/astc

game.bin: src/*.c $(BACKGROUND_HEADERS)
	sjasmplus main.asm
```

---

## Сравнительная таблица методов

| Метод | Память | Качество | FPS | Сложность | Рекомендация |
|-------|--------|----------|-----|-----------|--------------|
| **320×240 RGB565 + Bilinear** | 150 КБ | ⭐⭐ | 60 | Легко | ❌ Не рекомендуется |
| **320×240 RGB565 + Nearest** | 150 КБ | ⭐⭐⭐ | 60 | **5 мин** | ✅ Быстрое улучшение |
| **640×480 RGB565** | 600 КБ | ⭐⭐⭐⭐⭐ | 60 | Легко | ⚠️ Много памяти |
| **640×480 ASTC 4×4** | 300 КБ | ⭐⭐⭐⭐⭐ | 60 | Средне | ⚠️ Еще много памяти |
| **640×480 ASTC 6×6** | 135 КБ | ⭐⭐⭐⭐ | 60 | Средне | ✅ Баланс качество/размер |
| **640×480 ASTC 8×8** | **75 КБ** | **⭐⭐⭐⭐** | **60** | **Средне** | **✅✅ РЕКОМЕНДУЕТСЯ** |
| **640×480 ASTC 10×10** | 40 КБ | ⭐⭐⭐ | 60 | Средне | ⚠️ Заметна компрессия |
| **Процедурная генерация** | 0 КБ | ⭐⭐⭐ | 50-60 | Сложно | ⭐ Для экспериментов |

### Детальное сравнение для 10 уровней Zuma:

| Параметр | RGB565 320×240 | ASTC 8×8 640×480 | Экономия |
|----------|----------------|------------------|----------|
| **Один фон** | 150 КБ | 75 КБ | **2× лучше** |
| **10 фонов** | 1.5 МБ | 750 КБ | **2× лучше** |
| **Качество** | ⭐⭐ (upscale) | ⭐⭐⭐⭐ (native) | **Намного лучше** |
| **Влезает в RAM_G** | Нет (1 уровень) | Да (+ спрайты) | **✅** |

---

## Практические советы

### 1. Оптимизация для разных уровней

```c
// Уровни с простыми фонами
level1_bg.astc → ASTC 10×10 (40 КБ)

// Уровни с детализированными фонами
level5_bg.astc → ASTC 6×6 (135 КБ)

// Финальный уровень (Space)
space_bg.astc → Процедурная генерация (0 КБ)
```

### 2. Предзагрузка следующего уровня

```c
void preload_next_level(int current_level) {
    // Загружаем следующий фон в свободную область RAM_G
    if (current_level < MAX_LEVELS - 1) {
        uint32_t preload_addr = RAM_G_PRELOAD;
        load_astc_to_address(level_backgrounds[current_level + 1],
                             preload_addr);
    }
}

void swap_to_next_level(void) {
    // Быстрая смена: просто меняем BITMAP_SOURCE
    FT81x_Cmd_DL(BITMAP_SOURCE(RAM_G_PRELOAD));
}
```

### 3. Тестирование качества

```bash
# Создайте несколько версий для сравнения
astcenc-avx2 -cl bg.png bg_4x4.astc 4x4 -thorough
astcenc-avx2 -cl bg.png bg_6x6.astc 6x6 -medium
astcenc-avx2 -cl bg.png bg_8x8.astc 8x8 -medium
astcenc-avx2 -cl bg.png bg_10x10.astc 10x10 -fast

# Конвертируйте обратно
astcenc-avx2 -dl bg_4x4.astc bg_4x4_check.png
astcenc-avx2 -dl bg_6x6.astc bg_6x6_check.png
astcenc-avx2 -dl bg_8x8.astc bg_8x8_check.png
astcenc-avx2 -dl bg_10x10.astc bg_10x10_check.png

# Сравните визуально
```

### 4. Профилирование памяти

```c
void print_memory_usage(void) {
    uint32_t used = RAM_G_PRELOAD;  // Последний используемый адрес
    uint32_t free = RAM_G_SIZE - used;
    
    printf("RAM_G Usage:\n");
    printf("  Used: %u KB (%.1f%%)\n", 
           used / 1024, 
           (used * 100.0) / RAM_G_SIZE);
    printf("  Free: %u KB (%.1f%%)\n", 
           free / 1024, 
           (free * 100.0) / RAM_G_SIZE);
}
```

---

## Итоговые рекомендации

### 🎯 План действий:

#### Этап 1: Быстрое улучшение (5 минут)
```c
// Замените BILINEAR на NEAREST
FT81x_Cmd_DL(BITMAP_SIZE(NEAREST, BORDER, BORDER, 640, 480));
```
**Результат**: Сразу четче, pixel-art вид ✅

#### Этап 2: Конвертация в ASTC (1-2 часа)
```bash
# Установите astcenc
# Запустите скрипт конвертации
./convert_backgrounds.sh

# Интегрируйте .h файлы в проект
```
**Результат**: Вдвое меньше памяти + нативное разрешение ✅✅

#### Этап 3: Оптимизация (опционально)
- Разные ASTC блоки для разных уровней
- Предзагрузка следующего фона
- Процедурная генерация декораций

---

## Заключение

**Для Zuma Deluxe на ZX Evolution VDAC2 (640×480):**

### ✅ Используйте:
- **ASTC 8×8** для фоновых изображений (75 КБ)
- **PALETTED565** для спрайтов шаров
- **NEAREST** фильтр для четких пикселей

### ❌ Избегайте:
- Bilinear upscale низкого разрешения
- Несжатые RGB565 фоны (600 КБ)
- DXT компрессию (не поддерживается FT812)

### 📊 Результат:
- **Память**: 75 КБ на фон вместо 150 КБ (2× экономия)
- **Качество**: Нативное 640×480 вместо upscale
- **Производительность**: 60 FPS, аппаратная декомпрессия
- **Влезает**: 10+ уровней в 1 МБ RAM_G

---

## Ссылки и ресурсы

### Инструменты:
- **ARM ASTC Encoder**: https://github.com/ARM-software/astc-encoder
- **FT81x Datasheet**: https://brtchip.com/wp-content/uploads/Support/Documentation/Datasheets/ICs/EVE/DS_FT81x.pdf

### Документация:
- **ASTC Specification**: https://www.khronos.org/registry/DataFormat/specs/1.3/dataformat.1.3.html#ASTC
- **FT812 Programming Guide**: https://brtchip.com/wp-content/uploads/Support/Documentation/Programming_Guides/ICs/EVE/FT81X_Series_Programmer_Guide.pdf

### Форумы:
- **ZX Evolution Forum**: https://forum.tslabs.info/
- **FTDI Community**: https://www.ftdichip.com/Support/Knowledgebase.htm

---

**Документ создан**: 2026-05-08  
**Версия**: 1.0  
**Автор**: Claude (Anthropic)  
**Лицензия**: MIT / CC BY 4.0

---

*Удачи с оптимизацией Zuma Deluxe для ZX Evolution! 🎮🚀*