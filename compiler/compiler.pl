:- module(compiler, [compile_source/2, compile_source/3, compile_file/2]).
:- use_module(library(between)).

:- use_module(parser).
:- use_module(ast).
:- use_module('../gen/gen').
:- use_module(typecheck).
:- use_module(codegen).
:- use_module(emit).
:- use_module(effects).
:- use_module(deadcode).
:- use_module(constfold).
:- use_module(inline).
:- use_module(locals).

:- use_module(library(lists)).
:- use_module(library(format)).
:- use_module(library(charsio)).
:- use_module(library(iso_ext)).
:- use_module(library(dcgs)).

%% compile_source(+Source, -Result)
%% Result = ok(Bytes) | error(Stage, Detail)
compile_source(Source, Result) :-
    compile_source(Source, binary, Result).

%% compile_source(+Source, +Target, -Result)
%% Target = parsed | ast | typed | ir | binary
compile_source(Source, Target, Result) :-
    %% Stage 1: parse
    parser:parse(Source, ParseResult),
    ( ParseResult \= ok(_) ->
        Result = error(parse, ParseResult)
    ; ParseResult = ok(Forms),
      %% Stage 1.5: meta-expansion ($section, $alloc, $vm-sp, etc.)
      expand_metas(Forms, Expanded, FinalPtr),
      compute_def_lines(Source, DefLines),
      ( Target = parsed ->
          Result = ok(Expanded)
      ;
          compile_from_forms(Expanded, Target, DefLines, FinalPtr, Result)
      )
    ).

%% ============================================================
%% file compilation
%% ============================================================

compile_file(InFile, OutFile) :-
    file_directory(InFile, BaseDir),
    read_source(InFile, Chars),
    compile_source_with_includes(Chars, BaseDir, binary, Result),
    ( Result = ok(Bytes) ->
        write_binary(OutFile, Bytes)
    ;
        halt(1)
    ).

%% compile with include expansion
compile_source_with_includes(Source, BaseDir, Target, Result) :-
    paren_balance(Source, BalCheck),
    ( BalCheck \= ok ->
        format_paren_error(BalCheck),
        Result = error(parse, BalCheck)
    ;
    parser:parse(Source, ParseResult),
    ( ParseResult \= ok(_) ->
        Result = error(parse, ParseResult)
    ; ParseResult = ok(Forms),
      compute_def_lines(Source, MainDefLines),
      expand_includes(Forms, BaseDir, IncExpanded, IncDefLines),
      phrase((seq(MainDefLines), seq(IncDefLines)), DefLines),
      expand_metas(IncExpanded, Expanded, FinalPtr),
      ( Target = parsed ->
          Result = ok(Expanded)
      ;
          compile_from_forms(Expanded, Target, DefLines, FinalPtr, Result)
      )
    )
    ).

%% compile pipeline from already-parsed (and include-expanded) forms
compile_from_forms(Forms, Target, DefLines, SlotBase, Result) :-
    ast:transform_program(Forms, AstResult),
    ( AstResult \= ok(_) ->
        Result = error(ast, AstResult)
    ; AstResult = ok(RawDefs),
      %% Stage 1.7: expand `local` into real per-function memory cells
      locals:expand_locals(RawDefs, SlotBase, Defs, SlotBase1),
      ( Target = ast ->
          Result = ok(Defs)
      ;
          typecheck:check_program(Defs, TcResult),
          ( TcResult \= ok(_) ->
              TcResult = error(TcErrors),
              format_typecheck_errors(TcErrors, DefLines),
              Result = error(typecheck, TcResult)
          ; TcResult = ok(TypedDefs),
            ( Target = typed ->
                Result = ok(TypedDefs)
            ;
                %% Stage 3.5: effect inference
                effects:infer_effects(TypedDefs, EffectEnv),
                ( Target = effects ->
                    Result = ok(EffectEnv)
                ;
                effects:check_annotations(TypedDefs, EffectEnv, DefLines, EffErrors),
                ( EffErrors \= [] ->
                    format_effect_errors(EffErrors),
                    Result = error(effects, EffErrors)
                ;
                %% Stage 3.6: dead code warnings (non-fatal, to stderr)
                deadcode:find_dead_code(TypedDefs, DeadNames),
                warn_dead_code(DeadNames),
                %% Stage 3.6b: effect annotation warnings (non-fatal, to stderr)
                effects:collect_effect_warnings(TypedDefs, EffectEnv, EffWarnings),
                warn_effects(EffWarnings),
                %% Stage 3.65: expand [inline] call sites
                inline:inline_warnings(TypedDefs, InlineWarnings),
                warn_inline(InlineWarnings),
                inline:inline_calls(TypedDefs, InlinedDefs),
                %% Stage 3.7: constant folding for det functions
                constfold:fold_constants(InlinedDefs, EffectEnv, FoldedDefs),
                codegen:compile_program(FoldedDefs, SlotBase1, CgResult),
                ( CgResult \= ok(_) ->
                    Result = error(codegen, CgResult)
                ; CgResult = ok(Tokens),
                  ( Target = ir ->
                      Result = ok(Tokens)
                  ;
                      ( member(label(main), Tokens) ->
                          phrase(([branch(main)], seq(Tokens)), AllTokens),
                          emit:emit_binary(AllTokens, Bytes),
                          Result = ok(Bytes)
                      ;
                          write_stderr("error: no main function defined\n"),
                          Result = error(no_main)
                      )
                  )
                )
                )
                )
            )
          )
      )
    ).

