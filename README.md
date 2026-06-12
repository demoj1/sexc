# SexC

[![CI](https://github.com/demoj1/sexc/actions/workflows/ci.yml/badge.svg)](https://github.com/demoj1/sexc/actions/workflows/ci.yml)

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

### A taste

One small program: a struct whose printer is **derived** from its field
metadata, a **sum type** with methods and exhaustive `match`, and a function
**generated at compile time** by reflecting over the metadata table.

```lisp
(struct Point
  :fields (float x) (float y)
  :methods (derive/prints))                   ; Point/print, generated from :fields

(defsum Shape                                 ; a tagged union, with methods
  :variants
  (Circle (float r))
  (Rect   (float w) (float h))
  :methods
  (defn float area ((Shape self))             ; miss a variant -> compile error
    (match self
      (Shape/Circle (r)   (return (* 3.14159f r r)))
      (Shape/Rect   (w h) (return (* w h))))))

; reflection: read the variant metadata *now*, emit one match arm per variant
(%eval
  `(defn (:* :const char) shape-name ((Shape s))
     (match s
       ,@($for (v ($m-get 'Shape :variants))
           `(,($symcat 'Shape "/" ($car v)) () (return ,($str ($car v))))))))

(defn int main ()
  (decl (Shape s) (Shape/Circle# 3.0f))       ; `#` constructs, like `new`
  (printf "%s has area %.2f\n" (shape-name s) (Shape/area s))
  (return 0))
```

It all compiles to plain C: `Shape` is a `struct { enum tag; union {…} u; }`,
`match` is a `switch`, and `shape-name` is an ordinary function the macro layer
wrote for you. No runtime, no RTTI. The fuller version — heap allocation with
`adecl`, scoped cleanup with `defer`, and threading with `|>` — is in
[`examples/shapes.sexc`](examples/shapes.sexc); the rest of this page takes the
pieces one at a time.

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

### Sum types — `defsum` and `match`

A tagged union with exhaustive pattern matching — a stdlib macro, no compiler
support. `:variants` lists the constructors (each with its own payload);
`:methods` attaches functions, exactly like `struct`:

```lisp
(defsum Shape
  :variants
  (Circle (float r))
  (Rect   (float w) (float h))
  (Dot)                                    ; a variant with no payload
  :methods
  (defn float area ((Shape self))
    (match self
      (Shape/Circle (r)   (return (* 3.14159f r r)))
      (Shape/Rect   (w h) (return (* w h)))
      (Shape/Dot    ()    (return 0.0f)))))
```
```c
typedef enum { Shape_Circle, Shape_Rect, Shape_Dot } Shape_tag;
typedef struct { float r; }       Shape_Circle_p;
typedef struct { float w, h; }    Shape_Rect_p;
typedef struct {
  Shape_tag tag;
  union { Shape_Circle_p Circle; Shape_Rect_p Rect; } u;
} Shape;
/* + float Shape_area(Shape), int Shape_Circle?(Shape), … */
```

- **Construct** with the `#` convention: `(Shape/Circle# 3.0)` →
  `(Shape){ .tag = Shape_Circle, .u.Circle = {3.0} }`.
- **`match`** compiles to a `switch` on the tag; fields bind positionally
  (`_` ignores one). It is **exhaustive** — leave a variant out and compilation
  stops; a trailing `...` opts into a partial match.
- Each variant also gets a predicate `Shape/Circle?`.

(`/` is mangled to a legal C identifier in the real output; shown plain above.)

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
(decl (int sign) 0)
(cond ((> x 0) (set sign 1))
      ((< x 0) (set sign -1))
      (else    (set sign 0)))
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

### Dynamic binding and scoped cleanup

`with` rebinds a variable for the dynamic extent of its body and
restores it on **any** exit, `return` included — Clojure-`binding` /
Odin-`context` style dynamic scope. The variable is declared once,
`_Thread_local`, at the file head (so callees down the stack see it),
so you never write a top-level declaration. A bare-atom binding
infers the type from the value via `__typeof__`; a `(Type var)`
binding states it explicitly (needed for self-referential or
local-typed values):

```lisp
(defn void say (((%ptr (%const char)) m))   ; reads *out* — never passed in
  (fprintf *out* "%s\n" m))

(defn int main ()
  (with *out* stdout                ; type inferred via __typeof__: FILE*
    (say "hello"))                  ; *out* reverts after the block
  (return 0))
```
```c
_Thread_local __typeof__(stdout) *out*;   /* hoisted to the file head */
/* ... with body saves/sets/restores *out* around (say ...) ... */
```

`defer1` / `defer*` run a one-argument cleanup at block exit, in LIFO
order, on any exit path — both compile to `__attribute__((cleanup))`
(GCC/Clang):

```lisp
(decl ((%ptr char) buf) (cast (%ptr char) (malloc 64)))
(defer1 free buf)                   ; free(buf) when the block exits
(defer* (free a) (fclose f))        ; or a batch, run b…a in reverse
```

Together they give a temporary allocator scoped to a region: bind a
fresh arena as the ambient `*arena*`, `defer*` its teardown, and let
callees allocate from it without taking it as a parameter (see
`examples/with-alloca.sexc`).

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
- `tests/examples/standalone.list` — examples built end-to-end
  via **gcc and clang** (clang when installed). If an example has
  an `examples/X.expected` sidecar, it is also run and its stdout
  diffed (`UPDATE=1` regenerates the sidecar).

## Further reading

- `examples/` — runnable code, including `audio-viz`
  (`auto-print` lives there).
- `AGENTS.md` — pipeline, intrinsics, evaluator, metadata
  schema.
- `std/c-interop.sexc`, `std/meta.sexc` — the surface DSL is
  almost entirely defined in these two files.
- `std/ocaml-api.sexc` — reference for OCaml-only symbols
  (`%...`, `$...`, `$defun`s).

## License

MIT — see [LICENSE](LICENSE). The stdlib (`std/*.sexc`) is
covered by the same permissive terms, so code you compile with
SexC carries no licensing obligations from the toolchain.

---

<a id="russian"></a>

## RU

S-выражения на входе, C на выходе. Никакого runtime, никакого
GC, никаких скрытых аллокаций — таргет обычный C и таким
остаётся. Большая часть того, что выглядит как синтаксис —
макрос в `std/`; OCaml-ядро делает только
reader → macro → frontend → codegen.

### Знакомство

Маленькая программа: struct, чей принтер **выведен** из метадаты полей,
**sum-тип** с методами и exhaustive `match`, и функция, **сгенерированная в
compile-time** рефлексией по таблице метадаты.

```lisp
(struct Point
  :fields (float x) (float y)
  :methods (derive/prints))                   ; Point/print, выведен из :fields

(defsum Shape                                 ; tagged union, с методами
  :variants
  (Circle (float r))
  (Rect   (float w) (float h))
  :methods
  (defn float area ((Shape self))             ; пропусти вариант -> ошибка компиляции
    (match self
      (Shape/Circle (r)   (return (* 3.14159f r r)))
      (Shape/Rect   (w h) (return (* w h))))))

; рефлексия: читаем метадату вариантов *сейчас*, эмитим по arm'у на вариант
(%eval
  `(defn (:* :const char) shape-name ((Shape s))
     (match s
       ,@($for (v ($m-get 'Shape :variants))
           `(,($symcat 'Shape "/" ($car v)) () (return ,($str ($car v))))))))

(defn int main ()
  (decl (Shape s) (Shape/Circle# 3.0f))       ; `#` конструирует, как `new`
  (printf "%s has area %.2f\n" (shape-name s) (Shape/area s))
  (return 0))
```

Всё компилится в обычный C: `Shape` — это `struct { enum tag; union {…} u; }`,
`match` — `switch`, а `shape-name` — обычная функция, которую написал за тебя
макрослой. Без runtime, без RTTI. Расширенная версия — heap-аллокация через
`adecl`, scoped-cleanup через `defer`, threading через `|>` — в
[`examples/shapes.sexc`](examples/shapes.sexc); дальше страница разбирает
кусочки по одному.

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

### Sum-типы — `defsum` и `match`

Tagged union с exhaustive сопоставлением — stdlib-макрос, без поддержки в
компиляторе. `:variants` перечисляет конструкторы (каждый со своей нагрузкой);
`:methods` навешивает функции — ровно как у `struct`:

```lisp
(defsum Shape
  :variants
  (Circle (float r))
  (Rect   (float w) (float h))
  (Dot)                                    ; вариант без полей
  :methods
  (defn float area ((Shape self))
    (match self
      (Shape/Circle (r)   (return (* 3.14159f r r)))
      (Shape/Rect   (w h) (return (* w h)))
      (Shape/Dot    ()    (return 0.0f)))))
```
```c
typedef enum { Shape_Circle, Shape_Rect, Shape_Dot } Shape_tag;
typedef struct { float r; }       Shape_Circle_p;
typedef struct { float w, h; }    Shape_Rect_p;
typedef struct {
  Shape_tag tag;
  union { Shape_Circle_p Circle; Shape_Rect_p Rect; } u;
} Shape;
/* + float Shape_area(Shape), int Shape_Circle?(Shape), … */
```

- **Конструктор** через конвенцию `#`: `(Shape/Circle# 3.0)` →
  `(Shape){ .tag = Shape_Circle, .u.Circle = {3.0} }`.
- **`match`** компилится в `switch` по тегу; поля биндятся позиционно
  (`_` игнорит поле). Он **exhaustive** — пропусти вариант, и компиляция
  падает; хвостовой `...` включает частичный match.
- На каждый вариант — предикат `Shape/Circle?`.

(`/` мэнглится в легальный C-идентификатор; выше показан как есть.)

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
(decl (int sign) 0)
(cond ((> x 0) (set sign 1))
      ((< x 0) (set sign -1))
      (else    (set sign 0)))
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

### Динамический биндинг и scoped-cleanup

`with` переопределяет переменную на время своего тела и
восстанавливает её на **любом** выходе, включая `return` —
динамический скоуп в стиле Clojure-`binding` / Odin-`context`.
Переменная объявляется один раз, `_Thread_local`, в начале файла
(чтобы её видели callee вниз по стеку) — top-level-декларацию руками
писать не нужно. Атом-биндинг выводит тип из значения через
`__typeof__`; биндинг `(Type var)` задаёт тип явно (нужно для
self-referential или локально-типизированных значений):

```lisp
(defn void say (((%ptr (%const char)) m))   ; читает *out* — не передаётся параметром
  (fprintf *out* "%s\n" m))

(defn int main ()
  (with *out* stdout                ; тип выведен через __typeof__: FILE*
    (say "hello"))                  ; *out* откатывается после блока
  (return 0))
```
```c
_Thread_local __typeof__(stdout) *out*;   /* поднято в начало файла */
/* ... тело with сохраняет/ставит/восстанавливает *out* вокруг (say ...) ... */
```

`defer1` / `defer*` выполняют cleanup одного аргумента на выходе из
блока, в порядке LIFO, на любом пути выхода — оба компилятся в
`__attribute__((cleanup))` (GCC/Clang):

```lisp
(decl ((%ptr char) buf) (cast (%ptr char) (malloc 64)))
(defer1 free buf)                   ; free(buf) при выходе из блока
(defer* (free a) (fclose f))        ; или пачкой, b…a в обратном порядке
```

Вместе это даёт временный аллокатор, ограниченный регионом: ставишь
свежую арену как ambient `*arena*`, `defer*` её разрушение, а callee
аллоцируют из неё, не принимая её параметром (см.
`examples/with-alloca.sexc`).

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
- `tests/examples/standalone.list` — examples, собираемые
  end-to-end через **gcc и clang** (clang — если установлен).
  Если рядом лежит сайдкар `examples/X.expected`, пример ещё и
  запускается, а его stdout сверяется (`UPDATE=1` перегенерит).

## Куда смотреть дальше

- `examples/` — рабочий код, в том числе `audio-viz` (там
  живёт `auto-print`).
- `AGENTS.md` — пайплайн, intrinsic'и, evaluator, схема
  метадаты.
- `std/c-interop.sexc`, `std/meta.sexc` — surface DSL почти
  целиком описан здесь.
- `std/ocaml-api.sexc` — справочник по OCaml-only символам
  (`%...`, `$...`, `$defun`-ы).

## Лицензия

MIT — см. [LICENSE](LICENSE). stdlib (`std/*.sexc`) под теми
же permissive-условиями, поэтому код, скомпилированный SexC,
не несёт никаких лицензионных обязательств от тулчейна.
