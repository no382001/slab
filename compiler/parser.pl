:- module(parser, [parse/2]).

:- use_module(library(lists)).
:- use_module(library(charsio)).
:- use_module(library(dcgs)).

%% parse(+Chars, -Result)
%% Result = ok(Forms) | error(Msg)
parse(Chars, Result) :-
    ( phrase(program(Forms), Chars, []) ->
        Result = ok(Forms)
    ; phrase(program(Forms), Chars, Rest),
      Rest \= [] ->
        Result = error(unparsed(Rest))
    ;
        Result = error(parse_failed)
    ).

%% ============================================================
%% top-level: list of forms separated by whitespace
%% ============================================================

program([F|Fs]) --> ws, form(F), !, program(Fs).
program([]) --> ws.

%% ============================================================
%% forms — all clauses together to avoid discontiguous warning
%% ============================================================

form(list(Elems))    --> ['('], !, ws, list_elems(Elems), ws, [')'].
form(bracket(Elems)) --> ['['], !, ws, list_elems(Elems), ws, [']'].
form(asm(Elems))     --> ['{'], !, ws, list_elems(Elems), ws, ['}'].
form(str(Cs))        --> ['"'], !, string_content(Cs), ['"'].
form(num(N))         --> num_chars(Ds), { Ds = [_|_], !, number_chars(N, Ds) }.
form(sym(A))         --> sym_chars(Cs), { Cs = [_|_], atom_chars(A, Cs) }.

%% ============================================================
%% list contents
%% ============================================================

list_elems([F|Fs]) --> form(F), !, ws, list_elems(Fs).
list_elems([]) --> [].

%% ============================================================
%% numbers: optional minus then digits
%% ============================================================

num_chars([-|Ds]) --> [-], digits1(Ds).
num_chars(Ds) --> digits1(Ds).

digits1([D|Ds]) --> [D], { D @>= '0', D @=< '9' }, digits0(Ds).

digits0([D|Ds]) --> [D], { D @>= '0', D @=< '9' }, !, digits0(Ds).
digits0([]) --> [].

%% ============================================================
%% symbols: anything that's not whitespace, parens, semicolons, or quotes
%% ============================================================

sym_chars([C|Cs]) --> [C], { sym_char(C) }, !, sym_chars(Cs).
sym_chars([]) --> [].

sym_char(C) :-
    \+ member(C, [' ', '\n', '\t', '\r', '(', ')', '[', ']', '{', '}', '"', ;]).

%% ============================================================
%% string literals
%% ============================================================

string_content([C|Cs]) --> [C], { C \== '"' }, !, string_content(Cs).
string_content([]) --> [].

%% ============================================================
%% whitespace and comments
%% ============================================================

ws --> [C], { ws_char(C) }, !, ws.
ws --> [;], !, skip_to_newline, ws.
ws --> [].

ws_char(' ').
ws_char('\n').
ws_char('\t').
ws_char('\r').

skip_to_newline --> "\n", !.
skip_to_newline --> [_], !, skip_to_newline.
skip_to_newline --> [].

%% ============================================================
%% tests
%% ============================================================

%% atoms
?- parse("hello", R).
   R = ok([sym(hello)]).

?- parse("+", R).
   R = ok([sym(+)]).

?- parse("foo bar", R).
   R = ok([sym(foo), sym(bar)]).

%% numbers
?- parse("42", R).
   R = ok([num(42)]).

?- parse("-7", R).
   R = ok([num(-7)]).

?- parse("0", R).
   R = ok([num(0)]).

%% lists
?- parse("()", R).
   R = ok([list([])]).

?- parse("(+ 1 2)", R).
   R = ok([list([sym(+), num(1), num(2)])]).

?- parse("(if (< x 0) 1 2)", R).
   R = ok([list([sym(if), list([sym(<), sym(x), num(0)]), num(1), num(2)])]).

%% strings
?- parse("\"hello\"", R).
   R = ok([str("hello")]).

%% whitespace / comments
?- parse("  1   2  ", R).
   R = ok([num(1), num(2)]).

?- parse("; this is a comment\n42", R).
   R = ok([num(42)]).

%% function def
?- parse("(def square (x) : int (* x x))", R).
   R = ok([list([sym(def), sym(square), list([sym(x)]), sym(:), sym(int), list([sym(*), sym(x), sym(x)])])]).

%% empty
?- parse("", R).
   R = ok([]).
