/* packet-ppcap.c
 * Copyright 2012, 2014, Ericsson AB
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
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 */

#include "config.h"
#include <epan/packet.h>
#include "packet-mtp3.h"
#include <epan/prefs.h>

#define INVALID_SSN	0xff

#define PPCAP_REV_DOC_PC1 1
#define PPCAP_REV_DOC_2014_MAR 2


static const enum_val_t rev_doc[]  = {
{ "rev pc1",	"FDTs 2012 Rev PC1",	PPCAP_REV_DOC_PC1 },
{ "rev ",		"FDTS 2014 Rev", 		PPCAP_REV_DOC_2014_MAR },
{ NULL,		NULL,		0}
};


void proto_register_ppcap(void);

static gint global_ppcap_rev_doc = PPCAP_REV_DOC_2014_MAR;

static guint8 ssn;

static dissector_handle_t ppcap_handle;
static dissector_handle_t mtp3_handle;  /* MTP3 handle */
static dissector_handle_t tcap_handle;  /* TCAP handle */
static dissector_handle_t bssap_handle; /* BSSAP handle */
static dissector_handle_t ranap_handle; /* RANAP handle */
static dissector_handle_t h248_handle;  /* H248 handle */
static dissector_handle_t sip_handle;   /* SIP handle  */
static dissector_handle_t sccp_handle;  /* SCCP handle */
static dissector_handle_t data_handle;  /* DATA handle */

static dissector_table_t sccp_ssn_dissector_table;

static mtp3_addr_pc_t* mtp3_addr_opc;
static mtp3_addr_pc_t* mtp3_addr_dpc;

static gint ett_ppcap = -1;
static gint ett_ppcap1 = -1;
static gint ett_ppcap_new = -1;

static const value_string payload_tag_values[] = {
	{  1,	"Payload Type"},
	{  2,	"Payload Data"},
	{  3,	"Source Address"},
	{  4,	"Destination Address"},
	{  5,	"Local Port"},
	{  6,	"Remote Port"},
	{  7,	"Transfer Protocol for SIP/SIP-I message"},
	{256,	"Info String"},
	{0,	NULL},

};

static const value_string address_type_values[] = {
	{1,	"SSN+SPC"},
	{2,	"SPC"},
	{3,	"IP Address"},
	{4,	"Node Id"},
	{0,	NULL},

};

/* Initialise the header fields */

static int proto_ppcap= -1;
static int hf_ppcap_length = -1;
static int hf_ppcap_payload_type = -1;
static int hf_ppcap_ssn = -1;
static int hf_ppcap_spc = -1;
static int hf_ppcap_ssn1 = -1;
static int hf_ppcap_spc1 = -1;
static int hf_ppcap_opc = -1;
static int hf_ppcap_dpc = -1;
static int hf_ppcap_source_nodeid = -1;
static int hf_ppcap_destination_nodeid = -1;
/*static int hf_ppcap_source_address_type = -1; */
/*static int hf_ppcap_destination_address_type = -1; */
static int hf_ppcap_address_type = -1;
static int hf_ppcap_source_ip_address1 = -1;
static int hf_ppcap_source_ip_address2 = -1;
static int hf_ppcap_destination_ip_address1 = -1;
static int hf_ppcap_destination_ip_address2 = -1;
static int hf_ppcap_reserved = -1;
static int hf_ppcap_destreserved = -1;
static int hf_ppcap_info = -1;
static int hf_ppcap_payload_data = -1;
static int hf_ppcap_local_port = -1;
static int hf_ppcap_remote_port = -1;
static int hf_ppcap_tcp_sip_type = -1;

/* Initiliaze the subtree pointers*/

void proto_reg_handoff_ppcap(void);


/* PPCAP payload types */
typedef enum {
	PPCAP_UNKNOWN = 0,
	PPCAP_MTP3    = 1,
	PPCAP_TCAP    = 2,
	PPCAP_BSSAP   = 3,
	PPCAP_RANAP   = 4,
	PPCAP_H248    = 5,
	PPCAP_SIP     = 6,
	PPCAP_SCCP    = 7
} payload_type_type;

