/**
	DNS wire format encoding and decoding.

	Copyright: © 2012-2016 Sönke Ludwig
	Authors: Bogdan Szabo
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.dns;

import vibe.core.net : listenUDP, UDPConnection;
import core.time : Duration, seconds;
import std.algorithm : filter, map;
import std.array : array, join;
import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.exception : enforce;
import std.file : readText, exists;
import std.random : uniform;
import std.string : split;

version (Windows) pragma(lib, "iphlpapi");

@safe:

/// Fixed length in bytes of the DNS message header preceding the question section.
private enum size_t dnsHeaderLength = 12;

/// High bits in a label-length byte marking it as a compression pointer.
private enum ubyte dnsPointerFlag = 0xC0;

/// Mask selecting the 14-bit offset carried by a compression pointer.
private enum ushort dnsPointerOffsetMask = 0x3FFF;

/// DNS resource-record TYPE codes, named by their IANA-assigned values.
enum DNSRecordType : ushort {
	A = 1, ///< IPv4 host address
	NS = 2, ///< Authoritative name server for the zone
	MD = 3, ///< Mail destination (obsolete, use MX)
	MF = 4, ///< Mail forwarder (obsolete, use MX)
	CNAME = 5, ///< Canonical name alias for another domain
	SOA = 6, ///< Start of authority, zone's authoritative metadata
	MB = 7, ///< Mailbox domain name (experimental)
	MG = 8, ///< Mail group member (experimental)
	MR = 9, ///< Mail rename domain name (experimental)
	NULL = 10, ///< Placeholder record holding arbitrary data (experimental)
	WKS = 11, ///< Well-known service description for a host
	PTR = 12, ///< Domain name pointer, used for reverse DNS lookups
	HINFO = 13, ///< Host CPU and operating system information
	MINFO = 14, ///< Mailbox or mailing-list information
	MX = 15, ///< Mail exchange server with a preference value
	TXT = 16, ///< Arbitrary descriptive text strings
	RP = 17, ///< Responsible person mailbox for the domain
	AFSDB = 18, ///< AFS cell database server location
	X25 = 19, ///< X.25 PSDN address
	ISDN = 20, ///< ISDN address
	RT = 21, ///< Route-through binding to an intermediate host
	NSAP = 22, ///< NSAP address for ISO-protocol mapping
	NSAP_PTR = 23, ///< NSAP-style reverse pointer (obsolete)
	SIG = 24, ///< Cryptographic signature (obsolete, use RRSIG)
	KEY = 25, ///< Public key record (obsolete, use DNSKEY)
	PX = 26, ///< X.400-to-RFC822 mail mapping pointer
	GPOS = 27, ///< Geographical position (obsolete, use LOC)
	AAAA = 28, ///< IPv6 host address
	LOC = 29, ///< Geographic location of the host
	NXT = 30, ///< Next-domain record (obsolete, use NSEC)
	EID = 31, ///< Endpoint identifier (Nimrod)
	NIMLOC = 32, ///< Nimrod locator
	SRV = 33, ///< Service location with priority, weight and port
	ATMA = 34, ///< ATM address
	NAPTR = 35, ///< Naming authority pointer for regex-based rewriting
	KX = 36, ///< Key exchanger for the domain
	CERT = 37, ///< Stored certificate or CRL
	A6 = 38, ///< IPv6 address (obsolete, use AAAA)
	DNAME = 39, ///< Non-terminal name redirection of an entire subtree
	SINK = 40, ///< Kitchen-sink experimental record
	OPT = 41, ///< EDNS pseudo-record carrying extension options
	APL = 42, ///< Address prefix list
	DS = 43, ///< Delegation signer, hash of a delegated zone's key
	SSHFP = 44, ///< SSH public-key fingerprint
	IPSECKEY = 45, ///< IPsec public key for the host
	RRSIG = 46, ///< DNSSEC signature over a record set
	NSEC = 47, ///< Authenticated denial of existence, next secure name
	DNSKEY = 48, ///< DNSSEC public signing key for the zone
	DHCID = 49, ///< DHCP client identifier
	NSEC3 = 50, ///< Hashed authenticated denial of existence
	NSEC3PARAM = 51, ///< Parameters for NSEC3 hashing
	TLSA = 52, ///< TLS certificate association (DANE)
	SMIMEA = 53, ///< S/MIME certificate association
	HIP = 55, ///< Host identity protocol binding
	NINFO = 56, ///< Zone status information
	RKEY = 57, ///< Key for encrypted resource records
	TALINK = 58, ///< Trust anchor link
	CDS = 59, ///< Child DS record signalled to the parent
	CDNSKEY = 60, ///< Child DNSKEY signalled to the parent
	OPENPGPKEY = 61, ///< OpenPGP public key
	CSYNC = 62, ///< Child-to-parent synchronization signal
	ZONEMD = 63, ///< Message digest over the zone contents
	SVCB = 64, ///< General service binding parameters
	HTTPS = 65, ///< HTTPS-specific service binding parameters
	SPF = 99, ///< Sender policy framework (obsolete, use TXT)
	UINFO = 100, ///< User information (reserved, IANA)
	UID = 101, ///< User ID (reserved, IANA)
	GID = 102, ///< Group ID (reserved, IANA)
	UNSPEC = 103, ///< Unspecified data (reserved, IANA)
	NID = 104, ///< Node identifier for ILNP
	L32 = 105, ///< 32-bit ILNP locator
	L64 = 106, ///< 64-bit ILNP locator
	LP = 107, ///< ILNP locator pointer to L32/L64 records
	EUI48 = 108, ///< 48-bit IEEE extended unique identifier
	EUI64 = 109, ///< 64-bit IEEE extended unique identifier
	TKEY = 249, ///< Transaction key for shared-secret negotiation
	TSIG = 250, ///< Transaction signature for message authentication
	IXFR = 251, ///< Incremental zone transfer request
	AXFR = 252, ///< Full zone transfer request
	MAILB = 253, ///< Query for mailbox-related records (MB, MG, MR)
	MAILA = 254, ///< Query for mail-agent records (obsolete, use MX)
	ANY = 255, ///< Query matching all record types
	URI = 256, ///< URI mapping for the domain
	CAA = 257, ///< Certification authority authorization
	AVC = 258, ///< Application visibility and control
	DOA = 259, ///< Digital object architecture
	AMTRELAY = 260, ///< Automatic multicast tunneling relay
	TA = 32768, ///< DNSSEC trust anchor (DLV-style)
	DLV = 32769, ///< DNSSEC lookaside validation (obsolete)
}

/** A single resource record decoded from a DNS message. */
struct DNSResourceRecord {
	string name;
	DNSRecordType type;
	ubyte[] rdata;
}

