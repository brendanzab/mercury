/*---------------------------------------------------------------------------*/

/*
** Copyright (C) 1995-1999 The University of Melbourne.
** This file may only be copied under the terms of the GNU General
** Public License - see the file COPYING in the Mercury distribution.
*/

/*
** File: mkinit.c
** Main authors: zs, fjh
**
** Given a list of .c or .init files on the command line, this program
** produces the initialization file (usually called *_init.c) on stdout.
** The initialization file is a small C program that calls the initialization
** functions for all the modules in a Mercury program.
*/

/*---------------------------------------------------------------------------*/

#include	<stdio.h>
#include	<stdlib.h>
#include	<string.h>
#include	<ctype.h>
#include	<errno.h>
#include	<unistd.h>
#include	<sys/stat.h>
#include	"getopt.h"
#include	"mercury_conf.h"
#include	"mercury_std.h"

/* --- adjustable limits --- */
#define	MAXCALLS	40	/* maximum number of calls per function */
#define	MAXLINE		256	/* maximum number of characters per line */
				/* (characters after this limit are ignored) */

/* --- used to collect a list of strings, e.g. Aditi data constant names --- */

typedef struct String_List_struct {
		char *data;
		struct String_List_struct *next;
	} String_List;

/* --- global variables --- */

static const char *progname = NULL;

/* options and arguments, set by parse_options() */
static const char *entry_point = "mercury__main_2_0";
static int maxcalls = MAXCALLS;
static int num_files;
static char **files;
static bool output_main_func = TRUE;
static bool c_files_contain_extra_inits = FALSE;
static bool aditi = FALSE;
static bool need_initialization_code = FALSE;
static bool need_tracing = FALSE;

static int num_modules = 0;
static int num_errors = 0;

	/* List of directories to search for init files */
static String_List *init_file_dirs = NULL;

	/* Pointer to tail of the init_file_dirs list */
static String_List **init_file_dirs_tail = &init_file_dirs;

	/* List of names of Aditi-RL code constants. */
static String_List *rl_data = NULL;

/* --- code fragments to put in the output file --- */
static const char header1[] = 
	"/*\n"
	"** This code automatically generated by mkinit - do not edit.\n"
	"**\n"
	"** Input files:\n"
	"**\n"
	;

static const char header2[] = 
	"*/\n"
	"\n"
	"#include <stddef.h>\n"
	"#include \"mercury_init.h\"\n"
	"#include \"mercury_grade.h\"\n"
	"\n"
	"/*\n"
	"** Work around a bug in the Solaris 2.X (X<=4) linker;\n"
	"** on these machines, init_gc must be statically linked.\n"
	"*/\n"
	"\n"
	"#ifdef CONSERVATIVE_GC\n"
	"static void init_gc(void)\n"
	"{\n"
	"	GC_INIT();\n"
	"}\n"
	"#endif\n"
	"\n"
	;

