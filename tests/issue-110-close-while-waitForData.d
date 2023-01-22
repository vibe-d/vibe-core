/+ dub.sdl:
	name "test"
	dependency "vibe-core" path=".."
+/
module test;

import core.time;
import std.algorithm.searching : countUntil;
import vibe.core.core;
import vibe.core.net;

ushort port;
void main()
{
	TCPListener listener;
	try {
		listener = listenTCP(0, (conn) @safe nothrow {
			sleepUninterruptible(200.msecs);
		}, "127.0.0.1");
		port = listener.bindAddress.port;
	} catch (Exception e) assert(false, e.msg);

	TCPConnection tcp;
	try tcp = connectTCP("127.0.0.1", port);
	catch (Exception e) assert(false, e.msg);
	runTask({
		sleepUninterruptible(10.msecs);
		tcp.close();
	});
	assert(!tcp.waitForData());
	assert(!tcp.connected);
	listener.stopListening();
}