/** A decoded DNS message, exposing the transaction id and its answer records. */
struct DNSMessage {
	ushort id;
	DNSResourceRecord[] answers;
}

/** A decoded SRV resource record locating a service host and port. */
struct SRVRecord {
	ushort priority;
	ushort weight;
	ushort port;
	string target;
}

/** Decodes a DNS message from its wire format.

	Params:
		msg = The complete DNS message in wire format.

	Returns:
		The decoded message with its transaction id and answer records.
*/
DNSMessage parseDNSMessage(const(ubyte)[] msg)
{
	enforce(msg.length >= dnsHeaderLength, "truncated DNS message: shorter than the header");

	auto id = readBigEndianU16(msg, 0);
	auto questionCount = readBigEndianU16(msg, 4);
	auto answerCount = readBigEndianU16(msg, 6);

	size_t cursor = dnsHeaderLength;

	foreach (_; 0 .. questionCount) {
		decodeName(msg, cursor);
		cursor += 4;
	}

	DNSResourceRecord[] answers;
	foreach (_; 0 .. answerCount) {
		enforce(cursor < msg.length, "truncated DNS message: answer record past end of buffer");
		auto name = decodeName(msg, cursor);
		auto type = cast(DNSRecordType)readBigEndianU16(msg, cursor);
		cursor += 8;
		auto rdlength = readBigEndianU16(msg, cursor);
		cursor += 2;
		enforce(cursor + rdlength <= msg.length, "truncated DNS message: rdata runs past end of buffer");
		auto rdata = msg[cursor .. cursor + rdlength].dup;
		cursor += rdlength;
		answers ~= DNSResourceRecord(name, type, rdata);
	}

	return DNSMessage(id, answers);
}

