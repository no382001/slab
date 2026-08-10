:- module(cse, [cse_defs/3, cse_stats/1]).

:- use_module(library(lists)).
:- use_module(library(dcgs)).
:- use_module(builder).
:- use_module(effects).
:- use_module(constfold).

%% ============================================================
%% stats
%% ============================================================

:- dynamic(cse_stat/2).
cse_stat(hoist, 0).
cse_stat(branch_merge, 0).

reset_cse_stats :-
    retractall(cse_stat(_, _)),
    assertz(cse_stat(hoist, 0)),
    assertz(cse_stat(branch_merge, 0)).

bump_cse_stat(Kind) :-
    retract(cse_stat(Kind, N)),
    N1 is N + 1,
    assertz(cse_stat(Kind, N1)).

%% cse_stats(-Stats): Stats = [hoist-N, branch_merge-M] from the last cse_defs/3 call
cse_stats(Stats) :-
    findall(Kind-N, cse_stat(Kind, N), Stats).

%% ============================================================
%% entry point
%% ============================================================

cse_defs(Defs, EffectEnv, NewDefs) :-
    reset_cse_stats,
    maplist(cse_def(EffectEnv), Defs, NewDefs).

cse_def(_, const(N, T, V), const(N, T, V)).
cse_def(_, extern(N, P, R), extern(N, P, R)).
cse_def(_, extern(N, C, P, R), extern(N, C, P, R)).
cse_def(EffectEnv, def(Name, Params, RetType, Decl, Body), def(Name, Params, RetType, Decl, NewBody)) :-
    cse_scope(Body, EffectEnv, NewBody).

%% ============================================================
%% cse_scope: dedupe one scope, then recurse into nested scopes
%% ============================================================

cse_scope(List0, EffectEnv, List) :-
    hoist_all(List0, EffectEnv, [], BindingsRev, List1),
    reverse(BindingsRev, Bindings),
    maplist(cse_walk_binding(EffectEnv), Bindings, NBindings),
    maplist(cse_walk_expr(EffectEnv), List1, NList1),
    ( NBindings == [] ->
        List = NList1
    ;
        List = [let(NBindings, NList1)]
    ).

cse_walk_binding(EffectEnv, bind(Name, Expr), bind(Name, NExpr)) :-
    cse_scope([Expr], EffectEnv, [NExpr]).

%% hoist_all: repeatedly hoists the most profitable duplicate into a fresh binding until none remain
hoist_all(List0, EffectEnv, BindingsAcc, BindingsRev, List) :-
    ( find_best_duplicate(List0, EffectEnv, T) ->
        fresh_cse_name(Temp),
        bump_cse_stat(hoist),
        replace_in_scope(List0, T, var(Temp), List1),
        hoist_all(List1, EffectEnv, [bind(Temp, T)|BindingsAcc], BindingsRev, List)
    ;
        BindingsRev = BindingsAcc,
        List = List0
    ).

%% ============================================================
%% cse_walk_expr: recurses into scopes collect_candidates skips (if/while/let/do) for their own dedup pass
%% ============================================================

cse_walk_expr(_, num(N), num(N)) :- !.
cse_walk_expr(_, str(S), str(S)) :- !.
cse_walk_expr(_, var(V), var(V)) :- !.
cse_walk_expr(_, addr(N), addr(N)) :- !.
cse_walk_expr(_, inline(Ops), inline(Ops)) :- !.
cse_walk_expr(EffectEnv, binop(Op, A, B), binop(Op, NA, NB)) :- !,
    cse_walk_expr(EffectEnv, A, NA),
    cse_walk_expr(EffectEnv, B, NB).
cse_walk_expr(EffectEnv, call(Name, Args), call(Name, NArgs)) :- !,
    maplist(cse_walk_expr(EffectEnv), Args, NArgs).
cse_walk_expr(EffectEnv, @(E), @(NE)) :- !, cse_walk_expr(EffectEnv, E, NE).
cse_walk_expr(EffectEnv, 'c@'(E), 'c@'(NE)) :- !, cse_walk_expr(EffectEnv, E, NE).
cse_walk_expr(EffectEnv, !(A, V), !(NA, NV)) :- !,
    cse_walk_expr(EffectEnv, A, NA),
    cse_walk_expr(EffectEnv, V, NV).
