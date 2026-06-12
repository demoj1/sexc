# AGENTS Notes (SexC)

Короткая сводка текущих договоренностей по проекту, чтобы быстро продолжать в новой сессии.

## Структура проекта

- OCaml исходники лежат в `src/`.
- Основной CLI: `src/sexc.ml`.
- Макросная stdlib: `std/core.sexc`, `std/c-interop.sexc`, `std/meta.sexc`, `std/ocaml-api.sexc`.
- Примеры: `examples/`.
- Регрессионные тесты: `tests/` (bash + golden snapshots, см. ниже).
- Emacs mode plugin: `sexc.el` (major mode, font-lock, indent rules, compile command, eldoc через `show-doc`).
  - completion-at-point через `sexc complete` (учитывает imports + std + `%module`).
  - Flymake backend `sexc-flymake` (вкл. `sexc/enable-flymake`, default t): пайпит буфер через `sexc --quiet -`, парсит диагностики `file:line:col: error[phase]: msg`, кладёт регион через `flymake-diag-region`. Запускается из директории буфера (чтобы `%import` резолвились). Async через `make-process`.

## Карта модулей (OCaml)

- `src/sexc.ml` — CLI и флаги (`--no-prelude`, `--quiet`/`-q`, `-C`).
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
- `make build` собирает SexC и кладёт бинарник в корень как `./sexc` (dune-внутренний `.exe`-артефакт скрыт от вывода).
- `make run FILE=...` использует `./sexc`.
- `make install` ставит бинарник в `$(PREFIX)/bin/sexc` (по умолчанию `/usr/local/bin/sexc`), stdlib в `$(PREFIX)/include/sexc/std`, docs в `$(PREFIX)/share/sexc/docs`.
- В `Makefile` есть авто-очистка битого/stale `_build/.lock`.
- Prelude загружается с диска из stdlib-директории (по умолчанию `/usr/local/include/sexc/std`, можно переопределить через `SEXC_STDLIB_DIR`).
- Prelude подключается автоматически для каждого файла; флаг `--no-prelude` отключает автоподключение.
- Явный `%import "../std/core.sexc"` по-прежнему допустим, но уже не обязателен.
- Циклические `%import` запрещены (ошибка `Cyclic %import detected: ...`).

### Прогресс-логи стадий

- Компилятор пишет на stderr тэгированный лог стадий пайплайна с таймингами в human-readable формате (`850µs`/`12.4ms`/`1.23s`/`1m 32s`). Видны: `load <file> (N forms) — Xµs`, `prelude — Xms`, `macro collect/expand`, `frontend parse`, `codegen C`, `running: <gcc cmd>`, `<bin> exit N — Xs`, `total — Xs`.
- Зачем по умолчанию: длинные сборки (большие `%import`-графы или тяжёлый `gcc -O2`) иначе выглядят зависшими.
- Отключение — `--quiet`/`-q` или `SEXC_QUIET=1` (например для редакторских интеграций, которые не хотят шум в stderr).
- Реализация: `Common.quiet` ref / `Common.logf` / `Common.with_stage` / `Common.format_span`. Тайминги стадий — в `compile_forms` и `load_forms_from_file` (`src/compiler.ml`), время gcc — в `run_with_temp_c` (`src/sexc.ml`).

## Регрессионные тесты (`tests/`)

- Тесты написаны на **bash** намеренно — чтобы не зависеть от языка реализации компилятора. При смене языка (OCaml → что угодно) тесты продолжат работать как есть.
- Запуск: `make test` (или напрямую `./tests/run.sh`). Параллелизм по умолчанию = `nproc`, переопределяется через `JOBS=N`. Фильтр по подстроке пути — `FILTER=substr`.
- Перегенерация expected: `make test-update` (= `UPDATE=1 ./tests/run.sh`). Diff после регена надо ревьюить.

Состав:

- `tests/cases/*.sexc-test` — golden snapshot тесты. **Одиночный файл** содержит и source, и expected, разделённые маркером `;==EXPECTED==`:
  ```
  ;; sexc-flags: --no-prelude    ; опциональная первая строка
  ... SexC исходник ...
  ;==EXPECTED==
  ... ожидаемый C-выход ...
  ```
  Runner пайпит часть до маркера через `sexc - --quiet` (с прелюдией по умолчанию), сравнивает с частью после маркера.
- `tests/examples/standalone.list` — список путей к example'ам, которые компилируются через `gcc -O0 -w -lm`. Examples с raylib/miniaudio-зависимостями (`raylib*.sexc`, `audio-viz/`) сюда не включены.
- `tests/run.sh` — диспетчер: находит cases + lists, запускает воркеров через `xargs -P`, агрегирует pass/fail через файлы-маркеры в tmpdir, выводит summary с общим временем.
- `tests/run_one.sh` — один snapshot: парсит формат, проверяет/обновляет.
- `tests/run_example.sh` — один example-compile: выполняет `sexc <src> -C gcc % ...`, проверяет exit 0.