/** Splits TXT resource-record data into its length-prefixed character-strings.

	Params:
		rdata = The TXT rdata holding one or more length-prefixed strings.

	Returns:
		The decoded character-strings in order.
*/
string[] parseTXT(const(ubyte)[] rdata) pure
{
	string[] strings;

	size_t cursor = 0;
	while (cursor < rdata.length) {
		auto len = rdata[cursor];
		auto start = cursor + 1;
		enforce(start + len <= rdata.length, "malformed TXT record: chunk runs past end of rdata");
		strings ~= (cast(const(char)[])rdata[start .. start + len]).idup;
		cursor = start + len;
	}

	return strings;
}

/** Decodes an SRV record from its resource-record data.

	Params:
		rdata = The SRV rdata holding priority, weight, port and the target name.

	Returns:
		The decoded SRVRecord.
*/
SRVRecord parseSRV(const(ubyte)[] rdata) pure
{
	auto priority = readBigEndianU16(rdata, 0);
	auto weight = readBigEndianU16(rdata, 2);
	auto port = readBigEndianU16(rdata, 4);

	size_t pos = 6;
	auto target = decodeName(rdata, pos);

	return SRVRecord(priority, weight, port, target);
}

/** Returns the configured DNS nameserver addresses.

	On POSIX systems the addresses are read from `/etc/resolv.conf`, falling back
	to the systemd-resolved stub resolver `127.0.0.53` when the file is missing or
	lists no nameservers. On Windows they are obtained from the network
	configuration via `GetNetworkParams`.

	Returns:
		The nameserver addresses to query, in priority order.
*/
string[] nameservers() @trusted
{
	version (Windows)
		return windowsNameservers();
	else
		return posixNameservers();
}

version (Windows) {
	private string[] windowsNameservers() @trusted
	{
		import core.sys.windows.iphlpapi : GetNetworkParams;
		import core.sys.windows.iptypes : FIXED_INFO;
		import core.stdc.stdlib : malloc, free;
		import std.string : fromStringz;

		uint length = 0;
		GetNetworkParams(null, &length);          // sizes the buffer (returns ERROR_BUFFER_OVERFLOW)

		auto buffer = malloc(length);
		if (buffer is null)
			return null;
		scope (exit) free(buffer);

		auto info = cast(FIXED_INFO*) buffer;
		if (GetNetworkParams(info, &length) != 0) // ERROR_SUCCESS
			return null;

		string[] servers;
		for (auto entry = &info.DnsServerList; entry !is null; entry = entry.Next) {
			auto address = entry.IpAddress.String.ptr.fromStringz.idup;
			if (address.length > 0)
				servers ~= address;
		}
		return servers;
	}
} else {
	private string[] posixNameservers()
	{
		enum stubResolver = "127.0.0.53";       // systemd-resolved

		if (exists("/etc/resolv.conf")) {
			auto configured = parseResolvConf(readText("/etc/resolv.conf"));
			if (configured.length > 0)
				return configured;
		}

		return [stubResolver];
	}
}

/** Resolves a DNS query over UDP against the configured nameservers.

	A random transaction id is used and responses whose id does not match are
	rejected as potential spoofs. Each nameserver is tried in turn; a timeout or
	parse error on one falls through to the next.

	Params:
		name = The dotted domain name to query.
		type = The resource-record type being requested.
		timeout = Maximum time to wait for each nameserver's reply.

	Returns:
		The decoded DNS message from the first nameserver that answers.

	Throws:
		Exception if no nameserver returns a valid matching response.
*/
DNSMessage resolveDNS(string name, DNSRecordType type, Duration timeout = 5.seconds) @trusted
{
	ushort id = uniform!ushort;
	auto query = encodeDNSQuery(id, name, type);

	foreach (ns; nameservers()) {
		try {
			auto conn = listenUDP(0);
			conn.connect(ns, 53);
			conn.send(query);
			auto response = conn.recv(timeout);
			auto msg = parseDNSMessage(response);
			if (msg.id != id)
				continue;
			return msg;
		} catch (Exception e) {
			continue;
		}
	}

	throw new Exception("DNS resolution failed for " ~ name);
}

