:- module(paren_balance, [paren_balance/2]).

%% ============================================================
%% paren balance checker. runs before the parser to give a
%% useful error location instead of a raw character dump
%% ============================================================

%% paren_balance(+Chars, -Result)
%% Result = ok | error(extra_close, loc(L,C)) | error(unclosed, loc(L,C))
paren_balance(Chars, Result) :-
    paren_scan(Chars, 1, 1, 0, [], Result).

paren_scan([], _, _, 0, _, ok) :- !.
paren_scan([], _, _, _, [open(Ch,L,C)|_], error(unclosed(Ch), loc(L,C))) :- !.
paren_scan(['\n'|Rest], L, _, D, Stk, R) :- !,
    L1 is L+1, paren_scan(Rest, L1, 1, D, Stk, R).
paren_scan([;|Rest], L, _, D, Stk, R) :- !,
    skip_to_nl(Rest, L, Rest1, L1),
    paren_scan(Rest1, L1, 1, D, Stk, R).
paren_scan(['"'|Rest], L, C, D, Stk, R) :- !,
    C1 is C+1, skip_str(Rest, L, C1, Rest1, L1, C2),
    paren_scan(Rest1, L1, C2, D, Stk, R).
paren_scan([Ch|Rest], L, C, D, Stk, R) :-
    open_bracket(Ch), !,
    D1 is D+1, C1 is C+1,
    paren_scan(Rest, L, C1, D1, [open(Ch,L,C)|Stk], R).
paren_scan([Ch|Rest], L, C, D, Stk, R) :-
    close_bracket(Ch), !,
    ( D =:= 0 ->
        R = error(extra_close, loc(L,C))
    ;
        D1 is D-1, C1 is C+1,
        Stk = [_|Stk1],
        paren_scan(Rest, L, C1, D1, Stk1, R)
    ).
paren_scan([_|Rest], L, C, D, Stk, R) :- !,
    C1 is C+1, paren_scan(Rest, L, C1, D, Stk, R).

open_bracket('(').
open_bracket('[').
open_bracket('{').

close_bracket(')').
close_bracket(']').
close_bracket('}').

skip_to_nl([], L, [], L1) :- L1 is L+1.
skip_to_nl(['\n'|Rest], L, Rest, L1) :- !, L1 is L+1.
skip_to_nl([_|Rest], L, Rest1, L1) :- skip_to_nl(Rest, L, Rest1, L1).

skip_str([], L, C, [], L, C).
skip_str(['"'|Rest], L, C, Rest, L, C1) :- !, C1 is C+1.
skip_str(['\n'|Rest], L, _, Rest1, L1, C1) :- !,
    L_ is L+1, skip_str(Rest, L_, 1, Rest1, L1, C1).
skip_str([_|Rest], L, C, Rest1, L1, C1) :-
    C_ is C+1, skip_str(Rest, L, C_, Rest1, L1, C1).