static int dissect_ppcap_payload_type(tvbuff_t *, proto_tree *, int, payload_type_type *);
static int dissect_ppcap_source_address(tvbuff_t *, packet_info *, proto_tree *, int);
static int dissect_ppcap_destination_address(tvbuff_t *, packet_info *, proto_tree *, int);
static int dissect_ppcap_info_string(tvbuff_t *, proto_tree *, int);
static int dissect_ppcap_local_port(tvbuff_t *, proto_tree *, int);
static int dissect_ppcap_remote_port(tvbuff_t *,proto_tree *, int);
static int dissect_ppcap_tcp_sip_msg(tvbuff_t *,proto_tree *, int);
static int dissect_ppcap_payload_data(tvbuff_t *, packet_info *, proto_tree *, int, proto_tree *, payload_type_type);

/*Dissecting the function PPCAP */

static void
dissect_ppcap(tvbuff_t *tvb, packet_info *pinfo, proto_tree *tree)
{
	proto_item *ti;
	proto_tree *ppcap_tree, *ppcap_tree1;
	guint16 msg_type;
	int offset = 0;
	payload_type_type payload_type = PPCAP_UNKNOWN;

	col_set_str(pinfo->cinfo, COL_PROTOCOL, "PPCAP");
	col_clear(pinfo->cinfo, COL_INFO);

	ti = proto_tree_add_item(tree, proto_ppcap, tvb, 0, -1, ENC_NA);
	ppcap_tree = proto_item_add_subtree(ti, ett_ppcap);

	while (tvb_reported_length_remaining(tvb, offset) > 0)
	{
		msg_type = tvb_get_ntohs(tvb, offset);
		ppcap_tree1 = proto_tree_add_subtree(ppcap_tree, tvb, offset, 2, ett_ppcap1, NULL,
					val_to_str(msg_type, payload_tag_values, "Unknown PPCAP message type (%u)"));
		offset  = offset + 2;
		switch (msg_type) {
		case 1:
			payload_type = PPCAP_UNKNOWN;
			offset = dissect_ppcap_payload_type(tvb, ppcap_tree1, offset, &payload_type);
			break;
		case 2:
			offset = dissect_ppcap_payload_data(tvb, pinfo, ppcap_tree1, offset, tree, payload_type);
			break;
		case 3:
			offset = dissect_ppcap_source_address(tvb, pinfo, ppcap_tree1, offset);
			break;
		case 4:
			offset = dissect_ppcap_destination_address(tvb, pinfo, ppcap_tree1, offset);
			break;
		case 5:
			if(global_ppcap_rev_doc == PPCAP_REV_DOC_2014_MAR)
			offset = dissect_ppcap_local_port(tvb,ppcap_tree1, offset);
			break;
		case 6:
			if(global_ppcap_rev_doc == PPCAP_REV_DOC_2014_MAR)
			offset = dissect_ppcap_remote_port(tvb,ppcap_tree1, offset);
			break;
		case 7:
			if(global_ppcap_rev_doc == PPCAP_REV_DOC_2014_MAR)
			offset = dissect_ppcap_tcp_sip_msg(tvb,ppcap_tree1, offset);
			break;
		case 256:
			if(global_ppcap_rev_doc == PPCAP_REV_DOC_PC1)
			offset = dissect_ppcap_info_string(tvb, ppcap_tree1, offset);
			break;
		}
	}
}


/* Dissecting the function Payload type to compare the protocol type */

/*
  *******************************************************
  *               Payload Type                          *
  *                                                     *
  *******************************************************
*/