cse_walk_expr(EffectEnv, 'c!'(A, V), 'c!'(NA, NV)) :- !,
    cse_walk_expr(EffectEnv, A, NA),
    cse_walk_expr(EffectEnv, V, NV).
cse_walk_expr(EffectEnv, execute(E), execute(NE)) :- !, cse_walk_expr(EffectEnv, E, NE).

cse_walk_expr(EffectEnv, if(C, Th, El), Result) :- !,
    cse_scope([C], EffectEnv, [NC]),
    cse_scope([Th], EffectEnv, [NTh]),
    cse_scope([El], EffectEnv, [NEl]),
    ( NTh == NEl ->
        Result = do([NC, NTh]),
        bump_cse_stat(branch_merge)
    ;
        Result = if(NC, NTh, NEl)
    ).
cse_walk_expr(EffectEnv, while(C, B), while(NC, NB)) :- !,
    cse_scope([C], EffectEnv, [NC]),
    cse_scope(B, EffectEnv, NB).

cse_walk_expr(EffectEnv, let(Bs, B), Result) :- !,
    maplist(cse_walk_binding(EffectEnv), Bs, NBs),
    cse_scope(B, EffectEnv, NB),
    simplify_let(NBs, NB, EffectEnv, Result).
cse_walk_expr(EffectEnv, do(Es), do(NEs)) :- !,
    cse_scope(Es, EffectEnv, NEs).

%% ============================================================
%% simplify_let: drops dead [det] bindings, inlines single-use ones (cheaper than the rack); semidet/nondet bindings are never touched, since moving them could reorder effects
%% ============================================================

simplify_let(Bindings, Body, EffectEnv, Result) :-
    eliminate_bindings(Bindings, Body, EffectEnv, RemainingBindings, NewBody),
    ( RemainingBindings == [] ->
        ( NewBody = [Single] -> Result = Single ; Result = do(NewBody) )
    ;
        Result = let(RemainingBindings, NewBody)
    ).

eliminate_bindings([], Body, _, [], Body).
eliminate_bindings([bind(Name, Expr)|Rest], Body0, EffectEnv, RemainingBindings, FinalBody) :-
    rest_exprs(Rest, RestExprs),
    count_var_list(Name, RestExprs, RestCount),
    ( RestCount =:= 0,
      infer_expr_effect(Expr, EffectEnv, det),
      count_var_list(Name, Body0, BodyCount),
      BodyCount =< 1 ->
        ( BodyCount =:= 0 ->
            Body1 = Body0
        ;
            subst_body([Name-Expr], Body0, Body1)
        ),
        eliminate_bindings(Rest, Body1, EffectEnv, RemainingBindings, FinalBody)
    ;
        eliminate_bindings(Rest, Body0, EffectEnv, RestBindings, FinalBody),
        RemainingBindings = [bind(Name, Expr)|RestBindings]
    ).

rest_exprs([], []).
rest_exprs([bind(_, E)|Rest], [E|Es]) :- rest_exprs(Rest, Es).

subst_body(Subs, Body0, Body1) :- maplist(subst_body_(Subs), Body0, Body1).
subst_body_(Subs, E, NE) :- constfold:subst_vars(Subs, E, NE).

%% count_var_list(+Name, +Exprs, -Count): total occurrences of var(Name) across Exprs, respecting shadowing
count_var_list(Name, Exprs, Count) :-
    maplist(count_var_(Name), Exprs, Cs),
    sum_list(Cs, Count).

count_var_(Name, E, C) :- count_var(Name, E, C).

count_var(Name, var(Name), 1) :- !.
count_var(_, var(_), 0) :- !.
count_var(_, num(_), 0).
count_var(_, str(_), 0).
count_var(_, addr(_), 0).
count_var(_, inline(_), 0).
count_var(Name, binop(_, A, B), C) :-
    count_var(Name, A, CA), count_var(Name, B, CB), C is CA + CB.
