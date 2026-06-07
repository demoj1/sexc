# SexC

S-expression frontend for C with a Lisp-style macro system.
Compiler written in OCaml.

[English](#english) · [Русский](#russian)

---

> ## ⚠️ Heavy WIP — do not use in production
>
> Personal research project. Surface syntax, intrinsics,
> metadata schema, stdlib layout and CLI flags change without
> notice. No stability guarantees, no semantic versioning, no
> migration tools. Codegen has known rough edges, errors are
> incomplete, the macro evaluator can leak state between files
> in non-obvious ways.
>
> ## ⚠️ Глубокий WIP — не для продакшна
>
> Персональный исследовательский проект. Синтаксис, intrinsic'и,
> схема метадаты, раскладка stdlib и CLI-флаги меняются без
> предупреждения. Никаких гарантий стабильности, semantic
> versioning или миграций нет. У codegen есть известные
> шероховатости, сообщения об ошибках неполные, macro-evaluator
> умеет незаметно переносить state между файлами.

---

<a id="english"></a>

## EN

S-expressions in, C out. No runtime, no GC, no hidden
allocations — the target is ordinary C and stays that way.
Most of what looks like syntax is a macro defined in `std/`;
the OCaml core only does reader → macro engine → frontend →
codegen.

### Type declarations read left to right

C declarations are read inside-out — type constructors bind
in the wrong direction, so anything past one pointer needs
mental parsing.

```c
int (*sort_cmp)(const void *, const void *);
void (*sig_handlers[16])(int);
char *(*strdup_fn)(const char *);
```
```lisp
(decl (%ptr (%fn int ((%ptr (%const void)) (%ptr (%const void))))) sort_cmp)
(decl (%array (%ptr (%fn void (int))) 16)                          sig_handlers)
(decl (%ptr (%fn (%ptr char) ((%ptr (%const char)))))              strdup_fn)
```

Every type constructor (`%ptr`, `%array`, `%fn`, `%const`,
`%volatile`, `%restrict`) is prefix, so the type reads in one
direction with no spiral rule.

### Struct + methods + named-field literals

```c
typedef struct { float x, y; } Vec2;

Vec2 Vec2_add(Vec2 a, Vec2 b) {
    return (Vec2){ .x = a.x + b.x, .y = a.y + b.y };
}

int main(void) {
    Vec2 a = { .x = 1.0f, .y = 2.0f };
    Vec2 b = { .x = 3.0f, .y = 4.0f };
    Vec2 c = Vec2_add(a, b);
    printf("(%f, %f)\n", c.x, c.y);
}
```
```lisp
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

Methods declared inside `struct` are namespaced as
`Type/method` at codegen — `MathOps/add`, `Vec2/add`. The
`Type#` form is a named-field constructor; missing fields
are zero-initialised.

### typedef, enum, and metadata-driven derive

`typedef` and `enum` mirror `struct`: they emit the C type **and**
record faithful metadata. `enum` is parallel to `struct` — sectioned
`:variants` + optional `:methods`:

```lisp
(typedef (%ptr char) String)

(enum Dir
  :variants
  North (East 5) South West       ; atom = auto-number, (name expr) = explicit
  :methods
  (defn (%ptr char) describe ((Dir d)) (return "...")))   ; → Dir/describe
```

Because the metadata is faithful, macros can **reflect over a type**
and generate code from it — no compiler magic, just stdlib. The
flagship is `derive/prints`: drop it into a struct's `:methods` and
get a value-printer and a pointer-printer for free.

```lisp
(struct Vec3
  :fields
  (float x) (float y) (float z)
  :methods
  (derive/prints))      ; ← generates Vec3/print and Vec3/print*
```
expands (reading `Vec3`'s recorded `:fields`) to:
```c
void Vec3_print(Vec3 self) {
    printf("Vec3 {\n");
    printf("  x = %f\n", self.x);
    printf("  y = %f\n", self.y);
    printf("  z = %f\n", self.z);
    printf("}\n");
}
void Vec3_print_ptr(Vec3 *self) { /* same, via self->x ... */ }
```
Add a field to `Vec3` and both printers pick it up — no per-field
stub, no codegen step. The building blocks are also usable directly:

```lisp
(print-as Vec3 v)     ; value:   v.x ...
(print-as* Vec3 p)    ; pointer: p->x ...
(print-as v)          ; infer the type from v's declaration metadata
(eq-as Vec3 a b)      ; expression: a.x == b.x && a.y == b.y && a.z == b.z
```

`print-as` chooses printf specifiers per field type (from `man 3 printf`),
recurses into nested structs, prints pointers as `%p`. It's ~180 lines of
SexC in `std/derive.sexc`, reading the same `$m-get … :fields` table that
`struct` writes — the whole "derive" mechanism lives in the language, not the
compiler.

### Threading instead of nested calls

```c
length(strdup(trim(to_upper(input))));
```
```lisp
(|> input to_upper trim strdup length)
```

Three threading macros, picked by where the value goes:
- `|>` — first arg (`(|> x (f a))` → `(f x a)`)
- `||>` — last arg (`(||> x (f a))` → `(f a x)`)
- `|as>` — substitute by name (`(|as> x it (f 1 it))`)

### Multi-binding `decl` and `set`

```c
int x = 1, y = 2, z = 3;
struct point p;
p.x = 0; p.y = 0; p.z = 0;
```
```lisp
(decl (int x) 1 (int y) 2 (int z) 3)
(set (. p x) 0 (. p y) 0 (. p z) 0)
```

### Multi-branch without if/else chains

```c
int sign;
if (x > 0)        sign = 1;
else if (x < 0)   sign = -1;
else              sign = 0;
```
```lisp
(decl (int sign)
  (cond ((> x 0)  1)
        ((< x 0) -1)
        (else    0)))
```

`when` / `unless` cover the single-branch cases. `dotimes`,
`for-range`, `incf` / `decf` cover the common loop shapes.

### Modules and import

```lisp
; ring-buffer.sexc
(%module ring)
(struct Buffer :fields (int cap) (int head))
(defn void init (((%ptr Buffer) b) (int c)) ...)
```
```lisp
; main.sexc
(%import "./ring-buffer" :as r)
(decl (r/Buffer buf) (zero-init))   ; ring/Buffer + alias
(r/Buffer/init (%addr buf) 1024)
```

Every top-level symbol of a module is namespaced to
`module-name/...`. `:as` adds an alias. Cycles are detected
and reported.

### Conditional compilation

For conditions only the C compiler can resolve — platform and
compiler macros like `_WIN32`, `__linux__`, `__APPLE__`,
`__GNUC__` — there is a `!`-family that emits real
`#if`/`#elif`/`#else`/`#endif`. The condition is a raw string
spliced verbatim into the directive:

```lisp
(when! "defined(__GNUC__)"
  (defn int has_gnuc () (return 1)))

(cond!
  ("defined(__ANDROID__)" (defn (%ptr char) os () (return "android")))   ; before linux!
  ("defined(__linux__)"   (defn (%ptr char) os () (return "linux")))
  ("defined(_WIN32)"      (defn (%ptr char) os () (return "windows")))
  (else                   (defn (%ptr char) os () (return "unknown"))))
```
```c
#if defined(__ANDROID__)
char *os(void) { return "android"; }
#elif defined(__linux__)
char *os(void) { return "linux"; }
#elif defined(_WIN32)
char *os(void) { return "windows"; }
#else
char *os(void) { return "unknown"; }
#endif
```

`when!` is a single guarded branch, `if!` is a two/three-form
Lisp `if`, `cond!` is the multi-branch form. Branch order
matters: Android also defines `__linux__`, Clang also defines
`__GNUC__` — put the more specific one first. These are top-level
only (selecting whole functions / structs / defines per platform),
built as macros over the one `%cpp` primitive. Compile-time-known
flags don't need this — use `%eval`/`$if` (below) and the dead
branch never reaches the C at all.

### Compile-time evaluation: `$defun`, `%eval`, `%evals`

Beyond `%defmacro`, there's a small Lisp that runs *during* expansion —
the `$...` evaluator (call-by-value, with `$if`/`$let`/`$for`/`$map`/
`$car`/`$cdr`/`$cons`/arithmetic/quasiquote). Two intrinsics splice its
results into your code:

- **`(%eval EXPR)`** — evaluate `EXPR` to **one** form and splice it.
- **`(%evals EXPR)`** — evaluate `EXPR` to a **list** and splice each
  element into the surrounding list context.

```lisp
; $defun — a compile-time function (no runtime cost)
($defun $square (n) ($* n n))

; %eval: splice one computed form
(define BUF_SIZE (%eval ($square 8)))      ; => #define BUF_SIZE 64

; %evals: generate many forms from data
(%evals
  ($for (row '((inc 1) (dec -1)))
    `(defn int ,($car row) ((int x))
       (return (+ x ,($car ($cdr row)))))))