static const char mercury_funcs[] =
	"\n"
	"#define MR_TRACE_ENABLED %d\n"
	"\n"
	"Declare_entry(%s);\n"
	"\n"
	"#ifdef CONSERVATIVE_GC\n"
	"extern char *GC_stackbottom;\n"
	"#endif\n"
	"\n"
	"#if defined(USE_DLLS)\n"
	"  #if !defined(libmer_DEFINE_DLL)\n"
	"       #define libmer_impure_ptr \\\n"
	"		(*__imp_libmer_impure_ptr)\n"
	"	extern void *libmer_impure_ptr;\n"
	"  #endif\n"
	"  #if !defined(libmercury_DEFINE_DLL)\n"
	"       #define libmercury_impure_ptr \\\n"
	"		(*__imp_libmercury_impure_ptr)\n"
	"	extern void *libmercury_impure_ptr;\n"
	"  #endif\n"
	"#endif\n"
	"\n"
	"void\n"
	"mercury_init(int argc, char **argv, char *stackbottom)\n"
	"{\n"
	"\n"
	"#ifdef CONSERVATIVE_GC\n"
	"	/*\n"
	"	** Explicitly register the bottom of the stack, so that the\n"
	"	** GC knows where it starts.  This is necessary for AIX 4.1\n"
	"	** on RS/6000, and for gnu-win32 on Windows 95 or NT.\n"
	"	** it may also be helpful on other systems.\n"
	"	*/\n"
	"	GC_stackbottom = stackbottom;\n"
	"#endif\n"
	"\n"
	"/*\n"
	"** If we're using DLLs on gnu-win32, then we need\n"
	"** to take special steps to initialize _impure_ptr\n"
	"** for the DLLs.\n"
	"*/\n"
	"#if defined(USE_DLLS)\n"
	"  #if !defined(libmer_DEFINE_DLL)\n"
	"	libmer_impure_ptr = _impure_ptr;\n"
	"  #endif\n"
	"  #if !defined(libmercury_DEFINE_DLL)\n"
	"	libmercury_impure_ptr = _impure_ptr;\n"
	"  #endif\n"
	"#endif\n"
	"\n"
	"	address_of_mercury_init_io = mercury_init_io;\n"
	"	address_of_init_modules = init_modules;\n"
	"#ifdef CONSERVATIVE_GC\n"
	"	address_of_init_gc = init_gc;\n"
	"#endif\n"
	"	MR_library_initializer = ML_io_init_state;\n"
	"	MR_library_finalizer = ML_io_finalize_state;\n"
	"	MR_io_stdin_stream = ML_io_stdin_stream;\n"
	"	MR_io_stdout_stream = ML_io_stdout_stream;\n"
	"	MR_io_stderr_stream = ML_io_stderr_stream;\n"
	"	MR_io_print_to_cur_stream = ML_io_print_to_cur_stream;\n"
	"	MR_io_print_to_stream = ML_io_print_to_stream;\n"
	"#if MR_TRACE_ENABLED\n"
	"	MR_address_of_trace_getline = MR_trace_getline;\n"
	"#else\n"
	"	MR_address_of_trace_getline = NULL;\n"
	"#endif\n"
	"#ifdef MR_USE_EXTERNAL_DEBUGGER\n"
	"  #if MR_TRACE_ENABLED\n"
	"	MR_address_of_trace_init_external = MR_trace_init_external;\n"
	"	MR_address_of_trace_final_external = MR_trace_final_external;\n"
	"  #else\n"
	"	MR_address_of_trace_init_external = NULL;\n"
	"	MR_address_of_trace_final_external = NULL;\n"
	"  #endif\n"
	"#endif\n"
	"#if MR_TRACE_ENABLED\n"
	"	MR_trace_func_ptr = MR_trace_real;\n"
	"	MR_address_of_trace_interrupt_handler =\n"
	"		MR_trace_interrupt_handler;\n"
	"	MR_register_module_layout = MR_register_module_layout_real;\n"
	"#else\n"
	"	MR_trace_func_ptr = MR_trace_fake;\n"
	"	MR_address_of_trace_interrupt_handler = NULL;"
	"	MR_register_module_layout = NULL;\n"
	"#endif\n"
	"#if defined(USE_GCC_NONLOCAL_GOTOS) && !defined(USE_ASM_LABELS)\n"
	"	do_init_modules();\n"
	"#endif\n"
	"	program_entry_point = ENTRY(%s);\n"
	"\n"
	"	mercury_runtime_init(argc, argv);\n"
	"	return;\n"
	"}\n"
	"\n"
	"void\n"
	"mercury_call_main(void)\n"
	"{\n"
	"	mercury_runtime_main();\n"
	"}\n"
	"\n"
	"int\n"
	"mercury_terminate(void)\n"
	"{\n"
	"	return mercury_runtime_terminate();\n"
	"}\n"
	"\n"
	"int\n"
	"mercury_main(int argc, char **argv)\n"
	"{\n"
	"	char dummy;\n"
	"	mercury_init(argc, argv, &dummy);\n"
	"	mercury_call_main();\n"
	"	return mercury_terminate();\n"
	"}\n"
	"\n"
	"/* ensure that everything gets compiled in the same grade */\n"
	"static const void *const MR_grade = &MR_GRADE_VAR;\n"
	;

