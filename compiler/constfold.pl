:- module(constfold, [fold_constants/3]).

:- use_module(library(lists)).

%% ============================================================
%% entry point
%% ============================================================

fold_constants(Defs, EffectEnv, FoldedDefs) :-
    build_det_fns(Defs, EffectEnv, DetFns),
    maplist(fold_def(DetFns), Defs, FoldedDefs).

%% Build a lookup of det function bodies: detfn(Name, Params, Body)
%% Variadic functions are excluded — bind_params/3 only binds fixed
%% params, so a rest_param here would just fail the whole fold.
build_det_fns([], _, []).
build_det_fns([def(Name, Params, _, _, Body)|Rest], Env, [detfn(Name, Params, Body)|Fns]) :-
    member(eff(Name, det), Env),
    \+ has_rest_param(Params), !,
    build_det_fns(Rest, Env, Fns).
build_det_fns([_|Rest], Env, Fns) :-
    build_det_fns(Rest, Env, Fns).

has_rest_param(Params) :- member(rest_param(_, _), Params).

%% ============================================================
%% fold a definition
%% ============================================================

fold_def(_, const(N, T, V), const(N, T, V)).
fold_def(_, extern(N, P, R), extern(N, P, R)).
fold_def(_, extern(N, C, P, R), extern(N, C, P, R)).
fold_def(DetFns, def(Name, Params, RetType, Decl, Body), def(Name, Params, RetType, Decl, FoldedBody)) :-
    maplist(fold_expr(DetFns), Body, FoldedBody).

%% ============================================================
%% fold expressions
%% ============================================================

fold_expr(_, num(N), num(N)).
fold_expr(_, str(S), str(S)).
fold_expr(_, var(V), var(V)).
fold_expr(_, addr(N), addr(N)).

fold_expr(DetFns, binop(Op, A, B), Result) :-
    fold_expr(DetFns, A, FA),
    fold_expr(DetFns, B, FB),
    ( FA = num(NA), FB = num(NB) ->
        eval_binop(Op, NA, NB, R),
        Result = num(R)
    ;
        Result = binop(Op, FA, FB)
    ).

fold_expr(DetFns, if(C, T, E), Result) :-
    fold_expr(DetFns, C, FC),
    fold_expr(DetFns, T, FT),
    fold_expr(DetFns, E, FE),
    ( FC = num(N) ->
        ( N =\= 0 -> Result = FT ; Result = FE )
    ;
        Result = if(FC, FT, FE)
    ).

fold_expr(DetFns, let(Bindings, Body), let(FBindings, FBody)) :-
    maplist(fold_binding(DetFns), Bindings, FBindings),
    maplist(fold_expr(DetFns), Body, FBody).

fold_expr(DetFns, do(Exprs), do(FExprs)) :-
    maplist(fold_expr(DetFns), Exprs, FExprs).

fold_expr(DetFns, while(Cond, Body), while(FCond, FBody)) :-
    fold_expr(DetFns, Cond, FCond),
    maplist(fold_expr(DetFns), Body, FBody).

fold_expr(DetFns, '@'(E), '@'(FE)) :-
    fold_expr(DetFns, E, FE).
fold_expr(DetFns, 'c@'(E), 'c@'(FE)) :-
    fold_expr(DetFns, E, FE).
fold_expr(DetFns, '!'(A, V), '!'(FA, FV)) :-
    fold_expr(DetFns, A, FA),
    fold_expr(DetFns, V, FV).
fold_expr(DetFns, 'c!'(A, V), 'c!'(FA, FV)) :-
    fold_expr(DetFns, A, FA),
    fold_expr(DetFns, V, FV).
fold_expr(DetFns, execute(E), execute(FE)) :-
    fold_expr(DetFns, E, FE).

%% function call: try to fold if det with all-constant args
fold_expr(DetFns, call(Name, Args), Result) :-
    maplist(fold_expr(DetFns), Args, FArgs),
    ( all_constant(FArgs),
      member(detfn(Name, Params, Body), DetFns) ->
        bind_params(Params, FArgs, Env),
        ( eval_body(DetFns, Env, Body, 1000, Val, _) ->
            Result = num(Val)
        ;
            Result = call(Name, FArgs)
        )
    ;
        Result = call(Name, FArgs)
    ).

fold_binding(DetFns, bind(N, E), bind(N, FE)) :-
    fold_expr(DetFns, E, FE).

%% ============================================================
%% compile-time evaluator (pure subset only, with step limit)
%% ============================================================

all_constant([]).
all_constant([num(_)|Rest]) :- all_constant(Rest).

bind_params([], [], []).
bind_params([param(Name, _)|Ps], [num(V)|Vs], [binding(Name, V)|Rest]) :-
    bind_params(Ps, Vs, Rest).

eval_body(_, _, _, Steps, _, _) :- Steps =< 0, !, fail.
eval_body(DetFns, Env, [Expr], Steps, Val, StepsOut) :-
    eval_expr(DetFns, Env, Expr, Steps, Val, StepsOut).
eval_body(DetFns, Env, [_|Rest], Steps, Val, StepsOut) :-
    Rest \= [],
    Steps1 is Steps - 1,
    eval_body(DetFns, Env, Rest, Steps1, Val, StepsOut).