Куда добавлять:
- Новый surface/raw-кейс — `tests/cases/<topic>-<name>.sexc-test`, source + `;==EXPECTED==` + (либо руками пишешь expected, либо запускаешь `UPDATE=1 ./tests/run.sh FILTER=<name>` и ревьюишь сгенерированное).
- Новый **error-кейс** — source + `;==EXPECTED-ERROR==` + ожидаемый stderr (file:line:col + caret + опц. hint-блок с docs). Sexc должен exit'нуть non-zero; stdout игнорируется. Абсолютные пути внутри ROOT нормализуются в `<root>` (через `pwd -P`-нормализацию плюс `sed` в `run_one.sh`), чтобы snapshot был портативным. Multi-error кейс просто кладёт несколько ошибочных top-форм.
- Новый **#line-кейс** — заголовок `;; sexc-keep-line` (отменяет дефолтный `--no-line` раннера), source + `;==EXPECTED==` + C-вывод **с** `#line`-директивами. Так тестируется сам source-mapping (см. `line-struct-fields`, `line-after-macro-def`, `line-after-empty-evals` — последние два проверяют, что не-эмитящие формы не сдвигают нумерацию).
- Заголовок первой строки управляет флагами раннера: `sexc-keep-line` (оставить `#line`), `--no-prelude` (без прелюдии). По умолчанию: `--quiet --no-line`.
- Новый standalone-пример без внешних зависимостей — добавить путь в `tests/examples/standalone.list`. `run_example.sh` собирает его **и gcc, и clang** (clang — если установлен; ловит непортабельность в GNU-расширениях типа `__typeof__`/`cleanup`).
- **Проверка вывода примера**: положи рядом сайдкар `examples/X.expected` — тогда раннер ещё и **запустит** gcc-бинарь и сдиффит stdout. Нет сайдкара → только компиляция. Сгенерировать/обновить: `UPDATE=1 tests/run_example.sh examples/X.sexc` (или `UPDATE=1 ./tests/run.sh`), потом отревьюить. Только для детерминированного вывода.
- Examples с экзотическими link-флагами могут указывать их в первой строке: `;; sexc-test-flags: -lm -lpthread`.
- `sexc check` exit-коды покрыты smoke-секцией в `run.sh` (не отдельные файлы).

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

## Диагностика ошибок

Три категории исключений, разный рендер:

| Класс | Когда бросается | Что печатается |
|---|---|---|
| `Sexc_cli_error` | Невалидный argv / неизвестная подкоманда — только в `src/sexc.ml`. | `error: <msg>` + полный usage() + exit 1. |
| `Sexc_diagnostic` | Любая компиляционная ошибка с известным `file:line:col`. Бросается из Reader напрямую (`fail_diag`) либо "promoted" из bare `Sexc_error` через `Common.promote_error_to_diagnostic`. | `file:line:col: error[phase]: msg` + строка-источник + caret `^` + опц. hint-блок (см. ниже). |
| `Sexc_error` (legacy) | Bare `fail`/`failf` без локации. Сохранён для глубоких фаз, которые ещё не привязаны к span. | Печатается одной строкой `error: msg` + опц. hint. **Без** usage'а. |
| `Sexc_errors` (multi) | Несколько накопленных ошибок: `compile_forms` ловит ошибку каждой top-формы, копит и продолжает, в конце бросает агрегат. | Все диагностики через пустую строку. Для единственной ошибки вывод идентичен одиночному пути. |

### Multi-error

`compile_forms` обрабатывает каждую top-форму в `try` (`emit_safe`): ошибка одной формы (`Sexc_diagnostic`/`Sexc_error`) пишется в аккумулятор `error_item` (с захваченной головой macro-chain для hint), форма пропускается, обработка продолжается. После прохода — если ошибки есть, бросается `Sexc_errors items`; C **не** эмитится (ни stdout, ни `-C gcc`). Так пользователь видит все проблемы за один прогон. Ошибки до per-form цикла (reader, `Macro.collect`) остаются одиночными.

### `sexc check`

`sexc [--no-prelude] check <input.sexc|->` — гоняет полный pipeline, отбрасывает C, печатает диагностику (через те же `Sexc_errors`/`Sexc_diagnostic`), exit nonzero при ошибках, тихо при успехе. Для CI/редакторов чище, чем `compile` с игнором stdout. Emacs flymake мог бы переключиться на `check`, но сейчас использует обычный stdin-compile (эквивалентно по диагностике).

### Источник позиций (deep spans)

