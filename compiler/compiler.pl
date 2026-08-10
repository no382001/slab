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
:- use_module(cse).
:- use_module(inline).
:- use_module(locals).
:- use_module(diagnostics).
:- use_module(paren_balance).

:- use_module(library(lists)).
:- use_module(library(format)).
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
    paren_balance:paren_balance(Source, BalCheck),
    ( BalCheck \= ok ->
        diagnostics:format_paren_error(BalCheck),
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
              diagnostics:format_typecheck_errors(TcErrors, DefLines),
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
                    diagnostics:format_effect_errors(EffErrors),
                    Result = error(effects, EffErrors)
                ;
                %% Stage 3.6: dead code warnings (non-fatal, to stderr)
                deadcode:find_dead_code(TypedDefs, DeadNames),
                diagnostics:warn_dead_code(DeadNames),
                %% Stage 3.6b: effect annotation warnings (non-fatal, to stderr)
                effects:collect_effect_warnings(TypedDefs, EffectEnv, EffWarnings),
                diagnostics:warn_effects(EffWarnings),
                %% Stage 3.65: expand [inline] call sites
                inline:inline_warnings(TypedDefs, InlineWarnings),
                diagnostics:warn_inline(InlineWarnings),
                inline:inline_calls(TypedDefs, InlinedDefs),
                %% Stage 3.7: constant folding for det functions
                constfold:fold_constants(InlinedDefs, EffectEnv, FoldedDefs),
                %% Stage 3.75: common subexpression elimination
                cse:cse_defs(FoldedDefs, EffectEnv, CsedDefs),
                codegen:compile_program(CsedDefs, SlotBase1, CgResult),
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
                          diagnostics:write_stderr("error: no main function defined\n"),
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
