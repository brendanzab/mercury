%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 1994-2011 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: mercury_compile.m.
% Main authors: fjh, zs.
%
% This is the top-level of the Mercury compiler.
%
% This module invokes the different passes of the compiler as appropriate.
% The constraints on pass ordering are documented in
% compiler/notes/compiler_design.html.
%
%---------------------------------------------------------------------------%

:- module top_level.mercury_compile_front_end.
:- interface.

:- import_module hlds.
:- import_module hlds.hlds_module.
:- import_module hlds.make_hlds.
:- import_module hlds.passes_aux.
:- import_module libs.
:- import_module libs.op_mode.
:- import_module parse_tree.
:- import_module parse_tree.error_util.

:- import_module bool.
:- import_module io.
:- import_module list.

:- pred frontend_pass(op_mode_augment::in, make_hlds_qual_info::in,
    bool::in, bool::in, bool::in, bool::out, module_info::in, module_info::out,
    dump_info::in, dump_info::out, list(error_spec)::in, list(error_spec)::out,
    io::di, io::uo) is det.

    % This type indicates what stage of compilation we are running
    % the simplification pass at. The exact simplifications tasks we run
    % will depend upon this.
    %
:- type simplify_pass
    --->    simplify_pass_frontend
            % Immediately after the frontend passes.

    ;       simplify_pass_post_untuple
            % After the untupling transformation has been applied.

    ;       simplify_pass_pre_prof_transforms
            % If deep/term-size profiling is enabled then immediately
            % before the source-to-source transformations that
            % implement them.

    ;       simplify_pass_pre_implicit_parallelism
            % If implicit parallelism is enabled then perform simplification
            % before it is applied. This helps ensure that the HLDS matches
            % the feedback data.

    ;       simplify_pass_ml_backend
            % The first stage of MLDS code generation.

    ;       simplify_pass_ll_backend.
            % The first stage of LLDS code generation.

    % This predicate sets up and maybe runs the simplification pass.
    %
:- pred maybe_simplify(bool::in, simplify_pass::in, bool::in, bool::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module check_hlds.
:- import_module check_hlds.check_for_missing_type_defns.
:- import_module check_hlds.check_promise.
:- import_module check_hlds.check_typeclass.
:- import_module check_hlds.clause_to_proc.
:- import_module check_hlds.cse_detection.
:- import_module check_hlds.det_analysis.
:- import_module check_hlds.implementation_defined_literals.
:- import_module check_hlds.inst_check.
:- import_module check_hlds.inst_user.
:- import_module check_hlds.mode_constraints.
:- import_module check_hlds.modes.
:- import_module check_hlds.oisu_check.
:- import_module check_hlds.old_type_constraints.
:- import_module check_hlds.polymorphism.
:- import_module check_hlds.polymorphism_post_copy.
:- import_module check_hlds.post_typecheck.
:- import_module check_hlds.pre_typecheck.
:- import_module check_hlds.purity.
:- import_module check_hlds.simplify.
:- import_module check_hlds.simplify.simplify_proc.
:- import_module check_hlds.simplify.simplify_tasks.
:- import_module check_hlds.stratify.
:- import_module check_hlds.style_checks.
:- import_module check_hlds.switch_detection.
:- import_module check_hlds.try_expand.
:- import_module check_hlds.type_constraints.
:- import_module check_hlds.typecheck.
:- import_module check_hlds.unique_modes.
:- import_module check_hlds.unused_imports.
:- import_module hlds.du_type_layout.
:- import_module hlds.goal_mode.
:- import_module hlds.hlds_clauses.
:- import_module hlds.hlds_error_util.
:- import_module hlds.hlds_pred.
:- import_module hlds.hlds_statistics.
:- import_module libs.file_util.
:- import_module libs.globals.
:- import_module libs.optimization_options.
:- import_module libs.options.
:- import_module mdbcomp.
:- import_module mdbcomp.sym_name.
:- import_module parse_tree.file_names.
:- import_module parse_tree.maybe_error.
:- import_module parse_tree.module_cmds.
:- import_module parse_tree.parse_tree_out.
:- import_module parse_tree.parse_tree_out_info.
:- import_module parse_tree.prog_data.
:- import_module top_level.mercury_compile_middle_passes.
:- import_module transform_hlds.
:- import_module transform_hlds.dead_proc_elim.
:- import_module transform_hlds.intermod.
:- import_module transform_hlds.intermod_analysis.

:- import_module benchmarking.
:- import_module int.
:- import_module map.
:- import_module maybe.
:- import_module pair.
:- import_module set.
:- import_module string.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

frontend_pass(OpModeAugment, QualInfo0,
        FoundUndefTypeError, FoundUndefModeError, !FoundError,
        !HLDS, !DumpInfo, !Specs, !IO) :-
    % We can't continue after an undefined type error, since typecheck
    % would get internal errors.
    module_info_get_globals(!.HLDS, Globals),
    globals.lookup_bool_option(Globals, verbose, Verbose),
    (
        FoundUndefTypeError = yes,
        % We can't continue after an undefined type error, because if we did,
        % typecheck could get internal errors.
        !:FoundError = yes,
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose,
            "% Program contains undefined type error(s).\n", !IO),
        io.set_exit_status(1, !IO)
    ;
        FoundUndefTypeError = no,
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),

        % It would be nice to move the decide_type_repns pass later,
        % possibly all the way to the end of the semantic analysis passes,
        % to make sure that semantic analysis does not depend on implementation
        % details.
        %
        % Unfortunately, this would require a large amount of extra work,
        % for reasons that are documented at the top of du_type_layout.m.
        globals.lookup_bool_option(Globals, statistics, Stats),
        decide_type_repns_pass(Verbose, Stats, !HLDS, !Specs, !IO),
        maybe_dump_hlds(!.HLDS, 3, "decide_type_repns", !DumpInfo, !IO),

        maybe_write_string(Verbose, "% Checking typeclasses...\n", !IO),
        check_typeclasses(!HLDS, QualInfo0, QualInfo, [], TypeClassSpecs),
        !:Specs = TypeClassSpecs ++ !.Specs,
        maybe_dump_hlds(!.HLDS, 5, "typeclass", !DumpInfo, !IO),
        set_module_recomp_info(QualInfo, !HLDS),

        TypeClassErrors = contains_errors(Globals, TypeClassSpecs),
        (
            TypeClassErrors = yes,
            % We can't continue after a typeclass error, because if we did,
            % typecheck could get internal errors.
            !:FoundError = yes
        ;
            TypeClassErrors = no,
            frontend_pass_after_typeclass_check(OpModeAugment,
                FoundUndefModeError, !FoundError, !HLDS, !DumpInfo,
                !Specs, !IO)
        )
    ).

