/*
** Copyright (C) 1994-2003 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** mercury_wrapper.h - defines the interface to mercury_wrapper.c.
** See mercury_wrapper.c for documentation.
*/

#ifndef	MERCURY_WRAPPER_H
#define	MERCURY_WRAPPER_H

#include "mercury_regs.h"		/* needs to come first */
#include <stddef.h>			/* for `size_t' */
#include "mercury_std.h"		/* for `MR_bool' */
#include "mercury_stack_layout.h"	/* for `MR_Label_Layout' etc */
#include "mercury_trace_base.h"		/* for `MR_trace_port' */
#include "mercury_stacks.h"		/* for `MR_{Cut,Generator}StackFrame' */
#include "mercury_type_info.h"		/* for `MR_TypeCtorInfo' */
#include "mercury_library_types.h"	/* for `MercuryFilePtr' */
#include <stdio.h>			/* for `FILE' */

/*
** mercury_runtime_init() does some stuff to initialize the garbage collector
** and the Mercury engine's data areas, and then calls io__init_state/2
** in the Mercury library to initialize the io__state.
*/
extern	void	mercury_runtime_init(int argc, char **argv);

/*
** mercury_runtime_main() basically just calls main/2,
** with a bit of debugging scaffolding around it.
*/
extern	void	mercury_runtime_main(void);

/*
** mercury_runtime_terminate() does any necessary cleanup,
** and then returns mercury_exit_status.
*/
extern	int	mercury_runtime_terminate(void);

/*
** MR_load_aditi_rl_code() uploads all the Aditi-RL code for
** the program to a database specified by connection. The code
** will be stored in the context of the given transaction.
** The return value is described by aditi2/src/AditiStatus/AditiStatus.h
** in the Aditi sources.
** Aborts if the executable was not compiled for Aditi execution. 
** The return value is an Aditi error code.
** We use MR_Box here rather than the actual argument types to
** avoid dependencies on the Aditi headers.
*/
extern	MR_Box	MR_load_aditi_rl_code(MR_Box connection, MR_Box transaction);

/*
** MR_init_conservative_GC() initializes the conservative collector.
** The conservative collector can be either the Boehm et al collector,
** or the MPS (Memory Pool System) kit collector.  This function is normally
** called from mercury_runtime_init().
*/
#ifdef MR_CONSERVATIVE_GC
  extern void	MR_init_conservative_GC(void);
#endif

/*
** The following global variables are set by mercury_init() on startup.
** The entry points are set based on the options to mkinit.c.
** The address_of_foo pointers are set to the address of
** the corresponding foo.
*/

#ifdef MR_HIGHLEVEL_CODE
extern	void MR_CALL	(*MR_program_entry_point)(void);
			/* normally main_2_p_0 */
#else
extern	MR_Code 	*MR_program_entry_point;
			/* normally mercury__main_2_0; */
#endif

extern const char *	MR_runtime_flags;

extern	void		(*MR_library_initializer)(void);
extern	void		(*MR_library_finalizer)(void);

extern	void		(*MR_io_stderr_stream)(MercuryFilePtr *);
extern	void		(*MR_io_stdout_stream)(MercuryFilePtr *);
extern	void		(*MR_io_stdin_stream)(MercuryFilePtr *);
extern	void		(*MR_io_print_to_cur_stream)(MR_Word, MR_Word);
extern	void		(*MR_io_print_to_stream)(MR_Word, MercuryFilePtr,
				MR_Word);

extern	void		(*MR_address_of_mercury_init_io)(void);
extern	void		(*MR_address_of_init_modules)(void);
extern	void		(*MR_address_of_init_modules_type_tables)(void);
extern	void		(*MR_address_of_init_modules_debugger)(void);
#ifdef	MR_DEEP_PROFILING
extern	void		(*MR_address_of_write_out_proc_statics)(FILE *fp);
#endif

