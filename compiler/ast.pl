:- module(ast, [transform/2, transform_program/2]).

:- use_module(library(lists)).

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
          def(Name, Params, RetType, DeclEffect, Body)) :-
    maplist(transform_param, RawParams, Params),
    valid_param_list(Params),
    transform_type(RetTy, RetType),
    parse_optional_effect(BodyForms, DeclEffect, ActualBody),
    maplist(transform, ActualBody, Body).

%% (extern name (param-types...) : ret-type)
transform(list([sym(extern), sym(Name), list(RawParamTypes), sym(:), RetTy]),
          extern(Name, ParamTypes, RetType)) :-
    maplist(transform_type, RawParamTypes, ParamTypes),
    transform_type(RetTy, RetType).

%% (extern name code (param-types...) : ret-type)  — extension trap with explicit code
transform(list([sym(extern), sym(Name), num(Code), list(RawParamTypes), sym(:), RetTy]),
          extern(Name, Code, ParamTypes, RetType)) :-
    maplist(transform_type, RawParamTypes, ParamTypes),
    transform_type(RetTy, RetType).

%% (const name type value)
transform(list([sym(const), sym(Name), TypeSym, ValForm]),
          const(Name, Type, Val)) :-
    transform_type(TypeSym, Type),
    transform(ValForm, Val).

%% ============================================================
%% expressions
%% ============================================================

%% literals
transform(num(N), num(N)).
transform(str(S), str(S)).
transform(sym(S), var(S)).

%% (if cond then else)
transform(list([sym(if), Cond, Then, Else]),
          if(CondE, ThenE, ElseE)) :-
    transform(Cond, CondE),
    transform(Then, ThenE),
    transform(Else, ElseE).

%% (let ((name expr) ...) body...)
transform(list([sym(let), list(Bindings) | BodyForms]),
          let(TransBindings, Body)) :-
    maplist(transform_binding, Bindings, TransBindings),
    maplist(transform, BodyForms, Body).

%% (local ((name expr) ...) body...)
transform(list([sym(local), list(Bindings) | BodyForms]),
          local(TransBindings, Body)) :-
    maplist(transform_binding, Bindings, TransBindings),
    maplist(transform, BodyForms, Body).

%% (do expr...)  — sequence, returns last
transform(list([sym(do) | Forms]),
          do(Exprs)) :-
    maplist(transform, Forms, Exprs).

%% (addr name) — address of a function
transform(list([sym(addr), sym(Name)]), addr(Name)).

%% (execute expr) — indirect call via address
transform(list([sym(execute), E]), execute(TE)) :-
    transform(E, TE).

%% (@ expr) — '@' cell
transform(list([sym('@'), E]), '@'(TE)) :-
    transform(E, TE).

%% (c@ expr) — '@' byte
transform(list([sym('c@'), E]), 'c@'(TE)) :-
    transform(E, TE).

%% (! addr val) — '!' cell
transform(list([sym('!'), A, V]), '!'(TA, TV)) :-
    transform(A, TA),
    transform(V, TV).

%% (c! addr val) — '!' byte
transform(list([sym('c!'), A, V]), 'c!'(TA, TV)) :-
    transform(A, TA),
    transform(V, TV).

%% (while cond body...)
transform(list([sym(while), Cond | BodyForms]),
          while(CondE, Body)) :-
    transform(Cond, CondE),
    maplist(transform, BodyForms, Body).

%% binary operators
transform(list([sym(Op), A, B]), binop(Op, TA, TB)) :-
    binop(Op),
    transform(A, TA),
    transform(B, TB).

%% {op op ...} — inline VM ops, bypasses type system
transform(asm(Syms), inline(Ops)) :-
    syms_to_names(Syms, Ops).

%% function call (anything else that's a list with a sym head)
transform(list([sym(Name) | Args]), call(Name, TArgs)) :-
    \+ reserved(Name),
    maplist(transform, Args, TArgs).

%% ============================================================
%% helpers
%% ============================================================

transform_param(sym(Name), param(Name, int)).  % default type for now
transform_param(list([sym(Name), sym(:), TypeSym]), param(Name, Type)) :-
    transform_type(TypeSym, Type).
transform_param(list([sym(Name), sym(:), TypeSym, sym('...')]),
                 rest_param(Name, Type)) :-
    transform_type(TypeSym, Type).

valid_param_list([]).
valid_param_list([param(_, _)]).
valid_param_list([rest_param(_, _)]).
valid_param_list([param(_, _) | Rest]) :-
    Rest = [_|_],
    valid_param_list(Rest).

transform_binding(list([sym(Name), Expr]), bind(Name, TE)) :-
    transform(Expr, TE).

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
transform_type(list([sym(ptr), Inner]), ptr(T)) :-
    transform_type(Inner, T).

binop(+). binop(-). binop(*). binop(/). binop(mod).
binop(and). binop(or). binop(xor).
binop(=). binop(<). binop(>).
binop('!='). binop(<=). binop(>=).

reserved(def). reserved(let). reserved(local). reserved(if). reserved(do).
reserved(while). reserved(const). reserved(extern).
reserved('@'). reserved('c@'). reserved('!'). reserved('c!').
reserved(addr). reserved(execute).
reserved('$include').

syms_to_names([], []).
syms_to_names([sym(S)|Rest], [S|Names]) :-
    syms_to_names(Rest, Names).
