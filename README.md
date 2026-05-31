# SexC

S-expression frontend for C with a Lisp-style macro system.
Compiler written in OCaml.

[English](#english) · [Русский](#russian)

---

> ## ⚠️ Heavy WIP — do not use in production
>
> This is a personal research project. The language surface,
> intrinsics, metadata schema, stdlib layout and CLI flags
> change without notice. There are no stability guarantees,
> no semantic versioning, no migration tools. Codegen has
> known rough edges, error reporting is incomplete, and the
> macro evaluator can leak state between files in non-obvious
> ways. Use it to read, experiment, and learn — not to ship.
>
> ## ⚠️ Глубокий WIP — не для продакшна
>
> Это персональный исследовательский проект. Синтаксис языка,
> intrinsic'и, схема метадаты, раскладка stdlib и CLI-флаги
> меняются без предупреждения. Никаких гарантий стабильности,
> semantic versioning или миграционных утилит нет. У codegen
> есть известные шероховатости, сообщения об ошибках неполные,
> macro-evaluator может незаметно переносить state между файлами.
> Использовать для чтения, экспериментов, учёбы — не для работы.

---

<a id="english"></a>

## Overview (EN)

SexC reads `(defn ...)`-style S-expressions and emits C. The
target is plain C — no runtime, no GC, no hidden allocations.
The macro system is Lisp-shaped: `%defmacro` with
`quasiquote`/`gensym`, a separate compile-time evaluator
(`$defun`) that runs during expansion, and a symbol-keyed
metadata table that macros can read and write.

Most of what looks like syntax is actually a macro defined in
`std/` rather than wired into the OCaml compiler. The OCaml
core is intentionally small: reader, macro engine, frontend,
codegen.

## Features

- **Macros**: `%defmacro` with `gensym`, quasiquote / unquote /
  unquote-splicing, recursive expansion. Macros run during a
  dedicated pass; their output is re-read as raw forms.
- **Compile-time evaluator (`$defun`)**: a small Lisp inside
  the macro pass. Used to write compile-time helpers — list
  manipulation, symbol generation, structural substitution —
  without touching OCaml. Most of `std/meta.sexc` is `$defun`.
- **Compile-time reflection (`$m-put` / `$m-get` / `%m-dump`)**:
  a per-symbol metadata table that macros can write to and
  read from. `struct` records `:fields`, `:methods`; `%define`
  records `:value`; `%decl-fn` records signatures. Other
  macros consume that metadata to generate code. `(%m-dump)`
  emits the whole table as a C comment.
- **Modules**: `(%module name)` namespaces every top-level
  symbol to `name/...`. `(%import "./file")` pulls another
  file's symbols in; cycles are detected and reported.
- **Documentation**: `%doc` attaches a docstring + signature
  + example to a symbol. `sexc show-doc <name>` prints it;
  `sexc dump-stdlib-docs <dir>` writes markdown for everything.
- **C interop**: `include`, `define`, `%ifdef`, `%decl-fn`
  for C prototypes, direct embedding of C identifiers.
- **Small OCaml core**: pipeline is reader → macro expander →
  frontend → C codegen, ~few thousand lines. Control flow,
  threading, struct sugar, dotimes, when, cond — all stdlib.

## Reflection and code generation

The metadata table is the part of SexC that does the most
work. Every declarative form populates it, and other macros
read it back during expansion. There is no separate "schema"
or "trait" mechanism — there is just `($m-put sym key val)`
and `($m-get sym key)`.

`struct` is itself a macro; when you write
```sexc
(struct Buffer
  :fields
  ((%ptr float) data)
  (int          cap)
  (int          head)
  (int          count))
```
it expands to a `typedef struct {...}` **and** calls
`($m-put 'Buffer :kind 'struct :fields '((...) (...) ...))`.

A different macro can now generate code from those fields.
`examples/audio-viz/auto-derive.sexc` defines `auto-print`,
which emits a debug printer for any struct:

```sexc
(%defmacro auto-print (type-name)
  ($let ((fields  ($m-get type-name :fields))
         (fn-name ($symcat type-name "/print"))
         (ptr-ty  ($list '%ptr type-name)))
    ($if ($null? fields)
      ($error "auto-print: no :fields metadata for this type")
      `(%def-fn void ,fn-name
                ((,ptr-ty x))
                (%block
                  (printf ,($str type-name " {\n"))
                  ,@($map
                       ($let ((ty   ($car it))
                              (name ($car ($cdr it))))
                         ($list 'printf
                                ($str "  " name " = " ($fmt-for-type ty) "\n")
                                ($cast-for-type ty ($list '%arrow 'x name))))
                       fields)
                  (printf "}\n"))))))
