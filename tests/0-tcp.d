/+ dub.sdl:
	name "tests"
	description "TCP semantics tests"
	copyright "Copyright © 2015-2020, Sönke Ludwig"
	dependency "vibe-core" path=".."
+/
module tests;

import eventcore.core;
import vibe.core.core;
import vibe.core.log;
import vibe.core.net;
import core.time;
import std.datetime.stopwatch : StopWatch;

enum Test {
  receive,
  receiveExisting,
  timeout,
  noTimeout,
  close
}

void test1()
{
	Test test;
	Task lt;

	auto l = listenTCP(0, (conn) @safe nothrow {
		lt = Task.getThis();
		try {
			while (!conn.empty) {
				assert(conn.fd() != StreamSocketFD.invalid);
				assert(conn.readLine() == "next");
				auto curtest = test;
				conn.write("continue\n");
				logInfo("Perform test %s", curtest);
				StopWatch sw;
				sw.start();
				final switch (curtest) {
					case Test.receive:
						assert(conn.waitForData(2.seconds) == true);
						assert(cast(Duration)sw.peek < 2.seconds); // should receive something instantly
						assert(conn.readLine() == "receive");
						break;
					case Test.receiveExisting:
						assert(conn.waitForData(2.seconds) == true);
						// TODO: validate that waitForData didn't yield!
						assert(cast(Duration)sw.peek < 2.seconds); // should receive something instantly
						assert(conn.readLine() == "receiveExisting");
						break;
					case Test.timeout:
						assert(conn.waitForData(2.seconds) == false);
						assert(cast(Duration)sw.peek > 1900.msecs); // should wait for at least 2 seconds
						assert(conn.connected);
						break;
					case Test.noTimeout:
						assert(conn.waitForData(Duration.max) == true);
						assert(cast(Duration)sw.peek > 2.seconds); // data only sent after 3 seconds
						assert(conn.readLine() == "noTimeout");
						break;
					case Test.close:
						assert(conn.waitForData(2.seconds) == false);
						assert(cast(Duration)sw.peek < 2.seconds); // connection should be closed instantly
						assert(conn.empty);
						conn.close();
						assert(!conn.connected);
						return;
				}
				conn.write("ok\n");
			}
		} catch (Exception e) {
			assert(false, e.msg);
		}
	}, "127.0.0.1");
	scope (exit) l.stopListening;

	auto conn = connectTCP(l.bindAddress);

	test = Test.receive;
	conn.write("next\n");
	assert(conn.readLine() == "continue");
	conn.write("receive\n");
	assert(conn.readLine() == "ok");

	test = Test.receiveExisting;
	conn.write("next\nreceiveExisting\n");
	assert(conn.readLine() == "continue");
	assert(conn.readLine() == "ok");

	test = Test.timeout;
	conn.write("next\n");
	assert(conn.readLine() == "continue");
	sleep(3.seconds);
	assert(conn.readLine() == "ok");

	test = Test.noTimeout;
	conn.write("next\n");
	assert(conn.readLine() == "continue");
	sleep(3.seconds);
	conn.write("noTimeout\n");
	assert(conn.readLine() == "ok");

	test = Test.close;
	conn.write("next\n");
	assert(conn.readLine() == "continue");
	conn.close();

	lt.join();
}

void test2()
{
	Task lt;
	logInfo("Perform test \"disconnect with pending write data\"");
	auto l = listenTCP(0, (conn) @safe nothrow {
		try {
			lt = Task.getThis();
			sleep(1.seconds);
			StopWatch sw;
			sw.start();
			try {
				assert(conn.waitForData() == true);
				assert(cast(Duration)sw.peek < 500.msecs); // waitForData should return immediately
				assert(conn.dataAvailableForRead);
				assert(conn.readAll() == "test");
				conn.close();
			} catch (Exception e) {
				assert(false, "Failed to read pending data: " ~ e.msg);
			}
		} catch (Exception e) {
			assert(false, e.msg);
		}
	}, "127.0.0.1");
	scope (exit) l.stopListening;

	auto conn = connectTCP(l.bindAddress);
	conn.write("test");
	conn.close();

	sleep(100.msecs);

	assert(lt != Task.init);
	lt.join();
}

void test3()
{
	Task lt;
	logInfo("Perform test \"disconnect with pending read data\"");
	auto l = listenTCP(0, (conn) @safe nothrow {
		try {
			lt = Task.getThis();
			sleep(1.seconds);
			conn.close();
			conn = TCPConnection.init;
		} catch (Exception e) {
			assert(false, e.msg);
		}
	}, "127.0.0.1");
	scope (exit) l.stopListening;

	ubyte[256] buf;
	auto conn = connectTCP(l.bindAddress);
	conn.readTimeout = 10.msecs;
	try {
		conn.read(buf);
		assert(false);
	} catch (Exception e) {}
	conn.close();
	conn = TCPConnection.init;

	sleep(100.msecs);

	assert(lt != Task.init);
	lt.join();
}

void main()
{
	test1();
	test2();
	test3();
}

string readLine(TCPConnection c) @safe
{
	import std.string : indexOf;

	string ret;
	while (!c.empty) {
		auto buf = () @trusted { return cast(char[])c.peek(); }();
		auto idx = buf.indexOf('\n');
		if (idx < 0) {
			ret ~= buf;
			c.skip(buf.length);
		} else {
			ret ~= buf[0 .. idx];
			c.skip(idx+1);
			break;
		}
	}
	return ret;
}

string readAll(TCPConnection c) @safe
{
	import std.algorithm.comparison : min;

	ubyte[] ret;
	while (!c.empty) {
		auto len = min(c.leastSize, size_t.max);
		ret.length += len;
		c.read(ret[$-len .. $]);
	}
	return () @trusted { return cast(string) ret; }();
}
