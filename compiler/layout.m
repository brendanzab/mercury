%-----------------------------------------------------------------------------%
% Copyright (C) 2001-2002 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% Definitions of Mercury types for representing layout structures within
% the compiler. Layout structures are generated by the compiler, and are
% used by the parts of the runtime system that need to look at the stacks
% (and sometimes the registers) and make sense of their contents. The parts
% of the runtime system that need to do this include exception handling,
% the debugger, the deep profiler and (eventually) the accurate garbage
% collector.
%
% When output by layout_out.m, values of most these types will correspond
% to the C types defined in runtime/mercury_stack_layout.h or
% runtime/mercury_deep_profiling.h; the documentation of those types
% can be found there. The names of the C types are listed next to the
% function symbol whose arguments represent their contents.
%
% The code to generate values of these types is in stack_layout.m and
% deep_profiling.m.
%
% This module should be, but as yet isn't, independent of whether we are
% compiling to LLDS or MLDS.
%
% Author: zs.

%-----------------------------------------------------------------------------%

:- module ll_backend__layout.

:- interface.

:- import_module parse_tree__prog_data, libs__trace_params, ll_backend__llds.
:- import_module backend_libs__rtti, hlds__hlds_goal.
:- import_module bool, std_util, list, assoc_list.

:- type layout_data
	--->	label_layout_data(		% defines MR_Label_Layout
			label			:: label,
			proc_layout_name	:: layout_name,
			maybe_port		:: maybe(trace_port),
			maybe_is_hidden		:: maybe(bool),
			maybe_goal_path		:: maybe(int), % offset
			maybe_var_info		:: maybe(label_var_info)
		)
	;	proc_layout_data(		% defines MR_Proc_Layout
			proc_label,
			proc_layout_stack_traversal,
			maybe_proc_id_and_exec_trace
		)
	;	module_layout_data(		% defines MR_Module_Layout
			module_name		:: module_name,
			string_table_size	:: int,
			string_table		:: string,
			proc_layout_names	:: list(layout_name),
			file_layouts		:: list(file_layout_data),
			trace_level		:: trace_level,
			suppressed_events	:: int
		)
	;	closure_proc_id_data(		% defines MR_Closure_Id
			caller_proc_label	:: proc_label,
			caller_closure_seq_no	:: int,
			closure_proc_label	:: proc_label,
			closure_module_name	:: module_name,
			closure_file_name	:: string,
			closure_line_number	:: int,
			closure_goal_path	:: string
		)
	;	proc_static_data(		% defines MR_ProcStatic
			proc_static_id		:: rtti_proc_label,
			proc_static_file_name	:: string,
			proc_static_line_number :: int,
			proc_is_in_interface	:: bool,
			call_site_statics	:: list(call_site_static_data)
		)
	;	table_io_decl_data(
			table_io_decl_proc_ptr	:: rtti_proc_label,
			table_io_decl_kind	:: proc_layout_kind,
			table_io_decl_num_ptis	:: int,
			table_io_decl_ptis	:: rval,
						% pseudo-typeinfos for headvars
			table_io_decl_type_params :: rval
		).

:- type call_site_static_data			% defines MR_CallSiteStatic
	--->	normal_call(
			normal_callee		:: rtti_proc_label,
			normal_type_subst	:: string,
			normal_file_name	:: string,
			normal_line_number	:: int,
			normal_goal_path	:: goal_path
		)
	;	special_call(
			special_file_name	:: string,
			special_line_number	:: int,
			special_goal_path	:: goal_path
		)
	;	higher_order_call(
			higher_order_file_name	:: string,
			ho_line_number		:: int,
			ho_goal_path		:: goal_path
		)
	;	method_call(
			method_file_name	:: string,
			method_line_number	:: int,
			method_goal_path	:: goal_path
		)
	;	callback(
			callback_file_name	:: string,
			callback_line_number	:: int,
			callback_goal_path	:: goal_path
		).

:- type label_var_info
	--->	label_var_info(			% part of MR_Label_Layout
			encoded_var_count	:: int,
			locns_types		:: rval,
			var_nums		:: rval,
			type_params		:: rval
		).

:- type proc_layout_stack_traversal		% defines MR_Stack_Traversal
	--->	proc_layout_stack_traversal(
			entry_label		:: maybe(label),
						% The proc entry label; will be
						% `no' if we don't have static
						% code addresses.
			succip_slot		:: maybe(int),
			stack_slot_count	:: int,
			detism			:: determinism
		).

:- type maybe_proc_id_and_exec_trace
	--->	no_proc_id
	;	proc_id_only
	;	proc_id_and_exec_trace(proc_layout_exec_trace).

:- type proc_layout_exec_trace			% defines MR_Exec_Trace
	--->	proc_layout_exec_trace(
			call_label_layout	:: layout_name,
			proc_body		:: maybe(rval),
			maybe_table_io_decl	:: maybe(layout_name),
			head_var_nums		:: list(int),
						% The variable numbers of the
						% head variables, including the
						% ones added by the compiler,
						% in order. The length of the
						% list must be the same as the
						% procedure's arity.
			var_names		:: list(int),
						% Each variable name is an
						% offset into the module's
						% string table.
			max_var_num		:: int,
			max_r_num		:: int,
			maybe_from_full_slot	:: maybe(int),
			maybe_io_seq_slot	:: maybe(int),
			maybe_trail_slot	:: maybe(int),
			maybe_maxfr_slot	:: maybe(int),
			eval_method		:: eval_method,
			maybe_call_table_slot	:: maybe(int)
		).

:- type file_layout_data
	--->	file_layout_data(
			file_name		:: string,
			line_no_label_list	:: assoc_list(int, layout_name)
		).

%-----------------------------------------------------------------------------%

:- type layout_name
	--->	label_layout(label, label_vars)
	;	proc_layout(proc_label, proc_layout_kind)
		% A proc layout structure for stack tracing, accurate gc
		% and/or execution tracing.
	;	proc_layout_head_var_nums(proc_label)
		% A vector of variable numbers, containing the numbers of the
		% procedure's head variables, including the ones generated by
		% the compiler.
	;	proc_layout_var_names(proc_label)
		% A vector of variable names (represented as offsets into
		% the string table) for a procedure layout structure.
	;	table_io_decl(rtti_proc_label)
	;	closure_proc_id(proc_label, int, proc_label)
	;	file_layout(module_name, int)
	;	file_layout_line_number_vector(module_name, int)
	;	file_layout_label_layout_vector(module_name, int)
	;	module_layout_string_table(module_name)
	;	module_layout_file_vector(module_name)
	;	module_layout_proc_vector(module_name)
	;	module_layout(module_name)
	;	proc_static(rtti_proc_label)
	;	proc_static_call_sites(rtti_proc_label).

:- type label_vars
	--->	label_has_var_info
	;	label_has_no_var_info.

:- type proc_layout_kind
	--->	proc_layout_traversal
	;	proc_layout_proc_id(proc_layout_user_or_compiler)
	;	proc_layout_exec_trace(proc_layout_user_or_compiler).

:- type proc_layout_user_or_compiler
	--->	user
	;	compiler.

%-----------------------------------------------------------------------------%