static int
dissect_ppcap_payload_type(tvbuff_t *tvb, proto_tree * ppcap_tree1, int offset, payload_type_type *payload_type)
{
	char *string;
	guint16 msg_len =0;
	msg_len = tvb_get_ntohs(tvb, offset);
	proto_tree_add_item( ppcap_tree1, hf_ppcap_length, tvb, offset, 2, ENC_BIG_ENDIAN);
	offset  = offset + 2;
	string = tvb_get_string_enc(wmem_packet_scope(), tvb, offset, msg_len, ENC_UTF_8|ENC_NA);
	if (strcmp(string,"mtp3") == 0) {
		*payload_type = PPCAP_MTP3;
	}else if (strcmp(string,"tcap")  == 0) {
		*payload_type = PPCAP_TCAP;
	}else if (strcmp(string,"bssap") == 0) {
		*payload_type = PPCAP_BSSAP;
	}else if (strcmp(string,"ranap") == 0) {
		*payload_type = PPCAP_RANAP;
	}else if (strcmp(string,"h248")  == 0) {
		*payload_type = PPCAP_H248;
	}else if (strcmp(string,"sip")   == 0) {
		*payload_type = PPCAP_SIP;
	}else if (strcmp(string,"sccp")  == 0) {
		*payload_type = PPCAP_SCCP;
	}

	proto_tree_add_item(ppcap_tree1, hf_ppcap_payload_type, tvb, offset, msg_len, ENC_UTF_8|ENC_NA);

	if (msg_len%4)
		msg_len = msg_len+(4-(msg_len%4));
	offset += msg_len;
	return offset;
}

/* Dissecting the function Source Address */

/*

  *******************************************************
  *	Reserved	*	Address Type		*
  *				*			*
  *******************************************************
  *	          Address Value				*
  *							*
  *******************************************************
*/

static int
dissect_ppcap_source_address(tvbuff_t *tvb, packet_info *pinfo, proto_tree * ppcap_tree1, int offset)
{
	int key1;
	guint16 msg_len;
	msg_len = tvb_get_ntohs(tvb, offset);
	proto_tree_add_item( ppcap_tree1, hf_ppcap_length, tvb, offset, 2, ENC_BIG_ENDIAN);
	offset  = offset + 2;
	proto_tree_add_item(ppcap_tree1, hf_ppcap_reserved, tvb, offset, 2, ENC_BIG_ENDIAN);
	offset += 2;

	key1 = tvb_get_ntohs(tvb, offset);
	proto_tree_add_item(ppcap_tree1, hf_ppcap_address_type, tvb, offset, 2, ENC_BIG_ENDIAN);
	offset += 2;

	if (key1 == 1)
	{
		proto_tree_add_item(ppcap_tree1, hf_ppcap_ssn, tvb, offset, 1, ENC_BIG_ENDIAN);
		offset += 1;
		proto_tree_add_item(ppcap_tree1, hf_ppcap_spc, tvb, offset, 3, ENC_BIG_ENDIAN);
		/*src_addr1 = (guint32 )tvb_get_ntoh24(tvb, offset);*/
		mtp3_addr_opc = wmem_new0(wmem_packet_scope(), mtp3_addr_pc_t);
		mtp3_addr_opc->pc = (guint32 )tvb_get_ntoh24(tvb, offset);
		mtp3_addr_opc->type = ITU_STANDARD;
		mtp3_addr_opc->ni = 0;
		/*set_address(&pinfo->net_src, AT_SS7PC, sizeof(mtp3_addr_pc_t), (guint8 *) mtp3_addr_opc);*/
		set_address(&pinfo->src, AT_SS7PC, sizeof(mtp3_addr_pc_t), (guint8 *) mtp3_addr_opc);
		if (msg_len%4)
			msg_len = msg_len + (4 - (msg_len%4));

		offset += msg_len-1;
		return offset;
	}
	else if (key1 == 2)
	{
		proto_tree_add_item(ppcap_tree1, hf_ppcap_opc, tvb, offset, msg_len, ENC_BIG_ENDIAN);

		/*src_addr1 = (guint32 )tvb_get_ntoh24(tvb, offset);*/
		mtp3_addr_opc = wmem_new0(wmem_packet_scope(), mtp3_addr_pc_t);
		mtp3_addr_opc->pc = tvb_get_ntohl(tvb, offset);
		mtp3_addr_opc->type = ITU_STANDARD;
		mtp3_addr_opc->ni = 0;
		set_address(&pinfo->src, AT_SS7PC, sizeof(mtp3_addr_pc_t), (guint8 *) mtp3_addr_opc);
	}
	else if (key1 == 3)
	{
		if (msg_len%16 != 0)
		{

			proto_tree_add_item(ppcap_tree1, hf_ppcap_source_ip_address1, tvb, offset, msg_len, ENC_NA);
			set_address_tvb(&pinfo->net_src, AT_IPv4, 4, tvb, offset);
			copy_address_shallow(&pinfo->src, &pinfo->net_src);
		}
		else
		{
			proto_tree_add_item(ppcap_tree1, hf_ppcap_source_ip_address2, tvb, offset, msg_len, ENC_NA);
			set_address_tvb(&pinfo->net_src, AT_IPv6, 6, tvb, offset);
			copy_address_shallow(&pinfo->src, &pinfo->net_src);
		}
	}

	else if (key1 == 4)

	{
		proto_tree_add_item(ppcap_tree1, hf_ppcap_source_nodeid, tvb, offset, msg_len, ENC_ASCII|ENC_NA);
		set_address_tvb(&pinfo->net_src, AT_STRINGZ, msg_len, tvb, offset);
		copy_address_shallow(&pinfo->src, &pinfo->net_src);
	}
	if (msg_len%4)
		msg_len = msg_len + (4 - (msg_len%4));
	offset += msg_len;
	return offset;
}

