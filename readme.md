# Спецификация языка SexC (S-expression C)
**Версия:** 1.0  
**Описание:** Формальное отображение синтаксических конструкций стандарта ISO C в S-выражения (S-expressions) для создания чистого фронтенда без синтаксического шума.

---

## 1. Литералы и Базовые Атомы

Все базовые типы данных Си транслируются один в один без изменений.


| Конструкция в Си | S-expression  | Комментарий / Особенности                          |
| :---             | :---          | :---                                               |
| `10`, `0x1A`, `077`    | `10`, `0x1A`, `077` | Десятичные, шестнадцатеричные и восьмеричные числа |
| `3.14f`, `1e-5`      | `3.14f`, `1e-5`   | Числа с плавающей точкой (float, double)           |
| `"hello\n"`        | `"hello\n"`     | Строковые литералы (экранирование сохраняется)     |
| `'a'`, `'\n'`        | `'a'`, `'\n'`     | Символьные литералы                                |
| `NULL`             | `NULL`          | Идентификатор нулевого указателя                   |

---

## 2. Операторы и Выражения (Expressions)

В SexC используется **префиксная нотация**. Скобки полностью устраняют двусмысленность и вопросы приоритетов операторов (Precedence).

Операторы оформляются как встроенные примитивы с префиксом `%`. Это позволяет однозначно отличать операторные формы языка от пользовательских символов.

### 2.1. Арифметические и Битовые операторы
Разрешена n-арная форма для операторов `+`, `-`, `*`, `/`, `&`, `|`, `^` (разворачиваются слева направо).


| Конструкция в Си | S-expression |
| :---             | :---         |
| `a + b + c`      | `(%+ a b c)` |
| `a - b - c`      | `(%- a b c)` |
| `a * b`          | `(%* a b)`   |
| `a / b`          | `(%/ a b)`   |
| `a % b`          | `(%% a b)`   |
| `~a`             | `(%~ a)`     |
| `a & b`          | `(%& a b)`   |
| `a \| b`        | `(%\| a b)` |
| `a ^ b`          | `(%^ a b)`   |
| `a << b`         | `(%<< a b)`  |
| `a >> b`         | `(%>> a b)`  |

### 2.2. Логические операторы и Сравнения
Операторы сравнения и логики возвращают в Си `int` (0 или 1). В SexC они также поддерживают цепочки (n-арность).


| Конструкция в Си | S-expression   |
| :---             | :---           |
| `a == b`         | `(%== a b)`    |
| `a != b`         | `(%!= a b)`    |
| `a < b`          | `(%< a b)`     |
| `a <= b`         | `(%<= a b)`    |
| `a > b`          | `(%> a b)`     |
| `a >= b`         | `(%>= a b)`    |
| `!a`             | `(%! a)`       |
| `a && b && c`    | `(%&& a b c)`  |
| `a \|\| b`      | `(%\|\| a b)` |

### 2.3. Унарные операторы, Присваивание и Специфичные конструкции


| Конструкция в Си | S-expression          | Описание                                              |
| :---             | :---                  | :---                                                  |
| `a = b`          | `(%set a b)`          | Присваивание значения                                 |
| `a += b`         | `(%+= a b)`           | Присваивание со сложением (аналогично для `%-=`, `%*=`, `%/=`, `%%=`) |
| `x++`            | `(%post-inc x)`       | Постфиксный инкремент                                 |
| `++x`            | `(%pre-inc x)`        | Префиксный инкремент                                  |
| `x--`            | `(%post-dec x)`       | Постфиксный декремент                                 |
| `--x`            | `(%pre-dec x)`        | Префиксный декремент                                  |
| `&x`             | `(%addr x)`           | Взятие адреса переменной                              |
| `*p`             | `(%deref p)`          | Разыменование указателя                               |
| `sizeof(int)`    | `(%sizeof-type int)`  | Размер типа данных                                    |
| `sizeof(x)`      | `(%sizeof-expr x)`    | Размер конкретного выражения / переменной             |
| `(float)x`       | `(%cast float x)`     | Явное приведение типов                                |
| `cond ? a : b`   | `(%ternary cond a b)` | Тернарный условный оператор                           |
| `a, b, c`        | `(%comma a b c)`      | Последовательное выполнение (оператор "запятая")      |

