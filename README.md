# slab

> **draft** — work in progress, details may change

*slab* is a flat-memory stack VM. It comes with **sets** *((**s**)-(**e**)xpression (**t**)yped (**s**)ystems language)* — a statically-typed s-expression language that compiles to slab bytecode. The instruction set is small and word-addressed, easy to target from a simple compiler and easy to extend. sets itself is written in Scryer Prolog; the VM in C++20.

`examples/forth/forth.sets` is a Forth interpreter written in sets, compiled to slab bytecode. `./mandelbrot` compiles it, loads `examples/forth/mandelbrot.fth`, and runs.

![mandelbrot demo](readme/output.gif)

*`cat examples/forth/mandelbrot.fth` then `./mandelbrot`*

## contents

- [ramble](#ramble)
- [build](#build)
- [usage](#usage)
- [test](#test)
- [language](#language)
  - [syntax](#syntax-ebnf)
  - [types](#types)
  - [effect annotations](#effect-annotations)
  - [built-in primitives](#built-in-primitives)
  - [directives](#directives)
  - [expressions](#expressions)
  - [example](#example)
- [compiler pipeline](#compiler-pipeline)
- [VM](#vm)
  - [memory model](#memory-model)
  - [instruction set](#instruction-set)

## ramble

Some time ago I found a word-sized celled Forth VM on the [Silicon Valley Forth Interest Group's site](https://www.forth.org/) and was baffled by the binary-only F# compiler that came with it. It didn't work for me, the whole thing was an old tar snapshot with memory dumps, I spent an embarrassing amount of time trying to make it work, but it just ended up easier to take the model and rewrite it. There were some sidetracks along the way — I spent some time thinking about memory footprint because (I thought) a lot of space was wasted in the bytecode, everything word-sized even where it didn't need to be. At that point I was thinking of compile mode as a special thing, effective and space-efficient, where interpreted and compiled would have been two different ways of looking at the same memory — but interpreted mode would have needed to live entirely in memory, I got really confused about what that even meant in practice and started from scratch. I wrote two Forth interpreters after that: the first time realizing mid-way that I needed a return stack, and the second time — with a return stack — being unsatisfied with the fact that I could just make it a VM and drop the interpreter part completely. It can be this clean, I thought. I guess this is the curse of implementing Forth systems (but at least the cost of re-inventing is minimal timewise, compared to anything else). The goal was now to make the dictionary in pure threaded code, and finding the smallest subset of operations that enables bigger abstractions to be built on top of them. Make everything threaded! 

This is where Prolog comes in, just like in one of my previous/ongoing projects — a [PDP-11/40 emulator](https://github.com/no382001/pdp-11-40-emulator) — where the pattern was the same: the emulator loops reading bytes from a stdin pipe, and a Prolog pipeline takes a list of atoms representing primitive instructions, encodes them, and pushes them down the pipe. Lists in Prolog make this kind of thing really easy to work with, and later when the compiler grows, pattern matching and DCGs make parsing and AST transformations trivial. Coming from the BCPL-like language I had there, I tried a C-like macro pasting approach to paper over the non-existence of named words at the bytecode level — which made everything even more confusing, and on top of that the postfix notation was catching up to me. When you take some weeks off and come back it can be baffling. I'm more of an s-expressions guy anyway, so I wrote a frontend for that instead.

Around the same time I remembered something I tried with my Scheme interpreter — I wanted to write an MCE (metacircular evaluator) that enabled some sort of typed Scheme, never got to it, got stuck on some combination of macros and semiquoting (made me drop the project). This felt like the right moment to try again. Type inference works as stack effect inference basically — Sets functions can only leave one value on the stack (or void), not two or more, just to keep things simple. While the compiler is catching type errors it can also infer `det`/`semidet`/`nondet` the same way and do const folding on top.

Sets does betray the Forth philosophy to some degree, though the type system and effect inference help keep kernel development in check. The Forth written in Sets and targeting the Forth VM is free to be as Forth as it wants, as long as it keeps to the memory boundaries the REPL sets behind it.

## build

```sh
make
```

Requires: C++20 compiler, [Scryer Prolog](https://github.com/mthom/scryer-prolog)

## usage

```sh
./run programs/echo.sets
```

`examples/forth/forth.sets` is a Forth interpreter written in sets and compiled to slab bytecode. It implements a small Forth kernel on top of the VM, giving you a second layer to write programs in Forth syntax — split across `forth.sets` (entry point), `reader.sets` (strings/dictionary/stack/tokenizer/number parsing), `primitives.sets` (Forth words), and `compile.sets` (word dispatch). `./mandelbrot` compiles `forth.sets`, loads `examples/forth/mandelbrot.fth` into it, and runs. Shared library code (`byte-ref`/`byte-set!`, ASCII constants, catch/throw) lives in `lib/`.

## test

```sh
make test
```

Requires: [bats](https://github.com/bats-core/bats-core)

## language

### syntax (EBNF)

```ebnf
program    = form* ;
form       = list | bracket | asm | string | number | symbol ;
list       = '(' form* ')' ;
bracket    = '[' form* ']' ;
asm        = '{' symbol* '}' ;
string     = '"' char* '"' ;
number     = '-'? digit+ ;
symbol     = (any char except whitespace, parens, brackets, braces, '"', ';')+ ;

top-level  = def | extern | const | directive ;
def        = '(' 'def' symbol params ':' type effect? expr+ ')' ;
extern     = '(' 'extern' symbol param-types ':' type ')' ;
const      = '(' 'const' symbol type expr ')' ;
directive  = '(' '$include' string ')'
           | '(' '$section' number ')'
           | '(' '$alloc' symbol number ')' ;

params     = '(' param* ')' ;
param      = symbol | '(' symbol ':' type ')' ;
param-types = '(' type* ')' ;
effect     = '[' 'det' ']' | '[' 'semidet' ']' | '[' 'nondet' ']' ;

type       = 'int' | 'byte' | 'bool' | 'void' | '(' 'ptr' type ')' ;

expr       = number | string | symbol
           | '(' 'if' expr expr expr ')'
           | '(' 'let' '(' binding* ')' expr+ ')'
           | '(' 'do' expr+ ')'
           | '(' 'while' expr expr+ ')'
           | '(' 'deref' expr ')'
           | '(' 'deref8' expr ')'
           | '(' 'store' expr expr ')'
           | '(' 'store8' expr expr ')'
           | '(' 'addr' symbol ')'
           | '(' 'execute' expr ')'
           | '(' binop expr expr ')'
           | '(' symbol expr* ')'
           | '{' symbol* '}' ;

binding    = '(' symbol expr ')' ;
binop      = '+' | '-' | '*' | '/' | 'mod' | '=' | '<' | '>' | '!=' | '<=' | '>=' | 'and' | 'or' | 'xor' ;
```

Comments start with `;` and run to end of line.

### types

| type | description |
|------|-------------|
| `int` | signed integer (`cell_t` wide) |
| `byte` | 8-bit value (always) |
| `bool` | boolean (0 or 1) |
| `void` | no value |
| `(ptr T)` | pointer to T |

> Sizes depend on the VM configuration. To change them, edit `src/vm.h`:
> - `cell_t` — the native cell type; determines the width of `int` and `(ptr T)` (default: `int16_t`)
> - `MEMORY_SIZE` — total address space in bytes (default: `0xFFFF`)
> - `STACK_SIZE` — max depth of each stack in cells (default: `256`)

### effect annotations

Every function sits at one level of a three-level hierarchy:

```
det  <  semidet  <  nondet
```

The names come from Prolog's solution determinism, but the meaning here is about predictability of effect:

**`[det]`** — pure. The result depends only on the arguments. No memory access, no side effects. Given the same inputs you always get the same output, so the compiler can fold calls at compile time.

**`[semidet]`** — reads or writes memory, but no I/O. Memory is *semi*-deterministic in the sense that it behaves predictably given a known state — a read always returns what was last written there, a write always takes effect. There is no blocking, no external influence. The function is deterministic conditioned on the flat address space; you just can't reduce it away at compile time because the memory state isn't known statically.

Write-only, non-blocking I/O sits in a structural gray area: `emit` always takes effect, never blocks, and returns nothing unpredictable — the same properties that define a memory write. The difference is that its effect escapes the address space, so it cannot be analyzed locally. It still belongs in `[nondet]`.

**`[nondet]`** — performs I/O or otherwise escapes. Non-determinism has two faces: the *value* returned (a `key` call gives back whatever the user types, a file read depends on disk state) and the *duration* before control returns (a read may block indefinitely). Either dimension alone is enough to force `[nondet]`. Write-only I/O like `emit` has no unpredictable return value and does not block, but it still escapes — its effects are invisible to local analysis and cannot be reordered or eliminated. Anything that touches the outside world belongs here.

The hierarchy is a claim about the worst thing a function does. It propagates upward: calling a `[semidet]` function makes the caller at least `[semidet]`; calling a `[nondet]` function forces `[nondet]` all the way up. The compiler infers the actual effect and errors if the declared annotation is stricter than the body warrants. Omitting the annotation on a `det`-eligible function produces a warning.

### built-in primitives

| primitive | signature | description |
|-----------|-----------|-------------|
| `emit` | `(int) : void` | write character to stdout |
| `key` | `() : int` | read character from stdin |
| `bye` | `() : void` | halt the VM |

Inline VM opcodes can be emitted directly with `{...}`, bypassing the type system.

### directives

Directives are compile-time only — they emit no code.

| directive | description |
|-----------|-------------|
| `($include "file")` | splices `file` into the current program at this point, resolved relative to the including file's directory |
| `($section addr)` | sets the static allocation cursor to `addr` |
| `($alloc name size)` | binds `name` to the current cursor as an `int` constant, then advances the cursor by `size` bytes |

### expressions

**`(let ((x expr) ...) body...)`** — binds names to values for the duration of `body`. Each binding is stored at a statically-assigned memory address allocated per-function starting at `0x4000`. No allocation occurs at runtime; the addresses are fixed at compile time.

**`(addr name)`** — pushes the address of a named function as an integer, without calling it. Used to pass functions as values.

**`(execute expr)`** — evaluates `expr` to get a function address, then calls it as an indirect call. Combined with `addr`, this is the only form of indirect dispatch.

**String literals** — a string `"hello"` compiles to a `branch` over its bytes, which are embedded inline in the code segment as null-terminated bytes, followed by a `lit` of the string's start address. Strings are read-only and live in the code region.

### example

```lisp
($section 1022)
($alloc STRI  2)
($alloc CHAR  2)
($alloc IDX   2)
($alloc BUF 256)

($include "core.sets") ; definitions for `true` and `false`

(def streq ((a : int) (b : int)) : bool
  (store STRI 0)
  (while (if (= (deref8 (+ a (deref STRI))) (deref8 (+ b (deref STRI))))
             (!= (deref8 (+ a (deref STRI))) 0)
             false)
    (store STRI (+ (deref STRI) 1)))
  (= (deref8 (+ a (deref STRI))) (deref8 (+ b (deref STRI)))))

(def main () : void
  (while true
    (store IDX 0)
    (while (do (store CHAR (key))
               (!= (deref CHAR) 10))
      (store8 (+ BUF (deref IDX)) (deref CHAR))
      (store IDX (+ (deref IDX) 1)))
    (store8 (+ BUF (deref IDX)) 0)
    (if (streq BUF "bye")
      (bye)
      (do (store IDX 0)
          (while (!= (deref8 (+ BUF (deref IDX))) 0)
            (emit (deref8 (+ BUF (deref IDX))))
            (store IDX (+ (deref IDX) 1)))
          (emit 10)))))
```

Memory layout of the above program at runtime (default config):

```
; $section 1022 sets the cursor; each $alloc advances it

 addr  0        ~N    1022  1024  1026  1028            1283
       ┌────────┬─────┬─────┬─────┬─────┬───────────────┐
       │ code   │     │STRI │CHAR │ IDX │      BUF      │ ...
       └────────┴─────┴─────┴─────┴─────┴───────────────┘
                       <-2-> <-2-> <-2-> <---256 bytes--->

; "bye" string literal is inlined in the code region (branch over + bytes + lit addr)

; let/param slots are statically assigned per-function starting at 0x4000

 addr  16384  16386   16404
       ┌──────┬───────┬────────── ...
       │  a   │   b   │  main slots
       │      streq   │
       └──────┴───────┴────────── ...

; stacks and registers occupy the top of address space
; (with MEMORY_SIZE=65535, STACK_SIZE=256, CELL_SIZE=2)
; DS_START = 64511, RS_START = 65023

 addr  64505   64511          65023          65535
       ┌───────┬──────────────┬──────────────┐
       │ regs  │   dstack     │   rstack     │
       │SP RP IP│  512 B      │   512 B      │
       └───────┴──────────────┴──────────────┘
```

## compiler pipeline

The compiler is a multi-pass Prolog program (`compiler/`):

| stage | file | description |
|-------|------|-------------|
| parse | `parser.pl` | characters -> s-expression forms (DCG) |
| ast | `ast.pl` | forms -> typed AST nodes |
| typecheck | `typecheck.pl` | monomorphic type synthesis + checking |
| effects | `effects.pl` | fixed-point effect inference (det/semidet/nondet) |
| dead code | `deadcode.pl` | warn on unreachable definitions |
| const fold | `constfold.pl` | fold `det` calls with constant arguments |
| codegen | `codegen.pl` | AST -> VM token sequence |
| emit | `emit.pl` | tokens -> binary bytecode |

The assembler binding (`gen/gen.pl`) is auto-generated from the C++ dispatch table, keeping the Prolog compiler in sync with the VM instruction set.

## VM

### memory model

Flat byte-addressable memory. Programs are loaded at address 0 and grow upward. The two stacks (data and return) are fixed-size regions at the top of the address space, laid out downward from `MEMORY_SIZE`:

```
0                                                           MEMORY_SIZE
┌─────────────────────────────────┬───────┬──────────┬──────────┐
│ program + heap (grows ->)       │ regs  │  dstack  │  rstack  │
└─────────────────────────────────┴───────┴──────────┴──────────┘
                                  DS_START-n DS_START  RS_START
```

Everything is memory-mapped, there are no loose parts. The instruction pointer (`IP`), data stack pointer (`SP`), and return stack pointer (`RP`) are stored as cells in memory just below the stack region (`DS_START - 1..3`). The stacks themselves are contiguous cell arrays in memory. Nothing lives outside the flat address space.

This means that you can just dump memory in runtime, and when you load it back in you have restored a snapshot of the execution.

`$section` / `$alloc` directives place named variables in the heap region; the compiler does not manage the heap at runtime.

Word size, memory size, and stack depth are set in `src/vm.h` (see [types](#types)):

| constant | default | effect |
|----------|---------|--------|
| `cell_t` | `int16_t` | native word width |
| `MEMORY_SIZE` | `0xFFFF` | total address space in bytes |
| `STACK_SIZE` | `256` | max depth of each stack in cells |

### instruction set

Minimal threaded-style bytecode:

| group | opcodes |
|-------|---------|
| literals | `nop` `lit` |
| memory | `@` `!` `c@` `c!` |
| stack | `dup` `drop` `swap` `over` |
| return stack | `>r` `r>` `r@` |
| alu | `+` `-` `*` `/` `mod` `and` `or` `xor` `=` `<` |
| control | `branch` `zbranch` `call` `ret` `execute` |
| system | `trap` |
