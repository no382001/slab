:- module(typecheck, [check_program/2]).

:- use_module(library(lists)).

%% ============================================================
%% entry point
%% ============================================================

check_program(Defs, Result) :-
    builtin_env(Builtins),
    build_func_env(Defs, Builtins, FuncEnv),
    check_defs(Defs, FuncEnv, Errors),
    ( Errors = [] ->
        Result = ok(Defs)
    ;
        Result = error(Errors)
    ).

%% built-in functions (from gen/gen.pl trap_type)
:- use_module('../gen/gen').

builtin_env(Env) :-
    findall(func(Name, Params, Ret),
            gen:trap_type(Name, _, Params, Ret),
            Env).

%% ============================================================
%% build function environment from definitions
%% ============================================================

build_func_env([], Env, Env).
build_func_env([def(Name, Params, RetType, _, _Body) | Rest], Acc, Env) :-
    append(FixedParams, [rest_param(_, RestType)], Params), !,
    param_types(FixedParams, PTypes),
    build_func_env(Rest, [funcv(Name, PTypes, RestType, RetType) | Acc], Env).
build_func_env([def(Name, Params, RetType, _, _Body) | Rest], Acc, Env) :-
    param_types(Params, PTypes),
    build_func_env(Rest, [func(Name, PTypes, RetType) | Acc], Env).
build_func_env([extern(Name, PTypes, RetType) | Rest], Acc, Env) :-
    build_func_env(Rest, [func(Name, PTypes, RetType) | Acc], Env).
build_func_env([extern(Name, _, PTypes, RetType) | Rest], Acc, Env) :-
    build_func_env(Rest, [func(Name, PTypes, RetType) | Acc], Env).
build_func_env([const(Name, Type, _) | Rest], Acc, Env) :-
    build_func_env(Rest, [const(Name, Type) | Acc], Env).

param_types([], []).
param_types([param(_, T) | Rest], [T | Ts]) :-
    param_types(Rest, Ts).

%% ============================================================
%% check all definitions
%% ============================================================

check_defs([], _, []).
check_defs([Def | Rest], FuncEnv, Errors) :-
    check_def(Def, FuncEnv, DefErrors),
    check_defs(Rest, FuncEnv, RestErrors),
    append(DefErrors, RestErrors, Errors).

check_def(extern(_, _, _), _, []).
check_def(extern(_, _, _, _), _, []).
check_def(const(Name, Type, Expr), FuncEnv, Errors) :-
    ( infer([], FuncEnv, Expr, ExprType),
      ( types_compatible(Type, ExprType) ; Type = bool, numeric_type(ExprType) ) ->
        Errors = []
    ;
        Errors = [type_mismatch(const, Name, Type)]
    ).
check_def(def(Name, Params, RetType, _, Body), FuncEnv, Errors) :-
    params_to_env(Params, LocalEnv),
    check_body(Body, LocalEnv, FuncEnv, RetType, Name, Errors).

params_to_env([], []).
params_to_env([param(N, T) | Rest], [var(N, T) | Env]) :-
    params_to_env(Rest, Env).
params_to_env([rest_param(N, T)], [var(N, ptr(T)), var(CountName, int)]) :-
    rest_count_name(N, CountName).

rest_count_name(Name, CountName) :- atom_concat(Name, '-count', CountName).

%% ============================================================
%% check function body (list of exprs, last one is return value)
%% ============================================================

check_body([], _, _, void, _, []).
check_body([Expr], Env, FEnv, RetType, FName, Errors) :-
    ( Expr = while(Cond, _), \+ infer(Env, FEnv, Cond, bool) ->
        Errors = [while_cond_not_bool]
    ; infer(Env, FEnv, Expr, ExprType),
      types_compatible(RetType, ExprType) ->
        Errors = []
    ;
        Errors = [return_type_mismatch(FName, RetType)]
    ).
check_body([Expr | Rest], Env, FEnv, RetType, FName, Errors) :-
    Rest = [_|_],
    check_expr_for_side_effects(Env, FEnv, Expr, ExprErrors, Env1),
    check_body(Rest, Env1, FEnv, RetType, FName, RestErrors),
    append(ExprErrors, RestErrors, Errors).

%% expressions used for side effects (middle of body)
check_expr_for_side_effects(Env, FEnv, Expr, Errors, NewEnv) :-
    ( Expr = let(Bindings, _Body) ->
        check_let_bindings(Bindings, Env, FEnv, [], BindErrors, ExtEnv),
        Expr = let(_, LetBody),
        check_let_body(LetBody, ExtEnv, FEnv, LetBodyErrors),
        append(BindErrors, LetBodyErrors, Errors),
        NewEnv = Env  % let doesn't leak scope
    ; Expr = while(Cond, _), \+ infer(Env, FEnv, Cond, bool) ->
        Errors = [while_cond_not_bool],
        NewEnv = Env
    ; infer(Env, FEnv, Expr, _) ->
        Errors = [],
        NewEnv = Env
    ;
        Errors = [type_error(Expr)],
        NewEnv = Env
    ).

