:- module(codegen, [compile_program/3]).

:- use_module(library(lists)).

:- dynamic(user_void_func/1).
:- dynamic(ext_trap/3). % ext_trap(Name, Code, Ret)
:- dynamic(variadic_func/3). % variadic_func(Name, FixedArity, MaxRest)

%% ============================================================
%% entry
%% ============================================================

compile_program(Defs, SlotBase, ok(Code)) :-
    collect_consts(Defs, Consts),
    register_void_funcs(Defs),
    register_ext_traps(Defs),
    register_variadic_funcs(Defs),
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

register_variadic_funcs(Defs) :-
    retractall(variadic_func(_, _, _)),
    findall(Name-FixedArity, variadic_def_arity(Defs, Name, FixedArity), FixedList),
    all_calls_in_defs(Defs, AllCalls),
    register_variadic_funcs_(FixedList, AllCalls).

variadic_def_arity(Defs, Name, FixedArity) :-
    member(def(Name, Params, _, _, _), Defs),
    append(FixedParams, [rest_param(_, _)], Params),
    length(FixedParams, FixedArity).

register_variadic_funcs_([], _).
register_variadic_funcs_([Name-FixedArity | Rest], AllCalls) :-
    findall(RestCount,
            ( member(call(Name, Args), AllCalls),
              length(Args, TotalArgs),
              RestCount is TotalArgs - FixedArity,
              RestCount >= 0
            ),
            Counts),
    ( Counts = [] -> Max = 0 ; list_max(Counts, Max) ),
    assertz(variadic_func(Name, FixedArity, Max)),
    register_variadic_funcs_(Rest, AllCalls).

all_calls_in_defs([], []).
all_calls_in_defs([def(_, _, _, _, Body) | Rest], Calls) :-
    !,
    collect_calls_list(Body, C1),
    all_calls_in_defs(Rest, C2),
    append(C1, C2, Calls).
all_calls_in_defs([_ | Rest], Calls) :-
    all_calls_in_defs(Rest, Calls).

collect_calls(num(_), []).
collect_calls(str(_), []).
collect_calls(var(_), []).
collect_calls(addr(_), []).
collect_calls(inline(_), []).
collect_calls(binop(_, A, B), Calls) :-
    collect_calls(A, CA), collect_calls(B, CB), append(CA, CB, Calls).
collect_calls(if(C, T, E), Calls) :-
    collect_calls(C, CC), collect_calls(T, CT), collect_calls(E, CE),
    append(CC, CT, C1), append(C1, CE, Calls).
collect_calls(let(Bindings, Body), Calls) :-
    collect_calls_bindings(Bindings, CB),
    collect_calls_list(Body, CBody),
    append(CB, CBody, Calls).
collect_calls(do(Exprs), Calls) :- collect_calls_list(Exprs, Calls).
collect_calls(while(Cond, Body), Calls) :-
    collect_calls(Cond, CC), collect_calls_list(Body, CB), append(CC, CB, Calls).
collect_calls(@(E), Calls) :- collect_calls(E, Calls).
collect_calls('c@'(E), Calls) :- collect_calls(E, Calls).
collect_calls(!(A, V), Calls) :-
    collect_calls(A, CA), collect_calls(V, CV), append(CA, CV, Calls).
collect_calls('c!'(A, V), Calls) :-
    collect_calls(A, CA), collect_calls(V, CV), append(CA, CV, Calls).
collect_calls(execute(E), Calls) :- collect_calls(E, Calls).
collect_calls(call(Name, Args), [call(Name, Args) | Rest]) :-
    collect_calls_list(Args, Rest).

collect_calls_list([], []).
collect_calls_list([E | Es], Calls) :-
    collect_calls(E, CE), collect_calls_list(Es, CEs), append(CE, CEs, Calls).

collect_calls_bindings([], []).
collect_calls_bindings([bind(_, E) | Bs], Calls) :-
    collect_calls(E, CE), collect_calls_bindings(Bs, CBs), append(CE, CBs, Calls).

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
    alloc_params(Name, Params, Slot0, ParamEnv, RestInfo, SlotAfter),
    build_prologue(RestInfo, ParamEnv, Consts, LN0, PrologueCode, LN1),
    compile_body(Body, ParamEnv, Consts, LN1, 0, BodyCode, LN),
    append(PrologueCode, BodyCode, InnerCode),
    append([label(Name) | InnerCode], [op(ret)], Code).

alloc_params(Name, Params, Slot, Env, RestInfo, SlotOut) :-
    ( append(FixedParams, [rest_param(RName, _RType)], Params) ->
        variadic_func(Name, _FixedArity, Max),
        alloc_fixed_params(FixedParams, Slot, FixedEnv, Slot1),
        rest_count_name(RName, CountName),
        CountSlot = Slot1,
        RestSlot is Slot1 + 2,
        RestBase is RestSlot + 2,
        IterSlot is RestBase + (Max * 2),
        SlotOut is IterSlot + 2,
        Env = [var(RName, RestSlot), var(CountName, CountSlot) | FixedEnv],
        RestInfo = rest(CountSlot, RestSlot, RestBase, IterSlot)
    ;
        alloc_fixed_params(Params, Slot, Env, SlotOut),
        RestInfo = none
    ).