Семантические требования для backend:

- `%&&` и `%||` обязаны сохранять short-circuit поведение C.
- `%set` и compound-assign формы возвращают значение выражения, как в C.
- `%post-inc/%post-dec` возвращают старое значение, `%pre-inc/%pre-dec` - новое.
- `%comma` вычисляет аргументы строго слева направо и возвращает последний.

### 2.4. Канонический `%IR` (Strict Mode)

Нормализованная форма программы SexC - это `%IR`, где все встроенные формы языка начинаются с `%`.

Правила strict mode:

- Пространство имен `%*` зарезервировано под встроенные формы языка.
- Любой неизвестный символ вида `%foo` - ошибка парсинга/валидации.
- Формы без `%` трактуются как пользовательские идентификаторы (функции, переменные, макросы), а не как встроенные конструкции.
- Встроенные операторы, statements, top-level формы и конструкторы типов обязаны использовать `%`-префикс.
- Для каждой встроенной формы проверяется фиксированная арность (например, `%ternary` - ровно 3 аргумента, `%return` - 0 или 1).
- `%if` поддерживает только 2 или 3 аргумента: `(%if cond then)` и `(%if cond then else)`.
- `%for` всегда имеет 4 позиции: `(%for init cond step body)`; пустые части задаются через `(%nop)`.
- `%switch` содержит только `%case` и `%default` внутри своего тела.
- `%sizeof-type` принимает только type-форму; `%sizeof-expr` принимает только expression-форму.
- `%set` и compound-assign формы требуют modifiable lvalue в левой части.
- `%dot` и `%arrow` требуют, чтобы последний аргумент был именем поля (идентификатором).
- `%&&` и `%||` обязаны оставаться ленивыми на всех этапах (macroexpand, normalize, codegen).
- Canonical output pretty-printer в SexC всегда использует `%`-формы.
- Рекомендуемый pipeline: `parse -> macroexpand -> validate(strict) -> normalize -> codegen(C)`.

---

## 3. Доступ к компонентам данных


| Конструкция в Си | S-expression   | Описание                                         |
| :---             | :---           | :---                                             |
| `arr[i]`           | `(%aref arr i)`      | Доступ к элементу массива по индексу             |
| `obj.field`        | `(%dot obj field)`   | Доступ к полю структуры/объединения по значению  |
| `ptr->field`       | `(%arrow ptr field)` | Доступ к полю структуры/объединения по указателю |

---

## 4. Инструкции и Управление потоком (Statements)

Блоки кода (фигурные скобки в Си) формализуются через ключевое слово `%block`.


| Конструкция в Си            | S-expression           |
| :---                        | :---                   |
| `;`                           | `(%nop)`                  |
| `{ stmt1; stmt2; }`           | `(%block stmt1 stmt2)`    |
| `if (c) { s1; }`              | `(%if c s1)`              |
| `if (c) { s1; } else { s2; }` | `(%if c s1 s2)`           |
| `while (c) { s; }`            | `(%while c s)`            |
| `do { s; } while (c);`        | `(%do-while c s)`         |
| `for (i=0; i<10; i++) { s; }` | `(%for init cond step s)` |
| `break;`                      | `(%break)`                |
| `continue;`                   | `(%continue)`             |
| `return expr;`                | `(%return expr)`          |
| `return;`                     | `(%return)`               |
| `goto label;`                 | `(%goto label)`           |
| `label:`                      | `(%label label_name)`     |

### 4.1. Конструкция Switch-Case
Конструкция `switch` преобразуется в плоский список пар (условие - блок действий).

**Си:**
```c
switch (x) {
    case 1: s1; break;
    case 2: s2; break;
    default: sd;
}
```
**SexC:**
```lisp
(%switch x
  (%case 1 s1 (%break))
  (%case 2 s2 (%break))
  (%default sd))
```

---

## 5. Система типов и Декларации (Declarations)

