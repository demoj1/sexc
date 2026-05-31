# SexC

Lisp-синтаксис → C, через мощную макросистему. Компилятор написан на OCaml.

## Зачем

Это не очередной транспайлер S-выражений в C. SexC даёт:

- **C без потерь** — таргет настоящий C, никакого runtime, никакого GC. Всё что можно сделать в C, можно сделать здесь.
- **Lisp-макросы поверх** — `%defmacro` с `quasiquote`/`gensym`, рекурсивные макросы, плюс отдельный compile-time evaluator со своими функциями (`$defun`).
- **Compile-time рефлексия** — `$m-put`/`$m-get` позволяют макросам обмениваться метадатой о символах (полях структур, типах переменных, сигнатурах функций) и генерировать код на основе этой информации.
- **Маленькое OCaml-ядро** — большая часть стандартной библиотеки (контроль потока, операторы, итерация, функции работы со списками compile-time) написана на самом SexC, а не зашита в компилятор.

Хорошо подходит, если хочется писать system-level код с метапрограммированием уровня Lisp, но без жертв в производительности и совместимости с C-экосистемой.

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

Запуск:

```bash
./sexc examples/hello.sexc -C gcc % -o hello && ./hello
```

Флаг `-C` принимает команду компиляции, где `%` — placeholder для сгенерированного `.c` файла.

## Установка

```bash
make build      # собрать ./sexc
make test       # прогнать регрессионные тесты (параллельно)
make install    # установить в /usr/local (PREFIX переопределяемый)
```

`make install` ставит бинарник, stdlib и docs:
- `$(PREFIX)/bin/sexc`
- `$(PREFIX)/include/sexc/std/` — prelude (`core.sexc`, `c-interop.sexc`, `meta.sexc`, `ocaml-api.sexc`)
- `$(PREFIX)/share/sexc/docs/` — markdown по всем символам

Путь к stdlib можно переопределить через `SEXC_STDLIB_DIR`.

По умолчанию компилятор пишет на stderr ход стадий пайплайна с таймингами (parse, macro expand, codegen, gcc, total) — длинные сборки не выглядят зависшими. Отключение — флаг `--quiet`/`-q` или `SEXC_QUIET=1` (например для редакторских интеграций).

## Use cases где SexC реально окупается

- **Кодогенерация на основе структур.** Опиши один раз `(struct Foo :fields ...)`, и серилизатор/принтер/визитор/equality для неё генерится макросом который читает `($m-get 'Foo :fields)` — никаких рукописных stub'ов.
- **DSL поверх C.** Описать сетевой протокол или конфиг-формат как S-выражения, развернуть в строго типизированный C код без runtime парсинга.
- **Метапрограммирование без C++ шаблонов.** Generic-функции через диспатч по сохранённой compile-time метадате, без `_Generic` и без шаблонов.
- **Бутстрап-проекты, embedded.** Никакого GC, никаких хидден аллокаций. Что сгенерили — то и работает.

## Что есть из коробки

- `defn`, `decl`/`adecl`, `struct`/`union`, операторы, контроль потока (`if`/`cond`/`while`/`for`/`return`/`set`), threading-макросы (`|>`, `||>`, `|as>`), доступ к полям (`.`, `->`).
- Препроцессор: `include`, `define`, `%ifdef`.
- Модульная система: `%module`, `%import` с предупреждением о циклических зависимостях.
- Документация: `%doc` для своих макросов/функций, `sexc show-doc <name>` для быстрой справки.
- Compile-time функции через `$defun` для собственных расширений макросистемы.
- Подсказка с раскладом метадаты по символам: `(%m-dump)` в конце файла вставляет в выход красивый C-комментарий со всем что компилятор знает о ваших именах.

## Архитектура компилятора

Пайплайн:

