:- module(codegen, [compile_program/3]).

:- use_module(library(lists)).

:- dynamic(user_void_func/1).
:- dynamic(ext_trap/3). % ext_trap(Name, Code, Ret)

%% ============================================================
%% entry
%% ============================================================

compile_program(Defs, SlotBase, ok(Code)) :-
    collect_consts(Defs, Consts),
    register_void_funcs(Defs),
    register_ext_traps(Defs),
    %% Align SlotBase to next even boundary (slots are 2 bytes)
    SlotBase0 is SlotBase + (SlotBase mod 2),
    %% Ensure slots start above 16384 minimum even without $alloc globals
    SlotStart is max(SlotBase0, 16384),
    compile_defs(Defs, Consts, 0, SlotStart, Code).

register_void_funcs(Defs) :-
    retractall(user_void_func(_)),
    register_void_funcs_(Defs).

register_void_funcs_([]).
register_void_funcs_([Def | Rest]) :-
    ( Def = def(Name, _, void, _, _) ->
        assertz(user_void_func(Name))
    ;
        true
    ),
    register_void_funcs_(Rest).

register_ext_traps(Defs) :-
    retractall(ext_trap(_, _, _)),
    register_ext_traps_(Defs).

register_ext_traps_([]).
register_ext_traps_([extern(Name, Code, _, Ret) | Rest]) :-
    assertz(ext_trap(Name, Code, Ret)),
    register_ext_traps_(Rest).
register_ext_traps_([_ | Rest]) :-
    register_ext_traps_(Rest).

%% ============================================================
%% collect top-level constants for inlining
%% ============================================================

collect_consts([], []).
collect_consts([const(Name, _, num(V)) | Rest], [const(Name, V) | Cs]) :-
    collect_consts(Rest, Cs).
collect_consts([_ | Rest], Cs) :-
    collect_consts(Rest, Cs).

%% ============================================================
%% compile definitions
%% ============================================================

compile_defs([], _, _, _, []).
compile_defs([Def | Rest], Consts, LN0, Slot0, Code) :-
    compile_def(Def, Consts, LN0, Slot0, DefCode, LN1, Slot1),
    compile_defs(Rest, Consts, LN1, Slot1, RestCode),
    append(DefCode, RestCode, Code).

compile_def(extern(_, _, _), _, LN, Slot, [], LN, Slot).
compile_def(extern(_, _, _, _), _, LN, Slot, [], LN, Slot).
compile_def(const(_, _, _), _, LN, Slot, [], LN, Slot).

compile_def(def(Name, Params, _RetType, _, Body), Consts, LN0, Slot0, Code, LN, SlotAfter) :-
    alloc_params(Params, Slot0, ParamEnv, SlotParams),
    reverse(ParamEnv, RevParams),
    prologue(RevParams, PrologueCode),
    compile_body(Body, ParamEnv, Consts, LN0, 0, BodyCode, LN),
    append(PrologueCode, BodyCode, InnerCode),
    append([label(Name) | InnerCode], [op(ret)], Code),
    SlotAfter is SlotParams.

alloc_params([], Slot, [], Slot).
alloc_params([param(Name, _Type) | Rest], Slot, [var(Name, Slot) | Env], SlotOut) :-
    Slot1 is Slot + 2,
    alloc_params(Rest, Slot1, Env, SlotOut).

prologue([], []).
prologue([var(_, Addr) | Rest], Code) :-
    prologue(Rest, RestCode),
    append([lit(Addr), op(!)], RestCode, Code).

%% ============================================================
%% body: list of exprs; middle ones drop result, last keeps it
%% ============================================================

compile_body([], _, _, LN, _, [], LN).
compile_body([E], Env, Consts, LN0, RD, Code, LN) :-
    compile_expr(E, Env, Consts, LN0, RD, Code, LN).
compile_body([E | Rest], Env, Consts, LN0, RD, Code, LN) :-
    Rest = [_|_],
    compile_expr(E, Env, Consts, LN0, RD, ECode, LN1),
    ( void_expr(E) -> DropCode = [] ; DropCode = [op(drop)] ),
    compile_body(Rest, Env, Consts, LN1, RD, RestCode, LN),
    append(ECode, DropCode, ECodeD),
    append(ECodeD, RestCode, Code).

void_expr(store(_, _)).
void_expr(store8(_, _)).
void_expr(while(_, _)).
void_expr(execute(_)).
void_expr(call(Name, _)) :- builtin_trap(Name, void, _).
void_expr(call(Name, _)) :- user_void_func(Name).
void_expr(let(_, Body)) :- last_void(Body).
void_expr(do(Exprs)) :- last_void(Exprs).
void_expr(if(_, T, E)) :- void_expr(T), void_expr(E).

last_void([E]) :- void_expr(E).
last_void([_|Rest]) :- Rest = [_|_], last_void(Rest).

