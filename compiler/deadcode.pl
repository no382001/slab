:- module(deadcode, [find_dead_code/2]).

:- use_module(library(lists)).

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
    append(AllRefs, Refs).

def_body_refs(def(_, _, _, _, Body), Refs) :- body_refs(Body, Refs).
def_body_refs(const(_, _, _), []).
def_body_refs(extern(_, _, _), []).
def_body_refs(extern(_, _, _, _), []).

body_refs(Exprs, Refs) :-
    maplist(expr_refs, Exprs, AllRefs),
    append(AllRefs, Refs).

expr_refs(num(_), []).
expr_refs(str(_), []).
expr_refs(var(Name), [Name]).
expr_refs(addr(Name), [Name]).
expr_refs(execute(E), Refs) :- expr_refs(E, Refs).
expr_refs(@(E), Refs) :- expr_refs(E, Refs).
expr_refs('c@'(E), Refs) :- expr_refs(E, Refs).

expr_refs(!(A, V), Refs) :-
    expr_refs(A, RA), expr_refs(V, RV),
    append(RA, RV, Refs).
expr_refs('c!'(A, V), Refs) :-
    expr_refs(A, RA), expr_refs(V, RV),
    append(RA, RV, Refs).

expr_refs(binop(_, A, B), Refs) :-
    expr_refs(A, RA), expr_refs(B, RB),
    append(RA, RB, Refs).

expr_refs(if(C, T, E), Refs) :-
    expr_refs(C, RC), expr_refs(T, RT), expr_refs(E, RE),
    append(RC, RT, R1), append(R1, RE, Refs).

expr_refs(let(Bindings, Body), Refs) :-
    bindings_refs(Bindings, BR),
    body_refs(Body, BodyR),
    append(BR, BodyR, Refs).

expr_refs(do(Exprs), Refs) :- body_refs(Exprs, Refs).

expr_refs(while(Cond, Body), Refs) :-
    expr_refs(Cond, CR),
    body_refs(Body, BR),
    append(CR, BR, Refs).

expr_refs(call(Name, Args), [Name|ArgRefs]) :-
    args_refs(Args, ArgRefs).

bindings_refs(Bindings, Refs) :-
    maplist(binding_refs, Bindings, AllRefs),
    append(AllRefs, Refs).

binding_refs(bind(_, Expr), Refs) :- expr_refs(Expr, Refs).

args_refs(Args, Refs) :-
    maplist(expr_refs, Args, AllRefs),
    append(AllRefs, Refs).