count_var(Name, if(Cnd, T, E), C) :-
    count_var(Name, Cnd, CC), count_var(Name, T, CT), count_var(Name, E, CE),
    C is CC + CT + CE.
count_var(Name, let(Bindings, Body), C) :-
    count_var_bindings(Name, Bindings, CB, Active),
    ( Active -> count_var_list(Name, Body, CBody) ; CBody = 0 ),
    C is CB + CBody.
count_var(Name, do(Exprs), C) :- count_var_list(Name, Exprs, C).
count_var(Name, while(Cnd, Body), C) :-
    count_var(Name, Cnd, CC), count_var_list(Name, Body, CB), C is CC + CB.
count_var(Name, @(E), C) :- count_var(Name, E, C).
count_var(Name, 'c@'(E), C) :- count_var(Name, E, C).
count_var(Name, !(A, V), C) :- count_var(Name, A, CA), count_var(Name, V, CV), C is CA + CV.
count_var(Name, 'c!'(A, V), C) :- count_var(Name, A, CA), count_var(Name, V, CV), C is CA + CV.
count_var(Name, execute(E), C) :- count_var(Name, E, C).
count_var(Name, call(_, Args), C) :- count_var_list(Name, Args, C).

%% count_var_bindings(+Name, +Bindings, -Count, -StillActive): let* order, so a rebinding of Name shadows it for the rest (matches subst_vars)
count_var_bindings(_, [], 0, true).
count_var_bindings(Name, [bind(Name, _)|_], 0, false) :- !.
count_var_bindings(Name, [bind(_, Expr)|Rest], C, Active) :-
    count_var(Name, Expr, CE),
    count_var_bindings(Name, Rest, CRest, Active),
    C is CE + CRest.

%% ============================================================
%% candidate collection: everything reachable in this scope without crossing a boundary (if/while/let/do), tagged det or not
%% ============================================================

collect_candidates(num(_), _, []).
collect_candidates(str(_), _, []).
collect_candidates(var(_), _, []).
collect_candidates(addr(_), _, []).
collect_candidates(inline(_), _, []).
collect_candidates(binop(Op, A, B), EffectEnv, Cands) :-
    collect_candidates(A, EffectEnv, CA),
    collect_candidates(B, EffectEnv, CB),
    ( infer_expr_effect(binop(Op, A, B), EffectEnv, det) -> Self = [binop(Op, A, B)] ; Self = [] ),
    append(Self, CA, C1),
    append(C1, CB, Cands).
collect_candidates(call(Name, Args), EffectEnv, Cands) :-
    maplist(collect_candidates_(EffectEnv), Args, ArgCandsList),
    append(ArgCandsList, ArgCands),
    ( infer_expr_effect(call(Name, Args), EffectEnv, det) -> Self = [call(Name, Args)] ; Self = [] ),
    append(Self, ArgCands, Cands).
collect_candidates(@(E), EffectEnv, Cands) :- collect_candidates(E, EffectEnv, Cands).
collect_candidates('c@'(E), EffectEnv, Cands) :- collect_candidates(E, EffectEnv, Cands).
collect_candidates(!(A, V), EffectEnv, Cands) :-
    collect_candidates(A, EffectEnv, CA),
    collect_candidates(V, EffectEnv, CV),
    append(CA, CV, Cands).
collect_candidates('c!'(A, V), EffectEnv, Cands) :-
    collect_candidates(A, EffectEnv, CA),
    collect_candidates(V, EffectEnv, CV),
    append(CA, CV, Cands).
collect_candidates(execute(E), EffectEnv, Cands) :- collect_candidates(E, EffectEnv, Cands).
%% scope boundaries: opaque to the parent scope's search
collect_candidates(if(_, _, _), _, []).
collect_candidates(while(_, _), _, []).
collect_candidates(let(_, _), _, []).
collect_candidates(do(_), _, []).

collect_candidates_(EffectEnv, E, Cands) :- collect_candidates(E, EffectEnv, Cands).

%% ============================================================
%% find the most profitable candidate that occurs 2+ times in this scope
%% ============================================================

