/+ dub.sdl:
name "test"
description "TCP disconnect task issue"
dependency "vibe-core" path="../"
+/
module test;

import vibe.core.core;
import vibe.core.log : logInfo;
import vibe.core.net;
import core.time : MonoTime, msecs;

void main()
{
	auto udp = listenUDP(11429, "127.0.0.1");

	runTask({
		sleepUninterruptible(500.msecs);
		assert(false, "Receive call did not return in a timely manner. Killing process.");
	});

	runTask({
		auto start = MonoTime.currTime();
		try {
			udp.recv(100.msecs);
			assert(false, "Timeout did not occur.");
		} catch (Exception e) {
			auto duration = MonoTime.currTime() - start;
			version (OSX) enum maxtolerance = 150.msecs;
			else enum maxtolerance = 50.msecs;
			assert(duration >= 99.msecs, "Timeout occurred too early");
			assert(duration >= 99.msecs && duration < 100.msecs + maxtolerance,
				"Timeout occurred too late.");
			logInfo("UDP receive timeout test was successful.");
			exitEventLoop();
		}
	});

	runEventLoop();
}
