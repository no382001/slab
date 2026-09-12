:- module(effects, [infer_effects/2, effect_join/3, check_annotations/4, collect_effect_warnings/3, effect_level/2, infer_expr_effect/3]).

:- use_module(library(lists)).
:- use_module(ast_shape).

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

%% infer_expr_effect(+Expr, +Env, -Eff)
infer_expr_effect(Expr, Env, Eff) :-
    own_effect(Expr, Env, Own),
    ast_children(Expr, Children),
    infer_body_effect(Children, Env, ChildEff),
    effect_join(Own, ChildEff, Eff).

own_effect(num(_), _, det).
own_effect(str(_), _, det).
own_effect(var(_), _, det).
own_effect(addr(_), _, det).            % just gets an address, no side effect
own_effect(inline(_), _, nondet).       % bc opaque VM ops
own_effect(binop(_, _, _), _, det).
own_effect(if(_, _, _), _, det).
own_effect(let(_, _), _, det).
own_effect(do(_), _, det).
own_effect(while(_, _), _, semidet).    % stateful looping, at minimum
%% memory operations -> semidet
own_effect(@(_), _, semidet).
own_effect('c@'(_), _, semidet).
own_effect(!(_, _), _, semidet).
own_effect('c!'(_, _), _, semidet).
%% execute -> nondet (unknown target)
own_effect(execute(_), _, nondet).
%% function call -> the callee's own effect (builtin, inferred, or an
%% unknown function, which is asssumed to be nondet)
own_effect(call(Name, _), Env, Own) :-
    ( builtin_effect(Name, Own) -> true
    ; member(eff(Name, Own), Env) -> true
    ; Own = nondet
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

infer_body_effect(Exprs, Env, Eff) :-
    maplist(infer_expr_eff(Env), Exprs, Effs),
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