%% a hoisted binding costs 6+4N bytes (>r + N*rpick + r> + drop); only profitable when (N-1)*recompute_cost > 6+4N — see gen/gen.pl and emit.pl for where 6/4 come from
find_best_duplicate(List, EffectEnv, Best) :-
    maplist(collect_candidates_(EffectEnv), List, CandsPerElem),
    append(CandsPerElem, AllCands),
    AllCands \= [],
    group_duplicates(AllCands, Groups),
    profitable_groups(Groups, Profitable),
    Profitable \= [],
    pick_most_profitable(Profitable, Best).

group_duplicates(Cands, Groups) :-
    group_duplicates_(Cands, [], Acc),
    filter_ge2(Acc, Groups).

filter_ge2([], []).
filter_ge2([G|Gs], [G|Rest]) :- G = _-N, N >= 2, !, filter_ge2(Gs, Rest).
filter_ge2([_|Gs], Rest) :- filter_ge2(Gs, Rest).

group_duplicates_([], Acc, Acc).
group_duplicates_([C|Cs], Acc0, Acc) :-
    ( bump_group(C, Acc0, Acc1) ->
        true
    ;
        Acc1 = [C-1|Acc0]
    ),
    group_duplicates_(Cs, Acc1, Acc).

bump_group(C, [T-N|Rest], [T-N1|Rest]) :- C == T, !, N1 is N + 1.
bump_group(C, [Other|Rest], [Other|Rest1]) :- bump_group(C, Rest, Rest1).

%% profitable_groups(+Groups, -Profitable)
%% Profitable = [Term-Savings, ...], only groups with positive savings.
profitable_groups([], []).
profitable_groups([T-N|Gs], Result) :-
    estimate_cost(T, Cost),
    Savings is (N - 1) * Cost - (6 + 4 * N),
    profitable_groups(Gs, Rest),
    ( Savings > 0 -> Result = [T-Savings|Rest] ; Result = Rest ).

pick_most_profitable([T0-S0|Gs], Best) :- pick_most_profitable_(Gs, T0, S0, Best).

pick_most_profitable_([], Best, _, Best).
pick_most_profitable_([T-S|Gs], Cur, CurS, Best) :-
    ( S > CurS -> Next = T, NextS = S ; Next = Cur, NextS = CurS ),
    pick_most_profitable_(Gs, Next, NextS, Best).

