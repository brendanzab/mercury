%-----------------------------------------------------------------------------%
% Copyright (C) 1995 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%

:- module dependency_graph.
% Main author: bromage, conway.

% The dependency_graph contains the intra-module dependency information
% of a module.  It is defined as a relation (see hlds.m) R where xRy
% means that the definition of x depends on the definition of y.
%
% The other important structure is the dependency_ordering which is
% a list of the cliques of this relation, in topological order.

%-----------------------------------------------------------------------------%

:- interface.
:- import_module hlds, io.

:- pred module_info_ensure_dependency_info(module_info, module_info).
:- mode module_info_ensure_dependency_info(in, out) is det.

:- pred dependency_graph__write_dependency_graph(module_info, module_info,
						io__state, io__state).
:- mode dependency_graph__write_dependency_graph(in, out, di, uo) is det.

	% Output a form of the static call graph to a file for use by the
	% profiler.
:- pred dependency_graph__write_prof_dependency_graph(module_info, module_info,
						io__state, io__state).
:- mode dependency_graph__write_prof_dependency_graph(in, out, di, uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.
:- import_module list, map, set, prog_io, std_util.
:- import_module mode_util, int, term, require, string.
:- import_module varset, mercury_to_mercury, relation.
:- import_module globals, options, code_info.
:- import_module llds.

%-----------------------------------------------------------------------------%

	% Ensure that the dependency graph has been built by building
	% it if necessary.

module_info_ensure_dependency_info(ModuleInfo0, ModuleInfo) :-
	( module_info_dependency_info_built(ModuleInfo0) ->
	    ModuleInfo = ModuleInfo0
	;
	    dependency_graph__build_dependency_graph(ModuleInfo0, ModuleInfo)
	).

	% Traverse the module structure, calling `dependency_graph__add_arcs'
	% for each procedure body.

:- pred dependency_graph__build_dependency_graph(module_info, module_info).
:- mode dependency_graph__build_dependency_graph(in, out) is det.

dependency_graph__build_dependency_graph(ModuleInfo0, ModuleInfo) :-
	module_info_predids(ModuleInfo0, PredIds),
	relation__init(DepGraph0),
	dependency_graph__add_pred_arcs(PredIds, ModuleInfo0,
				DepGraph0, DepGraph),
	dependency_info__init(DepInfo0),
	dependency_info__set_dependency_graph(DepInfo0, DepGraph, DepInfo1),
	relation__atsort(DepGraph, DepOrd0),
	dependency_graph__list_set_to_list_list(ModuleInfo0, DepOrd0,
				[], DepOrd),
	dependency_info__set_dependency_ordering(DepInfo1, DepOrd, DepInfo),
	module_info_set_dependency_info(ModuleInfo0, DepInfo, ModuleInfo).

:- pred dependency_graph__list_set_to_list_list(module_info,
			list(set(pred_proc_id)),
			list(list(pred_proc_id)), list(list(pred_proc_id))).
:- mode dependency_graph__list_set_to_list_list(in, in, in, out) is det.
dependency_graph__list_set_to_list_list(_ModuleInfo, [], Xs, Xs).
dependency_graph__list_set_to_list_list(ModuleInfo, [X | Xs], Ys, Zs) :-
	set__to_sorted_list(X, Y0),
	dependency_graph__remove_imported_preds(ModuleInfo, Y0, Y),
	( Y = [] ->
	    Ys1 = Ys
	;
	    Ys1 = [Y | Ys]
	),
	dependency_graph__list_set_to_list_list(ModuleInfo, Xs, Ys1, Zs).

:- pred dependency_graph__remove_imported_preds(module_info,
			list(pred_proc_id), list(pred_proc_id)).
:- mode dependency_graph__remove_imported_preds(in, in, out) is det.
dependency_graph__remove_imported_preds(_ModuleInfo, [], []).
dependency_graph__remove_imported_preds(ModuleInfo,
			[PredId - ProcId | Rest], PredsOut) :-
	module_info_preds(ModuleInfo, PredTable),
	map__lookup(PredTable, PredId, PredInfo),
	( pred_info_is_imported(PredInfo) ->
	    PredsOut = Rest1
	;
	    PredsOut = [PredId - ProcId | Rest1]
	),
	dependency_graph__remove_imported_preds(ModuleInfo, Rest, Rest1).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- pred dependency_graph__add_pred_arcs(list(pred_id), module_info,
			dependency_graph, dependency_graph).
:- mode dependency_graph__add_pred_arcs(in, in, in, out) is det.

dependency_graph__add_pred_arcs([], _ModuleInfo, DepGraph, DepGraph).
dependency_graph__add_pred_arcs([PredId | PredIds], ModuleInfo,
					DepGraph0, DepGraph) :-
	module_info_preds(ModuleInfo, PredTable),
	map__lookup(PredTable, PredId, PredInfo),
	(
		pred_info_is_imported(PredInfo)
	->
		DepGraph1 = DepGraph0
	;
		pred_info_procids(PredInfo, ProcIds),
		dependency_graph__add_proc_arcs(ProcIds, PredId, ModuleInfo,
			DepGraph0, DepGraph1)
	),
	dependency_graph__add_pred_arcs(PredIds, ModuleInfo, DepGraph1, DepGraph).

:- pred dependency_graph__add_proc_arcs(list(proc_id), pred_id, module_info,
			dependency_graph, dependency_graph).
:- mode dependency_graph__add_proc_arcs(in, in, in, in, out) is det.

dependency_graph__add_proc_arcs([], _PredId, _ModuleInfo, DepGraph, DepGraph).
dependency_graph__add_proc_arcs([ProcId | ProcIds], PredId, ModuleInfo,
						DepGraph0, DepGraph) :-
	module_info_preds(ModuleInfo, PredTable0),
	map__lookup(PredTable0, PredId, PredInfo0),
	pred_info_procedures(PredInfo0, ProcTable0),
	map__lookup(ProcTable0, ProcId, ProcInfo0),

	proc_info_goal(ProcInfo0, Goal),

	dependency_graph__add_arcs_in_goal(Goal, PredId - ProcId,
					DepGraph0, DepGraph1),

	dependency_graph__add_proc_arcs(ProcIds, PredId, ModuleInfo,
						DepGraph1, DepGraph).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

% The call_info structure (map(var, lval)) is threaded through the traversal
% of the goal. The liveness information is computed from the liveness
% delta annotations.

:- pred dependency_graph__add_arcs_in_goal(hlds__goal, pred_proc_id,
					dependency_graph, dependency_graph).
:- mode dependency_graph__add_arcs_in_goal(in, in, in, out) is det.

dependency_graph__add_arcs_in_goal(Goal - _GoalInfo, PPId, 
					DepGraph0, DepGraph) :-
	dependency_graph__add_arcs_in_goal_2(Goal, PPId, DepGraph0, DepGraph).

%-----------------------------------------------------------------------------%
	% Here we process each of the different sorts of goals.
	% `Liveness' is the set of live variables, i.e. vars which
	% have been referenced and will be referenced again.

:- pred dependency_graph__add_arcs_in_goal_2(hlds__goal_expr, pred_proc_id,
					dependency_graph, dependency_graph).
:- mode dependency_graph__add_arcs_in_goal_2(in, in, in, out) is det.

dependency_graph__add_arcs_in_goal_2(conj(Goals), Caller, 
					DepGraph0, DepGraph) :-
	dependency_graph__add_arcs_in_list(Goals, Caller, DepGraph0, DepGraph).

dependency_graph__add_arcs_in_goal_2(disj(Goals), Caller, 
					DepGraph0, DepGraph) :-
	dependency_graph__add_arcs_in_list(Goals, Caller, DepGraph0, DepGraph).

dependency_graph__add_arcs_in_goal_2(switch(_Var, _Det, Cases),
					Caller, DepGraph0, DepGraph) :-
	dependency_graph__add_arcs_in_cases(Cases, Caller, DepGraph0, DepGraph).

dependency_graph__add_arcs_in_goal_2(if_then_else(_Vars, Cond, Then, Else),
			Caller, DepGraph0, DepGraph) :-
	dependency_graph__add_arcs_in_goal(Cond, Caller, DepGraph0, DepGraph1),
	dependency_graph__add_arcs_in_goal(Then, Caller, DepGraph1, DepGraph2),
	dependency_graph__add_arcs_in_goal(Else, Caller, DepGraph2, DepGraph).

dependency_graph__add_arcs_in_goal_2(not(Goal), Caller, DepGraph0, DepGraph) :-
	dependency_graph__add_arcs_in_goal(Goal, Caller, DepGraph0, DepGraph).

dependency_graph__add_arcs_in_goal_2(some(_Vars, Goal), Caller, 
					DepGraph0, DepGraph) :-
	dependency_graph__add_arcs_in_goal(Goal, Caller, DepGraph0, DepGraph).

dependency_graph__add_arcs_in_goal_2(call(PredId, ProcId, _, Builtin, _, _, _),
			Caller, DepGraph0, DepGraph) :-
	(
		is_builtin__is_inline(Builtin)
	->
		DepGraph1 = DepGraph0
	;
		Callee = PredId - ProcId,
		relation__add(DepGraph0, Caller, Callee, DepGraph1)
	),
	DepGraph1 = DepGraph.

dependency_graph__add_arcs_in_goal_2(unify(_,_,_,Unify,_), Caller,
				DepGraph0, DepGraph) :-
	( Unify = assign(_, _),
	    DepGraph0 = DepGraph
	; Unify = simple_test(_, _),
	    DepGraph0 = DepGraph
	; Unify = construct(_, Cons, _, _),
	    dependency_graph__add_arcs_in_cons(Cons, Caller,
				DepGraph0, DepGraph)
	; Unify = deconstruct(_, Cons, _, _, _),
	    dependency_graph__add_arcs_in_cons(Cons, Caller,
				DepGraph0, DepGraph)
	; Unify = complicated_unify(_, _, _),
	    DepGraph0 = DepGraph
	).

%-----------------------------------------------------------------------------%

:- pred dependency_graph__add_arcs_in_list(list(hlds__goal), pred_proc_id,
			dependency_graph, dependency_graph).
:- mode dependency_graph__add_arcs_in_list(in, in, in, out) is det.

dependency_graph__add_arcs_in_list([], _Caller, DepGraph, DepGraph).
dependency_graph__add_arcs_in_list([Goal|Goals], Caller, DepGraph0, DepGraph) :-
	dependency_graph__add_arcs_in_goal(Goal, Caller, DepGraph0, DepGraph1),
	dependency_graph__add_arcs_in_list(Goals, Caller, DepGraph1, DepGraph).

%-----------------------------------------------------------------------------%

:- pred dependency_graph__add_arcs_in_cases(list(case), pred_proc_id,
			dependency_graph, dependency_graph).
:- mode dependency_graph__add_arcs_in_cases(in, in, in, out) is det.

dependency_graph__add_arcs_in_cases([], _Caller, DepGraph, DepGraph).
dependency_graph__add_arcs_in_cases([case(Cons, Goal)|Goals], Caller,
						DepGraph0, DepGraph) :-
	dependency_graph__add_arcs_in_cons(Cons, Caller, DepGraph0, DepGraph1),
	dependency_graph__add_arcs_in_goal(Goal, Caller, DepGraph1, DepGraph2),
	dependency_graph__add_arcs_in_cases(Goals, Caller, DepGraph2, DepGraph).

%-----------------------------------------------------------------------------%

:- pred dependency_graph__add_arcs_in_cons(cons_id, pred_proc_id,
			dependency_graph, dependency_graph).
:- mode dependency_graph__add_arcs_in_cons(in, in, in, out) is det.
dependency_graph__add_arcs_in_cons(cons(_, _), _Caller,
				DepGraph, DepGraph).
dependency_graph__add_arcs_in_cons(int_const(_), _Caller,
				DepGraph, DepGraph).
dependency_graph__add_arcs_in_cons(string_const(_), _Caller,
				DepGraph, DepGraph).
dependency_graph__add_arcs_in_cons(float_const(_), _Caller,
				DepGraph, DepGraph).
dependency_graph__add_arcs_in_cons(pred_const(Pred, Proc), Caller,
				DepGraph0, DepGraph) :-
	Callee = Pred - Proc,
	relation__add(DepGraph0, Caller, Callee, DepGraph).
dependency_graph__add_arcs_in_cons(address_const(Pred, Proc), Caller,
				DepGraph0, DepGraph) :-
	Callee = Pred - Proc,
	relation__add(DepGraph0, Caller, Callee, DepGraph).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

dependency_graph__write_dependency_graph(ModuleInfo0, ModuleInfo) -->
	io__write_string("% Dependency graph\n"),
	{ module_info_ensure_dependency_info(ModuleInfo0, ModuleInfo) },
	{ module_info_dependency_info(ModuleInfo, DepInfo) },
	{ dependency_info__get_dependency_graph(DepInfo, DepGraph) },
	{ relation__effective_domain(DepGraph, DomSet) },
	{ set__to_sorted_list(DomSet, DomList) },
	dependency_graph__write_dependency_graph_2(DomList, DepGraph,
			ModuleInfo),
	io__write_string("\n\n% Dependency ordering\n"),
	{ dependency_info__get_dependency_ordering(DepInfo, DepOrd) },
	dependency_graph__write_dependency_ordering(DepOrd, ModuleInfo, 1).

:- pred dependency_graph__write_dependency_graph_2(list(pred_proc_id),
		dependency_graph, module_info, io__state, io__state).
:- mode dependency_graph__write_dependency_graph_2(in, in, in, di, uo) is det.

dependency_graph__write_dependency_graph_2([], _DepGraph, _ModuleInfo) --> [].
dependency_graph__write_dependency_graph_2([Node|Nodes], DepGraph, 
			ModuleInfo) -->
	{ relation__lookup_from(DepGraph, Node, SuccSet) },
	{ set__to_sorted_list(SuccSet, SuccList) },
	dependency_graph__write_dependency_graph_3(SuccList, Node, DepGraph, 
				ModuleInfo),
	dependency_graph__write_dependency_graph_2(Nodes, DepGraph, 
				ModuleInfo).

:- pred dependency_graph__write_dependency_graph_3(list(pred_proc_id),
		pred_proc_id, dependency_graph, module_info, 
		io__state, io__state).
:- mode dependency_graph__write_dependency_graph_3(in, in, in, in, 
				di, uo) is det.

dependency_graph__write_dependency_graph_3([], _Node, _DepGraph, 
				_ModuleInfo) -->
	[].
dependency_graph__write_dependency_graph_3([S|Ss], Node, DepGraph, 
				ModuleInfo) -->
	{ Node = PPredId - PProcId },
	{ S    = CPredId - CProcId },
	{ module_info_pred_proc_info(ModuleInfo, PPredId, PProcId,
						PPredInfo, PProcInfo) },
	{ module_info_pred_proc_info(ModuleInfo, CPredId, CProcId,
						CPredInfo, CProcInfo) },
	{ pred_info_name(PPredInfo, PName) },
	{ proc_info_declared_determinism(PProcInfo, PDet) },
	{ proc_info_argmodes(PProcInfo, PModes) },
	{ proc_info_context(PProcInfo, PContext) },

	{ pred_info_name(CPredInfo, CName) },
	{ proc_info_declared_determinism(CProcInfo, CDet) },
	{ proc_info_argmodes(CProcInfo, CModes) },
	{ proc_info_context(CProcInfo, CContext) },

	{ varset__init(ModeVarSet) },

	mercury_output_mode_subdecl(ModeVarSet, unqualified(PName),
						PModes, PDet, PContext),
	io__write_string(" -> "),
	mercury_output_mode_subdecl(ModeVarSet, unqualified(CName),
						CModes, CDet, CContext),
	io__write_string(".\n"),

	dependency_graph__write_dependency_graph_3(Ss, Node, DepGraph, 
					ModuleInfo).

%-----------------------------------------------------------------------------%

:- pred dependency_graph__write_dependency_ordering(list(list(pred_proc_id)),
				module_info, int, io__state, io__state).
:- mode dependency_graph__write_dependency_ordering(in, in, in, di, uo) is det.
dependency_graph__write_dependency_ordering([], _ModuleInfo, _N) -->
	io__write_string("\n").
dependency_graph__write_dependency_ordering([Clique | Rest], ModuleInfo, N) -->
	io__write_string("% Clique "),
	io__write_int(N),
	io__write_string("\n"),
	dependency_graph__write_clique(Clique, ModuleInfo),
	{ N1 is N + 1 },
	dependency_graph__write_dependency_ordering(Rest, ModuleInfo, N1).

:- pred dependency_graph__write_clique(list(pred_proc_id),
				module_info, io__state, io__state).
:- mode dependency_graph__write_clique(in, in, di, uo) is det.
dependency_graph__write_clique([], _ModuleInfo) --> [].
dependency_graph__write_clique([PredId - ProcId | Rest], ModuleInfo) -->
	{ module_info_pred_proc_info(ModuleInfo, PredId, ProcId,
						PredInfo, ProcInfo) },
	{ pred_info_name(PredInfo, Name) },
	{ proc_info_declared_determinism(ProcInfo, Det) },
	{ proc_info_argmodes(ProcInfo, Modes) },
	{ proc_info_context(ProcInfo, Context) },	
	{ varset__init(ModeVarSet) },

	io__write_string("% "),
	mercury_output_mode_subdecl(ModeVarSet, unqualified(Name),
						Modes, Det, Context),
	io__write_string("\n"),
	dependency_graph__write_clique(Rest, ModuleInfo).

%-----------------------------------------------------------------------------%

% dependency_graph__write_prof_dependency_graph:
%	Output's the static call graph of the current module in the form of
%		CallerLabel (\t) CalleeLabel
%
dependency_graph__write_prof_dependency_graph(ModuleInfo0, ModuleInfo) -->
	{ module_info_ensure_dependency_info(ModuleInfo0, ModuleInfo) },
	{ module_info_dependency_info(ModuleInfo, DepInfo) },
	{ dependency_info__get_dependency_graph(DepInfo, DepGraph) },
	{ relation__effective_domain(DepGraph, DomSet) },
	{ set__to_sorted_list(DomSet, DomList) },
	dependency_graph__write_prof_dependency_graph_2(DomList, DepGraph,
			ModuleInfo).

:- pred dependency_graph__write_prof_dependency_graph_2(list(pred_proc_id),
		dependency_graph, module_info, io__state, io__state).
:- mode dependency_graph__write_prof_dependency_graph_2(in, in, in, di, uo) 
		is det.

% dependency_graph__write_prof_dependency_graph_2:
% 	Scan's through list of caller's, then call's next predicate to get
%	callee's
dependency_graph__write_prof_dependency_graph_2([], _DepGraph, _ModuleInfo) --> [].
dependency_graph__write_prof_dependency_graph_2([Node|Nodes], DepGraph, 
			ModuleInfo) -->
	{ relation__lookup_from(DepGraph, Node, SuccSet) },
	{ set__to_sorted_list(SuccSet, SuccList) },
	dependency_graph__write_prof_dependency_graph_3(SuccList, Node, DepGraph, 
				ModuleInfo),
	dependency_graph__write_prof_dependency_graph_2(Nodes, DepGraph, 
				ModuleInfo).


% dependency_graph__write_prof_dependency_graph_3:
%	Process all the callee's of a node.
%	XXX We should only make the Caller label once and then pass it around.
:- pred dependency_graph__write_prof_dependency_graph_3(list(pred_proc_id),
		pred_proc_id, dependency_graph, module_info, 
		io__state, io__state).
:- mode dependency_graph__write_prof_dependency_graph_3(in, in, in, in, 
				di, uo) is det.

dependency_graph__write_prof_dependency_graph_3([], _Node, _DepGraph, 
				_ModuleInfo) -->
	[].
dependency_graph__write_prof_dependency_graph_3([S|Ss], Node, DepGraph, 
				ModuleInfo) -->
	{ Node = PPredId - PProcId }, % Caller
	{ S    = CPredId - CProcId }, % Callee
	dependency_graph__output_label(ModuleInfo, PPredId, PProcId, 
			CPredId, CProcId),
	io__write_string("\t"),
	dependency_graph__output_label(ModuleInfo, CPredId, CProcId,
			CPredId, CProcId),
	io__write_string("\n"),
	dependency_graph__write_prof_dependency_graph_3(Ss, Node, DepGraph, 
					ModuleInfo).

%-----------------------------------------------------------------------------%


% dependency_graph__output_label:
%	Prints out the label corresponding to PredId and ProcId.  
%	CurPredId and CurProcId refer to the parent caller of the current 
%	predicate(Hack needed so that we can call code_util to build the 
%	correct type of label).
%
:- pred dependency_graph__output_label(module_info, pred_id, proc_id, pred_id,
                        proc_id, io__state, io__state).
:- mode dependency_graph__output_label(in, in, in, in, in, di, uo) is det.

dependency_graph__output_label(ModuleInfo, PredId, ProcId, CurPredId, 
								CurProcId) -->
	dependency_graph__make_entry_label(ModuleInfo, PredId, ProcId,
                        CurPredId, CurProcId, Address),
        (
                { Address = label(local(ProcLabela)) }
        ->
                output_label(local(ProcLabela))
        ;
                { Address = imported(ProcLabelb) }
        ->
                output_proc_label(ProcLabelb)
        ;
                { Address = label(exported(ProcLabelc)) }
        ->
                output_label(exported(ProcLabelc))
        ;
                { error("dependency_graph__output_label: Label not of type local or imported or exported\n") }
        ).


%-----------------------------------------------------------------------------%

% dependency_graph__make_entry_label:
%	Just shunts off it's duties to code_info__make_entry_label_2
%
:- pred dependency_graph__make_entry_label(module_info, pred_id, proc_id, 
			pred_id, proc_id, code_addr, io__state, io__state).
:- mode dependency_graph__make_entry_label(in, in, in, in, in, out, di, uo)
			is det.

dependency_graph__make_entry_label(ModuleInfo, PredId, ProcId, 
					CurPredId, CurProcId, PredAddress) -->
        globals__io_lookup_int_option(procs_per_c_function, ProcsPerFunc),
	{ code_info__make_entry_label_2(ModuleInfo, ProcsPerFunc, PredId,
				ProcId, CurPredId, CurProcId, PredAddress) }.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
