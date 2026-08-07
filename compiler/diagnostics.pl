:- module(diagnostics, [
    write_stderr/1,
    warn_effects/1,
    warn_dead_code/1,
    warn_inline/1,
    format_typecheck_errors/2,
    format_effect_errors/1,
    format_paren_error/1
]).

:- use_module(library(lists)).
:- use_module(library(dcgs)).
:- use_module(library(charsio)).

%% ============================================================
%% ANSI color helpers
%% ============================================================

esc_code(Codes) :- char_code(Esc, 27), Codes = [Esc, '['].

ansi_color_code(bold,   "1").
ansi_color_code(red,    "1;31").
ansi_color_code(yellow, "1;35").

ansi(Color, Text, Colored) :-
    esc_code(Esc),
    ansi_color_code(Color, Code),
    phrase((seq(Esc), seq(Code), "m", seq(Text), seq(Esc), "0m"), Colored).

%% ============================================================
%% effect annotation warnings to stderr
%% ============================================================

warn_effects([]).
warn_effects([unannotated(Name, Inferred)|Rest]) :-
    atom_chars(Name, NameChars),
    atom_chars(Inferred, InfChars),
    ansi(yellow, "warning:", WarnTag),
    ansi(bold, NameChars, BoldName),
    phrase((seq(WarnTag), " '", seq(BoldName),
            "' has no effect annotation, inferred [", seq(InfChars), "]\n"), Msg),
    write_stderr(Msg),
    warn_effects(Rest).
warn_effects([overpermissive(Name, Decl, Inferred)|Rest]) :-
    atom_chars(Name, NameChars),
    atom_chars(Decl, DeclChars),
    atom_chars(Inferred, InfChars),
    ansi(yellow, "warning:", WarnTag),
    ansi(bold, NameChars, BoldName),
    phrase((seq(WarnTag), " '", seq(BoldName), "' declared [", seq(DeclChars),
            "] but inferred [", seq(InfChars), "] (annotation is too permissive)\n"), Msg),
    write_stderr(Msg),
    warn_effects(Rest).

%% dead code warnings to stderr
warn_dead_code([]).
warn_dead_code([Kind-Name|Rest]) :-
    atom_chars(Name, NameChars),
    kind_label(Kind, KindLabel),
    ansi(yellow, "warning:", WarnTag),
    ansi(bold, NameChars, BoldName),
    phrase((seq(WarnTag), " unused ", seq(KindLabel), " '", seq(BoldName), "'\n"), Msg),
    write_stderr(Msg),
    warn_dead_code(Rest).

%% [inline] hints that can't actually be honored, to stderr
warn_inline([]).
warn_inline([ineligible_variadic(Name)|Rest]) :-
    warn_inline_reason(Name, "has a rest param"),
    warn_inline(Rest).
warn_inline([ineligible_self_recursive(Name)|Rest]) :-
    warn_inline_reason(Name, "calls itself"),
    warn_inline(Rest).

warn_inline_reason(Name, Reason) :-
    atom_chars(Name, NameChars),
    ansi(yellow, "warning:", WarnTag),
    ansi(bold, NameChars, BoldName),
    phrase((seq(WarnTag), " '", seq(BoldName), "' declared [inline] but ",
            seq(Reason), ", ignoring hint\n"), Msg),
    write_stderr(Msg).

kind_label(func,   "function").
kind_label(const,  "const").
kind_label(extern, "extern").

%% ============================================================
%% format typecheck errors to stderr
%% ============================================================

format_typecheck_errors([], _).
format_typecheck_errors([return_type_mismatch(Name, Expected)|Rest], DefLines) :-
    atom_chars(Name, NameCs),
    atom_chars(Expected, ExpCs),
    ( member(Name-Loc, DefLines) -> true ; Loc = unknown ),
    format_loc(Loc, LocCs),
    ansi(bold, LocCs, BoldLoc),
    ansi(red, "error:", ErrTag),
    ansi(bold, NameCs, BoldName),
    phrase((seq(BoldLoc), seq(ErrTag), " '", seq(BoldName),
            "' return type mismatch, expected ", seq(ExpCs), "\n"), Msg),
    write_stderr(Msg),
    format_typecheck_errors(Rest, DefLines).