1. **Reader** (`src/reader.ml`) — текст → `Raw.t` (`Atom | Str | List`). Парсит S-выражения и reader-sugar (`'x` → `(quote x)`, quasiquote/unquote).
2. **Macro phase** (`src/macro.ml`) — раскрывает `%defmacro`, обрабатывает `%eval`/`%evals`, выполняет compile-time evaluator (`$...`-формы), накапливает символьную метадату. Выход снова `Raw.t`, но без макросов.
3. **Frontend** (`src/frontend.ml`) — `Raw.t` → типизированный AST (top-level / stmt / expr / decl / type).
4. **Codegen** (`src/codegen_c.ml`) — AST → строки C, с mangling недопустимых для C идентификаторов.

Orchestration в `src/compiler.ml`: загрузка prelude и `%import`-графа, склейка фаз, обработка `%top-level-splice`.

Сопутствующее:
- `src/cache/` — пассивный disk-cache индекса символов для `show-doc`/`complete`/`xref`.
- `src/docs.ml` — `%doc` metadata, генерация markdown.

## Как расширять язык

| Хочется добавить | Куда |
|---|---|
| Surface-макрос (`when`, `dotimes`, ваш DSL) | `std/c-interop.sexc` (C-обёртки) или `std/meta.sexc` (универсальные helper'ы) |
| Compile-time функция (работа со списками/деревьями) | `$defun` в `std/meta.sexc` — пишется на самом SexC, не трогая OCaml |
| `$`-примитив, требующий OCaml-стейта/исключений | `src/macro.ml`, кейс в `eval_expr` |
| `%`-intrinsic (expr/stmt) | `src/frontend.ml` (parse) + `src/codegen_c.ml` (emit) |
| Новая top-level форма | вариант в `type top` во `frontend.ml`, кейс в `parse_top`, кейс в `emit_top` |
| Reader-sugar | `src/reader.ml` |
| Новая фаза компилятора | `src/compiler.ml`, вставить между macro/frontend/codegen |

**Принцип:** держим OCaml-ядро маленьким. Если что-то выражается через примитивы (`$car`/`$cdr`/`$cons`/`$if`/`$let`/арифметика) — пишем как `$defun` в sexc. OCaml-правка нужна только когда не обойтись без сайд-эффектов: мутация compile-time стейта (например `$m-put`, `$gensym`), исключения (`$error`/`$assert`), IO, или подгонка под frontend/codegen (новые `%`-формы).

Детальная сводка соглашений (что где, какие правила раскрытия, naming conventions) — в `AGENTS.md`.

## Инструменты разработчика

```bash
sexc show-doc defn                # документация одного символа
sexc dump-stdlib-docs ./docs      # markdown по всем символам stdlib
sexc complete --json (set) file   # автокомплит с учётом imports/std/module
sexc xref --json Vec2 file        # найти определения символа
```

В репозитории есть `sexc.el` — Emacs major-mode с font-lock, indent rules, eldoc через `show-doc` и completion-at-point.

## Тесты

Регрессионная сюита написана на bash (не зависит от языка реализации компилятора).

```bash
make test                        # прогон всей сюиты (параллельно, JOBS=nproc)
JOBS=8 make test                 # ограничить параллелизм
FILTER=struct make test          # запустить только подмножество по подстроке
make test-update                 # перегенерировать expected-блоки (ревью diff!)
```

- `tests/cases/*.sexc-test` — golden snapshot тесты. **Одиночный файл** содержит и source, и expected, разделённые маркером `;==EXPECTED==` — удобно ревьюить в одном месте.
- `tests/examples/standalone.list` — список example'ов, которые компилируются end-to-end через gcc.

Подробности — в `AGENTS.md`, раздел *Регрессионные тесты*.

## Куда смотреть дальше

- `examples/` — рабочие примеры, в том числе мини-проект из нескольких файлов и пример работы с raylib.
- `AGENTS.md` — техническая сводка: устройство компилятора, как добавлять интринсики/макросы/функции, как устроены compile-time evaluator и metadata.
- `std/c-interop.sexc`, `std/meta.sexc` — читать как референс синтаксиса; почти весь surface-DSL описан в этих двух файлах.
- `std/ocaml-api.sexc` — справочник по OCaml-only символам (`%...`, `$...`, `$defun`-функции).