static const char main_func[] =
	"\n"
	"int\n"
	"main(int argc, char **argv)\n"
	"{\n"
	"	return mercury_main(argc, argv);\n"
	"}\n"
	;

static const char aditi_rl_data_str[] = "mercury__aditi_rl_data__";

static const char if_need_to_init[] = 
	"#if defined(MR_MAY_NEED_INITIALIZATION)\n\n"
	;

/* --- function prototypes --- */
static	void parse_options(int argc, char *argv[]);
static	void usage(void);
static	void do_path_search(void);
static	char *find_init_file(const char *basename);
static	bool file_exists(const char *filename);
static	void output_headers(void);
static	void output_sub_init_functions(void);
static	void output_main_init_function(void);
static	void output_aditi_load_function(void);
static	void output_main(void);
static	void process_file(const char *filename);
static	void process_c_file(const char *filename);
static	void process_init_file(const char *filename);
static	void output_init_function(const char *func_name);
static	void add_rl_data(char *data);
static	int getline(FILE *file, char *line, int line_max);
static	void *checked_malloc(size_t size);

/*---------------------------------------------------------------------------*/

#ifndef HAVE_STRERROR

/*
** Apparently SunOS 4.1.3 doesn't have strerror()
**	(!%^&!^% non-ANSI systems, grumble...)
**
** This code is duplicated in runtime/mercury_prof.c.
*/

extern int sys_nerr;
extern char *sys_errlist[];

char *
strerror(int errnum)
{
	if (errnum >= 0 && errnum < sys_nerr && sys_errlist[errnum] != NULL) {
		return sys_errlist[errnum];
	} else {
		static char buf[30];
		sprintf(buf, "Error %d", errnum);
		return buf;
	}
}

#endif

/*---------------------------------------------------------------------------*/

int 
main(int argc, char **argv)
{
	progname = argv[0];

	parse_options(argc, argv);

	do_path_search();

	output_headers();
	output_sub_init_functions();
	output_main_init_function();
	
	if (aditi) {
		output_aditi_load_function();
	}

	output_main();

	if (num_errors > 0) {
		fputs("/* Force syntax error, since there were */\n", stdout);
		fputs("/* errors in the generation of this file */\n", stdout);
		fputs("#error \"You need to remake this file\"\n", stdout);
		return EXIT_FAILURE;
	}

	return EXIT_SUCCESS;
}

/*---------------------------------------------------------------------------*/

static void 
parse_options(int argc, char *argv[])
{
	int c;
	String_List *tmp_slist;
	while ((c = getopt(argc, argv, "ac:iI:ltw:x")) != EOF) {
		switch (c) {
		case 'a':
			aditi = TRUE;
			break;

		case 'c':
			if (sscanf(optarg, "%d", &maxcalls) != 1)
				usage();
			break;

		case 'i':
			need_initialization_code = TRUE;
			break;

		case 'I':
			/*
			** Add the directory name to the end of the
			** search path for `.init' files.
			*/
			tmp_slist = (String_List *)
					checked_malloc(sizeof(String_List));
			tmp_slist->next = NULL;
			tmp_slist->data = (char *)
					checked_malloc(strlen(optarg) + 1);
			strcpy(tmp_slist->data, optarg);
			*init_file_dirs_tail = tmp_slist;
			init_file_dirs_tail = &tmp_slist->next;
			break;

		case 'l':
			output_main_func = FALSE;
			break;

		case 't':
			need_tracing = TRUE;
			need_initialization_code = TRUE;
			break;

		case 'w':
			entry_point = optarg;
			break;

		case 'x':
			c_files_contain_extra_inits = TRUE;
			break;

		default:
			usage();
		}
	}
	num_files = argc - optind;
	if (num_files <= 0)
		usage();
	files = argv + optind;
}