:- pred frontend_pass_after_typeclass_check(op_mode_augment::in, bool::in,
    bool::in, bool::out, module_info::in, module_info::out,
    dump_info::in, dump_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

frontend_pass_after_typeclass_check(OpModeAugment, FoundUndefModeError,
        !FoundError, !HLDS, !DumpInfo, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    globals.lookup_bool_option(Globals, verbose, Verbose),
    globals.lookup_bool_option(Globals, statistics, Stats),

    maybe_eliminate_dead_preds(OpModeAugment, Verbose, Stats, Globals,
        !HLDS, !DumpInfo, !Specs, !IO),
    maybe_warn_about_insts_without_matching_type(Verbose, Stats, Globals,
        !HLDS, !DumpInfo, !Specs, !IO),
    do_typecheck(Verbose, Stats, Globals, FoundSyntaxError, FoundTypeError,
        NumberOfIterations, !HLDS, !DumpInfo, !Specs, !IO),

    % We can't continue after an undefined inst/mode error, since
    % propagate_types_into_proc_modes (in post_typecheck.m -- called by
    % purity.m) and mode analysis would get internal errors. Also mode analysis
    % can loop if there are cyclic insts/modes.
    %
    % We can't continue if the type inference iteration limit was exceeded
    % because the code to resolve overloading in post_typecheck.m (called by
    % purity.m) could abort.
    ( if FoundUndefModeError = yes then
        !:FoundError = yes,
        maybe_write_string(Verbose,
            "% Program contains undefined inst " ++
            "or undefined mode error(s).\n", !IO),
        io.set_exit_status(1, !IO)
    else if NumberOfIterations = exceeded_iteration_limit then
        % FoundTypeError will always be true here, so if Verbose = yes,
        % we have already printed a message about the program containing
        % type errors.
        !:FoundError = yes,
        io.set_exit_status(1, !IO)
    else
        check_for_missing_type_defns(!.HLDS, MissingTypeDefnSpecs),
        !:Specs = !.Specs ++ MissingTypeDefnSpecs,
        SomeMissingTypeDefns = contains_errors(Globals, MissingTypeDefnSpecs),

        pretest_user_inst_table(!HLDS),
        post_typecheck_finish_preds(!HLDS, NumPostTypeCheckErrors,
            PostTypeCheckAlwaysSpecs, PostTypeCheckNoTypeErrorSpecs),
        maybe_dump_hlds(!.HLDS, 19, "post_typecheck", !DumpInfo, !IO),
        % If the main part of typecheck detected some errors, then some of
        % the errors we detect during post-typecheck could be avalanche
        % messages. We get post_typecheck to put all such messages into
        % PostTypeCheckNoTypeErrorSpecs, and we report them only if
        % we did not find any errors during typecheck.
        !:Specs = !.Specs ++ PostTypeCheckAlwaysSpecs,
        (
            FoundTypeError = no,
            !:Specs = !.Specs ++ PostTypeCheckNoTypeErrorSpecs
        ;
            FoundTypeError = yes
        ),

        ( if
            ( FoundTypeError = yes
            ; FoundSyntaxError = some_clause_syntax_errors
            ; SomeMissingTypeDefns = yes
            ; NumPostTypeCheckErrors > 0
            )
        then
            % XXX It would be nice if we could go on and mode-check the
            % predicates which didn't have type errors, but we need to run
            % polymorphism before running mode analysis, and currently
            % polymorphism may get internal errors if any of the predicates
            % are not type-correct.
            !:FoundError = yes
        else
            frontend_pass_after_typecheck(OpModeAugment, Verbose, Stats,
                Globals, FoundUndefModeError, !FoundError,
                !HLDS, !DumpInfo, !Specs, !IO)
        )
    ).

:- pred maybe_eliminate_dead_preds(op_mode_augment::in, bool::in, bool::in,
    globals::in, module_info::in, module_info::out,
    dump_info::in, dump_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

maybe_eliminate_dead_preds(OpModeAugment, Verbose, Stats, Globals,
        !HLDS, !DumpInfo, !Specs, !IO) :-
    globals.lookup_bool_option(Globals, intermodule_optimization, IntermodOpt),
    globals.lookup_bool_option(Globals, intermodule_analysis,
        IntermodAnalysis),
    globals.lookup_bool_option(Globals, use_opt_files, UseOptFiles),
    ( if
        ( IntermodOpt = yes
        ; IntermodAnalysis = yes
        ; UseOptFiles = yes
        ),
        OpModeAugment \= opmau_make_plain_opt
    then
        % Eliminate unnecessary clauses from `.opt' files,
        % to speed up compilation. This must be done after
        % typeclass instances have been checked, since that
        % fills in which pred_ids are needed by instance decls.
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose, "% Eliminating dead predicates... ", !IO),
        dead_pred_elim(!HLDS),
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose, "done.\n", !IO),
        maybe_report_stats(Stats, !IO),
        maybe_dump_hlds(!.HLDS, 10, "dead_pred_elim", !DumpInfo, !IO)
    else
        true
    ).

:- pred maybe_warn_about_insts_without_matching_type(bool::in, bool::in,
    globals::in, module_info::in, module_info::out,
    dump_info::in, dump_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

maybe_warn_about_insts_without_matching_type(Verbose, Stats, Globals,
        !HLDS, !DumpInfo, !Specs, !IO) :-
    globals.lookup_bool_option(Globals, warn_insts_without_matching_type,
        WarnInstsWithNoMatchingType),
    (
        WarnInstsWithNoMatchingType = yes,
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose,
            "% Checking that insts have matching types... ", !IO),
        check_insts_have_matching_types(!HLDS, !Specs),
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose, "done.\n", !IO),
        maybe_report_stats(Stats, !IO),
        maybe_dump_hlds(!.HLDS, 12, "warn_insts_without_matching_type",
            !DumpInfo, !IO)
    ;
        WarnInstsWithNoMatchingType = no
    ).

:- pred do_typecheck(bool::in, bool::in, globals::in,
    maybe_clause_syntax_errors::out, bool::out, number_of_iterations::out,
    module_info::in, module_info::out, dump_info::in, dump_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

do_typecheck(Verbose, Stats, Globals, FoundSyntaxError, FoundTypeError,
        NumberOfIterations, !HLDS, !DumpInfo, !Specs, !IO) :-
    % Next typecheck the clauses.
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    maybe_write_string(Verbose, "% Type-checking...\n", !IO),
    maybe_write_string(Verbose, "% Type-checking clauses...\n", !IO),
    globals.lookup_bool_option(Globals, type_check_constraints,
        TypeCheckConstraints),
    (
        TypeCheckConstraints = yes,
        globals.lookup_string_option(Globals, experiment, Experiment),
        ( if Experiment = "old_type_constraints" then
            old_typecheck_constraints(!HLDS, TypeCheckSpecs)
        else
            typecheck_constraints(!HLDS, TypeCheckSpecs)
        ),
        % XXX We should teach typecheck_constraints to report syntax errors.
        FoundSyntaxError = no_clause_syntax_errors,
        NumberOfIterations = within_iteration_limit
    ;
        TypeCheckConstraints = no,
        prepare_for_typecheck_module(!HLDS),
        typecheck_module(!HLDS, TypeCheckSpecs, FoundSyntaxError,
            NumberOfIterations)
    ),
    !:Specs = TypeCheckSpecs ++ !.Specs,
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    FoundTypeError = contains_errors(Globals, TypeCheckSpecs),
    (
        FoundTypeError = yes,
        maybe_write_string(Verbose,
            "% Program contains type error(s).\n", !IO)
    ;
        FoundTypeError = no,
        maybe_write_string(Verbose,
            "% Program is type-correct.\n", !IO)
    ),
    maybe_report_stats(Stats, !IO),
    maybe_dump_hlds(!.HLDS, 15, "typecheck", !DumpInfo, !IO).

:- pred frontend_pass_after_typecheck(op_mode_augment::in,
    bool::in, bool::in, globals::in, bool::in, bool::in, bool::out,
    module_info::in, module_info::out, dump_info::in, dump_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

frontend_pass_after_typecheck(OpModeAugment, Verbose, Stats, Globals,
        FoundUndefModeError, !FoundError, !HLDS, !DumpInfo, !Specs, !IO) :-
    % We invoke purity check even if --typecheck-only was specified,
    % because the resolution of predicate and function overloading
    % is done during the purity pass, and errors in the resolution
    % of such overloading are type errors. However, the code that
    % does this resolution depends on the absence of the other type
    % errors that post_typecheck.m is designed to discover.
    % (See Mantis bug 113.)

    puritycheck(Verbose, Stats, !HLDS, !Specs, !IO),
    maybe_dump_hlds(!.HLDS, 20, "puritycheck", !DumpInfo, !IO),

    check_promises(Verbose, Stats, !HLDS, !Specs, !IO),
    maybe_dump_hlds(!.HLDS, 22, "check_promises", !DumpInfo, !IO),

    (
        OpModeAugment = opmau_typecheck_only
    ;
        % Switch detection looks at only a maximum of two levels
        % of disjunction, not three, so we need this block here;
        % the block that sets MakeOptInt is not recognized as
        % being a switch arm complementing the opmau_typecheck_only arm.
        ( OpModeAugment = opmau_make_plain_opt
        ; OpModeAugment = opmau_make_trans_opt
        ; OpModeAugment = opmau_make_analysis_registry
        ; OpModeAugment = opmau_make_xml_documentation
        ; OpModeAugment = opmau_errorcheck_only
        ; OpModeAugment = opmau_generate_code(_)
        ),
        (
            OpModeAugment = opmau_make_plain_opt,
            MakeOptInt = yes
        ;
            ( OpModeAugment = opmau_make_trans_opt
            ; OpModeAugment = opmau_make_analysis_registry
            ; OpModeAugment = opmau_make_xml_documentation
            ; OpModeAugment = opmau_errorcheck_only
            ; OpModeAugment = opmau_generate_code(_)
            ),
            MakeOptInt = no
        ),

        % Substitute implementation-defined literals before
        % clauses are written out to `.opt' files.
        subst_implementation_defined_literals(Verbose, Stats, !HLDS,
            !Specs, !IO),
        maybe_dump_hlds(!.HLDS, 25, "implementation_defined_literals",
            !DumpInfo, !IO),

        ( if
            !.FoundError = no,
            FoundUndefModeError = no
        then
            MakeOptIntEnabled = yes
        else
            MakeOptIntEnabled = no
        ),
        globals.lookup_bool_option(Globals, intermodule_analysis,
            IntermodAnalysis),
        % Whether we are creating a .opt file or not, we want to mark
        % the entities that *would be* in the .opt file as opt_exported,
        % so that e.g. we will set the storage class of the C code
        % we generate for opt_exported predicates to "extern" instead of
        % "static".
        %
        % However, if we found any errors so far that would prevent us
        % from getting to the code generation stage, then such marking
        % would have no effect, and so we don't bother.
        (
            MakeOptInt = yes,
            (
                MakeOptIntEnabled = no
            ;
                MakeOptIntEnabled = yes,
                % Only write out the `.opt' file if there are no errors.
                %
                % This will invoke frontend_pass_by_phases *if and only if*
                % some of the enabled optimizations need it.
                create_and_write_opt_file(IntermodAnalysis, Globals,
                    !HLDS, !DumpInfo, !Specs, !IO)
            )
            % If our job was to write out the `.opt' file, then we are done.
        ;
            MakeOptInt = no,
            (
                MakeOptIntEnabled = no
            ;
                MakeOptIntEnabled = yes,
                mark_entities_in_opt_file_as_opt_exported(IntermodAnalysis,
                    Globals, !HLDS, !IO)
            ),
            % Now go ahead and do the rest of the front end passes.
            frontend_pass_by_phases(!HLDS, FoundModeOrDetError,
                !DumpInfo, !Specs, !IO),
            bool.or(FoundModeOrDetError, !FoundError)
        )
    ).

%---------------------------------------------------------------------------%

:- pred create_and_write_opt_file(bool::in, globals::in,
    module_info::in, module_info::out, dump_info::in, dump_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

create_and_write_opt_file(IntermodAnalysis, Globals, !HLDS, !DumpInfo,
        !Specs, !IO) :-
    module_info_get_name(!.HLDS, ModuleName),
    module_name_to_file_name(Globals, $pred, do_create_dirs,
        ext_other(other_ext(".opt")), ModuleName, OptFileName, !IO),
    TmpOptFileName = OptFileName ++ ".tmp",

    io.open_output(TmpOptFileName, OpenResult, !IO),
    (
        OpenResult = error(Error),
        io.progname_base("mmc", ProgName, !IO),
        io.error_message(Error, ErrorMsg),
        io.format("%s: cannot open `%s' for output: %s\n",
            [s(ProgName), s(TmpOptFileName), s(ErrorMsg)], !IO),
        io.set_exit_status(1, !IO)
    ;
        OpenResult = ok(TmpOptStream),
        write_initial_opt_file(TmpOptStream, !.HLDS, IntermodInfo,
            ParseTreePlainOpt0, !IO),
        maybe_opt_export_listed_entities(IntermodInfo, !HLDS),

        % The following passes are only run with `--intermodule-optimisation'
        % to append their results to the `.opt.tmp' file. For
        % `--intermodule-analysis', analysis results should be recorded
        % using the intermodule analysis framework instead.
        % XXX So why is the test "IntermodAnalysis = no", instead of
        % "IntermodOpt = yes"?
        %
        % If intermod_unused_args is being performed, run polymorphism,
        % mode analysis and determinism analysis before unused_args.
        ( if
            IntermodAnalysis = no,
            need_middle_pass_for_opt_file(Globals, NeedMiddlePassForOptFile),
            NeedMiddlePassForOptFile = yes
        then
            frontend_pass_by_phases(!HLDS, FoundError, !DumpInfo, !Specs, !IO),
            (
                FoundError = no,
                middle_pass_for_opt_file(!HLDS, UnusedArgsInfos, !Specs, !IO),
                append_analysis_pragmas_to_opt_file(TmpOptStream, !.HLDS,
                    UnusedArgsInfos, ParseTreePlainOpt0, ParseTreePlainOpt,
                    !IO)
            ;
                FoundError = yes,
                io.set_exit_status(1, !IO),
                ParseTreePlainOpt = ParseTreePlainOpt0
            )
        else
            ParseTreePlainOpt = ParseTreePlainOpt0
        ),
        io.close_output(TmpOptStream, !IO),

        update_interface_report_any_error(Globals, ModuleName, OptFileName,
            _UpdateSucceeded, !IO),
        get_progress_output_stream(!.HLDS, ProgressStream, !IO),
        get_error_output_stream(!.HLDS, ErrorStream, !IO),
        touch_interface_datestamp(Globals, ProgressStream, ErrorStream,
            ModuleName, other_ext(".optdate"), _TouchSucceeded, !IO),

        globals.lookup_bool_option(Globals, experiment5, Experiment5),
        (
            Experiment5 = no
        ;
            Experiment5 = yes,
            io.open_output(OptFileName ++ "x", OptXResult, !IO),
            (
                OptXResult = error(_)
            ;
                OptXResult = ok(OptXStream),
                Info = init_merc_out_info(Globals, unqualified_item_names,
                    output_mercury),
                mercury_output_parse_tree_plain_opt(Info, OptXStream,
                    ParseTreePlainOpt, !IO),
                io.close_output(OptXStream, !IO)
            )
        )
    ).

    % If there is a `.opt' file for this module, then we must mark
    % the items that would be in the .opt file as opt_exported
    % even if we are not writing to the .opt file now.
    %
:- pred mark_entities_in_opt_file_as_opt_exported(bool::in,
    globals::in, module_info::in, module_info::out, io::di, io::uo) is det.

mark_entities_in_opt_file_as_opt_exported(IntermodAnalysis,
        Globals, !HLDS, !IO) :-
    globals.lookup_bool_option(Globals, intermodule_optimization,
        IntermodOpt),
    ( if
        ( IntermodOpt = yes
        ; IntermodAnalysis = yes
        )
    then
        UpdateStatus = yes
    else
        globals.lookup_bool_option(Globals, use_opt_files, UseOptFiles),
        (
            UseOptFiles = yes,
            module_info_get_name(!.HLDS, ModuleName),
            module_name_to_search_file_name(Globals, $pred,
                ext_other(other_ext(".opt")), ModuleName, OptFileName, !IO),
            globals.lookup_accumulating_option(Globals, intermod_directories,
                IntermodDirs),
            search_for_file_returning_dir(IntermodDirs, OptFileName,
                MaybeDir, !IO),
            (
                MaybeDir = ok(_),
                UpdateStatus = yes
            ;
                MaybeDir = error(_),
                UpdateStatus = no
            )
        ;
            UseOptFiles = no,
            UpdateStatus = no
        )
    ),
    (
        UpdateStatus = yes,
        intermod.maybe_opt_export_entities(!HLDS)
    ;
        UpdateStatus = no
    ).

:- pred need_middle_pass_for_opt_file(globals::in, bool::out) is det.

need_middle_pass_for_opt_file(Globals, NeedMiddlePassForOptFile) :-
    globals.get_opt_tuple(Globals, OptTuple),
    IntermodArgs = OptTuple ^ ot_opt_unused_args_intermod,
    globals.lookup_bool_option(Globals, termination, Termination),
    globals.lookup_bool_option(Globals, termination2, Termination2),
    globals.lookup_bool_option(Globals, structure_sharing_analysis,
        SharingAnalysis),
    globals.lookup_bool_option(Globals, structure_reuse_analysis,
        ReuseAnalysis),
    globals.lookup_bool_option(Globals, analyse_exceptions, ExceptionAnalysis),
    globals.lookup_bool_option(Globals, analyse_closures, ClosureAnalysis),
    globals.lookup_bool_option(Globals, analyse_trail_usage, TrailingAnalysis),
    globals.lookup_bool_option(Globals, analyse_mm_tabling, TablingAnalysis),
    ( if
        ( IntermodArgs = opt_unused_args_intermod
        ; Termination = yes
        ; Termination2 = yes
        ; ExceptionAnalysis = yes
        ; TrailingAnalysis = yes
        ; TablingAnalysis = yes
        ; ClosureAnalysis = yes
        ; SharingAnalysis = yes
        ; ReuseAnalysis = yes
        )
    then
        NeedMiddlePassForOptFile = yes
    else
        NeedMiddlePassForOptFile = no
    ).

%---------------------------------------------------------------------------%

:- pred frontend_pass_by_phases(module_info::in, module_info::out,
    bool::out, dump_info::in, dump_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

frontend_pass_by_phases(!HLDS, FoundError, !DumpInfo, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    globals.lookup_bool_option(Globals, verbose, Verbose),
    globals.lookup_bool_option(Globals, statistics, Stats),

    maybe_polymorphism(Verbose, Stats, ExistsCastPredIds, PolySafeToContinue,
        !HLDS, !Specs, !IO),
    maybe_dump_hlds(!.HLDS, 30, "polymorphism", !DumpInfo, !IO),

    (
        PolySafeToContinue = unsafe_to_continue,
        FoundError = yes
    ;
        PolySafeToContinue = safe_to_continue,

        clause_to_proc(Verbose, Stats, !HLDS, !Specs, !IO),
        maybe_dump_hlds(!.HLDS, 31, "clause_to_proc", !DumpInfo, !IO),

        post_copy_polymorphism_pass(Verbose, Stats, ExistsCastPredIds,
            !HLDS, !Specs, !IO),
        maybe_dump_hlds(!.HLDS, 32, "post_copy_polymorphism", !DumpInfo, !IO),

        maybe_warn_about_unused_imports(Verbose, Stats, !HLDS, !Specs, !IO),
        maybe_dump_hlds(!.HLDS, 33, "unused_imports", !DumpInfo, !IO),

        % XXX Convert the mode constraints pass to use error_specs.
        maybe_mode_constraints(Verbose, Stats, !HLDS, !IO),
        maybe_dump_hlds(!.HLDS, 34, "mode_constraints", !DumpInfo, !IO),

        modecheck(Verbose, Stats, !HLDS, FoundModeError, ModesSafeToContinue,
            !Specs, !IO),
        maybe_dump_hlds(!.HLDS, 35, "modecheck", !DumpInfo, !IO),

        maybe_compute_goal_modes(Verbose, Stats, !HLDS, !Specs, !IO),
        maybe_dump_hlds(!.HLDS, 36, "goal_modes", !DumpInfo, !IO),

        (
            ModesSafeToContinue = unsafe_to_continue,
            FoundError = yes
        ;
            ModesSafeToContinue = safe_to_continue,

            detect_switches(Verbose, Stats, !HLDS, !IO),
            maybe_dump_hlds(!.HLDS, 40, "switch_detect", !DumpInfo, !IO),

            detect_cse(Verbose, Stats, !HLDS, !IO),
            maybe_dump_hlds(!.HLDS, 45, "cse", !DumpInfo, !IO),

            check_determinism(Verbose, Stats, !HLDS, !Specs, !IO),
            maybe_dump_hlds(!.HLDS, 50, "determinism", !DumpInfo, !IO),

            check_unique_modes(Verbose, Stats, !HLDS, FoundUniqError,
                !Specs, !IO),
            maybe_dump_hlds(!.HLDS, 55, "unique_modes", !DumpInfo, !IO),

            check_stratification(Verbose, Stats, !HLDS, FoundStratError,
                !Specs, !IO),
            maybe_dump_hlds(!.HLDS, 60, "stratification", !DumpInfo, !IO),

            check_oisu_pragmas(Verbose, Stats, !HLDS, FoundOISUError,
                !Specs, !IO),
            maybe_dump_hlds(!.HLDS, 61, "oisu", !DumpInfo, !IO),

            process_try_goals(Verbose, Stats, !HLDS, FoundTryError,
                !Specs, !IO),
            maybe_dump_hlds(!.HLDS, 62, "try", !DumpInfo, !IO),

            maybe_simplify(yes, simplify_pass_frontend, Verbose, Stats,
                !HLDS, !Specs, !IO),
            maybe_dump_hlds(!.HLDS, 65, "frontend_simplify", !DumpInfo, !IO),

            maybe_generate_style_warnings(Verbose, Stats, !HLDS, !Specs, !IO),

            maybe_proc_statistics(Verbose, Stats, "AfterFrontEnd",
                !HLDS, !Specs, !IO),

            % Work out whether we encountered any errors.
            MaybeWorstSpecsSeverity =
                worst_severity_in_specs(Globals, !.Specs),
            io.get_exit_status(ExitStatus, !IO),
            ( if
                FoundModeError = no,
                FoundUniqError = no,
                FoundStratError = no,
                FoundOISUError = no,
                FoundTryError = no,
                (
                    MaybeWorstSpecsSeverity = no
                ;
                    MaybeWorstSpecsSeverity = yes(WorstSpecsSeverity),
                    worst_severity(WorstSpecsSeverity,
                        actual_severity_warning) = actual_severity_warning
                ),
                % Strictly speaking, we shouldn't need to check
                % the exit status. But the values returned for FoundModeError
                % etc. aren't always correct.
                ExitStatus = 0
            then
                FoundError = no
            else
                FoundError = yes
            )
        )
    ),
    maybe_dump_hlds(!.HLDS, 99, "front_end", !DumpInfo, !IO).

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- pred decide_type_repns_pass(bool::in, bool::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

decide_type_repns_pass(Verbose, Stats, !HLDS, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    maybe_write_string(Verbose,
        "% Deciding type representations...\n", !IO),
    decide_type_repns(!HLDS, !Specs, !IO),
    maybe_write_string(Verbose, "% done.\n", !IO),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred puritycheck(bool::in, bool::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

puritycheck(Verbose, Stats, !HLDS, !Specs, !IO) :-
    maybe_write_string(Verbose, "% Purity-checking clauses...\n", !IO),
    puritycheck_module(!HLDS, [], PuritySpecs),
    !:Specs = PuritySpecs ++ !.Specs,
    module_info_get_globals(!.HLDS, Globals),
    PurityErrors = contains_errors(Globals, PuritySpecs),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    (
        PurityErrors = yes,
        maybe_write_string(Verbose,
            "% Program contains purity error(s).\n", !IO)
    ;
        PurityErrors = no,
        maybe_write_string(Verbose,
            "% Program is purity-correct.\n", !IO)
    ),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred check_promises(bool::in, bool::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

check_promises(Verbose, Stats, !HLDS, !Specs, !IO) :-
    maybe_write_string(Verbose, "% Checking any promises...\n", !IO),
    check_promises_in_module(!HLDS, [], PromiseSpecs),
    !:Specs = PromiseSpecs ++ !.Specs,
    module_info_get_globals(!.HLDS, Globals),
    PromiseErrors = contains_errors(Globals, PromiseSpecs),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    (
        PromiseErrors = yes,
        maybe_write_string(Verbose,
            "% Program contains error(s) in promises.\n", !IO)
    ;
        PromiseErrors = no,
        maybe_write_string(Verbose,
            "% All promises are correct.\n", !IO)
    ),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred subst_implementation_defined_literals(bool::in, bool::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

subst_implementation_defined_literals(Verbose, Stats, !HLDS, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    maybe_write_string(Verbose,
        "% Substituting implementation-defined literals...\n", !IO),
    maybe_flush_output(Verbose, !IO),
    subst_impl_defined_literals(!HLDS),
    maybe_write_string(Verbose, "% done.\n", !IO),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred maybe_polymorphism(bool::in, bool::in,
    list(pred_id)::out, maybe_safe_to_continue::out,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

maybe_polymorphism(Verbose, Stats, ExistsCastPredIds, SafeToContinue,
        !HLDS, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),

    globals.lookup_bool_option(Globals, very_verbose, VeryVerbose),
    (
        VeryVerbose = no,
        maybe_write_string(Verbose,
            "% Transforming polymorphic unifications...", !IO)
    ;
        VeryVerbose = yes,
        maybe_write_string(Verbose,
            "% Transforming polymorphic unifications...\n", !IO)
    ),
    maybe_flush_output(Verbose, !IO),
    polymorphism_process_module(!HLDS, ExistsCastPredIds,
        SafeToContinue, PolySpecs),
    !:Specs = PolySpecs ++ !.Specs,
    (
        VeryVerbose = no,
        maybe_write_string(Verbose, " done.\n", !IO)
    ;
        VeryVerbose = yes,
        maybe_write_string(Verbose, "% done.\n", !IO)
    ),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred clause_to_proc(bool::in, bool::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

clause_to_proc(Verbose, Stats, !HLDS, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    maybe_write_string(Verbose, "% Copying clauses to procedures...", !IO),
    copy_clauses_to_proc_for_all_valid_procs(!HLDS),
    maybe_write_string(Verbose, " done.\n", !IO),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred post_copy_polymorphism_pass(bool::in, bool::in,
    list(pred_id)::in, module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

post_copy_polymorphism_pass(Verbose, Stats, ExistsCastPredIds, !HLDS,
        !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    maybe_write_string(Verbose, "% Post copy polymorphism...", !IO),
    post_copy_polymorphism(ExistsCastPredIds, !HLDS),
    maybe_write_string(Verbose, " done.\n", !IO),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred maybe_warn_about_unused_imports(bool::in, bool::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

maybe_warn_about_unused_imports(Verbose, Stats, !HLDS, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    globals.lookup_bool_option(Globals, warn_unused_imports,
        WarnUnusedImports),
    (
        WarnUnusedImports = yes,
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose, "% Checking for unused imports...", !IO),
        warn_about_unused_imports(!.HLDS, UnusedImportSpecs),
        !:Specs = UnusedImportSpecs ++ !.Specs,
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose, " done.\n", !IO),
        maybe_report_stats(Stats, !IO)
    ;
        WarnUnusedImports = no
    ).

%---------------------------------------------------------------------------%

:- pred maybe_mode_constraints(bool::in, bool::in,
    module_info::in, module_info::out, io::di, io::uo) is det.

maybe_mode_constraints(Verbose, Stats, !HLDS, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    globals.lookup_bool_option(Globals, mode_constraints, ModeConstraints),
    (
        ModeConstraints = yes,
        maybe_write_string(Verbose, "% Dumping mode constraints...\n", !IO),
        maybe_flush_output(Verbose, !IO),
        maybe_benchmark_modes(mc_process_module,
            "mode-constraints", !HLDS, !IO),
        maybe_write_string(Verbose, "% done.\n", !IO),
        maybe_report_stats(Stats, !IO)
    ;
        ModeConstraints = no
    ).

:- pred modecheck(bool::in, bool::in, module_info::in, module_info::out,
    bool::out, maybe_safe_to_continue::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

modecheck(Verbose, Stats, !HLDS, FoundModeError, SafeToContinue,
        !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    maybe_write_string(Verbose, "% Mode-checking clauses...\n", !IO),
    globals.lookup_bool_option(Globals, benchmark_modes, BenchmarkModes),
    (
        BenchmarkModes = yes,
        globals.lookup_int_option(Globals, benchmark_modes_repeat, Repeats),
        promise_equivalent_solutions [!:HLDS, SafeToContinue, ModeSpecs, Time]
        (
            benchmark_det(modecheck_module,
                !.HLDS, {!:HLDS, SafeToContinue, ModeSpecs}, Repeats, Time)
        ),
        io.format("BENCHMARK modecheck, %d repeats: %d ms\n",
            [i(Repeats), i(Time)], !IO)
    ;
        BenchmarkModes = no,
        modecheck_module(!.HLDS, {!:HLDS, SafeToContinue, ModeSpecs})
    ),
    !:Specs = ModeSpecs ++ !.Specs,
    FoundModeError = contains_errors(Globals, ModeSpecs),
    (
        FoundModeError = no,
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose, "% Program is mode-correct.\n", !IO)
    ;
        FoundModeError = yes,
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose, "% Program contains mode error(s).\n", !IO)
    ),
    maybe_report_stats(Stats, !IO).

:- pred maybe_benchmark_modes(
    pred(module_info, module_info, io, io)::in(pred(in, out, di, uo) is det),
    string::in, module_info::in, module_info::out, io::di, io::uo) is det.

maybe_benchmark_modes(Pred, Stage, !HLDS, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    globals.lookup_bool_option(Globals, benchmark_modes, BenchmarkModes),
    (
        BenchmarkModes = yes,
        globals.lookup_int_option(Globals, benchmark_modes_repeat, Repeats),
        io.format("%s %d ", [s(Stage), i(Repeats)], !IO),
        promise_equivalent_solutions [!:HLDS, Time, !:IO] (
            do_io_benchmark(Pred, Repeats, !.HLDS, !:HLDS - Time, !IO)
        ),
        io.format("%d ms\n", [i(Time)], !IO)
    ;
        BenchmarkModes = no,
        Pred(!HLDS, !IO)
    ).

:- pred do_io_benchmark(pred(T1, T2, io, io)::in(pred(in, out, di, uo) is det),
    int::in, T1::in, pair(T2, int)::out, io::di, io::uo) is cc_multi.

do_io_benchmark(Pred, Repeats, A0, A - Time, !IO) :-
    benchmark_det_io(Pred, A0, A, !IO, Repeats, Time).

%---------------------------------------------------------------------------%

:- pred maybe_compute_goal_modes(bool::in, bool::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

maybe_compute_goal_modes(Verbose, Stats, !HLDS, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    globals.lookup_bool_option(Globals, compute_goal_modes, ComputeGoalModes),
    (
        ComputeGoalModes = no
    ;
        ComputeGoalModes = yes,
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose, "% Computing goal modes... ", !IO),
        compute_goal_modes_in_module(!HLDS),
        maybe_write_string(Verbose, "% done.\n", !IO),
        maybe_report_stats(Stats, !IO)
    ).

%---------------------------------------------------------------------------%

:- pred detect_switches(bool::in, bool::in, module_info::in, module_info::out,
    io::di, io::uo) is det.

detect_switches(Verbose, Stats, !HLDS, !IO) :-
    maybe_write_string(Verbose, "% Detecting switches...\n", !IO),
    maybe_flush_output(Verbose, !IO),
    detect_switches_in_module(!HLDS),
    maybe_write_string(Verbose, "% done.\n", !IO),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred detect_cse(bool::in, bool::in, module_info::in, module_info::out,
    io::di, io::uo) is det.

detect_cse(Verbose, Stats, !HLDS, !IO) :-
    maybe_write_string(Verbose,
        "% Detecting common deconstructions...\n", !IO),
    detect_cse_in_module(!HLDS),
    maybe_write_string(Verbose, "% done.\n", !IO),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred check_determinism(bool::in, bool::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

check_determinism(Verbose, Stats, !HLDS, !Specs, !IO) :-
    determinism_pass(!HLDS, DetismSpecs),
    !:Specs = DetismSpecs ++ !.Specs,
    module_info_get_globals(!.HLDS, Globals),
    FoundError = contains_errors(Globals, DetismSpecs),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    (
        FoundError = yes,
        maybe_write_string(Verbose,
            "% Program contains determinism error(s).\n", !IO)
    ;
        FoundError = no,
        maybe_write_string(Verbose,
            "% Program is determinism-correct.\n", !IO)
    ),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred check_unique_modes(bool::in, bool::in,
    module_info::in, module_info::out, bool::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

check_unique_modes(Verbose, Stats, !HLDS, FoundError, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    maybe_write_string(Verbose,
        "% Checking for backtracking over unique modes...\n", !IO),
    unique_modes_check_module(!HLDS, UniqueSpecs),
    !:Specs = UniqueSpecs ++ !.Specs,
    FoundError = contains_errors(Globals, UniqueSpecs),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    (
        FoundError = yes,
        maybe_write_string(Verbose,
            "% Program contains unique mode error(s).\n", !IO)
    ;
        FoundError = no,
        maybe_write_string(Verbose, "% Program is unique-mode-correct.\n", !IO)
    ),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

:- pred check_stratification(bool::in, bool::in,
    module_info::in, module_info::out, bool::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

check_stratification(Verbose, Stats, !HLDS, FoundError, !Specs, !IO) :-
    module_info_get_must_be_stratified_preds(!.HLDS, MustBeStratifiedPreds),
    module_info_get_globals(!.HLDS, Globals),
    globals.lookup_bool_option(Globals, warn_non_stratification, Warn),
    ( if
        ( set.is_non_empty(MustBeStratifiedPreds)
        ; Warn = yes
        )
    then
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose, "% Checking stratification...\n", !IO),
        check_module_for_stratification(!HLDS, StratifySpecs),
        !:Specs = StratifySpecs ++ !.Specs,
        FoundError = contains_errors(Globals, StratifySpecs),
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        (
            FoundError = yes,
            maybe_write_string(Verbose,
                "% Program contains stratification error(s).\n", !IO)
        ;
            FoundError = no,
            maybe_write_string(Verbose, "% done.\n", !IO)
        ),
        maybe_report_stats(Stats, !IO)
    else
        FoundError = no
    ).

%---------------------------------------------------------------------------%

:- pred check_oisu_pragmas(bool::in, bool::in,
    module_info::in, module_info::out, bool::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

check_oisu_pragmas(Verbose, Stats, !HLDS, FoundError, !Specs, !IO) :-
    module_info_get_oisu_map(!.HLDS, OISUMap),
    map.to_assoc_list(OISUMap, OISUPairs),
    module_info_get_name(!.HLDS, ModuleName),
    list.filter(type_ctor_is_defined_in_this_module(ModuleName),
        OISUPairs, ModuleOISUPairs),
    (
        ModuleOISUPairs = [_ | _],
        module_info_get_globals(!.HLDS, Globals),
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose,
            "% Checking oisu pragmas...\n", !IO),
        check_oisu_pragmas_for_module(ModuleOISUPairs, !HLDS, OISUSpecs),
        !:Specs = OISUSpecs ++ !.Specs,
        FoundError = contains_errors(Globals, OISUSpecs),
        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        (
            FoundError = yes,
            maybe_write_string(Verbose,
                "% Program contains oisu pragma error(s).\n", !IO)
        ;
            FoundError = no,
            maybe_write_string(Verbose, "% done.\n", !IO)
        ),
        maybe_report_stats(Stats, !IO)
    ;
        ModuleOISUPairs = [],
        FoundError = no
    ).

:- pred type_ctor_is_defined_in_this_module(module_name::in,
    pair(type_ctor, oisu_preds)::in) is semidet.

type_ctor_is_defined_in_this_module(ModuleName, TypeCtor - _) :-
    TypeCtor = type_ctor(TypeSymName, _TypeArity),
    TypeSymName = qualified(TypeModuleName, _TypeName),
    ModuleName = TypeModuleName.

%---------------------------------------------------------------------------%

:- pred process_try_goals(bool::in, bool::in,
    module_info::in, module_info::out, bool::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

process_try_goals(Verbose, Stats, !HLDS, FoundError, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    maybe_write_string(Verbose, "% Transforming try goals...\n", !IO),
    expand_try_goals_in_module(!HLDS, [], TryExpandSpecs),
    !:Specs = TryExpandSpecs ++ !.Specs,
    FoundError = contains_errors(Globals, TryExpandSpecs),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
    (
        FoundError = yes,
        maybe_write_string(Verbose, "% Program contains error(s).\n", !IO)
    ;
        FoundError = no,
        maybe_write_string(Verbose, "% done.\n", !IO)
    ),
    maybe_report_stats(Stats, !IO).

%---------------------------------------------------------------------------%

maybe_simplify(Warn, SimplifyPass, Verbose, Stats, !HLDS, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    some [!SimpList] (
        ( Warn = no,  WarnGen = do_not_generate_warnings
        ; Warn = yes, WarnGen = generate_warnings
        ),
        find_simplify_tasks(Globals, WarnGen, SimplifyTasks0),
        !:SimpList = simplify_tasks_to_list(SimplifyTasks0),
        (
            SimplifyPass = simplify_pass_frontend,
            list.cons(simptask_after_front_end, !SimpList),
            list.cons(simptask_try_opt_const_structs, !SimpList)
        ;
            SimplifyPass = simplify_pass_post_untuple,
            list.cons(simptask_mark_code_model_changes, !SimpList)
        ;
            SimplifyPass = simplify_pass_pre_prof_transforms,

            % We run the simplify pass before the profiling transformations
            % only if those transformations are being applied; otherwise we
            % just leave things to the backend simplification passes.

            globals.lookup_bool_option(Globals, pre_prof_transforms_simplify,
                PreProfSimplify),
            (
                PreProfSimplify = yes,
                list.cons(simptask_mark_code_model_changes, !SimpList)
            ;
                PreProfSimplify = no,
                !:SimpList = []
            )
        ;
            SimplifyPass = simplify_pass_pre_implicit_parallelism,

            % We run the simplify pass before the implicit parallelism pass if
            % implicit parallelism is enabled.

            globals.lookup_bool_option(Globals,
                pre_implicit_parallelism_simplify, PreParSimplify),
            (
                PreParSimplify = yes,
                list.cons(simptask_mark_code_model_changes, !SimpList)
            ;
                PreParSimplify = no,
                !:SimpList = []
            )
        ;
            SimplifyPass = simplify_pass_ml_backend,
            list.cons(simptask_mark_code_model_changes, !SimpList)
        ;
            SimplifyPass = simplify_pass_ll_backend,
            % Don't perform constant propagation if one of the
            % profiling transformations has been applied.
            %
            % NOTE: Any changes made here may also need to be made
            % to the relevant parts of backend_pass_by_preds_4/12.
            globals.get_opt_tuple(Globals, OptTuple),
            ConstProp = OptTuple ^ ot_prop_constants,
            globals.lookup_bool_option(Globals, profile_deep, DeepProf),
            globals.lookup_bool_option(Globals, record_term_sizes_as_words,
                TSWProf),
            globals.lookup_bool_option(Globals, record_term_sizes_as_cells,
                TSCProf),
            ( if
                ConstProp = prop_constants,
                DeepProf = no,
                TSWProf = no,
                TSCProf = no
            then
                list.cons(simptask_constant_prop, !SimpList)
            else
                list.delete_all(!.SimpList, simptask_constant_prop, !:SimpList)
            ),
            list.cons(simptask_mark_code_model_changes, !SimpList),
            list.cons(simptask_elim_removable_scopes, !SimpList)
        ),
        SimpList = !.SimpList
    ),
    (
        SimpList = [_ | _],

        maybe_write_out_errors(Verbose, Globals, !Specs, !IO),
        maybe_write_string(Verbose, "% Simplifying goals...\n", !IO),
        maybe_flush_output(Verbose, !IO),
        SimplifyTasks = list_to_simplify_tasks(Globals, SimpList),
        process_valid_nonimported_preds_errors(
            update_pred_error(simplify_pred(SimplifyTasks)),
            !HLDS, [], SimplifySpecs, !IO),
        (
            SimplifyPass = simplify_pass_frontend,
            !:Specs = SimplifySpecs ++ !.Specs,
            maybe_write_out_errors(Verbose, Globals, !Specs, !IO)
        ;
            ( SimplifyPass = simplify_pass_ll_backend
            ; SimplifyPass = simplify_pass_ml_backend
            ; SimplifyPass = simplify_pass_post_untuple
            ; SimplifyPass = simplify_pass_pre_prof_transforms
            ; SimplifyPass = simplify_pass_pre_implicit_parallelism
            )
        ),
        maybe_write_string(Verbose, "% done.\n", !IO),
        maybe_report_stats(Stats, !IO)
    ;
        SimpList = []
    ).

:- pred simplify_pred(simplify_tasks::in, pred_id::in,
    module_info::in, module_info::out, pred_info::in, pred_info::out,
    list(error_spec)::in, list(error_spec)::out) is det.

simplify_pred(SimplifyTasks0, PredId, !ModuleInfo, !PredInfo, !Specs) :-
    trace [io(!IO)] (
        write_pred_progress_message(!.ModuleInfo, "Simplifying", PredId, !IO)
    ),
    ProcIds = pred_info_valid_non_imported_procids(!.PredInfo),
    % Don't warn for compiler-generated procedures.
    ( if is_unify_index_or_compare_pred(!.PredInfo) then
        SimplifyTasks = SimplifyTasks0 ^ do_warn_simple_code
            := do_not_warn_simple_code
    else
        SimplifyTasks = SimplifyTasks0
    ),
    ErrorSpecs0 = init_error_spec_accumulator,
    simplify_pred_procs(SimplifyTasks, PredId, ProcIds, !ModuleInfo,
        !PredInfo, ErrorSpecs0, ErrorSpecs),
    module_info_get_globals(!.ModuleInfo, Globals),
    SpecsList = error_spec_accumulator_to_list(ErrorSpecs),
    !:Specs = SpecsList ++ !.Specs,
    globals.lookup_bool_option(Globals, detailed_statistics, Statistics),
    trace [io(!IO)] (
        maybe_report_stats(Statistics, !IO)
    ).

%---------------------------------------------------------------------------%

:- pred maybe_generate_style_warnings(bool::in, bool::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

maybe_generate_style_warnings(Verbose, Stats, !HLDS, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),

    globals.lookup_bool_option(Globals, warn_non_contiguous_decls,
        NonContiguousDecls),
    globals.lookup_bool_option(Globals, warn_inconsistent_pred_order_clauses,
        InconsistentPredOrderClauses),
    globals.lookup_bool_option(Globals,
        warn_inconsistent_pred_order_foreign_procs,
        InconsistentPredOrderForeignProcs),
    (
        InconsistentPredOrderForeignProcs = no,
        (
            InconsistentPredOrderClauses = no,
            InconsistentPredOrder = no
        ;
            InconsistentPredOrderClauses = yes,
            InconsistentPredOrder = yes(only_clauses)
        )
    ;
        InconsistentPredOrderForeignProcs = yes,
        InconsistentPredOrder = yes(clauses_and_foreign_procs)
    ),
    (
        NonContiguousDecls = no,
        InconsistentPredOrder = no,
        MaybeTask = no
    ;
        NonContiguousDecls = no,
        InconsistentPredOrder = yes(DefnKinds),
        MaybeTask = yes(inconsistent_pred_order_only(DefnKinds))
    ;
        NonContiguousDecls = yes,
        InconsistentPredOrder = no,
        MaybeTask = yes(non_contiguous_decls_only)
    ;
        NonContiguousDecls = yes,
        InconsistentPredOrder = yes(DefnKinds),
        MaybeTask =
            yes(non_contiguous_decls_and_inconsistent_pred_order(DefnKinds))
    ),
    (
        MaybeTask = yes(Task),
        maybe_write_string(Verbose,
            "% Generating style warnings...\n", !IO),
        generate_style_warnings(!.HLDS, Task, StyleSpecs),
        !:Specs = StyleSpecs ++ !.Specs,
        maybe_write_string(Verbose, "% done.\n", !IO),
        maybe_report_stats(Stats, !IO)
    ;
        MaybeTask = no
    ).

%---------------------------------------------------------------------------%

:- pred maybe_proc_statistics(bool::in, bool::in, string::in,
    module_info::in, module_info::out,
    list(error_spec)::in, list(error_spec)::out, io::di, io::uo) is det.

maybe_proc_statistics(Verbose, Stats, Msg, !HLDS, !Specs, !IO) :-
    module_info_get_globals(!.HLDS, Globals),
    maybe_write_out_errors(Verbose, Globals, !Specs, !IO),

    globals.lookup_string_option(Globals, proc_size_statistics, StatsFileName),
    ( if StatsFileName = "" then
        % The user has not asked us to print these statistics.
        true
    else
        io.open_append(StatsFileName, StatsFileNameResult, !IO),
        (
            StatsFileNameResult = ok(StatsFileStream),
            maybe_write_string(Verbose,
                "% Generating proc statistics...\n", !IO),
            write_proc_stats_for_module(StatsFileStream, Msg, !.HLDS, !IO),
            io.close_output(StatsFileStream, !IO),
            maybe_write_string(Verbose, "% done.\n", !IO),
            maybe_report_stats(Stats, !IO)
        ;
            StatsFileNameResult = error(StatsFileError),
            io.error_message(StatsFileError, StatsFileErrorMsg),
            maybe_write_string(Verbose,
                "% Cannot write proc statistics: ", !IO),
            maybe_write_string(Verbose, StatsFileErrorMsg, !IO),
            maybe_write_string(Verbose, "\n", !IO)
        )
    ).

%---------------------------------------------------------------------------%
:- end_module top_level.mercury_compile_front_end.
%---------------------------------------------------------------------------%
