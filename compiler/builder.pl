:- module(builder, [
    mk_num/2, mk_str/2, mk_var/2,
    mk_if/4,
    mk_bind/3, mk_let/3, mk_local/3,
    mk_do/2, mk_while/3,
    mk_addr/2, mk_execute/2,
    mk_deref/2, mk_cderef/2, mk_store/3, mk_cstore/3,
    mk_binop/4, mk_call/3,
    mk_inline_asm/2,
    mk_param/3, mk_rest_param/3, mk_type_ptr/2,
    mk_effect/2, mk_effect_inline/2,
    mk_def/5, mk_def/6,
    mk_extern/4, mk_extern/5,
    mk_const/4
]).

%% NOTE: there is a mixed pattern currently, most passes build ast nodes on their own
%% but this will be useful for languages that compile to sets, so i want to use
%% this pattern wherever i can but i wont touch direct build sites

%% every mk_* predicate below is a deterministic smart constructor: it's never
%% used for backtracking search, so a bad argument is always a caller bug, not
%% a search failure. all of them validate and throw builder_error(Context, Why)

:- use_module(library(lists)).
:- use_module(library(error)).
:- use_module(effects).

%% ---- literals & variable references ----

mk_num(N, num(N)) :- check(integer, N, mk_num-n).
mk_str(S, str(S)) :- check(list, S, mk_str-s).
mk_var(Name, var(Name)) :- check(atom, Name, mk_var-name).

%% ---- control flow ----

mk_if(C, T, E, if(C, T, E)) :-
    check(term, C, mk_if-cond), check(term, T, mk_if-then), check(term, E, mk_if-else).
mk_do(Exprs, do(Exprs)) :- check_nonempty_list(Exprs, mk_do-exprs).
mk_while(Cond, Body, while(Cond, Body)) :-
    check(term, Cond, mk_while-cond), check_nonempty_list(Body, mk_while-body).

%% ---- bindings ----

mk_bind(Name, Expr, bind(Name, Expr)) :-
    check(atom, Name, mk_bind-name), check(term, Expr, mk_bind-expr).
mk_let(Bindings, Body, let(Bindings, Body)) :-
    check(list, Bindings, mk_let-bindings), check_nonempty_list(Body, mk_let-body).
mk_local(Bindings, Body, local(Bindings, Body)) :-
    check(list, Bindings, mk_local-bindings), check_nonempty_list(Body, mk_local-body).

%% ---- memory / indirection ----

mk_deref(E, @(E)) :- check(term, E, mk_deref-e).
mk_cderef(E, 'c@'(E)) :- check(term, E, mk_cderef-e).
mk_store(Addr, Val, !(Addr, Val)) :-
    check(term, Addr, mk_store-addr), check(term, Val, mk_store-val).
mk_cstore(Addr, Val, 'c!'(Addr, Val)) :-
    check(term, Addr, mk_cstore-addr), check(term, Val, mk_cstore-val).
mk_addr(Name, addr(Name)) :- check(atom, Name, mk_addr-name).
mk_execute(E, execute(E)) :- check(term, E, mk_execute-e).

%% ---- operators & calls ----

mk_binop(Op, A, B, binop(Op, A, B)) :-
    check(term, A, mk_binop-a), check(term, B, mk_binop-b),
    ( valid_binop(Op) -> true
    ; throw(builder_error(mk_binop-op, invalid_binop(Op)))
    ).

mk_call(Name, Args, call(Name, Args)) :-
    check(atom, Name, mk_call-name), check(list, Args, mk_call-args).

valid_binop(+). valid_binop(-). valid_binop(*). valid_binop(/). valid_binop(mod).
valid_binop(and). valid_binop(or). valid_binop(xor).
valid_binop(=). valid_binop(<). valid_binop(>).
valid_binop('!='). valid_binop(<=). valid_binop(>=).

%% ---- inline VM asm: {op1 op2 ...} ----

mk_inline_asm(Ops, inline(Ops)) :- check(list, Ops, mk_inline_asm-ops).

%% ---- params & types ----

mk_param(Name, Type, param(Name, Type)) :-
    check(atom, Name, mk_param-name), check(term, Type, mk_param-type).
mk_rest_param(Name, Type, rest_param(Name, Type)) :-
    check(atom, Name, mk_rest_param-name), check(term, Type, mk_rest_param-type).
mk_type_ptr(Inner, ptr(Inner)) :- check(term, Inner, mk_type_ptr-inner).

%% ---- effect declarations ----

mk_effect(Level, Level) :-
    ( valid_effect_level(Level) -> true
    ; throw(builder_error(mk_effect-level, invalid_effect_level(Level)))
    ).
mk_effect_inline(Level, inline(Level)) :-
    ( valid_effect_level(Level) -> true
    ; throw(builder_error(mk_effect_inline-level, invalid_effect_level(Level)))
    ).

valid_effect_level(Level) :- effects:effect_level(Level, _).

%% ---- top-level forms ----

%% mk_def/5: no effect annotation (DeclEffect = none)
mk_def(Name, Params, RetType, Body, def(Name, Params, RetType, none, Body)) :-
    check(atom, Name, mk_def-name), check(term, RetType, mk_def-rettype),
    check(list, Params, mk_def-params), check_nonempty_list(Body, mk_def-body).
%% mk_def/6: with an effect annotation (see mk_effect/mk_effect_inline)
mk_def(Name, Params, RetType, Effect, Body, def(Name, Params, RetType, Effect, Body)) :-
    check(atom, Name, mk_def-name), check(term, RetType, mk_def-rettype),
    check(term, Effect, mk_def-effect),
    check(list, Params, mk_def-params), check_nonempty_list(Body, mk_def-body).

mk_extern(Name, ParamTypes, RetType, extern(Name, ParamTypes, RetType)) :-
    check(atom, Name, mk_extern-name), check(term, RetType, mk_extern-rettype),
    check(list, ParamTypes, mk_extern-paramtypes).
mk_extern(Name, Code, ParamTypes, RetType, extern(Name, Code, ParamTypes, RetType)) :-
    check(atom, Name, mk_extern-name), check(integer, Code, mk_extern-code),
    check(term, RetType, mk_extern-rettype), check(list, ParamTypes, mk_extern-paramtypes).

mk_const(Name, Type, Val, const(Name, Type, Val)) :-
    check(atom, Name, mk_const-name), check(term, Type, mk_const-type), check(term, Val, mk_const-val).

%% ---- validation helpers ----

check(Type, Term, Context) :-
    catch(must_be(Type, Term), error(Why, _), throw(builder_error(Context, Why))).

%% must_be(list, _) alone accepts []; several forms require a non-empty body.
check_nonempty_list(List, Context) :-
    check(list, List, Context),
    ( List == [] -> throw(builder_error(Context, empty_body)) ; true ).