%% estimate_cost(+Expr, -Bytes): static compiled-size estimate matching emit.pl; var/_ intentionally underestimates at 4 bytes (ignoring memory-bound params, which cost 6) to keep the profitability check conservative
estimate_cost(num(_), 4).
estimate_cost(str(_), 4).
estimate_cost(var(_), 4).
estimate_cost(addr(_), 4).
estimate_cost(inline(Ops), S) :- length(Ops, L), S is L * 2.
estimate_cost(binop(_, A, B), S) :- estimate_cost(A, SA), estimate_cost(B, SB), S is SA + SB + 2.
estimate_cost(call(_, Args), S) :- maplist(estimate_cost, Args, Sizes), sum_list(Sizes, SS), S is SS + 4.
estimate_cost(@(E), S) :- estimate_cost(E, SE), S is SE + 2.
estimate_cost('c@'(E), S) :- estimate_cost(E, SE), S is SE + 2.
estimate_cost(!(A, V), S) :- estimate_cost(A, SA), estimate_cost(V, SV), S is SA + SV + 2.
estimate_cost('c!'(A, V), S) :- estimate_cost(A, SA), estimate_cost(V, SV), S is SA + SV + 2.
estimate_cost(execute(E), S) :- estimate_cost(E, SE), S is SE + 2.
%% control-flow nodes never appear as a candidate root (only nested in a call's args) — rough fallback, precision doesn't matter
estimate_cost(if(_, _, _), 10).
estimate_cost(while(_, _), 10).
estimate_cost(let(_, _), 10).
estimate_cost(do(_), 10).

%% ============================================================
%% replace every occurrence of T in a scope (or call arg list) with Repl, without crossing a scope boundary
%% ============================================================

replace_in_scope([], _, _, []).
replace_in_scope([E|Es], T, Repl, [NE|NEs]) :-
    replace_in_expr(E, T, Repl, NE),
    replace_in_scope(Es, T, Repl, NEs).

replace_in_expr(E, T, Repl, Repl) :- E == T, !.
replace_in_expr(num(N), _, _, num(N)) :- !.
replace_in_expr(str(S), _, _, str(S)) :- !.
replace_in_expr(var(V), _, _, var(V)) :- !.
replace_in_expr(addr(N), _, _, addr(N)) :- !.
replace_in_expr(inline(Ops), _, _, inline(Ops)) :- !.
replace_in_expr(binop(Op, A, B), T, Repl, binop(Op, NA, NB)) :- !,
    replace_in_expr(A, T, Repl, NA),
    replace_in_expr(B, T, Repl, NB).
replace_in_expr(call(Name, Args), T, Repl, call(Name, NArgs)) :- !,
    replace_in_scope(Args, T, Repl, NArgs).
replace_in_expr(@(E), T, Repl, @(NE)) :- !, replace_in_expr(E, T, Repl, NE).
replace_in_expr('c@'(E), T, Repl, 'c@'(NE)) :- !, replace_in_expr(E, T, Repl, NE).
replace_in_expr(!(A, V), T, Repl, !(NA, NV)) :- !,
    replace_in_expr(A, T, Repl, NA),
    replace_in_expr(V, T, Repl, NV).
replace_in_expr('c!'(A, V), T, Repl, 'c!'(NA, NV)) :- !,
    replace_in_expr(A, T, Repl, NA),
    replace_in_expr(V, T, Repl, NV).
replace_in_expr(execute(E), T, Repl, execute(NE)) :- !, replace_in_expr(E, T, Repl, NE).
%% scope boundaries never contain a literal top-level occurrence of T (collect_candidates never reaches inside them) — left untouched
replace_in_expr(if(C, Th, El), _, _, if(C, Th, El)) :- !.
replace_in_expr(while(C, B), _, _, while(C, B)) :- !.
replace_in_expr(let(Bs, B), _, _, let(Bs, B)) :- !.
replace_in_expr(do(Es), _, _, do(Es)) :- !.

%% ============================================================
%% fresh names for hoisted bindings
%% ============================================================

:- dynamic(cse_counter/1).
cse_counter(0).

fresh_cse_name(Fresh) :-
    retract(cse_counter(N)),
    N1 is N + 1,
    assertz(cse_counter(N1)),
    number_chars(N1, NChars),
    phrase((['_', c, s, e, '_'], seq(NChars)), FreshChars),
    atom_chars(Fresh, FreshChars).

%% ============================================================
%% tests
%% ============================================================

:- use_module(parser).
:- use_module(ast).
:- use_module(typecheck).
:- use_module(inline).
:- use_module(constfold).

cse_pipeline(Src, CsedDefs) :-
    parse(Src, ok(Forms)),
    transform_program(Forms, ok(Defs)),
    check_program(Defs, ok(_)),
    infer_effects(Defs, EffEnv),
    inline_calls(Defs, InlinedDefs),
    fold_constants(InlinedDefs, EffEnv, FoldedDefs),
    cse_defs(FoldedDefs, EffEnv, CsedDefs).

%% a duplicate appearing only twice is not profitable to hoist (this is
%% the case that regressed chip8.bin by 4 bytes before this check existed)
?- cse_pipeline("(def g ((a : int) (b : int)) : int (+ (* a b) (* a b)))", Defs),
   member(def(g, _, _, _, [binop(+, binop(*, var(a), var(b)), binop(*, var(a), var(b)))]), Defs),
   cse_stats(Stats), member(hoist-0, Stats).
   true.

%% a third occurrence tips the same duplicate into being profitable
?- cse_pipeline("(def g ((a : int) (b : int)) : int (+ (+ (* a b) (* a b)) (* a b)))", Defs),
   member(def(g, _, _, _, [let([bind(T, binop(*, var(a), var(b)))], [binop(+, binop(+, var(T), var(T)), var(T))])]), Defs),
   cse_stats(Stats), member(hoist-1, Stats).
   true.

%% hoists a duplicate spanning multiple statements, not just one expression
?- cse_pipeline("(def g ((a : int) (b : int)) : void (do (! 100 (* a b)) (! 102 (* a b)) (! 104 (* a b))))", Defs),
   member(def(g, _, _, _, [do([let([bind(T, binop(*, var(a), var(b)))], [!(num(100), var(T)), !(num(102), var(T)), !(num(104), var(T))])])]), Defs),
   cse_stats(Stats), member(hoist-1, Stats).
   true.

%% never hoists across if-branches: different work in each arm stays separate
?- cse_pipeline("(def g ((a : int) (b : int)) : int (if (> a 0) (* a b) (+ a b)))", Defs),
   member(def(g, _, _, _, [if(binop(>, var(a), num(0)), binop(*, var(a), var(b)), binop(+, var(a), var(b)))]), Defs),
   cse_stats(Stats), member(hoist-0, Stats).
   true.

%% identical if-branches merge into "evaluate condition, run the shared branch" — a distinct transformation (branch_merge), not a hoist
?- cse_pipeline("(def g ((a : int) (b : int)) : int (if (> a 0) (* a b) (* a b)))", Defs),
   member(def(g, _, _, _, [do([binop(>, var(a), num(0)), binop(*, var(a), var(b))])]), Defs),
   cse_stats(Stats), member(branch_merge-1, Stats).
   true.

%% no duplicate present -> body is untouched
?- cse_pipeline("(def g ((a : int) (b : int)) : int (+ (* a b) 1))", Defs),
   member(def(g, _, _, _, [binop(+, binop(*, var(a), var(b)), num(1))]), Defs),
   cse_stats(Stats), member(hoist-0, Stats), member(branch_merge-0, Stats).
   true.

%% a profitable duplicated det call (not just a binop) also gets hoisted
?- cse_pipeline("(def f ((x : int) (y : int)) : int (+ x y)) (def g ((a : int) (b : int)) : int (+ (+ (f a b) (f a b)) (f a b)))", Defs),
   member(def(g, _, _, _, [let([bind(T, call(f, [var(a), var(b)]))], [binop(+, binop(+, var(T), var(T)), var(T))])]), Defs),
   cse_stats(Stats), member(hoist-1, Stats).
   true.

%% a single-use det binding inlines at its use site and the let drops entirely
?- cse_pipeline("(def g ((n : int)) : int (let ((y (+ n 1))) (+ y 2)))", Defs),
   member(def(g, _, _, _, [binop(+, binop(+, var(n), num(1)), num(2))]), Defs).
   true.

%% a det binding used zero times is just dead code, dropped entirely
?- cse_pipeline("(def g ((n : int)) : int (let ((y (+ n 1))) 5))", Defs),
   member(def(g, _, _, _, [num(5)]), Defs).
   true.

%% mixed let: the single-use binding inlines, the multi-use sibling stays
?- cse_pipeline("(def g ((n : int)) : int (let ((y (+ n 1)) (z (* n 2))) (+ y (+ z z))))", Defs),
   member(def(g, _, _, _, [let([bind(z, binop(*, var(n), num(2)))], [binop(+, binop(+, var(n), num(1)), binop(+, var(z), var(z)))])]), Defs).
   true.

%% a semidet binding is never inlined regardless of use count — moving it could reorder a memory read around an intervening write
?- cse_pipeline("(const A int 1024) (def g () : int (let ((y (@ A))) (+ y 1)))", Defs),
   member(def(g, _, _, _, [let([bind(y, @(var(A)))], [binop(+, var(y), num(1))])]), Defs).
   true.

%% interaction with [inline]: inline.pl expands a call into a let binding the param name, and this pass inlines that single-use binding too, leaving zero rack overhead
?- cse_pipeline("(def inc ((x : int)) : int [det inline] (+ x 1)) (def g ((n : int)) : int (inc n))", Defs),
   member(def(g, _, _, _, [binop(+, var(n), num(1))]), Defs).
   true.