%% ============================================================
%% expressions
%% ============================================================

%% literal
compile_expr(num(N), _, _, LN, _, [lit(N)], LN).

%% string literal: branch over inline data, push address
compile_expr(str(Chars), _, _, LN0, _, Code, LN) :-
    genlabel(LN0, "_sdata_", DataL, LN1),
    genlabel(LN1, "_send_", EndL, LN2),
    LN = LN2,
    chars_to_bytes(Chars, DataBytes),
    append(DataBytes, [byte(0)], DataWithNull),
    append([branch(EndL), label(DataL) | DataWithNull],
           [label(EndL), lit_label(DataL)], Code).

%% variable: load from rack slot or memory slot
compile_expr(var(Name), Env, Consts, LN, RD, Code, LN) :-
    ( member(rvar(Name, Pos), Env) ->
        Depth is RD - 1 - Pos,
        Code = [rpick(Depth)]
    ; member(var(Name, Addr), Env) ->
        Code = [lit(Addr), op(@)]
    ; member(const(Name, V), Consts) ->
        Code = [lit(V)]
    ).

%% binop
compile_expr(binop(Op, A, B), Env, Consts, LN0, RD, Code, LN) :-
    compile_expr(A, Env, Consts, LN0, RD, ACode, LN1),
    compile_expr(B, Env, Consts, LN1, RD, BCode, LN),
    op_to_vm(Op, VmOps),
    append(ACode, BCode, ABCode),
    append(ABCode, VmOps, Code).

%% if
compile_expr(if(Cond, Then, Else), Env, Consts, LN0, RD, Code, LN) :-
    genlabel(LN0, "_else_", ElseL, LN1),
    genlabel(LN1, "_endif_", EndL, LN2),
    compile_expr(Cond, Env, Consts, LN2, RD, CC, LN3),
    compile_expr(Then, Env, Consts, LN3, RD, TC, LN4),
    compile_expr(Else, Env, Consts, LN4, RD, EC, LN),
    append(CC, [zbranch(ElseL)], C1),
    append(C1, TC, C2),
    append(C2, [branch(EndL), label(ElseL)], C3),
    append(C3, EC, C4),
    append(C4, [label(EndL)], Code).

%% let
compile_expr(let(Bindings, Body), Env, Consts, LN0, RD0, Code, LN) :-
    compile_let(Bindings, Env, Consts, LN0, RD0, BindCode, ExtEnv, LN1, RD1),
    compile_body(Body, ExtEnv, Consts, LN1, RD1, BodyCode, LN),
    N is RD1 - RD0,
    gen_cleanup(N, CleanupCode),
    append(BindCode, BodyCode, BC),
    append(BC, CleanupCode, Code).

%% do
compile_expr(do(Exprs), Env, Consts, LN0, RD, Code, LN) :-
    compile_body(Exprs, Env, Consts, LN0, RD, Code, LN).

%% while
compile_expr(while(Cond, Body), Env, Consts, LN0, RD, Code, LN) :-
    genlabel(LN0, "_wstart_", StartL, LN1),
    genlabel(LN1, "_wend_", EndL, LN2),
    compile_expr(Cond, Env, Consts, LN2, RD, CC, LN3),
    compile_body(Body, Env, Consts, LN3, RD, BC, LN),
    append([label(StartL) | CC], [zbranch(EndL)], C1),
    append(C1, BC, C2),
    append(C2, [branch(StartL), label(EndL)], Code).

%% deref
compile_expr(deref(E), Env, Consts, LN0, RD, Code, LN) :-
    compile_expr(E, Env, Consts, LN0, RD, EC, LN),
    append(EC, [op(@)], Code).

%% deref8 — byte-level read
compile_expr(deref8(E), Env, Consts, LN0, RD, Code, LN) :-
    compile_expr(E, Env, Consts, LN0, RD, EC, LN),
    append(EC, [op('c@')], Code).

%% store
compile_expr(store(Addr, Val), Env, Consts, LN0, RD, Code, LN) :-
    compile_expr(Val, Env, Consts, LN0, RD, VC, LN1),
    compile_expr(Addr, Env, Consts, LN1, RD, AC, LN),
    append(VC, AC, C1),
    append(C1, [op(!)], Code).

%% store8
compile_expr(store8(Addr, Val), Env, Consts, LN0, RD, Code, LN) :-
    compile_expr(Val, Env, Consts, LN0, RD, VC, LN1),
    compile_expr(Addr, Env, Consts, LN1, RD, AC, LN),
    append(VC, AC, C1),
    append(C1, [op('c!')], Code).

%% {op ...} — inline VM ops
compile_expr(inline(Ops), _, _, LN, _, Code, LN) :-
    ops_to_vm(Ops, Code).

%% addr — push function address
compile_expr(addr(Name), _, _, LN, _, [lit_label(Name)], LN).

