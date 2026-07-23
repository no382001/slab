:- module(locals, [expand_locals/4]).

:- use_module(library(lists)).

%% expand_locals(+Defs, +SlotBase, -ExpandedDefs, -NewSlotBase)
expand_locals([], Slot, [], Slot).
expand_locals([def(Name, Params, RetType, Decl, Body) | Rest], Slot0, AllDefs, SlotFinal) :-
    !,
    expand_exprs([], Slot0, Body, NewBody, [], ConstDefs, Slot1),
    expand_locals(Rest, Slot1, RestDefs, SlotFinal),
    append(ConstDefs, [def(Name, Params, RetType, Decl, NewBody) | RestDefs], AllDefs).
expand_locals([Other | Rest], Slot0, [Other | RestDefs], SlotFinal) :-
    expand_locals(Rest, Slot0, RestDefs, SlotFinal).

%% ============================================================
%% walk a list of sibling expressions
%% ============================================================

expand_exprs(_, Slot, [], [], CD, CD, Slot).
expand_exprs(Renames, Slot0, [E | Es], [NE | NEs], CD0, CD2, Slot2) :-
    expand_expr(Renames, Slot0, E, NE, CD0, CD1, Slot1),
    expand_exprs(Renames, Slot1, Es, NEs, CD1, CD2, Slot2).

%% ============================================================
%% walk one expression
%% ============================================================

expand_expr(_, Slot, num(N), num(N), CD, CD, Slot).
expand_expr(_, Slot, str(S), str(S), CD, CD, Slot).
expand_expr(_, Slot, addr(N), addr(N), CD, CD, Slot).
expand_expr(_, Slot, inline(Ops), inline(Ops), CD, CD, Slot).

expand_expr(Renames, Slot, var(Name), var(Fresh), CD, CD, Slot) :-
    member(Name-Fresh, Renames), !.
expand_expr(_, Slot, var(Name), var(Name), CD, CD, Slot).

expand_expr(Renames, Slot0, binop(Op, A, B), binop(Op, NA, NB), CD0, CD2, Slot2) :-
    expand_expr(Renames, Slot0, A, NA, CD0, CD1, Slot1),
    expand_expr(Renames, Slot1, B, NB, CD1, CD2, Slot2).

expand_expr(Renames, Slot0, if(C, T, E), if(NC, NT, NE), CD0, CD3, Slot3) :-
    expand_expr(Renames, Slot0, C, NC, CD0, CD1, Slot1),
    expand_expr(Renames, Slot1, T, NT, CD1, CD2, Slot2),
    expand_expr(Renames, Slot2, E, NE, CD2, CD3, Slot3).

expand_expr(Renames, Slot0, do(Exprs), do(NExprs), CD0, CD1, Slot1) :-
    expand_exprs(Renames, Slot0, Exprs, NExprs, CD0, CD1, Slot1).

expand_expr(Renames, Slot0, while(Cond, Body), while(NCond, NBody), CD0, CD2, Slot2) :-
    expand_expr(Renames, Slot0, Cond, NCond, CD0, CD1, Slot1),
    expand_exprs(Renames, Slot1, Body, NBody, CD1, CD2, Slot2).

expand_expr(Renames, Slot0, @(E), @(NE), CD0, CD1, Slot1) :-
    expand_expr(Renames, Slot0, E, NE, CD0, CD1, Slot1).
expand_expr(Renames, Slot0, 'c@'(E), 'c@'(NE), CD0, CD1, Slot1) :-
    expand_expr(Renames, Slot0, E, NE, CD0, CD1, Slot1).
expand_expr(Renames, Slot0, !(A, V), !(NA, NV), CD0, CD2, Slot2) :-
    expand_expr(Renames, Slot0, A, NA, CD0, CD1, Slot1),
    expand_expr(Renames, Slot1, V, NV, CD1, CD2, Slot2).
expand_expr(Renames, Slot0, 'c!'(A, V), 'c!'(NA, NV), CD0, CD2, Slot2) :-
    expand_expr(Renames, Slot0, A, NA, CD0, CD1, Slot1),
    expand_expr(Renames, Slot1, V, NV, CD1, CD2, Slot2).
expand_expr(Renames, Slot0, execute(E), execute(NE), CD0, CD1, Slot1) :-
    expand_expr(Renames, Slot0, E, NE, CD0, CD1, Slot1).

expand_expr(Renames, Slot0, call(Name, Args), call(Name, NArgs), CD0, CD1, Slot1) :-
    expand_exprs(Renames, Slot0, Args, NArgs, CD0, CD1, Slot1).

expand_expr(Renames, Slot0, let(Bindings, Body), let(NBindings, NBody), CD0, CD2, Slot2) :-
    expand_let_bindings(Renames, Slot0, Bindings, NBindings, CD0, CD1, Slot1, Renames1),
    expand_exprs(Renames1, Slot1, Body, NBody, CD1, CD2, Slot2).

expand_expr(Renames, Slot0, local(Bindings, Body), do(AllExprs), CD0, CD2, Slot2) :-
    expand_local_bindings(Renames, Slot0, Bindings, InitStores, CD0, CD1, Slot1, Renames1),
    expand_exprs(Renames1, Slot1, Body, NBody, CD1, CD2, Slot2),
    append(InitStores, NBody, AllExprs).

expand_let_bindings(Renames, Slot, [], [], CD, CD, Slot, Renames).
expand_let_bindings(Renames, Slot0, [bind(Name, Expr) | Rest], [bind(Name, NExpr) | NRest], CD0, CD2, Slot2, FinalRenames) :-
    expand_expr(Renames, Slot0, Expr, NExpr, CD0, CD1, Slot1),
    drop_rename(Name, Renames, Renames1),
    expand_let_bindings(Renames1, Slot1, Rest, NRest, CD1, CD2, Slot2, FinalRenames).

expand_local_bindings(Renames, Slot, [], [], CD, CD, Slot, Renames).
expand_local_bindings(Renames, Slot0, [bind(Name, Expr) | Rest], [Store | RestStores], CD0, CD2, Slot2, FinalRenames) :-
    expand_expr(Renames, Slot0, Expr, NExpr, CD0, CD1, Slot1),
    fresh_local_name(Name, Fresh),
    Addr = Slot1,
    Slot1a is Slot1 + 2,
    Store = !(var(Fresh), NExpr),
    expand_local_bindings([Name-Fresh | Renames], Slot1a, Rest, RestStores,
                           [const(Fresh, int, num(Addr)) | CD1], CD2, Slot2, FinalRenames).

drop_rename(_, [], []).
drop_rename(Name, [Name-_ | Rest], Rest) :- !.
drop_rename(Name, [Pair | Rest], [Pair | Rest1]) :-
    drop_rename(Name, Rest, Rest1).

:- dynamic(local_counter/1).
local_counter(0).

fresh_local_name(Name, Fresh) :-
    retract(local_counter(N)),
    N1 is N + 1,
    assertz(local_counter(N1)),
    number_chars(N1, NChars),
    atom_chars(Name, NameChars),
    append(['_', 'l', 'o', 'c', '_' | NChars], ['_' | NameChars], FreshChars),
    atom_chars(Fresh, FreshChars).
