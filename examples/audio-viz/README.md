# audio-viz

Микрофонный визуализатор уровня звука: скользящий 30-секундный график.
miniaudio захватывает аудио, raylib рисует.

Демо-проект на SexC — показывает большинство возможностей языка:

| Что демонстрируется | Где |
|---|---|
| Многофайловый проект через `%import` | `main.sexc` собирает остальное |
| File-level namespace через `%module` | `ring-buffer.sexc` (`%module ring`), `graph.sexc` (`%module graph`) |
| `struct` с типизированными полями и автоматической метадатой | `ring-buffer.sexc` |
| Threading-макросы (`||>`) | `main.sexc` — push в буфер |
| C-mirror sugar (`when`, `dotimes`, `for-range`, `incf`, `cast`) | по всем файлам |
| Биндинги к настоящей C-библиотеке (`%decl-fn`) | `audio.sexc` |
| **Compile-time metadata + code generation** | `auto-derive.sexc` + `main.sexc` |
| `%m-dump` для дампа compile-time состояния | конец `main.sexc` |

## Изюминка: auto-print через метадату

В `auto-derive.sexc` определён макрос `auto-print`. Когда писать
```sexc
(struct Buffer :fields (int x) (int y))
(auto-print Buffer)
```

SexC читает `($m-get 'Buffer :fields)` (метадата автоматически проставляется
макросом `struct`) и **генерирует** функцию:

```c
void Buffer/print(Buffer *x) {
  printf("Buffer {\n");
  printf("  x = %d\n", x->x);
  printf("  y = %d\n", x->y);
  printf("}\n");
}
```

Формат-спецификатор (`%d`, `%f`, `%p`, ...) подбирается из типа поля.
Указатели кастятся в `(void*)` под `%p`. Никаких рукописных stub-ов
на каждое поле — добавишь поле в struct, `auto-print` подхватит автоматически.

## Файлы

| Файл | Что внутри |
|---|---|
| `audio_impl.c` | miniaudio impl + три C-обёртки (audio_start/get_level/stop). Spawn'ит capture-thread, считает RMS уровень. |
| `audio.sexc` | `%decl-fn` для трёх C-функций. Без `%module` — иначе `%decl-fn` тоже переименовался бы. |
| `ring-buffer.sexc` | `(%module ring)` + struct `Buffer` + операции `init`/`push`/`get`/`size`/`cap`/`release`. |
| `graph.sexc` | `(%module graph)` + `draw` — рисует ring как полилинию, цвет HSV по уровню (зелёный → жёлтый → красный). |
| `auto-derive.sexc` | Макрос `auto-print` с двумя `$defun` helper'ами для подбора format-спецификатора по типу. |
| `main.sexc` | Точка входа: window init → loop → push level → draw graph. В конце — `(%m-dump)` для дампа всей метадаты в виде C-комментария. |

## Сборка

```bash
git submodule update --init --recursive   # один раз — подтянуть miniaudio
./build.sh                                # SexC → C → gcc + miniaudio + raylib
./audio-viz                               # запуск
```

Зависимости системы: `raylib` (через pkg-config или `-lraylib`), `gcc`,
заголовки PortAudio/ALSA/PulseAudio/etc. (нужны miniaudio для capture).
Linux: обычно достаточно `apt install libasound2-dev`.

## Что увидеть в выходном C

После `./build.sh` без линка можно посмотреть промежуточный C:

```bash
../../sexc main.sexc > out.c
```

В конце `out.c` будет большой C-комментарий с дампом всех символов,
их типов, видов (`fn`/`var`/`struct`/`union`/`define`) и метадаты —
снимок compile-time состояния.