```

`$fmt-for-type` and `$cast-for-type` are also `$defun`s in the
same file: they map field types to printf format specifiers
(`int → %d`, `float → %f`, anything else → `%p` with a cast to
`void*`). All of that runs at compile time; the output is
straight C.

Usage:
```sexc
(struct Buffer :fields (int x) (int y))
(auto-print Buffer)
```
expands to:
```c
void Buffer_SLASH_print(Buffer *x) {
  printf("Buffer {\n");
  printf("  x = %d\n", x->x);
  printf("  y = %d\n", x->y);
  printf("}\n");
}
```

Add a field to `Buffer` and the printer picks it up
automatically — no manual stub per field, no external
codegen step.

Other macros that consume metadata the same way:
- `%decl-fn` records `:return-type` / `:params`; the eldoc
  integration reads it back to show signatures in Emacs.
- `%import` walks the metadata of the imported file to expose
  qualified symbols.
- `(%m-dump)` placed at the end of a file emits a sorted dump
  of the whole table as a C comment, useful for debugging
  macro output.

To inspect what compilation actually stored, run
```bash
sexc m-dump [--json] file.sexc
```

## Quick example

```sexc
(include <stdio.h>)

(struct Vec2
  :fields
  (float x)
  (float y)
  :methods
  (defn Vec2 add ((Vec2 a) (Vec2 b))
    (return (Vec2# (x (+ (. a x) (. b x)))
                   (y (+ (. a y) (. b y)))))))

