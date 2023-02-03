/+ dub.sdl:
	name "test"
	description "Tests vibe.d's std.concurrency integration"
	dependency "vibe-core" path="../"
+/
module test;

import vibe.core.core;
import vibe.core.log;
import std.algorithm;
import std.concurrency;
import core.atomic;
import core.time;
import core.stdc.stdlib : exit;

__gshared Tid t1, t2;
shared watchdog_count = 0;

void main()
{
	t1 = spawn({
		// ensure that asynchronous operations can run in parallel to receive()
		int wc = 0;
		MonoTime stime = MonoTime.currTime;
		runTask({
			while (true) {
				sleepUntil((wc + 1) * 250.msecs, stime, 200.msecs);
				wc++;
				logInfo("Watchdog receiver %s", wc);
			}
		});

		bool finished = false;
		try while (!finished) {
			logDebug("receive1");
			receive(
				(string msg) {
					logInfo("Received string message: %s", msg);
				},
				(int msg) {
					logInfo("Received int message: %s", msg);
				});
			logDebug("receive2");
			receive(
				(double msg) {
					logInfo("Received double: %s", msg);
				},
				(int a, int b, int c) {
					logInfo("Received iii: %s %s %s", a, b, c);

					if (a == 1 && b == 2 && c == 3)
						finished = true;
				});
		}
		catch (Exception e) assert(false, "Receiver thread failed: "~e.msg);

		logInfo("Receive loop finished.");
		version (OSX) enum tolerance = 4; // macOS CI VMs have particularly bad timing behavior
		else enum tolerance = 1;
		if (wc < 6 * 4 - tolerance) {
			logError("Receiver watchdog failure.");
			exit(1);
		}
		logInfo("Exiting normally");
	});

	t2 = spawn({
		MonoTime stime = MonoTime.currTime;

		scope (failure) assert(false);
		sleepUntil(1.seconds, stime, 900.msecs);
		logInfo("send Hello World");
		t1.send("Hello, World!");

		sleepUntil(2.seconds, stime, 900.msecs);
		logInfo("send int 1");
		t1.send(1);

		sleepUntil(3.seconds, stime, 900.msecs);
		logInfo("send double 1.2");
		t1.send(1.2);

		sleepUntil(4.seconds, stime, 900.msecs);
		logInfo("send int 2");
		t1.send(2);

		sleepUntil(5.seconds, stime, 900.msecs);
		logInfo("send 3xint 1 2 3");
		t1.send(1, 2, 3);

		sleepUntil(6.seconds, stime, 900.msecs);
		logInfo("send string Bye bye");
		t1.send("Bye bye");

		sleep(100.msecs);
		logInfo("Exiting.");
		exitEventLoop(true);
	});

	runApplication();
}

// corrects for small timing inaccuracies to avoid the counter
// getting systematically out of sync when sleep timing is inaccurate
void sleepUntil(Duration until, MonoTime start_time, Duration min_sleep)
nothrow {
	auto tm = MonoTime.currTime;
	auto timeout = max(start_time - tm + until, min_sleep);
	try sleep(timeout);
	catch (Exception e) assert(false, e.msg);
}