%% ============================================================
%% include expansion
%% ============================================================

expand_includes([], _, [], []).
expand_includes([list([sym('$include'), str(File)])|Rest], BaseDir, Expanded, DefLines) :-
    !,
    atom_chars(BaseDir, BaseDirChars),
    phrase((seq(BaseDirChars), seq(File)), FullPathChars),
    atom_chars(FullPath, FullPathChars),
    read_source(FullPath, IncChars),
    parser:parse(IncChars, IncResult),
    ( IncResult = ok(IncForms) ->
        atom_chars(FileAtom, File),
        compute_def_lines_file(IncChars, FileAtom, FileDefLines),
        file_directory(FullPath, IncDir),
        expand_includes(IncForms, IncDir, ExpandedInc, IncDefLines),
        expand_includes(Rest, BaseDir, ExpandedRest, RestDefLines),
        phrase((seq(ExpandedInc), seq(ExpandedRest)), Expanded),
        phrase((seq(FileDefLines), seq(IncDefLines), seq(RestDefLines)), DefLines)
    ;
        format("include error: ~w: ~w~n", [File, IncResult]),
        halt(1)
    ).
expand_includes([F|Rest], BaseDir, [F|ExpandedRest], DefLines) :-
    expand_includes(Rest, BaseDir, ExpandedRest, DefLines).

%% ============================================================
%% meta-expansion: $vm-sp, $vm-rp, $vm-ip, $cell, $mem,
%%                 ($section addr), ($alloc name size)
%% ============================================================

%% VM layout constants (must match vm.h)
meta_const('$mem',  65535).  %% MEMORY_SIZE
meta_const('$cell', 2).     %% CELL_SIZE
meta_const('$stack-size', 256).
meta_const('$ds-start', DS) :- DS is 65535 - (256 * 2 * 2).
meta_const('$rs-start', RS) :- meta_const('$ds-start', DS), RS is DS + (256 * 2).
meta_const('$vm-sp', A)  :- meta_const('$ds-start', DS), A is DS - 6.
meta_const('$vm-rp', A)  :- meta_const('$ds-start', DS), A is DS - 4.
meta_const('$vm-ip', A)  :- meta_const('$ds-start', DS), A is DS - 2.

%% expand_metas(+Forms, -Expanded, -FinalPtr)
%% Process top-level forms, expanding $-prefixed meta directives.
%% FinalPtr is the allocation pointer after the last $alloc — use as slot base.
expand_metas(Forms, Expanded, FinalPtr) :-
    expand_metas_(Forms, 0, Expanded, FinalPtr).

%% expand_metas_(+Forms, +AllocPtr, -Expanded, -FinalPtr)
expand_metas_([], Ptr, [], Ptr).

