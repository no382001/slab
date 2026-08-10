:- module(constfold, [fold_constants/3, fold_stats/1, subst_vars/3]).

:- use_module(library(lists)).
:- use_module(builder).

%% ============================================================
%% fold statistics
%% ============================================================
%% Counts of successful folds by kind, from the most recent
%% fold_constants/3 call. Reset at the start of every call, so
%% only meaningful to read right after folding.

:- dynamic(fold_stat/2).
fold_stat(binop, 0).
fold_stat('if', 0).
fold_stat(call, 0).

reset_fold_stats :-
    retractall(fold_stat(_, _)),
    assertz(fold_stat(binop, 0)),
    assertz(fold_stat('if', 0)),
    assertz(fold_stat(call, 0)).

bump_fold_stat(Kind) :-
    retract(fold_stat(Kind, N)),
    N1 is N + 1,
    assertz(fold_stat(Kind, N1)).

%% fold_stats(-Stats)
%% Stats = [binop-N, if-N, call-N]
fold_stats(Stats) :-
    findall(Kind-N, fold_stat(Kind, N), Stats).

%% ============================================================
%% entry point
%% ============================================================

fold_constants(Defs, EffectEnv, FoldedDefs) :-
    reset_fold_stats,
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
        builder:mk_num(R, Result),
        bump_fold_stat(binop)
    ;
        Result = binop(Op, FA, FB)
    ).

fold_expr(DetFns, if(C, T, E), Result) :-
    fold_expr(DetFns, C, FC),
    fold_expr(DetFns, T, FT),
    fold_expr(DetFns, E, FE),
    ( FC = num(N) ->
        ( N =\= 0 -> Result = FT ; Result = FE ),
        bump_fold_stat('if')
    ;
        Result = if(FC, FT, FE)
    ).

%% let: propagate known-constant bindings forward, then inline any
%% binding that folded to a literal and drop it, literals are free
%% to duplicate, so there's no reason to keep them on the rack.
fold_expr(DetFns, let(Bindings, Body), Result) :-
    fold_let_bindings(DetFns, Bindings, [], FBindings, ConstSubs),
    ( ConstSubs == [] ->
        SubstBody = Body
    ;
        maplist(subst_vars_(ConstSubs), Body, SubstBody)
    ),
    maplist(fold_expr(DetFns), SubstBody, FBody),
    ( FBindings == [] ->
        ( FBody = [Single] -> Result = Single ; Result = do(FBody) )
    ;
        Result = let(FBindings, FBody)
    ).

fold_expr(DetFns, do(Exprs), do(FExprs)) :-
    maplist(fold_expr(DetFns), Exprs, FExprs).

fold_expr(DetFns, while(Cond, Body), while(FCond, FBody)) :-
    fold_expr(DetFns, Cond, FCond),
    maplist(fold_expr(DetFns), Body, FBody).

fold_expr(DetFns, @(E), @(FE)) :-
    fold_expr(DetFns, E, FE).
fold_expr(DetFns, 'c@'(E), 'c@'(FE)) :-
    fold_expr(DetFns, E, FE).
fold_expr(DetFns, !(A, V), !(FA, FV)) :-
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
            builder:mk_num(Val, Result),
            bump_fold_stat(call)
        ;
            Result = call(Name, FArgs)
        )
    ;
        Result = call(Name, FArgs)
    ).

%% ============================================================
%% let-binding helpers: constant propagation
%% ============================================================

fold_let_bindings(_, [], Subs, [], Subs).
fold_let_bindings(DetFns, [bind(Name, Expr)|Rest], Subs0, RemainingBindings, FinalSubs) :-
    subst_vars(Subs0, Expr, SExpr),
    fold_expr(DetFns, SExpr, FExpr),
    ( is_literal(FExpr) ->
        fold_let_bindings(DetFns, Rest, [Name-FExpr|Subs0], RemainingBindings, FinalSubs)
    ;
        fold_let_bindings(DetFns, Rest, Subs0, RestBindings, FinalSubs),
        RemainingBindings = [bind(Name, FExpr)|RestBindings]
    ).

is_literal(num(_)).
is_literal(str(_)).
is_literal(addr(_)).

%% subst_vars(+Subs, +Expr, -NewExpr)
%% Subs = [Name-ReplExpr, ...]. Replaces var(Name) with ReplExpr,
%% except where a nested let rebinds Name (let* semantics: shadowed
%% for the rest of that let).
subst_vars(Subs, var(Name), Repl) :- member(Name-Repl, Subs), !.
subst_vars(_, var(Name), var(Name)).
subst_vars(_, num(N), num(N)).
subst_vars(_, str(S), str(S)).
subst_vars(_, addr(N), addr(N)).
subst_vars(_, inline(Ops), inline(Ops)).
subst_vars(Subs, binop(Op, A, B), binop(Op, NA, NB)) :-
    subst_vars(Subs, A, NA), subst_vars(Subs, B, NB).
