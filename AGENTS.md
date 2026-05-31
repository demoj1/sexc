# AGENTS Notes (SexC)

Короткая сводка текущих договоренностей по проекту, чтобы быстро продолжать в новой сессии.

## Структура проекта

- OCaml исходники лежат в `src/`.
- Основной CLI: `src/sexc.ml`.
- Макросная stdlib: `std/core.sexc`, `std/c-interop.sexc`, `std/meta.sexc`, `std/ocaml-api.sexc`.
- Примеры: `examples/`.
- Emacs mode plugin: `sexc.el` (major mode, font-lock, indent rules, compile command, eldoc через `show-doc`).
  - completion-at-point через `sexc complete` (учитывает imports + std + `%module`).

## Карта модулей (OCaml)

- `src/sexc.ml` — CLI и флаги (`--no-prelude`, `-C`).
- `src/compiler.ml` — orchestration пайплайна: import/prelude -> macro -> frontend -> codegen.
- `src/reader.ml` — reader/парсер Raw-форм + quote/quasiquote sugars.
- `src/macro.ml` — `%defmacro`, `%eval/%evals`, compile-time `$...` builtins.
- `src/frontend.ml` — парсинг expanded Raw в AST (типы/stmt/expr/top-level).
- `src/codegen_c.ml` — генерация C из AST + mangling идентификаторов.
- `src/cache/cache.ml` — пассивный disk-cache индекса символов (md5 по файлам + сериализация).
- `src/cache/index.ml` — индекс символов/документации/локаций из парсера (для `show-doc`, `complete`, `xref`).
- `src/docs.ml` — `%doc` metadata, `show-doc`, `dump-docs`, `dump-stdlib-docs`, markdown генерация.
- `src/common.ml` — ошибки/диагностика.
- `src/raw.ml` — минимальный тип Raw AST.

Куда добавлять новые вещи:
- новый CLI-флаг: `src/sexc.ml` (+ прокинуть в `src/compiler.ml` при необходимости).
- новый reader-sugar: `src/reader.ml`.
- новый compile-time meta builtin `$...`: предпочтительно через `$defun` в `std/meta.sexc`; правка `src/macro.ml` только если требуется OCaml-стейт/исключения/арифметика.
- новый `%...` intrinsic (expr/stmt/top): `src/frontend.ml` + `src/codegen_c.ml`.
- новый compiler pass: вставлять в `src/compiler.ml` между macro/frontend/codegen.

## Карта stdlib (SexC)

- `std/core.sexc` — агрегатор prelude (`%import` цепочки), сюда не добавлять большую логику.
- `std/c-interop.sexc` — **всё, что (в конечном счёте) разворачивается в `%`-IR**. От прямых C-mirror (`defn`/`decl`/`adecl`/`struct`/`union`/операторы) до высокоуровневого C-statement sugar (`when`/`unless`/`incf`/`decf`/`incf-by`/`decf-by`/`dotimes`/`for-range`/`repeat`). Декларативные макросы (`defn`, `decl`, `adecl`, `struct`, `union`, `define`) дополнительно населяют compile-time metadata через `$m-put`.
- `std/meta.sexc` — **то, что НЕ привязано к C**. Compile-time `$defun` библиотека (`$list`, `$append`, `$subst`, `$length`, `$reverse`, `$nth`, `$--reverse-aux`) и generic structural sugar (`|>`, `||>`, `|as>`).
- `std/ocaml-api.sexc` — docs-only `%doc` записи для OCaml-only символов (`%...`, `$...`) и для `$defun`-функций из meta.sexc.

Правило для размещения нового макроса: *развернётся ли это (в итоге) в `%`-IR форму?* Да → `c-interop.sexc`. Нет (compile-time / form manipulation) → `meta.sexc`.

Куда добавлять макросы:
- макрос напрямую про C/interop/низкоуровневый surface синтаксис -> `std/c-interop.sexc`.
- высокоуровневый sugar/утилиты общего назначения -> `std/meta.sexc`.

## Сборка и запуск