eval_expr(_, _, _, Steps, _, _) :- Steps =< 0, !, fail.

eval_expr(_, _, num(N), Steps, N, Steps).

eval_expr(_, Env, var(Name), Steps, Val, Steps) :-
    member(binding(Name, Val), Env).

eval_expr(DetFns, Env, binop(Op, A, B), Steps, Val, StepsOut) :-
    Steps1 is Steps - 1,
    eval_expr(DetFns, Env, A, Steps1, VA, Steps2),
    eval_expr(DetFns, Env, B, Steps2, VB, Steps3),
    eval_binop(Op, VA, VB, Val),
    StepsOut = Steps3.

eval_expr(DetFns, Env, if(C, T, E), Steps, Val, StepsOut) :-
    Steps1 is Steps - 1,
    eval_expr(DetFns, Env, C, Steps1, CV, Steps2),
    ( CV =\= 0 ->
        eval_expr(DetFns, Env, T, Steps2, Val, StepsOut)
    ;
        eval_expr(DetFns, Env, E, Steps2, Val, StepsOut)
    ).

eval_expr(DetFns, Env, let(Bindings, Body), Steps, Val, StepsOut) :-
    Steps1 is Steps - 1,
    eval_let_bindings(DetFns, Env, Bindings, Steps1, ExtEnv, Steps2),
    eval_body(DetFns, ExtEnv, Body, Steps2, Val, StepsOut).

eval_expr(DetFns, Env, call(Name, Args), Steps, Val, StepsOut) :-
    Steps1 is Steps - 1,
    eval_args(DetFns, Env, Args, Steps1, Vals, Steps2),
    member(detfn(Name, Params, Body), DetFns),
    bind_params(Params, Vals, CallEnv),
    eval_body(DetFns, CallEnv, Body, Steps2, Val, StepsOut).

eval_let_bindings(_, Env, [], Steps, Env, Steps).
eval_let_bindings(DetFns, Env, [bind(Name, Expr)|Rest], Steps, OutEnv, StepsOut) :-
    eval_expr(DetFns, Env, Expr, Steps, Val, Steps1),
    eval_let_bindings(DetFns, [binding(Name, Val)|Env], Rest, Steps1, OutEnv, StepsOut).

eval_args(_, _, [], Steps, [], Steps).
eval_args(DetFns, Env, [A|As], Steps, [num(V)|Vs], StepsOut) :-
    eval_expr(DetFns, Env, A, Steps, V, Steps1),
    eval_args(DetFns, Env, As, Steps1, Vs, StepsOut).

%% ============================================================
%% binary op evaluation
%% ============================================================

eval_binop(+, A, B, R) :- R is (A + B) mod 65536.
eval_binop(-, A, B, R) :- R is (A - B) mod 65536.
eval_binop(*, A, B, R) :- R is (A * B) mod 65536.
eval_binop(/, A, B, R) :- B =\= 0, R is A // B.
eval_binop(mod, A, B, R) :- B =\= 0, R is A mod B.
eval_binop(<, A, B, R) :- ( A < B -> R = 1 ; R = 0 ).
eval_binop(>, A, B, R) :- ( A > B -> R = 1 ; R = 0 ).
eval_binop(=, A, B, R) :- ( A =:= B -> R = 1 ; R = 0 ).
eval_binop('!=', A, B, R) :- ( A =\= B -> R = 1 ; R = 0 ).
eval_binop(<=, A, B, R) :- ( A =< B -> R = 1 ; R = 0 ).
eval_binop(>=, A, B, R) :- ( A >= B -> R = 1 ; R = 0 ).
eval_binop(and, A, B, R) :- R is A /\ B.
eval_binop(or, A, B, R) :- R is A \/ B.
eval_binop(xor, A, B, R) :- R is (A \/ B) /\ (\(A /\ B)).

%% ============================================================
%% tests
%% ============================================================

:- use_module(parser).
:- use_module(ast).
:- use_module(typecheck).
:- use_module(effects).

fold_pipeline(Src, FoldedDefs) :-
    parse(Src, ok(Forms)),
    transform_program(Forms, ok(Defs)),
    check_program(Defs, ok(_)),
    infer_effects(Defs, EffEnv),
    fold_constants(Defs, EffEnv, FoldedDefs).

%% * folds: f(x) = x*3, call f(7) -> num(21)
?- fold_pipeline("(def f ((x : int)) : int (* x 3)) (def g () : int (f 7))", Defs),
   member(def(g, _, _, _, [num(21)]), Defs).
   true.

%% / folds: f(x) = x/4, call f(20) -> num(5)
?- fold_pipeline("(def f ((x : int)) : int (/ x 4)) (def g () : int (f 20))", Defs),
   member(def(g, _, _, _, [num(5)]), Defs).
   true.

%% mod folds: f(x) = x mod 7, call f(23) -> num(2)
?- fold_pipeline("(def f ((x : int)) : int (mod x 7)) (def g () : int (f 23))", Defs),
   member(def(g, _, _, _, [num(2)]), Defs).
   true.

%% division by zero must not fold (guard keeps call intact)
?- fold_pipeline("(def f ((x : int)) : int (/ x 0)) (def g () : int (f 10))", Defs),
   member(def(g, _, _, _, [call(f, [num(10)])]), Defs).
   true.
