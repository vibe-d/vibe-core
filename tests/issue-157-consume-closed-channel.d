/+ dub.sdl:
	name "tests"
	dependency "vibe-core" path=".."
+/
module tests;

import vibe.core.channel;
import vibe.core.core;
import core.time;

void main()
{
	auto tm = setTimer(10.seconds, { assert(false, "Test timeout."); });
	scope (exit) tm.stop();

	auto ch = createChannel!int();

	auto p = runTask(() nothrow {
		sleepUninterruptible(1.seconds);
		ch.close();
	});

	auto c = runTask(() nothrow {
		while (!ch.empty) {
			try ch.consumeOne();
			catch (Exception e) assert(false, e.msg);
		}
	});

	p.join();
	c.join();
}
