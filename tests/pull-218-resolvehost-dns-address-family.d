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
    runTask({
        scope(exit) exitEventLoop();

        auto addr = resolveHost("ip6.me", AddressFamily.INET);
        assert(addr.family == AddressFamily.INET);

        addr = resolveHost("ip6.me", AddressFamily.INET6);
        assert(addr.family == AddressFamily.INET6);

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
    });

    runEventLoop();
}