; => int inc(int x){ return x + 1; }
;    int dec(int x){ return x + -1; }
```

`%eval` works in top-level, statement, and even expression position
(`(+ (%eval ...) y)`); `%evals` is for list contexts (a function body,
a top level, an argument list). Most of `std/meta.sexc` is `$defun`s —
the compiler core stays small, the language grows in itself.

### Compile-time reflection

The macro system has a per-symbol metadata table:

```text
($m-put sym key value...)  ; write
($m-get sym key)           ; read
(%m-dump)                  ; dump entire table as a C comment
```

Declarative forms populate the table automatically. Writing
```lisp
(struct Buffer
  :fields
  ((%ptr float) data)
  (int          cap)
  (int          head))
```
not only emits a `typedef struct {...}` but also calls
```text
($m-put 'Buffer :kind 'struct :fields '(((%ptr float) data)
                                        (int cap)
                                        (int head)))
```

Other macros can then read those fields back and generate
code from them.

### `auto-print`: a derived printer from `:fields`

From `examples/audio-viz/auto-derive.sexc`. Reads the
`:fields` metadata of a type and emits `Type/print`:

```lisp
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

`$fmt-for-type` and `$cast-for-type` are compile-time
helpers in the same file: they pick a printf specifier for
each field type (`int → %d`, `float → %f`, anything else →
`%p` with a `void*` cast).

