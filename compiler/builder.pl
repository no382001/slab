:- module(builder, [
    mk_num/2, mk_str/2, mk_var/2,
    mk_if/4,
    mk_bind/3, mk_let/3, mk_local/3,
    mk_do/2, mk_while/3,
    mk_addr/2, mk_execute/2,
    mk_deref/2, mk_cderef/2, mk_store/3, mk_cstore/3,
    mk_binop/4, mk_call/3,
    mk_inline_asm/2,
    mk_param/3, mk_rest_param/3, mk_type_ptr/2,
    mk_effect/2, mk_effect_inline/2,
    mk_def/5, mk_def/6,
    mk_extern/4, mk_extern/5,
    mk_const/4
]).

%% NOTE: there is a mixed pattern currently, most passes build ast nodes on their own
%% but this will be useful for languages that compile to sets, so i want to use
%% this pattern wherever i can but i wont touch direct build sites

:- use_module(library(lists)).


%% ---- literals & variable references ----

mk_num(N, num(N)) :- number(N).
mk_str(S, str(S)).
mk_var(Name, var(Name)) :- atom(Name).

%% ---- control flow ----

mk_if(C, T, E, if(C, T, E)).
mk_do(Exprs, do(Exprs)) :- Exprs = [_|_].
mk_while(Cond, Body, while(Cond, Body)) :- Body = [_|_].

%% ---- bindings ----

mk_bind(Name, Expr, bind(Name, Expr)) :- atom(Name).
mk_let(Bindings, Body, let(Bindings, Body)) :- Body = [_|_].
mk_local(Bindings, Body, local(Bindings, Body)) :- Body = [_|_].

%% ---- memory / indirection ----

mk_deref(E, @(E)).
mk_cderef(E, 'c@'(E)).
mk_store(Addr, Val, !(Addr, Val)).
mk_cstore(Addr, Val, 'c!'(Addr, Val)).
mk_addr(Name, addr(Name)) :- atom(Name).
mk_execute(E, execute(E)).

%% ---- operators & calls ----

mk_binop(Op, A, B, binop(Op, A, B)) :-
    ( valid_binop(Op) -> true
    ; throw(builder_error(invalid_binop(Op)))
    ).

mk_call(Name, Args, call(Name, Args)) :- atom(Name), proper_list(Args).

valid_binop(+). valid_binop(-). valid_binop(*). valid_binop(/). valid_binop(mod).
valid_binop(and). valid_binop(or). valid_binop(xor).
valid_binop(=). valid_binop(<). valid_binop(>).
valid_binop('!='). valid_binop(<=). valid_binop(>=).

%% ---- inline VM asm: {op1 op2 ...} ----

mk_inline_asm(Ops, inline(Ops)) :- proper_list(Ops).

%% ---- params & types ----

mk_param(Name, Type, param(Name, Type)) :- atom(Name).
mk_rest_param(Name, Type, rest_param(Name, Type)) :- atom(Name).
mk_type_ptr(Inner, ptr(Inner)).

%% ---- effect declarations ----

mk_effect(Level, Level) :-
    ( valid_effect_level(Level) -> true
    ; throw(builder_error(invalid_effect_level(Level)))
    ).
mk_effect_inline(Level, inline(Level)) :-
    ( valid_effect_level(Level) -> true
    ; throw(builder_error(invalid_effect_level(Level)))
    ).

valid_effect_level(det). % TODO: should come from ast
valid_effect_level(semidet).
valid_effect_level(nondet).

%% ---- top-level forms ----

%% mk_def/5: no effect annotation (DeclEffect = none)
mk_def(Name, Params, RetType, Body, def(Name, Params, RetType, none, Body)) :-
    atom(Name), proper_list(Params), Body = [_|_].
%% mk_def/6: with an effect annotation (see mk_effect/mk_effect_inline)
mk_def(Name, Params, RetType, Effect, Body, def(Name, Params, RetType, Effect, Body)) :-
    atom(Name), proper_list(Params), Body = [_|_].

mk_extern(Name, ParamTypes, RetType, extern(Name, ParamTypes, RetType)) :-
    atom(Name), proper_list(ParamTypes).
mk_extern(Name, Code, ParamTypes, RetType, extern(Name, Code, ParamTypes, RetType)) :-
    atom(Name), integer(Code), proper_list(ParamTypes).

mk_const(Name, Type, Val, const(Name, Type, Val)) :- atom(Name).

%% ---- helpers ----

%% library(lists) here doesn't export is_list/1
%% TODO why is this here?
proper_list([]).
proper_list([_|T]) :- proper_list(T).