%% ($section addr) — set allocation pointer
expand_metas_([list([sym('$section'), num(Addr)])|Rest], _, Expanded, FinalPtr) :-
    !,
    expand_metas_(Rest, Addr, Expanded, FinalPtr).

%% ($alloc name size) — allocate and emit const
expand_metas_([list([sym('$alloc'), sym(Name), num(Size)])|Rest], Ptr, [Const|Expanded], FinalPtr) :-
    !,
    Const = list([sym(const), sym(Name), sym(int), num(Ptr)]),
    NextPtr is Ptr + Size,
    expand_metas_(Rest, NextPtr, Expanded, FinalPtr).

%% any other form — recursively expand meta-expressions inside it
expand_metas_([Form|Rest], Ptr, [Expanded|ExpandedRest], FinalPtr) :-
    expand_meta_expr(Form, Expanded),
    expand_metas_(Rest, Ptr, ExpandedRest, FinalPtr).

%% expand_meta_expr: replace ($vm-sp) etc. with num(N) inside any form
expand_meta_expr(list([sym(Name)]), num(Val)) :-
    meta_const(Name, Val), !.
%% ($op name) -> opcode number
expand_meta_expr(list([sym('$op'), sym(OpName)]), num(Code)) :-
    gen:op(OpName, Code, _, _, _, _), !.
expand_meta_expr(list(Elems), list(ExpandedElems)) :-
    !, maplist(expand_meta_expr, Elems, ExpandedElems).
expand_meta_expr(X, X).

file_directory(Path, Dir) :-
    atom_chars(Path, Chars),
    reverse(Chars, Rev),
    ( append(_, [/|DirRev], Rev) ->
        reverse([/|DirRev], DirChars),
        atom_chars(Dir, DirChars)
    ;
        Dir = ./
    ).

%% ANSI color helpers
esc_code(Codes) :- char_code(Esc, 27), Codes = [Esc, '['].

ansi_color_code(bold,   "1").
ansi_color_code(red,    "1;31").
ansi_color_code(yellow, "1;35").

ansi(Color, Text, Colored) :-
    esc_code(Esc),
    ansi_color_code(Color, Code),
    phrase((seq(Esc), seq(Code), "m", seq(Text), seq(Esc), "0m"), Colored).

ansi_bold(Text, Colored) :- ansi(bold, Text, Colored).
ansi_red(Text, Colored) :- ansi(red, Text, Colored).
ansi_yellow(Text, Colored) :- ansi(yellow, Text, Colored).

%% effect annotation warnings to stderr
warn_effects([]).
warn_effects([unannotated(Name, Inferred)|Rest]) :-
    atom_chars(Name, NameChars),
    atom_chars(Inferred, InfChars),
    ansi_yellow("warning:", WarnTag),
    ansi_bold(NameChars, BoldName),
    phrase((seq(WarnTag), " '", seq(BoldName),
            "' has no effect annotation, inferred [", seq(InfChars), "]\n"), Msg),
    write_stderr(Msg),
    warn_effects(Rest).
warn_effects([overpermissive(Name, Decl, Inferred)|Rest]) :-
    atom_chars(Name, NameChars),
    atom_chars(Decl, DeclChars),
    atom_chars(Inferred, InfChars),
    ansi_yellow("warning:", WarnTag),
    ansi_bold(NameChars, BoldName),
    phrase((seq(WarnTag), " '", seq(BoldName), "' declared [", seq(DeclChars),
            "] but inferred [", seq(InfChars), "] (annotation is too permissive)\n"), Msg),
    write_stderr(Msg),
    warn_effects(Rest).

%% dead code warnings to stderr
warn_dead_code([]).
warn_dead_code([Kind-Name|Rest]) :-
    atom_chars(Name, NameChars),
    kind_label(Kind, KindLabel),
    ansi_yellow("warning:", WarnTag),
    ansi_bold(NameChars, BoldName),
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
    ansi_yellow("warning:", WarnTag),
    ansi_bold(NameChars, BoldName),
    phrase((seq(WarnTag), " '", seq(BoldName), "' declared [inline] but ",
            seq(Reason), ", ignoring hint\n"), Msg),
    write_stderr(Msg).

kind_label(func,   "function").
kind_label(const,  "const").
kind_label(extern, "extern").