extern	MR_TypeCtorInfo	MR_type_ctor_info_for_univ;
extern	MR_TypeInfo	MR_type_info_for_type_info;
extern	MR_TypeInfo	MR_type_info_for_list_of_univ;
extern	MR_TypeInfo	MR_type_info_for_list_of_int;
extern	MR_TypeInfo	MR_type_info_for_list_of_char;
extern	MR_TypeInfo	MR_type_info_for_list_of_string;
extern	MR_TypeInfo	MR_type_info_for_list_of_type_info;

#ifdef MR_CONSERVATIVE_GC
extern	void		(*MR_address_of_init_gc)(void);
#endif

extern	MR_Box		(*MR_address_of_do_load_aditi_rl_code)(MR_Box, MR_Box);

/*
** MR_trace_getline(const char *, FILE *, FILE *) and
** MR_trace_get_command(const char *, FILE *, FILE *) are defined in
** trace/mercury_trace_internal.c but are called in browser/util.m.  As
** we cannot do direct calls from browser/ to trace/, we do indirect 
** calls via the following pointers.
*/

extern	char *		(*MR_address_of_trace_getline)(const char *,
				FILE *, FILE *);
extern	char *		(*MR_address_of_trace_get_command)(const char *,
				FILE *, FILE *);

/*
** MR_trace_browse_all_on_level() is defined in trace/mercury_trace_vars.c
** but may be called from runtime/mercury_stack_trace.c. As we can not do
** direct calls from runtime/ to trace/, we do an indirect call via the
** function pointer MR_address_of_trace_browse_all_on_level.
*/

extern	const char *	(*MR_address_of_trace_browse_all_on_level)(FILE *,
				const MR_Label_Layout *, MR_Word *, MR_Word *,
				int, MR_bool);

/*
** MR_trace_init_external() and MR_trace_final_external() are defined 
** in trace/mercury_trace_external.c but are called in
** runtime/mercury_trace_base.c. As we can not do direct calls from
** runtime/ to trace/, we do an indirect call via a function
** pointer MR_address_of_trace_init_external.
*/

extern	void		(*MR_address_of_trace_init_external)(void);
extern	void		(*MR_address_of_trace_final_external)(void);

/*
** MR_trace_func_ptr is set to either MR_trace_real (trace/mercury_trace.c),
** or MR_trace_fake (runtime/mercury_trace_base.c),
** depending on whether tracing was enabled when creating the _init.c
** file.  It is also temporarily set to MR_trace_interrupt by
** MR_trace_interrupt_handler if tracing was enabled and the
** process receives a SIGINT signal.
** It is called from MR_trace (runtime/mercury_trace_base.c).
**
** Since it is set from a signal handler, it must be declared `volatile'.
*/

extern	MR_Code		*(*volatile MR_trace_func_ptr)(
				const MR_Label_Layout *);

/*
** If the init file was built with tracing enabled, then
** MR_address_of_trace_interrupt_handler points to
** MR_trace_interrupt_handler, otherwise it is NULL.
*/
extern	void		(*MR_address_of_trace_interrupt_handler)(void);

/*
** If the init file was built with tracing enabled, then
** MR_register_module_layout points to MR_register_module_layout_real,
** otherwise it is NULL.
*/
extern	void		(*MR_register_module_layout)(const MR_Module_Layout *);

extern	void		MR_do_init_modules(void);
extern	void		MR_do_init_modules_type_tables(void);
extern	void		MR_do_init_modules_debugger(void);

extern	const char	*MR_progname;
extern	int		mercury_argc;
extern	char		**mercury_argv;
extern	int		mercury_exit_status;

/* sizes of the data areas, *including* the red zone size */
extern	size_t		MR_heap_size;
extern	size_t		MR_detstack_size;
extern	size_t		MR_nondstack_size;
extern	size_t		MR_solutions_heap_size;
extern	size_t		MR_trail_size;
extern	size_t		MR_global_heap_size;
extern	size_t		MR_debug_heap_size;
extern	size_t		MR_genstack_size;
extern	size_t		MR_cutstack_size;
extern	size_t		MR_pnegstack_size;

