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
 * Prefix scanner routines with "Dtd_Parse_" rather than "yy", so this scanner
 * can coexist with other scanners.
 */
%option prefix="Dtd_Parse_"

%option outfile="dtd_parse.c"

%{

	/* dtd_parse.l
	* an XML dissector for Wireshark
	* lexical analyzer for DTDs
	*
	* Copyright 2004, Luis E. Garcia Ontanon <luis@ontanon.org>
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

#include <glib.h>
#include <string.h>

#include "dtd.h"
#include "dtd_grammar.h"
#include "dtd_parse.h"
#include "dtd_parse_lex.h"

	struct _proto_xmlpi_attr {
		const gchar* name;
		void (*act)(gchar*);
	};

	static void* pParser;
	static GString* input_string;
	static size_t offsetx;
	static size_t len;
	static gchar* location;
	static gchar* attr_name;

	static size_t my_yyinput(char* buff,size_t size);

	static dtd_token_data_t* new_token(gchar*);

	static dtd_build_data_t* build_data;

	static void set_proto_name (gchar* val) { if(build_data->proto_name) g_free(build_data->proto_name); build_data->proto_name = g_strdup(val); }
	static void set_media_type (gchar* val) { if(build_data->media_type) g_free(build_data->media_type); build_data->media_type = g_strdup(val); }
	static void set_proto_root (gchar* val) { if(build_data->proto_root) g_free(build_data->proto_root); build_data->proto_root = g_strdup(val); }
	static void set_description (gchar* val) { if(build_data->description) g_free(build_data->description); build_data->description = g_strdup(val); }
	static void set_recursive (gchar* val) { build_data->recursion = ( g_ascii_strcasecmp(val,"yes") == 0 ) ? TRUE : FALSE; }

	static struct _proto_xmlpi_attr proto_attrs[] =
	{
		{ "proto_name", set_proto_name },
		{ "media", set_media_type },
		{ "root", set_proto_root },
		{ "description", set_description },
		{ "hierarchy", set_recursive },
		{NULL,NULL}
	};

#ifdef DEBUG_DTD_PARSER
#define DEBUG_DTD_TOKEN fprintf(stderr,"->%s (%i)%s\n",location,token_type,yytext)
#else
#define DEBUG_DTD_TOKEN
#endif

#define DTD_PARSE(token_type) \
	{   DEBUG_DTD_TOKEN; \
		DtdParse(pParser, (token_type), new_token(yytext), build_data); \
		if(build_data->error->len > 0) yyterminate(); \
	}


#define YY_INPUT(buff,result,max_size) ( (result) = my_yyinput((buff),(max_size)) )

/*
 * Flex (v 2.5.35) uses this symbol to "exclude" unistd.h
 */
#ifdef _WIN32
#define YY_NO_UNISTD_H
#endif

%}

comment_start "<!--"
comment_stop "-->"

start_xmlpi "<?"

location_xmlpi "wireshark:location"
protocol_xmlpi "wireshark:protocol"