static void 
usage(void)
{
	fprintf(stderr,
"Usage: mkinit [-a] [-c maxcalls] [-w entry] [-i] [-l] [-t] [-x] files...\n");
	exit(1);
}

/*---------------------------------------------------------------------------*/

	/*
	** Scan the list of files for ones not found in the current
	** directory, and replace them with their full path equivalent
	** if they are found in the list of search directories.
	*/
static void
do_path_search(void)
{
	int filenum;
	char *init_file;

	for (filenum = 0; filenum < num_files; filenum++) {
		init_file = find_init_file(files[filenum]);
		if (init_file != NULL)
			files[filenum] = init_file;
	}
}

	/*
	** Search the init file directory list to locate the file.
	** If the file is in the current directory or is not in any of the
	** search directories, then return NULL.  Otherwise return the full
	** path name to the file.
	** It is the caller's responsibility to free the returned buffer
	** holding the full path name when it is no longer needed.
	*/
static char *
find_init_file(const char *basename)
{
	char *filename;
	char *dirname;
	String_List *dir_ptr;
	int dirlen;
	int baselen;
	int len;

	if (file_exists(basename)) {
		/* File is in current directory, so no search required */
		return NULL;
	}

	baselen = strlen(basename);

	for (dir_ptr = init_file_dirs; dir_ptr != NULL;
			dir_ptr = dir_ptr->next)
	{
		dirname = dir_ptr->data;
		dirlen = strlen(dirname);
		len = dirlen + 1 + baselen;

		filename = (char *) checked_malloc(len + 1);
		strcpy(filename, dirname);
		filename[dirlen] = '/';
		strcpy(filename + dirlen + 1, basename);

		if (file_exists(filename))
			return filename;

		free(filename);
	}

	/* Did not find file */
	return NULL;
}

	/*
	** Check whether a file exists.
	** At some point in the future it may be worth making this
	** implementation more portable.
	*/
static bool
file_exists(const char *filename)
{
	struct stat buf;

	return (stat(filename, &buf) == 0);
}

/*---------------------------------------------------------------------------*/

static void 
output_headers(void)
{
	int filenum;

	fputs(header1, stdout);

	for (filenum = 0; filenum < num_files; filenum++) {
		fputs("** ", stdout);
		fputs(files[filenum], stdout);
		putc('\n', stdout);
	}

	fputs(header2, stdout);
}

static void 
output_sub_init_functions(void)
{
	int filenum;

	if (! need_initialization_code) {
		fputs(if_need_to_init, stdout);
	}

	fputs("static void init_modules_0(void)\n", stdout);
	fputs("{\n", stdout);

	for (filenum = 0; filenum < num_files; filenum++) {
		process_file(files[filenum]);
	}

	fputs("}\n", stdout);
	if (! need_initialization_code) {
		fputs("\n#endif\n", stdout);
	}
}

static void 
output_main_init_function(void)
{
	int i;

	fputs("\nstatic void init_modules(void)\n", stdout);
	fputs("{\n", stdout);

	if (! need_initialization_code) {
		fputs(if_need_to_init, stdout);
	}

	for (i = 0; i <= num_modules; i++) {
		printf("\tinit_modules_%d();\n", i);
	}

	if (! need_initialization_code) {
		fputs("\n#endif\n", stdout);
	}

	fputs("}\n", stdout);
}

static void 
output_main(void)
{
	printf(mercury_funcs, need_tracing, entry_point, entry_point);
	if (output_main_func) {
		fputs(main_func, stdout);
	}
}

/*---------------------------------------------------------------------------*/

static void 
process_file(const char *filename)
{
	int len = strlen(filename);
	if (len >= 2 && strcmp(filename + len - 2, ".c") == 0) {
		if (c_files_contain_extra_inits) {
			process_init_file(filename);
		} else {
			process_c_file(filename);
		}
	} else if (len >= 5 && strcmp(filename + len - 5, ".init") == 0) {
		process_init_file(filename);
	} else {
		fprintf(stderr,
			"%s: filename `%s' must end in `.c' or `.init'\n",
			progname, filename);
		num_errors++;
	}
}