/* Dissecting the function Destination Address */

/*
  *******************************************************
  *     Reserved        *       Address Type            *
  *                     *                               *
  *******************************************************
  *               Address Value                         *
  *                                                     *
  *******************************************************
*/


static int
dissect_ppcap_destination_address(tvbuff_t *tvb, packet_info * pinfo, proto_tree * ppcap_tree1, int offset)
{
	int key2;
	guint16 msg_len;
	msg_len = tvb_get_ntohs(tvb, offset);
	proto_tree_add_item( ppcap_tree1, hf_ppcap_length, tvb, offset, 2, ENC_BIG_ENDIAN);
	offset  = offset + 2;
	proto_tree_add_item(ppcap_tree1, hf_ppcap_destreserved, tvb, offset, 2, ENC_BIG_ENDIAN);
	offset += 2;

	key2 = tvb_get_ntohs(tvb, offset);
	proto_tree_add_item(ppcap_tree1, hf_ppcap_address_type, tvb, offset, 2, ENC_BIG_ENDIAN);
	offset += 2;

	if (key2 == 1)
	{
		ssn = tvb_get_guint8(tvb, offset);
		proto_tree_add_item(ppcap_tree1, hf_ppcap_ssn1, tvb, offset, 1, ENC_BIG_ENDIAN);
		offset += 1;

		proto_tree_add_item(ppcap_tree1, hf_ppcap_spc1, tvb, offset, 3, ENC_BIG_ENDIAN);

		/*dst_addr1 = (guint32 )tvb_get_ntoh24(tvb, offset);*/
		mtp3_addr_dpc = wmem_new0(wmem_packet_scope(), mtp3_addr_pc_t);
		mtp3_addr_dpc->pc = (guint32)tvb_get_ntoh24(tvb, offset);
		mtp3_addr_dpc->type = ITU_STANDARD;
		mtp3_addr_dpc->ni = 0;
		set_address(&pinfo->dst, AT_SS7PC, sizeof(mtp3_addr_pc_t), (guint8 *) mtp3_addr_dpc);

		if (msg_len%4)
			msg_len = msg_len + (4 - (msg_len%4));

		offset += msg_len-1;
		return offset;

	}
	else if (key2 == 2)
	{
		proto_tree_add_item(ppcap_tree1, hf_ppcap_dpc, tvb, offset, 4, ENC_BIG_ENDIAN);

		/*dst_addr1 = (guint32 )tvb_get_ntoh24(tvb, offset);*/
		mtp3_addr_dpc = wmem_new0(wmem_packet_scope(), mtp3_addr_pc_t);
		mtp3_addr_dpc->pc = tvb_get_ntohl(tvb, offset);
		mtp3_addr_dpc->type = ITU_STANDARD;
		mtp3_addr_dpc->ni = 0;
		set_address(&pinfo->dst, AT_SS7PC, sizeof(mtp3_addr_pc_t), (guint8 *) mtp3_addr_dpc);
	}
	else if (key2 == 3)
	{
		if (msg_len%16 != 0)
		{
			proto_tree_add_item(ppcap_tree1, hf_ppcap_destination_ip_address1, tvb, offset, msg_len, ENC_NA);
			set_address_tvb(&pinfo->net_dst, AT_IPv4, 4, tvb, offset);
			copy_address_shallow(&pinfo->dst, &pinfo->net_dst);
		}
		else
		{
			proto_tree_add_item(ppcap_tree1, hf_ppcap_destination_ip_address2, tvb, offset, msg_len, ENC_NA);
			set_address_tvb(&pinfo->net_dst, AT_IPv6, 6, tvb, offset);
			copy_address_shallow(&pinfo->dst, &pinfo->net_dst);
		}
	}

	else if (key2 == 4)
	{
		char *string;
		string = tvb_get_string_enc(wmem_packet_scope(), tvb, offset, msg_len, ENC_UTF_8|ENC_NA);
		proto_tree_add_string(ppcap_tree1, hf_ppcap_destination_nodeid, tvb, offset, msg_len, string);
		set_address_tvb(&pinfo->net_dst, AT_STRINGZ, msg_len, tvb, offset);
		copy_address_shallow(&pinfo->dst, &pinfo->net_dst);
	}

	if (msg_len%4)
		msg_len = msg_len+(4-(msg_len%4));

	offset += msg_len;

	return offset;
}

