:- module(effects, [infer_effects/2, effect_join/3, check_annotations/4, collect_effect_warnings/3]).

:- use_module(library(lists)).

%% ============================================================
%% effect lattice
%% ============================================================

%% ordering: det < semidet < nondet
effect_level(det, 0).
effect_level(semidet, 1).
effect_level(nondet, 2).

%% a declared effect is either none, a bare level, or level+inline
decl_effect_level(none, none) :- !.
decl_effect_level(inline(Level), Level) :- !.
decl_effect_level(Level, Level).

%% join: max of two effects
effect_join(A, B, R) :-
    effect_level(A, LA),
    effect_level(B, LB),
    Max is max(LA, LB),
    effect_level(R, Max).

%% join a list of effects
effect_join_list([], det).
effect_join_list([E|Es], R) :-
    effect_join_list(Es, Rest),
    effect_join(E, Rest, R).

%% ============================================================
%% entry point
%% ============================================================

%% infer_effects(+Defs, -EffectEnv)
%% Fixed-point iteration: start all as det, re-infer until stable.
infer_effects(Defs, EffectEnv) :-
    init_effects(Defs, Init),
    fixpoint(Defs, Init, EffectEnv).

init_effects([], []).
init_effects([def(Name, _, _, _, _)|Rest], [eff(Name, det)|Effs]) :-
    init_effects(Rest, Effs).
init_effects([const(_, _, _)|Rest], Effs) :-
    init_effects(Rest, Effs).
init_effects([extern(_, _, _)|Rest], Effs) :-
    init_effects(Rest, Effs).
init_effects([extern(_, _, _, _)|Rest], Effs) :-
    init_effects(Rest, Effs).

fixpoint(Defs, Env, Result) :-
    infer_all(Defs, Env, NewEnv),
    ( Env = NewEnv ->
        Result = Env
    ;
        fixpoint(Defs, NewEnv, Result)
    ).

infer_all([], Env, Env).
infer_all([def(Name, _, _, _, Body)|Rest], Env, Result) :-
    infer_body_effect(Body, Env, Eff),
    update_effect(Name, Eff, Env, Env1),
    infer_all(Rest, Env1, Result).
infer_all([const(_, _, _)|Rest], Env, Result) :-
    infer_all(Rest, Env, Result).
infer_all([extern(_, _, _)|Rest], Env, Result) :-
    infer_all(Rest, Env, Result).
infer_all([extern(_, _, _, _)|Rest], Env, Result) :-
    infer_all(Rest, Env, Result).

update_effect(Name, Eff, [], [eff(Name, Eff)]).
update_effect(Name, Eff, [eff(Name, _)|Rest], [eff(Name, Eff)|Rest]) :- !.
update_effect(Name, Eff, [Other|Rest], [Other|Rest1]) :-
    update_effect(Name, Eff, Rest, Rest1).

%% ============================================================
%% infer effect of an expression
%% ============================================================

infer_expr_effect(num(_), _, det).
infer_expr_effect(str(_), _, det).
infer_expr_effect(var(_), _, det).

%% memory operations -> semidet
infer_expr_effect(@(E), Env, Eff) :-
    infer_expr_effect(E, Env, ChildEff),
    effect_join(semidet, ChildEff, Eff).
infer_expr_effect('c@'(E), Env, Eff) :-
    infer_expr_effect(E, Env, ChildEff),
    effect_join(semidet, ChildEff, Eff).
infer_expr_effect(!(A, V), Env, Eff) :-
    infer_expr_effect(A, Env, EA),
    infer_expr_effect(V, Env, EV),
    effect_join(EA, EV, EArgs),
    effect_join(semidet, EArgs, Eff).
infer_expr_effect('c!'(A, V), Env, Eff) :-
    infer_expr_effect(A, Env, EA),
    infer_expr_effect(V, Env, EV),
    effect_join(EA, EV, EArgs),
    effect_join(semidet, EArgs, Eff).

%% execute -> nondet (unknown target)
infer_expr_effect(execute(E), Env, Eff) :-
    infer_expr_effect(E, Env, ChildEff),
    effect_join(nondet, ChildEff, Eff).

%% addr -> det (just gets an address, no side effect)
infer_expr_effect(addr(_), _, det).

%% inline VM ops: conservative nondet
infer_expr_effect(inline(_), _, nondet).

%% binary ops -> det + children
infer_expr_effect(binop(_, A, B), Env, Eff) :-
    infer_expr_effect(A, Env, EA),
    infer_expr_effect(B, Env, EB),
    effect_join(EA, EB, Eff).

%% if -> children
infer_expr_effect(if(C, T, E), Env, Eff) :-
    infer_expr_effect(C, Env, EC),
    infer_expr_effect(T, Env, ET),
    infer_expr_effect(E, Env, EE),
    effect_join_list([EC, ET, EE], Eff). % this could be a lambda?

