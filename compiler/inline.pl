:- module(inline, [inline_calls/2, inline_warnings/2]).

:- use_module(library(lists)).

inline_calls(Defs, InlinedDefs) :-
    build_inline_fns(Defs, InlineFns),
    maplist(inline_def(InlineFns), Defs, InlinedDefs).

%% inline_warnings(+Defs, -Warnings)
inline_warnings(Defs, Warnings) :-
    findall(W, ineligible_inline(Defs, W), Warnings).

ineligible_inline(Defs, W) :-
    member(def(Name, Params, _, Decl, Body), Defs),
    is_inline(Decl),
    ( has_rest_param(Params) -> W = ineligible_variadic(Name)
    ; calls_name(Body, Name) -> W = ineligible_self_recursive(Name)
    ; fail
    ).

%% Only plain fixed-arity functions declared [level inline] are eligible.
%% A function that (directly) calls itself is excluded
build_inline_fns([], []).
build_inline_fns([def(Name, Params, _, Decl, Body) | Rest], Fns) :-
    is_inline(Decl),
    \+ has_rest_param(Params),
    \+ calls_name(Body, Name),
    !,
    build_inline_fns(Rest, RestFns),
    Fns = [inl(Name, Params, Body) | RestFns].
build_inline_fns([_ | Rest], Fns) :-
    build_inline_fns(Rest, Fns).

is_inline(inline(_)).

has_rest_param(Params) :- member(rest_param(_, _), Params).

%% does any expression in Body contain a call to Name, at any depth?
calls_name(Body, Name) :- member(E, Body), expr_calls_name(E, Name), !.

expr_calls_name(call(Name, _), Name) :- !.
expr_calls_name(call(_, Args), Name) :- !, calls_name(Args, Name).
expr_calls_name(binop(_, A, B), Name) :- !, calls_name([A, B], Name).
expr_calls_name(if(C, T, E), Name) :- !, calls_name([C, T, E], Name).
expr_calls_name(let(Bindings, Body), Name) :-
    !,
    ( member(bind(_, E), Bindings), expr_calls_name(E, Name) -> true
    ; calls_name(Body, Name)
    ).
expr_calls_name(do(Exprs), Name) :- !, calls_name(Exprs, Name).
expr_calls_name(while(Cond, Body), Name) :-
    !,
    ( expr_calls_name(Cond, Name) -> true ; calls_name(Body, Name) ).
expr_calls_name(@(E), Name) :- !, expr_calls_name(E, Name).
expr_calls_name('c@'(E), Name) :- !, expr_calls_name(E, Name).
expr_calls_name(!(A, V), Name) :- !, calls_name([A, V], Name).
expr_calls_name('c!'(A, V), Name) :- !, calls_name([A, V], Name).
expr_calls_name(execute(E), Name) :- !, expr_calls_name(E, Name).

%% ============================================================
%% rewrite one definition's body
%% ============================================================

inline_def(_, const(N, T, V), const(N, T, V)).
inline_def(_, extern(N, P, R), extern(N, P, R)).
inline_def(_, extern(N, C, P, R), extern(N, C, P, R)).
inline_def(InlineFns, def(Name, Params, RetType, Decl, Body), def(Name, Params, RetType, Decl, NewBody)) :-
    max_inline_depth(MaxDepth),
    maplist(inline_expr(InlineFns, MaxDepth), Body, NewBody).

max_inline_depth(8).

%% ============================================================
%% expand inline calls, walking every expression shape
%% ============================================================

inline_expr(_, 0, E, E) :- !.

inline_expr(_, _, num(N), num(N)).
inline_expr(_, _, str(S), str(S)).
inline_expr(_, _, var(V), var(V)).
inline_expr(_, _, addr(N), addr(N)).
inline_expr(_, _, inline(Ops), inline(Ops)).

inline_expr(Fns, D, binop(Op, A, B), binop(Op, IA, IB)) :-
    inline_expr(Fns, D, A, IA),
    inline_expr(Fns, D, B, IB).

inline_expr(Fns, D, if(C, T, E), if(IC, IT, IE)) :-
    inline_expr(Fns, D, C, IC),
    inline_expr(Fns, D, T, IT),
    inline_expr(Fns, D, E, IE).

inline_expr(Fns, D, let(Bindings, Body), let(IBindings, IBody)) :-
    maplist(inline_binding(Fns, D), Bindings, IBindings),
    maplist(inline_expr(Fns, D), Body, IBody).

inline_expr(Fns, D, do(Exprs), do(IExprs)) :-
    maplist(inline_expr(Fns, D), Exprs, IExprs).

inline_expr(Fns, D, while(Cond, Body), while(ICond, IBody)) :-
    inline_expr(Fns, D, Cond, ICond),
    maplist(inline_expr(Fns, D), Body, IBody).

inline_expr(Fns, D, @(E), @(IE)) :- inline_expr(Fns, D, E, IE).
inline_expr(Fns, D, 'c@'(E), 'c@'(IE)) :- inline_expr(Fns, D, E, IE).
inline_expr(Fns, D, !(A, V), !(IA, IV)) :-
    inline_expr(Fns, D, A, IA),
    inline_expr(Fns, D, V, IV).
