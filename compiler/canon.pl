:- module(canon, [canon_expr/3, canon_defs/3]).

:- use_module(library(lists)).
:- use_module(ast_shape).
:- use_module(effects).

%% canon_defs(+Defs, +EffectEnv, -NewDefs)
canon_defs(Defs, EffectEnv, NewDefs) :- maplist(canon_def(EffectEnv), Defs, NewDefs).

canon_def(_, const(N, T, V), const(N, T, V)).
canon_def(_, extern(N, P, R), extern(N, P, R)).
canon_def(_, extern(N, C, P, R), extern(N, C, P, R)).
canon_def(EffectEnv, def(Name, Params, RetType, Decl, Body), def(Name, Params, RetType, Decl, NewBody)) :-
    maplist(canon_expr(EffectEnv), Body, NewBody).

%% canon_expr(+EffectEnv, +Expr, -NewExpr)
%% Flattens/sorts/rebuilds +,*,and,or,xor chains; skips reordering when det, 
%% since that could change observable behavior.
canon_expr(EffectEnv, binop(Op, A, B), Result) :-
    assoc_op(Op), !,
    canon_expr(EffectEnv, A, CA),
    canon_expr(EffectEnv, B, CB),
    ( infer_expr_effect(binop(Op, CA, CB), EffectEnv, det) ->
        flatten_assoc(Op, binop(Op, CA, CB), Leaves),
        term_sort(Leaves, Sorted),
        rebuild_assoc(Op, Sorted, Result)
    ;
        Result = binop(Op, CA, CB)
    ).
canon_expr(EffectEnv, Expr, NewExpr) :-
    ast_children(Expr, Children),
    maplist(canon_expr(EffectEnv), Children, NewChildren),
    ast_rebuild(Expr, NewChildren, NewExpr).

assoc_op(+).
assoc_op(*).
assoc_op(and).
assoc_op(or).
assoc_op(xor).

%% flatten_assoc(+Op, +Expr, -Leaves)
%% Leaves = Expr's operands under repeated Op, stopping at anything
%% that isn't itself binop(Op, _, _) — a different op is an opaque leaf.
flatten_assoc(Op, binop(Op, A, B), Leaves) :- !,
    flatten_assoc(Op, A, LA),
    flatten_assoc(Op, B, LB),
    append(LA, LB, Leaves).
flatten_assoc(_, Expr, [Expr]).

%% rebuild_assoc(+Op, +Leaves, -Expr)
%% Right-associates a sorted, non-empty leaf list back into a binop chain.
rebuild_assoc(_, [Single], Single) :- !.
rebuild_assoc(Op, [L|Ls], binop(Op, L, Rest)) :-
    rebuild_assoc(Op, Ls, Rest).

%% term_sort(+List, -Sorted)
%% stable insertion sort keeping duplicates
term_sort(List, Sorted) :- term_sort_(List, [], Sorted).

term_sort_([], Acc, Acc).
term_sort_([X|Xs], Acc0, Sorted) :-
    term_insert(X, Acc0, Acc1),
    term_sort_(Xs, Acc1, Sorted).

term_insert(X, [], [X]).
term_insert(X, [Y|Ys], [X, Y|Ys]) :- X @=< Y, !.
term_insert(X, [Y|Ys], [Y|Rest]) :- term_insert(X, Ys, Rest).

%% ============================================================
%% tests
%% ============================================================

:- use_module(parser).
:- use_module(ast).
:- use_module(typecheck).

canon_pipeline(Src, EffEnv, Defs) :-
    parse(Src, ok(Forms)),
    transform_program(Forms, ok(Defs0)),
    check_program(Defs0, ok(_)),
    infer_effects(Defs0, EffEnv),
    Defs = Defs0.

%% pairwise swap: (+ b a) and (+ a b) canonicalize identically
?- canon_expr([], binop(+, var(a), var(b)), R1),
   canon_expr([], binop(+, var(b), var(a)), R2),
   R1 == R2.
   true.

%% chain flattening: (+ (+ a b) c) and (+ a (+ b c)) canonicalize identically
?- canon_expr([], binop(+, binop(+, var(a), var(b)), var(c)), R1),
   canon_expr([], binop(+, var(a), binop(+, var(b), var(c))), R2),
   R1 == R2.
   true.

%% a different grouping/order of the same three terms still matches
?- canon_expr([], binop(+, var(c), binop(+, var(b), var(a))), R1),
   canon_expr([], binop(+, binop(+, var(a), var(b)), var(c)), R2),
   R1 == R2.
   true.

%% mixed-operator boundary
   R == binop(+, var(c), binop(-, var(a), var(b))).
   true.

%% a non-assoc op's own children are still recursively canonicalized —
%% here the inner * chain reorders even though the outer - stops the +.
?- canon_expr([], binop(-, binop(*, var(b), var(a)), var(c)), R),
   R == binop(-, binop(*, var(a), var(b)), var(c)).
   true.

%% a nested chain inside one leaf of an outer chain still canonicalizes
?- canon_expr([], binop(+, binop(*, var(c), var(b)), var(a)), R1),
   canon_expr([], binop(+, var(a), binop(*, var(b), var(c))), R2),
   R1 == R2.
   true.

%% a nondet call in the chain blocks reordering entirely
?- canon_expr([eff(f, nondet)], binop(+, call(f, []), var(a)), R),
   R == binop(+, call(f, []), var(a)).
   true.

%% swapped operands of the same nondet chain stay swapped
?- canon_expr([eff(f, nondet)], binop(+, var(a), call(f, [])), R),
   R == binop(+, var(a), call(f, [])).
   true.

%% a det call is treated like any other det leaf and can be reordered
?- canon_expr([eff(f, det)], binop(+, call(f, []), var(a)), R1),
   canon_expr([eff(f, det)], binop(+, var(a), call(f, [])), R2),
   R1 == R2.
   true.

%% canon_defs runs over a real program without error
?- canon_pipeline("(def f ((a : int) (b : int) (c : int)) : int (+ c (+ b a)))", EffEnv, Defs),
   canon_defs(Defs, EffEnv, NewDefs),
   member(def(f, _, _, _, [binop(+, var(a), binop(+, var(b), var(c)))]), NewDefs).
   true.
