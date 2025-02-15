/*
 * We don't use input, so don't generate code for it.
 */
%option noinput

/*
 * We don't use unput, so don't generate code for it.
 */
%option nounput

/*
 * We don't read interactively from the terminal.
 */
%option never-interactive

/*
 * Prefix scanner routines with "K12Text_" rather than "yy", so this scanner
 * can coexist with other scanners.
 */
%option prefix="K12Text_"

%option outfile="k12text.c"

/* Options useful for debugging				*/
/* noline:  Prevent generation of #line directives	*/
/*	    Seems to be required when using the		*/
/*	    Windows VS debugger so as to be able	*/
/*	    to properly step through the code and	*/
/*	    set breakpoints & etc using the		*/
/*	    k12text.c file rather than the		*/
/*	    k12text.l file				*/
/*	XXX: %option noline gives an error message:	*/
/*	    "unrecognized %option: line"		*/
/*	    with flex 2.5.35; the --noline		*/
/*	    command-line option works OK.		*/
/*							*/
/* debug:   Do output of "rule acceptance" info		*/
/*	    during parse				*/
/*							*/
/* %option noline  */
/* %option debug   */

%{
/* k12text.l
 *
 * Wiretap Library
 * Copyright (c) 1998 by Gilbert Ramirez <gram@alumni.rice.edu>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

 /*
  * TODO:
  *   - fix timestamps after midnight
  *   - verify encapsulations
  */

#include "config.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include "wtap-int.h"
#include "wtap.h"
#include "file_wrappers.h"
#include <wsutil/buffer.h>
#include "k12.h"
#include "k12text_lex.h"

#ifndef HAVE_UNISTD_H
#define YY_NO_UNISTD_H
#endif

static guint g_h;
static guint g_m;
static guint g_s;
static guint g_ms;
static guint g_ns;
static gint g_encap;
static guint8 bb[WTAP_MAX_PACKET_SIZE];
static guint ii;
static gboolean is_k12text;
static gboolean at_eof;
static guint junk_chars;
static void finalize_frame(void);
static gchar* error_str;
static guint64 file_bytes_read;
static gboolean ok_frame;
static FILE_T yy_fh;

#define KERROR(text) do { error_str = g_strdup(text); yyterminate(); } while(0)
#define SET_HOURS(text) g_h = (guint) strtoul(text,NULL,10)
#define SET_MINUTES(text) g_m = (guint) strtoul(text,NULL,10)
#define SET_SECONDS(text) g_s = (guint) strtoul(text,NULL,10)
#define SET_MS(text) g_ms = (guint) strtoul(text,NULL,10)
#define SET_NS(text) g_ns = (guint) strtoul(text,NULL,10)
#define ADD_BYTE(text) do {if (ii >= WTAP_MAX_PACKET_SIZE) {KERROR("frame too large");} bb[ii++] = (guint8)strtoul(text,NULL,16); } while(0)
#define FINALIZE_FRAME() finalize_frame()
/*~ #define ECHO*/
#define YY_USER_ACTION file_bytes_read += yyleng;
#define YY_INPUT(buf,result,max_size) { int c = file_getc(yy_fh);  result = (c==EOF) ? YY_NULL : (buf[0] = c, 1); }

#define MAX_JUNK 400000
#define ECHO

/*
 * Private per-file data.
 */
typedef struct {
	/*
	 * The file position after the end of the previous frame processed by
	 * k12text_read.
	 *
	 * We need to keep this around, and seek to it at the beginning of
	 * each call to k12text_read(), since the lexer undoubtedly did some
	 * amount of look-ahead when processing the previous frame.
	 */
	gint64	next_frame_offset;
} k12text_t;
%}
start_timestamp \053[\055]{9}\053[\055]{15,100}\053[\055]{10,100}\053
oneormoredigits [0-9]+:
twodigits [0-9][0-9]
colon :
comma ,
threedigits [0-9][0-9][0-9]
start_bytes \174\060\040\040\040\174
bytes_junk \174[A-F0-9][A-F0-9\040][A-F0-9\040][A-F0-9\040]\174
byte [a-f0-9][a-f0-9]\174
end_bytes \015?\012\015?\012
eth ETHER
mtp2 MTP-L2
sscop SSCOP
sscfnni SSCF
hdlc HDLC

