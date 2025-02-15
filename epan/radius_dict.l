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
 * The language we're scanning is case-insensitive.
 */
%option caseless

/*
 * Prefix scanner routines with "Radius" rather than "yy", so this scanner
 * can coexist with other scanners.
 */
%option prefix="Radius"

%option outfile="radius_dict.c"

%{
	/* radius_dict.l
	*
	* RADIUS dictionary parser
	*
	* Wireshark - Network traffic analyzer
	* By Gerald Combs <gerald@wireshark.org>
	* Copyright 1998 Gerald Combs
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

#include "config.h"

#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <epan/packet.h>
#include <epan/dissectors/packet-radius.h>
#include "radius_dict_lex.h"
#include <wsutil/file_util.h>

#ifdef _WIN32
/* disable Windows VC compiler warning "signed/unsigned mismatch" associated  */
/* with YY_INPUT code generated by flex versions such as 2.5.35.              */
#pragma warning (disable:4018)
#endif

#define ECHO
#define MAX_INCLUDE_DEPTH 10

	static void add_vendor(const gchar* name, guint32 id, guint type_octets, guint length_octets, gboolean has_flags);
	static void add_value(const gchar* attrib_name,const  gchar* repr, guint32 value);
	static void add_tlv(const gchar* name, const  gchar* code, radius_attr_dissector_t type, const gchar* attr);
	static void add_attribute(const gchar*,const  gchar*, radius_attr_dissector_t,const  gchar*, guint, gboolean, const gchar*);

	static YY_BUFFER_STATE include_stack[10];
	static int include_stack_ptr = 0;

	static radius_dictionary_t* dict = NULL;
	static GHashTable* value_strings = NULL; /* GArray(value_string) by attribute name */

	static gchar* attr_name = NULL;
	static gchar* attr_id = NULL;
	static radius_attr_dissector_t* attr_type = NULL;
	static gchar* attr_vendor = NULL;
	static gchar* vendor_name = NULL;
	static guint32 vendor_id = 0;
	static guint vendor_type_octets = 1;
	static guint vendor_length_octets = 1;
	static gboolean vendor_has_flags = FALSE;
	static gchar* value_repr = NULL;
	static guint encrypted = 0;
	static gboolean has_tag = FALSE;
	static gchar* current_vendor = NULL;
	static gchar* current_attr = NULL;

	static GString* error = NULL;
	static gchar* directory = NULL;
	static int linenums[] = {1,1,1,1,1,1,1,1,1,1};
	static gchar* fullpaths[] = {NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL};

%}

/* Note: FreeRadius allows VENDOR, ATTRIBUTE and VALUE names to contain any non-blank character.
 *       Using a negated "blank character class" pattern below for those names fails for some reason
 *       so for now the patterns for each name type include those characters found for the corresponding
 *       name types in the FreeRadius dictionaries.
 */

%START WS_OUT VENDOR VENDOR_W_NAME ATTR ATTR_W_NAME ATTR_W_ID ATTR_W_TYPE ATTR_W_VENDOR VALUE VALUE_W_ATTR VALUE_W_NAME INCLUDE JUNK BEGIN_VENDOR END_VENDOR VENDOR_W_ID VENDOR_W_FORMAT VENDOR_W_TYPE_OCTETS VENDOR_W_LENGTH_OCTETS VENDOR_W_CONTINUATION BEGIN_TLV END_TLV
%%
[:blank:]   ;
#[^\n]*		;

<JUNK>.*\qn		;

<WS_OUT>VENDOR { BEGIN VENDOR; }
<WS_OUT>ATTRIBUTE { BEGIN ATTR; }
<WS_OUT>VALUE { BEGIN VALUE; }
<WS_OUT>\$INCLUDE { BEGIN INCLUDE; }
<WS_OUT>BEGIN-VENDOR { BEGIN BEGIN_VENDOR; }
<WS_OUT>END-VENDOR { BEGIN END_VENDOR; }
<WS_OUT>BEGIN-TLV { BEGIN BEGIN_TLV; }
<WS_OUT>END-TLV { BEGIN END_TLV; }

