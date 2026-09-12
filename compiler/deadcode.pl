:- module(deadcode, [find_dead_code/2, prune_dead_defs/2]).

:- use_module(library(lists)).
:- use_module(library(dcgs)).
:- use_module(ast_shape).

%% ============================================================
%% entry point
%% ============================================================

find_dead_code(Defs, Dead) :-
    collect_defined(Defs, Defined),
    collect_referenced(Defs, Referenced),
    findall(Kind-Name,
        (member(Kind-Name, Defined),
         Name \= main,
         \+ member(Name, Referenced)),
        Dead).

%% ============================================================
%% prune_dead_defs: transitive reachability from main
%% ============================================================

%% prune_dead_defs(+Defs, -LiveDefs)
prune_dead_defs(Defs, LiveDefs) :-
    def_refs_map(Defs, RefsMap),
    reachable_names([main], RefsMap, [], LiveNames),
    findall(Def, (member(Def, Defs), def_name(Def, Name), member(Name, LiveNames)), LiveDefs).

def_name(def(Name, _, _, _, _), Name).
def_name(const(Name, _, _), Name).
def_name(extern(Name, _, _), Name).
def_name(extern(Name, _, _, _), Name).

def_refs_map([], []).
def_refs_map([Def | Rest], [Name-Refs | Map]) :-
    def_name(Def, Name),
    def_body_refs(Def, Refs),
    def_refs_map(Rest, Map).

%% reachable_names(+Frontier, +RefsMap, +Seen0, -Seen)
reachable_names([], _, Seen, Seen).
reachable_names([Name | Rest], RefsMap, Seen0, Seen) :-
    ( member(Name, Seen0) ->
        reachable_names(Rest, RefsMap, Seen0, Seen)
    ;
        ( member(Name-Refs, RefsMap) -> true ; Refs = [] ),
        append(Refs, Rest, Frontier1),
        reachable_names(Frontier1, RefsMap, [Name | Seen0], Seen)
    ).

%% ============================================================
%% collect defined names with their kind
%% ============================================================

collect_defined([], []).
collect_defined([Def|Rest], [Kind-Name|Names]) :-
    Def =.. [Functor, Name | _],
    def_kind(Functor, Kind),
    collect_defined(Rest, Names).

def_kind(def,func).
def_kind(const,const).
def_kind(extern,extern).

%% ============================================================
%% collect all referenced names (calls + addr)
%% ============================================================

collect_referenced(Defs, Refs) :-
    maplist(def_body_refs, Defs, AllRefs),
    phrase(seqq(AllRefs), Refs).

def_body_refs(def(_, _, _, _, Body), Refs) :- body_refs(Body, Refs).
def_body_refs(const(_, _, Val), Refs) :- expr_refs(Val, Refs).
def_body_refs(extern(_, _, _), []).
def_body_refs(extern(_, _, _, _), []).

body_refs(Exprs, Refs) :-
    maplist(expr_refs, Exprs, AllRefs),
    phrase(seqq(AllRefs), Refs).

expr_refs(var(Name), [Name]) :- !.
expr_refs(addr(Name), [Name]) :- !.
expr_refs(call(Name, Args), [Name|ArgRefs]) :- !,
    body_refs(Args, ArgRefs).
expr_refs(Expr, Refs) :-
    ast_children(Expr, Children),
    body_refs(Children, Refs).

%% ============================================================
%% tests
%% ============================================================

%% a function with no remaining callers is pruned
?- prune_dead_defs([def(main, [], void, none, [call(bye, [])]),
                     def(unused, [], int, none, [num(1)])], Live),
   \+ member(def(unused, _, _, _, _), Live),
   member(def(main, _, _, _, _), Live).
   true.

%% a function main calls is kept
?- prune_dead_defs([def(main, [], void, none, [call(helper, [])]),
                     def(helper, [], void, none, [call(bye, [])])], Live),
   member(def(helper, _, _, _, _), Live).
   true.

%% a dead function's own callee is pruned
%% even though it's still "mentioned" inside the dead function's body
?- prune_dead_defs([def(main, [], void, none, [call(bye, [])]),
                     def(dead_a, [], void, none, [call(dead_b, [])]),
                     def(dead_b, [], void, none, [call(bye, [])])], Live),
   \+ member(def(dead_a, _, _, _, _), Live),
   \+ member(def(dead_b, _, _, _, _), Live).
   true.

%% a const referenced only through a live function's body is kept
?- prune_dead_defs([def(main, [], void, none, [var(bufsize)]),
                     const(bufsize, int, num(256))], Live),
   member(const(bufsize, _, _), Live).
   true.

%% a const referenced only through another const's own value is kept
?- prune_dead_defs([def(main, [], void, none, [var(b)]),
                     const(a, int, num(10)),
                     const(b, int, var(a))], Live),
   member(const(a, _, _), Live).
   true.

%% an unreferenced const is pruned
?- prune_dead_defs([def(main, [], void, none, [num(1)]),
                     const(unused_const, int, num(0))], Live),
   \+ member(const(unused_const, _, _), Live).
   true.

%% an extern referenced only through a now-dead function is pruned too
?- prune_dead_defs([def(main, [], void, none, [num(1)]),
                     def(dead_caller, [], void, none, [call(ext, [])]),
                     extern(ext, [], void)], Live),
   \+ member(extern(ext, _, _), Live).
   true.

%% const A referencing const B directly is no longer missed
?- find_dead_code([const(a, int, num(1)), const(b, int, var(a)),
                    def(main, [], void, none, [var(b)])], Dead),
   \+ member(const-a, Dead).
   true.
