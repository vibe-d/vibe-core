/+ dub.sdl:
	dependency "vibe-core" path=".."
+/
module tests;

import vibe.core.core;
import vibe.core.log;
import vibe.core.net;

import eventcore.driver : IOMode;
import std.algorithm.comparison;
import std.exception;
import std.datetime.stopwatch;
import std.stdio;

void handleTcp(ref TCPConnection stream)
@trusted nothrow {
	assumeWontThrow(stream.readTimeout = dur!"msecs"(500));

	ubyte[] buffer = new ubyte[2048];
	bool got_timeout = false;

	while (true) {
		ubyte[] tmp;
		auto sw = StopWatch(AutoStart.yes);
		try {
			tmp = buffer[0 .. stream.read(buffer, IOMode.once)];
		} catch (ReadTimeoutException e) {
			assert (sw.peek >= 500.msecs, "Timeout occurred too early");
			got_timeout = true;
		} catch (Exception e) {
			assert(false, "Unexpected exception on server side: " ~ e.msg);
		}

		if (tmp == "end") break;
		else stream.write(tmp).assumeWontThrow;
	}

	assert(got_timeout, "Expected timeout did not occur");
	stream.close();
}

void main()
{
	version (Windows) logWarn("SKIPPING TEST DUE TO EVENTCORE BUG #225");
	else {
		auto tm = setTimer(10.seconds, { assert(false, "Test timed out"); });

		auto listeners = listenTCP(17000, (conn) @safe nothrow {handleTcp(conn);});

		// closes the listening sockets
		scope (exit)
			foreach (l; listeners)
				l.stopListening();

		// sleep one seconds let server start
		sleep(dur!"seconds"(1));
		ubyte[] buffer = new ubyte[512];
		auto client = connectTCP("127.0.0.1", 17000);
		client.readTimeout = 500.msecs;
		assert(client.connected, "connect server error!");
		auto send = "hello word";
		client.write(send);
		auto readed = client.read(buffer,IOMode.once);
		auto tmp = buffer[0 .. readed];
		assert(tmp == send, "Client received unexpected echo data");
		sleep(700.msecs);
		client.write("end");
		assert(client.empty);
		client.close();
	}
}