`Raw.t` сам несёт `Common.span option` на КАЖДОМ узле:
```ocaml
type t =
  | Atom of string * Common.span option
  | Str of string * Common.span option
  | List of t list * Common.span option
```

Каждый pattern-match теперь — `Raw.X (arg, _)`; каждый конструктор — `Raw.X (arg, None)` (или `Raw.X (arg, Some sp)` если span известен). Smart-constructors `Raw.atom`/`Raw.str`/`Raw.list_` (с опциональным `?span`) и accessor `Raw.span_of` есть в `src/raw.ml`.

Откуда берётся span:
- **`src/reader.ml:parse_many`** — каждый узел пишется с реальным span (`file`/`source`/`start_off`/`end_off`) из cursor state.
- **Macro синтез** (quasiquote, splice, unquote, литералы внутри тела макроса) — наследует **call-site** span текущего раскрываемого макроса через `Macro.ctx.expand_site_span`. `Macro.apply` устанавливает поле перед `eval_expr m.body`, `eval_quasiquote` читает и проставляет span на синтезированные узлы. Это значит, что ошибки **внутри stdlib-макроса** указывают на пользовательский call-site, а не на `std/c-interop.sexc`.

Три уровня приоритета локации (от точного к грубому), `promote_error_to_diagnostic` выбирает первый доступный:
1. **`Common.current_eval_span`** — span формы, которую СЕЙЧАС вычисляет `$`-evaluator. `eval_expr` обёрнут так, что на каждом рекурсивном шаге пишет `Raw.span_of expr` в этот ref; на исключении ref остаётся грязным (= самая глубокая упавшая подформа). Это покрывает ошибки compile-time Lisp'а внутри `%eval`/`%evals`/`$defun` (например опечатка `$for222222` или unbound `$strrr` глубоко внутри quasiquote). Сбрасывается в None в начале каждой top-формы (`with_top_span`).
2. **`Common.current_top_span`** — span top-level формы. Fallback для bare `fail`/`failf` в helper'ах без span'а.
3. None → пробрасывается как есть `Sexc_error`.

Бросать ошибку с конкретным span:
- `Common.fail_at ~phase span msg` / `Common.failf_at ~phase span fmt` — если span = Some, бросает `Sexc_diagnostic`; если None, fall back на `Sexc_error` (который потом promoted).
- `Macro.apply` использует `failf_at` для arity-ошибок surface-макросов; `eval_expr_inner` использует `failf_at` для unbound-variable (span самого атома).

**Важно при macro expansion:** `expand_one` НЕ должен стирать спаны при пересборке пользовательских форм. Финальный fallthrough `Raw.List (xs, sp) -> Raw.List (..., sp)` сохраняет span (раньше ставил None → поля struct с list-типом вроде `((%ptr char) name)` теряли локацию и `#line` дрейфовал).

### `#line` директивы (source maps для C-компилятора)

Генерируемый C несёт `#line N "file"`, чтобы ошибки самого gcc указывали на `.sexc`, а не на временный `.c`. По умолчанию вкл; `--no-line` отключает (тест-раннер его передаёт, чтобы golden-вывод не зависел от номеров строк — opt-in обратно через заголовок `;; sexc-keep-line`).

Гранулярность — точная, не top-form:
- **Стейтменты**: frontend оборачивает каждый в `SAt of span * stmt` (`parse_stmt_or_decl` вешает span исходной Raw-формы); `Codegen_c.emit_stmt` для `SAt` эмитит `line_directive` перед телом.
- **Поля struct/union**: `field.f_span` + `Codegen_c.emit_fields` ставит `#line` перед каждым полем (иначе не-эмитящий `:fields` сдвигал бы нумерацию).
- **Top-форма**: `compile_forms` префиксит чанк `#line` от `top.span` — покрывает строку сигнатуры функции / `typedef`.

Дрейф от не-эмитящих форм (`%defmacro`, `%doc`, `(%evals ($list))` → ноль форм, blank/comment) не страшен на top-level: каждая следующая top-форма ре-якорится своим `#line`. Внутри функции — каждый стейтмент ре-якорится через `SAt`. Покрыто тестами `line-*.sexc-test`.

`Codegen_c.line_directive sp` — общий хелпер; гейтится `Common.emit_line_directives`.

`raw_equal` в `src/macro.ml` пишется span-агностично — pattern-match `Raw.Atom (x, _), Raw.Atom (y, _) -> ...`. Это критично для `$eq?` и `$case`.

### Контекст активной surface-формы (hint с docs)