Для устранения хаотичного синтаксиса Си («чтение изнутри наружу») объявления типов в SexC строятся **строго слева направо** с помощью префиксных конструкторов типов: `%ptr`, `%const`, `%volatile`, `%restrict`, `%array`, `%fn`.

### 5.1. Базовые ключевые слова типов
`void`, `char`, `short`, `int`, `long`, `float`, `double`, `signed`, `unsigned`.

### 5.2. Спецификаторы хранения (Storage Classes)
`%extern`, `%static`, `%register`, `%auto`, `%typedef`.

### 5.3. Примеры сложных объявлений


| Конструкция в Си            | S-expression                       | Разбор семантики SexC                            |
| :---                        | :---                               | :---                                             |
| `int x;`                      | `(%decl int x)`                                    | Переменная `x` типа `int`                            |
| `static unsigned long y = 5;` | `(%decl (%static unsigned long) y 5)`              | Статическая переменная с инициализацией              |
| `const int *p;`               | `(%decl (%ptr (%const int)) p)`                    | `p` — это указатель на константный `int`             |
| `int * const p;`              | `(%decl (%const (%ptr int)) p)`                    | `p` — это константный указатель на `int`             |
| `int arr[10];`                | `(%decl (%array int 10) arr)`                      | Массив из 10 элементов типа `int`                    |
| `int mat[3][5];`              | `(%decl (%array (%array int 5) 3) mat)`            | Двумерный массив (массив из 3 массивов по 5 `int`)   |

### 5.4. Указатели на функции
Один из самых сложных синтаксических элементов Си становится линейным и читаемым.

**Си:** `int (*fp)(char, float);`  
**SexC:** `(%decl (%ptr (%fn int (char float))) fp)`  
*(Логика: Объявить переменную `fp`, которая является `%ptr` (указателем) на `%fn` (функцию), возвращающую `int` и принимающую параметры типов `char` и `float`)*.

---

## 6. Глобальные конструкции верхнего уровня (Definitions)

### 6.1. Структуры, Объединения и Перечисления (Struct, Union, Enum)
Определения пользовательских типов описываются через декларации структуры и передаются в `%typedef`.

**Си:**
```c
typedef struct Node {
    int data;
    struct Node* next;
} Node_t;
```
**SexC:**
```lisp
(%typedef (%struct Node
            (int data)
            ((%ptr (%struct Node)) next))
          Node_t)
```

### 6.2. Прототипы и Определения функций

**Си (Прототип функции):**
```c
int add(int a, int b);
```
**SexC:**
```lisp
(%decl-fn int add ((int a) (int b)))
```

**Си (Определение / Реализация функции):**
```c
int main(int argc, char** argv) {
    return 0;
}
```
**SexC:**
```lisp
(%def-fn int main ((int argc) ((%ptr (%ptr char)) argv))
  (%block
    (%return 0)))
```

---

## 7. Директивы Препроцессора

Макросы препроцессора Си обрабатываются как встроенные макрокоманды компилятора SexC на самом верхнем уровне абстракции.


| Конструкция в Си                   | S-expression                                   |
| :---                               | :---                                           |
| `#include <stdio.h>`                 | `(%include <stdio.h>)`                                |
| `#include "my_header.h"`             | `(%include "my_header.h")`                            |
| `#define TAX_RATE 0.21`              | `(%define TAX_RATE 0.21)`                             |
| `#define MAX(a,b) ((a)>(b)?(a):(b))` | `(%define-macro (MAX a b) (%ternary (%> a b) a b))`  |
| `#ifdef DEBUG ... #endif`            | `(%ifdef DEBUG (%block ...))`                         |

---

## 8. Комплексный пример трансляции

Пример перевода классического алгоритма Евклида (нахождение НОД) из Си в формат SexC.

### Код на Си:
```c
#include <stdio.h>

int gcd(int a, int b) {
    while (b != 0) {
        int t = b;
        b = a % b;
        a = t;
    }
    return a;
}

int main() {
    printf("GCD: %d\n", gcd(48, 18));
    return 0;
}
```

