% -*- mode: Prolog -*-

% Post-processor for the simplified nodes with FQNs that is generated
% by pykythe (see ast_cooked.Base.add_fqns).  The post-processing is
% mainly:
% - add Kythe anchor facts
% - add facts/edges for attributes (e.g., "foo" in self.foo)
% - resolve and process imports
% - in future, things like function call references

% TODO: :- use_module(library(protobufs)).  % instead of outputting JSON

% There are two passes:

% 1. Read in the "cooked" ASTN (see ast_cooked.Base), transform them
%    into a simpler form, and produce (using accumulators):
%    - Kythe facts (e.g., anchors) for all the variables and
%      parameters in the code (but not the attributes)
%    - references and assignments (in the assign/2 facts).
%    Each predicate also returns a "type" result that is used to
%    populate the right-hand-side of assign/2 facts (for statements,
%    a expr/1 term is returned for completeness.  For more details,
%    see node_anchors//2.
% 2. Process the assign/2 and expr/1 facts, by intepreting the
%    expressions and recording the results in a symtab (symbol table),
%    then outputting Kythe facts for the attributes, calls, etc.  Note
%    that expr([]) is a no-op.

% A word on "types" and "eval".

% The input consists of a list of simplified items from the AST.
% For example, this Python line (in class C2's __init__):
%   self.x = 'C2_x'
% is turned into the following (in portray-output format):
%    'AssignExprStmt'{
%        expr: 'StringNode'{astn: [ASTN(1160:1166, "'C2_x'")]},
%        left: 'AtomDotNode'{
%               atom: 'NameRefFqn'{
%                         fqn: str("test_data.simple.C2.__init__.<local>.self"),
%                         name: 'ASTN'(1151:1155, "self") },
%               attr_name: 'ASTN'(1156:1157, "x"),
%               binds: bool("True") } }
%
% When this is read in, it is simplified to:
%   assign(dot([fqn('test_data.simple.C2.__init__.<local>.self')],
%              astn(1156,1157, "x"),
%              '/kythe/edge/defines/binding'),
%          [class('builtin.str', [])])
%                     % (Py2.7 would be __builtin__.str)
%             -- TODO: need to incorporate $PYTHONPATH
%
% To process this, we need to resolve the FQNs (in this case,
% fqn('test_data.simple.C2.__init__.<local>.self') by looking up in
% the symtab, eventually resulting in the dot(...) expression being
% reduced to fqn('test_data.simple.C2.x')).

% The symtab mappings are an ord_union (possibly empty) of:
%     fqn(Fqn) - a global or local name (fully qualified)
%     class(Fqn, Bases)  % Bases is a list of union types
%     func(Fqn, ReturnType)  % ReturnType is a union type
%     import(Fqn, Path)  % TODO: this will probably change somewhat

% There are two flavors of the "eval" predicates, depending on the
% behavior with fqn(Fqn): those ending with ..._and_lookup are for the
% right-hand-side of assignments; they use the symtab to look up any
% resulting Fqn and return the associated value (or add it to symtab
% and return []).  For the left-hand-side of an assignment, the lookup
% isn't done.
%   (Implementation detail: this is done using
%        [ Fqn-Result ]:sym_rej
%   which calls add_kythe_fact_accum/3.
%
% All types are unions (represented as an ordset); [] means that
% there's no information and is effectively "Any". Many of the
% predicates come in two versions: one that works with a type union
% (ordset), and one that works on single "types", such as fqn(...),
% class(...), func(...), etc. -- typically the predicate that works
% with a type union iterates over the single items, calling the
% predicate for single "types", and uses ord_union/3 to combine them
% all. (This use of ord_union ensures that there's no need to
% "flatten" the list and that the single types are kept in a canonical
% order).

% The list of assign(Left, Right) and expr(Right) terms is repeatedly
% reprocessed until no changes occur. When a FQN is first encountered,
% it is put into the symtab with its type (the type is [] if it can't
% be determined) -- when subsequently encountered, any inconsistency
% in type is added to a "reject" list. After a pass is complete, the
% rejects are unioned with the symtab and if there were changes,
% another pass is done. In this way, each expression is repeatedly
% reprocessed until no more changes (in practice, only one or two
% passes are needed).

% TODO: can we remove the kythe_fact accumulator from the first pass
%       and generate all the Kythe information from the second pass?

% TODO: Use QLF: http://www.swi-prolog.org/pldoc/man?section=qlf


:- use_module(library(aggregate), [aggregate_all/3, foreach/2]).
:- use_module(library(assoc), [empty_assoc/1, assoc_to_values/2, get_assoc/3, put_assoc/4,
                               is_assoc/1, gen_assoc/3, min_assoc/3, max_assoc/3]).
:- use_module(library(edcg)).  % requires: ?- pack_install(edcg).
:- use_module(library(filesex), [relative_file_name/3]).
:- use_module(library(http/json), [json_read_dict/2, json_write_dict/3]).
:- use_module(library(optparse), [opt_arguments/3]).
:- use_module(library(ordsets), [list_to_ord_set/2, ord_empty/1, ord_union/3, ord_add_element/3]).
:- use_module(library(pprint), [print_term/2]).
:- use_module(must_once, [must_once/1,
                          must_once_msg/3,
                          must_once/3 as must_once_kythe_fact,
                          must_once/5 as must_once_kythe_fact_expr,
                          must_once/5 as must_once_fqn_sym_rej]).

:- dynamic corpus_root_path_language/4.  % KytheCorpus, KytheRoot, Path, Language
:- dynamic file_contents/1.

:- style_check(+singleton).
:- style_check(+no_effect).
:- style_check(+var_branches).
:- style_check(+discontiguous).
% :- set_prolog_flag(generate_debug_info, false).

% "kythe_fact" accumulator gets FQN anchor facts, in an association
% list, with the key being fact(Source,FactName) or
% edge(Source,EdgeKind,Target) and the value being a dict to be
% output in JSON. (An association list is used rather than a dict
% because the keys are compound terms, not atoms.)
edcg:acc_info(kythe_fact, T, In, Out, kythe_fact_accum(T, In, Out)).

% "expr" accumulator gets expressions that need interpreting.
edcg:acc_info(expr, T, Out, In, Out=[T|In]).

% "sym_rej" accumulator is for symtab + items that need reprocessing.
edcg:acc_info(sym_rej, FqnType, In, Out, sym_rej_accum(FqnType, In, Out)).

edcg:pred_info(must_once_kythe_fact_expr, 1,       [kythe_fact, expr]).

edcg:pred_info(must_once_kythe_fact, 1,            [kythe_fact]).

edcg:pred_info(anchor, 3,                          [kythe_fact]).
edcg:pred_info(dots_and_dotted_name, 3,            [kythe_fact]).
edcg:pred_info(edge, 3,                            [kythe_fact]).
edcg:pred_info(from_import_part, 3,                [kythe_fact]).
edcg:pred_info(kythe_fact, 3,                      [kythe_fact]).
edcg:pred_info(kythe_fact_b64, 3,                  [kythe_fact]).
edcg:pred_info(kythe_file, 1,                      [kythe_fact]).

edcg:pred_info(assign_normalized, 2,               [kythe_fact, expr]).
edcg:pred_info(expr_normalized, 1,                 [kythe_fact, expr]).
edcg:pred_info(kythe_json, 2,                      [kythe_fact, expr]).
edcg:pred_info(node_anchors, 2,                    [kythe_fact, expr]).
edcg:pred_info(node_anchors_impl, 2,               [kythe_fact, expr]).
edcg:pred_info(node_anchors_expr_list, 1,          [kythe_fact, expr]).
edcg:pred_info(node_anchors_import_from, 1,        [kythe_fact, expr]).
edcg:pred_info(node_anchors_list, 2,               [kythe_fact, expr]).

edcg:pred_info(must_once_fqn_sym_rej, 1,           [kythe_fact, sym_rej]).

edcg:pred_info(assign_expr_eval, 1,                [kythe_fact, sym_rej]).
edcg:pred_info(assign_exprs_count, 2,              [kythe_fact, sym_rej]).
edcg:pred_info(assign_exprs_eval_list, 1,          [kythe_fact, sym_rej]).
edcg:pred_info(eval_atom_call_single, 4,           [kythe_fact, sym_rej]).
edcg:pred_info(eval_atom_call_single_list, 4,      [kythe_fact, sym_rej]).
edcg:pred_info(eval_atom_call_union, 3,            [kythe_fact, sym_rej]).
edcg:pred_info(eval_atom_dot_single, 7,            [kythe_fact, sym_rej]).
edcg:pred_info(eval_atom_dot_single_list, 5,       [kythe_fact, sym_rej]).
edcg:pred_info(eval_atom_dot_union, 4,             [kythe_fact, sym_rej]).
edcg:pred_info(eval_atom_dot_union, 5,             [kythe_fact, sym_rej]).
edcg:pred_info(eval_lookup, 2,                     [kythe_fact, sym_rej]).
edcg:pred_info(eval_lookup, 3,                     [kythe_fact, sym_rej]).
edcg:pred_info(eval_lookup_single, 2,              [kythe_fact, sym_rej]).
edcg:pred_info(eval_single_type, 2,                [kythe_fact, sym_rej]).
edcg:pred_info(eval_single_type_and_lookup, 2,     [kythe_fact, sym_rej]).
edcg:pred_info(eval_union_type, 2,                 [kythe_fact, sym_rej]).
edcg:pred_info(eval_union_type, 3,                 [kythe_fact, sym_rej]).
edcg:pred_info(eval_union_type_and_lookup, 2,      [kythe_fact, sym_rej]).
edcg:pred_info(eval_union_type_and_lookup_list, 2, [kythe_fact, sym_rej]).
edcg:pred_info(eval_union_type_list, 2,            [kythe_fact, sym_rej]).

% TODO: process typeshed builtins.
%       also module special attributes:
%           '__build_class__', '__debug__', '__doc__', '__import__',
%           '__loader__', '__name__', '__package__', '__spec__'.

% builtin_names(['ArithmeticError', 'AssertionError', 'AttributeError',
%     'BaseException', 'BlockingIOError', 'BrokenPipeError',
%     'BufferError', 'BytesWarning', 'ChildProcessError',
%     'ConnectionAbortedError', 'ConnectionError',
%     'ConnectionRefusedError', 'ConnectionResetError',
%     'DeprecationWarning', 'EOFError', 'Ellipsis', 'EnvironmentError',
%     'Exception', 'False', 'FileExistsError', 'FileNotFoundError',
%     'FloatingPointError', 'FutureWarning', 'GeneratorExit', 'IOError',
%     'ImportError', 'ImportWarning', 'IndentationError', 'IndexError',
%     'InterruptedError', 'IsADirectoryError', 'KeyError',
%     'KeyboardInterrupt', 'LookupError', 'MemoryError',
%     'ModuleNotFoundError', 'NameError', 'None', 'NotADirectoryError',
%     'NotImplemented', 'NotImplementedError', 'OSError',
%     'OverflowError', 'PendingDeprecationWarning', 'PermissionError',
%     'ProcessLookupError', 'RecursionError', 'ReferenceError',
%     'ResourceWarning', 'RuntimeError', 'RuntimeWarning',
%     'StopAsyncIteration', 'StopIteration', 'SyntaxError',
%     'SyntaxWarning', 'SystemError', 'SystemExit', 'TabError',
%     'TimeoutError', 'True', 'TypeError', 'UnboundLocalError',
%     'UnicodeDecodeError', 'UnicodeEncodeError', 'UnicodeError',
%     'UnicodeTranslateError', 'UnicodeWarning', 'UserWarning',
%     'ValueError', 'Warning', 'ZeroDivisionError', 'abs', 'all', 'any',
%     'ascii', 'bin', 'bool', 'bytearray', 'bytes', 'callable', 'chr',
%     'classmethod', 'compile', 'complex', 'copyright', 'credits',
%     'delattr', 'dict', 'dir', 'divmod', 'enumerate', 'eval', 'exec',
%     'exit', 'filter', 'float', 'format', 'frozenset', 'getattr',
%     'globals', 'hasattr', 'hash', 'help', 'hex', 'id', 'input', 'int',
%     'isinstance', 'issubclass', 'iter', 'len', 'license', 'list',
%     'locals', 'map', 'max', 'memoryview', 'min', 'next', 'object',
%     'oct', 'open', 'ord', 'pow', 'print', 'property', 'quit', 'range',
%     'repr', 'reversed', 'round', 'set', 'setattr', 'slice', 'sorted',
%     'staticmethod', 'str', 'sum', 'super', 'tuple', 'type', 'vars',
%     'zip']).

%! builtin_names(-BuiltinNames:list) is det.
builtin_names([]).  % TODO: use the commented-out list above

%! builtin_name(+BuiltinName:atom) is det.
%! builtin_name(-BuiltinName:atom) is nondet.
%  True if BuiltinName is in the initial Python (builtins) symbol table.
builtin_name(Name) :-
    builtin_names(Names),
    member(Name, Names).

%! initial_symtab(-Symtab:dict) is det.
%  creates a symtab with the contents of typeshed/stdlib/3/builtins.pyi
%  TODO: implement this properly
initial_symtab(Symtab) :-
    (  bagof(BuiltinName-Type,
            (builtin_name(Name),
             atomic_list_concat([builtin, Name], '.', BuiltinName),
             list_to_ord_set([class(BuiltinName, [])], Type)
            ),
            SymtabPairs)
    ;  SymtabPairs = []
    ),
    % TODO: string, number are provisional
    %       also use list_to_ord_set
    % TODO: add builtin.int, etc. should really process builtin.pyi
    dict_create(Symtab, symtab,
                ['builtin.str'-[class('builtin.str', [])],
                 'builtin.Number'-[class('builtin.Number', [])]
                | SymtabPairs]).

:- initialization main.

%! main is det.
%  The main predicate, run during initialization.
main :-
    current_prolog_flag(version, PrologVersion),
    must_once_msg(PrologVersion >= 70713, 'SWI-Prolog version is too old', []),  % Sync this with README.md
    % TODO: optparse has a bug if a longflags contains '_', so using '-' for now.
    OptsSpec = [
        [opt(parsecmd), type(atom), longflags([parsecmd]),
         help('Command for running parser than generates fqn.json file')],
        [opt(kythe_corpus), type(atom), default(''), longflags(['kythe-corpus']),
        help('Value of "corpus" in Kythe facts')],
        [opt(kythe_root), type(atom), default(''), longflags(['kythe-root']),
         help('Value of "root" in Kythe facts')],
        [opt(pythonpath), type(atom), default(''), longflags(['pythonpath']),
         help('Similar to $PYTHONPATH for resolving imports (":"-separated paths)')],
        [opt(rootpath), type(atom), default(''), longflags(['rootpath']),
         help('":"-separated list of paths used to turn an absolute path into a canonical FQN')],
        [opt(python_version), type(integer), default(3), longflags(python_version),
         help('Python major version')]
    ],
    opt_arguments(OptsSpec, Opts0, PositionalArgs),
    must_once_msg(PositionalArgs = [Src], 'Missing/extra positional args', []),
    split_path_string(pythonpath, Opts0, Opts1),
    split_path_string(rootpath, Opts1, Opts),
    memberchk(rootpath(RootPaths), Opts),
    memberchk(pythonpath(PythonPaths), Opts),
    validate_paths(PythonPaths, RootPaths),
    path_to_python_module(Src, RootPaths, SrcFqn),
    must_once(
        parse_and_process_module(SrcFqn, Opts)),
    halt.

%! validate_paths(+PythonPaths:list(atom), RootPaths:list(atom)) is semidet.
validate_paths(PythonPaths, RootPaths) :-
    forall(
        member(P, PythonPaths),
        must_once(
            (member(R, RootPaths),
             starts_with(P, R)))).

%! split_path_string0(+OptName:atom, +Opts0:list, -Opts:list) is det.
%  Find the option given by OptName in Opts0, split the value into
%  components in a list, add back into Opts (can be in a different
%  position in the list).
split_path_string(OptName, Opts0, [NewOpt|Opts1]) :-
    Opt =.. [OptName, PathStr],
    select(Opt, Opts0, Opts1),
    split_atom(PathStr, ':', '', PathList0),
    maplist(absolute_dir, PathList0, PathList),
    NewOpt =.. [OptName, PathList].

%! absolute_dir(+Path0:atom, -AbsPath:atom) is det.
%  Apply absolute_file_name to Path0, giving AbsPath, ensuring it's a directory
%  and appending '/' to the name.
absolute_dir(Path0, AbsPath) :-
    remove_suffix_star(Path0, '/', Path),
    absolute_file_name(Path, AbsPath0, [access(read), file_type(directory), file_errors(fail)]),
    atom_concat(AbsPath0, '/', AbsPath).

%! split_atom(+Atom:atom, +SepChars:atom, +PadChars:atom, -SubAtoms:list(atom)) is det.
%  Like split_string, but result is a list of atoms.
split_atom(Atom, SepChars, PadChars, SubAtoms) :-
    split_string(Atom, SepChars, PadChars, SubString),
    string_list_atom_list(SubString, SubAtoms).

%! string_list_atom_list(+Strings:list(string), -Atoms:list(atom)) is det.
%  Convert a list of strings to a list of atoms.
string_list_atom_list([], []).
string_list_atom_list([S|Ss], [A|As]) :-
    atom_string(A, S),
    string_list_atom_list(Ss, As).

%! starts_with(+Full:atom, +Prefix:atom) is semidet.
%  Test for Full starting with Prefix.
starts_with(Full, Prefix) :-
    starts_with(Full, Prefix, _).

%! starts_with(+Full:atom, +Prefix:atom, -Rest:atom) is semidet.
%  Full = Prefix concat Rest
starts_with(Full, Prefix, Rest) :-
    string_concat(Prefix, RestStr, Full),
    atom_string(Rest, RestStr).

%! remove_suffix_star(+Full:atom, +Suffix:atom, -NoSuffix:atom) is det.
%  Repeatedly removes suffix if present.
remove_suffix_star(Full, Suffix, NoSuffix) :-
    (  atom_concat(Full1, Suffix, Full)
    -> remove_suffix_star(Full1, Suffix, NoSuffix)
    ;  NoSuffix = Full
    ).

%! lookup_module(+Module:atom, +RootPaths:list(atom), -CanonicalPath:atom, -FullPath:atom) is det.
%  Given a module (e.g., 'os.path'), a list of root paths, a list of
%  Python paths, find the file (e.g.,
%  FullPath='/path/to/my/dir/typeshed/stdlib/3/os/path.pyi',
%  CanonicalPath='typeshed/stdlib/3/os/path.pyi').  Assumes that all
%  RootPaths and PythonPaths are absolute form and that the Module has
%  been created by using an entry from PythonPaths that canonicalizes
%  it (see validate_paths/2).
lookup_module(Module, RootPaths, CanonicalPath, FullPath) :-
    module_name_as_path(Module, CanonicalPath),
    member(RootPathPrefix, RootPaths),
    atom_concat(RootPathPrefix, CanonicalPath, FullPath),
    path_to_python_module(FullPath, RootPaths, Fqn),
    must_once_msg(
        Module == Fqn,
        'Derived FQN differs from Module name ... canonical(~q) full(~q)',
        [CanonicalPath, FullPath]).

%! module_name_as_path(+Module:atom, -Path:atom) is nondet.
%! module_name_as_path(-Module:atom, +Path:atom) is nondet.
%  Convert a module ('path.to.module') to a path
%  ('path/to/module.py').  Does not check for existence of the file,
%  nor apply any PythonPath addition or RootPath removal. Backtracks
%  through all solutions. At least one of Module and Path must be
%  instantiated.
module_name_as_path(Module, Path) :-
    (  var(Module)
    -> py_ext(Path0, Path),
       split_atom(Path0, '/', '', ModuleParts),
       atomic_list_concat(ModuleParts, '.', Module)
    ;  split_atom(Module, '.', '', ModuleParts),
       atomic_list_concat(ModuleParts, '/', Path1),
       py_ext(Path1, Path)
    ).

path_to_python_module(Path, RootPaths, Fqn) :-
    canonical_path(Path, RootPaths, CanonicalPath),
    py_ext(CanonicalPath0, CanonicalPath),
    split_atom(CanonicalPath0, '/', '', FqnParts),
    atomic_list_concat(FqnParts, '.', Fqn).

canonical_path(Path, RootPaths, CanonicalPath) :-
    absolute_file_name(Path, AbsPath, [access(read), file_errors(fail)]),
    member(RootPathPart, RootPaths),
    starts_with(AbsPath, RootPathPart, CanonicalPath).

%! parse_and_process_module(+SrcFqn:atom, +Opts) is det.
%  Read in a single file (JSON output from pykythe module, which
%  encodes the AST nodes with FQNs), output Kythe JSON to current
%  output stream.
parse_and_process_module(SrcFqn, Opts) :-
    memberchk(rootpath(RootPaths), Opts),
    lookup_module(SrcFqn, RootPaths, CanonicalSrc, Src),
    SrcInfo = src{src_fqn: SrcFqn,
                  canonical_src: CanonicalSrc,
                  src: Src},
    must_once(
        run_parse_cmd(Opts, Src, SrcFqn, ParsedFile)),
    must_once(
        read_nodes(ParsedFile, Opts, Nodes)),
    do_if(false,
          dump_term('NODES', Nodes)),
    must_once(
        kythe_json(Nodes, SrcInfo, KytheFacts, Exprs)),
    do_if(false,
          dump_term('EXPRS', Exprs, [indent_arguments(auto),
                                     right_margin(72)])),
    must_once(
        assign_exprs(Exprs, Symtab, KytheFacts2)),
    do_if(false,
          dump_term('SYMTAB', Symtab)),
    current_output(KytheStream),
    % write(KytheStream, "%% === Kythe ==="), nl(KytheStream),
    symtab_as_kythe_fact(Symtab, SymtabKytheFact),
    output_kythe_fact(SymtabKytheFact, KytheStream),
    output_kythe_facts(KytheFacts, KytheStream),
    output_kythe_facts(KytheFacts2, KytheStream).

%! run_parse_cmd(+Opts, +Src, +SrcFqn, -OutFile) is det.
%  Run the parse command into a temporary file. (The temp file is
%  automatically deleted on graceful termination.)
%  An alternative would be to run the parse command as a process, into
%  a a pipe. This needs more memory, is more complicated to manage,
%  and is a bit more difficult to debug.
run_parse_cmd(Opts, Src, SrcFqn, OutFile) :-
    must_once_msg(ground(Opts), 'Invalid command line options', []),
    memberchk(parsecmd(ParseCmd), Opts),
    memberchk(kythe_corpus(KytheCorpus), Opts),
    memberchk(kythe_root(KytheRoot), Opts),
    memberchk(python_version(PythonVersion), Opts),
    must_once_msg(memberchk(PythonVersion, [2, 3]), 'Invalid Python version: ~q', [PythonVersion]),
    tmp_file_stream(OutFile, OutFileStream, [encoding(binary), extension('fqn-json')]),
    close(OutFileStream),
    atomic_list_concat(
            [ParseCmd,
             " --kythe-corpus='", KytheCorpus, "'",
             " --kythe-root='", KytheRoot, "'",
             " --python_version='", PythonVersion, "'",
             " --src='", Src, "'",
             " --module='", SrcFqn, "'",
             " --out_fqn_expr='", OutFile, "'"],
            Cmd),
    must_once_msg(shell(Cmd, 0), 'Parse failed', []).

%! symtab_as_kythe_fact(+Symtab, -KytheFactAsJsonDict) is det.
%  Convert the symtab into a Kythe fact.
symtab_as_kythe_fact(Symtab,
                     json{source: Source,
                          fact_name: '/kythe/x-symtab',
                          fact_value: SymtabStr64}) :-
    print_term_cleaned(Symtab,
                       [tab_width(0),
                        indent_arguments(2),
                        right_margin(100)],
                       SymtabStr),
    % TODO: the following is dup-ed from kythe_file//0 but
    %       with Language specified
    base64(SymtabStr, SymtabStr64),
    corpus_root_path_language(KytheCorpus, KytheRoot, Path, Language),
    Source = json{corpus: KytheCorpus, root: KytheRoot, path: Path, language: Language}.


%! read_nodes(+FqnExprPath:atom, +Opts:list, -Nodes) is det.
%  Read the JSON node tree (with FQNs) into Nodes.
read_nodes(FqnExprPath, Opts, Nodes) :-
    open(FqnExprPath, read, FqnExprStream),
    json_read_dict(FqnExprStream, MetaDict),
    assert_meta(MetaDict, Opts),
    json_read_dict(FqnExprStream, JsonDict),
    must_once(
        at_end_of_stream(FqnExprStream)),
    simplify_json(JsonDict, Nodes).

%! assert_meta(+MetaDictJson:dict, +Opts:list) is det.
%  Assert the meta-data as facts. The argument is the Prolog dict form
%  of the first JSON item (see ast_cooked.Meta).
assert_meta(
        _{kind: "Meta",
          slots: _{
            kythe_corpus: _{kind: "str", value: KytheCorpus},
            kythe_root: _{kind: "str", value: KytheRoot},
            path: _{kind: "str", value: Path},
            language: _{kind: "str", value: Language},
            contents_b64: _{kind: "str", value: ContentsB64}}},
        Opts) :-
    retractall(corpus_root_path_language(_KytheCorpus, _KytheRoot, _Path, _Language)),
    retractall(file_contents(_)),
    memberchk(rootpath(RootPaths), Opts),
    canonical_path(Path, RootPaths, CanonicalPath),
    assertz(corpus_root_path_language(KytheCorpus, KytheRoot, CanonicalPath, Language)),
    assertz(file_contents_b64(ContentsB64)).

%! simplify_json(+Json, -Prolog) is det.
%  Simplify the JSON term into more specific dicts, each one
%  distinguished by its tag. The input dicts for base types (str, int,
%  etc.) are turned into simpler functors.
simplify_json([], []).
simplify_json([V|Vs], Values) :-
    maplist(simplify_json, [V|Vs], Values).
simplify_json(_{kind: "str", value: Value}, str(Value)).
simplify_json(_{kind: "int", value: Value}, int(Value)).
simplify_json(_{kind: "bool", value: Value}, bool(Value)).
simplify_json(_{kind: "None"}, none).
simplify_json(_{kind: "dict", items: Items}, Value) :-
    dict_pairs(Items, _, ItemPairs),
    maplist(simplify_json_slot_pair, ItemPairs, ItemPairs2),
    dict_pairs(Value, dict, ItemPairs2).
simplify_json(_{kind: Kind, slots: Slots}, Value) :-
    dict_pairs(Slots, _, SlotPairs),
    maplist(simplify_json_slot_pair, SlotPairs, SlotPairs2),
    atom_string(KindAtom, Kind),
    dict_pairs(Value, KindAtom, SlotPairs2).

%! simplify_json_slot_pair(+KeyValue:pair, -KeyValue2:pair) is det.
simplify_json_slot_pair(Key-Value, Key-Value2) :-
    simplify_json(Value, Value2).

%! kythe_json(+Nodes, +SrcInfo:dict, -KytheFacts:list, -Exprs:list) is det.
%  Wrapper for kythe_json//1.
%  TODO: separate KytheFacts into those that require de-duping and
%        those that can be simply appended (difference list). This is
%        for performance because get_assoc/3 and assoc:insert/5
%        (calling compare/3) are the performance bottleneck.
kythe_json(Node, SrcInfo, KytheFacts, Exprs) :-
    empty_assoc(KytheFacts0),
    kythe_json(Node, SrcInfo, KytheFacts0, KytheFacts1, Exprs, []),  % phrase(kythe_json(Node), KytheFacts, Exprs)
    assoc_to_values(KytheFacts1, KytheFacts).

%! kythe_json(+Nodes)//[kythe_fact, expr] is det.
%  Traverse the Nodes, accumulating in KytheFacts (mostly anchors)
%  and Expr (which will be traversed later, to fill in dynamically
%  created attribtes (e.g., self.foo).
kythe_json(Node, SrcInfo) -->>
    kythe_file(SrcInfo),
    node_anchors(Node, _Expr).

%! kythe_file//[kythe_fact] is det.
%  Generate the KytheFacts at the file level.
kythe_file(SrcInfo) -->>
    % TODO: output x-numlines, x-html ?
    { corpus_root_path_language(KytheCorpus, KytheRoot, Path, _Language) },
    { must_once(Path == SrcInfo.canonical_src) },
    { Source = json{corpus: KytheCorpus, root: KytheRoot, path: Path} },
    kythe_fact(Source, '/kythe/node/kind', 'file'),
    { file_contents_b64(ContentsB64) },
    kythe_fact_b64(Source, '/kythe/text', ContentsB64).

%! node_anchors(+Node, -Type)//[kythe_fact, expr] is det.
%  Extract anchors (with FQNs) from the the AST nodes.  The anchors go
%  into accumulator 'kythe_fact' and the expressions (for further
%  processing) go into accumulator 'expr'. The predicate returns a
%  "type", which is used to populate the right-hand-sides of assign/2
%  terms in the 'expr' accumulator.
node_anchors(Node, Type) -->>
    must_once_kythe_fact_expr(
        node_anchors_impl(Node, Type)).

%! node_anchors_impl(+Node:json_dict, -ExprType)//[kythe_fact, expr] is det.

%   For descriptions of the following, and how they relate to the raw
%   ASTN, see ast_cooked.py.

%   [], [_|_], bool(_), dict(_), int(_), none, str(_), 'Astn'{...}'
%   are all handled by higher-level nodes.
%     (e.g., 'Astn'{start: int(Start), end: int(End), value: str(Value)}}
%     in node_astn/4, which is uesd by 'ArgumentNode', 'AtomDotNode', etc.;
%     str(_) is used by 'Class', 'Func', etc.)

%   assign/2 facts are made up of a left-hand-side (a list) and a
%   right-hand-side (a singleton list or an empty list). These
%   correspond to the LHS and RHS of an expression, and have a few
%   variants:
%     assign(a, [b]) corresponds to the statement `a = b`
%     assign(a, []) corresponds to the definition of a name, e.g. `def foo(a)`
%   expr/1 are like assign/2 but with nothing to assign to (expr([]) is a no-op).

%   See comments at the top of this file on union and single types.

%   The following are handled by the container (e.g., ImportFromStmt):
%     AsNameNode
%     NameRawNode  (from DottedNameNode, ImportFromStmt, etc.)
%     NameNode

node_anchors_impl('AnnAssignStmt'{left_annotation: LeftAnnotation,
                                  expr: Expr,
                                  left: Left},
                  stmt(annassign)) -->>
    expr_normalized(Expr),
    assign_normalized(Left, LeftAnnotation).
node_anchors_impl('ArgumentNode'{name: NameAstn, arg: Arg},
                  todo_arg(Name, ArgType)) -->>
    % ast_raw creates ArgumentNode only for `test '=' test`; all other cases
    % just generate the expr (or similar)
    % TODO: match Name to func def param
    { node_astn(NameAstn, _, _, Name) },
    node_anchors(Arg, ArgType).
node_anchors_impl('AssertStmt'{items: Items},
                  stmt(assert)) -->>
    node_anchors_expr_list(Items).
node_anchors_impl('AssignExprStmt'{expr: Expr, left: Left},
                  stmt(assign)) -->>
    assign_normalized(Left, Expr).
node_anchors_impl('AtomCallNode'{args: Args, atom: Atom},
                  call([AtomType], ArgsType)) -->>
    node_anchors(Atom, AtomType),
    node_anchors_list(Args, ArgsType).
node_anchors_impl('AtomDotNode'{atom: Atom, binds: bool(Binds),
                                attr_name: AttrNameAstn},
                  dot([AtomType], astn(Start, End, AttrName), DotEdgeName)) -->>
    { dot_edge_name(Binds, DotEdgeName) },
    { node_astn(AttrNameAstn, Start, End, AttrName) },
    node_anchors(Atom, AtomType).
node_anchors_impl('AtomSubscriptNode'{atom: Atom,
                                      subscripts: Subscripts},
                  todo_subscr([AtomType])) -->>
    node_anchors(Atom, AtomType),
    node_anchors_list(Subscripts, _).
node_anchors_impl('AugAssignStmt'{augassign: _OpAstn,
                                  expr: Expr,
                                  left: Left},
                  stmt(augassign)) -->>
    % { node_astn(OpAstn, _, _, _Op) },
    expr_normalized(Left),
    expr_normalized(Expr).
node_anchors_impl('BreakStmt'{},
                  stmt(break)) -->> [ ].
node_anchors_impl('Class'{bases: Bases, fqn: str(Fqn), name: NameAstn},
                  class(FqnAtom, BasesType)) -->>
    { atom_string(FqnAtom, Fqn) },
    { node_astn(NameAstn, Start, End, _Token) },
    { signature_node(FqnAtom, Signature) },
    anchor(Start, End, Source),
    edge(Source, '/kythe/edge/defines/binding', FqnAtom),
    kythe_fact(Signature, '/kythe/node/kind', 'record'),
    kythe_fact(Signature, '/kythe/subkind', 'class'),
    node_anchors_list(Bases, BasesType),
    [ class(FqnAtom, BasesType) ]:expr.
node_anchors_impl('CompFor'{for_astn: _ForAstn,
                            for_exprlist: ForExprlist,
                            in_testlist: InTestlist,
                            comp_iter: CompIter},
                  todo_compfor(iter:CompIterType, for:ForExprlistType, in:InTestlistType)) -->>
    node_anchors(ForExprlist, ForExprlistType),
    node_anchors(InTestlist, InTestlistType),
    node_anchors(CompIter, CompIterType).
node_anchors_impl('CompIfCompIterNode'{value_expr: ValueExpr,
                                       comp_iter: CompIter},
                  todo_compifcompiter(ValueExprType, CompIterType)) -->>
    node_anchors(ValueExpr, ValueExprType),
    node_anchors(CompIter, CompIterType).
node_anchors_impl('ContinueStmt'{},
                  stmt(continue)) -->> [ ].
node_anchors_impl('DecoratedStmt'{items: Items},
                  todo_decorated(ItemsType)) -->>
                 node_anchors_list(Items, ItemsType).
node_anchors_impl('DecoratorDottedNameNode'{items: Items},
                  todo_decorator_dottedname(ItemsType)) -->>
    from_dots(Items, ItemsType).
node_anchors_impl('DecoratorsNode'{items: Items},
                  todo_decorators(ItemsType)) -->>
    node_anchors_list(Items, ItemsType).
node_anchors_impl('DelStmt'{items: Items},
                  stmt(del)) -->>
    node_anchors_expr_list(Items).
node_anchors_impl('DictGenListSetMakerCompFor'{value_expr: ValueExpr,
                                               comp_for: CompFor},
                  todo_dictgen(ValueExprType, CompForType)) -->>
    node_anchors(ValueExpr, ValueExprType),
    node_anchors(CompFor, CompForType).
node_anchors_impl('DictKeyValue'{items: Items},
                  todo_dictkeyvaluelist(ItemsType)) -->>
    node_anchors_list(Items, ItemsType).
node_anchors_impl('DictSetMakerNode'{items: Items},
                  todo_dictset(ItemsType)) -->>
    node_anchors_list(Items, ItemsType).
%% DottedNameNode is restricted to import contexts (see also DecoratorDottedNameNode)
node_anchors_impl('DottedNameNode'{items: Items},
                  todo_dottedname(ItemsType)) -->>
    { must_once(
          dotted_name_raw(Items, ItemsType)) }.
node_anchors_impl('EllipsisNode'{}, ellipsis) -->> [ ].
node_anchors_impl('ExceptClauseNode'{expr: Expr,
                                     as_item: AsItem},
                  stmt(except)) -->>
    node_anchors(Expr, ExprType),
    node_anchors(AsItem, AsItemType),
    (  { AsItem = omitted }
    -> [ expr([ExprType]) ]:expr
    ;  [ assign(AsItemType, [ExprType]) ]:expr
    ).
node_anchors_impl('ExprListNode'{items: Items},
                  todo_exprlist(ItemsType)) -->>
    node_anchors_list(Items, ItemsType).
node_anchors_impl('ExprStmt'{expr: Expr},
                  stmt(assign)) -->>
    node_anchors(Expr, ExprType),
    [ expr([ExprType]) ]:expr.
node_anchors_impl('FileInput'{scope_bindings: _ScopeBindings,
                              stmts: Stmts,
                              path: _Path},
                  stmt(file)) -->>
    %% node_anchors(ScopeBindings, _),
    node_anchors_list(Stmts, _).
node_anchors_impl('ForStmt'{for_exprlist:
                            ForExprlist,
                            in_testlist: InTestlist,
                            suite: Suite,
                            else_suite: ElseSuite},
                  stmt(for)) -->>
    node_anchors(ElseSuite, _),  % node_anchors(ElseSuite, stmt(_))
    node_anchors(ForExprlist, _),
    node_anchors(InTestlist, _),
    node_anchors(Suite, _).
node_anchors_impl('Func'{fqn: str(Fqn),
                         name: NameAstn,
                         parameters: Parameters,
                         return_type: ReturnType},
                  func(FqnAtom, [ReturnTypeType])) -->>
    { atom_string(FqnAtom, Fqn) },
    { node_astn(NameAstn, Start, End, _Token) },
    { signature_node(FqnAtom, Signature) },
    anchor(Start, End, Source),
    edge(Source, '/kythe/edge/defines/binding', FqnAtom),
    kythe_fact(Signature, '/kythe/node/kind', 'function'),
    node_anchors_list(Parameters, _),
    node_anchors(ReturnType, ReturnTypeType),
    [ func(FqnAtom, [ReturnTypeType]) ]:expr.
node_anchors_impl('GlobalStmt'{items: Items},
                  stmt(global)) -->>
    node_anchors_expr_list(Items).
node_anchors_impl('IfStmt'{items: Items},
                  stmt(if)) -->>
    node_anchors_list(Items, _).
node_anchors_impl('ImportDottedAsNameFqn'{dotted_name: DottedName,
                                          as_name: AsName},
                  unused_importdotted(DottedNameType, AsNameType)) -->>
    node_anchors(AsName, AsNameType),
    node_anchors(DottedName, DottedNameType).
node_anchors_impl('ImportDottedAsNamesFqn'{items: Items},
                  unused_importdotteds) -->>
    { must_once(map_match('ImportDottedAsNameFqn'{as_name:_, dotted_name: _}, Items)) },  % TODO: remove
    node_anchors_list(Items, _).
node_anchors_impl('ImportFromStmt'{from_name: DotsAndDottedName,
                                   import_part: 'ImportAsNamesNode'{items: ImportPartItems}},
                  unused_importfrom(CombImportPart)) -->>
    must_once_kythe_fact(
        dots_and_dotted_name(DotsAndDottedName, ImportPartItems, CombImportPart)),
    % TOO: ref/import
    node_anchors_import_from(CombImportPart).
node_anchors_impl('ImportFromStmt'{from_name: DotsAndDottedName,
                                   import_part: 'StarNode'{}},
                  unused_importfrom_star) -->>
    must_once_kythe_fact(
        dots_and_dotted_name(DotsAndDottedName, '*', _CombImportPart)),
    % TODO: expand '*'
    % TOO: ref/import
    [ ].
node_anchors_impl('ImportNameFqn'{dotted_as_names: DottedAsNames},
                  unused_import(DottedAsNamesType)) -->>
                 { must_once(DottedAsNames = 'ImportDottedAsNamesFqn'{items:_}) },  % TODO: remove
    node_anchors(DottedAsNames, DottedAsNamesType).

node_anchors_impl('ListMakerNode'{items: Items},
                  todo_list(ItemsType)) -->>
    node_anchors_list(Items, ItemsType).
node_anchors_impl('NameBindsFqn'{fqn: str(Fqn), name: NameAstn},
                  fqn(FqnAtom)) -->>  %% result is same as NameRefFqn
    { atom_string(FqnAtom, Fqn) },
    { node_astn(NameAstn, Start, End, _Token) },
    { signature_node(FqnAtom, Signature) },
    anchor(Start, End, Source),
    edge(Source, '/kythe/edge/defines/binding', FqnAtom),  %% only difference from NameRef
    kythe_fact(Signature, '/kythe/node/kind', 'variable').
node_anchors_impl('NameRefFqn'{fqn: str(Fqn), name: NameAstn},
                  fqn(FqnAtom)) -->>  %% result is same as NameBinds
    { atom_string(FqnAtom, Fqn) },
    { node_astn(NameAstn, Start, End, _Token) },
    anchor(Start, End, Source),
    edge(Source, '/kythe/edge/ref', FqnAtom).  %% only difference from NameBindsFqn
node_anchors_impl('NameRefGenerated'{fqn: str(Fqn)},
                  fqn(FqnAtom)) -->>  %% result is same as NameBinds
    { atom_string(FqnAtom, Fqn) }.
node_anchors_impl('NonLocalStmt'{items: Items},
                  stmt(nonlocal)) -->>
    node_anchors_expr_list(Items).
node_anchors_impl('NumberNode'{astn: _Astn},
                  class('builtin.Number', [])) -->> [ ].
node_anchors_impl('OmittedNode'{}, omitted) -->> [ ].
node_anchors_impl('OpNode'{args: Args, op_astns: OpAstns},
                  call_op(OpAstns, ArgsType)) -->>
    node_anchors_list(Args, ArgsType).
node_anchors_impl('PassStmt'{},
                  stmt(break)) -->> [ ].
node_anchors_impl('RaiseStmt'{items: Items},
                  stmt(raise)) -->>
    node_anchors_list(Items, _).
node_anchors_impl('StarNode'{},
                  star) -->> [ ].  % TODO: can we get rid of this in ast_cooked?
node_anchors_impl('Stmts'{items: Items},
                  todo_expr(stmts)) -->>
    node_anchors_list(Items, _).
node_anchors_impl('StringNode'{astns: _Astns},
                  class('builtin.str', [])) -->> [ ].
node_anchors_impl('SubscriptNode'{expr1: Expr1, expr2: Expr2, expr3: Expr3},
                  subscr([Expr1Type, Expr2Type, Expr3Type])) -->>
    node_anchors(Expr1, Expr1Type),
    node_anchors(Expr2, Expr2Type),
    node_anchors(Expr3, Expr3Type).
node_anchors_impl('TnameNode'{name: Name, type_expr: TypeType},
                  stmt(tname)) -->>
    assign_normalized(Name, TypeType).
node_anchors_impl('TryStmt'{items: Items},
                  stmt(try)) -->>
    node_anchors_list(Items, _).
node_anchors_impl('TypedArgNode'{tname: 'TnameNode'{name: Name,
                                                    type_expr: TypeExpr},
                                 expr: Expr},
                  todo_typedarg()) -->>
    assign_normalized(Name, TypeExpr),
    expr_normalized(Expr).  %% assign_normalized(Name, Expr) would cause duplicate facts
node_anchors_impl('WhileStmt'{else_suite: ElseSuite,
                              suite: Suite,
                              test: Test},
                  stmt(while)) -->>
    node_anchors(ElseSuite, _),
    node_anchors(Suite, _),
    node_anchors(Test, _).
node_anchors_impl('WithItemNode'{item: Item,
                                 as_item: AsItem},
                  stmt(with_item)) -->>
    node_anchors(Item, ItemType),
    node_anchors(AsItem, AsItemType),
    (  { AsItemType = omitted }
    -> [ expr([ItemType]) ]:expr
    ;  [ assign(AsItemType, [ItemType]) ]:expr
    ).
node_anchors_impl('WithStmt'{items: Items, suite: Suite},
                  stmt(with)) -->>
    node_anchors_list(Items, _),  % handled by WithItemNode
    node_anchors(Suite, _).

% TODO: need to update with file lookup etc.
% TODO: add module info into symtab for handling recursive imports
%! dots_and_dotted_name(+DotsAndDottedName, +ImportPart, -CombImportPart)//[kythe_fact] is det.
%  The name is zero or more ImportDotNode's followed by zero or one
%  DottedNameNode. If there are no ImportDotNode's, then the result is
%  $PYTHONPATH.DottedName/ImportPart. If there are ImportDotNode's,
%  then the result is FilePath/ImportPart, where FilePath is derived
%  from the Meta information for the file, followed by '/..' as
%  needed.
dots_and_dotted_name(DotsAndDottedName, ImportPart, CombImportPart) -->>
    { corpus_root_path_language(_KytheCorpus, _KytheRoot, Path, _Language) },
    { must_once(
          py_ext(PathBase, Path)) },
    { from_dots_import(DotsAndDottedName, PathBase, Dots, DottedNameList) },
    { atomic_list_concat(DottedNameList, '.', DottedName) },
    (  { Dots = [] }
    -> { atomic_list_concat(['$PYTHONPATH/', DottedName], FullFromName) }
    ;  { atomic_list_concat(Dots, FullFromName) }
    ),
    from_import_part(ImportPart, FullFromName, CombImportPart).

%! py_ext(+Path:atom, -PathBase:atom is nondet.
%! py_ext(-Path:atom, +PathBase:atom is nondet.
%  Path unifies with all permutations of PathBase plus {.py,.pyi} and
%  __init_ equivalents
py_ext(PathBase, Path) :-
    % TODO: allow more than .py and .pyi as extensions?
    % TODO: verify order of checking.
    % TODO: allow more than one "hit" (e.g., if there are both a .py and .pyi,
    %       then use the .pyi to get type info for the .py and possibly create
    %       anchors in both)
    ( Ext = '.py' ; Ext = '.pyi' ; Ext = '/__init__.py' ; Ext = '/__init__.pyi' ),
    % file_name_extension/3 adds a '.', so can't use for /__init__.*
    atom_concat(PathBase, Ext, Path).

%! from_dots_import(+ImportPart:list, +PathBase:atom, -CombImportPart:list) is det.
from_dots_import([], _, [], []) :- !.
from_dots_import(['ImportDotNode'{}|Ds], PathBase, [PathBase|Dots], DottedNames) :- !,
    from_dots_import(Ds, '/..', Dots, DottedNames).
from_dots_import(['DottedNameNode'{items: Ds}], _, [], DottedNames) :-
    from_dots(Ds, DottedNames).

%! from_dots(+DottedNameItems:list, -DottedNames:list) is det.
%  Process a list of NameRawNode nodes into a list of names
from_dots([], []).
from_dots(['NameRawNode'{name: NameAstn}|Ns], [Name|Names]) :-
    node_astn(NameAstn, _, _, Name),
    from_dots(Ns, Names).

%! from_import_part(+ImportPart, +FullFromName, -CombImportPart)//[kythe_fact] is det.
%  Used by ImportFromStmt (via dots_and_dotted_name): extracts from
%  individual AsNameNode items and combines it with the FullFromName
%  and outputs a list of name-name pairs.
% TODO: '*' handling needs a better convention (and implementation).
from_import_part('*', _, '*') -->> [ ].
from_import_part([], _, []) -->> [ ].
from_import_part(['AsNameNode'{as_name: 'NameBindsFqn'{fqn: str(AsName), name: AsNameAstn},
                               name: 'NameRawNode'{name: NameAstn}}|Ns],
                 FullFromName,
                 [ConcatName-AsNameAtom|NANs]) -->>
    { node_astn(NameAstn, _, _, Name) },
    { node_astn(AsNameAstn, Start, End, _) },
    { atomic_list_concat([FullFromName, '/', Name], ConcatName) },
    { atom_string(AsNameAtom, AsName) },
    anchor(Start, End, Source),
    edge(Source, '/kythe/edge/defines/binding', AsName),
    from_import_part(Ns, FullFromName, NANs).

%! node_anchors_import_from(+PathFqn:list(pair)//[kythe_fact, expr] is det.
%  Used by ImportFromStmt to process the Path-Fqn pairs generated by
%  from_import_part.
node_anchors_import_from([]) -->> [ ].
node_anchors_import_from([Path-Fqn|AsItems]) -->>
    [ import_from(Path, Fqn) ]:expr,
    % TODO: ref/import
    node_anchors_import_from(AsItems).

%! dotted_name_raw(+Nodes:list, -Astns:list) is det.
%  Used by DottedNameNode to process a list of NameRawNode.
% TODO: needs some file resolution
dotted_name_raw([], []).
dotted_name_raw(['NameRawNode'{name: NameAstn}|Raws], [astn(Start, End, Name)|Astns]) :-
    node_astn(NameAstn, Start, End, Name),
    dotted_name_raw(Raws, Astns).

%! node_anchors_list(+Nodes:list, -NodeTypes:list)//[kythe_fact, expr] is det.
%  maplist(node_anchors, Nodes, NodeTypes)
node_anchors_list([], []) -->> [ ].
node_anchors_list([Node|Nodes], [[NodeType]|NodeTypes]) -->>
    node_anchors(Node, NodeType),
    node_anchors_list(Nodes, NodeTypes).

%! node_anchors_expr_list(NodeTypes:list)//[kythe_fact, expr] is det.
%  maplist(expr_normalized, NodeTypes)
node_anchors_expr_list([]) -->> [ ].
node_anchors_expr_list([Type|Types]) -->>
    expr_normalized(Type),
    node_anchors_expr_list(Types).

%! assign_normalized(+Left, +Right)//[kythe_fact, expr] is det.
%  Process the Left and Right parts of an assign/2 term, handling
%  things like `omitted` and `ellipsis`.
assign_normalized(Left, Right) -->>
    node_anchors(Left, LeftType),
    node_anchors(Right, RightType),
    (  { LeftType = omitted }
    -> [ ]
    ;  { RightType = omitted ; RightType = ellipsis }
    -> [ assign(LeftType, []) ]:expr  % TODO: Right is left uninstantiated
    ;  [ assign(LeftType, [RightType]) ]:expr
    ).

%! expr_normalized(+Right)//[kythe_fact, expr] is det.
%  Process the Right parts of an expr/1 term, handling
%  things like `omitted` and `ellipsis`.
expr_normalized(Right) -->>
    node_anchors(Right, RightType),
    (  { RightType = [omitted] ; RightType = [ellipsis] }
    -> [ ]
    ;  [ expr([RightType]) ]:expr
    ).

%! node_astn(+AstnNode, -Start, -End, -Value) is det.
%  Access the inner parts of an Astn node.
%  See also portray/1 rule for 'Astn' (uses node_astn/4).
node_astn('Astn'{start: int(Start), end: int(End), value: str(Value)},
          Start, End, Value).

%! dot_edge_name(+TrueFalse:string, -KytheEdge:atom) is det.
%  Translate True/False to Kythe ref or binding edge type
dot_edge_name("False", '/kythe/edge/ref').
dot_edge_name("True", '/kythe/edge/defines/binding').

%! anchor(+Start, +End, -Source)//[kythe_fact] is det.
%  Create the Kythe facts for an anchor.
anchor(Start, End, Source) -->>
    { format(string(Signature), '@~d:~d', [Start, End]) },
    { signature_source(Signature, Source) },
    kythe_fact(Source, '/kythe/node/kind', anchor),
    kythe_fact(Source, '/kythe/loc/start', Start),
    kythe_fact(Source, '/kythe/loc/end', End).

%! edge(+Source, +EdgeKind, +Fqn)//[kythe_fact] is det.
%  High-level create a Kythe edge fact.
edge(Source, EdgeKind, Fqn) -->>
    { signature_node(Fqn, Target) },
    [ json{source: Source, edge_kind: EdgeKind, target: Target, fact_name: '/'} ]:kythe_fact.

%! kythe_fact(+Source, FactName, FactValue//[kythe_fact] is det.
%  Low-level create a Kythe fact or edge
kythe_fact(Source, FactName, FactValue) -->>
    { base64(FactValue, FactBase64) },
    kythe_fact_b64(Source, FactName, FactBase64).

%! kythe_fact_64(+Source, +FactName, +FactBase64)//[kythe_fact] is det.
%  Low-level create a Kythe fact or edge inputting the base64 of the
%  fact value.
%  The accumulator takes care of duplicate removal.
kythe_fact_b64(Source, FactName, FactBase64) -->>
    [ json{source: Source, fact_name: FactName, fact_value: FactBase64} ]:kythe_fact.

%! signature_source(+Signature:string, -Source) is det.
%  Create a Kythe "source" tuple from a Signature string.
signature_source(Signature, Source) :-
    corpus_root_path_language(KytheCorpus, KytheRoot, Path, _Language),
    Source = json{signature: Signature, corpus: KytheCorpus, root: KytheRoot, path: Path}.

%! signature_node(+Signature:string, -Vname) is det.
%  Create a Kythe "vname" from a Signature string
signature_node(Signature, Vname) :-
    corpus_root_path_language(KytheCorpus, KytheRoot, _Path, Language),
    Vname = json{signature: Signature, corpus: KytheCorpus, root: KytheRoot, language: Language}.

%! output_kythe_facts(+Anchors:list, +KytheStream:stream) is det.
%  Output the Kythe facts to a specified stream.
output_kythe_facts([], _KytheStream).
output_kythe_facts([Anchor|Anchors], KytheStream) :-
    must_once(
        output_kythe_fact(Anchor, KytheStream)),
    output_kythe_facts(Anchors, KytheStream).

%! output_kythe_fact(+AnchorAsDict:json_dict, +KytheStream:stream) is det.
%  Output a single Kythe fact.
output_kythe_fact(AnchorAsDict, KytheStream) :-
    % The tags are ignored unless option tag(type) is specified (which
    % it isn't). All dicts should have the tag 'json', for simplicity.
    % (See also kythe_fact_accum/3 for a bit more on the dicts.)
    json_write_dict(KytheStream, AnchorAsDict, [width(0)]),
    nl(KytheStream).

%%%%%%       %%%%%%%
%%%%%% Pass 2 %%%%%%%
%%%%%%        %%%%%%%

%! assign_exprs(+Exprs:list, -Symtab:dict, -KytheFacts:list) is det.
%  Process a list of Exprs, generating a Symtab and list of KytheFacts.
assign_exprs(Exprs, Symtab, KytheFacts) :-
    initial_symtab(Symtab0),
    assign_exprs_count(1, Exprs, Symtab0, Symtab, KytheFacts).

%! assign_exprs(+Count, +Exprs:list, -Symtab:dict, -KytheFacts:list) is det.
%  Process a list of Exprs, generating a Symtab and list of KytheFacts.
%  Count tracks the number of passes over Exprs; if too large, the
%  processing stops.
% TODO: Improveed output when too many passes are needed.
% TODO: Parameterize max number of passes.
assign_exprs_count(Count, Exprs, Symtab0, Symtab, KytheFacts) :-
    do_if(false,
          format(user_error, '% === EXPRS === ~q~n~n', [Count])),
    assign_exprs_count_impl(Exprs, Symtab0, Symtab1, Rej, KytheFacts1),  % phrase(assign_exprs_count(...))
    length(Rej, RejLen),
    do_if(RejLen > 0,
          format(user_error, 'Pass ~q (rej=~q)~n', [Count, RejLen])),
    CountIncr is Count + 1,
    (  (Rej = [] ; CountIncr > 5)  % TODO: parameterize.
    -> Symtab = Symtab1,
       KytheFacts = KytheFacts1
    ;  assign_exprs_count(CountIncr, Exprs, Symtab1, Symtab, KytheFacts)
    ).

%! assign_exprs_count_impl(+Exprs, Symtab0, SymtabWithRej, Rej, KytheFacts) :-
%  Helper for assign_exprs_count, which does the actual processing.
assign_exprs_count_impl(Exprs, Symtab0, SymtabWithRej, Rej, KytheFacts) :-
    dict_pairs(Symtab0, symtab, SymtabPairs0),
    exprs_from_symtab(SymtabPairs0, ExprsFromSymtab1),
    sort(ExprsFromSymtab1, ExprsFromSymtab),  % remove dups
    append(ExprsFromSymtab, Exprs, ExprsCombined),  %% TODO: difference list
    empty_assoc(KytheFacts0),
    must_once(
        assign_exprs_eval_list(ExprsCombined, KytheFacts0, KytheFacts1, Symtab0-[], SymtabAfterEval-Rej)),  % phrase(assign_exprs_eval_list(...))
    assoc_to_values(KytheFacts1, KytheFacts),
    do_if(false,
          dump_term('REJ', Rej)),
    must_once(
        add_rej_to_symtab(Rej, SymtabAfterEval, SymtabWithRej)).

%! assign_exprs_eval_list(+Assign:list)//[kythe_fact, sym_rej] is det.
%  Process a list of assign or eval nodes.
assign_exprs_eval_list([]) -->> [ ].
assign_exprs_eval_list([Assign|Assigns]) -->>
    SymtabRej/sym_rej,  %% TODO: delete (it's only used for debug logging)
    { do_if(false,
            dump_term('', SymtabRej)) },
    { do_if(false,
            dump_term('', Assign, [indent_arguments(auto),
                                   right_margin(60)])) },
    must_once_fqn_sym_rej(
        assign_expr_eval(Assign)),
    assign_exprs_eval_list(Assigns).

%! assign_expr_eval(+Node)//[kythe_fact, sym_rej] is det.
%  Process a single assign/2 or expr/1 node.
assign_expr_eval(assign(Left, Right)) -->>
    eval_union_type_and_lookup(Right, RightEval),
    eval_single_type(Left, LeftEval),
    (  { LeftEval = [LeftEvalSingle] }
    -> eval_lookup_single(LeftEvalSingle, RightEval)
    ;  [ ]
    ).
assign_expr_eval(expr(Right)) -->>
    %% TODO: do we need _and_lookup (for processing anchors)?
    eval_union_type_and_lookup(Right, _RightEval).
assign_expr_eval(class(Fqn, Bases)) -->>
    [ Fqn-[class(Fqn, Bases)] ]:sym_rej.
assign_expr_eval(func(Fqn, ReturnType)) -->>
    [ Fqn-[func(Fqn, ReturnType)] ]:sym_rej.
assign_expr_eval(import_from(Path, Fqn)) -->>
    [ Fqn-[import(Fqn, Path)] ]: sym_rej.

%! eval_union_type(+Type:ordset, -EvalType:ordset)//[kythe_fact, sym_rej] is det.
%  Evaluate a Type, generating a new (union) EvalType.
eval_union_type(Type, EvalType) -->>
    { ord_empty(EvalType0) },
    eval_union_type(Type, EvalType0, EvalType).

%! eval_union_type(+Type:ordset, -EvalType:ordset)//[kythe_fact, sym_rej] is det.
%  Evaluate a Type, generating a new (union) EvalType, using an explicit
%  accumuilator (UnionSoFar).
eval_union_type([], UnionSofar, UnionSofar) -->> [ ].
eval_union_type([T|Ts], UnionSoFar, EvalTypes) -->>
    must_once_fqn_sym_rej(
        eval_single_type_and_lookup(T, ET)),
    { ord_union(UnionSoFar, ET, UnionSoFar2) },
    eval_union_type(Ts, UnionSoFar2, EvalTypes).

%! eval_union_type_and_lookup(+Expr, -UnionEvalType)//[kythe_fact, sym_rej] is det.
%  Evaluate (union) Expr and look it up in the symtab.
eval_union_type_and_lookup(Expr, UnionEvalType) -->>
    eval_union_type(Expr, UnionEvalType0),
    eval_lookup(UnionEvalType0, UnionEvalType).

%! eval_single_type_and_lookup(+Expr, -UnionEvalType)//[kythe_fact, sym_rej]
%  Evaluate (non-union) Expr and look it up in the symtab.
eval_single_type_and_lookup(Expr, UnionEvalType) -->>
    eval_single_type(Expr, UnionEvalType0),
    eval_lookup(UnionEvalType0, UnionEvalType).

%! eval_lookup(+UnionType, -UnionEvalType)//[kythe_fact, sym_rej] is det.
%  Look up an evaluated union type, generating a union UnionEvalType.
% TODO: handle [string], [number], etc.
%       (this is a nice-to-do, for when we add more support for Kythe's
%       type annotations; but for now, we really only need lookups for
%       functions (calls) and classes/imports (',' operation))
eval_lookup(UnionType, UnionEvalType) -->>
    { ord_empty(UnionEvalType0) },
    eval_lookup(UnionType, UnionEvalType0, UnionEvalType).

%! eval_lookup(+Types:ordset, -UnionEvalType:ordset)//[kythe_fact, sym_rej] is det.
%  eval_lookup_single to items in Types, combining into UnionEvalType.
eval_lookup([], UnionEvalType, UnionEvalType) -->> [ ].
eval_lookup([X|Xs], UnionEvalType0, UnionEvalType) -->>
    eval_lookup_single(X, Y),
    { ord_union(UnionEvalType0, Y, UnionEvalType1) },
    eval_lookup(Xs, UnionEvalType1, UnionEvalType).

%! eval_lookup_single(+Type, -UnionEvalType:ordset) -->> [kythe_fact, sym_rej]
eval_lookup_single(fqn(Fqn), UnionEvalType) -->> !,
    [ Fqn-UnionEvalType ]:sym_rej.
eval_lookup_single(class(ClassName, Bases0),
                   [class(ClassName, Bases)]) -->> !,
    eval_union_type_and_lookup_list(Bases0, Bases).
eval_lookup_single(func(FuncName, ReturnType0),
                   [func(FuncName, ReturnType)]) -->> !,
    eval_lookup(ReturnType0, ReturnType).
eval_lookup_single(import(Fqn, Path),
                   [import(Fqn, Path)]) -->> !,
    [ ].
eval_lookup_single(var(Fqn),
                   [var(Fqn)]) -->> !, [ ].
eval_lookup_single(_EvalType, []) -->> [ ].

%! eval_single_type(+Type, -EvalType:ordset)//[kythe_fact, sym_rej] is det.
eval_single_type(fqn(Fqn), [fqn(Fqn)]) -->> [ ].
eval_single_type(dot(Atom, Astn, DotEdgeName), EvalType) -->>
    eval_union_type_and_lookup(Atom, AtomEval),
    %% TODO: MRO for class -- watch out for Bases containing Unions!
    eval_atom_dot_union(AtomEval, Astn, DotEdgeName, EvalType).
eval_single_type(call(Atom, Parms), EvalType) -->>
    eval_union_type_and_lookup(Atom, AtomEval),
    eval_union_type_list(Parms, ParmsEval),
    eval_atom_call_union(AtomEval, ParmsEval, EvalType).
eval_single_type(call_op(OpAstns, ArgsType), [call_op(OpAstns, ArgsTypeEval)]) -->>
    eval_union_type_list(ArgsType, ArgsTypeEval).
eval_single_type(class(Name, Bases), [class(Name, BasesEval)]) -->> 
    eval_union_type_list(Bases, BasesEval).
eval_single_type(import(Fqn, Path), [import(Fqn, Path)]) -->>
    [ ].  % TODO: look-up
eval_single_type(func(Name, ReturnType), [func(Name, ReturnTypeEval)]) -->>
    eval_union_type_and_lookup(ReturnType, ReturnTypeEval).
eval_single_type(ellipsis, []) -->> [ ].
eval_single_type(omitted, []) -->> [ ].

% TODO: implement the following:
eval_single_type(todo_compfor(iter:_CompIterType, for:_ForExprlistType, in:_InTestlistType), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_compifcompiter(_ValueExprType, _CompIterType), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_decorated(_ItemsType), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_decorator_dottedname(_ItemsType), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_decorators(_ItemsType), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_dictgen(_ValueExprType, _CompForType), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_dictkeyvaluelist(_ItemsType), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_dictset(_ItemsType), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_dottedname(_ItemsType), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_expr(stmts), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_typedarg(), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_subscr(_), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_arg(_, _), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_list(_), []) -->> [ ].  % [kythe_fact, sym_rej]
eval_single_type(todo_exprlist(_), []) -->> [ ].  % [kythe_fact, sym_rej]

%! eval_atom_dot_union(+AtomEval:ordset, +Astn, +DotEdgeName:atom, -EvalType:ordset)//[kythe_fact, sym_rej]
%  Helper for eval(dot(Atom, Astn, DotEdgeName)), which loops over the
%  individual types in the (union) AtomEval and creates a union type
%  of all the possibilities.
eval_atom_dot_union(AtomEval, Astn, DotEdgeName, EvalType) -->>
    { ord_empty(EvalType0) },
    eval_atom_dot_union(AtomEval, Astn, DotEdgeName, EvalType0, EvalType).

%! eval_atom_dot_union(+Types:list, +Astn, +DotEdgeName:atom, +EvalType0:ordset, +EvalType:ordset)//[kythe_fact, sym_rej] is det.
%  eval_atom_dot_union with explicit accumulator (EvalType0, EvalType).
eval_atom_dot_union([], _Astn, _DotEdgeName, EvalType, EvalType) -->> [ ].
eval_atom_dot_union([T|Ts], Astn, DotEdgeName, EvalType0, EvalType) -->>
    eval_single_type(T, ET0),
    eval_atom_dot_single_list(ET0, Astn, DotEdgeName, EvalType0, EvalType1),
    eval_atom_dot_union(Ts, Astn, DotEdgeName, EvalType1, EvalType).

%! eval_atom_dot_single_list(+Types:list, +Astn, +DotEdgeName:atom, +EvalType0:ordset, -EvalType:ordset)//[kythe_fact, sym_rej]//[kythe_fact, sym_rej]) is det.
%  maplist_combine(eval_atom_dot_single, Types, Astn, DotEdgeName, EvalType0, EvalType).
eval_atom_dot_single_list([], _Astn, _DotEdgeName, EvalType, EvalType) -->> [ ].
eval_atom_dot_single_list([T|Ts], Astn, DotEdgeName, EvalType0, EvalType) -->>
    Astn = astn(Start, End, Attr),
    eval_atom_dot_single(T, Start, End, Attr, DotEdgeName, EvalType0, EvalType1),
    eval_atom_dot_single_list(Ts, Astn, DotEdgeName, EvalType1, EvalType).

%! eval_atom_dot_single(+Type, +Start, +End, +Attr, +DotEdgeName:atom, +EvalType0:ordset, -EvalType:ordset)//[kythe_fact, sym_rej] is det.
%  Process a single type-dot-attr, adding to EvalType
% TODO: also allow func(...).attr (currently only allows class(...).attr
eval_atom_dot_single(class(ClassName, _), Start, End, Attr, DotEdgeName, EvalType0, EvalType) -->> !,
    { atomic_list_concat([ClassName, '.', Attr], FqnAttr) },
    { ord_add_element(EvalType0, fqn(FqnAttr), EvalType) },
    anchor(Start, End, Source),
    edge(Source, DotEdgeName, FqnAttr).
eval_atom_dot_single(import(_Fqn, Path), Start, End, Attr, DotEdgeName, EvalType0, EvalType) -->> !,
    { atomic_list_concat([Path, '::', Attr], FqnAttr) },  % TODO: need to resolve path
    anchor(Start, End, Source),
    edge(Source, DotEdgeName, FqnAttr),
    { EvalType = EvalType0 }.
eval_atom_dot_single(_, _Start, _End, _Attr, _DotEdgeName, EvalType, EvalType) -->> [ ].

%! eval_atom_call_union(+AtomEval:ordset, +Parms, -EvalType:ordset)//[kythe_fact, sym_rej] is det.
%  Helper for eval_single_type(call(Atom, Parms)), which loops over
%  the individual types in the (union) AtomEval and creates a union
%  type of all the possibilities.
eval_atom_call_union(AtomEval, Parms, EvalType) -->>
   { ord_empty(EvalType0) },
    eval_atom_call_union(AtomEval, Parms, EvalType0, EvalType).

% eval_atom_call_union(+Types:ordset, +Parms, +EvalType0:ordset, +EvalType:ordset)//[kythe_fact, sym_rej] is det.
% eval_atom_call_union with explicit accumulator (EvalType0, EvalType).
eval_atom_call_union([], _Parms, EvalType, EvalType) -->> [ ].
eval_atom_call_union([T|Ts], Parms, EvalType0, EvalType) -->>
    eval_single_type(T, ET0),
    eval_atom_call_single_list(ET0, Parms, EvalType0, EvalType1),
    eval_atom_call_union(Ts, Parms, EvalType1, EvalType).

%! eval_atom_call_single_list(+Types:list, +Parms, +EvalType0, -EvalType)//[kythe_fact, sym_rej] is det.
%  maplist_combine(eval_atom_call_single, Types, Parms, EvalType0, EvalType).
eval_atom_call_single_list([], _Parms, EvalType, EvalType) -->> [ ].
eval_atom_call_single_list([T|Ts], Parms, EvalType0, EvalType) -->>
    eval_atom_call_single(T, Parms, EvalType0, EvalType1),
    eval_atom_call_single_list(Ts, Parms, EvalType1, EvalType).

%! eval_atom_call_single(+Type, +Parms, +EvalType0:ordset, -EvalType:ordset)//[kythe_fact, sym_rej] is det.
%  Process a single call, adding to EvalType
eval_atom_call_single(class(Fqn, Bases), _Parms, EvalType0, EvalType) -->>  !,
    % TODO: MRO for__init__ and output ref to it
    { ord_add_element(EvalType0, class(Fqn, Bases), EvalType) }.
eval_atom_call_single(func(_, ReturnType), _Parms, EvalType0, EvalType) -->>  !,
    % ord_union because ReturnTYpe is a union type
    { ord_union(EvalType0, ReturnType, EvalType) }.
eval_atom_call_single(T, Parms, EvalType0, EvalType) -->>
    { ord_add_element(EvalType0, func(T, Parms), EvalType) }.

%! eval_union_type_list(Types:list, +EvalTypes:list)//[kythe_fact, sym_rej] is det.
%  maplist(eval_union_type, Ts, ETs).
eval_union_type_list([], []) -->> [ ].  % [kythe_fact, sym_rej]
eval_union_type_list([T|Ts], [ET|ETs]) -->>  % [kythe_fact, sym_rej]
    eval_union_type(T, ET),
    eval_union_type_list(Ts, ETs).

%! eval_union_type_list_and_lookup(Types:list, +EvalTypes:list)//[kythe_fact, sym_rej] is det.
%  maplist(eval_union_type_and_lookup, Ts, ETs).
eval_union_type_and_lookup_list([], []) -->> [ ].  % [kythe_fact, sym_rej]
eval_union_type_and_lookup_list([T|Ts], [ET|ETs]) -->>  % [kythe_fact, sym_rej]
    eval_union_type_and_lookup(T, ET),
    eval_union_type_and_lookup_list(Ts, ETs).

%! exprs_from_symtab(+SymtabPairs:list(pair), -Exprs:list) is det.
%  Using the Fqn-Type pairs dict_pairs, get exprs into a list of expr(_) items.
exprs_from_symtab([], []).
exprs_from_symtab([_Fqn-Type|FTs], Exprs) :-
    (  Type = []
    -> Exprs = Exprs2
    ;  Exprs = [expr(Type)|Exprs2]
    ),
    exprs_from_symtab(FTs, Exprs2).

%! add_rej_to_symtab(+FqnRejTypes:list(pair), +Symtab0, -Symtab) is det.
%  For Fqn-RejType pairs in FqnRejTypes, add to symtab.
add_rej_to_symtab([], Symtab, Symtab).
add_rej_to_symtab([Fqn-RejType|FTs], Symtab0, Symtab) :-
    must_once(
        get_dict(Fqn, Symtab0, FqnType)),
    ord_union(FqnType, RejType, CombinedType),
    put_dict(Fqn, Symtab0, CombinedType, Symtab1),
    add_rej_to_symtab(FTs, Symtab1, Symtab).

%! sym_rej_accum(+FqnType:pair, +Symtab0Rej0:pair, +SymtabRej:pair) is det.
%  The accumulator for 'sym_rej'.
%  Tries to unify Key-Type unifies with what's already in symtab;
%  if that fails because it's not in the symtab, adds it; otherwise
%  adds it Rej.
% TODO: use library(assoc) instead of dict for Symtab (performance)
sym_rej_accum(Fqn-Type, Symtab0-Rej0, Symtab-Rej) :-
    (  get_dict(Fqn, Symtab0, TypeSymtab)
    -> Symtab = Symtab0,
       (  Type = TypeSymtab  %% in case Type is not instantiated (i.e., a lookup)
       -> Rej = Rej0
       ;  ord_union(TypeSymtab, Type, TypeComb),  % TODO: ord_intersect(TypeSymtab, Type) ?
          TypeComb = TypeSymtab
       -> Rej = Rej0
       ;  Rej = [Fqn-Type|Rej0]
       )
    ;  Type = []  %% in case Type is not instantiated (i.e., a lookup)
    -> Rej = Rej0,
       put_dict(Fqn, Symtab0, Type, Symtab)
    ;  Rej = Rej0,
       put_dict(Fqn, Symtab0, Type, Symtab)
    ).

%! dict_values(+Dict, -Values) is det.
%  Extract the values from a dict.
dict_values(Dict, Values) :-
    dict_pairs(Dict, _, Pairs),
    pairs_values(Pairs, Values).

%! kythe_fact_accum(+T, +In, -Out) is det.
%  The accumulator for 'kythe_fact'.
kythe_fact_accum(T, In, Out) :-
    % If a fact is already there, keep it and ignore subsequent value (e.g.,
    % for redefining a variable).
    % This code depends on all the JSON dicts having a ground tag (e.g., the
    % Source and Target are typically dicts, and they must have ground tags ...
    % for simplicity, these are all 'json').
    (  T = json{source: Source, fact_name: FactName, fact_value: _FactBase64}
    -> (  get_assoc(fact(Source,FactName), In, _)
       -> In = Out  % already there - ignore subsequent values
       ;  put_assoc(fact(Source,FactName), In, T, Out)
       )
    ;  T = json{source: Source, edge_kind: EdgeKind, target: Target, fact_name: '/'},
       must_once_msg(
           \+ get_assoc(edge(Source,EdgeKind,Target), In, _),
           'Duplicate Kythe edge facts', []),
       put_assoc(edge(Source,EdgeKind,Target), In, T, Out)
    ;  throw(error(bad_kythe_fact(T), _))
    ).

%! portray is det.
%  For more compact output (debugging).
portray(Astn) :-
    node_astn(Astn, Start, End, Value), !,
    format("'ASTN'(~d:~d, ~q)", [Start, End, Value]).
portray(str(S)) :-
    format('str(~q)', [S]), !.
portray(bool(B)) :-
    format('bool(~q)', [B]), !.
portray('StringNode'{astns: [Astn]}) :- !,  % doesn't handle "foo" "bar"
    format("'StringNode'{astn:[~p]}", [Astn]).
portray('NumberNode'{astn: Astn}) :-
    format("'StringNode'{astn:[~p]}", [Astn]).
portray(op([Astn])) :-
    node_astn(Astn, _, _, _), !,
    format('op([~p])', [Astn]).
portray(fqn(X)) :- !,
    format('fqn(~p)', [X]).
portray(func(F, R)) :- !,
    format('func(~p, ~p)', [F, R]).
portray(class(F, R)) :- !,
    format('class(~p, ~p)', [F, R]).
portray(union(U)) :- !,
    format('union(~p)', [U]).
portray(astn(Start, End, String)) :- !,
    format('astn(~p,~p, ~p)', [Start, End, String]).
portray('$VAR'('_')) :- !,  % work around a bug in print_term
    format('_', []).        % (numbervars(true) should handle this):
portray('$VAR'(N)) :- !,
    Chr is N + 65,
    format('~c', [Chr]).
portray(Assoc) :-
    is_assoc(Assoc), !,
    aggregate_all(count, gen_assoc(_, Assoc, _), Length),
    min_assoc(Assoc, MinKey, MinValue),
    max_assoc(Assoc, MaxKey, MaxValue),
    format('<assoc:~d, ~p: ~p ... ~p: ~p>', [Length, MinKey, MinValue, MaxKey, MaxValue]).
% portray(Symtab) :-
%     is_dict(Symtab, Tag), !,
%     ground(Tag),
%     Tag = symtab, !,
%     format('symtab{...}').

%! do_if(:Cond, :Pred) is det.
%  A handy meta-predicate for turning debug stuff on/off, according to Cond
do_if(Cond, Pred) :-
    (  call(Cond)
    -> call(Pred)
    ;  true
    ).

%! map_match(+Pattern, +Xs:list) is semidet.
%  Check that all items in a list can unify without instantiating
%  anything in the pattern.
map_match(_Pattern, []).
map_match(Pattern, [X|Xs]) :-
    \+ \+ Pattern = X,
    map_match(Pattern, Xs).

%! dump_term(+Msg:atom, +Term) is det.
% TODO: Remove this debugging code
dump_term(Msg, Term) :-
    dump_term(Msg, Term, [tab_width(0),
                          indent_arguments(2),
                          right_margin(100)]).
%! dump_term(+Msg:atom, +Term, +Options:list) is det.
% TODO: Remove this debugging code
dump_term(Msg, Term, Options) :-
    (  Msg = ''
    -> true
    ;  format(user_error, '% === ~w ===~n~n', [Msg])
    ),
    print_term_cleaned(Term, Options, TermStr),
    (  Msg = ''
    -> format(user_error, '~s.~n', [TermStr])
    ;  format(user_error, '~s.~n~n', [TermStr]),
       format(user_error, '% === end ~w ===~n~n', [Msg])
    ).

%! print_term_cleaned(+Term, +Options, -TermStr) is det.
%  print_term, cleaned up
print_term_cleaned(Term, Options, TermStr) :-
    % print_term leaves trailing whitespace, so remove it
    with_output_to(
            string(TermStr0),
            (current_output(TermStream),
             print_term(Term, [output(TermStream)|Options]))),
    re_replace(" *\n"/g, "\n", TermStr0, TermStr).