get_attr_quote =[:blank:]*["]
avoid_editor_bug ["]

get_location_xmlpi  [^[:blank:]]+

stop_xmlpi "?>"

notation_tag       "<!"[:blank:]*NOTATION

special_start  "<!"
special_stop   ">"
whitespace     [[:blank:]\r\n]+
newline        \n
attlist_kw     ATTLIST
doctype_kw     DOCTYPE
element_kw     ELEMENT

pcdata         #PCDATA
any            ANY
cdata          #CDATA

iD             ID
idref          IDREF
idrefs         IDREFS
nmtoken        NMTOKEN
nmtokens       NMTOKENS
entity         ENTITY
entities       ENTITIES
notation       NOTATION
cdata_t        CDATA

empty          EMPTY
defaulT        #DEFAULT
fixed          #FIXED
required       #REQUIRED
implied        #IMPLIED

star           "*"
question       "?"
plus           "+"
open_parens    "("
close_parens   ")"
open_bracket   "["
close_bracket  "]"
comma          ","
pipe           "|"
dquote         ["]

name           [A-Za-z0-9][-a-zA-Z0-9_]*
dquoted        ["][^\"]*["]
squoted        ['][^\']*[']

%START DTD XMLPI LOCATION DONE PROTOCOL GET_ATTR_QUOTE GET_ATTR_VAL GET_ATTR_CLOSE_QUOTE IN_COMMENT IN_NOTATION
%%

{whitespace}            ;


<DTD>{comment_start}		{ BEGIN IN_COMMENT; }
<IN_COMMENT>[^-]?				|
<IN_COMMENT>[-]					;
<IN_COMMENT>{comment_stop}		{ BEGIN DTD; }

<DTD>{notation_tag} { BEGIN IN_NOTATION; }
<IN_NOTATION>[^>]  ;
<IN_NOTATION>{special_stop} { BEGIN DTD; }

<DTD>{start_xmlpi}		{
	BEGIN XMLPI;
}

<XMLPI>{location_xmlpi} {
	BEGIN LOCATION;
}

<XMLPI>{protocol_xmlpi} {
	BEGIN PROTOCOL;
}

<XMLPI><.> ;
<XMLPI>{stop_xmlpi} BEGIN DTD;

<LOCATION>{get_location_xmlpi} {
    if(location) g_free(location);
	location = g_strdup(yytext);
	BEGIN DONE;
}

<DONE>{stop_xmlpi}  BEGIN DTD;

<PROTOCOL>{name} {
	attr_name = g_ascii_strdown(yytext, -1);
	BEGIN GET_ATTR_QUOTE;
}

<GET_ATTR_QUOTE>{get_attr_quote} { BEGIN GET_ATTR_VAL; }

<GET_ATTR_QUOTE>. {
	g_string_append_printf(build_data->error,
					"error in wireshark:protocol xmpli at %s : could not find attribute value!",
					location);
	yyterminate();
}

<GET_ATTR_VAL>[^"]+ {
	/*"*/
	struct _proto_xmlpi_attr* pa;
	gboolean got_it = FALSE;

	for(pa = proto_attrs; pa->name; pa++) {
		if (g_ascii_strcasecmp(attr_name,pa->name) == 0) {
			pa->act(yytext);
			got_it = TRUE;
			break;
		}
	}

	if (! got_it) {
		g_string_append_printf(build_data->error,
						"error in wireshark:protocol xmpli at %s : no such parameter %s!",
						location, attr_name);
		g_free(attr_name);
		yyterminate();
	}

	g_free(attr_name);

	BEGIN GET_ATTR_CLOSE_QUOTE;
}

<GET_ATTR_CLOSE_QUOTE>{dquote} { BEGIN PROTOCOL;}

<PROTOCOL>{stop_xmlpi} BEGIN DTD;

<DTD>{special_start}         { DTD_PARSE(TOKEN_TAG_START); }
<DTD>{special_stop}          { DTD_PARSE(TOKEN_TAG_STOP); }

<DTD>{attlist_kw}            { DTD_PARSE(TOKEN_ATTLIST_KW); }
<DTD>{element_kw}            { DTD_PARSE(TOKEN_ELEMENT_KW); }
<DTD>{doctype_kw}            { DTD_PARSE(TOKEN_DOCTYPE_KW); }

<DTD>{pcdata}                { DTD_PARSE(TOKEN_ELEM_DATA); }
<DTD>{any}                   { DTD_PARSE(TOKEN_ELEM_DATA); }
<DTD>{cdata}                 { DTD_PARSE(TOKEN_ELEM_DATA); }
<DTD>{empty}				 { DTD_PARSE(TOKEN_EMPTY_KW); }

<DTD>{iD}			         { DTD_PARSE(TOKEN_ATT_TYPE); }
<DTD>{idref}                 { DTD_PARSE(TOKEN_ATT_TYPE); }
<DTD>{idrefs}                { DTD_PARSE(TOKEN_ATT_TYPE); }
<DTD>{nmtoken}               { DTD_PARSE(TOKEN_ATT_TYPE); }
<DTD>{nmtokens}              { DTD_PARSE(TOKEN_ATT_TYPE); }
<DTD>{entity}                { DTD_PARSE(TOKEN_ATT_TYPE); }
<DTD>{entities}              { DTD_PARSE(TOKEN_ATT_TYPE); }
<DTD>{notation}              { DTD_PARSE(TOKEN_ATT_TYPE); }
<DTD>{cdata_t}               { DTD_PARSE(TOKEN_ATT_TYPE); }
<DTD>{defaulT}               { DTD_PARSE(TOKEN_ATT_DEF_WITH_VALUE); }
<DTD>{fixed}                 { DTD_PARSE(TOKEN_ATT_DEF_WITH_VALUE); }
<DTD>{required}              { DTD_PARSE(TOKEN_ATT_DEF); }
<DTD>{implied}               { DTD_PARSE(TOKEN_ATT_DEF); }

<DTD>{star}                  { DTD_PARSE(TOKEN_STAR); }
<DTD>{question}              { DTD_PARSE(TOKEN_QUESTION); }
<DTD>{plus}                  { DTD_PARSE(TOKEN_PLUS); }
<DTD>{comma}                  { DTD_PARSE(TOKEN_COMMA); }
<DTD>{open_parens}           { DTD_PARSE(TOKEN_OPEN_PARENS); }
<DTD>{close_parens}          { DTD_PARSE(TOKEN_CLOSE_PARENS); }
<DTD>{open_bracket}          { DTD_PARSE(TOKEN_OPEN_BRACKET); }
<DTD>{close_bracket}         { DTD_PARSE(TOKEN_CLOSE_BRACKET); }
<DTD>{pipe}                  { DTD_PARSE(TOKEN_PIPE); }

<DTD>{dquoted}               |
<DTD>{squoted}               { DTD_PARSE(TOKEN_QUOTED); }
<DTD>{name}                  { DTD_PARSE(TOKEN_NAME); }

%%

static dtd_token_data_t* new_token(gchar* text) {
	dtd_token_data_t* t = g_new(dtd_token_data_t,1);

	t->text = g_strdup(text);
	t->location = g_strdup(location);

	return t;
}


static size_t my_yyinput(char* buff, size_t size) {

	if (offsetx >= len ) {
		return YY_NULL;
	} else if ( offsetx + size <= len ) {
		memcpy(buff, input_string->str + offsetx,size);
		offsetx += size;
		return size;
	} else {
		size = len - offsetx;
		memcpy(buff, input_string->str + offsetx,size);
		offsetx = len;
		return size;
	}
}

extern dtd_build_data_t* dtd_parse(GString* s) {

	input_string = s;
	offsetx = 0;
	len = input_string->len;

	pParser = DtdParseAlloc(g_malloc);

#ifdef DEBUG_DTD_PARSER
	DtdParseTrace(stderr, ">>");
#endif

	build_data = g_new(dtd_build_data_t,1);

	build_data->proto_name = NULL;
	build_data->media_type = NULL;
	build_data->description = NULL;
	build_data->proto_root = NULL;
	build_data->recursion = FALSE;

	build_data->elements = g_ptr_array_new();
	build_data->attributes = g_ptr_array_new();

	build_data->error = g_string_new("");

	location = NULL;

	BEGIN DTD;

	yylex();

	DtdParse(pParser, 0, NULL,build_data);

	yyrestart(NULL);

	if (location) g_free(location);

	location = NULL;

	DtdParseFree(pParser, g_free );

	return build_data;
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