%% ============================================================
%% type inference
%% ============================================================

%% literals
infer(_, _, num(_), int).
infer(_, _, str(_), ptr(byte)).

%% variable lookup
infer(Env, _, var(Name), Type) :-
    member(var(Name, Type), Env), !.
infer(_, FEnv, var(Name), Type) :-
    member(const(Name, Type), FEnv).

%% binary arithmetic -> int
infer(Env, FEnv, binop(Op, A, B), int) :-
    member(Op, [+, -, *, /, mod, and, or, xor]),
    infer(Env, FEnv, A, AT),
    infer(Env, FEnv, B, BT),
    numeric_type(AT),
    numeric_type(BT).

%% and/or/xor on two bools is logical, not bitwise -> bool
infer(Env, FEnv, binop(Op, A, B), bool) :-
    member(Op, [and, or, xor]),
    infer(Env, FEnv, A, bool),
    infer(Env, FEnv, B, bool).

%% comparison -> bool
infer(Env, FEnv, binop(Op, A, B), bool) :-
    member(Op, [=, <, >, '!=', <=, >=]),
    infer(Env, FEnv, A, AT),
    infer(Env, FEnv, B, BT),
    numeric_type(AT),
    numeric_type(BT).

%% if -> type of branches (must agree)
infer(Env, FEnv, if(Cond, Then, Else), T) :-
    infer(Env, FEnv, Cond, bool),
    infer(Env, FEnv, Then, T),
    infer(Env, FEnv, Else, T2),
    types_compatible(T, T2).

%% let
infer(Env, FEnv, let(Bindings, Body), T) :-
    eval_bindings(Bindings, Env, FEnv, ExtEnv),
    infer_body(Body, ExtEnv, FEnv, T).

%% do — returns type of last expr
infer(Env, FEnv, do(Exprs), T) :-
    infer_body(Exprs, Env, FEnv, T).

%% while -> void
infer(Env, FEnv, while(Cond, Body), void) :-
    infer(Env, FEnv, Cond, bool),
    infer_body(Body, Env, FEnv, _).

%% '@': ptr(T) -> T, or int -> int (raw address)
infer(Env, FEnv, '@'(E), T) :-
    infer(Env, FEnv, E, ET),
    (ET = ptr(T) ; (numeric_type(ET), T = int)).

%% 'c@': ptr(byte)|int -> byte
infer(Env, FEnv, 'c@'(E), byte) :-
    infer(Env, FEnv, E, ET),
    (ET = ptr(byte) ; numeric_type(ET)).

%% '!': ptr(T) × T -> void, or int addr
infer(Env, FEnv, '!'(Addr, Val), void) :-
    infer(Env, FEnv, Addr, AT),
    (AT = ptr(T) ; (numeric_type(AT), T = int)),
    infer(Env, FEnv, Val, VT),
    types_compatible(T, VT).

%% 'c!': ptr(byte)|int × numeric -> void
infer(Env, FEnv, 'c!'(Addr, Val), void) :-
    infer(Env, FEnv, Addr, AT),
    (AT = ptr(byte) ; numeric_type(AT)),
    infer(Env, FEnv, Val, VT),
    numeric_type(VT).

%% addr: get function address -> int
infer(_, FEnv, addr(Name), int) :-
    member(func(Name, _, _), FEnv).
infer(_, FEnv, addr(Name), int) :-
    member(funcv(Name, _, _, _), FEnv).

%% execute: indirect call -> void
infer(Env, FEnv, execute(E), void) :-
    infer(Env, FEnv, E, ET),
    numeric_type(ET).

%% inline VM ops: escape hatch, typed as int; validates each op name
infer(_, _, inline(Ops), int) :-
    all_known_vm_ops(Ops).

%% function call
infer(Env, FEnv, call(Name, Args), RetType) :-
    member(func(Name, ParamTypes, RetType), FEnv),
    length(ParamTypes, Arity),
    length(Args, Arity),
    check_args(Args, ParamTypes, Env, FEnv).

%% variadic function call
infer(Env, FEnv, call(Name, Args), RetType) :-
    member(funcv(Name, ParamTypes, RestType, RetType), FEnv),
    length(ParamTypes, FixedArity),
    length(Args, TotalArgs),
    TotalArgs >= FixedArity,
    length(FixedArgs, FixedArity),
    append(FixedArgs, RestArgs, Args),
    check_args(FixedArgs, ParamTypes, Env, FEnv),
    check_rest_args(RestArgs, RestType, Env, FEnv).

%% ============================================================
%% helpers
%% ============================================================

infer_body([E], Env, FEnv, T) :-
    infer(Env, FEnv, E, T).
infer_body([E | Rest], Env, FEnv, T) :-
    Rest = [_|_],
    infer(Env, FEnv, E, _),
    infer_body(Rest, Env, FEnv, T).

eval_bindings([], Env, _, Env).
eval_bindings([bind(Name, Expr) | Rest], Env, FEnv, FinalEnv) :-
    infer(Env, FEnv, Expr, T),
    eval_bindings(Rest, [var(Name, T) | Env], FEnv, FinalEnv).