/* Dissecting the function Info String */

/*
  *******************************************************
  *               Info                        		*
  *                                                     *
  *******************************************************
*/

static int
dissect_ppcap_info_string(tvbuff_t *tvb, proto_tree * ppcap_tree1, int offset)
{
	guint16 msg_len;
	msg_len = tvb_get_ntohs(tvb, offset);
	proto_tree_add_item( ppcap_tree1, hf_ppcap_length, tvb, offset, 2, ENC_BIG_ENDIAN);
	offset  = offset + 2;
	proto_tree_add_item(ppcap_tree1, hf_ppcap_info, tvb, offset, msg_len, ENC_ASCII|ENC_NA);

	if (msg_len%4)
		msg_len = msg_len +( 4- (msg_len%4));
	offset += msg_len;
	return offset;
}

/* Dissecting the function Local Port */

/*
  *******************************************************
  *               Local Port                            *
  *                                                     *
  *******************************************************
*/
static int
dissect_ppcap_local_port(tvbuff_t *tvb,proto_tree * ppcap_tree1, int offset)
{
	proto_tree_add_item(ppcap_tree1,hf_ppcap_local_port,tvb,offset,2,ENC_BIG_ENDIAN);
	offset = offset+6;      /*Adding offset of filler bytes without text*/
	return offset;
}

/* Dissecting the function Remote Port */

/*
  *******************************************************
  *               Remote Port                           *
  *                                                     *
  *******************************************************
*/

static int
dissect_ppcap_remote_port(tvbuff_t *tvb,proto_tree * ppcap_tree1, int offset)
{
	proto_tree_add_item(ppcap_tree1,hf_ppcap_remote_port,tvb,offset,2,ENC_BIG_ENDIAN);
	offset = offset+6;      /*Adding offset of filler bytes without text*/
	return offset;
}

/* Dissecting the function TCP SIP Message */

/*
  *******************************************************
  *               TCP SIP MESSAGE                       *
  *                                                     *
  *******************************************************
*/

static int
dissect_ppcap_tcp_sip_msg(tvbuff_t *tvb,proto_tree * ppcap_tree1, int offset)
{
	proto_tree_add_item( ppcap_tree1, hf_ppcap_length, tvb, offset, 2, ENC_BIG_ENDIAN);
	offset  = offset + 2;
	proto_tree_add_item(ppcap_tree1, hf_ppcap_tcp_sip_type, tvb, offset, 4, ENC_ASCII|ENC_NA);
	offset += 4;
	return offset;
}


/* Dissecting the function Payload Data to call the protocol that based upon the type decided in the Payload Type */

