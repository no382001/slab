#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/helpers.sh"
}

# ============================================================
# typecheck: should accept
# ============================================================

@test "typecheck: identity function" {
  result="$(compile '(def id ((x : int)) : int x)' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: arithmetic" {
  result="$(compile '(def f ((a : int) (b : int)) : int (+ a b))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: comparison returns bool" {
  result="$(compile '(def f ((a : int) (b : int)) : bool (< a b))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: if expression" {
  result="$(compile '(def abs ((n : int)) : int (if (< n 0) (- 0 n) n))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: let binding" {
  result="$(compile '(def f ((x : int)) : int (let ((y (+ x 1))) y))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: while loop" {
  result="$(compile '(def f ((n : int)) : void (while (< n 10) (+ n 1)))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: pointer @" {
  result="$(compile '(def f ((p : (ptr int))) : int (@ p))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: pointer !" {
  result="$(compile '(def f ((p : (ptr int)) (v : int)) : void (! p v))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: const" {
  result="$(compile '(const SIZE int 256) (def f () : int SIZE)' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: builtin emit" {
  result="$(compile '(def f () : void (emit 65))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: builtin key" {
  result="$(compile '(def f () : int (key))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: string literal is ptr(byte)" {
  result="$(compile '(def f () : int (c@ "hi"))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: int and ptr compatible" {
  result="$(compile '(def f ((a : int)) : int (c@ a))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: c@ on int address" {
  result="$(compile '(const BUF int 1024) (def f () : byte (c@ BUF))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: c! with int address" {
  result="$(compile '(const BUF int 1024) (def f () : void (c! BUF 0))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: function call" {
  result="$(compile '(def inc ((x : int)) : int (+ x 1)) (def f () : int (inc 5))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: do block" {
  result="$(compile '(def f () : int (do (emit 65) 42))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: ptr arithmetic" {
  result="$(compile '(def f ((p : (ptr byte))) : (ptr byte) (+ p 1))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: ptr comparison" {
  result="$(compile '(def f ((a : (ptr byte)) (b : (ptr byte))) : bool (= a b))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: string arg to ptr(byte) param" {
  result="$(compile '(def f ((s : (ptr byte))) : byte (c@ s)) (def main () : void (f "hi") (bye))' typed)"
  [[ "$result" == ok* ]]
}

@test "typecheck: variadic call accepts varying rest counts" {
  result="$(compile '(def f ((a : int) (rest : int ...)) : int a) (def g () : int (+ (f 1) (+ (f 1 2 3) (f 1 2 3 4 5))))' typed)"
  [[ "$result" == ok* ]]
}

# ============================================================
# typecheck: should reject
# ============================================================

@test "typecheck rejects: wrong return type" {
  result="$(compile '(def bad ((n : int)) : bool n)' typed)"
  [[ "$result" == error* ]]
}

@test "typecheck rejects: if branch type mismatch" {
  result="$(compile '(def bad ((n : int)) : int (if (< n 0) 1 (< n 5)))' typed)"
  [[ "$result" == error* ]]
}

@test "typecheck rejects: undefined variable" {
  result="$(compile '(def bad () : int x)' typed)"
  [[ "$result" == error* ]]
}

@test "typecheck rejects: wrong arity" {
  result="$(compile '(def f ((x : int)) : int x) (def g () : int (f 1 2))' typed)"
  [[ "$result" == error* ]]
}

@test "typecheck rejects: variadic call below fixed arity" {
  result="$(compile '(def f ((a : int) (rest : int ...)) : int a) (def g () : int (f))' typed)"
  [[ "$result" == error* ]]
}

@test "typecheck rejects: while condition not bool" {
  result="$(compile '(def f ((n : int)) : void (while n (emit 65)))' typed)"
  [[ "$result" == error* ]]
}

@test "typecheck rejects: while condition not bool (arithmetic expr)" {
  result="$(compile '(def f ((n : int)) : void (while (+ n 1) (emit 65)))' typed)"
  [[ "$result" == error* ]]
}

@test "compile rejects: no main" {
  result="$(compile '(def f () : int 42)')"
  [[ "$result" == error* ]]
}

@test "compile rejects: no main but library-only target succeeds" {
  result="$(compile '(def f () : int 42)' typed)"
  [[ "$result" == ok* ]]
}

# ============================================================
# end-to-end: compile and run
# ============================================================

@test "e2e: emit literal" {
  run run_program '(def main () : void (emit 65) (bye))'
  [ "$output" = "A" ]
}

@test "e2e: arithmetic" {
  run run_program '(def main () : void (emit (+ 60 5)) (bye))'
  [ "$output" = "A" ]
}

@test "e2e: if expression" {
  run run_program '(def main () : void (emit (if (< 1 2) 65 66)) (bye))'
  [ "$output" = "A" ]
}

@test "e2e: let binding" {
  run run_program '(def main () : void (let ((x 65)) (emit x)) (bye))'
  [ "$output" = "A" ]
}

@test "e2e: function call" {
  run run_program '(def add1 ((n : int)) : int (+ n 1)) (def main () : void (emit (add1 64)) (bye))'
  [ "$output" = "A" ]
}

@test "e2e: variadic function with no rest args" {
  run run_program '(const ACC int 1024) (const IDX int 1026) (def sum_all ((first : int) (rest : int ...)) : int [semidet] (! ACC first) (! IDX 0) (while (< (@ IDX) rest-count) (! ACC (+ (@ ACC) (@ (+ rest (* (@ IDX) 2))))) (! IDX (+ (@ IDX) 1))) (@ ACC)) (def main () : void (emit (+ 48 (sum_all 5))) (bye))'
  [ "$output" = "5" ]
}

@test "e2e: variadic function sums rest args" {
  run run_program '(const ACC int 1024) (const IDX int 1026) (def sum_all ((first : int) (rest : int ...)) : int [semidet] (! ACC first) (! IDX 0) (while (< (@ IDX) rest-count) (! ACC (+ (@ ACC) (@ (+ rest (* (@ IDX) 2))))) (! IDX (+ (@ IDX) 1))) (@ ACC)) (def main () : void (emit (+ 48 (sum_all 1 2 3))) (bye))'
  [ "$output" = "6" ]
}

@test "e2e: variadic function called with different rest counts" {
  run run_program '(const ACC int 1024) (const IDX int 1026) (def sum_all ((first : int) (rest : int ...)) : int [semidet] (! ACC first) (! IDX 0) (while (< (@ IDX) rest-count) (! ACC (+ (@ ACC) (@ (+ rest (* (@ IDX) 2))))) (! IDX (+ (@ IDX) 1))) (@ ACC)) (def main () : void (emit (+ 48 (sum_all 5))) (emit (+ 48 (sum_all 1 2 3))) (emit (+ 48 (sum_all 1 1 1 1 1 1 1 1 1))) (bye))'
  [ "$output" = "569" ]
}

@test "e2e: while loop" {
  run run_program '(const I int 1024) (def main () : void (! I 65) (while (< (@ I) 68) (emit (@ I)) (! I (+ (@ I) 1))) (bye))'
  [ "$output" = "ABC" ]
}

@test "e2e: string literal first byte" {
  run run_program '(def main () : void (emit (c@ "Hello")) (bye))'
  [ "$output" = "H" ]
}

@test "e2e: echo program" {
  run run_program \
    '(const BUF int 1028) (const I int 1026) (const C int 1024) (def main () : void (! I 0) (while (do (! C (key)) (!= (@ C) 10)) (c! (+ BUF (@ I)) (@ C)) (! I (+ (@ I) 1))) (c! (+ BUF (@ I)) 0) (! I 0) (while (!= (c@ (+ BUF (@ I))) 0) (emit (c@ (+ BUF (@ I)))) (! I (+ (@ I) 1))) (bye))' \
    $'hello\n'
  [ "$output" = "hello" ]
}

@test "e2e: user void function no spurious drop" {
  run run_program '(def greet () : void (emit 72) (emit 105)) (def main () : void (greet) (emit 10) (bye))'
  [ "$output" = "Hi" ]
}

@test "e2e: multiple void calls in sequence" {
  run run_program '(def a () : void (emit 65)) (def b () : void (emit 66)) (def main () : void (a) (b) (emit 10) (bye))'
  [ "$output" = "AB" ]
}

@test "e2e: ptr(byte) param with string literal" {
  run run_program '(def first ((s : (ptr byte))) : byte (c@ s)) (def main () : void (emit (first "Zap")) (bye))'
  [ "$output" = "Z" ]
}

@test "e2e: dict program" {
  run run_program_file "$BATS_TEST_DIRNAME/../programs/dict.sets" $'hello\nwords\nfoo\nbye\n'
  [ "$output" = $'Hello!\nwords hello bye \nfoo ?' ]
}

@test "e2e: forth repl arithmetic" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $'1 2 + .\nbye\n'
  [[ "$output" == *"3 "* ]]
}

@test "e2e: forth repl stack ops" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $'5 dup * .\nbye\n'
  [[ "$output" == *"25 "* ]]
}

@test "e2e: forth repl number parsing" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $'42 .\nbye\n'
  [[ "$output" == *"42 "* ]]
}

@test "e2e: forth repl unknown word" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $'foo\nbye\n'
  [[ "$output" == *"foo ?"* ]]
}

@test "e2e: forth colon def simple" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $': test 42 ;\ntest .\nbye\n'
  [[ "$output" == *"42 "* ]]
}

@test "e2e: forth colon def using builtins" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $': square dup * ;\n5 square .\nbye\n'
  [[ "$output" == *"25 "* ]]
}

@test "e2e: forth colon def calling colon def" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $': square dup * ;\n: quad square square ;\n3 quad .\nbye\n'
  [[ "$output" == *"81 "* ]]
}

@test "e2e: forth colon def with literal and op" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $': double 2 * ;\n7 double .\nbye\n'
  [[ "$output" == *"14 "* ]]
}

@test "e2e: forth throw and recover" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $'99 throw\n3 4 + .\nbye\n'
  [[ "$output" == *"error: 99"* ]]
  [[ "$output" == *"7 "* ]]
}

@test "e2e: forth throw from colon def" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $': boom 42 throw ;\nboom\n10 .\nbye\n'
  [[ "$output" == *"error: 42"* ]]
  [[ "$output" == *"10 "* ]]
}

@test "e2e: forth if/then control flow" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $': myabs dup 0 < if negate then ;\n-7 myabs .\nbye\n'
  [[ "$output" == *"7 "* ]]
}

@test "e2e: forth begin/until control flow" {
  run run_program_file "$BATS_TEST_DIRNAME/../examples/forth/forth.sets" $': cnt3 begin dup . 1 - dup 0 = until drop ;\n3 cnt3\nbye\n'
  [[ "$output" == *"3 2 1 "* ]]
}

@test "e2e: meta alloc and vm-sp" {
  prog='($section 1000)
($alloc X 2)
(def main () : void
  (! X ($vm-sp))
  (if (!= (@ X) 0) (emit 89) (emit 78))
  (bye))'
  run run_program "$prog"
  [ "$output" = "Y" ]
}

# ============================================================
# effects: inference
# ============================================================

@test "effects: pure arithmetic is det" {
  result="$(compile '(def f ((x : int)) : int (+ x 1))' effects)"
  [[ "$result" == *"eff(f,det)"* ]]
}

@test "effects: emit is nondet" {
  result="$(compile '(def f () : void (emit 65))' effects)"
  [[ "$result" == *"eff(f,nondet)"* ]]
}

@test "effects: key is nondet" {
  result="$(compile '(def f () : int (key))' effects)"
  [[ "$result" == *"eff(f,nondet)"* ]]
}

@test "effects: bye is nondet" {
  result="$(compile '(def f () : void (bye))' effects)"
  [[ "$result" == *"eff(f,nondet)"* ]]
}

@test "effects: @ is semidet" {
  result="$(compile '(def f ((p : (ptr int))) : int (@ p))' effects)"
  [[ "$result" == *"eff(f,semidet)"* ]]
}

@test "effects: c@ is semidet" {
  result="$(compile '(def f ((p : (ptr byte))) : byte (c@ p))' effects)"
  [[ "$result" == *"eff(f,semidet)"* ]]
}

@test "effects: ! is semidet" {
  result="$(compile '(def f ((p : (ptr int)) (v : int)) : void (! p v))' effects)"
  [[ "$result" == *"eff(f,semidet)"* ]]
}

@test "effects: c! is semidet" {
  result="$(compile '(def f ((p : (ptr byte)) (v : byte)) : void (c! p v))' effects)"
  [[ "$result" == *"eff(f,semidet)"* ]]
}

@test "effects: if/let/while stay det when pure" {
  result="$(compile '(def f ((n : int)) : int (if (< n 0) (- 0 n) n))' effects)"
  [[ "$result" == *"eff(f,det)"* ]]
}

@test "effects: call propagates callee effect" {
  result="$(compile '(def pure ((x : int)) : int (+ x 1)) (def impure () : void (emit (pure 5)))' effects)"
  [[ "$result" == *"eff(pure,det)"* ]]
  [[ "$result" == *"eff(impure,nondet)"* ]]
}

@test "effects: semidet caller of det callee stays semidet" {
  result="$(compile '(def inc ((x : int)) : int (+ x 1)) (def f ((p : (ptr int))) : void (! p (inc 5)))' effects)"
  [[ "$result" == *"eff(inc,det)"* ]]
  [[ "$result" == *"eff(f,semidet)"* ]]
}

@test "effects: transitive nondet through call chain" {
  result="$(compile '(def a () : void (emit 65)) (def b () : void (a)) (def c () : void (b))' effects)"
  [[ "$result" == *"eff(a,nondet)"* ]]
  [[ "$result" == *"eff(b,nondet)"* ]]
  [[ "$result" == *"eff(c,nondet)"* ]]
}

@test "effects: addr is det" {
  result="$(compile '(def f () : int (addr f))' effects)"
  [[ "$result" == *"eff(f,det)"* ]]
}

@test "effects: execute is nondet" {
  result="$(compile '(def f ((p : int)) : void (execute p))' effects)"
  [[ "$result" == *"eff(f,nondet)"* ]]
}

@test "effects: do block joins children" {
  result="$(compile '(def f ((p : (ptr int))) : int (do (! p 1) (@ p)))' effects)"
  [[ "$result" == *"eff(f,semidet)"* ]]
}

@test "effects: while with semidet body is semidet" {
  result="$(compile '(const I int 1024) (def f () : void (while (< (@ I) 10) (! I (+ (@ I) 1))))' effects)"
  [[ "$result" == *"eff(f,semidet)"* ]]
}

# ============================================================
# effects: annotations
# ============================================================

@test "effects annotation: det accepted on pure fn" {
  result="$(compile '(def f ((x : int)) : int [det] (+ x 1))' effects)"
  [[ "$result" == ok* ]]
}

@test "effects annotation: semidet accepted on memory fn" {
  result="$(compile '(def f ((p : (ptr int))) : int [semidet] (@ p))' effects)"
  [[ "$result" == ok* ]]
}

@test "effects annotation: nondet accepted on io fn" {
  result="$(compile '(def f () : void [nondet] (emit 65))' effects)"
  [[ "$result" == ok* ]]
}

@test "effects annotation: nondet accepted on det fn (overapprox)" {
  result="$(compile '(def f ((x : int)) : int [nondet] (+ x 1))' effects)"
  [[ "$result" == ok* ]]
}

@test "effects annotation rejects: det on nondet fn" {
  result="$(compile '(def f () : void [det] (emit 65))' binary)"
  [[ "$result" == *"declared [det] but inferred nondet"* ]]
}

@test "effects annotation rejects: det on semidet fn" {
  result="$(compile '(def f ((p : (ptr int))) : int [det] (@ p))' binary)"
  [[ "$result" == *"declared [det] but inferred semidet"* ]]
}

@test "effects annotation rejects: semidet on nondet fn" {
  result="$(compile '(def f () : void [semidet] (emit 65))' binary)"
  [[ "$result" == *"declared [semidet] but inferred nondet"* ]]
}

@test "effects annotation: unannotated fn still compiles" {
  result="$(compile '(def main () : void (emit 65) (bye))' binary)"
  [[ "$result" == ok* ]]
}

@test "effects annotation rejects: det on !" {
  result="$(compile '(def f ((p : (ptr int))) : void [det] (! p 1))' binary)"
  [[ "$result" == *"declared [det] but inferred semidet"* ]]
}

@test "effects annotation rejects: det on c!" {
  result="$(compile '(def f ((p : (ptr byte))) : void [det] (c! p 0))' binary)"
  [[ "$result" == *"declared [det] but inferred semidet"* ]]
}

@test "effects annotation rejects: det on c@" {
  result="$(compile '(def f ((p : (ptr byte))) : byte [det] (c@ p))' binary)"
  [[ "$result" == *"declared [det] but inferred semidet"* ]]
}

@test "effects annotation rejects: det on key" {
  result="$(compile '(def f () : int [det] (key))' binary)"
  [[ "$result" == *"declared [det] but inferred nondet"* ]]
}

@test "effects annotation rejects: semidet on key" {
  result="$(compile '(def f () : int [semidet] (key))' binary)"
  [[ "$result" == *"declared [semidet] but inferred nondet"* ]]
}

@test "effects annotation rejects: semidet on bye" {
  result="$(compile '(def f () : void [semidet] (bye))' binary)"
  [[ "$result" == *"declared [semidet] but inferred nondet"* ]]
}

@test "effects annotation rejects: det on execute" {
  result="$(compile '(def f ((p : int)) : void [det] (execute p))' binary)"
  [[ "$result" == *"declared [det] but inferred nondet"* ]]
}

@test "effects annotation rejects: transitive nondet via call" {
  result="$(compile '(def io () : void (emit 65)) (def f () : void [det] (io))' binary)"
  [[ "$result" == *"declared [det] but inferred nondet"* ]]
}

@test "effects annotation rejects: transitive semidet via call" {
  result="$(compile '(const P int 1024) (def rd () : int (@ P)) (def f () : int [det] (rd))' binary)"
  [[ "$result" == *"declared [det] but inferred semidet"* ]]
}

@test "effects annotation: correct fn compiles despite wrong sibling" {
  result="$(compile '(def good () : int [det] (+ 1 2)) (def bad () : void [det] (emit 65))' binary)"
  [[ "$result" == *"bad"*"declared [det] but inferred nondet"* ]]
  [[ "$result" != *"good"*"declared"* ]]
}

# ============================================================
# dead code warnings
# ============================================================

@test "deadcode: warns on unused function" {
  warnings="$(compile_warnings '(def unused () : int 42) (def main () : void (emit 65) (bye))')"
  [[ "$warnings" == *"unused function"*"unused"* ]]
}

@test "deadcode: no warning when function is called" {
  warnings="$(compile_warnings '(def helper () : int 42) (def main () : void (emit (helper)) (bye))')"
  [[ "$warnings" != *"unused function"* ]]
}

@test "deadcode: no warning for main" {
  warnings="$(compile_warnings '(def main () : void (emit 65) (bye))')"
  [[ -z "$warnings" ]]
}

@test "deadcode: warns multiple unused functions" {
  warnings="$(compile_warnings '(def a () : int 1) (def b () : int 2) (def main () : void (emit 65) (bye))')"
  [[ "$warnings" == *"unused function"*"a"* ]]
  [[ "$warnings" == *"unused function"*"b"* ]]
}

@test "deadcode: addr counts as reference" {
  warnings="$(compile_warnings '(def target () : void (emit 65)) (def main () : void (execute (addr target)) (bye))')"
  [[ -z "$warnings" ]]
}

@test "deadcode: warns on unused const" {
  warnings="$(compile_warnings '(const UNUSED int 42) (def main () : void (emit 65) (bye))')"
  [[ "$warnings" == *"unused const"*"UNUSED"* ]]
}

@test "deadcode: no warning when const is used" {
  warnings="$(compile_warnings '(const N int 65) (def main () : void (emit N) (bye))')"
  [[ "$warnings" != *"unused const"* ]]
}

@test "deadcode: warns on unused extern" {
  warnings="$(compile_warnings '(extern noop 10 () : void) (def main () : void (emit 65) (bye))')"
  [[ "$warnings" == *"unused extern"*"noop"* ]]
}

@test "deadcode: no warning when extern is used" {
  warnings="$(compile_warnings '(extern noop 10 () : void) (def main () : void (noop) (bye))')"
  [[ "$warnings" != *"unused extern"* ]]
}

# ============================================================
# constant folding
# ============================================================

@test "constfold: det call with constants is folded" {
  result="$(compile '(def double ((x : int)) : int (+ x x)) (def main () : void (emit (double 33)) (bye))' ir)"
  # double(33) should be folded to lit(66), no call to double
  [[ "$result" == *"lit(66)"* ]]
  [[ "$result" != *"call"* ]]
}

@test "constfold: folded program runs correctly" {
  run run_program '(def double ((x : int)) : int (+ x x)) (def main () : void (emit (double 33)) (bye))'
  [ "$output" = "B" ]
}

@test "constfold: binop with two constants is folded" {
  result="$(compile '(def main () : void (emit (+ 60 5)) (bye))' ir)"
  [[ "$result" == *"lit(65)"* ]]
}

@test "constfold: nested det calls folded" {
  result="$(compile '(def inc ((x : int)) : int (+ x 1)) (def add2 ((x : int)) : int (inc (inc x))) (def main () : void (emit (add2 63)) (bye))' ir)"
  [[ "$result" == *"lit(65)"* ]]
}

@test "constfold: nested det calls run correctly" {
  run run_program '(def inc ((x : int)) : int (+ x 1)) (def add2 ((x : int)) : int (inc (inc x))) (def main () : void (emit (add2 63)) (bye))'
  [ "$output" = "A" ]
}

@test "constfold: nondet function not folded" {
  result="$(compile '(def f () : void (emit 65)) (def main () : void (f) (bye))' ir)"
  # f() has side effects, should remain as a call
  [[ "$result" == *"label(f)"* ]]
}

@test "constfold: semidet function not folded" {
  result="$(compile '(const P int 1024) (def f () : int (@ P)) (def main () : void (emit (f)) (bye))' ir)"
  # @ is semidet, should not be folded
  [[ "$result" == *"label(f)"* ]]
}

@test "constfold: if with constant condition folded" {
  result="$(compile '(def main () : void (emit (if (< 1 2) 65 66)) (bye))' ir)"
  [[ "$result" == *"lit(65)"* ]]
}

@test "constfold: det with non-constant arg not folded" {
  result="$(compile '(def inc ((x : int)) : int (+ x 1)) (def main ((n : int)) : void (emit (inc n)) (bye))' ir)"
  # n is a variable, can not fold
  [[ "$result" == *"label(inc)"* ]]
}

@test "constfold: variadic det function not folded" {
  # a variadic function can infer as det (no memory ops) and get called
  # with all-literal args — bind_params only handles fixed params, so
  # this must not be attempted as a fold, just compiled as a normal call
  result="$(compile '(def h ((first : int) (rest : int ...)) : int first) (def main () : void (emit (h 1 2 3)) (bye))' ir)"
  [[ "$result" == *"label(h)"* ]]
}
