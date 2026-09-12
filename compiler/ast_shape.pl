:- module(ast_shape, [ast_children/2, ast_rebuild/3]).

:- use_module(library(lists)).

%% ast_children(+Expr, -Children)
ast_children(num(_), []).
ast_children(str(_), []).
ast_children(var(_), []).
ast_children(addr(_), []).
ast_children(inline(_), []).
ast_children(binop(_, A, B), [A, B]).
ast_children(if(C, T, E), [C, T, E]).
ast_children(let(Bindings, Body), Children) :-
    binding_exprs(Bindings, BExprs),
    append(BExprs, Body, Children).
ast_children(do(Exprs), Exprs).
ast_children(while(Cond, Body), [Cond|Body]).
ast_children(@(E), [E]).
ast_children('c@'(E), [E]).
ast_children(!(A, V), [A, V]).
ast_children('c!'(A, V), [A, V]).
ast_children(execute(E), [E]).
ast_children(call(_, Args), Args).

binding_exprs([], []).
binding_exprs([bind(_, E)|Rest], [E|Es]) :- binding_exprs(Rest, Es).

%% ast_rebuild(+Expr, +NewChildren, -NewExpr)
ast_rebuild(Expr, [], Expr).
ast_rebuild(binop(Op, _, _), [NA, NB], binop(Op, NA, NB)).
ast_rebuild(if(_, _, _), [NC, NT, NE], if(NC, NT, NE)).
ast_rebuild(let(Bindings, _), Children, let(NBindings, NBody)) :-
    length(Bindings, NB),
    length(NBExprs, NB),
    append(NBExprs, NBody, Children),
    rebuild_bindings(Bindings, NBExprs, NBindings).
ast_rebuild(do(_), NExprs, do(NExprs)).
ast_rebuild(while(_, _), [NCond|NBody], while(NCond, NBody)).
ast_rebuild(@(_), [NE], @(NE)).
ast_rebuild('c@'(_), [NE], 'c@'(NE)).
ast_rebuild(!(_, _), [NA, NV], !(NA, NV)).
ast_rebuild('c!'(_, _), [NA, NV], 'c!'(NA, NV)).
ast_rebuild(execute(_), [NE], execute(NE)).
ast_rebuild(call(Name, _), NArgs, call(Name, NArgs)).

rebuild_bindings([], [], []).
rebuild_bindings([bind(Name, _)|Bs], [NExpr|NEs], [bind(Name, NExpr)|NBs]) :-
    rebuild_bindings(Bs, NEs, NBs).

%% ============================================================
%% tests
%% ============================================================

%% round-trip identity: rebuilding with the same children reproduces the node
?- ast_children(binop(+, num(1), num(2)), Cs), ast_rebuild(binop(+, num(1), num(2)), Cs, E),
   E == binop(+, num(1), num(2)).
   true.

?- ast_children(if(var(a), num(1), num(2)), Cs), ast_rebuild(if(var(a), num(1), num(2)), Cs, E),
   E == if(var(a), num(1), num(2)).
   true.

?- ast_children(let([bind(x, num(1)), bind(y, num(2))], [var(x), var(y)]), Cs),
   ast_rebuild(let([bind(x, num(1)), bind(y, num(2))], [var(x), var(y)]), Cs, E),
   E == let([bind(x, num(1)), bind(y, num(2))], [var(x), var(y)]).
   true.

?- ast_children(while(var(c), [num(1), num(2)]), Cs),
   ast_rebuild(while(var(c), [num(1), num(2)]), Cs, E),
   E == while(var(c), [num(1), num(2)]).
   true.

?- ast_children(call(f, [num(1), num(2), num(3)]), Cs),
   ast_rebuild(call(f, [num(1), num(2), num(3)]), Cs, E),
   E == call(f, [num(1), num(2), num(3)]).
   true.

%% rebuild with different children
?- ast_rebuild(binop(+, num(1), num(2)), [num(9), num(8)], E),
   E == binop(+, num(9), num(8)).
   true.

%% let: binding names survive even when the bound expressions change
?- ast_rebuild(let([bind(x, num(1))], [var(x)]), [num(99), var(z)], E),
   E == let([bind(x, num(99))], [var(z)]).
   true.

%% leaves have no children and rebuild to themselves
?- ast_children(num(42), []), ast_rebuild(num(42), [], num(42)).
   true.

?- ast_children(inline([dup, drop]), []), ast_rebuild(inline([dup, drop]), [], inline([dup, drop])).
   true.