Usage:
```lisp
(struct Buffer
  :fields
  (int x)
  (int y)
  ((%ptr float) data))
(auto-print Buffer)
```
generates:
```c
void Buffer_SLASH_print(Buffer *x) {
    printf("Buffer {\n");
    printf("  x = %d\n",    x->x);
    printf("  y = %d\n",    x->y);
    printf("  data = %p\n", (void *)x->data);
    printf("}\n");
}
```

Add a field — the printer picks it up next compile. The
equivalent C is either hand-written per type, hand-written
per field, or X-macros.

### `%m-dump`: see what compilation actually stored

Place `(%m-dump)` at the end of a file. The compiler emits a
sorted C comment listing every symbol the metadata table
knows about, with kind, type, and any other recorded keys —
useful for debugging macro output. There is also a CLI form:

```bash
sexc m-dump [--json] file.sexc
```

## Quick run

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
- `$(PREFIX)/share/sexc/docs/` — markdown for every symbol

`SEXC_STDLIB_DIR` overrides the stdlib lookup path.
`--quiet` / `-q` or `SEXC_QUIET=1` silences the per-stage
timing log on stderr.

## Diagnostics

Errors carry `file:line:col` and a caret pointing at the exact
offending form (deep through nested macros). When the form has
known documentation, a `Signature/Doc/Example` hint follows.
A whole file is compiled before reporting, so **all** errors
surface in one run, not one at a time.

Generated C carries `#line` directives, so errors from the C
compiler itself (type mismatches, unknown types) also map back
to the `.sexc` source line — not the temporary `.c`. Disable
with `--no-line`.

`sexc check <file>` runs the full pipeline, discards the C, and
just reports diagnostics (exit non-zero on error, silent on
success) — handy for editors and CI.

## Compiler pipeline

1. **Reader** (`src/reader.ml`) — text → `Raw.t`. S-expressions
   and reader sugar (`'x`, quasiquote / unquote).
2. **Macro phase** (`src/macro.ml`) — `%defmacro`, `%eval` /
   `%evals`, the `$...` compile-time evaluator, metadata
   table mutation.
3. **Frontend** (`src/frontend.ml`) — `Raw.t` → typed AST
   (top-level / stmt / expr / decl / type).
4. **Codegen** (`src/codegen_c.ml`) — AST → C, with mangling
   for identifiers C can't accept.

Orchestrated by `src/compiler.ml` (prelude, `%import` graph,
`%top-level-splice`). Side artifacts: `src/cache/` (on-disk
symbol index for `show-doc` / `complete` / `xref`),
`src/docs.ml` (`%doc` + markdown generation).

## Extending