inline_expr(Fns, D, 'c!'(A, V), 'c!'(IA, IV)) :-
    inline_expr(Fns, D, A, IA),
    inline_expr(Fns, D, V, IV).
inline_expr(Fns, D, execute(E), execute(IE)) :- inline_expr(Fns, D, E, IE).

%% call to an inline-eligible function: expand into a let
inline_expr(Fns, D, call(Name, Args), Result) :-
    member(inl(Name, Params, Body), Fns), !,
    maplist(inline_expr(Fns, D), Args, IArgs),
    fresh_names(Params, Renames),
    bindings_for(Renames, IArgs, Bindings),
    rename_body(Body, Renames, RenamedBody),
    D1 is D - 1,
    maplist(inline_expr(Fns, D1), RenamedBody, InlinedBody),
    Result = let(Bindings, InlinedBody).

%% ordinary call: just recurse into the arguments
inline_expr(Fns, D, call(Name, Args), call(Name, IArgs)) :-
    maplist(inline_expr(Fns, D), Args, IArgs).

inline_binding(Fns, D, bind(Name, Expr), bind(Name, IExpr)) :-
    inline_expr(Fns, D, Expr, IExpr).

%% ============================================================
%% fresh names for a callee's params, one per call site
%% ============================================================

:- dynamic(inline_counter/1).
inline_counter(0).

fresh_names([], []).
fresh_names([param(Name, _) | Rest], [Name-Fresh | RestR]) :-
    retract(inline_counter(N)),
    N1 is N + 1,
    assertz(inline_counter(N1)),
    number_chars(N1, NChars),
    atom_chars(Name, NameChars),
    append(['_', 'i', 'n', 'l', '_' | NChars], ['_' | NameChars], FreshChars),
    atom_chars(Fresh, FreshChars),
    fresh_names(Rest, RestR).

bindings_for([], [], []).
bindings_for([_-Fresh | RestR], [Arg | RestA], [bind(Fresh, Arg) | RestB]) :-
    bindings_for(RestR, RestA, RestB).

%% ============================================================
%% capture-avoiding rename of param references inside the callee body
%% ============================================================

rename_body(Body, Renames, RenamedBody) :-
    maplist(rename_expr(Renames), Body, RenamedBody).

rename_expr(R, var(Name), var(Fresh)) :- member(Name-Fresh, R), !.
rename_expr(_, var(Name), var(Name)).
rename_expr(_, num(N), num(N)).
rename_expr(_, str(S), str(S)).
rename_expr(_, addr(N), addr(N)).
rename_expr(_, inline(Ops), inline(Ops)).

rename_expr(R, binop(Op, A, B), binop(Op, RA, RB)) :-
    rename_expr(R, A, RA),
    rename_expr(R, B, RB).

rename_expr(R, if(C, T, E), if(RC, RT, RE)) :-
    rename_expr(R, C, RC),
    rename_expr(R, T, RT),
    rename_expr(R, E, RE).

%% let* semantics: a binding whose own name shadows an active rename
%% target drops that target for the rest of this let (bindings after it,
%% and the body) — it now refers to the local binding, not the outer param.
rename_expr(R, let(Bindings, Body), let(RBindings, RBody)) :-
    rename_bindings(R, Bindings, RBindings, R1),
    maplist(rename_expr(R1), Body, RBody).

rename_expr(R, do(Exprs), do(RExprs)) :-
    maplist(rename_expr(R), Exprs, RExprs).

rename_expr(R, while(Cond, Body), while(RCond, RBody)) :-
    rename_expr(R, Cond, RCond),
    maplist(rename_expr(R), Body, RBody).

rename_expr(R, @(E), @(RE)) :- rename_expr(R, E, RE).
rename_expr(R, 'c@'(E), 'c@'(RE)) :- rename_expr(R, E, RE).
rename_expr(R, !(A, V), !(RA, RV)) :-
    rename_expr(R, A, RA),
    rename_expr(R, V, RV).
rename_expr(R, 'c!'(A, V), 'c!'(RA, RV)) :-
    rename_expr(R, A, RA),
    rename_expr(R, V, RV).
rename_expr(R, execute(E), execute(RE)) :- rename_expr(R, E, RE).
rename_expr(R, call(Name, Args), call(Name, RArgs)) :-
    maplist(rename_expr(R), Args, RArgs).

rename_bindings(R, [], [], R).
rename_bindings(R, [bind(Name, Expr) | Rest], [bind(Name, RExpr) | RRest], FinalR) :-
    rename_expr(R, Expr, RExpr),
    remove_rename(Name, R, R1),
    rename_bindings(R1, Rest, RRest, FinalR).

%% drop the Name-_ pair from R, if present, leaving order and the rest intact
remove_rename(_, [], []).
remove_rename(Name, [Name-_ | Rest], Rest) :- !.
remove_rename(Name, [Pair | Rest], [Pair | Rest1]) :-
    remove_rename(Name, Rest, Rest1).