- `Common.current_macro_chain : string list ref` — стек активных макросов от самого внешнего к самому глубокому (голова — глубочайший).
- `Common.with_macro_context name f` пушит `name` на стек, на нормальном return — попит. **На исключении не попит** — стек остаётся "грязным", чтобы CLI-handler в `src/sexc.ml` мог прочитать самую глубокую активную форму и вывести её документацию через `Index.find_by_name` + `Index.render_show_doc`. Процесс всё равно exit'ится после ошибки, leak не проблема.
- `Macro.apply` уже оборачивается в `with_macro_context m.name`. Дополнительно можно обернуть известные intrinsics во `frontend.ml` (например `Type#` constructor), если хотим hint для них тоже.

### Конкретный пример

```
$ echo '(defn int main () (when))' | sexc -
<stdin>:1:19: error[macro]: Macro when expects at least 1 arguments, got 0
(defn int main () (when))
                  ^

Signature: (when cond &rest body)
Doc: Execute BODY when COND is truthy.
Example: (when (> x 0) (set y x))
```

Caret указывает точно на `(when)` (col 19), а не на начало `(defn ...)`.

Глубокая вложенность тоже работает:
```
$ cat /tmp/deep.sexc
(defn int main ()
  (decl (int sum) 0)
  (dotimes i 10
    (when (> i 5)
      (incf-by)))
  (return sum))
$ sexc /tmp/deep.sexc
/tmp/deep.sexc:5:7: error[macro]: Macro incf-by expects 2 arguments, got 0
      (incf-by)))
      ^

Signature: (incf-by x n)
Doc: Increment X by N.
Example: (incf-by total 4)
```

### Что NOT делать

- **Не** конвертировать ВСЕ ~100+ `fail`/`failf` в `fail_at` поштучно. Для типичных сайтов внутри helper'ов (`expect_atom`, `expect_list`) — оставлять bare `fail`; `promote_error_to_diagnostic` поднимет до доступного span'а (top-form или expand_site_span). Точечно `fail_at` ставить там, где конкретная форма очевидна (arity check в `Macro.apply`).
- **Не** дёргать usage() из не-CLI ошибок — usage остаётся только в ветке `Sexc_cli_error`.
- **Не** ломать span-агностичность `raw_equal` — `$eq?`/`$case` сравнивают по узлам, без оглядки на позиции.

## Макросы std/core.sexc (актуальные правила)

- `if` строго только 2 или 3 аргумента.
- Для сложных ветвлений использовать `cond`.
- `decl` теперь в стиле `let*` и с **обязательной инициализацией**:
  - Формат: `(decl (type name) init (type2 name2) init2 ...)`.
  - Примеры:
    - `(decl (int x) 5)`
    - `(decl (int x) 5 (int y) (+ x 9))`.
  - Старый формат `(decl name type ...)` — **удален** (breaking change).
  - **Спецификаторы у типа** через ведущие `:keyword` в тип-позиции
    (`parse_decl_type`, `frontend.ml`): `(decl ((:thread_local int) x) 0)` →
    `_Thread_local int x = 0;`. Допустимы `:thread_local`/`:static`/`:extern`/
    `:register`/`:auto`/`:inline`/`:const`/`:volatile`/`:atomic`; стакаются
    (`(:static :thread_local int)`); неизвестный `:kw` — ошибка. Эмитятся
    префиксом перед типом (`decl.d_specs`), сосуществуют со старыми
    `%storage`-атомами (`%static` и т.п.).
- **Flat keyword type form** (sexc, `$unpack-type` в `std/c-interop.sexc`, без
  правки OCaml-парсера типов): `:*`/`:ptr`, `:const`, `:volatile`, `:restrict` —
  плоская запись типа вместо матрёшки `%ptr`/`%const`. Схема «слева = снаружи»
  (каждый токен оборачивает остальное): `(:* :const char)` → `const char *`,
  `(:const :* char)` → `char * const`, `(:* :* int)` → `int **`. Атомы/`%`-формы/
  `(unsigned long)` проходят насквозь. Раскрывается во всех тип-позициях:
  `decl`/`adecl`/`defn`(ret+params)/`struct`/`union`/`cast`/`sizeof`/`with`.
- **Bundled binding form** (`$binding-split`): в binding-позициях (параметры,
  поля, `decl`/`adecl`/`with`) можно слить тип+имя: `(:* :const char msg)` ≡
  `((:* :const char) msg)` → `const char *msg`. Дискриминатор — первый элемент
  группы начинается с `:` → bundled, иначе классика `(тип имя…)` (не ломается).
  База — ровно один элемент после модификаторов (многословную группируй:
  `(:const (unsigned long) x)`). Namespace: `rewrite_params` (compiler.ml) видит
  `:keyword`-группу как единый тип, поэтому модульный базовый тип в bundled
  всё равно квалифицируется (`(:* Buf b)` в `%module ring` → `ring/Buf *b`).