/** Looks up the SRV records for a service name.

	Params:
		name = The SRV service name to query (e.g. `_sip._tcp.example.com`).
		timeout = Maximum time to wait for each nameserver's reply.

	Returns:
		The decoded SRV records from the response.
*/
SRVRecord[] lookupSRV(string name, Duration timeout = 5.seconds) @trusted
{
	return resolveDNS(name, DNSRecordType.SRV, timeout)
		.answers
		.filter!(a => a.type == DNSRecordType.SRV)
		.map!(a => parseSRV(a.rdata))
		.array;
}

/** Looks up the TXT records for a domain name.

	Params:
		name = The dotted domain name to query.
		timeout = Maximum time to wait for each nameserver's reply.

	Returns:
		The character-strings of all TXT answers, flattened in order.
*/
string[] lookupTXT(string name, Duration timeout = 5.seconds) @trusted
{
	return resolveDNS(name, DNSRecordType.TXT, timeout)
		.answers
		.filter!(a => a.type == DNSRecordType.TXT)
		.map!(a => parseTXT(a.rdata))
		.join;
}

/** Encodes a recursion-desired DNS query carrying a single question.

	Params:
		id = The transaction identifier echoed back in the matching response.
		name = The dotted domain name to query.
		type = The resource-record type being requested.

	Returns:
		The complete DNS query message in wire format.
*/
package ubyte[] encodeDNSQuery(ushort id, string name, DNSRecordType type) pure
{
	enum ushort recursionDesired = 0x0100;
	enum ushort questionCount = 0x0001;
	enum ushort emptyCount = 0x0000;
	enum ushort classInternet = 0x0001;

	ubyte[] message;
	message ~= nativeToBigEndian(id);
	message ~= nativeToBigEndian(recursionDesired);
	message ~= nativeToBigEndian(questionCount);
	message ~= nativeToBigEndian(emptyCount);
	message ~= nativeToBigEndian(emptyCount);
	message ~= nativeToBigEndian(emptyCount);
	message ~= encodeName(name);
	message ~= nativeToBigEndian(cast(ushort)type);
	message ~= nativeToBigEndian(classInternet);

	return message;
}

/** Encodes a domain name into DNS wire format.

	Each non-empty dot-separated segment becomes a length-prefixed label and the
	name is terminated by a zero-length root label.

	Params:
		name = The dotted domain name to encode.

	Returns:
		The encoded label sequence including the trailing root terminator.
*/
package ubyte[] encodeName(string name) pure
{
	ubyte[] encoded;

	foreach (label; name.split('.').filter!(segment => segment.length > 0))
		encoded ~= cast(ubyte)label.length ~ cast(ubyte[])label.dup;

	return encoded ~ cast(ubyte)0;
}

/** Decodes a domain name from a DNS message at the given offset.

	Reads a sequence of length-prefixed labels and joins them with dots. A label
	whose length byte has its two high bits set (`>= dnsPointerFlag`) is a
	compression pointer into an earlier part of the message; decoding follows it
	transparently.

	Params:
		msg = The complete DNS message being decoded.
		pos = Offset of the name; on return it points just past the name (or past
			the first compression pointer, per the wire format).

	Returns:
		The decoded dotted domain name.
*/
package string decodeName(const(ubyte)[] msg, ref size_t pos) pure
{
	string[] labels;
	size_t cursor = pos;
	bool jumped = false;
	size_t pointerJumps = 0;

	while (msg[cursor] != 0) {
		if (msg[cursor] >= dnsPointerFlag) {
			auto target = readBigEndianU16(msg, cursor) & dnsPointerOffsetMask;
			enforce(target < msg.length, "invalid DNS compression pointer: target past end of message");
			pointerJumps++;
			enforce(pointerJumps <= msg.length, "DNS compression pointer cycle or limit exceeded");
			if (!jumped) {
				pos = cursor + 2;
				jumped = true;
			}
			cursor = target;
			continue;
		}

		auto labelStart = cursor + 1;
		auto labelLength = msg[cursor];
		enforce(labelStart + labelLength <= msg.length, "truncated DNS message: label runs past end of buffer");
		labels ~= (cast(const(char)[])msg[labelStart .. labelStart + labelLength]).idup;
		cursor = labelStart + labelLength;
	}

	if (!jumped)
		pos = cursor + 1;

	return labels.join('.');
}