%% format typecheck errors to stdout
format_typecheck_errors([], _).
format_typecheck_errors([return_type_mismatch(Name, Expected)|Rest], DefLines) :-
    atom_chars(Name, NameCs),
    atom_chars(Expected, ExpCs),
    ( member(Name-Loc, DefLines) -> true ; Loc = unknown ),
    format_loc(Loc, LocCs),
    ansi_bold(LocCs, BoldLoc),
    ansi_red("error:", ErrTag),
    ansi_bold(NameCs, BoldName),
    phrase((seq(BoldLoc), seq(ErrTag), " '", seq(BoldName),
            "' return type mismatch, expected ", seq(ExpCs), "\n"), Msg),
    write_stderr(Msg),
    format_typecheck_errors(Rest, DefLines).
format_typecheck_errors([type_mismatch(const, Name, Type)|Rest], DefLines) :-
    atom_chars(Name, NameCs),
    atom_chars(Type, TypeCs),
    ( member(Name-Loc, DefLines) -> true ; Loc = unknown ),
    format_loc(Loc, LocCs),
    ansi_bold(LocCs, BoldLoc),
    ansi_red("error:", ErrTag),
    ansi_bold(NameCs, BoldName),
    phrase((seq(BoldLoc), seq(ErrTag), " const '", seq(BoldName),
            "' type mismatch, declared ", seq(TypeCs), "\n"), Msg),
    write_stderr(Msg),
    format_typecheck_errors(Rest, DefLines).
format_typecheck_errors([while_cond_not_bool|Rest], DefLines) :-
    ansi_red("error:", ErrTag),
    phrase((seq(ErrTag), " while condition must be bool\n"), Msg),
    write_stderr(Msg),
    format_typecheck_errors(Rest, DefLines).
format_typecheck_errors([type_error(Expr)|Rest], DefLines) :-
    ansi_red("error:", ErrTag),
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
    ansi_bold(LocCs, BoldLoc),
    ansi_red("error:", ErrTag),
    ansi_bold(NameCs, BoldName),
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
%% paren balance checker — runs before the parser to give a
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
paren_scan(['('|Rest], L, C, D, Stk, R) :- !,
    D1 is D+1, C1 is C+1,
    paren_scan(Rest, L, C1, D1, [open('(',L,C)|Stk], R).
paren_scan([')'|Rest], L, C, D, Stk, R) :- !,
    ( D =:= 0 ->
        R = error(extra_close, loc(L,C))
    ;
        D1 is D-1, C1 is C+1,
        Stk = [_|Stk1],
        paren_scan(Rest, L, C1, D1, Stk1, R)
    ).
paren_scan(['['|Rest], L, C, D, Stk, R) :- !,
    D1 is D+1, C1 is C+1,
    paren_scan(Rest, L, C1, D1, [open('[',L,C)|Stk], R).
paren_scan([']'|Rest], L, C, D, Stk, R) :- !,
    ( D =:= 0 ->
        R = error(extra_close, loc(L,C))
    ;
        D1 is D-1, C1 is C+1,
        Stk = [_|Stk1],
        paren_scan(Rest, L, C1, D1, Stk1, R)
    ).
paren_scan(['{'|Rest], L, C, D, Stk, R) :- !,
    D1 is D+1, C1 is C+1,
    paren_scan(Rest, L, C1, D1, [open('{',L,C)|Stk], R).
paren_scan(['}'|Rest], L, C, D, Stk, R) :- !,
    ( D =:= 0 ->
        R = error(extra_close, loc(L,C))
    ;
        D1 is D-1, C1 is C+1,
        Stk = [_|Stk1],
        paren_scan(Rest, L, C1, D1, Stk1, R)
    ).
paren_scan([_|Rest], L, C, D, Stk, R) :- !,
    C1 is C+1, paren_scan(Rest, L, C1, D, Stk, R).

skip_to_nl([], L, [], L1) :- L1 is L+1.
skip_to_nl(['\n'|Rest], L, Rest, L1) :- !, L1 is L+1.
skip_to_nl([_|Rest], L, Rest1, L1) :- skip_to_nl(Rest, L, Rest1, L1).