%% execute — indirect call via address on stack
compile_expr(execute(E), Env, Consts, LN0, RD, Code, LN) :-
    compile_expr(E, Env, Consts, LN0, RD, EC, LN),
    append(EC, [op(execute)], Code).

%% function call
compile_expr(call(Name, Args), Env, Consts, LN0, RD, Code, LN) :-
    compile_args(Args, Env, Consts, LN0, RD, ArgsCode, LN),
    ( builtin_trap(Name, _, TrapCode) ->
        append(ArgsCode, TrapCode, Code)
    ;
        append(ArgsCode, [call(Name)], Code)
    ).

%% ============================================================
%% helpers
%% ============================================================

ops_to_vm([], []).
ops_to_vm([Op|Ops], [op(Op)|Code]) :-
    ops_to_vm(Ops, Code).

compile_args([], _, _, LN, _, [], LN).
compile_args([A | As], Env, Consts, LN0, RD, Code, LN) :-
    compile_expr(A, Env, Consts, LN0, RD, AC, LN1),
    compile_args(As, Env, Consts, LN1, RD, RestCode, LN),
    append(AC, RestCode, Code).

%% let bindings go onto the rack via >r; access via rpick(depth)
compile_let([], Env, _, LN, RD, [], Env, LN, RD).
compile_let([bind(Name, Expr) | Rest], Env, Consts, LN0, RD0, Code, ExtEnv, LN, RD) :-
    compile_expr(Expr, Env, Consts, LN0, RD0, ExprCode, LN1),
    Pos is RD0,
    RD1 is RD0 + 1,
    NewEnv = [rvar(Name, Pos) | Env],
    compile_let(Rest, NewEnv, Consts, LN1, RD1, RestCode, ExtEnv, LN, RD),
    append(ExprCode, [op('>r') | RestCode], Code).

gen_cleanup(0, []).
gen_cleanup(N, [op('r>'), op(drop) | Rest]) :-
    N > 0, N1 is N - 1, gen_cleanup(N1, Rest).

chars_to_bytes([], []).
chars_to_bytes([C|Cs], [byte(B)|Bs]) :-
    char_code(C, B),
    chars_to_bytes(Cs, Bs).

genlabel(N, Prefix, Label, N1) :-
    N1 is N + 1,
    number_chars(N, NChars),
    append(Prefix, NChars, LabelChars),
    atom_chars(Label, LabelChars).

%% Map source ops to VM instruction sequences
op_to_vm(+, [op(+)]).
op_to_vm(-, [op(-)]).
op_to_vm(*, [op(*)]).
op_to_vm(/, [op('/')]).
op_to_vm(mod, [op(mod)]).
op_to_vm(and, [op(and)]).
op_to_vm(or, [op(or)]).
op_to_vm(xor, [op(xor)]).
op_to_vm(=, [op(=)]).
op_to_vm(<, [op(<)]).
%% > : swap then <
op_to_vm(>, [op(swap), op(<)]).
%% != : = then logical invert (0= -> swap truth)
%% invert bool: lit 0 =  (if TOS was 0 -> -1, if TOS was -1 -> 0)
op_to_vm('!=', [op(=), lit(0), op(=)]).
%% <= : > then invert
op_to_vm(<=, [op(swap), op(<), lit(0), op(=)]).
%% >= : < then invert
op_to_vm(>=, [op(<), lit(0), op(=)]).

%% Built-in trap functions (from gen/gen.pl)
:- use_module('../gen/gen').

builtin_trap(Name, Ret, [lit(Code), op(trap)]) :-
    gen:trap_type(Name, Code, _, Ret).
builtin_trap(Name, Ret, [lit(Code), op(trap)]) :-
    ext_trap(Name, Code, Ret).

%% ============================================================
%% tests
%% ============================================================

:- use_module(parser).
:- use_module(ast).
:- use_module(typecheck).

codegen_pipeline(Src, Result) :-
    parse(Src, ok(Forms)),
    transform_program(Forms, ok(Defs)),
    check_program(Defs, ok(_)),
    compile_program(Defs, 0, Result).

?- codegen_pipeline("(def main () : void (emit 65) (bye))", ok(_)).
   true.

?- codegen_pipeline("(def main () : void (emit (+ 60 5)) (bye))", ok(_)).
   true.

?- codegen_pipeline("(def main () : void (emit (if (< 1 2) 65 66)) (bye))", ok(_)).
   true.

?- codegen_pipeline("(def main () : void (let ((x 65)) (emit x)) (bye))", ok(_)).
   true.

?- codegen_pipeline("(def add1 ((n : int)) : int (+ n 1)) (def main () : void (emit (add1 64)) (bye))", ok(Tokens)),
   member(label(main), Tokens), member(label(add1), Tokens).
   true.