- `make` == `make build`.
- `make build` собирает `./src/sexc.exe` и копирует бинарник в корень как `./sexc`.
- `make run FILE=...` использует `./sexc`.
- `make install` ставит бинарник в `$(PREFIX)/bin/sexc` (по умолчанию `/usr/local/bin/sexc`), stdlib в `$(PREFIX)/include/sexc/std`, docs в `$(PREFIX)/share/sexc/docs`.
- В `Makefile` есть авто-очистка битого/stale `_build/.lock`.
- Prelude загружается с диска из stdlib-директории (по умолчанию `/usr/local/include/sexc/std`, можно переопределить через `SEXC_STDLIB_DIR`).
- Prelude подключается автоматически для каждого файла; флаг `--no-prelude` отключает автоподключение.
- Явный `%import "../std/core.sexc"` по-прежнему допустим, но уже не обязателен.
- Циклические `%import` запрещены (ошибка `Cyclic %import detected: ...`).

## CLI фича `-C`

- Формат: `./sexc path/to/file.sexc -C <command...>`.
- В команде обязателен `%` — он заменяется на временный `.c` файл.
- Пример: `./sexc examples/raylib_std.sexc -C gcc % -lraylib -o raylib-example`.

## CLI docs

- `./sexc show-doc <symbol>` — показать документацию символа.
- `./sexc dump-docs <input.sexc> <out-dir>` — сгенерировать docs по файлам (user graph + std, если prelude включен).
- `./sexc dump-stdlib-docs <out-dir>` — сгенерировать docs только для stdlib.
- `./sexc complete <prefix> [input.sexc|-]` — выдать completion-кандидаты (макросы + функции) с учетом imports/std и `%module`.
- `./sexc complete --json <prefix> [input.sexc|-]` — выдать completion в JSON (единый symbol-формат: `name`, `kind`, `file`, `line`, optional `module`/`signature`/`doc`/`example`/`type`, `internal`, `file_md5`).
- `./sexc xref --json <symbol> <input.sexc>` — выдать определения символа (локации + метаданные) из того же индекс-кэша.
- `./sexc print-cache-dump` — вывести весь disk-cache индекса символов в human-readable виде.

## `%doc` metadata

- `%doc` — top-level metadata форма, не влияет на C codegen.
- Формат: `(%doc name [:sig ...] :doc "..." [:example "..."] [:internal t] [:since "..."] [:deprecated "..."] [:see sym...])`.
- `:doc` обязателен; `:sig` опционален (для OCaml-only обычно указывается явно).
- `:example` можно повторять; выводится в `show-doc` и markdown docs.
- `:internal t` скрывает символ из `show-doc` и `dump-docs` (для helper-макросов).

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
- `adecl` в стиле `let*` для malloc-аллоцируемых указателей:
  - Формат: `(adecl (type name) size (type2 name2) size2 ...)`.
  - Пример: `(adecl (char name) 25 (int foo) 15)`.
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
  - Публичные sugar-алиасы: `$map`, `$filter`, `$reduce`.
  - `$for`, `$let`.
- Reader поддерживает quote-сахар: `'x` -> `(quote x)`.

### Compile-time функции (`$defun`)

- `($defun $name (params...) body...)` — определяет именованную compile-time функцию, доступную в `$`-контексте (внутри `%defmacro`, `%eval`, `%evals`).
- Семантика: **call-by-value** (аргументы вычисляются до вызова). Это отличие от `%defmacro`, который получает невычисленный синтаксис.
- Хранилище: `ctx.ct_fns : def String.Map.t`, наполняется `Macro.collect` на верхнем уровне.
- Несколько body-форм оборачиваются в `$do` автоматически.
- Поддерживает `&rest`.
- Используется для функций, которые можно выразить через примитивы `$car`/`$cdr`/`$cons`/`$if`/`$let`/арифметику. Не подходит для функций с неявными биндингами `it`/`acc` (`$map`, `$filter`, `$reduce`) — те остаются OCaml-only, так как требуют невычисленных аргументов-шаблонов.

### Compile-time арифметика

- `$+`, `$-`, `$*`, `$/` — целочисленные операции в `eval_expr`. Бинарные, операнды должны вычисляться в атом-число.

### Что мигрировано из OCaml в sexc