/* sizes of the red zones */
extern	size_t		MR_heap_zone_size;
extern	size_t		MR_detstack_zone_size;
extern	size_t		MR_nondstack_zone_size;
extern	size_t		MR_solutions_heap_zone_size;
extern	size_t		MR_trail_zone_size;
extern	size_t		MR_global_heap_zone_size;
extern	size_t		MR_debug_heap_zone_size;
extern	size_t		MR_genstack_zone_size;
extern	size_t		MR_cutstack_zone_size;
extern	size_t		MR_pnegstack_zone_size;

/* heap margin for MLDS->C accurate GC (documented in mercury_wrapper.c) */
extern	size_t		MR_heap_margin_size;

/* heap expansion factor for accurate GC (see mercury_accurate_gc.c) */
extern  double		MR_heap_expansion_factor;

/* file names for the mdb debugging streams */
extern	const char	*MR_mdb_in_filename;
extern	const char	*MR_mdb_out_filename;
extern	const char	*MR_mdb_err_filename;

/* should mdb be started in a window */
extern	MR_bool		MR_mdb_in_window;

/* use readline() in the debugger even if the input stream is not a tty */
extern	MR_bool		MR_force_readline;

/* size of the primary cache */
extern	size_t		MR_pcache_size;

/* low level debugging */
extern	MR_bool		MR_check_space;
extern	MR_Word		*MR_watch_addr;
extern	MR_CallSiteDynamic
			*MR_watch_csd_addr;
extern	MR_bool		MR_watch_csd_started;
extern	const char	*MR_watch_csd_start_name;

extern	unsigned long	MR_lld_cur_call;
extern	MR_bool		MR_lld_print_enabled;
extern	MR_bool		MR_lld_print_name_enabled;
extern	MR_bool		MR_lld_print_csd_enabled;
extern	MR_bool		MR_lld_print_region_enabled;

extern	const char	*MR_lld_start_name;
extern	unsigned	MR_lld_start_block;
extern	unsigned long	MR_lld_start_until;
extern	unsigned long	MR_lld_csd_until;
extern	unsigned long	MR_lld_print_min;
extern	unsigned long	MR_lld_print_max;
extern	char		*MR_lld_print_more_min_max;

/* timing */
extern	int		MR_time_at_start;
extern	int		MR_time_at_last_stat;

/* time profiling */
enum MR_TimeProfileMethod {
	MR_profile_real_time,			/* i.e. ITIMER_REAL */
	MR_profile_user_time,			/* i.e. ITIMER_VIRTUAL */
	MR_profile_user_plus_system_time	/* i.e. ITIMER_PROF */
};
extern	enum MR_TimeProfileMethod
			MR_time_profile_method;

extern	MR_bool		MR_profiling;
extern	MR_bool		MR_print_deep_profiling_statistics;

#ifdef  MR_TYPE_CTOR_STATS

typedef	struct MR_TypeStat_Struct	MR_TypeStat;

extern	MR_TypeStat	MR_type_stat_mer_unify;
extern	MR_TypeStat	MR_type_stat_c_unify;
extern	MR_TypeStat	MR_type_stat_mer_compare;
extern	MR_TypeStat	MR_type_stat_c_compare;

extern	void		MR_register_type_ctor_stat(MR_TypeStat *type_stat,
				MR_TypeCtorInfo type_ctor_info);

#endif

/* This is used by compiler/mlds_to_gcc.m. */
const char	*MR_make_argv(const char *, char **, char ***, int *);

void		MR_setup_call_intervals(char **more_str_ptr,
			unsigned long *min_ptr, unsigned long *max_ptr);

#endif /* not MERCURY_WRAPPER_H */