| Want to add                                              | Where                                                                 |
|----------------------------------------------------------|-----------------------------------------------------------------------|
| Surface macro (`when`, `dotimes`, a DSL)                 | `std/c-interop.sexc` or `std/meta.sexc`                               |
| Compile-time function (list/tree work)                   | `$defun` in `std/meta.sexc`                                           |
| `$`-primitive needing OCaml state or exceptions          | `src/macro.ml`, case in `eval_expr`                                   |
| `%`-intrinsic (expr/stmt)                                | `src/frontend.ml` (parse) + `src/codegen_c.ml` (emit)                 |
| New top-level form                                       | variant in `type top`, case in `parse_top`, case in `emit_top`        |
| Reader sugar                                             | `src/reader.ml`                                                       |
| New compiler stage                                       | `src/compiler.ml`, between macro / frontend / codegen                 |

The OCaml core stays small on purpose. Anything expressible
via primitives (`$car`/`$cdr`/`$cons`/`$if`/`$let` + arithmetic)
goes in as `$defun` in sexc. OCaml edits are reserved for
side effects: metadata mutation, exceptions, IO, or new
`%`-forms needing a frontend/codegen case.

Full conventions reference: `AGENTS.md`.

## Developer tools

```bash
sexc show-doc defn                # one symbol's doc
sexc dump-stdlib-docs ./docs      # markdown for all stdlib
sexc complete --json (set) file   # completion with imports/std/module
sexc xref --json Vec2 file        # find definitions of a symbol
sexc m-dump file.sexc             # dump the metadata table
```

`sexc.el` is an Emacs major-mode: font-lock, indent rules,
eldoc backed by `show-doc`, completion-at-point, and Flymake
diagnostics driven by the compiler (on edit and on save).

## Tests

```bash
make test                        # whole suite, parallel (JOBS=nproc)
JOBS=8 make test                 # cap concurrency
FILTER=struct make test          # subset by substring
make test-update                 # regenerate expected blocks
```

- `tests/cases/*.sexc-test` — golden snapshots. Source and
  expected in one file, split by `;==EXPECTED==`.
- `tests/examples/standalone.list` — examples that build
  end-to-end via gcc.

## Further reading

- `examples/` — runnable code, including `audio-viz`
  (`auto-print` lives there).
- `AGENTS.md` — pipeline, intrinsics, evaluator, metadata
  schema.
- `std/c-interop.sexc`, `std/meta.sexc` — the surface DSL is
  almost entirely defined in these two files.
- `std/ocaml-api.sexc` — reference for OCaml-only symbols
  (`%...`, `$...`, `$defun`s).

---

<a id="russian"></a>

## RU

S-выражения на входе, C на выходе. Никакого runtime, никакого
GC, никаких скрытых аллокаций — таргет обычный C и таким
остаётся. Большая часть того, что выглядит как синтаксис —
макрос в `std/`; OCaml-ядро делает только
reader → macro → frontend → codegen.

### Типы читаются слева направо

В C декларации читаются изнутри-наружу — конструкторы типа
связываются «не в ту сторону», и за пределами одного указателя
всё парсится в голове.

```c
int (*sort_cmp)(const void *, const void *);
void (*sig_handlers[16])(int);
char *(*strdup_fn)(const char *);
```
```lisp
(decl (%ptr (%fn int ((%ptr (%const void)) (%ptr (%const void))))) sort_cmp)
(decl (%array (%ptr (%fn void (int))) 16)                          sig_handlers)
(decl (%ptr (%fn (%ptr char) ((%ptr (%const char)))))              strdup_fn)
```

Все конструкторы (`%ptr`, `%array`, `%fn`, `%const`,
`%volatile`, `%restrict`) — префиксные, тип читается в одном
направлении без spiral rule.

### Struct + методы + конструктор с именованными полями

```c
typedef struct { float x, y; } Vec2;

Vec2 Vec2_add(Vec2 a, Vec2 b) {
    return (Vec2){ .x = a.x + b.x, .y = a.y + b.y };
}

int main(void) {
    Vec2 a = { .x = 1.0f, .y = 2.0f };
    Vec2 b = { .x = 3.0f, .y = 4.0f };
    Vec2 c = Vec2_add(a, b);
    printf("(%f, %f)\n", c.x, c.y);
}
```
```lisp
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

Методы внутри `struct` неймспейсятся в `Type/method` на
codegen — `MathOps/add`, `Vec2/add`. `Type#` — конструктор
с именованными полями; пропущенные поля zero-init.

### typedef, enum и derive по метадате