### Код на SexC:
```lisp
(%include <stdio.h>)

(%def-fn int gcd ((int a) (int b))
  (%block
    (%while (%!= b 0)
      (%block
        (%decl int t b)
        (%set b (%% a b))
        (%set a t)))
    (%return a)))

(%def-fn int main ()
  (%block
    (printf "GCD: %d\\n" (gcd 48 18))
    (%return 0)))
```

---

## 9. Минимальная формальная грамматика SexC (EBNF)

Ниже - компактная грамматика для парсера S-expression фронтенда. Она не кодирует все семантические ограничения, но задает синтаксический каркас.

```ebnf
program        = { top_form } ;

top_form       = include
               | define
               | define_macro
               | ifdef
               | typedef_form
               | decl_fn
               | def_fn
               | decl
               | stmt
               ;

include        = "(" "%include" ( angle_header | string ) ")" ;
define         = "(" "%define" ident expr ")" ;
define_macro   = "(" "%define-macro" "(" ident { ident } ")" expr ")" ;
ifdef          = "(" "%ifdef" ident stmt ")" ;

typedef_form   = "(" "%typedef" type ident ")" ;
decl_fn        = "(" "%decl-fn" type ident params ")" ;
def_fn         = "(" "%def-fn" type ident params stmt ")" ;
decl           = "(" "%decl" type ident [ init ] ")" ;
init           = expr ;

params         = "(" { param } ")" ;
param          = "(" type ident ")"
               | "(" type "..." ")"
               ;

type           = basic_type
               | ident
               | "(" "%ptr" type ")"
               | "(" "%array" type [ integer ] ")"
               | "(" "%fn" type "(" { type } [ "..." ] ")" ")"
               | "(" "%const" type ")"
               | "(" "%volatile" type ")"
               | "(" "%restrict" type ")"
               | "(" storage_seq ")"
               | struct_type
               | union_type
               | enum_type
               ;

storage_seq    = storage_class { storage_class | basic_type | type_qual } ;
storage_class  = "%extern" | "%static" | "%register" | "%auto" | "%typedef" ;
type_qual      = "%const" | "%volatile" | "%restrict" ;
basic_type     = "void" | "char" | "short" | "int" | "long"
               | "float" | "double" | "signed" | "unsigned" ;

struct_type    = "(" "%struct" ident { field } ")" ;
union_type     = "(" "%union" ident { field } ")" ;
enum_type      = "(" "%enum" ident { enum_item } ")" ;
field          = "(" type ident ")" ;
enum_item      = "(" ident [ integer ] ")" ;

stmt           = "(" "%nop" ")"
               | "(" "%block" { stmt_or_decl } ")"
               | "(" "%if" expr stmt [ stmt ] ")"
               | "(" "%while" expr stmt ")"
               | "(" "%do-while" expr stmt ")"
               | "(" "%for" for_init for_cond for_step stmt ")"
               | "(" "%switch" expr { case_clause | default_clause } ")"
               | "(" "%break" ")"
               | "(" "%continue" ")"
               | "(" "%return" [ expr ] ")"
               | "(" "%goto" ident ")"
               | "(" "%label" ident ")"
               | expr
               ;

stmt_or_decl   = stmt | decl ;
for_init       = expr | decl | "(" "%nop" ")" ;
for_cond       = expr | "(" "%nop" ")" ;
for_step       = expr | "(" "%nop" ")" ;

case_clause    = "(" "%case" expr { stmt_or_decl } ")" ;
default_clause = "(" "%default" { stmt_or_decl } ")" ;

expr           = atom
               | "(" op { expr } ")"
               ;

op             = "%+" | "%-" | "%*" | "%/" | "%%"
               | "%~" | "%&" | "%|" | "%^" | "%<<" | "%>>"
               | "%==" | "%!=" | "%<" | "%<=" | "%>" | "%>="
               | "%!" | "%&&" | "%||"
               | "%set" | "%+=" | "%-=" | "%*=" | "%/=" | "%%="
               | "%post-inc" | "%pre-inc" | "%post-dec" | "%pre-dec"
               | "%addr" | "%deref" | "%sizeof-type" | "%sizeof-expr"
               | "%cast" | "%ternary" | "%comma"
               | "%aref" | "%dot" | "%arrow"
               ;

atom           = ident | integer | float | string | char | "NULL" ;
```