%START MAGIC NEXT_FRAME HOURS MINUTES M2S SECONDS S2M MS M2N NS ENCAP STARTBYTES BYTE
%%
<MAGIC>{start_timestamp}  { is_k12text = TRUE; yyterminate(); }

<MAGIC>. { if (++ junk_chars > MAX_JUNK) { is_k12text = FALSE;  yyterminate(); } }

<NEXT_FRAME>{start_timestamp} {BEGIN(HOURS); }
<HOURS>{oneormoredigits} { SET_HOURS(yytext); BEGIN(MINUTES); }
<MINUTES>{twodigits} { SET_MINUTES(yytext); BEGIN(M2S);}
<M2S>{colon} { BEGIN(SECONDS);}
<SECONDS>{twodigits} { SET_SECONDS(yytext); BEGIN(S2M); }
<S2M>{comma}  { BEGIN(MS); }
<MS>{threedigits} { SET_MS(yytext); BEGIN(M2N);  }
<M2N>{comma}  { BEGIN(NS); }
<NS>{threedigits} { SET_NS(yytext); BEGIN(ENCAP);}
<ENCAP>{eth} {g_encap = WTAP_ENCAP_ETHERNET; BEGIN(STARTBYTES); }
<ENCAP>{mtp2} {g_encap = WTAP_ENCAP_MTP2; BEGIN(STARTBYTES); }
<ENCAP>{sscop} {g_encap = WTAP_ENCAP_ATM_PDUS; BEGIN(STARTBYTES); }
<ENCAP>{sscfnni} {g_encap = WTAP_ENCAP_MTP3; BEGIN(STARTBYTES); }
<ENCAP>{hdlc} {g_encap = WTAP_ENCAP_CHDLC; BEGIN(STARTBYTES); }
<ENCAP,STARTBYTES>{start_bytes} { BEGIN(BYTE); }
<BYTE>{byte} { ADD_BYTE(yytext); }
<BYTE>{bytes_junk} ;
<BYTE>{end_bytes} { FINALIZE_FRAME(); yyterminate(); }

. {  if (++junk_chars > MAX_JUNK) { KERROR("too much junk");  } }
<<EOF>> { at_eof = TRUE; yyterminate(); }

%%

static void finalize_frame(void) {
	ok_frame = TRUE;
}

/* Fill in pkthdr */

static gboolean
k12text_set_headers(struct wtap_pkthdr *phdr, int *err, gchar **err_info)
{
	phdr->rec_type = REC_TYPE_PACKET;
	phdr->presence_flags = WTAP_HAS_TS|WTAP_HAS_CAP_LEN;

	phdr->ts.secs = 946681200 + (3600*g_h) + (60*g_m) + g_s;
	phdr->ts.nsecs = 1000000*g_ms + 1000*g_ns;

	phdr->caplen = phdr->len = ii;

	phdr->pkt_encap = g_encap;

	/* The file-encap is WTAP_ENCAP_PER_PACKET */
	switch(g_encap) {
	    case WTAP_ENCAP_ETHERNET:
		    phdr->pseudo_header.eth.fcs_len = 0;
		    break;
	    case WTAP_ENCAP_MTP3:
	    case WTAP_ENCAP_CHDLC:
		    /* no pseudo_header to fill in for these types */
		    break;
	    case WTAP_ENCAP_MTP2:      /* not (yet) supported		*/
		    /* XXX: I don't know how to fill in the		*/
		    /* pseudo_header for these types.			*/
		    *err = WTAP_ERR_UNSUPPORTED;
		    *err_info = g_strdup("k12text: MTP2 packets not yet supported");
		    return FALSE;
	    case WTAP_ENCAP_ATM_PDUS:  /* not (yet) supported		*/
		    /* XXX: I don't know how to fill in the		*/
		    /* pseudo_header for these types.			*/
		    *err = WTAP_ERR_UNSUPPORTED;
		    *err_info = g_strdup("k12text: SSCOP packets not yet supported");
		    return FALSE;
	    default:
		    *err = WTAP_ERR_UNSUPPORTED;
		    *err_info = g_strdup("k12text: unknown encapsulation type");
		    return FALSE;
	}
	return TRUE;
}

