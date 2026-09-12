:- module(inline, [inline_calls/2, inline_warnings/2]).

:- use_module(library(lists)).
:- use_module(library(dcgs)).
:- use_module(builder).
:- use_module(constfold).
:- use_module(ast_shape).

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

%% call to an inline-eligible function
inline_expr(Fns, D, call(Name, Args), Result) :-
    member(inl(Name, Params, Body), Fns), !,
    maplist(inline_expr(Fns, D), Args, IArgs),
    fresh_names(Params, Renames),
    bindings_for(Renames, IArgs, Bindings),
    rename_body(Body, Renames, RenamedBody),
    D1 is D - 1,
    maplist(inline_expr(Fns, D1), RenamedBody, InlinedBody),
    builder:mk_let(Bindings, InlinedBody, Result).

%% everything else, including an ordinary (non-inlined) call
inline_expr(Fns, D, Expr, NewExpr) :-
    ast_children(Expr, Children),
    maplist(inline_expr(Fns, D), Children, NewChildren),
    ast_rebuild(Expr, NewChildren, NewExpr).

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
    phrase((['_', i, n, l, '_'], seq(NChars), ['_'], seq(NameChars)), FreshChars),
    atom_chars(Fresh, FreshChars),
    fresh_names(Rest, RestR).

bindings_for([], [], []).
bindings_for([_-Fresh | RestR], [Arg | RestA], [Bind | RestB]) :-
    builder:mk_bind(Fresh, Arg, Bind),
    bindings_for(RestR, RestA, RestB).

%% ============================================================
%% capture-avoiding rename of param references inside the callee body
%% ============================================================

rename_body(Body, Renames, RenamedBody) :-
    maplist(rename_pair_to_subst, Renames, Subs),
    maplist(constfold:subst_vars(Subs), Body, RenamedBody).

rename_pair_to_subst(Name-Fresh, Name-var(Fresh)).
