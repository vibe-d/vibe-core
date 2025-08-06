/+ dub.sdl:
	name "test"
	dependency "vibe-core" path=".."
+/
module test;

import std.socket: AddressFamily;

import vibe.core.core;
import vibe.core.net;

void main()
{
	try {
		auto addr = resolveHost("ip6.me", AddressFamily.INET);
		assert(addr.family == AddressFamily.INET);
	} catch (Exception e) assert(false, e.msg);

	try {
		auto addr = resolveHost("ip6.me", AddressFamily.INET6);
		assert(addr.family == AddressFamily.INET6);
	} catch (Exception e) assert(false, e.msg);

	try
	{
		resolveHost("ip4only.me", AddressFamily.INET6);
		assert(false);
	}
	catch(Exception) {}

	try
	{
		resolveHost("ip6only.me", AddressFamily.INET);
		assert(false);
	}
	catch(Exception) {}
}