/*
  *******************************************************
  *               Payload Data                          *
  *                                                     *
  *******************************************************
*/


static int
dissect_ppcap_payload_data(tvbuff_t *tvb, packet_info *pinfo, proto_tree * ppcap_tree1, int offset, proto_tree *tree, payload_type_type payload_type)
{
	tvbuff_t        *next_tvb;
	guint16 msg_len;
	msg_len = tvb_get_ntohs(tvb, offset);
	proto_tree_add_item( ppcap_tree1, hf_ppcap_length, tvb, offset, 2, ENC_BIG_ENDIAN);
	offset  = offset + 2;
	proto_tree_add_item(ppcap_tree1, hf_ppcap_payload_data, tvb, offset, msg_len, ENC_NA);

	if (msg_len%4)
		msg_len = msg_len +( 4- (msg_len%4));

	next_tvb = tvb_new_subset_remaining(tvb, offset);

	switch (payload_type) {
	case PPCAP_MTP3:
		call_dissector(mtp3_handle, next_tvb, pinfo, tree);  /* calling the MTP3 handle */
		break;
	case PPCAP_TCAP:
		/*
		 * The protocol which runs on TCAP takes the SSN value from the SCCP layer which is missing in this case.
		 * So we have made code changes for TCAP handle as below for taking the SSN value from ppcap.
		 */
		if (ssn != INVALID_SSN && dissector_try_uint(sccp_ssn_dissector_table, ssn, next_tvb, pinfo, tree))	{
			return  offset+msg_len;
		}else{
			call_dissector(tcap_handle, next_tvb, pinfo, tree);  /* calling the TCAP handle */
		}
		break;
	case PPCAP_BSSAP:
		call_dissector(bssap_handle, next_tvb, pinfo, tree);  /* calling the BSSAP handle */
		break;
	case PPCAP_RANAP:
		call_dissector(ranap_handle, next_tvb, pinfo, tree);  /* calling the RANAP handle */
		break;
	case PPCAP_H248:
		call_dissector(h248_handle, next_tvb, pinfo, tree);   /* calling the H248 handle */
		break;
	case PPCAP_SIP:
		call_dissector(sip_handle, next_tvb, pinfo, tree);    /* calling the SIP handle */
		break;
	case PPCAP_SCCP:
		call_dissector(sccp_handle, next_tvb, pinfo, tree);   /* calling the SCCP handle */
		break;
	default:
		call_dissector(data_handle, next_tvb, pinfo, tree);   /* calling the DATA handle */
		break;
	}

	offset += msg_len;
	return offset;
}

/* Registering the hf variables */