(defn int main ()
  (decl (Vec2 a) (Vec2# (x 1.0) (y 2.0))
        (Vec2 b) (Vec2# (x 3.0) (y 4.0))
        (Vec2 c) (Vec2/add a b))
  (printf "(%f, %f)\n" (. c x) (. c y))
  (return 0))
```
```bash
./sexc examples/hello.sexc -C gcc % -o hello && ./hello
```
`-C` is a compile command where `%` is the generated `.c`.

## Build and install

```bash
make build      # builds ./sexc
make test       # parallel regression suite (bash-driven)
make install    # installs to /usr/local (override with PREFIX=)
```

`make install` places:
- `$(PREFIX)/bin/sexc`
- `$(PREFIX)/include/sexc/std/` — prelude
  (`core.sexc`, `c-interop.sexc`, `meta.sexc`, `ocaml-api.sexc`)
- `$(PREFIX)/share/sexc/docs/` — markdown for every symbol

Stdlib path is overridable via `SEXC_STDLIB_DIR`.

The compiler logs stage timings (parse, macro expand, codegen,
gcc, total) to stderr. Silence with `--quiet` / `-q` or
`SEXC_QUIET=1` (editor integrations want this).

## Compiler pipeline

1. **Reader** (`src/reader.ml`) — text → `Raw.t`
   (`Atom | Str | List`). Parses S-expressions and reader
   sugar (`'x` → `(quote x)`, quasi/unquote).
2. **Macro phase** (`src/macro.ml`) — expands `%defmacro`,
   runs `%eval`/`%evals`, runs the `$...` compile-time
   evaluator, mutates the metadata table. Output is `Raw.t`
   without macros.
3. **Frontend** (`src/frontend.ml`) — `Raw.t` → typed AST
   (top-level / stmt / expr / decl / type).
4. **Codegen** (`src/codegen_c.ml`) — AST → C strings, with
   mangling for identifiers C can't accept.

Orchestrated by `src/compiler.ml`: prelude loading, `%import`
graph, `%top-level-splice` handling.

Side artifacts:
- `src/cache/` — passive on-disk symbol index for
  `show-doc` / `complete` / `xref`.
- `src/docs.ml` — `%doc` metadata, markdown generation.

## Extending the language

| Want to add                                              | Where                                                                 |
|----------------------------------------------------------|-----------------------------------------------------------------------|
| Surface macro (`when`, `dotimes`, a DSL)                 | `std/c-interop.sexc` or `std/meta.sexc`                               |
| Compile-time function (list/tree work)                   | `$defun` in `std/meta.sexc`                                           |
| `$`-primitive needing OCaml state or exceptions          | `src/macro.ml`, case in `eval_expr`                                   |
| `%`-intrinsic (expr/stmt)                                | `src/frontend.ml` (parse) + `src/codegen_c.ml` (emit)                 |
| New top-level form                                       | variant in `type top`, case in `parse_top`, case in `emit_top`        |
| Reader sugar                                             | `src/reader.ml`                                                       |
| New compiler stage                                       | `src/compiler.ml`, between macro / frontend / codegen                 |

Principle: keep the OCaml core small. If something is
expressible via primitives (`$car`/`$cdr`/`$cons`/`$if`/`$let`
plus arithmetic), write it as `$defun` in sexc. OCaml edits
are for side effects only: metadata mutation, exceptions,
IO, or new `%`-forms that need a frontend/codegen case.

Full conventions reference: `AGENTS.md`.

## Developer tools

```bash
sexc show-doc defn                # one symbol's doc
sexc dump-stdlib-docs ./docs      # markdown for all stdlib
sexc complete --json (set) file   # completion with imports/std/module
sexc xref --json Vec2 file        # find defs of a symbol
sexc m-dump file.sexc             # dump the metadata table
```

`sexc.el` is an Emacs major-mode: font-lock, indent rules,
eldoc backed by `show-doc`, completion-at-point.

## Tests

Bash-driven regression suite — independent of the compiler's
host language.

```bash
make test                        # whole suite, parallel (JOBS=nproc)
JOBS=8 make test                 # cap concurrency
FILTER=struct make test          # subset by substring
make test-update                 # regenerate expected blocks (review diff!)
```

- `tests/cases/*.sexc-test` — golden-snapshot tests. Each
  file has source and expected output separated by
  `;==EXPECTED==` — reviewable in one place.
- `tests/examples/standalone.list` — examples that build
  end-to-end via gcc.

Details in `AGENTS.md` → *Регрессионные тесты*.

## Further reading

- `examples/` — runnable code, including the audio-viz mini
  project (`auto-print` lives there).
- `AGENTS.md` — internals: pipeline, intrinsics, evaluator,
  metadata schema.
- `std/c-interop.sexc`, `std/meta.sexc` — the surface DSL is
  almost entirely defined in these two files.
- `std/ocaml-api.sexc` — reference for OCaml-only symbols
  (`%...`, `$...`, `$defun`s).

---

<a id="russian"></a>

## Обзор (RU)

SexC читает S-выражения вида `(defn ...)` и эмитит C. Таргет —
обычный C: никакого runtime, никакого GC, никаких скрытых
аллокаций. Макросистема Lisp-образная: `%defmacro` с
`quasiquote` / `gensym`, отдельный compile-time evaluator
(`$defun`), работающий во время раскрытия, и таблица
метадаты по символам, в которую макросы пишут и из которой
читают.

Большая часть того, что выглядит как синтаксис — на деле
макрос в `std/`, а не зашит в OCaml-компилятор. OCaml-ядро
намеренно маленькое: reader, macro-движок, frontend, codegen.

## Фичи

- **Макросы**: `%defmacro` с `gensym`, quasiquote / unquote /
  unquote-splicing, рекурсивное раскрытие. Макросы работают
  в отдельной фазе; их выход перечитывается как raw-формы.
- **Compile-time evaluator (`$defun`)**: маленький Lisp
  внутри macro-фазы. Через него пишутся compile-time helper'ы
  — работа со списками, генерация символов, структурная
  подстановка — без правки OCaml. Почти весь `std/meta.sexc`
  — это `$defun`'ы.
- **Compile-time рефлексия (`$m-put` / `$m-get` / `%m-dump`)**:
  таблица метадаты на каждый символ, в которую макросы пишут
  и из которой читают. `struct` сохраняет `:fields`,
  `:methods`; `%define` — `:value`; `%decl-fn` — сигнатуру.
  Другие макросы потребляют эти данные для кодогенерации.
  `(%m-dump)` дампит таблицу в виде C-комментария.
- **Модули**: `(%module name)` неймспейсит все top-level
  символы файла в `name/...`. `(%import "./file")` подтягивает
  символы другого файла; циклы детектятся и репортятся.
- **Документация**: `%doc` цепляет к символу docstring +
  signature + example. `sexc show-doc <name>` печатает;
  `sexc dump-stdlib-docs <dir>` пишет markdown по всему.
- **C interop**: `include`, `define`, `%ifdef`, `%decl-fn`
  для прототипов C-функций, прямое использование C-имён.
- **Маленькое OCaml-ядро**: пайплайн reader → macro expander
  → frontend → C codegen, пара тысяч строк. Control flow,
  threading, struct-сахар, dotimes, when, cond — всё stdlib.

## Рефлексия и кодогенерация

Таблица метадаты — самая нагруженная часть SexC. Каждая
декларативная форма её заполняет, а другие макросы читают
оттуда во время раскрытия. Никакого отдельного механизма
«схем» или «trait»'ов нет — есть только `($m-put sym key val)`
и `($m-get sym key)`.

`struct` сам по себе макрос; когда вы пишете
```sexc
(struct Buffer
  :fields
  ((%ptr float) data)
  (int          cap)
  (int          head)
  (int          count))
```
он раскрывается в `typedef struct {...}` **и** вызывает
`($m-put 'Buffer :kind 'struct :fields '((...) (...) ...))`.

Любой другой макрос теперь может генерить код по этим полям.
`examples/audio-viz/auto-derive.sexc` определяет `auto-print`,
который эмитит debug-принтер для любой структуры:

```sexc
(%defmacro auto-print (type-name)
  ($let ((fields  ($m-get type-name :fields))
         (fn-name ($symcat type-name "/print"))
         (ptr-ty  ($list '%ptr type-name)))
    ($if ($null? fields)
      ($error "auto-print: no :fields metadata for this type")
      `(%def-fn void ,fn-name
                ((,ptr-ty x))
                (%block
                  (printf ,($str type-name " {\n"))
                  ,@($map
                       ($let ((ty   ($car it))
                              (name ($car ($cdr it))))
                         ($list 'printf
                                ($str "  " name " = " ($fmt-for-type ty) "\n")
                                ($cast-for-type ty ($list '%arrow 'x name))))
                       fields)
                  (printf "}\n"))))))