- `with`/`defer1`/`defer*` — динамический биндинг и scoped-cleanup через
  `__attribute__((cleanup))` (GCC/Clang). `(with binding value body...)` сохраняет/
  восстанавливает переменную на любом выходе из блока (вкл. `return`). **Переменная
  объявляется автоматически** (`_Thread_local`) — `with` шлёт `%decl` в голову файла
  через `%file-head-splice` (видна всем читателям, в т.ч. callee выше по файлу; дедуп
  по имени). `binding` задаёт тип: атом `var` → инференс через `(%typeof value)`;
  список `(Type var)` → явный тип (нужен для self-ref/локальных значений, напр.
  `(with (int *depth*) (+ *depth* 1) ...)`). `(defer1 fn arg)`
  зовёт `fn(arg)` на выходе (LIFO), `fn` — одного указательного аргумента;
  `(defer* (fn arg)...)` — пачка `defer1` (общий `$sx-defer-decl` строит guard на
  каждый клауз). Общий top-level хелпер (guard-struct + restore/run fn) всплывает
  один раз через `%top-level-splice` (`$sx-with-runtime`/`$sx-defer-runtime`, флаг
  в метадате + `#ifndef`-гард). `defer1`/`defer*` НЕ создают scope (сплайс через
  `%evals` в текущий блок), иначе cleanup сработал бы сразу.
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

- `%top-level-splice` всплывает на файловый уровень из **любой** вложенности
  (`hoist_splices` в `compiler.ml`): splice, сгенерированный макросом внутри тела
  функции, вытаскивается на top-level (и удаляется из исходной позиции). Это даёт
  statement-макросу (`with`/`defer1`) эмитить общий top-level хелпер (typedef /
  `static inline` fn). `quote`/`quasiquote`-поддеревья не трогаются. Дедуп — забота
  макроса (напр. `#ifndef`-гард). Написанный буквально в выражении/stmt
  `%top-level-splice` всё ещё ошибка (`frontend.ml`) — он рассчитан на генерацию
  макросом, а не на ручное использование во вложенной позиции.

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
  - `typedef ty name` → `:kind 'typedef`, `:underlying ty` (алиас несёт структуру → указатель за typedef виден из меты)
  - `enum name :variants ... :methods ...` → `:kind 'enum`, `:variants` (имена), `:methods`
- `(%m-dump)` — top-level интринсик, разворачивается в `(%comment "...")` с отсортированным дампом всей метадаты на момент expand'а. Поставить в конце файла, чтобы увидеть финальное состояние.
- `(%comment "text")` — новая top-level форма, эмитит `/*text*/` (parse в `frontend.ml`, codegen в `codegen_c.ml`).
- `(%cpp "if defined(_WIN32)")` — top-level форма, эмитит сырую препроцессорную директиву `#` + строка, verbatim без mangling (parse в `frontend.ml`, codegen в `codegen_c.ml`). Кирпич для условной компиляции; поверх него в `std/c-interop.sexc` собраны макросы `when!`/`if!`/`cond!` (через `%top-level-splice`), эмитящие `#if`/`#elif`/`#else`/`#endif` по строковому условию. Top-level only.

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
- `%module` применяет префикс `foo/` к именованным top-level сущностям файла (`defn`, `define`, `struct`, `union`, `enum`, `%def-fn`, `%decl-fn`, `%define`, `%typedef`) и локальным ссылкам на них в этом же файле.
- Внутри файла можно использовать короткие имена без префикса; снаружи доступны имена с префиксом `foo/...`.
- `%module` удаляется на раннем compiler-pass и не попадает в frontend/codegen как runtime-форма.
- **Квалификация работает на раскрытом `%`-IR (после макрофазы), НЕ на surface.**
  Каждая top-форма тегается своим `%module` (`top_form.module_name`); проход
  `qualify_ir` (`src/compiler.ml`) рерайтит фиксированный набор `%`-форм с
  известными позициями типов/имён (`%def-fn`/`%decl-fn`/`%struct`/`%union`/
  `%enum`/`%typedef`/`%arrow`/`%dot` + catch-all для вызовов/типов), защищая
  name-позиции (имена параметров/полей/вариантов). Весь surface-сахар (flat/
  bundled-типы, любой будущий) разворачивается в `%`-IR ДО прохода → **новый
  type-сахар НЕ требует правок OCaml**.
- Метадату квалифицируют сами макросы: builtin `$qualify` (ключи: `Buffer` →
  `ring/Buffer`, идемпотентно) и `$qualify-type` (типы в значениях `:c-type`/
  `:params`/`:fields`/`:return-type`/`:underlying` — по name_map модуля, чтобы
  `int`/чужие типы не трогать). Оба читают `ctx.current_module`/
  `ctx.current_name_map`, выставляемые per-form в `compile_forms`.

## Именование уровней (строго)

