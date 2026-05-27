# AGENTS Notes (SexC)

Короткая сводка текущих договоренностей по проекту, чтобы быстро продолжать в новой сессии.

## Структура проекта

- OCaml исходники лежат в `src/`.
- Основной CLI: `src/sexc.ml`.
- Макросная stdlib: `std/core.sexc`.
- Примеры: `examples/`.

## Сборка и запуск

- `make` == `make build`.
- `make build` собирает `./src/sexc.exe` и копирует бинарник в корень как `./sexc`.
- `make run FILE=...` использует `./sexc`.
- В `Makefile` есть авто-очистка битого/stale `_build/.lock`.

## CLI фича `-C`

- Формат: `./sexc path/to/file.sexc -C <command...>`.
- В команде обязателен `%` — он заменяется на временный `.c` файл.
- Пример: `./sexc examples/raylib_std.sexc -C gcc % -lraylib -o raylib-example`.

## Диагностика ошибок (этап 1)

- Reader ошибки показываются как `file:line:col` + строка + caret `^`.
- Фаза в сообщении: `error[reader]`.
- Реализация в `src/common.ml`, `src/reader.ml`, `src/sexc.ml`.

## Макросы std/core.sexc (актуальные правила)

- `if` строго только 2 или 3 аргумента.
- Для сложных ветвлений использовать `cond`.
- `decl` теперь в стиле `let*` и с **обязательной инициализацией**:
  - Формат: `(decl (type name) init (type2 name2) init2 ...)`.
  - Примеры:
    - `(decl (int x) 5)`
    - `(decl (int x) 5 (int y) (+ x 9))`.
  - Старый формат `(decl name type ...)` — **удален** (breaking change).
- `set` порядок аргументов: **lhs, value**.
  - Поддерживает пачку пар: `(set x v y v2 ...)`.
- `include` принимает один или несколько заголовков.
- Математические и логические макросы n-арные:
  - `+ - * / %`
  - `&& || and or`
- `-` поддерживает унарную форму: `(- x)` -> `0 - x`.
- Доступ к полям:
  - `dot` и `arrow` поддерживают цепочки полей: `(dot obj a b c)`, `(arrow ptr a b c)`.
  - Есть алиасы: `.` и `->`.
  - `->` всегда разворачивается в цепочку `%arrow` (без автоподмены на `dot`).

## Top-level splicing

- Поддержан `%top-level-splice` на уровне программы.
- Используется для макросов, которые должны эмитить несколько top-level форм.
- Внутри выражений/stmt `%top-level-splice` не допускается.

## Raw escape hatch

- Добавлен `%raw` как expression intrinsic для прямой вставки C-фрагмента.
- Формат: `(%raw part1 part2 ...)`, где строковые части вставляются как есть, а не-строковые части рендерятся как обычные выражения.
- Типичный кейс: инициализатор вида `{0}` через макрос `zero-init`.

## Compile-time eval

- Добавлены `%eval` и `%evals` на стадии макро-экспансии:
  - `%eval` ожидает одно выражение и возвращает одну форму.
  - `%evals` ожидает одно выражение, результат должен быть списком; элементы сплайсятся в текущий list-контекст.
- Это позволяет генерировать код в top-level, stmt и даже expr-контексте (например `(+ (%evals ...))`).
- Для `%eval` доступны meta-операторы в macro-eval:
  - `$--map`, `$--filter`, `$--reduce`, `$dolist`.
- Reader поддерживает quote-сахар: `'x` -> `(quote x)`.

## Полезные sugar-макросы

- В `std/core.sexc` добавлен `(zero-init)` -> `(%raw "{0}")`.
- Часть простых оберток выражается через `%raw` (например `not`, `aref`, `post-inc`, `sizeof-expr`).

## Struct и инициализация

- В std есть макросы:
  - `(struct Name (type field) ...)` -> `typedef struct ... Name;`
  - `(union Name (type field) ...)` -> `typedef union ... Name;`
- Инициализация структур через sugar `Type#`:
  - `(Roots# (x1 5) (x2 7))` -> `(Roots){ .x1 = 5, .x2 = 7 }`
  - `(Roots# 0)` -> zero-init `(Roots){ 0 }`
  - `(Roots# X)` при `X != 0` запрещено.

## Функции

- Используется `defn`:
  - `(defn int main () ...)`
  - Параметры в форматах:
    - классический: `((float a) (float b))`
    - групповой: `((float a b c))`.
- `defun` специально **не используется**.

## Генерация C идентификаторов

- В codegen включен mangling идентификаторов для невалидных C-символов:
  - недопустимые символы кодируются как `_uXXXX_` (или `_UXXXXXXXX_` при необходимости),
  - пример: `Roots/disc` -> `Roots_u002F_disc`.
- Это позволяет использовать DSL-имена с `/` и другими символами.

## Пример raylib

- Основной актуальный пример: `examples/raylib_std.sexc`.
- Пример больше не импортирует `std/raylib.sexc`; вызовы raylib (`BeginDrawing`, `EndDrawing`, `DrawCircleV`, ...) используются напрямую.
- Из-за обязательного init в `decl`, неинициализированные массивы в raylib-примере объявляются через `%decl`.

## Примеры

- `examples/hello.sexc` — актуальный demo с `struct`, grouped params, `Type#`, и именами вида `Type/method`.
- `examples/dot_arrow_alias.sexc` — demo для `.` / `->` и цепочек полей.