format_typecheck_errors([type_mismatch(const, Name, Type)|Rest], DefLines) :-
    atom_chars(Name, NameCs),
    atom_chars(Type, TypeCs),
    ( member(Name-Loc, DefLines) -> true ; Loc = unknown ),
    format_loc(Loc, LocCs),
    ansi(bold, LocCs, BoldLoc),
    ansi(red, "error:", ErrTag),
    ansi(bold, NameCs, BoldName),
    phrase((seq(BoldLoc), seq(ErrTag), " const '", seq(BoldName),
            "' type mismatch, declared ", seq(TypeCs), "\n"), Msg),
    write_stderr(Msg),
    format_typecheck_errors(Rest, DefLines).
format_typecheck_errors([while_cond_not_bool|Rest], DefLines) :-
    ansi(red, "error:", ErrTag),
    phrase((seq(ErrTag), " while condition must be bool\n"), Msg),
    write_stderr(Msg),
    format_typecheck_errors(Rest, DefLines).
format_typecheck_errors([type_error(Expr)|Rest], DefLines) :-
    ansi(red, "error:", ErrTag),
    with_output_to(chars(ExprCs), write(Expr)),
    phrase((seq(ErrTag), " type error in expression: ", seq(ExprCs), "\n"), Msg),
    write_stderr(Msg),
    format_typecheck_errors(Rest, DefLines).
format_typecheck_errors([_|Rest], DefLines) :-
    format_typecheck_errors(Rest, DefLines).

%% format effect errors to stdout
format_effect_errors([]).
format_effect_errors([effect_mismatch(Name, Decl, Inferred, Loc)|Rest]) :-
    atom_chars(Name, NameCs),
    atom_chars(Decl, DeclCs),
    atom_chars(Inferred, InfCs),
    format_loc(Loc, LocCs),
    ansi(bold, LocCs, BoldLoc),
    ansi(red, "error:", ErrTag),
    ansi(bold, NameCs, BoldName),
    phrase((seq(BoldLoc), seq(ErrTag), " '", seq(BoldName), "' declared [",
            seq(DeclCs), "] but inferred ", seq(InfCs), "\n"), Msg),
    maplist(put_char, Msg),
    format_effect_errors(Rest).

format_loc(loc(L, C), Cs) :-
    number_chars(L, LCs),
    number_chars(C, CCs),
    phrase((seq(LCs), ":", seq(CCs), ": "), Cs).
format_loc(loc(File, L, C), Cs) :-
    atom_chars(File, FCs),
    number_chars(L, LCs),
    number_chars(C, CCs),
    phrase((seq(FCs), ":", seq(LCs), ":", seq(CCs), ": "), Cs).
format_loc(unknown, "").

%% ============================================================
%% paren-balance error formatting
%% ============================================================

format_paren_error(error(unclosed(Ch), loc(L, C))) :-
    format_loc(loc(L, C), LocCs),
    ansi(bold, LocCs, BoldLoc),
    ansi(red, "error:", ErrTag),
    phrase((seq(BoldLoc), seq(ErrTag), " unclosed '", [Ch], "'\n"), Msg),
    write_stderr(Msg).
format_paren_error(error(extra_close, loc(L, C))) :-
    format_loc(loc(L, C), LocCs),
    ansi(bold, LocCs, BoldLoc),
    ansi(red, "error:", ErrTag),
    phrase((seq(BoldLoc), seq(ErrTag), " unexpected ')'\n"), Msg),
    write_stderr(Msg).

write_stderr(Msg) :-
    maplist(put_char(user_error), Msg).