- `%...` — системные/IR формы компилятора.
- `$...` — compile-time meta builtins (доступны в `%defmacro`, `%eval`, `%evals`).
- Имена без `%` и без `$` — только surface DSL (объявлены в prelude-файлах `std/c-interop.sexc` и `std/meta.sexc`).
- Legacy meta-имена без `$` (`car`, `cdr`, `null?`, `if`, ...) запрещены.

## Группы ключевых слов

- `IR/Intrinsic (%...)`:
  - Top-level/decl/fn: `%include`, `%define`, `%define-macro`, `%ifdef`, `%cpp`, `%inline`, `%static`, `%extern`, `%typedef`, `%decl-fn`, `%def-fn`, `%decl`, `%decl-many`, `%top-level-splice`, `%file-head-splice`, `%comment`
  - Stmt/control: `%block`, `%if`, `%while`, `%do-while`, `%for`, `%switch`, `%case`, `%default`, `%break`, `%continue`, `%return`, `%goto`, `%label`, `%nop`
  - Expr/operators: `%raw`, `%expr`, `%typeof`, `%null`, `%cast`, `%sizeof-type`, `%sizeof-expr`, `%ternary`, `%comma`, `%aref`, `%dot`, `%arrow`, `%call`, `%!`, `%~`, `%addr`, `%deref`, `%pre-inc`, `%pre-dec`, `%post-inc`, `%post-dec`, `%+`, `%-`, `%*`, `%/`, `%%`, `%==`, `%!=`, `%<`, `%<=`, `%>`, `%>=`, `%&&`, `%||`, `%set`, `%+=`, `%-=`, `%*=`, `%/=`, `%%=`, `%&=`, `%|=`, `%^=`, `%<<=`, `%>>=`
  - Compile-time control: `%defmacro`, `%eval`, `%evals`, `%module`, `%m-dump`
- `Meta builtins ($...)`:
  - В `src/macro.ml` (OCaml-primitives): `$quote`, `$if`, `$cond`, `$case`, `$cons`, `$car`, `$cdr`, `$null?`, `$atom?`, `$eq?`, `$keyword?`, `$keyword-name`, `$let`, `$do`, `$not`, `$error`, `$assert`, `$gensym`, `$symcat`, `$str`, `$namespace-of`, `$current-module`, `$qualify`, `$qualify-type`, `$+`, `$-`, `$*`, `$/`, `$defun`, `$|>`, `$||>`, `$|as>`, `$--map`, `$--filter`, `$--reduce`, `$dolist`, `$map`, `$filter`, `$reduce`, `$for`, `$m-put`, `$m-get`
  - В `std/meta.sexc` (sexc `$defun`): `$list`, `$append`, `$length`, `$reverse`, `$nth`, `$subst`