alloc_fixed_params([], Slot, [], Slot).
alloc_fixed_params([param(Name, _Type) | Rest], Slot, [var(Name, Slot) | Env], SlotOut) :-
    Slot1 is Slot + 2,
    alloc_fixed_params(Rest, Slot1, Env, SlotOut).

rest_count_name(Name, CountName) :- atom_concat(Name, '-count', CountName).

build_prologue(none, ParamEnv, _Consts, LN, Code, LN) :-
    reverse(ParamEnv, RevParams),
    prologue(RevParams, Code).
build_prologue(rest(CountSlot, RestSlot, RestBase, IterSlot), ParamEnv, Consts, LN0, Code, LN) :-
    ParamEnv = [_, _ | FixedEnv],
    reverse(FixedEnv, RevFixed),
    prologue(RevFixed, FixedPrologueCode),
    rest_prologue(CountSlot, RestSlot, RestBase, IterSlot, Consts, LN0, RestPrologueCode, LN),
    append(RestPrologueCode, FixedPrologueCode, Code).

prologue([], []).
prologue([var(_, Addr) | Rest], Code) :-
    prologue(Rest, RestCode),
    append([lit(Addr), op(!)], RestCode, Code).

rest_prologue(CountSlot, RestSlot, RestBase, IterSlot, Consts, LN0, Code, LN) :-
    LoopConsts = [const(rest_iter_sym, IterSlot),
                  const(rest_base_sym, RestBase),
                  const(rest_count_sym, CountSlot)],
    append(LoopConsts, Consts, ExtConsts),
    PopCount = [lit(CountSlot), op(!)],
    BindRestPtr = [lit(RestBase), lit(RestSlot), op(!)],
    InitIter = !(var(rest_iter_sym), binop(-, @(var(rest_count_sym)), num(1))),
    compile_expr(InitIter, [], ExtConsts, LN0, 0, InitIterCode, LN1),
    Cond = binop(>=, @(var(rest_iter_sym)), num(0)),
    compile_expr(Cond, [], ExtConsts, LN1, 0, CondCode, LN2),
    AddrExpr = binop(+, var(rest_base_sym), binop(*, @(var(rest_iter_sym)), num(2))),
    compile_expr(AddrExpr, [], ExtConsts, LN2, 0, AddrCode, LN3),
    Decr = !(var(rest_iter_sym), binop(-, @(var(rest_iter_sym)), num(1))),
    compile_expr(Decr, [], ExtConsts, LN3, 0, DecrCode, LN4),
    genlabel(LN4, "_restpop_", StartL, LN5),
    genlabel(LN5, "_restend_", EndL, LN),
    append(AddrCode, [op(!)], StoreCode),
    append(StoreCode, DecrCode, LoopBody),
    append([label(StartL) | CondCode], [zbranch(EndL)], C1),
    append(C1, LoopBody, C2),
    append(C2, [branch(StartL), label(EndL)], LoopCode),
    append(PopCount, BindRestPtr, C3),
    append(C3, InitIterCode, C4),
    append(C4, LoopCode, Code).

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

void_expr(Expr) :- Expr =.. [Op, _, _], member(Op, [!, 'c!']).
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

%% variable: @ from rack slot or memory slot
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

%% load: @ and 'c@' — op name is the functor
compile_expr(Expr, Env, Consts, LN0, RD, Code, LN) :-
    Expr =.. [Op, E],
    member(Op, [@, 'c@']),
    compile_expr(E, Env, Consts, LN0, RD, EC, LN),
    append(EC, [op(Op)], Code).

%% store: ! and 'c!' — op name is the functor
compile_expr(Expr, Env, Consts, LN0, RD, Code, LN) :-
    Expr =.. [Op, Addr, Val],
    member(Op, [!, 'c!']),
    compile_expr(Val, Env, Consts, LN0, RD, VC, LN1),
    compile_expr(Addr, Env, Consts, LN1, RD, AC, LN),
    append(VC, AC, C1),
    append(C1, [op(Op)], Code).

%% {op ...} — inline VM ops
compile_expr(inline(Ops), _, _, LN, _, Code, LN) :-
    ops_to_vm(Ops, Code).

%% addr — push function address
compile_expr(addr(Name), _, _, LN, _, [lit_label(Name)], LN).

%% execute — indirect call via address on stack
compile_expr(execute(E), Env, Consts, LN0, RD, Code, LN) :-
    compile_expr(E, Env, Consts, LN0, RD, EC, LN),
    append(EC, [op(execute)], Code).

%% function call — variadic
compile_expr(call(Name, Args), Env, Consts, LN0, RD, Code, LN) :-
    variadic_func(Name, FixedArity, _Max), !,
    compile_args(Args, Env, Consts, LN0, RD, ArgsCode, LN),
    length(Args, TotalArgs),
    RestCount is TotalArgs - FixedArity,
    append(ArgsCode, [lit(RestCount), call(Name)], Code).

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