В `std/meta.sexc` как `$defun`: `$append` (binary), `$length`, `$reverse`, `$nth`, `$list` (variadic через `&rest`), `$subst` (рекурсивный обход дерева через `$atom?`/`$null?`).

В OCaml остаются (irreducible bootstrap): `$if`, `$let`, `$do`, `$quote`, `quasiquote`, `$car`, `$cdr`, `$cons`, `$null?`, `$atom?`, `$eq?`, `$symcat`, `$gensym`, `$error`, `$assert`, `$not`, арифметика, `$|>`/`$||>`/`$|as>`, `$for`/`$dolist`/`$map`/`$filter`/`$reduce`, `$defun`, `$m-put`/`$m-get`.

## Compile-time symbol metadata

- `($m-put sym key1 val1 key2 val2 ...)` — variadic, кладёт N пар key/value в глобальную мапу `ctx.sym_meta` под именем `sym`. Перезаписывает только указанные ключи, остальные сохраняет. Возвращает `nil`.
- `($m-get sym key)` — читает значение или `nil`, если символ/ключ отсутствуют.
- Подход — Common Lisp `symbol-plist`: глобально, мутабельно, привязано к **имени** символа (а не к форме).
- Stdlib-макросы автоматически населяют метадату:
  - `define name value` → `:kind 'define`, `:value`
  - `defn ret name params body` → `:kind 'fn`, `:return-type`, `:params`
  - `decl (ty name) init ...` → на каждое имя: `:kind 'var`, `:c-type`
  - `adecl (ty name) size ...` → `:kind 'var`, `:c-type (%ptr ty)`, `:allocated t`
  - `struct name :fields ... :methods ...` → `:kind 'struct`, `:fields`, `:methods`
  - `union name fields...` → `:kind 'union`, `:fields`
- `(%m-dump)` — top-level интринсик, разворачивается в `(%comment "...")` с отсортированным дампом всей метадаты на момент expand'а. Поставить в конце файла, чтобы увидеть финальное состояние.
- `(%comment "text")` — новая top-level форма, эмитит `/*text*/` (parse в `frontend.ml`, codegen в `codegen_c.ml`).

### Module-level metadata (auto-populated)

Декларативные макросы дополнительно регистрируют себя в **родительском namespace**'е через `$namespace-of` + `$m-append`. Тогда модуль или struct становятся контейнером своих членов:

- `defn name ...` → `($m-append (namespace-of name) :fns name)`
- `define name ...` → `:defines`
- `struct name ...` → `:types` родителя; **каждый метод** из `:methods` → `:fns` самой структуры (плюс собственная `$m-put` запись)
- `union name ...` → `:types`

Примеры:
```sexc
($m-get 'ring :types)         ; → ('ring/Buffer ...) — все struct/union модуля
($m-get 'ring/Buffer :fns)    ; → ('ring/Buffer/init 'ring/Buffer/push ...) — методы
($m-get 'mymod :fns)          ; → top-level defn'ы (не methods)
($m-get 'mymod :defines)      ; → константы define
```

Намespace разбивается по **последнему** `/` — каждое имя попадает в свой непосредственный родительский namespace.

### CLI: `sexc m-dump`

```
sexc [--no-prelude] m-dump [--json] <input.sexc>
```

Прогоняет macro expansion и дампит `ctx.sym_meta`. JSON-вариант — для tooling. Реализовано через `Compiler.metadata_of_file` (то же что `compile_forms`, но останавливается после expand и возвращает sym_meta). Форматтеры: `Macro.format_meta_text`, `Macro.format_meta_json`.

## File-level module namespace

- Поддержан `%module` на уровне файла: `(%module foo)`.
- `%module` применяет префикс `foo/` к именованным top-level сущностям файла (`defn`, `define`, `struct`, `union`, `%def-fn`, `%decl-fn`, `%define`, `%typedef`) и локальным ссылкам на них в этом же файле.
- Внутри файла можно использовать короткие имена без префикса; снаружи доступны имена с префиксом `foo/...`.
- `%module` удаляется на раннем compiler-pass и не попадает в frontend/codegen как runtime-форма.

## Именование уровней (строго)