/* Note: k12text_reset is called each time data is to be processed from	*/
/*       a file. This ensures that no "state" from a previous read is	*/
/*       used (such as the lexer look-ahead buffer, file_handle, file	*/
/*       position and so on. This allows a single lexer buffer to be	*/
/*       used even when multiple files are open simultaneously (as for	*/
/*       a file merge).							*/

static void
k12text_reset(FILE_T fh)
{
	yy_fh = fh;
	yyrestart(0);
	g_encap = WTAP_ENCAP_UNKNOWN;
	ok_frame = FALSE;
	is_k12text = FALSE;
	at_eof = FALSE;
	junk_chars = 0;
	error_str = NULL;
	file_bytes_read=0;
	g_h=0;
	g_m=0;
	g_s=0;
	g_ns=0;
	g_ms=0;
	ii=0;
}

static gboolean
k12text_read(wtap *wth, int *err, char ** err_info, gint64 *data_offset)
{
	k12text_t *k12text = (k12text_t *)wth->priv;

	/*
	 * We seek to the file position after the end of the previous frame
	 * processed by k12text_read(), since the lexer undoubtedly did some
	 * amount of look-ahead when processing the previous frame.
	 *
	 * We also clear out any lexer state (eg: look-ahead buffer) and
	 * init vars set by lexer.
	 */

	if ( file_seek(wth->fh, k12text->next_frame_offset, SEEK_SET, err) == -1) {
		return FALSE;
	}
	k12text_reset(wth->fh);		/* init lexer buffer and vars set by lexer */

	BEGIN(NEXT_FRAME);
	yylex();

	if (ok_frame == FALSE) {
		if (at_eof) {
			*err = 0;
			*err_info = NULL;
		} else {
			*err = WTAP_ERR_BAD_FILE;
			*err_info = error_str;
		}
		return FALSE;
	}

	*data_offset = k12text->next_frame_offset;       /* file position for beginning of this frame   */
	k12text->next_frame_offset += file_bytes_read;   /* file position after end of this frame       */

	if (!k12text_set_headers(&wth->phdr, err, err_info))
		return FALSE;

	ws_buffer_assure_space(wth->frame_buffer, wth->phdr.caplen);
	memcpy(ws_buffer_start_ptr(wth->frame_buffer), bb, wth->phdr.caplen);

	return TRUE;
}

static gboolean
k12text_seek_read(wtap *wth, gint64 seek_off, struct wtap_pkthdr *phdr, Buffer *buf, int *err, char **err_info)
{
	if ( file_seek(wth->random_fh, seek_off, SEEK_SET, err) == -1) {
		return FALSE;
	}
	k12text_reset(wth->random_fh);		/* init lexer buffer and vars set by lexer */

	BEGIN(NEXT_FRAME);
	yylex();

	if (ok_frame == FALSE) {
		*err = WTAP_ERR_BAD_FILE;
		if (at_eof) {
			/* What happened ? The desired frame was previously read without a problem */
			*err_info = g_strdup("Unexpected EOF (program error ?)");
		} else {
			*err_info = error_str;
		}
		return FALSE;
	}

	if (!k12text_set_headers(phdr, err, err_info))
		return FALSE;

	ws_buffer_assure_space(buf, phdr->caplen);
	memcpy(ws_buffer_start_ptr(buf), bb, phdr->caplen);

	return TRUE;
}

wtap_open_return_val
k12text_open(wtap *wth, int *err, gchar **err_info _U_)
{
	k12text_t *k12text;

	k12text_reset(wth->fh);       /* init lexer buffer and vars set by lexer */

	BEGIN(MAGIC);
	yylex();

	if (! is_k12text) return WTAP_OPEN_NOT_MINE;

	if ( file_seek(wth->fh, 0, SEEK_SET, err) == -1) {
		return WTAP_OPEN_ERROR;
	}

	k12text = (k12text_t *)g_malloc(sizeof(k12text_t));
	wth->priv = (void *)k12text;
	k12text->next_frame_offset = 0;
	wth->file_type_subtype = WTAP_FILE_TYPE_SUBTYPE_K12TEXT;
	wth->file_encap = WTAP_ENCAP_PER_PACKET;
	wth->snapshot_length = 0;
	wth->subtype_read = k12text_read;
	wth->subtype_seek_read = k12text_seek_read;
	wth->file_tsprec = WTAP_TSPREC_NSEC;

	return WTAP_OPEN_MINE;
}


