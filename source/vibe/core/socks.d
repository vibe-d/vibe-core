/**
	SOCKS5 proxy connection handling.

	Copyright: © 2026 Denis Feklushkin
	Authors: Denis Feklushkin
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.socks;

import std.exception : enforce;
import std.format : format;
import std.socket : AddressFamily;
import vibe.core.net;
import core.time : Duration;

@safe:


/**
	Establishes a connection to the given host/port through a SOCKS5 proxy.

	The destination host name is passed to the proxy unchanged, so that the
	proxy performs the DNS resolution of the destination on its side. If
	`host` is an IP address literal, it is sent to the proxy as such.

	Params:
		proxy_addr = Address of the SOCKS5 proxy server (must include the port)
		host = Host name or IP address of the destination
		port = Port of the destination
		username = Optional user name (enables RFC 1929 username/password authentication)
		password = Optional password (enables RFC 1929 username/password authentication)
		bind_address = Local address to bind the connection to
		timeout = Timeout for establishing the TCP connection and for the SOCKS5 handshake
	Returns:
		A `TCPConnection` that is tunneled through the proxy.
*/
TCPConnection connectTCPSocks5(NetworkAddress proxy_addr, string host, ushort port,
	string username = null, string password = null, NetworkAddress bind_address = anyAddress,
	Duration timeout = Duration.max)
{
	enforce(proxy_addr.family == AddressFamily.INET || proxy_addr.family == AddressFamily.INET6,
		"SOCKS5 proxy address must be an IPv4 or IPv6 address.");
	enforce(proxy_addr.port != 0, "SOCKS5 proxy port must not be zero.");

	auto conn = connectTCP(proxy_addr, bind_address, timeout);
	scope (failure) conn.close();

	auto previous_timeout = conn.readTimeout;
	conn.readTimeout = timeout;
	scope (exit) conn.readTimeout = previous_timeout;

	socks5Handshake(conn, host, port, username, password);

	return conn;
}


private enum Socks5Code : ubyte {
	Version = 0x05,
	AuthNone = 0x00,
	AuthUserPass = 0x02,
	AuthNotAcceptable = 0xFF,
	UserPassVersion = 0x01,
	CmdConnect = 0x01,
	RepSuccess = 0x00,
	AddrIPv4 = 0x01,
	AddrDomain = 0x03,
	AddrIPv6 = 0x04,
}

private void socks5Handshake(TCPConnection conn, string host, ushort port, string username, string password)
{
	enforce(host.length > 0, "Destination host name must not be empty.");
	enforce(host.length <= 255, "Destination host name is too long for SOCKS5.");

	ubyte[] methods = username.length
		? [Socks5Code.Version, ubyte(2), Socks5Code.AuthUserPass, Socks5Code.AuthNone]
		: [Socks5Code.Version, ubyte(1), Socks5Code.AuthNone];
	conn.write(methods);

	ubyte[2] method_reply;
	conn.read(method_reply[]);
	enforce(method_reply[0] == Socks5Code.Version, "Invalid version in SOCKS5 method selection reply.");

	if (method_reply[1] == Socks5Code.AuthUserPass) {
		enforce(username.length > 0,
			"SOCKS5 proxy requested username/password authentication, but no credentials were supplied.");
		enforce(username.length <= 255, "SOCKS5 user name must not exceed 255 bytes.");
		enforce(password.length <= 255, "SOCKS5 password must not exceed 255 bytes.");

		auto auth = new ubyte[3 + username.length + password.length];
		auth[0] = Socks5Code.UserPassVersion;
		auth[1] = cast(ubyte)username.length;
		auth[2 .. 2 + username.length] = cast(const(ubyte)[])username;
		auth[2 + username.length] = cast(ubyte)password.length;
		auth[3 + username.length .. $] = cast(const(ubyte)[])password;
		conn.write(auth);

		ubyte[2] auth_reply;
		conn.read(auth_reply[]);
		enforce(auth_reply[0] == Socks5Code.UserPassVersion, "Invalid version in SOCKS5 authentication reply.");
		enforce(auth_reply[1] == Socks5Code.RepSuccess, "SOCKS5 proxy authentication failed.");
	} else {
		enforce(method_reply[1] == Socks5Code.AuthNone, method_reply[1] == Socks5Code.AuthNotAcceptable
			? "SOCKS5 proxy requires authentication, but no credentials were supplied."
			: format("SOCKS5 proxy requested unsupported authentication method 0x%02x.", method_reply[1]));
	}

	NetworkAddress dest;
	// IP literal: send the address itself to the proxy
	try dest = resolveHost(host, AddressFamily.UNSPEC, false);
	catch (Exception) {} // not a valid address after all - send it as a domain name

	ubyte[4 + 1 + 255 + 2] request;
	size_t n = 0;
	request[n++] = Socks5Code.Version;
	request[n++] = Socks5Code.CmdConnect;
	request[n++] = 0x00; // reserved
	if (dest.family == AddressFamily.INET || dest.family == AddressFamily.INET6) {
		auto is_ipv4 = dest.family == AddressFamily.INET;
		request[n++] = is_ipv4 ? Socks5Code.AddrIPv4 : Socks5Code.AddrIPv6;
		auto ip_len = is_ipv4 ? size_t(4) : size_t(16);
		auto ip = () @trusted {
			auto p = is_ipv4
				? cast(const(ubyte)*)&dest.sockAddrInet4.sin_addr
				: cast(const(ubyte)*)&dest.sockAddrInet6.sin6_addr;
			return p[0 .. ip_len];
		} ();
		request[n .. n + ip_len] = ip;
		n += ip_len;
	} else {
		request[n++] = Socks5Code.AddrDomain;
		request[n++] = cast(ubyte)host.length;
		request[n .. n + host.length] = cast(const(ubyte)[])host;
		n += host.length;
	}
	request[n++] = cast(ubyte)(port >> 8);
	request[n++] = cast(ubyte)(port & 0xFF);
	conn.write(request[0 .. n]);

	ubyte[4] reply;
	conn.read(reply[]);
	enforce(reply[0] == Socks5Code.Version, "Invalid version in SOCKS5 reply.");
	enforce(reply[1] == Socks5Code.RepSuccess, format("SOCKS5 proxy failed to connect to %s:%s: %s",
		host, port, socks5ReplyDescription(reply[1])));
	enforce(reply[2] == 0x00, "Invalid reserved byte in SOCKS5 reply.");

	// consume the bound address, which we have no use for
	switch (reply[3]) {
		default:
			enforce(false, format("Invalid address type in SOCKS5 reply: 0x%02x.", reply[3]));
			break;

		case Socks5Code.AddrIPv4:
			ubyte[4 + 2] addr;
			conn.read(addr[]);
			break;

		case Socks5Code.AddrIPv6:
			ubyte[16 + 2] addr;
			conn.read(addr[]);
			break;

		case Socks5Code.AddrDomain:
			ubyte[1] len;
			conn.read(len[]);
			auto addr = new ubyte[len[0] + 2];
			conn.read(addr);
			break;
	}
}

private pure string socks5ReplyDescription(ubyte reply)
{
	switch (reply) {
		default: return format("unknown error 0x%02x", reply);
		case 0x01: return "general SOCKS server failure";
		case 0x02: return "connection not allowed by ruleset";
		case 0x03: return "network unreachable";
		case 0x04: return "host unreachable";
		case 0x05: return "connection refused";
		case 0x06: return "TTL expired";
		case 0x07: return "command not supported";
		case 0x08: return "address type not supported";
	}
}