static void
process_c_file(const char *filename)
{
	char func_name[1000];
	char *position;
	int i;

	/* remove the directory name, if any */
	if ((position = strrchr(filename, '/')) != NULL) {
		filename = position + 1;
	}

	/*
	** The func name is "mercury__<modulename>__init",
	** where <modulename> is the base filename with
	** all `.'s replaced with `__', and with each
	** component of the module name mangled according
	** to the algorithm in llds_out__name_mangle/2
	** in compiler/llds_out.m. 
	**
	** XXX We don't handle the full name mangling algorithm here;
	** instead we use a simplified version:
	** - if there are no special charaters, but the
	**   name starts with `f_', then replace the leading
	**   `f_' with `f__'
	** - if there are any special characters, give up
	*/

	/* check for special characters */
	for (i = 0; filename[i] != '\0'; i++) {
		if (filename[i] != '.' && !MR_isalnumunder(filename[i])) {
			fprintf(stderr, "mkinit: sorry, file names containing "
				"special characters are not supported.\n");
			fprintf(stderr, "File name `%s' contains special "
				"character `%c'.\n", filename, filename[i]);
			exit(1);
		}
	}
	strcpy(func_name, "mercury");
	while ((position = strchr(filename, '.')) != NULL) {
		strcat(func_name, "__");
		/* replace `f_' with `f__' */
		if (strncmp(filename, "f_", 2) == 0) {
			strcat(func_name, "f__");
			filename += 2;
		}
		strncat(func_name, filename, position - filename);
		filename = position + 1;
	}
	/*
	** The trailing stuff after the last `.' should just be the `c' suffix.
	*/
	strcat(func_name, "__init");

	output_init_function(func_name);

	if (aditi) {
		char *rl_data_name;
		int module_name_size;
		int mercury_len;

		mercury_len = strlen("mercury__");
		module_name_size =
		    strlen(func_name) - mercury_len - strlen("__init");
		rl_data_name = checked_malloc(module_name_size +
			strlen(aditi_rl_data_str) + 1);
		strcpy(rl_data_name, aditi_rl_data_str);
		strncat(rl_data_name, func_name + mercury_len,
			module_name_size);
		add_rl_data(rl_data_name);

	}
}

static void 
process_init_file(const char *filename)
{
	const char * const	init_str = "INIT ";
	const char * const	endinit_str = "ENDINIT ";
	const char * const	aditi_init_str = "ADITI_DATA ";
	const int		init_strlen = strlen(init_str);
	const int		endinit_strlen = strlen(endinit_str);
	const int		aditi_init_strlen = strlen(aditi_init_str);
	char			line[MAXLINE];
	char *			rl_data_name;
	FILE *			cfile;

	cfile = fopen(filename, "r");
	if (cfile == NULL) {
		fprintf(stderr, "%s: error opening file `%s': %s\n",
			progname, filename, strerror(errno));
		num_errors++;
		return;
	}

	while (getline(cfile, line, MAXLINE) > 0) {
	    if (strncmp(line, init_str, init_strlen) == 0) {
		int	j;

		for (j = init_strlen;
			MR_isalnum(line[j]) || line[j] == '_'; j++)
		{
			/* VOID */
		}
		line[j] = '\0';

		output_init_function(line + init_strlen);
	    } else if (aditi 
		    && strncmp(line, aditi_init_str, aditi_init_strlen) == 0) {
		int j;
	
		for (j = aditi_init_strlen;
			MR_isalnum(line[j]) || line[j] == '_'; j++)
		{
			/* VOID */
		}
		line[j] = '\0';

		rl_data_name = checked_malloc(
				strlen(line + aditi_init_strlen) + 1);
		strcpy(rl_data_name, line + aditi_init_strlen);
		add_rl_data(rl_data_name);
	    } else if (strncmp(line, endinit_str, endinit_strlen) == 0) {
		break;
	    }
	}

	fclose(cfile);
}

