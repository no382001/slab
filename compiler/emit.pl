:- module(emit, [emit_binary/2]).

:- use_module(library(lists)).
:- use_module('../gen/gen').

%% ============================================================
%% entry
%% ============================================================

emit_binary(Tokens, Bytes) :-
    collect_labels(Tokens, 0, Labels),
    encode_tokens(Tokens, Labels, Bytes).

%% ============================================================
%% pass 1: collect label -> byte offset mapping
%% ============================================================

collect_labels([], _, []).
collect_labels([label(Name) | Rest], Pos, [Name-Pos | Labels]) :-
    collect_labels(Rest, Pos, Labels).
collect_labels([Token | Rest], Pos, Labels) :-
    Token \= label(_),
    token_size(Token, Size),
    Pos1 is Pos + Size,
    collect_labels(Rest, Pos1, Labels).

%% ============================================================
%% token sizes (in bytes)
%% ============================================================

token_size(op(_), S)      :- gen:cell_size(S).
token_size(lit(_), S)     :- gen:cell_size(C), S is C * 2.     % opcode + value
token_size(rpick(_), S)   :- gen:cell_size(C), S is C * 2.     % opcode + depth
token_size(call(_), S)    :- gen:cell_size(C), S is C * 2.     % opcode + addr
token_size(branch(_), S)  :- gen:cell_size(C), S is C * 2.     % opcode + addr
token_size(zbranch(_), S) :- gen:cell_size(C), S is C * 2.     % opcode + addr
token_size(lit_label(_), S) :- gen:cell_size(C), S is C * 2. % opcode + addr
token_size(byte(_), 1).
token_size(label(_), 0).

%% ============================================================
%% pass 2: encode tokens to bytes
%% ============================================================

encode_tokens([], _, []).
encode_tokens([Token | Rest], Labels, Bytes) :-
    encode_token(Token, Labels, TBytes),
    encode_tokens(Rest, Labels, RestBytes),
    append(TBytes, RestBytes, Bytes).

%% label — emits nothing
encode_token(label(_), _, []).

%% literal: lit opcode + value
encode_token(lit(N), _, Bytes) :-
    opcode(lit, Op),
    gen:cell_size(CS),
    encode_cell(CS, Op, OpBytes),
    encode_cell(CS, N, ValBytes),
    append(OpBytes, ValBytes, Bytes).

%% rpick: rpick opcode + depth
encode_token(rpick(N), _, Bytes) :-
    opcode(rpick, Op),
    gen:cell_size(CS),
    encode_cell(CS, Op, OpBytes),
    encode_cell(CS, N, DepthBytes),
    append(OpBytes, DepthBytes, Bytes).

%% opcode
encode_token(op(Name), _, Bytes) :-
    opcode(Name, Op),
    gen:cell_size(CS),
    encode_cell(CS, Op, Bytes).

%% call label
encode_token(call(Label), Labels, Bytes) :-
    opcode(call, Op),
    member(Label-Addr, Labels),
    gen:cell_size(CS),
    encode_cell(CS, Op, OpBytes),
    encode_cell(CS, Addr, AddrBytes),
    append(OpBytes, AddrBytes, Bytes).

%% branch label
encode_token(branch(Label), Labels, Bytes) :-
    opcode(branch, Op),
    member(Label-Addr, Labels),
    gen:cell_size(CS),
    encode_cell(CS, Op, OpBytes),
    encode_cell(CS, Addr, AddrBytes),
    append(OpBytes, AddrBytes, Bytes).

%% zbranch label
encode_token(zbranch(Label), Labels, Bytes) :-
    opcode('zbranch', Op),
    member(Label-Addr, Labels),
    gen:cell_size(CS),
    encode_cell(CS, Op, OpBytes),
    encode_cell(CS, Addr, AddrBytes),
    append(OpBytes, AddrBytes, Bytes).

%% lit_label: push a label's address as a literal
encode_token(lit_label(Label), Labels, Bytes) :-
    opcode(lit, Op),
    member(Label-Addr, Labels),
    gen:cell_size(CS),
    encode_cell(CS, Op, OpBytes),
    encode_cell(CS, Addr, AddrBytes),
    append(OpBytes, AddrBytes, Bytes).

%% raw byte
encode_token(byte(B), _, [B]).

%% ============================================================
%% cell encoding (little-endian)
%% ============================================================

encode_cell(0, _, []) :- !.
encode_cell(N, Value, [B | Bs]) :-
    N > 0,
    B is Value /\ 0xFF,
    Value1 is Value >> 8,
    N1 is N - 1,
    encode_cell(N1, Value1, Bs).

%% ============================================================
%% opcode lookup (from gen/gen.pl)
%% ============================================================

opcode(Name, Op) :- gen:op(Name, Op, _, _, _, _).
