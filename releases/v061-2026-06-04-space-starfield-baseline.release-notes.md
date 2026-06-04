## v061: опорная версия со звёздным небом Space

Релиз после v056 boot GS/SFX baseline.

### Space

- Добавлено процедурное анимированное звёздное небо для финального уровня Space.
- 3 параллакс-слоя через FT812 `POINTS`, по 24 звезды на слой.
- Порядок рендера: фон уровня -> звёзды Space -> gameplay bitmap-слои.
- Новые RAM_G-ассеты не требуются, persistent state для звёзд не используется.
- Добавлен статический тест `test_space_starfield_static.py`.

### Boot / загрузка / GS

- Boot loading background переведён на DXT-L4 raw pages.
- После разрушительной попытки boot GS-диагностики визуальный boot/menu path возвращён к стабильной опоре.
- Определение памяти GS оставлено WC-совместимым: команда `#23`, один байт ответа.
- Загрузка SFX gated по обнаруженному объёму GS RAM.
- Убрано рисование FT812 из SD read loops, чтобы не чередовать FT812 и SD на общей SPI-шине.

### Исправления для реального железа

- Исправлен конфликт WIN explosion с ROM font 26 FT812: WINEXP handle теперь `9`, не `26`.
- WIN explosion atlas возвращён внутрь 1 МБ FT812 RAM_G и заливается поверх региона BALLS только на входе в WIN.
- WIN-взрывы рисуются до HUD/cursor overlays.
- При входе в меню чистится boot RAM_G tail перед загрузкой ассетов меню.

### Gameplay / очки

- Исправлен gap bonus gauge compare после того, как `GetCurrentTargetScore` затирал `HL`.
- Проверены match/cascade/Shot2 регрессии.
- Для Space текущая таблица даёт fallback target score `1000` на difficulty slots с `#FF`; setting `75` используется только на 4-й сложности.

### Вложения

Во вложениях только SPG и PAK-файлы. Исходники GitHub формирует автоматически из тега.