<BEGIN_VENDOR>[0-9a-z_-]+ {
    if (current_vendor) {
        g_free(current_vendor);
    }
    current_vendor = g_strdup(yytext);
    BEGIN WS_OUT;
}
<END_VENDOR>[^\n]* {
    if (current_vendor) {
        g_free(current_vendor);
        current_vendor = NULL;
    }
    BEGIN WS_OUT;
}

<BEGIN_TLV>[0-9a-z_-]+ {
    if (current_attr) {
        g_free(current_attr);
    }
    current_attr = g_strdup(yytext);
    BEGIN WS_OUT;
}
<END_TLV>[^\n]* {
    if (current_attr) {
        g_free(current_attr);
        current_attr = NULL;
    }
    BEGIN WS_OUT;
}

<VENDOR>[0-9a-z_-]+   {
    vendor_name = g_strdup(yytext);
    vendor_type_octets = 1;
    vendor_length_octets = 1;
    vendor_has_flags = FALSE;
    BEGIN VENDOR_W_NAME;
}
<VENDOR_W_NAME>[0-9]+   {
    vendor_id = (guint32) strtoul(yytext,NULL,10);
    BEGIN VENDOR_W_ID;
}
<VENDOR_W_NAME>0x[0-9a-f]+   {
    vendor_id = (guint32) strtoul(yytext,NULL,16);
    BEGIN VENDOR_W_ID;
}
<VENDOR_W_ID>format= {
    BEGIN VENDOR_W_FORMAT;
}
<VENDOR_W_FORMAT>[124] {
    vendor_type_octets = (guint) strtoul(yytext,NULL,10);
    BEGIN VENDOR_W_TYPE_OCTETS;
}
<VENDOR_W_TYPE_OCTETS>,[012] {
    vendor_length_octets = (guint) strtoul(yytext+1,NULL,10);
    BEGIN VENDOR_W_LENGTH_OCTETS;
}
<VENDOR_W_LENGTH_OCTETS>,c {
    vendor_has_flags = TRUE;
    BEGIN VENDOR_W_CONTINUATION;
}
<VENDOR_W_FORMAT>\n |
<VENDOR_W_TYPE_OCTETS>\n |
<VENDOR_W_LENGTH_OCTETS>\n |
<VENDOR_W_CONTINUATION>\n |
<VENDOR_W_ID>\n {
    add_vendor(vendor_name, vendor_id, vendor_type_octets, vendor_length_octets, vendor_has_flags);
    g_free(vendor_name);
    BEGIN WS_OUT;
}