```

`$fmt-for-type` и `$cast-for-type` — тоже `$defun`'ы в том же
файле: они мапят тип поля в printf-спецификатор (`int → %d`,
`float → %f`, всё остальное → `%p` с кастом в `void*`).
Всё это выполняется в compile-time; на выходе — обычный C.

Использование:
```sexc
(struct Buffer :fields (int x) (int y))
(auto-print Buffer)
```
раскрывается в:
```c
void Buffer_SLASH_print(Buffer *x) {
  printf("Buffer {\n");
  printf("  x = %d\n", x->x);
  printf("  y = %d\n", x->y);
  printf("}\n");
}
```

Добавил поле в `Buffer` — `auto-print` подхватит автоматически.
Никаких рукописных stub'ов на каждое поле, никакого внешнего
кодогенератора.

Другие макросы, которые потребляют метадату так же:
- `%decl-fn` сохраняет `:return-type` / `:params`; интеграция
  с eldoc в Emacs читает их обратно для показа сигнатур.
- `%import` ходит по метадате импортируемого файла, чтобы
  выставить qualified-имена.
- `(%m-dump)` в конце файла эмитит отсортированный дамп всей
  таблицы как C-комментарий — удобно дебажить macro-выход.

Чтобы посмотреть, что компиляция реально сохранила:
```bash
sexc m-dump [--json] file.sexc
```

## Быстрый пример

```sexc
(include <stdio.h>)

(struct Vec2
  :fields
  (float x)
  (float y)
  :methods
  (defn Vec2 add ((Vec2 a) (Vec2 b))
    (return (Vec2# (x (+ (. a x) (. b x)))
                   (y (+ (. a y) (. b y)))))))

