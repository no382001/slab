:- module(ast, [transform/2, transform_program/2]).

:- use_module(library(lists)).
:- use_module(builder).

%% transform_program(+Forms, -Result)
%% Result = ok(Defs) | error(Msg)
transform_program(Forms, Result) :-
    ( maplist(transform, Forms, Defs) ->
        Result = ok(Defs)
    ;
        Result = error(ast_transform_failed)
    ).

%% ============================================================
%% top-level forms
%% ============================================================

%% (def name (params...) : ret-type [effect] body)
transform(list([sym(def), sym(Name), list(RawParams), sym(:), RetTy | BodyForms]),
          Result) :-
    maplist(transform_param, RawParams, Params),
    valid_param_list(Params),
    transform_type(RetTy, RetType),
    parse_optional_effect(BodyForms, DeclEffect, ActualBody),
    maplist(transform, ActualBody, Body),
    builder:mk_def(Name, Params, RetType, DeclEffect, Body, Result).

%% (extern name (param-types...) : ret-type)
transform(list([sym(extern), sym(Name), list(RawParamTypes), sym(:), RetTy]),
          Result) :-
    maplist(transform_type, RawParamTypes, ParamTypes),
    transform_type(RetTy, RetType),
    builder:mk_extern(Name, ParamTypes, RetType, Result).

%% (extern name code (param-types...) : ret-type)  — extension trap with explicit code
transform(list([sym(extern), sym(Name), num(Code), list(RawParamTypes), sym(:), RetTy]),
          Result) :-
    maplist(transform_type, RawParamTypes, ParamTypes),
    transform_type(RetTy, RetType),
    builder:mk_extern(Name, Code, ParamTypes, RetType, Result).

%% (const name type value)
transform(list([sym(const), sym(Name), TypeSym, ValForm]),
          Result) :-
    transform_type(TypeSym, Type),
    transform(ValForm, Val),
    builder:mk_const(Name, Type, Val, Result).

%% ============================================================
%% expressions
%% ============================================================

%% literals
transform(num(N), Result) :- builder:mk_num(N, Result).
transform(str(S), Result) :- builder:mk_str(S, Result).
transform(sym(S), Result) :- builder:mk_var(S, Result).

%% (if cond then else)
transform(list([sym(if), Cond, Then, Else]),
          Result) :-
    transform(Cond, CondE),
    transform(Then, ThenE),
    transform(Else, ElseE),
    builder:mk_if(CondE, ThenE, ElseE, Result).

%% (let ((name expr) ...) body...)
transform(list([sym(let), list(Bindings) | BodyForms]),
          Result) :-
    maplist(transform_binding, Bindings, TransBindings),
    maplist(transform, BodyForms, Body),
    builder:mk_let(TransBindings, Body, Result).

%% (local ((name expr) ...) body...)
transform(list([sym(local), list(Bindings) | BodyForms]),
          Result) :-
    maplist(transform_binding, Bindings, TransBindings),
    maplist(transform, BodyForms, Body),
    builder:mk_local(TransBindings, Body, Result).

%% (do expr...)  — sequence, returns last
transform(list([sym(do) | Forms]),
          Result) :-
    maplist(transform, Forms, Exprs),
    builder:mk_do(Exprs, Result).

%% (addr name) — address of a function
transform(list([sym(addr), sym(Name)]), Result) :- builder:mk_addr(Name, Result).

%% (execute expr) — indirect call via address
transform(list([sym(execute), E]), Result) :-
    transform(E, TE),
    builder:mk_execute(TE, Result).

%% (@ expr) — @ cell
transform(list([sym(@), E]), Result) :-
    transform(E, TE),
    builder:mk_deref(TE, Result).

%% (c@ expr) — @ byte
transform(list([sym('c@'), E]), Result) :-
    transform(E, TE),
    builder:mk_cderef(TE, Result).

%% (! addr val) — ! cell
transform(list([sym(!), A, V]), Result) :-
    transform(A, TA),
    transform(V, TV),
    builder:mk_store(TA, TV, Result).

%% (c! addr val) — ! byte
transform(list([sym('c!'), A, V]), Result) :-
    transform(A, TA),
    transform(V, TV),
    builder:mk_cstore(TA, TV, Result).

%% (while cond body...)
transform(list([sym(while), Cond | BodyForms]),
          Result) :-
    transform(Cond, CondE),
    maplist(transform, BodyForms, Body),
    builder:mk_while(CondE, Body, Result).

%% binary operators
transform(list([sym(Op), A, B]), Result) :-
    binop(Op),
    transform(A, TA),
    transform(B, TB),
    builder:mk_binop(Op, TA, TB, Result).

%% {op op ...} — inline VM ops, bypasses type system
transform(asm(Syms), Result) :-
    syms_to_names(Syms, Ops),
    builder:mk_inline_asm(Ops, Result).

%% function call (anything else that's a list with a sym head)
transform(list([sym(Name) | Args]), Result) :-
    \+ reserved(Name),
    maplist(transform, Args, TArgs),
    builder:mk_call(Name, TArgs, Result).

%% ============================================================
%% helpers
%% ============================================================

transform_param(sym(Name), Result) :- builder:mk_param(Name, int, Result).  % default type for now
transform_param(list([sym(Name), sym(:), TypeSym]), Result) :-
    transform_type(TypeSym, Type),
    builder:mk_param(Name, Type, Result).
transform_param(list([sym(Name), sym(:), TypeSym, sym('...')]),
                 Result) :-
    transform_type(TypeSym, Type),
    builder:mk_rest_param(Name, Type, Result).

valid_param_list([]).
valid_param_list([param(_, _)]).
valid_param_list([rest_param(_, _)]).
valid_param_list([param(_, _) | Rest]) :-
    Rest = [_|_],
    valid_param_list(Rest).

transform_binding(list([sym(Name), Expr]), Result) :-
    transform(Expr, TE),
    builder:mk_bind(Name, TE, Result).

%% parse optional effect annotation from body forms
%% [level], [level inline], or [inline level] (order doesn't matter)
parse_optional_effect([bracket(Syms) | Rest], DeclEffect, Rest) :-
    Rest \= [],
    effect_bracket_syms(Syms, DeclEffect), !.
parse_optional_effect(Body, none, Body).

effect_bracket_syms([sym(Level)], Level) :- effect_level_sym(Level).
effect_bracket_syms([sym(Level), sym(inline)], inline(Level)) :- effect_level_sym(Level).
effect_bracket_syms([sym(inline), sym(Level)], inline(Level)) :- effect_level_sym(Level).

effect_level_sym(det).
effect_level_sym(semidet).
effect_level_sym(nondet).

transform_type(sym(int), int).
transform_type(sym(byte), byte).
transform_type(sym(bool), bool).
transform_type(sym(void), void).
transform_type(list([sym(ptr), Inner]), Result) :-
    transform_type(Inner, T),
    builder:mk_type_ptr(T, Result).

binop(+). binop(-). binop(*). binop(/). binop(mod).
binop(and). binop(or). binop(xor).
binop(=). binop(<). binop(>).
binop('!='). binop(<=). binop(>=).

reserved(def). reserved(let). reserved(local). reserved(if). reserved(do).
reserved(while). reserved(const). reserved(extern).
reserved(@). reserved('c@'). reserved(!). reserved('c!').
reserved(addr). reserved(execute).
reserved('$include').

syms_to_names([], []).
syms_to_names([sym(S)|Rest], [S|Names]) :-
    syms_to_names(Rest, Names).
