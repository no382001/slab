:- module(ast_shape, [ast_children/2]).

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
