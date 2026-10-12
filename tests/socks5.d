/+ dub.sdl:
	name "socks5_tests"
	description "SOCKS5 proxy connection test"
	dependency "vibe-core" path=".."
+/
module tests;

import core.time : seconds;
import std;
import vibe.core;

void testRoundtrip(NetworkAddress proxy, string host, ushort target_port,
	string username = null, string password = null)
{
	auto conn = connectTCPSocks5(proxy, host, target_port, username, password, anyAddress, 10.seconds);
	scope(exit) conn.close();

	ubyte[4] request = [1, 2, 3, 4];
	ubyte[4] response;

	conn.write(request[]);
	conn.read(response[]);

	enforce(response[] == request[], "SOCKS5 round-trip returned corrupted data.");
}

void main()
{
	auto proxy = resolveHost(environment.get("SOCKS5_PROXY_HOST", "127.0.0.1"));
	proxy.port = environment.get("SOCKS5_PROXY_PORT", "1080").to!ushort;

	// listen on "::" so the target is reachable both via IPv4 and IPv6;
	// the proxy may resolve "localhost" to ::1 depending on the system
	auto echoServer = listenTCP(0, (conn) @safe nothrow {
		try {
			while (!conn.empty) {
				ubyte[4] buf;
				conn.read(buf[]);
				conn.write(buf[]);
			}
		} catch (Exception e) assert(false, e.msg);
	}, "::");
	scope(exit) echoServer.stopListening;

	auto echo_port = echoServer.bindAddress.port;

	logInfo("Testing SOCKS5 connection using an IPv4 literal");
	testRoundtrip(proxy, "127.0.0.1", echo_port);

	logInfo("Testing SOCKS5 connection using a domain name");
	testRoundtrip(proxy, "localhost", echo_port);

	auto user = environment.get("SOCKS5_USER", null);
	if (user.length) {
		logInfo("Testing SOCKS5 username/password authentication");
		auto auth_proxy = resolveHost(environment.get("SOCKS5_AUTH_HOST", "127.0.0.1"));
		auth_proxy.port = environment.get("SOCKS5_AUTH_PORT", "1081").to!ushort;
		testRoundtrip(auth_proxy, "127.0.0.1", echo_port, user, environment.get("SOCKS5_PASS", null));
	}

	logInfo("Testing SOCKS5 connection to an unreachable target");
	ushort closed_port;
	{
		auto tmp = listenTCP(0, (conn) @safe nothrow {}, "127.0.0.1");
		closed_port = tmp.bindAddress.port;
		tmp.stopListening();
	}
	assertThrown(connectTCPSocks5(proxy, "127.0.0.1", closed_port, null, null, anyAddress, 10.seconds),
		"Expected connecting to an unreachable target to fail.");

	logInfo("SOCKS5 test finished successfully.");
}