subst_vars(Subs, if(C, T, E), if(NC, NT, NE)) :-
    subst_vars(Subs, C, NC), subst_vars(Subs, T, NT), subst_vars(Subs, E, NE).
subst_vars(Subs, let(Bindings, Body), let(NBindings, NBody)) :-
    subst_bindings(Subs, Bindings, NBindings, Subs1),
    maplist(subst_vars_(Subs1), Body, NBody).
subst_vars(Subs, do(Exprs), do(NExprs)) :- maplist(subst_vars_(Subs), Exprs, NExprs).
subst_vars(Subs, while(C, Body), while(NC, NBody)) :-
    subst_vars(Subs, C, NC), maplist(subst_vars_(Subs), Body, NBody).
subst_vars(Subs, @(E), @(NE)) :- subst_vars(Subs, E, NE).
subst_vars(Subs, 'c@'(E), 'c@'(NE)) :- subst_vars(Subs, E, NE).
subst_vars(Subs, !(A, V), !(NA, NV)) :- subst_vars(Subs, A, NA), subst_vars(Subs, V, NV).
subst_vars(Subs, 'c!'(A, V), 'c!'(NA, NV)) :- subst_vars(Subs, A, NA), subst_vars(Subs, V, NV).
subst_vars(Subs, execute(E), execute(NE)) :- subst_vars(Subs, E, NE).
subst_vars(Subs, call(Name, Args), call(Name, NArgs)) :- maplist(subst_vars_(Subs), Args, NArgs).

subst_vars_(Subs, E, NE) :- subst_vars(Subs, E, NE).

subst_bindings(Subs, [], [], Subs).
subst_bindings(Subs, [bind(Name, Expr)|Rest], [bind(Name, NExpr)|NRest], FinalSubs) :-
    subst_vars(Subs, Expr, NExpr),
    remove_subst(Name, Subs, Subs1),
    subst_bindings(Subs1, Rest, NRest, FinalSubs).

remove_subst(_, [], []).
remove_subst(Name, [Name-_|Rest], Rest) :- !.
remove_subst(Name, [Pair|Rest], [Pair|Rest1]) :- remove_subst(Name, Rest, Rest1).

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

%% stats: folding f(7) counts as one call fold, no binop/if folds at the call site
?- fold_pipeline("(def f ((x : int)) : int (* x 3)) (def g () : int (f 7))", _),
   fold_stats(Stats),
   member(binop-0, Stats), member('if'-0, Stats), member(call-1, Stats).
   true.

%% stats: (if (> 1 0) (+ 2 3) 0) folds two binops (> and +) and the if itself
?- fold_pipeline("(def g () : int (if (> 1 0) (+ 2 3) 0))", _),
   fold_stats(Stats),
   member(binop-2, Stats), member('if'-1, Stats), member(call-0, Stats).
   true.

%% stats reset between calls: a no-op fold reports all zeros
?- fold_pipeline("(def g () : int 5)", _),
   fold_stats(Stats),
   member(binop-0, Stats), member('if'-0, Stats), member(call-0, Stats).
   true.

%% let: a constant binding propagates into the body and folds fully away
?- fold_pipeline("(def g () : int (let ((x (+ 2 3))) (* x x)))", Defs),
   member(def(g, _, _, _, [num(25)]), Defs).
   true.

%% let: constants chain — b's binding sees a's already-folded value
?- fold_pipeline("(def g () : int (let ((a 5) (b (+ a 1))) (* a b)))", Defs),
   member(def(g, _, _, _, [num(30)]), Defs).
   true.

%% let: mixed bindings — the constant one drops, the non-constant one stays
?- fold_pipeline("(def g ((n : int)) : int (let ((x 5) (y (+ n 1))) (+ x y)))", Defs),
   member(def(g, _, _, _, [let([bind(y, binop(+, var(n), num(1)))], [binop(+, num(5), var(y))])]), Defs).
   true.

%% let: no constant bindings — the let survives untouched
?- fold_pipeline("(def g ((n : int)) : int (let ((y (+ n 1))) (* y y)))", Defs),
   member(def(g, _, _, _, [let([bind(y, binop(+, var(n), num(1)))], [binop(*, var(y), var(y))])]), Defs).
   true.

%% let: shadowing — an inner rebinding blocks the outer constant
?- fold_pipeline("(def g () : int (let ((x 5)) (let ((x 10)) x)))", Defs),
   member(def(g, _, _, _, [num(10)]), Defs).
   true.
