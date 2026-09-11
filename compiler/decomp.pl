:- module(decomp, [collect_decomp_warnings/3]).

:- use_module(library(lists)).
:- use_module(effects).
:- use_module(cse).

%% ============================================================
%% entry point
%% ============================================================

decomp_threshold(24).

%% collect_decomp_warnings(+Defs, +EffectEnv, -Warnings)
%% Warnings = [decomp(Name, Cost), ...]  one per semidet/nondet
%% function whose largest det sub-expression clears decomp_threshold.
collect_decomp_warnings(Defs, EffectEnv, Warnings) :-
    findall(decomp(Name, Cost),
        ( member(def(Name, _, _, _, Body), Defs),
          member(eff(Name, Eff), EffectEnv),
          ( Eff = semidet ; Eff = nondet ),
          det_regions_list(Body, EffectEnv, Regions),
          Regions \= [],
          max_region_cost(Regions, Cost),
          decomp_threshold(T),
          Cost >= T
        ),
        Warnings).

max_region_cost([R], Cost) :- !, region_cost(R, Cost).
max_region_cost([R|Rs], Cost) :-
    region_cost(R, C1),
    max_region_cost(Rs, C2),
    Cost is max(C1, C2).

region_cost(Expr, Cost) :- cse:estimate_cost(Expr, Cost).


det_regions(Expr, EffectEnv, [Expr]) :-
    infer_expr_effect(Expr, EffectEnv, det), !.
det_regions(Expr, EffectEnv, Regions) :-
    det_region_children(Expr, EffectEnv, Regions).

det_regions_list(Exprs, EffectEnv, Regions) :-
    maplist(det_regions_(EffectEnv), Exprs, RegionsPerExpr),
    append(RegionsPerExpr, Regions).
det_regions_(EffectEnv, Expr, Regions) :- det_regions(Expr, EffectEnv, Regions).

det_region_children(inline(_), _, []).
det_region_children(binop(_, A, B), EffectEnv, Regions) :-
    det_regions_list([A, B], EffectEnv, Regions).
det_region_children(@(E), EffectEnv, Regions) :- det_regions(E, EffectEnv, Regions).
det_region_children('c@'(E), EffectEnv, Regions) :- det_regions(E, EffectEnv, Regions).
det_region_children(!(A, V), EffectEnv, Regions) :- det_regions_list([A, V], EffectEnv, Regions).
det_region_children('c!'(A, V), EffectEnv, Regions) :- det_regions_list([A, V], EffectEnv, Regions).
det_region_children(execute(E), EffectEnv, Regions) :- det_regions(E, EffectEnv, Regions).
det_region_children(if(C, T, E), EffectEnv, Regions) :-
    det_regions_list([C, T, E], EffectEnv, Regions).
det_region_children(while(C, Body), EffectEnv, Regions) :-
    det_regions_list([C|Body], EffectEnv, Regions).
det_region_children(do(Exprs), EffectEnv, Regions) :-
    det_regions_list(Exprs, EffectEnv, Regions).
det_region_children(let(Bindings, Body), EffectEnv, Regions) :-
    binding_exprs(Bindings, BExprs),
    append(BExprs, Body, All),
    det_regions_list(All, EffectEnv, Regions).
det_region_children(call(_, Args), EffectEnv, Regions) :-
    det_regions_list(Args, EffectEnv, Regions).

binding_exprs([], []).
binding_exprs([bind(_, E)|Rest], [E|Es]) :- binding_exprs(Rest, Es).

%% ============================================================
%% tests
%% ============================================================

:- use_module(parser).
:- use_module(ast).
:- use_module(typecheck).

decomp_pipeline(Src, Warnings) :-
    parse(Src, ok(Forms)),
    transform_program(Forms, ok(Defs)),
    check_program(Defs, ok(_)),
    infer_effects(Defs, EffEnv),
    collect_decomp_warnings(Defs, EffEnv, Warnings).

%% a small det expression inside a nondet function doesn't clear the
%% threshold -> no warning
?- decomp_pipeline("(def f () : void (emit (+ 1 2)))", Warnings),
   Warnings == [].
   true.

%% a large det expression inside a nondet function -> flagged
?- decomp_pipeline("(def f () : void (emit (+ (+ (+ (+ 1 2) 3) 4) (+ (+ 5 6) (+ 7 8)))))", Warnings),
   member(decomp(f, _), Warnings).
   true.

%% a fully det function is never flagged, no matter how large its body
?- decomp_pipeline("(def f () : int (+ (+ (+ (+ 1 2) 3) 4) (+ (+ 5 6) (+ 7 8))))", Warnings),
   Warnings == [].
   true.

%% a large det region nested inside a while loop (crossing a scope
%% boundary cse.pl itself never crosses) is still found
?- decomp_pipeline("(def f ((a : int)) : void (while (!= a 0) (emit (+ (+ (+ a 1) 2) (+ (+ a 3) (+ a 4))))))", Warnings),
   member(decomp(f, _), Warnings).
   true.

%% only the largest region per function is reported, not one per pocket
?- decomp_pipeline("(def f ((a : int)) : void (emit (+ (+ (+ a 1) 2) (+ (+ a 3) (+ a 4)))) (emit (+ a 1)))", Warnings),
   length(Warnings, 1).
   true.
