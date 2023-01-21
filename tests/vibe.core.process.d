/+ dub.sdl:
name "test"
description "Subprocesses"
dependency "vibe-core" path="../"
+/
module test;

import core.thread;
import vibe.core.log;
import vibe.core.core;
import vibe.core.process;
import std.algorithm;
import std.array;
import std.range;

void testEcho()
{
	foreach (i; 0..100) {
		auto procPipes = pipeProcess(["echo", "foo bar"], Redirect.stdout);

		auto output = procPipes.stdout.collectOutput();

		assert(procPipes.process.wait() == 0);
		assert(procPipes.process.exited);

		assert(output == "foo bar\n");
	}
}

void testCat()
{
	auto procPipes = pipeProcess(["cat"]);

	string output;
	auto outputTask = runTask({
		output = procPipes.stdout.collectOutput();
	});

	auto inputs = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
					.map!(s => s ~ "\n")
					.repeat(4000).join.array;
	foreach (input; inputs) {
		procPipes.stdin.write(input);
	}

	procPipes.stdin.close();
	assert(procPipes.process.wait() == 0);

	outputTask.join();

	assert(output == inputs.join());
}

void testStderr()
{
	auto program = q{
		foreach (line; stdin.byLine())
			stderr.writeln(line);
	};
	auto procPipes = pipeProcess(["rdmd", "--eval", program], Redirect.stdin | Redirect.stderr);

	// Wait for rdmd to compile
	sleep(3.seconds);

	string output;
	auto outputTask = runTask({
		output = procPipes.stderr.collectOutput();
	});

	auto inputs = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
					.map!(s => s ~ "\n")
					.repeat(4000).join.array;
	foreach (input; inputs) {
		procPipes.stdin.write(input);
	}

	procPipes.stdin.close();
	assert(procPipes.process.wait() == 0);

	outputTask.join();

	assert(output == inputs.join);
}

void testRandomDeath()
{
	auto program = q{
		import core.thread;
		import std.random;
		Thread.sleep(dur!"msecs"(uniform(0, 1000)));
	};
	// Prime rdmd
	execute(["rdmd", "--eval", program]);

	foreach (i; 0..20) {
		auto process = spawnProcess(["rdmd", "--eval", program]);

		assert(!process.exited);

		sleep(800.msecs);
		try {
			process.kill();
		} catch (Exception e) {
		}
		process.wait();

		assert(process.exited);
	}
}

void testIgnoreSigterm()
{
	auto program = q{
		import core.thread;
		import core.sys.posix.signal;

		signal(SIGINT, SIG_IGN);
		signal(SIGTERM, SIG_IGN);

		foreach (line; stdin.byLine()) {
			writeln(line);
			stdout.flush();
		}

		// Zombie
		while (true) Thread.sleep(100.dur!"msecs");
	};
	auto procPipes = pipeProcess(
		["rdmd", "--eval", program],
		Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout);

	string output;
	auto outputTask = runTask({
		output = procPipes.stdout.collectOutput();
	});

	assert(!procPipes.process.exited);

	// Give the program some time to compile and install the signal handler
	sleep(4.seconds);

	procPipes.process.kill();
	procPipes.stdin.write("foo\n");

	assert(!procPipes.process.exited);

	assert(procPipes.process.waitOrForceKill(2.seconds) == -9);

	assert(procPipes.process.exited);

	outputTask.join();

	assert(output == "foo\n");
}

void testSimpleShell()
{
	auto res = executeShell("echo foo");

	assert(res.status == 0);
	assert(res.output == "foo\n");
}

void testLineEndings()
{
	auto program = q{
		write("linux\n");
		write("os9\r");
		write("win\r\n");
	};
	auto res = execute(["rdmd", "--eval", program]);

	assert(res.status == 0);
	assert(res.output == "linux\nos9\rwin\r\n");
}

void main()
{
	import core.stdc.stdlib : abort;
	import core.time;
	import std.meta : AliasSeq;


	version (Windows) {
		import vibe.core.log : logInfo;
		logInfo("Skipping process test on Windows");
	} else {
		runTask({
			alias Tasks = AliasSeq!(
				testEcho,
				testCat,
				testStderr,
				testRandomDeath,
				testIgnoreSigterm,
				testSimpleShell,
				testLineEndings
			);

			static foreach (alias task; Tasks) {{
				auto t = runTask({
					logInfo("Running test %s...", __traits(identifier, task));
					auto tm = setTimer(60.seconds, {
						logError("Test %s timed out!", __traits(identifier, task));
						abort();
					});
					try {
						task();
					} catch (Exception e) {
						logError("Test %s failed: %s", __traits(identifier, task), e);
						abort();
					}
					tm.stop();
				});
				t.join();
			}}

			exitEventLoop();
		});

		runEventLoop();
	}
}