- `%...` — системные/IR формы компилятора.
- `$...` — compile-time meta builtins (доступны в `%defmacro`, `%eval`, `%evals`).
- Имена без `%` и без `$` — только surface DSL (объявлены в prelude-файлах `std/c-interop.sexc` и `std/meta.sexc`).
- Legacy meta-имена без `$` (`car`, `cdr`, `null?`, `if`, ...) запрещены.

## Группы ключевых слов

- `IR/Intrinsic (%...)`:
  - Top-level/decl/fn: `%include`, `%define`, `%define-macro`, `%ifdef`, `%typedef`, `%decl-fn`, `%def-fn`, `%decl`, `%decl-many`, `%top-level-splice`, `%comment`
  - Stmt/control: `%block`, `%if`, `%while`, `%do-while`, `%for`, `%switch`, `%case`, `%default`, `%break`, `%continue`, `%return`, `%goto`, `%label`, `%nop`
  - Expr/operators: `%raw`, `%cast`, `%sizeof-type`, `%sizeof-expr`, `%ternary`, `%comma`, `%aref`, `%dot`, `%arrow`, `%call`, `%!`, `%~`, `%addr`, `%deref`, `%pre-inc`, `%pre-dec`, `%post-inc`, `%post-dec`, `%+`, `%-`, `%*`, `%/`, `%%`, `%==`, `%!=`, `%<`, `%<=`, `%>`, `%>=`, `%&&`, `%||`, `%set`, `%+=`, `%-=`, `%*=`, `%/=`, `%%=`
  - Compile-time control: `%defmacro`, `%eval`, `%evals`, `%module`, `%m-dump`
- `Meta builtins ($...)`:
  - В `src/macro.ml` (OCaml-primitives): `$quote`, `$if`, `$cond`, `$case`, `$cons`, `$car`, `$cdr`, `$null?`, `$atom?`, `$eq?`, `$let`, `$do`, `$not`, `$error`, `$assert`, `$gensym`, `$symcat`, `$str`, `$namespace-of`, `$+`, `$-`, `$*`, `$/`, `$defun`, `$|>`, `$||>`, `$|as>`, `$--map`, `$--filter`, `$--reduce`, `$dolist`, `$map`, `$filter`, `$reduce`, `$for`, `$m-put`, `$m-get`
  - В `std/meta.sexc` (sexc `$defun`): `$list`, `$append`, `$length`, `$reverse`, `$nth`, `$subst`
- `Surface std macros` (без префикса, в std/*.sexc):
  - `std/c-interop.sexc` (всё разворачивается в `%`-IR): `include`, `define`, `defn`, `decl`, `adecl`, `free*`, `block`, `if`, `cond`, `when`, `unless`, `while`, `for`, `dotimes`, `for-range`, `repeat`, `return`, `set`, `incf`, `decf`, `incf-by`, `decf-by`, `cast`, `struct`, `union`, `zero-init`, `sizeof-type`, `sizeof-expr`, `aref`, `dot`, `arrow`, `.`, `->`, `not`, `+`, `-`, `*`, `/`, `%`, `=`, `not=`, `<`, `<=`, `>`, `>=`, `&&`, `and`, `||`, `or`, `post-inc`, `nop`
  - `std/meta.sexc` (не привязано к C): `|>`, `||>`, `|as>` (threading)

## Полезные sugar-макросы

- В `std/core.sexc` добавлен `(zero-init)` -> `(%raw "{0}")`.
- Часть простых оберток выражается через `%raw` (например `not`, `aref`, `post-inc`, `sizeof-expr`).

## Struct и инициализация

- В std есть макросы:
  - `(struct Name :fields (type field) ... :methods (defn ...) ...)` -> `typedef struct ... Name;` + namespace-функции
  - Секции `:fields` обязательна, `:methods` опциональна; старый mixed-формат `struct` удален.
  - Внутри `struct` можно объявлять методы через `defn`; они автогенерируются как `Name/method`.
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
- Используется `defn` как единый синтаксис для объявления функций.

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
- `examples/struct_methods.sexc` — demo для `defn` внутри `struct` и namespace-функций.
- `examples/complex-project/` — мини-проект из 3 файлов (`main.sexc`, `lib.sexc`, `utils.sexc`) с `%import` между файлами.