static const struct { int e; const char* s; } encaps[] = {
	{ WTAP_ENCAP_ETHERNET, "ETHER" },
	{ WTAP_ENCAP_MTP2, "MTP-L2" },
	{ WTAP_ENCAP_ATM_PDUS, "SSCOP" },
	{ WTAP_ENCAP_MTP3, "SSCF" },
	{ WTAP_ENCAP_CHDLC, "HDLC" },
	/* ... */
	{ 0, NULL }
};

static gboolean
k12text_dump(wtap_dumper *wdh _U_, const struct wtap_pkthdr *phdr,
	     const guint8 *pd, int *err, gchar **err_info _U_) {
#define K12BUF_SIZE 196808
	char *buf;
	size_t left = K12BUF_SIZE;
	size_t wl;
	char *p;
	const char* str_enc;
	guint i;
	guint ns;
	guint ms;
	gboolean ret;
	struct tm *tmp;

	/* Don't write anything bigger than we're willing to read. */
	if (phdr->caplen > WTAP_MAX_PACKET_SIZE) {
		*err = WTAP_ERR_PACKET_TOO_LARGE;
		return FALSE;
	}

	str_enc = NULL;
	for(i=0; encaps[i].s; i++) {
		if (phdr->pkt_encap == encaps[i].e) {
			str_enc = encaps[i].s;
			break;
		}
	}
	if (str_enc == NULL) {
		/*
		 * That encapsulation type is not supported.  Fail.
		 */
		*err = WTAP_ERR_UNWRITABLE_ENCAP;
		return FALSE;
	}

	buf = (char *)g_malloc(K12BUF_SIZE);
	p = buf;

	ms = phdr->ts.nsecs / 1000000;
	ns = (phdr->ts.nsecs - (1000000*ms))/1000;

	tmp = gmtime(&phdr->ts.secs);
	if (tmp == NULL)
		g_snprintf(p, 90, "+---------+---------------+----------+\r\nXX:XX:XX,");
	else
		strftime(p, 90, "+---------+---------------+----------+\r\n%H:%M:%S,", tmp);
	wl = strlen(p);
	p += wl;
	left -= wl;

	wl = g_snprintf(p, (gulong)left, "%.3d,%.3d   %s\r\n|0   |", ms, ns, str_enc);
	p += wl;
	left -= wl;

	for(i = 0; i < phdr->caplen && left > 2; i++) {
		wl = g_snprintf(p, (gulong)left, "%.2x|", pd[i]);
		p += wl;
		left -= wl;
	}

	wl = g_snprintf(p, (gulong)left, "\r\n\r\n");
	left -= wl;

	ret = wtap_dump_file_write(wdh, buf, K12BUF_SIZE - left, err);

	g_free(buf);
	return ret;
}


gboolean
k12text_dump_open(wtap_dumper *wdh, int *err _U_)
{
    wdh->subtype_write = k12text_dump;

    return TRUE;
}

int
k12text_dump_can_write_encap(int encap)
{
    switch (encap) {
	case WTAP_ENCAP_PER_PACKET:
	case WTAP_ENCAP_ETHERNET:
	case WTAP_ENCAP_MTP3:
	case WTAP_ENCAP_CHDLC:
		return 0;
	case WTAP_ENCAP_MTP2:
	case WTAP_ENCAP_ATM_PDUS:
	default:
		return WTAP_ERR_UNWRITABLE_ENCAP;
    }
}

/*
 * We want to stop processing when we get to the end of the input.
 * (%option noyywrap is not used because if used then
 * some flex versions (eg: 2.5.35) generate code which causes
 * warnings by the Windows VC compiler).
 */

int yywrap(void) {
    return 1;
}
