/+ dub.sdl:
name "test"
description "TCP disconnect task issue"
dependency "vibe-core" path="../"
+/
module test;

import vibe.core.core;
import vibe.core.net;
import core.time : msecs;
import std.string : representation;

void main()
{
	import vibe.core.log;
	bool connected = false;
	listenTCP(12211, (conn) {
		try {
        	conn.waitForData(45.msecs);

		} catch (Exception e) {
			assert(false, e.msg);
		}
		connected = conn.connected; // should be false
	});

	runTask({
		auto conn = connectTCP("127.0.0.1", 12211);
		sleep(10.msecs);
		conn.close();
		sleep(80.msecs);
		assert(connected is false);
		exitEventLoop();
	});

	runEventLoop();
}