(defn int main ()
  (decl (Vec2 a) (Vec2# (x 1.0) (y 2.0))
        (Vec2 b) (Vec2# (x 3.0) (y 4.0))
        (Vec2 c) (Vec2/add a b))
  (printf "(%f, %f)\n" (. c x) (. c y))
  (return 0))
```
```bash
./sexc examples/hello.sexc -C gcc % -o hello && ./hello
```
`-C` — команда компиляции, где `%` — placeholder для
сгенерированного `.c`.

## Сборка и установка

```bash
make build      # собрать ./sexc
make test       # параллельная регрессионная сюита (bash)
make install    # установить в /usr/local (PREFIX переопределяемый)
```

`make install` ставит:
- `$(PREFIX)/bin/sexc`
- `$(PREFIX)/include/sexc/std/` — prelude
  (`core.sexc`, `c-interop.sexc`, `meta.sexc`, `ocaml-api.sexc`)
- `$(PREFIX)/share/sexc/docs/` — markdown по всем символам

Путь к stdlib переопределяется через `SEXC_STDLIB_DIR`.

Компилятор логирует тайминги стадий (parse, macro expand,
codegen, gcc, total) на stderr. Заглушить — `--quiet` / `-q`
или `SEXC_QUIET=1` (для редакторских интеграций).

## Пайплайн компилятора

1. **Reader** (`src/reader.ml`) — текст → `Raw.t`
   (`Atom | Str | List`). Парсит S-выражения и reader-sugar
   (`'x` → `(quote x)`, quasi/unquote).
2. **Macro phase** (`src/macro.ml`) — раскрывает `%defmacro`,
   обрабатывает `%eval`/`%evals`, гоняет `$...` compile-time
   evaluator, мутирует таблицу метадаты. Выход — `Raw.t` без
   макросов.
3. **Frontend** (`src/frontend.ml`) — `Raw.t` → типизированный
   AST (top-level / stmt / expr / decl / type).
4. **Codegen** (`src/codegen_c.ml`) — AST → C-строки, с
   mangling недопустимых для C идентификаторов.

Оркестрация — `src/compiler.ml`: загрузка prelude, граф
`%import`'ов, обработка `%top-level-splice`.

Сопутствующее:
- `src/cache/` — пассивный disk-cache символьного индекса для
  `show-doc` / `complete` / `xref`.
- `src/docs.ml` — `%doc` metadata, генерация markdown.

## Как расширять язык

| Хочется добавить                                       | Куда                                                                  |
|--------------------------------------------------------|-----------------------------------------------------------------------|
| Surface-макрос (`when`, `dotimes`, ваш DSL)            | `std/c-interop.sexc` или `std/meta.sexc`                              |
| Compile-time функция (работа со списками/деревьями)    | `$defun` в `std/meta.sexc`                                            |
| `$`-примитив, требующий OCaml-стейта/исключений        | `src/macro.ml`, кейс в `eval_expr`                                    |
| `%`-intrinsic (expr/stmt)                              | `src/frontend.ml` (parse) + `src/codegen_c.ml` (emit)                 |
| Новая top-level форма                                  | вариант в `type top`, кейс в `parse_top`, кейс в `emit_top`           |
| Reader-sugar                                           | `src/reader.ml`                                                       |
| Новая фаза компилятора                                 | `src/compiler.ml`, между macro / frontend / codegen                   |

Принцип: держим OCaml-ядро маленьким. Если что-то выражается
через примитивы (`$car`/`$cdr`/`$cons`/`$if`/`$let` плюс
арифметика) — пишется как `$defun` в sexc. OCaml-правка нужна
только под сайд-эффекты: мутация метадаты, исключения, IO или
новые `%`-формы, требующие frontend/codegen-кейса.

Полный референс соглашений — `AGENTS.md`.

## Инструменты разработчика

```bash
sexc show-doc defn                # документация одного символа
sexc dump-stdlib-docs ./docs      # markdown по всем символам stdlib
sexc complete --json (set) file   # автокомплит с учётом imports/std/module
sexc xref --json Vec2 file        # найти определения символа
sexc m-dump file.sexc             # дамп таблицы метадаты
```

`sexc.el` — Emacs major-mode: font-lock, indent rules, eldoc
через `show-doc`, completion-at-point.

## Тесты

Регрессионная сюита на bash — не зависит от языка реализации
компилятора.

```bash
make test                        # вся сюита, параллельно (JOBS=nproc)
JOBS=8 make test                 # ограничить параллелизм
FILTER=struct make test          # подмножество по подстроке
make test-update                 # перегенерировать expected (ревью diff!)
```

- `tests/cases/*.sexc-test` — golden snapshot. В одном файле
  source и expected, разделённые `;==EXPECTED==` — ревью в
  одном месте.
- `tests/examples/standalone.list` — examples, которые
  компилируются end-to-end через gcc.

Подробнее — `AGENTS.md`, раздел *Регрессионные тесты*.

## Куда смотреть дальше

- `examples/` — рабочий код, в том числе мини-проект
  audio-viz (там живёт `auto-print`).
- `AGENTS.md` — внутренности: пайплайн, intrinsic'и,
  evaluator, схема метадаты.
- `std/c-interop.sexc`, `std/meta.sexc` — surface DSL почти
  целиком описан здесь.
- `std/ocaml-api.sexc` — справочник по OCaml-only символам
  (`%...`, `$...`, `$defun`-ы).