static void 
output_init_function(const char *func_name)
{
	static int num_calls = 0;

	if (num_calls >= maxcalls) {
		printf("}\n\n");

		num_modules++;
		num_calls = 0;
		printf("static void init_modules_%d(void)\n", num_modules);
		printf("{\n");
	}

	num_calls++;

	printf("\t{ extern void %s(void);\n", func_name);
	printf("\t  %s(); }\n", func_name);
}

/*---------------------------------------------------------------------------*/

	/*
	** Load the Aditi-RL for each module into the database.
	** mercury__load_aditi_rl_code() is called by aditi__connect/6
	** in extras/aditi/aditi.m.
	*/
static void
output_aditi_load_function(void)
{
	int len;
	int filenum;
	char filename[1000];
	int num_rl_modules;
	String_List *node;

	printf("\n/*\n** Load the Aditi-RL code for the program into the\n");
	printf("** currently connected database.\n*/\n");
	printf("#include \"aditi_api_config.h\"\n");
	printf("#include \"aditi_clnt.h\"\n");

	/*
	** Declare all the RL data constants.
	** Each RL data constant is named mercury___aditi_rl_data__<module>.
	*/
	for (node = rl_data; node != NULL; node = node->next) {
		printf("extern const char %s[];\n", node->data);
		printf("extern const int %s__length;\n", node->data);
	}

	printf("int mercury__load_aditi_rl_code(void)\n{\n"),

	/* Build an array containing the addresses of the RL data constants. */
	printf("\tstatic const char *rl_data[] = {\n\t\t");
	for (node = rl_data; node != NULL; node = node->next) {
		printf("%s,\n\t\t", node->data);
	}
	printf("NULL};\n");

	/* Build an array containing the lengths of the RL data constants. */
	printf("\tstatic const int * const rl_data_lengths[] = {\n\t\t");
	num_rl_modules = 0;
	for (node = rl_data; node != NULL; node = node->next) {
		num_rl_modules++;
		printf("&%s__length,\n\t\t", node->data);
	}
	printf("0};\n");
	
	printf("\tconst int num_rl_modules = %d;\n", num_rl_modules);
	printf("\tint status;\n");
	printf("\tint i;\n\n");

	/*
	** Output code to load the Aditi-RL for each module in turn.
	*/
	printf("\tfor (i = 0; i < num_rl_modules; i++) {\n");
	printf("\t\tif (*rl_data_lengths[i] != 0\n");

	/* The ADITI_NAME macro puts a prefix on the function name. */
	printf("\t\t    && (status = ADITI_NAME(load_immed)"
		"(*rl_data_lengths[i],\n");
	printf("\t\t\t\trl_data[i])) != ADITI_OK) {\n");
	printf("\t\t\treturn status;\n");
	printf("\t\t}\n");
	printf("\t}\n");
	printf("\treturn ADITI_OK;\n");
	printf("}\n");
}

/*---------------------------------------------------------------------------*/

static void
add_rl_data(char *data)
{
	String_List *new_node;

	new_node = checked_malloc(sizeof(String_List));
	new_node->data = data;
	new_node->next = rl_data;
	rl_data = new_node;
}

/*---------------------------------------------------------------------------*/

static int 
getline(FILE *file, char *line, int line_max)
{
	int	c, num_chars, limit;

	num_chars = 0;
	limit = line_max - 2;
	while ((c = getc(file)) != EOF && c != '\n') {
		if (num_chars < limit) {
			line[num_chars++] = c;
		}
	}
	
	if (c == '\n' || num_chars > 0) {
		line[num_chars++] = '\n';
	}

	line[num_chars] = '\0';
	return num_chars;
}

/*---------------------------------------------------------------------------*/

static void *
checked_malloc(size_t size)
{
	void *mem;
	if ((mem = malloc(size)) == NULL) {
		fprintf(stderr, "Out of memory\n");
		exit(1);
	}
	return mem;
}

/*---------------------------------------------------------------------------*/