check_let_bindings([], Env, _, _, [], Env).
check_let_bindings([bind(Name, Expr) | Rest], Env, FEnv, Acc, Errors, FinalEnv) :-
    ( infer(Env, FEnv, Expr, T) ->
        check_let_bindings(Rest, [var(Name, T) | Env], FEnv, Acc, Errors, FinalEnv)
    ;
        check_let_bindings(Rest, Env, FEnv, Acc, RestErrors, FinalEnv),
        Errors = [type_error(bind(Name, Expr)) | RestErrors]
    ).

check_let_body([], _, _, []).
check_let_body([E], Env, FEnv, Errors) :-
    ( infer(Env, FEnv, E, _) -> Errors = [] ; Errors = [type_error(E)] ).
check_let_body([E | Rest], Env, FEnv, Errors) :-
    Rest = [_|_],
    ( infer(Env, FEnv, E, _) -> E1Errors = [] ; E1Errors = [type_error(E)] ),
    check_let_body(Rest, Env, FEnv, RestErrors),
    append(E1Errors, RestErrors, Errors).

check_args([], [], _, _).
check_args([A | As], [T | Ts], Env, FEnv) :-
    infer(Env, FEnv, A, AT),
    types_compatible(T, AT),
    check_args(As, Ts, Env, FEnv).

check_rest_args([], _, _, _).
check_rest_args([A | As], T, Env, FEnv) :-
    infer(Env, FEnv, A, AT),
    types_compatible(T, AT),
    check_rest_args(As, T, Env, FEnv).

%% int and byte are interchangeable for arithmetic
%% bool is separate
types_compatible(T, T) :- !.
types_compatible(int, byte) :- !.
types_compatible(byte, int) :- !.
types_compatible(int, ptr(_)) :- !.
types_compatible(ptr(_), int) :- !.

numeric_type(int).
numeric_type(byte).
numeric_type(ptr(_)).

all_known_vm_ops([]).
all_known_vm_ops([Op|Ops]) :-
    ( gen:op(Op, Opcode, _, _, _, _), number(Opcode) ->
        true
    ;
        throw(error(unknown_vm_op(Op), context(inline/0, 'unknown VM op')))
    ),
    all_known_vm_ops(Ops).

%% ============================================================
%% test helper: parse -> ast -> typecheck pipeline
%% ============================================================

:- use_module(parser).
:- use_module(ast).

pipeline(Src, Result) :-
    parse(Src, ParseResult),
    ( ParseResult = ok(Forms) ->
        transform_program(Forms, AstResult),
        ( AstResult = ok(Defs) ->
            check_program(Defs, Result)
        ;
            Result = AstResult
        )
    ;
        Result = ParseResult
    ).

%% ============================================================
%% tests
%% ============================================================

%% basic function typing
?- pipeline("(def id ((x : int)) : int x)", ok(_)).
   true.

?- pipeline("(def add ((a : int) (b : int)) : int (+ a b))", ok(_)).
   true.

?- pipeline("(def lt ((a : int) (b : int)) : bool (< a b))", ok(_)).
   true.

?- pipeline("(def abs ((n : int)) : int (if (< n 0) (- 0 n) n))", ok(_)).
   true.

%% and/or/xor on two bools is logical (bool), not bitwise (int)
?- pipeline("(def f ((a : bool) (b : bool)) : bool (and a b))", ok(_)).
   true.

?- pipeline("(def f ((a : int) (b : int)) : int (and a b))", ok(_)).
   true.

%% type errors
?- pipeline("(def bad ((n : int)) : bool n)", error(_)).
   true.

?- pipeline("(def bad ((n : int)) : int (if (< n 0) 1 (< n 5)))", error(_)).
   true.

?- pipeline("(def bad ((a : bool) (b : int)) : bool (and a b))", error(_)).
   true.

?- pipeline("(def bad () : int x)", error(_)).
   true.

?- pipeline("(def f ((x : int)) : int x) (def g () : int (f 1 2))", error(_)).
   true.

%% let bindings
?- pipeline("(def f ((x : int)) : int (let ((y (+ x 1))) y))", ok(_)).
   true.

%% pointers
?- pipeline("(def f ((p : (ptr int))) : int (@ p))", ok(_)).
   true.

?- pipeline("(def f ((p : (ptr int)) (v : int)) : void (! p v))", ok(_)).
   true.

%% extern
?- pipeline("(extern emit (int) : void) (def f () : void (emit 65))", ok(_)).
   true.

%% const
?- pipeline("(const BUFSIZE int 256) (def f () : int BUFSIZE)", ok(_)).
   true.

%% while
?- pipeline("(def f ((n : int)) : void (while (< n 10) (+ n 1)))", ok(_)).
   true.

%% multi-expr body
?- pipeline("(extern emit (int) : void) (def f ((n : int)) : int (emit n) (+ n 1))", ok(_)).
   true.