%% let -> bindings + body
infer_expr_effect(let(Bindings, Body), Env, Eff) :-
    infer_bindings_effect(Bindings, Env, EB),
    infer_body_effect(Body, Env, EBody),
    effect_join(EB, EBody, Eff).

%% do -> all children
infer_expr_effect(do(Exprs), Env, Eff) :-
    infer_body_effect(Exprs, Env, Eff).

%% while -> cond + body (semidet at minimum: stateful looping)
infer_expr_effect(while(Cond, Body), Env, Eff) :-
    infer_expr_effect(Cond, Env, EC),
    infer_body_effect(Body, Env, EB),
    effect_join(EC, EB, ChildEff),
    effect_join(semidet, ChildEff, Eff).

%% function call -> callee's effect + args effects
infer_expr_effect(call(Name, Args), Env, Eff) :-
    infer_args_effect(Args, Env, EArgs),
    ( builtin_effect(Name, BEff) ->
        effect_join(BEff, EArgs, Eff)
    ; member(eff(Name, FnEff), Env) ->
        effect_join(FnEff, EArgs, Eff)
    ;
        %% unknown function — assume nondet
        effect_join(nondet, EArgs, Eff)
    ).

%% ============================================================
%% built-in function effects
%% ============================================================

builtin_effect(emit, nondet).
builtin_effect(key, nondet).
builtin_effect(bye, nondet).
builtin_effect('assert-fail', nondet).

%% ============================================================
%% helpers
%% ============================================================

infer_expr_eff(Env, Expr, Eff) :- infer_expr_effect(Expr, Env, Eff).
infer_binding_eff(Env, bind(_, Expr), Eff) :- infer_expr_effect(Expr, Env, Eff).

infer_body_effect(Exprs, Env, Eff) :-
    maplist(infer_expr_eff(Env), Exprs, Effs),
    effect_join_list(Effs, Eff).

infer_args_effect(Args, Env, Eff) :-
    maplist(infer_expr_eff(Env), Args, Effs),
    effect_join_list(Effs, Eff).

infer_bindings_effect(Bindings, Env, Eff) :-
    maplist(infer_binding_eff(Env), Bindings, Effs),
    effect_join_list(Effs, Eff).

%% ============================================================
%% annotation checking
%% ============================================================

%% check_annotations(+Defs, +EffectEnv, +LineMap, -Errors)
%% Verify declared effects are at least as permissive as inferred.
%% LineMap = [Name-Line, ...] mapping def names to source line numbers.
check_annotations([], _, _, []).
check_annotations([def(Name, _, _, Decl, _)|Rest], Env, LineMap, Errors) :-
    decl_effect_level(Decl, Level),
    ( Level = none ->
        check_annotations(Rest, Env, LineMap, Errors)
    ; member(eff(Name, Inferred), Env) ->
        effect_level(Level, DL),
        effect_level(Inferred, IL),
        ( IL > DL ->
            ( member(Name-Loc, LineMap) -> true ; Loc = unknown ),
            Errors = [effect_mismatch(Name, Level, Inferred, Loc)|RestErrors],
            check_annotations(Rest, Env, LineMap, RestErrors)
        ;
            check_annotations(Rest, Env, LineMap, Errors)
        )
    ;
        check_annotations(Rest, Env, LineMap, Errors)
    ).
check_annotations([const(_, _, _)|Rest], Env, LineMap, Errors) :-
    check_annotations(Rest, Env, LineMap, Errors).
check_annotations([extern(_, _, _)|Rest], Env, LineMap, Errors) :-
    check_annotations(Rest, Env, LineMap, Errors).
check_annotations([extern(_, _, _, _)|Rest], Env, LineMap, Errors) :-
    check_annotations(Rest, Env, LineMap, Errors).

%% ============================================================
%% effect warnings (non-fatal, to stderr)
%% ============================================================

%% collect_effect_warnings(+Defs, +EffectEnv, -Warnings)
%% Warnings for unannotated functions and over-permissive annotations.
collect_effect_warnings([], _, []).
collect_effect_warnings([def(Name, _, _, Decl, _)|Rest], Env, Warnings) :-
    decl_effect_level(Decl, Level),
    member(eff(Name, Inferred), Env),
    ( Level = none, Inferred = det ->
        Warnings = [unannotated(Name, Inferred)|RestW]
    ; effect_level(Level, DL),
      effect_level(Inferred, IL),
      IL < DL ->
        Warnings = [overpermissive(Name, Level, Inferred)|RestW]
    ;
        Warnings = RestW
    ),
    collect_effect_warnings(Rest, Env, RestW).
collect_effect_warnings([const(_, _, _)|Rest], Env, Warnings) :-
    collect_effect_warnings(Rest, Env, Warnings).
collect_effect_warnings([extern(_, _, _)|Rest], Env, Warnings) :-
    collect_effect_warnings(Rest, Env, Warnings).
collect_effect_warnings([extern(_, _, _, _)|Rest], Env, Warnings) :-
    collect_effect_warnings(Rest, Env, Warnings).
