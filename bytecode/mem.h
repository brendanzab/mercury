/*
** Copyright (C) 1997 University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
**
** $Id: mem.h,v 1.2 1997-03-25 02:15:45 aet Exp $
*/

#if	! defined(MEMALLOC_H)
#define	MEMALLOC_H

void*
mem_malloc(size_t size);

void
mem_free(void *mem);

void*
mem_realloc(void *mem, size_t size);

#endif	/* MEMALLOC_H */