/** Extracts the configured nameserver addresses from resolv.conf contents.

	Each line is split on whitespace; lines whose first token is `nameserver`
	contribute their second token. All other lines are ignored.

	Params:
		contents = The full text of a resolv.conf file.

	Returns:
		The nameserver addresses in the order they appear.
*/
package string[] parseResolvConf(string contents) pure
{
	import std.algorithm : splitter;
	import std.string : strip, split;

	string[] nameservers;

	foreach (line; contents.splitter('\n')) {
		auto tokens = line.strip.split;
		if (tokens.length < 2 || tokens[0] != "nameserver")
			continue;
		nameservers ~= tokens[1];
	}

	return nameservers;
}

/** Reads a big-endian 16-bit unsigned integer from a byte buffer.

	Params:
		data = The buffer to read from.
		offset = Byte offset of the most significant byte.

	Returns:
		The decoded host-order value.
*/
package ushort readBigEndianU16(const(ubyte)[] data, size_t offset) pure
{
	return bigEndianToNative!ushort(data[offset .. offset + 2][0 .. 2]);
}

/// encodeName of a single label produces a length prefix, label bytes and a root terminator
unittest {
	assert(encodeName("a") == cast(ubyte[])[1, 'a', 0]);
}

/// encodeName of a dotted name produces one length-prefixed label per segment
unittest {
	assert(encodeName("a.b") == cast(ubyte[])[1, 'a', 1, 'b', 0]);
}

/// decodeName of a single label returns the label and advances the cursor past the root terminator
unittest {
	size_t pos = 0;
	auto name = decodeName(cast(const(ubyte)[])[1, 'a', 0], pos);
	assert(name == "a");
	assert(pos == 3);
}

/// decodeName following a compression pointer returns the resolved name and leaves the cursor past the pointer
unittest {
	auto msg = cast(const(ubyte)[])[1, 'a', 0, 1, 'b', 0xC0, 0];
	size_t pos = 3;
	assert(decodeName(msg, pos) == "b.a");
	assert(pos == 7);
}

/// decodeName rejects a compression pointer targeting past the buffer
unittest {
	import std.exception : assertThrown;
	auto wire = cast(const(ubyte)[])[0xC0, 0x40];
	size_t pos = 0;
	assertThrown(decodeName(wire, pos));
}

/// decodeName rejects a cyclic compression pointer instead of looping forever
unittest {
	import std.exception : assertThrown;
	auto wire = cast(const(ubyte)[])[0xC0, 0x00];
	size_t pos = 0;
	assertThrown(decodeName(wire, pos));
}

/// decodeName rejects a label whose length runs past the buffer
unittest {
	import std.exception : assertThrown;
	auto wire = cast(const(ubyte)[])[0x05, 'a', 'b'];
	size_t pos = 0;
	assertThrown(decodeName(wire, pos));
}

/// DNSRecordType maps record type names to their IANA wire values
unittest {
	assert(DNSRecordType.A == 1);
	assert(DNSRecordType.CNAME == 5);
	assert(DNSRecordType.TXT == 16);
	assert(DNSRecordType.AAAA == 28);
	assert(DNSRecordType.SRV == 33);
	assert(DNSRecordType.ANY == 255);
	assert(DNSRecordType.CAA == 257);
	assert(cast(ushort)DNSRecordType.CAA == 257);
}

/// encodeDNSQuery builds a recursion-desired query with one question
unittest {
	auto query = encodeDNSQuery(0x1234, "a", DNSRecordType.SRV);
	assert(query == cast(ubyte[])[
		0x12,0x34, 0x01,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00,
		1,'a',0,
		0x00,0x21,
		0x00,0x01
	]);
}

/// parseDNSMessage reads the transaction id from a header-only message
unittest {
	auto wire = cast(const(ubyte)[])[0x12,0x34, 0x81,0x80, 0x00,0x00, 0x00,0x00, 0x00,0x00, 0x00,0x00];
	auto msg = parseDNSMessage(wire);
	assert(msg.id == 0x1234);
	assert(msg.answers.length == 0);
}