skip_str([], L, C, [], L, C).
skip_str(['"'|Rest], L, C, Rest, L, C1) :- !, C1 is C+1.
skip_str(['\n'|Rest], L, _, Rest1, L1, C1) :- !,
    L_ is L+1, skip_str(Rest, L_, 1, Rest1, L1, C1).
skip_str([_|Rest], L, C, Rest1, L1, C1) :-
    C_ is C+1, skip_str(Rest, L, C_, Rest1, L1, C1).

format_paren_error(error(unclosed(Ch), loc(L, C))) :-
    format_loc(loc(L, C), LocCs),
    ansi_bold(LocCs, BoldLoc),
    ansi_red("error:", ErrTag),
    phrase((seq(BoldLoc), seq(ErrTag), " unclosed '", [Ch], "'\n"), Msg),
    write_stderr(Msg).
format_paren_error(error(extra_close, loc(L, C))) :-
    format_loc(loc(L, C), LocCs),
    ansi_bold(LocCs, BoldLoc),
    ansi_red("error:", ErrTag),
    phrase((seq(BoldLoc), seq(ErrTag), " unexpected ')'\n"), Msg),
    write_stderr(Msg).

write_stderr(Msg) :-
    maplist(put_char(user_error), Msg).

read_source(File, Chars) :-
    open(File, read, S),
    get_chars(S, Chars),
    close(S).

%% compute_def_lines(+SourceChars, -Map)
%% Map = [Name-loc(Line,Col), ...] for each (def Name ...) found in source.
compute_def_lines(Source, Map) :-
    phrase(def_lines_(1, 1, Map), Source).

%% compute_def_lines_file(+SourceChars, +FileName, -Map)
%% Map = [Name-loc(File,Line,Col), ...] with filename.
compute_def_lines_file(Source, File, Map) :-
    phrase(def_lines_file_(File, 1, 1, Map), Source).

def_lines_file_(F, L, _, Map) --> ['\n'], !, { L1 is L+1 },
    def_lines_file_(F, L1, 1, Map).
def_lines_file_(F, L, Col, Map) --> [;], !, skip_comment,
    def_lines_file_(F, L, Col, Map).
def_lines_file_(F, L, Col, [Name-loc(F,L,Col)|Map]) -->
    "(def ", !, scan_def_name(NameCs),
    { atom_chars(Name, NameCs),
      length(NameCs, NameLen), Skip is NameLen + 5,  % "(def " is 5 chars
      Col1 is Col + Skip },
    def_lines_file_(F, L, Col1, Map).
def_lines_file_(F, L, Col, Map) --> [_], !, { Col1 is Col+1 },
    def_lines_file_(F, L, Col1, Map).
def_lines_file_(_, _, _, []) --> [].

def_lines_(L, _, Map) --> ['\n'], !, { L1 is L+1 },
    def_lines_(L1, 1, Map).
def_lines_(L, Col, Map) --> [;], !, skip_comment,
    def_lines_(L, Col, Map).
def_lines_(L, Col, [Name-loc(L,Col)|Map]) -->
    "(def ", !, scan_def_name(NameCs),
    { atom_chars(Name, NameCs),
      length(NameCs, NameLen), Skip is NameLen + 5,  % "(def " is 5 chars
      Col1 is Col + Skip },
    def_lines_(L, Col1, Map).
def_lines_(L, Col, Map) --> [_], !, { Col1 is Col+1 },
    def_lines_(L, Col1, Map).
def_lines_(_, _, []) --> [].

scan_def_name([C|Rest]) --> [C],
    { C \= ' ', C \= '\n', C \= '\t', C \= '(', C \= ')' }, !,
    scan_def_name(Rest).
scan_def_name([]) --> [].

skip_comment --> [C], { C \= '\n' }, !, skip_comment.
skip_comment --> [].

get_chars(S, Chars) :-
    get_char(S, C),
    ( C = end_of_file ->
        Chars = []
    ;
        Chars = [C|Rest],
        get_chars(S, Rest)
    ).

write_binary(File, Bytes) :-
    open(File, write, S, [type(binary)]),
    maplist(put_byte(S), Bytes),
    close(S).