---

## 10. Нормализованное AST-представление

Чтобы backend в C был простым, удобно отделить внешний S-expression синтаксис от внутреннего AST. Рекомендуется нормализация в три слоя: `Expr`, `Stmt`, `Type`.

```text
Type
  kind: "Builtin" | "Named" | "Pointer" | "Array" | "Function" | "Qualified" | "Record" | "Enum"
  qualifiers: { const: bool, volatile: bool, restrict: bool }
  storage: ["extern" | "static" | "register" | "auto" | "typedef"]
  ...payload by kind...

Expr
  kind: "Literal" | "Ident" | "Unary" | "Binary" | "Nary" | "Assign" | "Call"
      | "Cast" | "SizeofType" | "SizeofExpr" | "Member" | "PtrMember"
      | "Index" | "Ternary" | "Comma" | "PostInc" | "PreInc" | "PostDec" | "PreDec"
  type: optional<Type>     ; после type-check
  value_category: "lvalue" | "rvalue"
  ...payload by kind...

Stmt
  kind: "Nop" | "Expr" | "Block" | "If" | "While" | "DoWhile" | "For"
      | "Switch" | "Break" | "Continue" | "Return" | "Goto" | "Label" | "Decl"
  ...payload by kind...
```

Нормализации, которые стоит делать сразу после парсинга:

- n-арные `(%+ a b c)` -> бинарная левая цепочка `((a + b) + c)`.
- `(%&& a b c)` и `(%|| a b c)` -> цепочка с сохранением short-circuit.
- `(%set a b)` и `%+=`/`%-=`/... -> отдельный `Assign`-узел c полем `op`.
- `(%sizeof-type int)` и `(%sizeof-expr x)` -> два разных узла (`SizeofType`, `SizeofExpr`).
- `(%dot obj field)` и `(%arrow ptr field)` -> разные узлы (`Member`, `PtrMember`).

Минимальные семантические инварианты AST:

- `%set`/`%+=`/... возвращают значение выражения (как в C).
- `%pre-inc`/`%pre-dec` возвращают новое значение, `%post-inc`/`%post-dec` - старое.
- `%&&`/`%||` всегда ленивые.
- `%comma` вычисляет все аргументы слева направо и возвращает последний.

---

## 11. Правила pretty-printer в C

Генерация C-кода должна быть двуступенчатой: сначала из AST в C-термы с приоритетами, потом печать со скобками по правилам.

Базовый приоритет (от низкого к высокому):

```text
1  assignment        =, +=, -=, *=, /=
2  conditional       ?:
3  logical-or        ||
4  logical-and       &&
5  bitwise-or        |
6  bitwise-xor       ^
7  bitwise-and       &
8  equality          == !=
9  relational        < <= > >=
10 shift             << >>
11 additive          + -
12 multiplicative    * / %
13 unary             ! ~ & * ++ -- (cast) sizeof
14 postfix           () [] . -> x++ x--
15 primary           ident literal (expr)
```

Правило скобок: подвыражение печатается в `(...)`, если его приоритет ниже приоритета контекста.

Дополнительные правила корректности:

- Для неассоциативных/частично ассоциативных операторов (`-`, `/`, `<<`, `>>`, сравнения) добавлять скобки даже при равном приоритете справа.
- Для `%set` и compound-assignment учитывать right-associativity (`a = b = c`).
- Для `cast` всегда печатать `(T)expr`, а если `expr` бинарный/тернарный - в скобках.
- Для `if/else` всегда использовать блоки `{ ... }`, чтобы избежать dangling-else.
- Для `switch` явно печатать `break;` там, где в AST нет `fallthrough`.

Рекомендуемый pipeline backend:

1. Parse S-expression -> Raw AST.
2. Normalize AST (n-ary, sizeof, assign, member access).
3. Type-check / symbol resolution.
4. C pretty-print with precedence-aware parentheses.
5. Optional: run `clang-format`.
