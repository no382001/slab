:- module(deadcode, [find_dead_code/2]).

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
def_body_refs(const(_, _, _), []).
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