<ATTR>[0-9a-z_/.-]+			{ attr_name = g_strdup(yytext); encrypted = 0; has_tag = FALSE; BEGIN ATTR_W_NAME; }
<ATTR_W_NAME>[0-9]+			{ attr_id = g_strdup(yytext);  BEGIN ATTR_W_ID;}
<ATTR_W_NAME>0x[0-9a-f]+		{ attr_id = g_strdup_printf("%u",(int)strtoul(yytext,NULL,16)); BEGIN ATTR_W_ID;}
<ATTR_W_ID>integer			{ attr_type = radius_integer;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>string			{ attr_type = radius_string;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>octets			{ attr_type = radius_octets;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>ipaddr			{ attr_type = radius_ipaddr;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>ipv6addr			{ attr_type = radius_ipv6addr;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>ipv6prefix			{ attr_type = radius_ipv6prefix;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>ipxnet			{ attr_type = radius_ipxnet;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>date				{ attr_type = radius_date;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>abinary			{ attr_type = radius_abinary;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>ether  			{ attr_type = radius_ether;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>ifid				{ attr_type = radius_ifid;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>byte				{ attr_type = radius_integer;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>short			{ attr_type = radius_integer;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>signed			{ attr_type = radius_signed;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>combo-ip			{ attr_type = radius_combo_ip;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>tlv				{ attr_type = radius_tlv;  BEGIN ATTR_W_TYPE; }
<ATTR_W_ID>[0-9a-z_-]+			{ attr_type = radius_octets;  BEGIN ATTR_W_TYPE; }
<ATTR_W_TYPE>has_tag[,]?		{ has_tag = TRUE; }
<ATTR_W_TYPE>encrypt=[123][,]?		{ encrypted = (guint) strtoul(yytext+8,NULL,10); }
<ATTR_W_TYPE>[0-9a-z_-]+=([^\n]*)	;
<ATTR_W_TYPE>[0-9a-z_-]+		{
    attr_vendor = g_strdup(yytext);
    add_attribute(attr_name,attr_id,attr_type,attr_vendor,encrypted,has_tag,current_attr);
    g_free(attr_id);
    g_free(attr_vendor);
    g_free(attr_name);
    attr_id = NULL;
    attr_vendor = NULL;
    attr_name = NULL;
    BEGIN WS_OUT;
}
<ATTR_W_TYPE>\n						{
    add_attribute(attr_name,attr_id,attr_type,current_vendor,encrypted,has_tag,current_attr);
    g_free(attr_id);
    g_free(attr_name);
    linenums[include_stack_ptr]++;
    has_tag = FALSE;
    encrypted=FALSE;
    BEGIN WS_OUT;
}
<ATTR_W_VENDOR>\n					{
    add_attribute(attr_name,attr_id,attr_type,attr_vendor,encrypted,has_tag,current_attr);
    g_free(attr_id);
    g_free(attr_vendor);
    g_free(attr_name);
    linenums[include_stack_ptr]++;
    BEGIN WS_OUT;
};

<VALUE>[0-9a-z_/-]+				{ attr_name = g_strdup(yytext); BEGIN VALUE_W_ATTR; }
<VALUE_W_ATTR>[^[:blank:]]+			{ value_repr = g_strdup(yytext); BEGIN VALUE_W_NAME; }
<VALUE_W_NAME>[0-9]+				{ add_value(attr_name,value_repr, (guint32) strtoul(yytext,NULL,10));  g_free(attr_name); g_free(value_repr); BEGIN WS_OUT;}
<VALUE_W_NAME>0x[0-9a-f]+			{ add_value(attr_name,value_repr, (guint32) strtoul(yytext,NULL,16));  g_free(attr_name); g_free(value_repr); BEGIN WS_OUT;}

<INCLUDE>[^[:blank:]\n]+   {
	if ( include_stack_ptr >= MAX_INCLUDE_DEPTH ) {
		g_string_append_printf(error, "$INCLUDE files nested to deeply\n");
		yyterminate();
	}

	include_stack[include_stack_ptr++] = YY_CURRENT_BUFFER;

	fullpaths[include_stack_ptr] = g_strdup_printf("%s" G_DIR_SEPARATOR_S "%s",
	    directory,yytext);

	yyin = ws_fopen( fullpaths[include_stack_ptr], "r" );

	if (!yyin) {
		if (errno) {
			g_string_append_printf(error,
					"Could not open file: '%s', error: %s\n",
					fullpaths[include_stack_ptr],
					g_strerror(errno) );
		} else {
			g_string_append_printf(error,
					"Could not open file: '%s', no errno\n",
					fullpaths[include_stack_ptr]);
		}
		g_free(fullpaths[include_stack_ptr]);
		fullpaths[include_stack_ptr] = NULL;
		include_stack_ptr--;
	} else {
		linenums[include_stack_ptr] = 1;
		yy_switch_to_buffer(yy_create_buffer( yyin, YY_BUF_SIZE ) );
	}


	BEGIN WS_OUT;
}

<<EOF>> {

	fclose(yyin);
	yyin = NULL;

	if ( --include_stack_ptr < 0 ) {
		yyterminate();
	} else {
		g_free(fullpaths[include_stack_ptr+1]);
		fullpaths[include_stack_ptr+1] = NULL;

		yy_delete_buffer( YY_CURRENT_BUFFER );
		yy_switch_to_buffer(include_stack[include_stack_ptr]);
	}

	BEGIN WS_OUT;
}

\n 	{ linenums[include_stack_ptr]++; BEGIN WS_OUT; }


%%

static void add_vendor(const gchar* name, guint32 id, guint type_octets, guint length_octets, gboolean has_flags) {
	radius_vendor_info_t* v;

	v = (radius_vendor_info_t *)g_hash_table_lookup(dict->vendors_by_id, GUINT_TO_POINTER(id));

	if (!v) {
		/*
		 * New vendor.
		 * Allocate a new entry and insert it into the by-ID and
		 * by-name hash tables.
		 */
		v = g_new(radius_vendor_info_t,1);
		v->attrs_by_id = g_hash_table_new(g_direct_hash,g_direct_equal);
		v->code = id;
		v->ett = -1;
		v->name = g_strdup(name);
		v->type_octets = type_octets;
		v->length_octets = length_octets;
		v->has_flags = has_flags;

		g_hash_table_insert(dict->vendors_by_id,GUINT_TO_POINTER(v->code),v);
		g_hash_table_insert(dict->vendors_by_name, (gpointer) v->name, v);
	} else {
		/*
		 * This vendor is already in the table.
		 *
		 * Assume that the dictionary knows the 'ground truth' about
		 * the type/length/has_flags information and thus allow the
		 * dictionary to overwrite these values even for vendors that
		 * have already been loaded.
		 *
		 * XXX - this could be due to the vendor being in multiple
		 * dictionary files, rather than having been specially
		 * entered by the RADIUS dissector, as a side effect of
		 * specially entering an attribute; should we report vendors
		 * that appear in different dictionaries with different
		 * properties?
		 */
		v->type_octets = type_octets;
		v->length_octets = length_octets;
		v->has_flags = has_flags;

		/*
		 * Did the name change?
		 */
		if (g_strcmp0(v->name, name) != 0) {
			/*
			 * Yes.  Remove the entry from the by-name hash table
			 * and re-insert it with the new name.
			 */
			g_hash_table_remove(dict->vendors_by_name, (gpointer) v->name);
			g_free((gpointer) v->name);
			v->name = g_strdup(name);
			g_hash_table_insert(dict->vendors_by_name, (gpointer) v->name, v);
		}
	}
}

static void add_attribute(const gchar* name, const  gchar* codestr, radius_attr_dissector_t type, const  gchar* vendor, guint encrypted_flag, gboolean tagged, const gchar* attr) {
	radius_attr_info_t* a;
	GHashTable* by_id;
	guint32 code;

	if (attr){
		add_tlv(name, codestr, type, attr);
		return;
	}


	if (vendor) {
		radius_vendor_info_t* v;
		v = (radius_vendor_info_t *)g_hash_table_lookup(dict->vendors_by_name,vendor);

		if (! v) {
			g_string_append_printf(error, "Vendor: '%s', does not exist in %s:%i \n", vendor, fullpaths[include_stack_ptr], linenums[include_stack_ptr] );
			BEGIN JUNK;
			return;
		} else {
			by_id = v->attrs_by_id;
		}
	} else {
		by_id = dict->attrs_by_id;
	}

	code= (guint32) strtoul(codestr, NULL, 10);

	a=(radius_attr_info_t*)g_hash_table_lookup(by_id, GUINT_TO_POINTER(code));

	if (!a) {
		/*
		 * New attribute.
		 * Allocate a new entry and insert it into the by-ID and
		 * by-name hash tables.
		 */
		a = g_new(radius_attr_info_t,1);
		a->code = code;
		a->name = g_strdup(name);
		a->dissector = NULL;
		a->encrypt = encrypted_flag;
		a->tagged =  tagged;
		a->type = type;
		a->vs = NULL;
		a->hf = -1;
		a->hf_alt = -1;
		a->hf_tag = -1;
		a->hf_len = -1;
		a->ett = -1;
		a->tlvs_by_id = NULL;
		g_hash_table_insert(by_id, GUINT_TO_POINTER(code),a);
		g_hash_table_insert(dict->attrs_by_name,(gpointer) (a->name),a);
	} else {
		/*
		 * This attribute is already in the table.
		 *
		 * Overwrite the encrypted flag, tagged property, and type;
		 * the other properties don't get set until after we've
		 * finished reading the dictionaries.
		 *
		 * XXX - this could be due to the attribute being in
		 * multiple dictionary files, rather than having been
		 * specially entered by the RADIUS dissector to give it
		 * a special dissection routine; should we report attributes
		 * that appear in different dictionaries with different
		 * properties?
		 */
		a->encrypt = encrypted_flag;
		a->tagged =  tagged;
		a->type = type;

		/*
		 * Did the name change?
		 */
		if (g_strcmp0(a->name, name) != 0) {
			/*
			 * Yes.  Remove the entry from the by-name hash table
			 * and re-insert it with the new name.
			 */
			g_hash_table_remove(dict->attrs_by_name, (gpointer) (a->name));
			g_free((gpointer) a->name);
			a->name = g_strdup(name);
			g_hash_table_insert(dict->attrs_by_name, (gpointer) (a->name),a);
		}
	}
}

static void add_tlv(const gchar* name, const  gchar* codestr, radius_attr_dissector_t type, const gchar* attr) {
	radius_attr_info_t* a;
	radius_attr_info_t* s;
	guint32 code;

	a = (radius_attr_info_t*)g_hash_table_lookup(dict->attrs_by_name, attr);

	if (! a) {
		g_string_append_printf(error, "Attr: '%s', does not exist in %s:%i \n", attr, fullpaths[include_stack_ptr], linenums[include_stack_ptr]);
		BEGIN JUNK;
		return;
	}

	if (type == radius_tlv) {
		g_string_append_printf(error, "sub-TLV: '%s', sub-TLV's type is specified as tlv in %s:%i \n", name, fullpaths[include_stack_ptr], linenums[include_stack_ptr]);
		BEGIN JUNK;
		return;
	}


	if (! a->tlvs_by_id) {
		a->tlvs_by_id = g_hash_table_new(g_direct_hash,g_direct_equal);
	}

	code = (guint32) strtoul(codestr, NULL, 10);

	s = (radius_attr_info_t*)g_hash_table_lookup(a->tlvs_by_id, GUINT_TO_POINTER(code));

	if (!s) {
		/*
		 * This TLV doesn't yet exist in this attribute's TLVs-by-ID
		 * hash table.  Add it.
		 */
		s = g_new(radius_attr_info_t,1);
		s->name = g_strdup(name);
		s->dissector = NULL;
		s->code = code;
		s->type = type;
		s->encrypt = FALSE;
		s->tagged = FALSE;
		s->dissector = NULL;
		s->vs = NULL;
		s->hf = -1;
		s->hf_alt = -1;
		s->hf_tag = -1;
		s->hf_len = -1;
		s->ett = -1;
		s->tlvs_by_id = NULL;

		g_hash_table_insert(a->tlvs_by_id,GUINT_TO_POINTER(s->code),s);
		g_hash_table_insert(dict->tlvs_by_name,(gpointer) (s->name),s);
	}

	/*
	 * If it *does* exist, leave it alone; there shouldn't be duplicate
	 * entries by name in the dictionaries (even if there might be
	 * multiple entries for a given attribute in the dictionaries, each
	 * one adding some TLV values), and we don't directly add entries
	 * for TLVs in the RADIUS dissector.
	 *
	 * XXX - report the duplicate entries? 
	 */
}

void add_value(const gchar* attrib_name, const gchar* repr, guint32 value) {
	value_string v;
	GArray* a = (GArray*)g_hash_table_lookup(value_strings,attrib_name);

	if (! a) {
		a = g_array_new(TRUE,TRUE,sizeof(value_string));
		g_hash_table_insert(value_strings,g_strdup(attrib_name),a);
	}

	v.value = value;
	v.strptr = g_strdup(repr);

	g_array_append_val(a,v);
}

static void setup_tlvs(gpointer k _U_, gpointer v, gpointer p _U_) {
	radius_attr_info_t* s = (radius_attr_info_t*)v;
	gpointer key;

	union {
		GArray* a;
		gpointer p;
	} vs;

	if (g_hash_table_lookup_extended(value_strings, s->name, &key, &vs.p)) {
		s->vs = (value_string*)(void *)vs.a->data;
		g_array_free(vs.a, FALSE);
		g_hash_table_remove(value_strings, key);
		g_free(key);
	}
}

static void setup_attrs(gpointer k _U_, gpointer v, gpointer p _U_) {
	radius_attr_info_t* a = (radius_attr_info_t*)v;
	gpointer key;

	union {
		GArray* a;
		gpointer p;
	} vs;

	if (g_hash_table_lookup_extended(value_strings,a->name,&key,&vs.p) ) {
		a->vs = (value_string*)(void *)vs.a->data;
		g_array_free(vs.a,FALSE);
		g_hash_table_remove(value_strings,key);
		g_free(key);
	}

	if (a->tlvs_by_id) {
		g_hash_table_foreach(a->tlvs_by_id, setup_tlvs, p);
	}
}

static void setup_vendors(gpointer k _U_, gpointer v, gpointer p) {
	radius_vendor_info_t* vnd = (radius_vendor_info_t*)v;

	g_hash_table_foreach(vnd->attrs_by_id,setup_attrs,p);
}

static gboolean destroy_value_strings(gpointer k, gpointer v, gpointer p _U_) {
	value_string* vs = (value_string*)(void *)(((GArray*)v)->data);

	g_free(k);

	for (;vs->strptr;vs++) {
		g_free((void*)vs->strptr);
	}

	g_array_free((GArray*)v,TRUE);
	return TRUE;
}

gboolean radius_load_dictionary (radius_dictionary_t* d, gchar* dir, const gchar* filename, gchar** err_str) {
	int i;

	dict = d;
	directory = dir;

	fullpaths[include_stack_ptr] = g_strdup_printf("%s" G_DIR_SEPARATOR_S "%s",
	    directory,filename);

	error = g_string_new("");

	yyin = ws_fopen(fullpaths[include_stack_ptr],"r");

	if (!yyin) {
		g_string_append_printf(error, "Could not open file: '%s', error: %s\n", fullpaths[include_stack_ptr], g_strerror(errno) );
		g_free(fullpaths[include_stack_ptr]);
		*err_str = g_string_free(error,FALSE);
		return FALSE;
	}

	value_strings = g_hash_table_new(g_str_hash,g_str_equal);

	BEGIN WS_OUT;

	yylex();

	if (yyin != NULL) fclose(yyin);
	yyin = NULL;

	for (i=0; i < 10; i++) {
		if (fullpaths[i]) g_free(fullpaths[i]);
	}

	g_hash_table_foreach(dict->attrs_by_id,setup_attrs,NULL);
	g_hash_table_foreach(dict->vendors_by_id,setup_vendors,NULL);
	g_hash_table_foreach_remove(value_strings,destroy_value_strings,NULL);

	if (error->len > 0) {
		*err_str = g_string_free(error,FALSE);
		return FALSE;
	} else {
		*err_str = NULL;
		g_string_free(error,TRUE);
		return TRUE;
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

/*
 * Editor modelines  -  http://www.wireshark.org/tools/modelines.html
 *
 * Local variables:
 * c-basic-offset: 8
 * tab-width: 8
 * indent-tabs-mode: t
 * End:
 *
 * vi: set shiftwidth=8 tabstop=8 noexpandtab:
 * :indentSize=8:tabSize=8:noTabs=false:
 */
