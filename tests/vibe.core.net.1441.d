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
	bool done = false;
	listenTCP(11375, (conn) {
		try {
			conn.write("foo".representation);
			conn.close();
		} catch (Exception e) {
			assert(false, e.msg);
		}
		done = true;
	});

	runTask({
		scope (failure) assert(false);

		auto conn = connectTCP("127.0.0.1", 11375);
		conn.close();

		sleep(50.msecs);
		assert(done);

		exitEventLoop();
	});

	runEventLoop();
}