void proto_register_ppcap(void)
{
module_t *ppcap_module;

	static hf_register_info hf[] = {
	{ &hf_ppcap_length,
	{ "Length",         "ppcap.length",
		FT_UINT16, BASE_DEC, NULL,   0x00, NULL, HFILL}},
	{ &hf_ppcap_payload_type,
	{ "Payload Type" , "ppcap.payload_type", FT_STRING,
		BASE_NONE, 	NULL, 	0x0    , NULL,    HFILL}},
	{ &hf_ppcap_reserved,
	{ "Reserved",         "ppcap.reserved",    FT_UINT16,
		BASE_DEC,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_address_type,
	{ "Address Type",         "ppcap.address_type",    FT_UINT16,
		BASE_DEC,    VALS(address_type_values),         0x00 , NULL, HFILL}},
#if 0
	{ &hf_ppcap_source_address_type,
	{ "Source Address Type",         "ppcap.source_address_type",    FT_UINT16,
		BASE_DEC,    VALS(address_type_values),         0x00 , NULL, HFILL}},
#endif
	{ &hf_ppcap_ssn,
	{ "SSN",     "ppcap.ssn",   FT_UINT16,
		BASE_DEC,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_spc,
	{"OPC",     "ppcap.spc",   FT_UINT16,
		BASE_DEC,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_opc,
	{ "OPC",     "ppcap.opc",   FT_UINT16,
		BASE_DEC,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_source_ip_address1,
	{ "Source IP Address",     "ppcap.source_ip_address1",   FT_IPv4,
		BASE_NONE,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_source_ip_address2,
	{ "Source IP Address",     "ppcap.source_ip_address2",   FT_IPv6,
		BASE_NONE,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_destreserved,
	{ "Reserved",         "ppcap.destreserved",    FT_UINT16,
		BASE_DEC,       NULL,   0x00,   NULL,     HFILL}},
#if 0
	{ &hf_ppcap_destination_address_type,
	{ "Destination Address Type",         "ppcap.destination_address_type",    FT_UINT16,
		BASE_DEC,      VALS(address_type_values),   0x00,   NULL,     HFILL}},
#endif
	{ &hf_ppcap_ssn1,
	{ "SSN",     "ppcap.ssn1",   FT_UINT8,
		BASE_DEC,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_spc1,
	{ "DPC",     "ppcap.spc1",   FT_UINT24,
		BASE_DEC,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_dpc,
	{ "DPC",     "ppcap.dpc",   FT_UINT32,
		BASE_DEC,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_destination_ip_address1,
	{ "Destination IP Address",     "ppcap.destination_ip_address1",   FT_IPv4,
		BASE_NONE,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_destination_ip_address2,
	{ "Destination IP Address",     "ppcap.destination_ip_address2",   FT_IPv6,
		BASE_NONE,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_source_nodeid,
	{ "Source Node ID",         "ppcap.source_nodeid",    FT_STRING,
		BASE_NONE,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_destination_nodeid,
	{ "Destination Node ID",         "ppcap.destination_address",    FT_STRING,
		BASE_NONE,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_info,
	{ "Info",         "ppcap.info",    FT_STRING,
		BASE_NONE,       NULL,   0x0000,   NULL,     HFILL}},
	{ &hf_ppcap_payload_data,
	{ "Payload Data",         "ppcap.payload_data",    FT_BYTES,
		BASE_NONE,       NULL,   0x0000,   NULL,     HFILL}},
	{ &hf_ppcap_local_port,
	{ "Local Port",         "ppcap.local_port",    FT_UINT16,
		BASE_DEC,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_remote_port,
	{ "Remote Port",         "ppcap.remote_port",    FT_UINT16,
		BASE_DEC,       NULL,   0x00,   NULL,     HFILL}},
	{ &hf_ppcap_tcp_sip_type,
	{ "Transport Protocol for SIP/SIP-I Message" , "ppcap.tcp_sip_type", FT_STRING,
		BASE_NONE,      NULL,   0x0    , NULL,    HFILL}},
	};

	static gint *ett[]= {
		&ett_ppcap,
		&ett_ppcap1,
		&ett_ppcap_new,
	};
	proto_ppcap = proto_register_protocol("Proprietary PCAP", "PPCAP", "ppcap");
	proto_register_field_array(proto_ppcap , hf , array_length(hf));
	proto_register_subtree_array(ett, array_length(ett));
	register_dissector("ppcap", dissect_ppcap, proto_ppcap);
	ppcap_module = prefs_register_protocol(proto_ppcap, proto_reg_handoff_ppcap);
	prefs_register_enum_preference(ppcap_module,"rev_doc","PPCAP, Select the document","Select Document",&global_ppcap_rev_doc,rev_doc,TRUE);

}

void proto_reg_handoff_ppcap(void)
{
	ppcap_handle = find_dissector("ppcap");
	mtp3_handle  = find_dissector("mtp3");  /* calling the protocol MTP3 */
	tcap_handle  = find_dissector("tcap");  /* calling the protocol TCAP */
	bssap_handle = find_dissector("bssap"); /* calling the protocol BSSAP */
	ranap_handle = find_dissector("ranap"); /* calling the protocol RANAP */
	h248_handle  = find_dissector("h248");  /* calling the protocol H248 */
	sip_handle   = find_dissector("sip");   /* calling the protocol SIP */
	sccp_handle  = find_dissector("sccp");  /* calling the protocol SCCP */
	data_handle  = find_dissector("data");  /* calling the protocol DATA */

	sccp_ssn_dissector_table = find_dissector_table("sccp.ssn");

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