`typedef` и `enum` симметричны `struct`: эмитят C-тип **и** пишут
faithful-метадату. `enum` параллелен `struct` — секции `:variants`
+ опц. `:methods`:

```lisp
(typedef (%ptr char) String)

(enum Dir
  :variants
  North (East 5) South West       ; атом = авто-нумерация, (имя выраж) = явно
  :methods
  (defn (%ptr char) describe ((Dir d)) (return "...")))   ; → Dir/describe
```

Раз метадата faithful, макросы **рефлексируют тип** и генерят по нему
код — без магии компилятора, чистый stdlib. Флагман — `derive/prints`:
кладёшь в `:methods` структуры и получаешь принтер-по-значению и
принтер-по-указателю бесплатно.

```lisp
(struct Vec3
  :fields
  (float x) (float y) (float z)
  :methods
  (derive/prints))      ; ← генерит Vec3/print и Vec3/print*
```
раскрывается (читая записанные `:fields` у `Vec3`) в:
```c
void Vec3_print(Vec3 self) {
    printf("Vec3 {\n");
    printf("  x = %f\n", self.x);
    printf("  y = %f\n", self.y);
    printf("  z = %f\n", self.z);
    printf("}\n");
}
void Vec3_print_ptr(Vec3 *self) { /* то же, через self->x ... */ }
```
Добавил поле в `Vec3` — оба принтера подхватят его сами. Кирпичики
доступны и напрямую:

```lisp
(print-as Vec3 v)     ; значение:  v.x ...
(print-as* Vec3 p)    ; указатель: p->x ...
(print-as v)          ; вывести тип из метадаты объявления v
(eq-as Vec3 a b)      ; выражение: a.x == b.x && a.y == b.y && a.z == b.z
```

`print-as` подбирает printf-спецификатор по типу поля (по `man 3 printf`),
рекурсится во вложенные struct, указатели печатает как `%p`. Это ~180 строк
SexC в `std/derive.sexc`, читающих ту же таблицу `$m-get … :fields`, что пишет
`struct` — весь механизм «derive» живёт в языке, а не в компиляторе.

### Threading вместо вложенных вызовов

```c
length(strdup(trim(to_upper(input))));
```
```lisp
(|> input to_upper trim strdup length)
```

Три threading-макроса по позиции вставки:
- `|>` — первый аргумент (`(|> x (f a))` → `(f x a)`)
- `||>` — последний (`(||> x (f a))` → `(f a x)`)
- `|as>` — подстановка по имени (`(|as> x it (f 1 it))`)

### Multi-binding `decl` и `set`

```c
int x = 1, y = 2, z = 3;
struct point p;
p.x = 0; p.y = 0; p.z = 0;
```
```lisp
(decl (int x) 1 (int y) 2 (int z) 3)
(set (. p x) 0 (. p y) 0 (. p z) 0)
```

### Multi-branch без if/else цепочек

```c
int sign;
if (x > 0)        sign = 1;
else if (x < 0)   sign = -1;
else              sign = 0;
```
```lisp
(decl (int sign)
  (cond ((> x 0)  1)
        ((< x 0) -1)
        (else    0)))
```

`when` / `unless` для single-branch. `dotimes`, `for-range`,
`incf` / `decf` — на типовые формы цикла.

### Модули и import

```lisp
; ring-buffer.sexc
(%module ring)
(struct Buffer :fields (int cap) (int head))
(defn void init (((%ptr Buffer) b) (int c)) ...)
```
```lisp
; main.sexc
(%import "./ring-buffer" :as r)
(decl (r/Buffer buf) (zero-init))   ; ring/Buffer + alias
(r/Buffer/init (%addr buf) 1024)
```

Все top-level символы модуля неймспейсятся в
`module-name/...`. `:as` добавляет алиас. Циклы детектятся
и репортятся.

### Условная компиляция

Для условий, которые может разрешить только C-компилятор —
платформенные и компиляторные макросы вроде `_WIN32`,
`__linux__`, `__APPLE__`, `__GNUC__` — есть `!`-семейство,
эмитящее реальные `#if`/`#elif`/`#else`/`#endif`. Условие —
сырая строка, вставляемая в директиву as-is:

```lisp
(when! "defined(__GNUC__)"
  (defn int has_gnuc () (return 1)))

(cond!
  ("defined(__ANDROID__)" (defn (%ptr char) os () (return "android")))   ; до linux!
  ("defined(__linux__)"   (defn (%ptr char) os () (return "linux")))
  ("defined(_WIN32)"      (defn (%ptr char) os () (return "windows")))
  (else                   (defn (%ptr char) os () (return "unknown"))))
```
```c
#if defined(__ANDROID__)
char *os(void) { return "android"; }
#elif defined(__linux__)
char *os(void) { return "linux"; }
#elif defined(_WIN32)
char *os(void) { return "windows"; }
#else
char *os(void) { return "unknown"; }
#endif
```

`when!` — одна охраняемая ветка, `if!` — лисп-`if` на 2/3
формы, `cond!` — мультиветка. Порядок веток важен: Android
тоже определяет `__linux__`, Clang тоже определяет `__GNUC__`
— более специфичную ветку ставь первой. Всё это top-level
(выбор функций/структур/define под платформу), собрано
макросами поверх одного примитива `%cpp`. Флаги, известные
на этапе сборки sexc, в этом не нуждаются — для них `%eval`/
`$if` (ниже), и мёртвая ветка вообще не попадает в C.

### Compile-time вычисления: `$defun`, `%eval`, `%evals`

Кроме `%defmacro`, есть маленький Lisp, исполняемый *во время* раскрытия —
`$...` evaluator (call-by-value: `$if`/`$let`/`$for`/`$map`/`$car`/`$cdr`/
`$cons`/арифметика/quasiquote). Два интринсика сплайсят его результат в код:

- **`(%eval EXPR)`** — вычислить `EXPR` в **одну** форму и вставить.
- **`(%evals EXPR)`** — вычислить в **список** и вставить каждый элемент в
  окружающий list-контекст.

```lisp
; $defun — compile-time функция (без рантайм-стоимости)
($defun $square (n) ($* n n))

; %eval: вставить одну вычисленную форму
(define BUF_SIZE (%eval ($square 8)))      ; => #define BUF_SIZE 64

; %evals: сгенерить много форм из данных
(%evals
  ($for (row '((inc 1) (dec -1)))
    `(defn int ,($car row) ((int x))
       (return (+ x ,($car ($cdr row)))))))
; => int inc(int x){ return x + 1; }
;    int dec(int x){ return x + -1; }
```

`%eval` работает в top-level, statement и даже expression-позиции
(`(+ (%eval ...) y)`); `%evals` — для list-контекстов (тело функции,
top level, список аргументов). Бо́льшая часть `std/meta.sexc` — это `$defun`:
ядро компилятора остаётся маленьким, язык растёт в себе.

### Compile-time рефлексия

Macro-система ведёт таблицу метадаты на каждый символ:

```text
($m-put sym key value...)  ; запись
($m-get sym key)           ; чтение
(%m-dump)                  ; дамп всей таблицы как C-комментарий
```

Декларативные формы заполняют таблицу автоматически. Когда
вы пишете
```lisp
(struct Buffer
  :fields
  ((%ptr float) data)
  (int          cap)
  (int          head))
```
кроме `typedef struct {...}` происходит ещё и
```text
($m-put 'Buffer :kind 'struct :fields '(((%ptr float) data)
                                        (int cap)
                                        (int head)))
```

Другие макросы могут эти поля прочитать и сгенерить по ним
код.

### `auto-print`: принтер, выведенный из `:fields`

Из `examples/audio-viz/auto-derive.sexc`. Читает `:fields`
типа и эмитит `Type/print`:

```lisp
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

`$fmt-for-type` и `$cast-for-type` — compile-time helper'ы
в том же файле: мапят тип поля в printf-спецификатор
(`int → %d`, `float → %f`, всё остальное → `%p` с кастом в
`void*`).

Использование:
```lisp
(struct Buffer
  :fields
  (int x)
  (int y)
  ((%ptr float) data))
(auto-print Buffer)
```
генерирует:
```c
void Buffer_SLASH_print(Buffer *x) {
    printf("Buffer {\n");
    printf("  x = %d\n",    x->x);
    printf("  y = %d\n",    x->y);
    printf("  data = %p\n", (void *)x->data);
    printf("}\n");
}
```

Добавили поле — принтер подхватит на следующей компиляции.
Эквивалент в C — либо рукописный принтер на каждый тип,
либо рукописная строка на каждое поле, либо X-macros.

### `%m-dump`: что компиляция реально сохранила

`(%m-dump)` в конце файла эмитит отсортированный C-комментарий
со всеми символами в таблице — kind, type, остальные ключи.
Удобно дебажить выход макросов. Есть CLI-форма:

```bash
sexc m-dump [--json] file.sexc
```

## Быстрый запуск

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
- `$(PREFIX)/share/sexc/docs/` — markdown по всем символам

`SEXC_STDLIB_DIR` переопределяет путь к stdlib.
`--quiet` / `-q` или `SEXC_QUIET=1` глушит per-stage тайминги
на stderr.

## Диагностика

Ошибки несут `file:line:col` и caret точно на проблемную форму
(вглубь через вложенные макросы). Если у формы есть документация,
снизу идёт hint `Signature/Doc/Example`. Файл компилируется
целиком перед отчётом, поэтому **все** ошибки видны за один
прогон, а не по одной.

Генерируемый C несёт `#line`-директивы, так что ошибки самого
C-компилятора (несовпадение типов, unknown type) тоже маппятся
на строку `.sexc`, а не на временный `.c`. Отключается `--no-line`.

`sexc check <file>` гоняет полный pipeline, отбрасывает C и просто
печатает диагностику (exit non-zero при ошибке, тихо при успехе) —
удобно для редакторов и CI.

## Пайплайн компилятора

1. **Reader** (`src/reader.ml`) — текст → `Raw.t`. S-выражения
   и reader-sugar (`'x`, quasi/unquote).
2. **Macro phase** (`src/macro.ml`) — `%defmacro`, `%eval` /
   `%evals`, `$...` compile-time evaluator, мутация таблицы
   метадаты.
3. **Frontend** (`src/frontend.ml`) — `Raw.t` → типизированный
   AST (top-level / stmt / expr / decl / type).
4. **Codegen** (`src/codegen_c.ml`) — AST → C, с mangling
   недопустимых для C идентификаторов.

Оркестрация — `src/compiler.ml` (prelude, граф `%import`'ов,
`%top-level-splice`). Сопутствующее: `src/cache/` (disk-cache
символьного индекса для `show-doc` / `complete` / `xref`),
`src/docs.ml` (`%doc` + генерация markdown).

## Расширение

| Хочется добавить                                       | Куда                                                                  |
|--------------------------------------------------------|-----------------------------------------------------------------------|
| Surface-макрос (`when`, `dotimes`, DSL)                | `std/c-interop.sexc` или `std/meta.sexc`                              |
| Compile-time функция (работа со списками/деревьями)    | `$defun` в `std/meta.sexc`                                            |
| `$`-примитив, требующий OCaml-стейта/исключений        | `src/macro.ml`, кейс в `eval_expr`                                    |
| `%`-intrinsic (expr/stmt)                              | `src/frontend.ml` (parse) + `src/codegen_c.ml` (emit)                 |
| Новая top-level форма                                  | вариант в `type top`, кейс в `parse_top`, кейс в `emit_top`           |
| Reader-sugar                                           | `src/reader.ml`                                                       |
| Новая фаза компилятора                                 | `src/compiler.ml`, между macro / frontend / codegen                   |

OCaml-ядро намеренно маленькое. Всё, что выражается через
примитивы (`$car`/`$cdr`/`$cons`/`$if`/`$let` + арифметика),
пишется как `$defun` в sexc. OCaml-правка нужна под
сайд-эффекты: мутация метадаты, исключения, IO или новые
`%`-формы, требующие frontend/codegen-кейса.

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
через `show-doc`, completion-at-point и Flymake-диагностика от
компилятора (на лету и при сохранении).

## Тесты

```bash
make test                        # вся сюита, параллельно (JOBS=nproc)
JOBS=8 make test                 # ограничить параллелизм
FILTER=struct make test          # подмножество по подстроке
make test-update                 # перегенерировать expected
```

- `tests/cases/*.sexc-test` — golden snapshot. Source и
  expected в одном файле, разделённые `;==EXPECTED==`.
- `tests/examples/standalone.list` — examples,
  компилирующиеся end-to-end через gcc.

## Куда смотреть дальше

- `examples/` — рабочий код, в том числе `audio-viz` (там
  живёт `auto-print`).
- `AGENTS.md` — пайплайн, intrinsic'и, evaluator, схема
  метадаты.
- `std/c-interop.sexc`, `std/meta.sexc` — surface DSL почти
  целиком описан здесь.
- `std/ocaml-api.sexc` — справочник по OCaml-only символам
  (`%...`, `$...`, `$defun`-ы).
