%-----------------------------------------------------------------------------%
% Copyright (C) 2000, 2003-2004 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

:- module hlds__code_model.

% This module defines the `code_model' data type, and associated procedures.
% The `code_model' type is a simplified version of the `determinism' type
% that is defined in prog_data.m.  It ignores most of the distinctions in
% the determinism type and keeps only the distinctions that are important
% for code generation.

% We define this in a different module than the `determinism' type because
% it is only used by some of the different back-ends, not all of them.
% It is used by the MLDS, LLDS, and bytecode back-ends, but not by the
% Aditi-RL back-end.

%-----------------------------------------------------------------------------%

:- interface.

:- import_module hlds__hlds_goal.
:- import_module hlds__hlds_pred.
:- import_module parse_tree__prog_data.

:- type code_model
	--->	model_det		% functional & total
	;	model_semi		% just functional
	;	model_non.		% not functional

:- pred determinism_to_code_model(determinism, code_model).
:- mode determinism_to_code_model(in, out) is det.
:- mode determinism_to_code_model(out, in) is multi.

:- pred proc_info_interface_code_model(proc_info::in, code_model::out) is det.

:- pred goal_info_get_code_model(hlds_goal_info::in, code_model::out) is det.

	% Construct a representation of the interface determinism of a
	% procedure. The code we have chosen is not sequential; instead
	% it encodes the various properties of each determinism.
	% This must match the encoding of MR_Determinism in
	% mercury_stack_layout.h.
	%
	% The 8 bit is set iff the context is first_solution.
	% The 4 bit is set iff the min number of solutions is more than zero.
	% The 2 bit is set iff the max number of solutions is more than zero.
	% The 1 bit is set iff the max number of solutions is more than one.
:- func represent_determinism(determinism) = int.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module int.

determinism_to_code_model(det,         model_det).
determinism_to_code_model(semidet,     model_semi).
determinism_to_code_model(nondet,      model_non).
determinism_to_code_model(multidet,    model_non).
determinism_to_code_model(cc_nondet,   model_semi).
determinism_to_code_model(cc_multidet, model_det).
determinism_to_code_model(erroneous,   model_det).
determinism_to_code_model(failure,     model_semi).

proc_info_interface_code_model(ProcInfo, CodeModel) :-
	proc_info_interface_determinism(ProcInfo, Determinism),
	determinism_to_code_model(Determinism, CodeModel).

goal_info_get_code_model(GoalInfo, CodeModel) :-
	goal_info_get_determinism(GoalInfo, Determinism),
	determinism_to_code_model(Determinism, CodeModel).

represent_determinism(det) = max_more_than_zero \/ min_more_than_zero.
represent_determinism(semidet) = max_more_than_zero.
represent_determinism(nondet) = max_more_than_one.
represent_determinism(multidet) = max_more_than_one \/ min_more_than_zero.
represent_determinism(erroneous) = min_more_than_zero.
represent_determinism(failure) = 0.
represent_determinism(cc_nondet) =
		represent_determinism(nondet) \/ first_solution.
represent_determinism(cc_multidet) =
		represent_determinism(multidet) \/ first_solution.

:- func first_solution = int.
first_solution = 8.

:- func min_more_than_zero = int.
min_more_than_zero = 4.

:- func max_more_than_zero = int.
max_more_than_zero = 2.

:- func max_more_than_one = int.
max_more_than_one = 3.

%-----------------------------------------------------------------------------%
