# slab

*slab* is a flat-memory stack VM. It comes with **sets** *((**s**)-(**e**)xpression (**t**)yped (**s**)ystems language)*, a statically-typed s-expression language that compiles to slab bytecode. The instruction set is small and word-addressed, easy to target from a simple compiler and easy to extend. sets itself is written in [Scryer Prolog](https://github.com/mthom/scryer-prolog); the VM in C++20.

`examples/forth/forth.sets` is a Forth interpreter written in sets, compiled to slab bytecode. `./mandelbrot` compiles it, loads `examples/forth/mandelbrot.fth`, and runs.

![mandelbrot demo](readme/output.gif)

*`cat examples/forth/mandelbrot.fth` then `./mandelbrot`*

## talk

slab and sets were presented at the Scryer Prolog Meetup 2026 in Vienna. Slides: [scryer-meetup-2026/slab-sets.pdf](scryer-meetup-2026/slab-sets.pdf).

## contents

- [talk](#talk)
- [ramble](#ramble)
- [build](#build)
- [usage](#usage)
- [test](#test)
- [language](#language)
  - [syntax](#syntax-ebnf)
  - [types](#types)
  - [effect inference](#effect-inference)
  - [built-in primitives](#built-in-primitives)
  - [directives](#directives)
  - [example](#example)
- [compiler pipeline](#compiler-pipeline)
- [VM](#vm)
  - [memory model](#memory-model)
  - [instruction set](#instruction-set)

## ramble

Some time ago I found a word-sized celled Forth VM on the [Silicon Valley Forth Interest Group's site](https://www.forth.org/) and was baffled by the binary-only F# compiler that came with it. It didn't work for me, the whole thing was an old tar snapshot with memory dumps, I spent an embarrassing amount of time trying to make it work, but it just ended up easier to take the model and rewrite it. There were some sidetracks along the way: I spent some time thinking about memory footprint because (I thought) a lot of space was wasted in the bytecode, everything word-sized even where it didn't need to be. At that point I was thinking of compile mode as a special thing, effective and space-efficient, where interpreted and compiled would have been two different ways of looking at the same memory, but interpreted mode would have needed to live entirely in memory, I got really confused about what that even meant in practice and started from scratch. I wrote two Forth interpreters after that: the first time realizing mid-way that I needed a return stack, and the second time (with a return stack) being unsatisfied with the fact that I could just make it a VM and drop the interpreter part completely. It can be this clean, I thought. I guess this is the curse of implementing Forth systems (but at least the cost of re-inventing is minimal timewise, compared to anything else). The goal was now to make the dictionary in pure threaded code, and finding the smallest subset of operations that enables bigger abstractions to be built on top of them. Make everything threaded! 

This is where Prolog comes in, just like in one of my previous/ongoing projects, a [PDP-11/40 emulator](https://github.com/no382001/pdp-11-40-emulator), where the pattern was the same: the emulator loops reading bytes from a stdin pipe, and a Prolog pipeline takes a list of atoms representing primitive instructions, encodes them, and pushes them down the pipe. Lists in Prolog make this kind of thing really easy to work with, and later when the compiler grows, pattern matching and DCGs make parsing and AST transformations trivial. Coming from the BCPL-like language I had there, I tried a C-like macro pasting approach to paper over the non-existence of named words at the bytecode level, which made everything even more confusing, and on top of that the postfix notation was catching up to me. When you take some weeks off and come back it can be baffling. I'm more of an s-expressions guy anyway, so I wrote a frontend for that instead.

Around the same time I remembered something I tried with my Scheme interpreter: I wanted to write an MCE (metacircular evaluator) that enabled some sort of typed Scheme, never got to it, got stuck on some combination of macros and semiquoting (made me drop the project). This felt like the right moment to try again. Type inference works as stack effect inference basically: sets functions can only leave one value on the stack (or void), not two or more, just to keep things simple. While the compiler is catching type errors it can also infer `det`/`semidet`/`nondet` the same way and do const folding on top.

sets does betray the Forth philosophy to some degree, though the type system and effect inference help keep kernel development in check. The Forth written in sets and targeting the Forth VM is free to be as Forth as it wants, as long as it keeps to the memory boundaries the REPL sets behind it.

## build

```sh
make
```

Requires: C++20 compiler, [Scryer Prolog](https://github.com/mthom/scryer-prolog)

## usage

```sh
./run programs/echo.sets
```

`examples/forth/forth.sets` is a Forth interpreter written in sets and compiled to slab bytecode. It implements a small Forth kernel on top of the VM, giving you a second layer to write programs in Forth syntax, split across `forth.sets` (entry point), `reader.sets` (strings/dictionary/stack/tokenizer/number parsing), `primitives.sets` (Forth words), and `compile.sets` (word dispatch). `./mandelbrot` compiles `forth.sets`, loads `examples/forth/mandelbrot.fth` into it, and runs. Shared library code (`byte-ref`/`byte-set!`, ASCII constants, catch/throw) lives in `lib/`.

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
extern     = '(' 'extern' symbol param-types ':' type ')'
           | '(' 'extern' symbol number param-types ':' type ')' ;
const      = '(' 'const' symbol type expr ')' ;
directive  = '(' '$include' string ')'
           | '(' '$section' number ')'
           | '(' '$code-starts-at' number ')'
           | '(' '$alloc' symbol number ')' ;

params     = '(' param* rest-param? ')' ;
param      = symbol | '(' symbol ':' type ')' ;
rest-param = '(' symbol ':' type '...' ')' ;
param-types = '(' type* ')' ;
level      = 'det' | 'semidet' | 'nondet' ;
effect     = '[' level ']' | '[' level 'inline' ']' | '[' 'inline' level ']' ;

type       = 'int' | 'byte' | 'bool' | 'void' | '(' 'ptr' type ')' ;

expr       = number | string | symbol
           | '(' 'if' expr expr expr ')'
           | '(' 'case' expr case-clause* else-clause ')'
           | '(' 'let' '(' binding* ')' expr+ ')'
           | '(' 'local' '(' binding* ')' expr+ ')'
           | '(' 'do' expr+ ')'
           | '(' 'while' expr expr+ ')'
           | '(' '@' expr ')'
           | '(' 'c@' expr ')'
           | '(' '!' expr expr ')'
           | '(' 'c!' expr expr ')'
           | '(' 'addr' symbol ')'
           | '(' 'execute' expr ')'
           | '(' binop expr expr ')'
           | '(' symbol expr* ')'
           | '{' symbol* '}'
           | meta ;

meta       = '(' ( '$vm-sp' | '$vm-rp' | '$vm-ip' | '$mem' | '$cell'
                 | '$stack-size' | '$ds-start' | '$rs-start' ) ')'
           | '(' '$op' symbol ')' ;

binding    = '(' symbol expr ')' ;
case-clause = '(' expr expr ')' ;
else-clause = '(' 'else' expr ')' ;
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
> - `cell_t`: the native cell type; determines the width of `int` and `(ptr T)` (default: `int16_t`)
> - `MEMORY_SIZE`: total address space in bytes (default: `0xFFFF`)
> - `STACK_SIZE`: max depth of each stack in cells (default: `256`)

### effect inference

The compiler infers an effect for every function, one of three levels:

```
det  <  semidet  <  nondet
```

The names have nothing to do with Prolog's determinism. Here they only say what a function touches:

**`[det]`**: only works on the stack. Its result is fully determined by its stack effect (the values it takes, the one it leaves), so with constant arguments the call can be evaluated statically and folded at compile time.

**`[semidet]`**: also reads or writes memory, but does no I/O. The stack effect no longer determines the result, because the memory state isn't known statically.

**`[nondet]`**: does I/O (`key`, `emit`, traps). Anything that reaches outside the address space ends up here, even write-only output like `emit`.

A function's effect is the worst effect in its body, so it propagates to callers: calling a `[semidet]` function makes the caller at least `[semidet]`, calling a `[nondet]` one makes it `[nondet]`. The annotation is optional and only checked against the inferred effect: the compiler errors if it is stricter than the body, and warns if it is looser or if a `det` function has none.

### built-in primitives

| primitive | signature | description |
|-----------|-----------|-------------|
| `emit` | `(int) : void` | write character to stdout |
| `key` | `() : int` | read character from stdin |
| `bye` | `() : void` | halt the VM |
| `assert-fail` | `() : void` | halt the VM with exit code 1 (assertion/panic) |

Inline VM opcodes can be emitted directly with `{...}`, bypassing the type system.

### directives

Directives are compile-time only, they emit no code.

| directive | description |
|-----------|-------------|
| `($include "file")` | splices `file` into the current program at this point, resolved relative to the including file's directory |
| `($section addr)` | sets the static allocation cursor to `addr` |
| `($code-starts-at addr)` | places the code at `addr`; without it the code goes in the first free gap after the data. Address 0 always holds a jump to `main` |
| `($alloc name size)` | binds `name` to the current cursor as an `int` constant, then advances the cursor by `size` bytes |
| `($vm-sp)` / `($vm-rp)` / `($vm-ip)` | expand to the memory address of the VM's SP/RP/IP register (memory-mapped, see [memory model](#memory-model)) |
| `($op name)` | expands to an opcode's numeric code (from `gen/gen.pl`), for use inside `{...}` inline asm |
| `($mem)` / `($cell)` / `($stack-size)` | expand to `MEMORY_SIZE`, `CELL_SIZE` and `STACK_SIZE` |
| `($ds-start)` / `($rs-start)` | expand to the start address of the data / return stack |

### example

`programs/echo.sets`:

```lisp
($alloc BUF 256)

($include "../lib/core.sets") ; true/false, byte-ref, byte-set!

(def streq ((a : (ptr byte)) (b : (ptr byte))) : bool [semidet]
  (local ((i 0))
    (while (and (= (byte-ref a i) (byte-ref b i))
                (!= (byte-ref a i) 0))
      (! i (+ (@ i) 1)))
    (= (byte-ref a i) (byte-ref b i))))

; read a line into BUF, null-terminated
(def read-line () : void [nondet]
  (local ((i 0) (c (key)))
    (while (!= (@ c) 10)
      (byte-set! BUF i (@ c))
      (! i (+ (@ i) 1))
      (! c (key)))
    (byte-set! BUF i 0)))

; print a null-terminated string, then a newline
(def print-line ((s : (ptr byte))) : void [nondet]
  (local ((i 0))
    (while (!= (byte-ref s i) 0)
      (emit (byte-ref s i))
      (! i (+ (@ i) 1)))
    (emit 10)))

(def main () : void [nondet]
  (while true
    (read-line)
    (if (streq BUF "bye")
      (bye)
      (print-line BUF))))
```

Memory layout of the above program at runtime (default config):

```
; address 0 holds the jump to main; data is laid out from there:
; $alloc first, then locals, then params, each function in definition order.
; the code goes in the first free gap that fits it (or at $code-starts-at)

 addr  0    4               260 262 264 266 268 270 272 274          714
       +----+---------------+---+---+---+---+---+---+---+------------+
       |jmp |      BUF      | i | i | c | i | a | b | s |    code    |
       +----+---------------+---+---+---+---+---+---+---+------------+

; BUF is 256 bytes; i, i, c, i are the locals of streq, read-line (2) and print-line;
; a, b, s are the params of streq and print-line. let bindings live on the return stack.
; the "bye" string literal is inlined in the code (branch over + bytes + lit addr)

; stacks and registers occupy the top of address space
; (with MEMORY_SIZE=65535, STACK_SIZE=256, CELL_SIZE=2)
; DS_START = 64511, RS_START = 65023

 addr  64505    64511          65023          65535
       +--------+--------------+--------------+
       | regs   |   dstack     |   rstack     |
       |SP RP IP|    512 B     |    512 B     |
       +--------+--------------+--------------+
```

## compiler pipeline

The compiler is a multi-pass Prolog program (`compiler/`):

| stage | file | description |
|-------|------|-------------|
| parse | `parser.pl` | characters -> s-expression forms (DCG) |
| meta-expansion | `compiler.pl` | expand `$include`/`$section`/`$alloc`/`$code-starts-at` directives and `$vm-*`/`$op` meta-constants into literals |
| ast | `ast.pl` | forms -> typed AST nodes |
| locals | `locals.pl` | expand `local` bindings into statically-allocated memory cells |
| typecheck | `typecheck.pl` | monomorphic type synthesis + checking |
| effects | `effects.pl` | fixed-point effect inference (det/semidet/nondet) |
| dead code | `deadcode.pl` | warn on unreachable definitions |
| inline | `inline.pl` | expand `[inline]`-annotated call sites |
| const fold | `constfold.pl` | fold `det` calls with constant arguments |
| cse | `cse.pl` | common subexpression elimination, if-branch merging, dead/single-use `let` elimination |
| codegen | `codegen.pl` | AST -> VM token sequence |
| emit | `emit.pl` | tokens -> binary bytecode |

The assembler binding (`gen/gen.pl`) is auto-generated from the C++ dispatch table, keeping the Prolog compiler in sync with the VM instruction set.

## VM

### memory model

Flat byte-addressable memory. The binary is loaded at address 0, which holds a jump to `main`; the compiler lays out data and code above it (see [example](#example)). The two stacks (data and return) are fixed-size regions at the top of the address space, laid out downward from `MEMORY_SIZE`:

```
0                                                           MEMORY_SIZE
+---------------------------------+-------+----------+----------+
| entry, data, code, heap          | regs  |  dstack  |  rstack  |
+---------------------------------+-------+----------+----------+
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
| return stack | `>r` `r>` `r@` `rpick` |
| alu | `+` `-` `*` `/` `mod` `and` `or` `xor` `=` `<` |
| control | `branch` `zbranch` `call` `ret` `execute` |
| system | `trap` |