- `Surface std macros` (без префикса, в std/*.sexc):
  - `std/c-interop.sexc` (всё разворачивается в `%`-IR): `include`, `define`, `defn` (с опц. флагами `:static`/`:inline`), `decl`, `adecl`, `free*`, `block`, `if`, `cond`, `when`, `unless`, `while`, `for`, `dotimes`, `for-range`, `repeat`, `return`, `set`, `incf`, `decf`, `incf-by`, `decf-by`, `cast`, `struct`, `union`, `typedef`, `enum`, `init`, `zero-init`, `sizeof` (авто-диспатч type/expr), `sizeof-type`, `sizeof-expr`, `aref`, `dot`, `arrow`, `.`, `->`, `not`, `+`, `-`, `*`, `/`, `%`, `=`, `not=`, `<`, `<=`, `>`, `>=`, `&&`, `and`, `||`, `or`, `post-inc`, `nop`, `nil`, `do`, `nil?`, `not-nil?`, `zero?`, `nonzero?`, `ltz?`, `letz?`, `gtz?`, `getz?`, `pos?`, `neg?`, `even?`, `odd?`, `bit-set?`, `between?`, `if-nil`, `when-nil`, `unless-nil`, `when!`, `if!`, `cond!`, `with`, `defer1`, `defer*`
  - **Конвенция**: имя любого surface-предиката заканчивается на `?`
    (`nil?`/`not-nil?`/`zero?`/`ltz?`/`letz?`/`gtz?`/`getz?`). `do` — плоская
    последовательность стейтментов без скоупа (через `%evals`-сплайс), в отличие
    от `block` (оборачивает в `{}`).
  - `std/derive.sexc` (in-place рефлексия по метадате): `eq-as`, `print-as` (+ compile-time `$type-kind`/`$pointer?`/`$rem-mods`/`$fmt-for-type`)
  - `std/meta.sexc` (не привязано к C): `|>`, `||>`, `|as>` (threading)

## Полезные sugar-макросы

- `(zero-init)` -> `{0}` (позиция инициализатора); `(zero-init Type)` ->
  `(Type){0}` compound literal (валидно как выражение где угодно).
- Часть простых оберток выражается через `%raw` (например `not`, `aref`, `post-inc`, `sizeof-expr`).

## Struct и инициализация

- В std есть макросы:
  - `(struct Name :fields (type field) ... :methods (defn ...) ...)` -> `typedef struct ... Name;` + namespace-функции
  - Секции `:fields` обязательна, `:methods` опциональна; старый mixed-формат `struct` удален.
  - Внутри `struct` можно объявлять методы через `defn`; они автогенерируются как `Name/method`.
  - `(union Name (type field) ...)` -> `typedef union ... Name;`
- `Type#` — типизированный compound-literal-конструктор (конвенция: `#` = «это
  конструктор», как `new`). В макрофазе (`macro.ml` `expand_one`, суффикс `#`)
  разворачивается в `(cast Type (init args…))`; всю работу по построению `{…}`
  делает `init`. База квалифицируется текущим модулем; bare-имена в выхлопе
  доквалифицирует `%`-IR проход. ИСКЛЮЧЕНИЕ: если база — sum-вариант (есть мета
  `:sum-of`), `#` делегирует `sum-construct` (см. defsum ниже). Раньше Type# был
  frontend-формой (`parse_type_hash_init` + `ECompoundLiteral`) — удалено.
  - `(Roots# :x1 5 :x2 7)` -> `(Roots){.x1 = 5, .x2 = 7}` (designated, keyword)
  - `(Pt# 5 6)` -> `(Pt){5, 6}` (positional)
  - `(Pt#)` -> `(Pt){0}` (zero)
- `init` — голый агрегат-инициализатор без типа (`std/c-interop.sexc`):
  `(init)` → `{0}`, `(init 1 2 3)` → `{1, 2, 3}`, `(init :x 1 :y 2)` →
  `{.x = 1, .y = 2}`. Режим по первому аргументу (`:keyword` ⇒ designated),
  через `$keyword?`. Вложенность для 2D/массивов структур. Для decl-init
  массивов: `(decl ((%array int 4) a) (init 1 2 3 4))`. `zero-init` —
  тонкий частный случай (оставлен, не ломаем).

## typedef и enum

- `(typedef ty name)` -> `typedef <ty> name;`. Тип первым (как в C/в `%typedef` IR).
  Пишет `:kind 'typedef`/`:underlying` — алиас несёт структуру в мете.
- `(enum Name :variants ... :methods ...)` — параллельно struct:
  - `:variants` (обязательна, первая): атом (авто-нумерация) | `(имя выражение)`
    (явное значение — любое выражение: `(%<< 1 1)`, отриц., `(+ A 10)`; C сам
    продолжает нумерацию). -> `typedef enum Name { ... } Name;`
  - `:methods` (опц.): `defn` -> функции `Name/method` (паттерн struct).
  - Мета: `:kind 'enum`, `:variants` (имена), `:methods`, `Name :fns`.
- IR: `%enum` несёт тело вариантов: `TEnum of string * (string * Raw.t option) list`
  (frontend + codegen). `(%enum Name)` без тела = ссылка `enum Name` (backward-compat).
  Значение варианта — `Raw.t` (уже `%`-IR после macro phase); codegen рендерит
  через `emit_expr (parse_expr raw)`. Для этого `emit_type_base`↔`emit_expr` в
  codegen объединены в одну рекурсивную группу (типы↔выражения взаимно-рекурсивны:
  cast/sizeof/enum-значение).

## defsum / match: tagged unions (`std/sum.sexc`)

Алгебраические типы (Rust/OCaml-вариант) — **чистый макрос**, ядро не трогали
(кроме `#`-диспатча и `defsum` в `collect_module_defined_names`).

```
(defsum Shape
  (Circle (float r))
  (Rect   (float w) (float h))
  (Unit))                          ; вариант без полей
```
Раскрывается в (всё имена квалифицируются модулем, печём `base = ($qualify Name)`):
- enum-тег `Name/tag` { `Name/Circle`, … } — значения тегов;
- payload-struct на вариант с полями: `Name/Circle/p = struct {...}`;
- сам тип `Name = struct { Name/tag tag; union { Name/Circle/p Circle; … } u; }`
  (union опускается, если НИ у одного варианта нет полей);
- предикаты-функции `Name/Circle?` → `s.tag == Name/Circle`;
- метадата: на типе `:kind 'sum :variants :tag-type`; на каждом варианте
  `Name/Variant` → `:sum-of :member :fields`.

**Конструктор** — `Name/Circle# v1 v2…` (конвенция `#`). Правило `#` в `macro.ml`
видит `:sum-of` в мете и делегирует sexc-макросу `sum-construct`, который читает
мету и строит тегированный compound literal `(cast Name (init :tag … :u (init :Circle (init v1 v2))))`.

**match** (`(match s (Variant (binders…) body…) … [...])`):
- тип скрутини берётся из `($m-get s :c-type)` → `:variants` (s — переменная);
- → `%switch (. s tag)` + на каждый arm `%case Name/Variant` с позиционным
  биндингом полей через `(decl (ty bn) (. (. (. s u) member) field))` + `%break`;
- **exhaustiveness**: непокрытые варианты → `$error` (compile-time). Хвостовой
  `...` отключает проверку (частичный match);
- `default`: exhaustive → `__builtin_unreachable()` (глушит `-Wreturn-type` когда
  все ветки `return`); партиал → пустой `break` (глушит `-Wswitch`).

**Namespace**: `defsum` печёт полностью-квалифицированные имена сам (enum-варианты
`%`-IR проход НЕ квалифицирует — protection), и зарегистрирован в
`collect_module_defined_names`, так что пользовательские ссылки на тип `Name`
квалифицируются. **v1-ограничение**: имена генераторов (`Name/Variant#`/`?`) —
глобальные; два модуля с одинаковым `defsum Name` дадут коллизию (документировано,
редкий кейс). Пример — `examples/sum-types.sexc`.

## derive: in-place `print-as` / `eq-as` (`std/derive.sexc`)

Рефлексия по метадате типов, БЕЗ генерации именованных функций — их пользователь
делает однострочной обёрткой.
- `(eq-as Type a b)` — ВЫРАЖЕНИЕ: `a.f == b.f && ...`; вложенный struct → рекурсивно;
  scalar/enum/ptr → `==`; array/union → `$error` (follow-up).
- `(print-as Type x)` — СТЕЙТМЕНТ: `(block (printf "T {") <поля> (printf "}"))`;
  scalar → printf по `$fmt-for-type`; struct → рекурсия; enum → `%d`; ptr/fn →
  `%p`+cast; array/union → `$error`.
- **value vs pointer**: тип-форма решает аксессор — `Type` → `.` (значение),
  `(%ptr Type)` → `->`. `$acc-of`/`$sname-of` диспатчат по `$type-kind`.
  - `print-as*`/`eq-as*` (Type p) — сахар = `print-as`/`eq-as` с `(%ptr Type)` →
    `p->f` без ручного `%deref`. (для методов, где `self` — указатель.)
  - `(print-as x)` (1 арг) — выводит тип из `($m-get x :c-type)`: работает для
    `decl`-переменных (включая указательные → авто `->`); НЕ для параметров
    функций (defn не пишет тип параметров) и не для shadowing.
- Обёртки: `(defn void Foo/print ((Foo v)) (print-as Foo v))`,
  `(defn void Foo/print* (((%ptr Foo) p)) (print-as* Foo p))`.
- `derive/prints` — генератор пары методов внутри `struct :methods`:
  `(derive/prints)` → `Type/print` + `Type/print*`; `(derive/prints show)` →
  `Type/show` + `Type/show*`. Тип подставляет `struct`.

### Параметры в метадате + генераторы методов

- `defn` теперь пишет тип каждого параметра: `($m-put pname :kind 'var :c-type ty)`.
  Поэтому `(print-as self)` работает внутри тела (тип параметра выводится).
  Глобально по имени (последний выигрывает), но раскрытие тела идёт сразу после
  defn → в теле тип верный. Параметры функций ⇒ inference работает и в методах.
- `struct`/`enum` методы теперь эмитятся через surface `defn` (а не голый
  `%def-fn`): `(defn ret Type/method params body)`. defn сам пишет fn- и
  param-метадату + неймспейс. Вывод C идентичен прежнему.
- `:methods` пускает не только `defn`, но и **генераторы методов** — любой
  другой список `(GEN args...)`. `struct`/`enum` подставляют имя типа первым
  аргументом: `(GEN Type args...)`, который раскрывается в `defn`(ы). Так
  устроен `derive/prints`.
- `$type-kind ty` → `scalar|ptr|array|fn|struct|union|enum`: атом резолвит через
  `$m-get :kind` (typedef → рекурсия по `:underlying`), список — по голове
  (`%ptr`/`%array`/…), не-`%`-голова = многословный скаляр (`(unsigned long)`).
- `$fmt-for-type` — printf-формат по man (int→%d, (unsigned long)→%lu, double→%f,
  size_t→%zu, …; многословные матчатся структурно `$eq?`); неизвестный скаляр → `$error`.
- В prelude (`core.sexc` импортирует `derive.sexc`). Генерит surface-формы.
- Follow-up: печать enum по имени (через `:variants`), полный обход массивов.

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