/// parseDNSMessage rejects a message whose answer count exceeds its data
unittest {
	import std.exception : assertThrown;
	auto wire = cast(const(ubyte)[])[0x12,0x34, 0x81,0x80, 0x00,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00];
	assertThrown(parseDNSMessage(wire));
}

/// parseDNSMessage rejects a buffer smaller than the DNS header
unittest {
	import std.exception : assertThrown;
	assertThrown(parseDNSMessage(cast(const(ubyte)[])[0x12]));
}

/// parseDNSMessage rejects an answer whose rdlength runs past the buffer
unittest {
	import std.exception : assertThrown;
	auto wire = cast(const(ubyte)[])[
		0x12,0x34, 0x81,0x80, 0x00,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00,   // header: qdcount=0, ancount=1
		0x00,                  // answer NAME = root
		0x00,0x01,             // TYPE = A
		0x00,0x01,             // CLASS = IN
		0x00,0x00,0x00,0x00,   // TTL
		0x00,0x04              // RDLENGTH = 4, but ZERO rdata bytes follow
	];
	assertThrown(parseDNSMessage(wire));
}

/// parseDNSMessage decodes a single A answer with its compressed name and rdata
unittest {
	auto wire = cast(const(ubyte)[])[
		0x12,0x34, 0x81,0x80, 0x00,0x01, 0x00,0x01, 0x00,0x00, 0x00,0x00,   // header
		1,'a',0, 0x00,0x01, 0x00,0x01,                                       // question
		0xC0,0x0C, 0x00,0x01, 0x00,0x01, 0x00,0x00,0x01,0x2C, 0x00,0x04, 0x5D,0xB8,0xD8,0x22  // answer
	];
	auto msg = parseDNSMessage(wire);
	assert(msg.answers.length == 1);
	assert(msg.answers[0].name == "a");
	assert(msg.answers[0].type == DNSRecordType.A);
	assert(msg.answers[0].rdata == cast(ubyte[])[0x5D,0xB8,0xD8,0x22]);
}

/// parseDNSMessage keeps an unknown record type with its raw rdata
unittest {
	auto wire = cast(const(ubyte)[])[
		0x12,0x34, 0x81,0x80, 0x00,0x00, 0x00,0x01, 0x00,0x00, 0x00,0x00,  // header: qdcount=0, ancount=1
		0x00,                  // answer NAME = root
		0xFF,0xFE,             // TYPE = 0xFFFE (not a named DNSRecordType)
		0x00,0x01,             // CLASS = IN
		0x00,0x00,0x00,0x00,   // TTL
		0x00,0x02,             // RDLENGTH = 2
		0xAB,0xCD              // RDATA
	];
	auto msg = parseDNSMessage(wire);
	assert(msg.answers.length == 1);
	assert(cast(ushort)msg.answers[0].type == 0xFFFE);
	assert(msg.answers[0].rdata == cast(ubyte[])[0xAB,0xCD]);
}

/// parseSRV decodes priority, weight, port and target from SRV rdata
unittest {
	auto rdata = cast(const(ubyte)[])[0x00,0x00, 0x00,0x05, 0x1F,0x90, 1,'a',1,'b',0];
	auto srv = parseSRV(rdata);
	assert(srv == SRVRecord(0, 5, 8080, "a.b"));
}

/// parseTXT splits rdata into its length-prefixed character-strings
unittest {
	auto rdata = cast(const(ubyte)[])[0x03,'a','b','c', 0x02,'d','e'];
	assert(parseTXT(rdata) == ["abc", "de"]);
}

/// parseTXT rejects a chunk whose length runs past the rdata
unittest {
	import std.exception : assertThrown;
	assertThrown(parseTXT(cast(const(ubyte)[])[0x05, 'a', 'b']));
}

/// parseResolvConf collects the nameserver addresses and ignores other lines
unittest {
	auto conf = "# comment\nsearch example.com\nnameserver 8.8.8.8\nnameserver 1.1.1.1\n";
	assert(parseResolvConf(conf) == ["8.8.8.8", "1.1.1.1"]);
}
