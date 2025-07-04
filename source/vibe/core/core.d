/**
	This module contains the core functionality of the vibe.d framework.

	Copyright: © 2012-2020 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.core;

public import vibe.core.task;

import eventcore.core;
import vibe.container.ringbuffer : RingBuffer;
import vibe.core.args;
import vibe.core.concurrency;
import vibe.core.internal.release;
import vibe.core.log;
import vibe.core.sync : ManualEvent, createSharedManualEvent;
import vibe.core.taskpool : TaskPool;
import vibe.internal.async;
//import vibe.utils.array;
import std.algorithm;
import std.conv;
import std.encoding;
import core.exception;
import std.exception;
import std.functional;
import std.range : empty, front, popFront;
import std.string;
import std.traits : isFunctionPointer;
import std.typecons : Flag, Yes, Typedef, Tuple, tuple;
import core.atomic;
import core.sync.condition;
import core.sync.mutex;
import core.stdc.stdlib;
import core.thread;

version(Posix)
{
	import core.sys.posix.signal;
	import core.sys.posix.unistd;
	import core.sys.posix.pwd;

	static if (__traits(compiles, {import core.sys.posix.grp; getgrgid(0);})) {
		import core.sys.posix.grp;
	} else {
		extern (C) {
			struct group {
				char*   gr_name;
				char*   gr_passwd;
				gid_t   gr_gid;
				char**  gr_mem;
			}
			group* getgrgid(gid_t);
			group* getgrnam(in char*);
		}
	}
}

version (Windows)
{
	import core.stdc.signal;
}


/**************************************************************************************************/
/* Public functions                                                                               */
/**************************************************************************************************/

/**
	Performs final initialization and runs the event loop.

	This function performs three tasks:
	$(OL
		$(LI Makes sure that no unrecognized command line options are passed to
			the application and potentially displays command line help. See also
			`vibe.core.args.finalizeCommandLineOptions`.)
		$(LI Performs privilege lowering if required.)
		$(LI Runs the event loop and blocks until it finishes.)
	)

	Params:
		args_out = Optional parameter to receive unrecognized command line
			arguments. If left to `null`, an error will be reported if
			any unrecognized argument is passed.

	See_also: ` vibe.core.args.finalizeCommandLineOptions`, `lowerPrivileges`,
		`runEventLoop`
*/
int runApplication(string[]* args_out = null)
@safe {
	try if (!() @trusted { return finalizeCommandLineOptions(args_out); } () ) return 0;
	catch (Exception e) {
		logDiagnostic("Error processing command line: %s", e.msg);
		return 1;
	}

	lowerPrivileges();

	logDiagnostic("Running event loop...");
	int status;
	version (VibeDebugCatchAll) {
		try {
			status = runEventLoop();
		} catch (Throwable th) {
			th.logException("Unhandled exception in event loop");
			return 1;
		}
	} else {
		status = runEventLoop();
	}

	logDiagnostic("Event loop exited with status %d.", status);
	return status;
}

/// A simple echo server, listening on a privileged TCP port.
unittest {
	import vibe.core.core;
	import vibe.core.net;

	int main()
	{
		// first, perform any application specific setup (privileged ports still
		// available if run as root)
		listenTCP(7, (conn) {
			try conn.write(conn);
			catch (Exception e) { /* log error */ }
		});

		// then use runApplication to perform the remaining initialization and
		// to run the event loop
		return runApplication();
	}
}

/** The same as above, but performing the initialization sequence manually.

	This allows to skip any additional initialization (opening the listening
	port) if an invalid command line argument or the `--help`  switch is
	passed to the application.
*/
unittest {
	import vibe.core.core;
	import vibe.core.net;

	int main()
	{
		// process the command line first, to be able to skip the application
		// setup if not required
		if (!finalizeCommandLineOptions()) return 0;

		// then set up the application
		listenTCP(7, (conn) {
			try conn.write(conn);
			catch (Exception e) { /* log error */ }
		});

		// finally, perform privilege lowering (safe to skip for non-server
		// applications)
		lowerPrivileges();

		// and start the event loop
		return runEventLoop();
	}
}

/**
	Starts the vibe.d event loop for the calling thread.

	Note that this function is usually called automatically by the vibe.d
	framework. However, if you provide your own `main()` function, you may need
	to call either this or `runApplication` manually.

	The event loop will by default continue running during the whole life time
	of the application, but calling `runEventLoop` multiple times in sequence
	is allowed. Tasks will be started and handled only while the event loop is
	running.

	Returns:
		The returned value is the suggested code to return to the operating
		system from the `main` function.

	See_Also: `runApplication`
*/
int runEventLoop()
@safe nothrow {
	setupSignalHandlers();

	logDebug("Starting event loop.");
	s_eventLoopRunning = true;
	scope (exit) {
		eventDriver.core.clearExitFlag();
		s_eventLoopRunning = false;
		s_exitEventLoop = false;
		if (s_isMainThread) atomicStore(st_term, false);
		() @trusted nothrow {
			scope (failure) assert(false); // notifyAll is not marked nothrow
			st_threadShutdownCondition.notifyAll();
		} ();
	}

	// runs any yield()ed tasks first
	assert(!s_exitEventLoop, "Exit flag set before event loop has started.");
	s_exitEventLoop = false;
	performIdleProcessing();
	if (getExitFlag()) return 0;

	Task exit_task;

	// handle exit flag in the main thread to exit when
	// exitEventLoop(true) is called from a thread)
	() @trusted nothrow {
		if (s_isMainThread)
			exit_task = runTask(toDelegate(&watchExitFlag));
	} ();

	while (true) {
		auto er = s_scheduler.waitAndProcess();
		if (er != ExitReason.idle || s_exitEventLoop) {
			logDebug("Event loop exit reason (exit flag=%s): %s", s_exitEventLoop, er);
			break;
		}
		performIdleProcessing();
	}

	// make sure the exit flag watch task finishes together with this loop
	// TODO: would be nice to do this without exceptions
	if (exit_task && exit_task.running)
		exit_task.interrupt();

	logDebug("Event loop done (scheduled tasks=%s, waiters=%s, thread exit=%s).",
		s_scheduler.scheduledTaskCount, eventDriver.core.waiterCount, s_exitEventLoop);
	return 0;
}

/**
	Stops the currently running event loop.

	Calling this function will cause the event loop to stop event processing and
	the corresponding call to runEventLoop() will return to its caller.

	Params:
		shutdown_all_threads = If true, exits event loops of all threads -
			false by default. Note that the event loops of all threads are
			automatically stopped when the main thread exits, so usually
			there is no need to set shutdown_all_threads to true.
*/
void exitEventLoop(bool shutdown_all_threads = false)
@safe nothrow {
	logDebug("exitEventLoop called (%s)", shutdown_all_threads);

	assert(s_eventLoopRunning || shutdown_all_threads, "Exiting event loop when none is running.");
	if (shutdown_all_threads) {
		() @trusted nothrow {
			shutdownWorkerPool();
			atomicStore(st_term, true);
			st_threadsSignal.emit();
		} ();
	}

	// shutdown the calling thread
	s_exitEventLoop = true;
	if (s_eventLoopRunning) eventDriver.core.exit();
}

/**
	Process all pending events without blocking.

	Checks if events are ready to trigger immediately, and run their callbacks if so.

	Returns: Returns false $(I iff) exitEventLoop was called in the process.
*/
bool processEvents()
@safe nothrow {
	return !s_scheduler.process().among(ExitReason.exited, ExitReason.outOfWaiters);
}

/**
	Wait once for events and process them.

	Params:
		timeout = Maximum amount of time to wait for an event. A duration of
			zero will cause the function to only process pending events. A
			duration of `Duration.max`, if necessary, will wait indefinitely
			until an event arrives.

*/
ExitReason runEventLoopOnce(Duration timeout=Duration.max)
@safe nothrow {
	auto ret = s_scheduler.waitAndProcess(timeout);
	if (ret == ExitReason.idle)
		performIdleProcessing();
	return ret;
}

/**
	Sets a callback that is called whenever no events are left in the event queue.

	The callback delegate is called whenever all events in the event queue have been
	processed. Returning true from the callback will cause another idle event to
	be triggered immediately after processing any events that have arrived in the
	meantime. Returning false will instead wait until another event has arrived first.
*/
void setIdleHandler(void delegate() @safe nothrow del)
@safe nothrow {
	s_idleHandler = () @safe nothrow { del(); return false; };
}
/// ditto
void setIdleHandler(bool delegate() @safe nothrow del)
@safe nothrow {
	s_idleHandler = del;
}

/**
	Runs a new asynchronous task.

	task will be called synchronously from within the vibeRunTask call. It will
	continue to run until vibeYield() or any of the I/O or wait functions is
	called.

	Note that the maximum size of all args must not exceed `maxTaskParameterSize`.
*/
Task runTask(ARGS...)(void delegate(ARGS) @safe nothrow task, auto ref ARGS args)
{
	return runTask_internal!((ref tfi) { tfi.set(task, args); });
}
///
Task runTask(ARGS...)(void delegate(ARGS) @system nothrow task, auto ref ARGS args)
@system {
	return runTask_internal!((ref tfi) { tfi.set(task, args); });
}
/// ditto
Task runTask(CALLABLE, ARGS...)(CALLABLE task, auto ref ARGS args)
	if (!is(CALLABLE : void delegate(ARGS)) && isNothrowCallable!(CALLABLE, ARGS))
{
	return runTask_internal!((ref tfi) { tfi.set(task, args); });
}
/// ditto
Task runTask(ARGS...)(TaskSettings settings, void delegate(ARGS) @safe nothrow task, auto ref ARGS args)
{
	return runTask_internal!((ref tfi) {
		tfi.settings = settings;
		tfi.set(task, args);
	});
}
/// ditto
Task runTask(ARGS...)(TaskSettings settings, void delegate(ARGS) @system nothrow task, auto ref ARGS args)
@system {
	return runTask_internal!((ref tfi) {
		tfi.settings = settings;
		tfi.set(task, args);
	});
}
/// ditto
Task runTask(CALLABLE, ARGS...)(TaskSettings settings, CALLABLE task, auto ref ARGS args)
	if (!is(CALLABLE : void delegate(ARGS)) && isNothrowCallable!(CALLABLE, ARGS))
{
	return runTask_internal!((ref tfi) {
		tfi.settings = settings;
		tfi.set(task, args);
	});
}

unittest { // test proportional priority scheduling
	auto tm = setTimer(1000.msecs, { assert(false, "Test timeout"); });
	scope (exit) tm.stop();

	size_t a, b;
	auto t1 = runTask(TaskSettings(1), { while (a + b < 100) { a++; try yield(); catch (Exception e) assert(false); } });
	auto t2 = runTask(TaskSettings(10), { while (a + b < 100) { b++; try yield(); catch (Exception e) assert(false); } });
	runTask({
		t1.joinUninterruptible();
		t2.joinUninterruptible();
		exitEventLoop();
	});
	runEventLoop();
	assert(a + b == 100);
	assert(b.among(90, 91, 92)); // expect 1:10 ratio +-1
}


/**
	Runs an asyncronous task that is guaranteed to finish before the caller's
	scope is left.
*/
auto runTaskScoped(FT, ARGS)(scope FT callable, ARGS args)
{
	static struct S {
		Task handle;

		@disable this(this);

		~this()
		{
			handle.joinUninterruptible();
		}
	}

	return S(runTask(callable, args));
}

package Task runTask_internal(alias TFI_SETUP)()
{
	import std.typecons : Tuple, tuple;

	TaskFiber f;
	while (!f && !s_availableFibers.empty) {
		f = s_availableFibers.back;
		s_availableFibers.removeBack();
		if (() @trusted nothrow { return f.state; } () != Fiber.State.HOLD) f = null;
	}

	if (f is null) {
		// if there is no fiber available, create one.
		if (s_availableFibers.capacity == 0) s_availableFibers.capacity = 1024;
		logDebugV("Creating new fiber...");
		f = new TaskFiber;
	}

	TFI_SETUP(f.m_taskFunc);

	f.bumpTaskCounter();
	auto handle = f.task();

	debug if (TaskFiber.ms_taskCreationCallback) {
		TaskCreationInfo info;
		info.handle = handle;
		info.functionPointer = () @trusted { return cast(void*)f.m_taskFunc.functionPointer; } ();
		() @trusted { TaskFiber.ms_taskCreationCallback(info); } ();
	}

	debug if (TaskFiber.ms_taskEventCallback) {
		() @trusted { TaskFiber.ms_taskEventCallback(TaskEvent.preStart, handle); } ();
	}

	debug (VibeTaskLog) logTrace("Switching to newly created task");
	switchToTask(handle);

	debug if (TaskFiber.ms_taskEventCallback) {
		() @trusted { TaskFiber.ms_taskEventCallback(TaskEvent.postStart, handle); } ();
	}

	return handle;
}

unittest { // ensure task.running is true directly after runTask
	Task t;
	bool hit = false;
	{
		auto l = yieldLock();
		t = runTask({ hit = true; });
		assert(!hit);
		assert(t.running);
	}
	t.join();
	assert(!t.running);
	assert(hit);
}

unittest {
	import core.atomic : atomicOp;

	static struct S {
		shared(int)* rc;
		this(this) @safe nothrow { if (rc) atomicOp!"+="(*rc, 1); }
		~this() @safe nothrow { if (rc) atomicOp!"-="(*rc, 1); }
	}

	S s;
	s.rc = new int;
	*s.rc = 1;

	runTask((ref S sc) {
		auto rc = sc.rc;
		assert(*rc == 2);
		sc = S.init;
		assert(*rc == 1);
	}, s).joinUninterruptible();

	assert(*s.rc == 1);

	runWorkerTaskH((ref S sc) {
		auto rc = sc.rc;
		assert(*rc == 2);
		sc = S.init;
		assert(*rc == 1);
	}, s).joinUninterruptible();

	assert(*s.rc == 1);
}


/**
	Runs a new asynchronous task in a worker thread.

	Only function pointers with weakly isolated arguments are allowed to be
	able to guarantee thread-safety.
*/
void runWorkerTask(FT, ARGS...)(FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	st_workerPool.runTask(func, args);
}
/// ditto
void runWorkerTask(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	setupWorkerThreads();
	st_workerPool.runTask!method(object, args);
}
/// ditto
void runWorkerTask(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	st_workerPool.runTask(settings, func, args);
}
/// ditto
void runWorkerTask(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	setupWorkerThreads();
	st_workerPool.runTask!method(settings, object, args);
}


/**
	Runs a new asynchronous task in a worker thread, returning the task handle.

	This function will yield and wait for the new task to be created and started
	in the worker thread, then resume and return it.

	Only function pointers with weakly isolated arguments are allowed to be
	able to guarantee thread-safety.
*/
Task runWorkerTaskH(FT, ARGS...)(FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskH(func, args);
}
/// ditto
Task runWorkerTaskH(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskH!method(object, args);
}
/// ditto
Task runWorkerTaskH(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskH(settings, func, args);
}
/// ditto
Task runWorkerTaskH(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, auto ref ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskH!method(settings, object, args);
}

/// Running a worker task using a function
unittest {
	static void workerFunc(int param)
	{
		logInfo("Param: %s", param);
	}

	static void test()
	{
		runWorkerTask(&workerFunc, 42);
		runWorkerTask(&workerFunc, cast(ubyte)42); // implicit conversion #719
		runWorkerTaskDist(&workerFunc, 42);
		runWorkerTaskDist(&workerFunc, cast(ubyte)42); // implicit conversion #719
	}
}

/// Running a worker task using a class method
unittest {
	static class Test {
		void workerMethod(int param)
		shared nothrow {
			logInfo("Param: %s", param);
		}
	}

	static void test()
	{
		auto cls = new shared Test;
		runWorkerTask!(Test.workerMethod)(cls, 42);
		runWorkerTask!(Test.workerMethod)(cls, cast(ubyte)42); // #719
		runWorkerTaskDist!(Test.workerMethod)(cls, 42);
		runWorkerTaskDist!(Test.workerMethod)(cls, cast(ubyte)42); // #719
	}
}

/// Running a worker task using a function and communicating with it
unittest {
	static void workerFunc(Task caller)
	nothrow {
		int counter = 10;
		try {
			while (receiveOnly!string() == "ping" && --counter) {
				logInfo("pong");
				caller.send("pong");
			}
			caller.send("goodbye");
		} catch (Exception e) assert(false, e.msg);
	}

	static void test()
	{
		Task callee = runWorkerTaskH(&workerFunc, Task.getThis);
		do {
			logInfo("ping");
			callee.send("ping");
		} while (receiveOnly!string() == "pong");
	}

	static void work719(int) nothrow {}
	static void test719() { runWorkerTaskH(&work719, cast(ubyte)42); }
}

/// Running a worker task using a class method and communicating with it
unittest {
	static class Test {
		void workerMethod(Task caller)
		shared nothrow {
			int counter = 10;
			try {
				while (receiveOnly!string() == "ping" && --counter) {
					logInfo("pong");
					caller.send("pong");
				}
				caller.send("goodbye");
			} catch (Exception e) assert(false, e.msg);
		}
	}

	static void test()
	{
		auto cls = new shared Test;
		Task callee = runWorkerTaskH!(Test.workerMethod)(cls, Task.getThis());
		do {
			logInfo("ping");
			callee.send("ping");
		} while (receiveOnly!string() == "pong");
	}

	static class Class719 {
		void work(int) shared nothrow {}
	}
	static void test719() {
		auto cls = new shared Class719;
		runWorkerTaskH!(Class719.work)(cls, cast(ubyte)42);
	}
}

unittest { // run and join local task from outside of a task
	int i = 0;
	auto t = runTask({
		try sleep(1.msecs);
		catch (Exception e) assert(false, e.msg);
		i = 1;
	});
	t.join();
	assert(i == 1);
}

unittest { // run and join worker task from outside of a task
	__gshared int i = 0;
	auto t = runWorkerTaskH({
		try sleep(5.msecs);
		catch (Exception e) assert(false, e.msg);
		i = 1;
	});
	t.join();
	assert(i == 1);
}


/**
	Runs a new asynchronous task in all worker threads concurrently.

	This function is mainly useful for long-living tasks that distribute their
	work across all CPU cores. Only function pointers with weakly isolated
	arguments are allowed to be able to guarantee thread-safety.

	The number of tasks started is guaranteed to be equal to
	`workerThreadCount`.
*/
void runWorkerTaskDist(FT, ARGS...)(FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskDist(func, args);
}
/// ditto
void runWorkerTaskDist(alias method, T, ARGS...)(shared(T) object, ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskDist!method(object, args);
}
/// ditto
void runWorkerTaskDist(FT, ARGS...)(TaskSettings settings, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskDist(settings, func, args);
}
/// ditto
void runWorkerTaskDist(alias method, T, ARGS...)(TaskSettings settings, shared(T) object, ARGS args)
	if (isNothrowMethod!(shared(T), method, ARGS))
{
	setupWorkerThreads();
	return st_workerPool.runTaskDist!method(settings, object, args);
}


/** Runs a new asynchronous task in all worker threads and returns the handles.

	`on_handle` is a callble that takes a `Task` as its only argument and is
	called for every task instance that gets created.

	See_also: `runWorkerTaskDist`
*/
void runWorkerTaskDistH(HCB, FT, ARGS...)(scope HCB on_handle, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	st_workerPool.runTaskDistH(on_handle, func, args);
}
/// ditto
void runWorkerTaskDistH(HCB, FT, ARGS...)(TaskSettings settings, scope HCB on_handle, FT func, auto ref ARGS args)
	if (isFunctionPointer!FT && isNothrowCallable!(FT, ARGS))
{
	setupWorkerThreads();
	st_workerPool.runTaskDistH(settings, on_handle, func, args);
}


/** Groups together a set of tasks and ensures that no task outlives the group.

	This struct uses RAII to ensure that none of the associated tasks can
	outlive the group.
*/
struct TaskGroup {
	private {
		Task[] m_tasks;
	}

	@disable this(this);

	~this()
	@safe nothrow {
		joinUninterruptible();
	}

	/// Runs a new task and adds it to the group.
	Task run(ARGS...)(ARGS args)
	{
		auto t = runTask(args);
		add(t);
		return t;
	}

	/// Runs a new task and adds it to the group.
	Task runInWorker(ARGS...)(ARGS args)
	{
		auto t = runWorkerTaskH(args);
		add(t);
		return t;
	}

	/// Adds an existing task to the group.
	void add(Task t)
	@safe nothrow {
		if (t.running)
			m_tasks ~= t;
		cleanup();
	}

	/// Interrupts all tasks of the group.
	void interrupt()
	@safe nothrow {
		foreach (t; m_tasks)
			t.interrupt();
	}

	/// Joins all tasks in the group.
	void join()
	@safe {
		foreach (t; m_tasks)
			t.join();
		cleanup();
	}
	/// ditto
	void joinUninterruptible()
	@safe nothrow {
		foreach (t; m_tasks)
			t.joinUninterruptible();
		cleanup();
	}

	private void cleanup()
	@safe nothrow {
		size_t j = 0;
		foreach (i; 0 .. m_tasks.length)
			if (m_tasks[i].running) {
				if (i != j) m_tasks[j] = m_tasks[i];
				j++;
			}
		m_tasks.length = j;
		() @trusted { m_tasks.assumeSafeAppend(); } ();
	}
}


enum isCallable(CALLABLE, ARGS...) = is(typeof({ mixin(testCall!ARGS("CALLABLE.init")); }));
enum isNothrowCallable(CALLABLE, ARGS...) = is(typeof(() nothrow { mixin(testCall!ARGS("CALLABLE.init")); }));
enum isMethod(T, alias method, ARGS...) = is(typeof({ mixin(testCall!ARGS("__traits(getMember, T.init, __traits(identifier, method))")); }));
enum isNothrowMethod(T, alias method, ARGS...) = is(typeof(() nothrow { mixin(testCall!ARGS("__traits(getMember, T.init, __traits(identifier, method))")); }));
private string testCall(ARGS...)(string callable) {
	auto ret = callable ~ "(";
	foreach (i, Ti; ARGS) {
		if (i > 0) ret ~= ", ";
		static if (is(typeof((Ti a) => a)))
			ret ~= "(function ref ARGS["~i.stringof~"]() { static ARGS["~i.stringof~"] ret; return ret; }) ()";
		else
			ret ~= "ARGS["~i.stringof~"].init";
	}
	return ret ~ ");";
}

unittest {
	static assert(isCallable!(void function() @system));
	static assert(isCallable!(void function(int) @system, int));
	static assert(isCallable!(void function(ref int) @system, int));
	static assert(isNothrowCallable!(void function() nothrow @system));
	static assert(!isNothrowCallable!(void function() @system));

	struct S { @disable this(this); }
	static assert(isCallable!(void function(S) @system, S));
	static assert(isNothrowCallable!(void function(S) @system nothrow, S));
}


/**
	Sets up num worker threads.

	This function gives explicit control over the number of worker threads.
	Note, to have an effect the function must be called prior to related worker
	tasks functions which set up the default number of worker threads
	implicitly.

	Params:
		num = The number of worker threads to initialize. Defaults to
			`logicalProcessorCount`.
	See_also: `runWorkerTask`, `runWorkerTaskH`, `runWorkerTaskDist`
*/
public void setupWorkerThreads(uint num = 0)
@safe nothrow {
	static bool s_workerThreadsStarted = false;
	if (s_workerThreadsStarted) return;
	s_workerThreadsStarted = true;

	if (num == 0) {
		try num = () @trusted { return logicalProcessorCount(); } ();
		catch (Exception e) {
			logException(e, "Failed to get logical processor count, assuming 4.");
			num = 4;
		}
	}

	() @trusted nothrow {
		st_threadsMutex.lock_nothrow();
		scope (exit) st_threadsMutex.unlock_nothrow();

		if (!st_workerPool)
			st_workerPool = new shared TaskPool(num, "vibe-worker");

		if (!st_ioWorkerPool)
			st_ioWorkerPool = new shared TaskPool(3, "vibe-io");
	} ();
}


/** Returns the default worker task pool.

	This pool is used by `runWorkerTask`, `runWorkerTaskH` and
	`runWorkerTaskDist`.
*/
@property shared(TaskPool) workerTaskPool()
@safe nothrow {
	setupWorkerThreads();
	return st_workerPool;
}


package @property shared(TaskPool) ioWorkerTaskPool()
@safe nothrow {
	setupWorkerThreads();
	return st_ioWorkerPool;
}


/** Determines the number of logical processors in the system.

	This number includes virtual cores on hyper-threading enabled CPUs.
*/
@property uint logicalProcessorCount()
@safe nothrow {
	import std.parallelism : totalCPUs;
	return totalCPUs;
}


/** Suspends the execution of the calling task to let other tasks and events be
	handled.

	Calling this function in short intervals is recommended if long CPU
	computations are carried out by a task. It can also be used in conjunction
	with Signals to implement cross-fiber events with no polling.

	Throws:
		May throw an `InterruptException` if `Task.interrupt()` gets called on
		the calling task.

	See_also: `yieldUninterruptible`
*/
void yield()
@safe {
	auto t = Task.getThis();
	if (t != Task.init) {
		auto tf = () @trusted { return t.taskFiber; } ();
		tf.handleInterrupt();
		s_scheduler.yield();
		tf.handleInterrupt();
	} else {
		// avoid recursive event processing, which could result in an infinite
		// recursion
		static bool in_yield = false;
		if (in_yield) return;
		in_yield = true;
		scope (exit) in_yield = false;

		// Let yielded tasks execute
		TaskFiber.getThis().yieldLockCheck();
		() @safe nothrow { performIdleProcessingOnce(true); } ();
	}
}

unittest {
	size_t ti;
	auto t = runTask({
		for (ti = 0; ti < 10; ti++)
			try yield();
			catch (Exception e) assert(false, e.msg);
	});

	foreach (i; 0 .. 5) yield();
	assert(ti > 0 && ti < 10, "Task did not interleave with yield loop outside of task");

	t.join();
	assert(ti == 10);
}


/** Suspends the execution of the calling task to let other tasks and events be
	handled.

	This version of `yield` will not react to calls to `Task.interrupt` and will
	not throw any exceptions.

	See_also: `yield`
*/
void yieldUninterruptible()
@safe nothrow {
	auto t = Task.getThis();
	if (t != Task.init) {
		auto tf = () @trusted { return t.taskFiber; } ();
		s_scheduler.yieldUninterruptible();
	} else {
		// avoid recursive event processing, which could result in an infinite
		// recursion
		static bool in_yield = false;
		if (in_yield) return;
		in_yield = true;
		scope (exit) in_yield = false;

		// Let yielded tasks execute
		TaskFiber.getThis().yieldLockCheck();
		() @safe nothrow { performIdleProcessingOnce(true); } ();
	}
}


/**
	Suspends the execution of the calling task until `switchToTask` is called
	manually.

	This low-level scheduling function is usually only used internally. Failure
	to call `switchToTask` will result in task starvation and resource leakage.

	Params:
		on_interrupt = If specified, is required to

	See_Also: `switchToTask`
*/
void hibernate(scope void delegate() @safe nothrow on_interrupt = null)
@safe nothrow {
	auto t = Task.getThis();
	if (t == Task.init) {
		TaskFiber.getThis().yieldLockCheck();
		runEventLoopOnce();
	} else {
		auto tf = () @trusted { return t.taskFiber; } ();
		tf.handleInterrupt(on_interrupt);
		s_scheduler.hibernate();
		tf.handleInterrupt(on_interrupt);
	}
}


/**
	Switches execution to the given task.

	This function can be used in conjunction with `hibernate` to wake up a
	task. The task must live in the same thread as the caller.

	If no priority is specified, `TaskSwitchPriority.prioritized` or
	`TaskSwitchPriority.immediate` will be used, depending on whether a
	yield lock is currently active.

	Note that it is illegal to use `TaskSwitchPriority.immediate` if a yield
	lock is active.

	This function must only be called on tasks that belong to the calling
	thread and have previously been hibernated!

	See_Also: `hibernate`, `yieldLock`
*/
void switchToTask(Task t)
@safe nothrow {
	auto defer = TaskFiber.getThis().isInYieldLock();
	s_scheduler.switchTo(t, defer ? TaskSwitchPriority.prioritized : TaskSwitchPriority.immediate);
}
/// ditto
void switchToTask(Task t, TaskSwitchPriority priority)
@safe nothrow {
	s_scheduler.switchTo(t, priority);
}


/**
	Suspends the execution of the calling task for the specified amount of time.

	Note that other tasks of the same thread will continue to run during the
	wait time, in contrast to $(D core.thread.Thread.sleep), which shouldn't be
	used in vibe.d applications.

	Repeated_sleep:
	  As this method creates a new `Timer` every time, it is not recommended to
	  use it in a tight loop. For functions that calls `sleep` frequently,
	  it is preferable to instantiate a single `Timer` and reuse it,
	  as shown in the following example:
	  ---
	  void myPollingFunction () {
		  Timer waiter = createTimer(null); // Create a re-usable timer
		  while (true) {
			  // Your awesome code goes here
			  timer.rearm(timeout, false);
			  timer.wait();
		  }
	  }
	  ---

	Throws: May throw an `InterruptException` if the task gets interrupted using
		`Task.interrupt()`.
*/
void sleep(Duration timeout)
@safe {
	assert(timeout >= 0.seconds, "Argument to sleep must not be negative.");
	if (timeout <= 0.seconds) return;
	auto tm = setTimer(timeout, null);
	tm.wait();
}
///
unittest {
	import vibe.core.core : sleep;
	import vibe.core.log : logInfo;
	import core.time : msecs;

	void test()
	{
		logInfo("Sleeping for half a second...");
		sleep(500.msecs);
		logInfo("Done sleeping.");
	}
}


/** Suspends the execution of the calling task an an uninterruptible manner.

	This function behaves the same as `sleep`, except that invoking
	`Task.interrupt` on the calling task will not result in an
	`InterruptException` being thrown from `sleepUninterruptible`. Instead,
	if any, a later interruptible wait state will throw the exception.
*/
void sleepUninterruptible(Duration timeout)
@safe nothrow {
	assert(timeout >= 0.seconds, "Argument to sleep must not be negative.");
	if (timeout <= 0.seconds) return;
	auto tm = setTimer(timeout, null);
	tm.waitUninterruptible();
}


/**
	Creates a new timer, that will fire `callback` after `timeout`

	Timers can be be separated into two categories: one-off or periodic.
	One-off timers fire only once, after a specific amount of time,
	while periodic timer fire at a regular interval.

	One-off_timers:
	One-off timers can be used for performing a task after a specific delay,
	or to schedule a time without interrupting the currently running code.
	For example, the following is a way to emulate a 'schedule' primitive,
	a way to schedule a task without starting it immediately (unlike `runTask`):
	---
	void handleRequest (scope HTTPServerRequest req, scope HTTPServerResponse res) {
		Payload payload = parse(req);
		if (payload.isValid())
		  // Don't immediately yield, finish processing the data and the query
		  setTimer(0.msecs, () => sendToPeers(payload));
		process(payload);
		res.writeVoidBody();
	}
	---

	In this example, the server delays the network communication that
	will be	 performed by `sendToPeers` until after the request is fully
	processed, ensuring the client doesn't wait more than the actual processing
	time for the response.

	Periodic_timers:
	Periodic timers will trigger for the first time after `timeout`,
	then at best every `timeout` period after this. Periodic timers may be
	explicitly stopped by calling the `Timer.stop()` method on the return value
	of this function.

	As timer are non-preemtive (see the "Preemption" section), user code does
	not need to compensate for time drift, as the time spent in the function
	will not affect the frequency, unless the function takes longer to complete
	than the timer.

	Preemption:
	Like other events in Vibe.d, timers are non-preemptive, meaning that
	the currently executing function will not be interrupted to let a timer run.
	This is usually not a problem in server applications, as any blocking code
	will be easily noticed (the server will stop to handle requests), but might
	come at a surprise in code that doesn't handle request.
	If this is a problem, the solution is usually to either explicitly give
	control to the event loop (by calling `yield`) or ensuring operations are
	asynchronous (e.g. call functions from `vibe.core.file` instead of `std.file`).

	Reentrancy:
	The event loop guarantees that the same timer will never be called more than
	once at a time. Hence, functions run on a timer do not need to be re-entrant,
	even if they execute for longer than the timer frequency.

	Params:
		timeout = Determines the minimum amount of time that elapses before the timer fires.
		callback = A delegate to be called when the timer fires. Can be `null`,
				   in which case the timer will not do anything.
		periodic = Speficies if the timer fires repeatedly or only once

	Returns:
		Returns a `Timer` object that can be used to identify and modify the timer.

	See_also: `createTimer`
*/
Timer setTimer(Duration timeout, Timer.Callback callback, bool periodic = false)
@safe nothrow {
	auto tm = createTimer(callback);
	tm.rearm(timeout, periodic);
	return tm;
}
///
unittest {
	void printTime()
	@safe nothrow {
		import std.datetime;
		logInfo("The time is: %s", Clock.currTime());
	}

	void test()
	{
		import vibe.core.core;
		// start a periodic timer that prints the time every second
		setTimer(1.seconds, toDelegate(&printTime), true);
	}
}

/// Compatibility overload - use a `@safe nothrow` callback instead.
Timer setTimer(Duration timeout, void delegate() callback, bool periodic = false)
@system nothrow {
	return setTimer(timeout, () @trusted nothrow {
		try callback();
		catch (Exception e) {
			e.logException!(LogLevel.warn)("Timer callback failed");
		}
	}, periodic);
}

unittest { // make sure that periodic timer calls never overlap
	int ccount = 0;
	int fcount = 0;
	Timer tm;

	tm = setTimer(10.msecs, {
		ccount++;
		scope (exit) ccount--;
		assert(ccount == 1); // no concurrency allowed
		assert(fcount < 5);
		sleep(100.msecs);
		if (++fcount >= 5)
			tm.stop();
	}, true);

	while (tm.pending) sleep(50.msecs);

	sleep(50.msecs);

	assert(fcount == 5);
}


/** Creates a new timer without arming it.

	Each time `callback` gets invoked, it will be run inside of a newly started
	task.

	Params:
		callback = If non-`null`, this delegate will be called when the timer
			fires

	See_also: `createLeanTimer`, `setTimer`
*/
Timer createTimer(void delegate() nothrow @safe callback = null)
@safe nothrow {
	static struct C {
		void delegate() nothrow @safe m_callback;
		bool m_running = false;
		bool m_pendingFire = false;

		void opCall(Timer tm)
		nothrow @safe {
			if (m_running) {
				m_pendingFire = true;
				return;
			}

			m_running = true;

			runTask(function(Timer tm, C* ctx) nothrow {
				assert(ctx.m_running);
				scope (exit) ctx.m_running = false;

				do {
					ctx.m_pendingFire = false;
					ctx.m_callback();

					// make sure that no callbacks are fired after the timer
					// has been actively stopped
					if (ctx.m_pendingFire && !tm.pending)
						ctx.m_pendingFire = false;
				} while (ctx.m_pendingFire);
			}, tm, () @trusted { return &this; } ());
			// NOTE: the called C is allocated at a fixed address within the
			//       timer descriptor slot of eventcore, so that we can "safely"
			//       pass the address to runTask here, as long as it is
			//       guaranteed that the timer lives longer than the task.
		}
	}

	if (callback) {
		C c = {callback};
		return createLeanTimer(c);
	}

	return createLeanTimer!(Timer.Callback)(null);
}


/** Creates a new timer with a lean callback mechanism.

	In contrast to the standard `createTimer`, `callback` will not be called
	in a new task, but is instead called directly in the context of the event
	loop.

	For this reason, the supplied callback is not allowed to perform any
	operation that needs to block/yield execution. In this case, `runTask`
	needs to be used explicitly to perform the operation asynchronously.

	Additionally, `callback` can carry arbitrary state without requiring a heap
	allocation.

	See_also: `createTimer`
*/
Timer createLeanTimer(CALLABLE)(CALLABLE callback)
	if (is(typeof(() @safe nothrow { callback(); } ()))
		|| is(typeof(() @safe nothrow { callback(Timer.init); } ())))
{
	return Timer.create(eventDriver.timers.create(), callback);
}


/**
	Creates an event to wait on an existing file descriptor.

	The file descriptor usually needs to be a non-blocking socket for this to
	work.

	Params:
		file_descriptor = The Posix file descriptor to watch
		event_mask = Specifies which events will be listened for

	Returns:
		Returns a newly created FileDescriptorEvent associated with the given
		file descriptor.
*/
FileDescriptorEvent createFileDescriptorEvent(int file_descriptor, FileDescriptorEvent.Trigger event_mask)
@safe nothrow {
	return FileDescriptorEvent(file_descriptor, event_mask);
}


/**
	Sets the stack size to use for tasks.

	The default stack size is set to 512 KiB on 32-bit systems and to 16 MiB
	on 64-bit systems, which is sufficient for most tasks. Tuning this value
	can be used to reduce memory usage for large numbers of concurrent tasks
	or to avoid stack overflows for applications with heavy stack use.

	Note that this function must be called at initialization time, before any
	task is started to have an effect.

	Also note that the stack will initially not consume actual physical memory -
	it just reserves virtual address space. Only once the stack gets actually
	filled up with data will physical memory then be reserved page by page. This
	means that the stack can safely be set to large sizes on 64-bit systems
	without having to worry about memory usage.
*/
void setTaskStackSize(size_t sz)
nothrow {
	TaskFiber.ms_taskStackSize = sz;
}


/**
	The number of worker threads used for processing worker tasks.

	Note that this function will cause the worker threads to be started,
	if they haven't	already.

	See_also: `runWorkerTask`, `runWorkerTaskH`, `runWorkerTaskDist`,
	`setupWorkerThreads`
*/
@property size_t workerThreadCount() nothrow
	out(count) { assert(count > 0, "No worker threads started after setupWorkerThreads!?"); }
do {
	setupWorkerThreads();
	st_threadsMutex.lock_nothrow();
	scope (exit) st_threadsMutex.unlock_nothrow();

	return st_workerPool.threadCount;
}


/**
	Disables the signal handlers usually set up by vibe.d.

	During the first call to `runEventLoop`, vibe.d usually sets up a set of
	event handlers for SIGINT, SIGTERM and SIGPIPE. Since in some situations
	this can be undesirable, this function can be called before the first
	invocation of the event loop to avoid this.

	Calling this function after `runEventLoop` will have no effect.
*/
void disableDefaultSignalHandlers()
{
	synchronized (st_threadsMutex)
		s_disableSignalHandlers = true;
}

/**
	Sets the effective user and group ID to the ones configured for privilege lowering.

	This function is useful for services run as root to give up on the privileges that
	they only need for initialization (such as listening on ports <= 1024 or opening
	system log files).
*/
void lowerPrivileges(string uname, string gname)
@safe {
	if (!isRoot()) return;
	if (uname != "" || gname != "") {
		static bool tryParse(T)(string s, out T n)
		{
			import std.conv, std.ascii;
			if (!isDigit(s[0])) return false;
			n = parse!T(s);
			return s.length==0;
		}
		int uid = -1, gid = -1;
		if (uname != "" && !tryParse(uname, uid)) uid = getUID(uname);
		if (gname != "" && !tryParse(gname, gid)) gid = getGID(gname);
		setUID(uid, gid);
	} else logWarn("Vibe was run as root, and no user/group has been specified for privilege lowering. Running with full permissions.");
}

// ditto
void lowerPrivileges()
@safe {
	lowerPrivileges(s_privilegeLoweringUserName, s_privilegeLoweringGroupName);
}


/**
	Sets a callback that is invoked whenever a task changes its status.

	This function is useful mostly for implementing debuggers that
	analyze the life time of tasks, including task switches. Note that
	the callback will only be called for debug builds.
*/
void setTaskEventCallback(TaskEventCallback func)
{
	debug TaskFiber.ms_taskEventCallback = func;
}

/**
	Sets a callback that is invoked whenever new task is created.

	The callback is guaranteed to be invoked before the one set by
	`setTaskEventCallback` for the same task handle.

	This function is useful mostly for implementing debuggers that
	analyze the life time of tasks, including task switches. Note that
	the callback will only be called for debug builds.
*/
void setTaskCreationCallback(TaskCreationCallback func)
{
	debug TaskFiber.ms_taskCreationCallback = func;
}


/**
	A version string representing the current vibe.d core version
*/
enum vibeVersionString = "2.12.0";


/**
	Generic file descriptor event.

	This kind of event can be used to wait for events on a non-blocking
	file descriptor. Note that this can usually only be used on socket
	based file descriptors.
*/
struct FileDescriptorEvent {
	/** Event mask selecting the kind of events to listen for.
	*/
	enum Trigger {
		none = 0,         /// Match no event (invalid value)
		read = 1<<0,      /// React on read-ready events
		write = 1<<1,     /// React on write-ready events
		any = read|write  /// Match any kind of event
	}

	private {
		static struct Context {
			Trigger trigger;
			shared(NativeEventDriver) driver;
		}

		StreamSocketFD m_socket;
		Context* m_context;
	}

	@safe:

	private this(int fd, Trigger event_mask)
	nothrow {
		m_socket = eventDriver.sockets.adoptStream(fd);
		m_context = () @trusted { return &eventDriver.sockets.userData!Context(m_socket); } ();
		m_context.trigger = event_mask;
		m_context.driver = () @trusted { return cast(shared)eventDriver; } ();
	}

	this(this)
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			eventDriver.sockets.addRef(m_socket);
	}

	~this()
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			releaseHandle!"sockets"(m_socket, m_context.driver);
	}


	/** Waits for the selected event to occur.

		Params:
			which = Optional event mask to react only on certain events
			timeout = Maximum time to wait for an event

		Returns:
			The overload taking the timeout parameter returns true if
			an event was received on time and false otherwise.
	*/
	void wait(Trigger which = Trigger.any)
	{
		wait(Duration.max, which);
	}
	/// ditto
	bool wait(Duration timeout, Trigger which = Trigger.any)
	{
		if ((which & m_context.trigger) == Trigger.none) return true;

		assert((which & m_context.trigger) == Trigger.read, "Waiting for write event not yet supported.");

		bool got_data;

		alias readwaiter = Waitable!(IOCallback,
			cb => eventDriver.sockets.waitForData(m_socket, cb),
			cb => eventDriver.sockets.cancelRead(m_socket),
			(fd, st, nb) { got_data = st == IOStatus.ok; }
		);

		asyncAwaitAny!(true, readwaiter)(timeout);

		return got_data;
	}
}


/**
	Represents a timer.
*/
struct Timer {
	private {
		NativeEventDriver m_driver;
		TimerID m_id;
		debug uint m_magicNumber = 0x4d34f916;
	}

	alias Callback = void delegate() @safe nothrow;

	@safe:

	private static Timer create(CALLABLE)(TimerID id, CALLABLE callback)
	nothrow {
		assert(id != TimerID.init, "Invalid timer ID.");

		Timer ret;
		ret.m_driver = eventDriver;
		ret.m_id = id;

		static if (is(typeof(!callback)))
			if (!callback)
				return ret;

		ret.m_driver.timers.userData!CALLABLE(id) = callback;
		ret.m_driver.timers.wait(id, &TimerCallbackHandler!CALLABLE.instance.handle);

		return ret;
	}

	this(this)
	nothrow {
		debug assert(m_magicNumber == 0x4d34f916, "Timer corrupted.");
		if (m_driver) m_driver.timers.addRef(m_id);
	}

	~this()
	nothrow {
		debug assert(m_magicNumber == 0x4d34f916, "Timer corrupted.");
		if (m_driver) releaseHandle!"timers"(m_id, () @trusted { return cast(shared)m_driver; } ());
	}

	/// True if the timer is yet to fire.
	@property bool pending() nothrow { return m_driver.timers.isPending(m_id); }

	/// The internal ID of the timer.
	@property size_t id() const nothrow { return m_id; }

	bool opCast() const nothrow { return m_driver !is null; }

	/// Determines if this reference is the only one
	@property bool unique() const nothrow { return m_driver ? m_driver.timers.isUnique(m_id) : false; }

	/** Resets the timer to the specified timeout
	*/
	void rearm(Duration dur, bool periodic = false) nothrow
		in { assert(dur >= 0.seconds, "Negative timer duration specified."); }
	    do { m_driver.timers.set(m_id, dur, periodic ? dur : 0.seconds); }

	/** Resets the timer and avoids any firing.
	*/
	void stop() nothrow { if (m_driver) m_driver.timers.stop(m_id); }

	/** Waits until the timer fires.

		This method may only be used if no timer callback has been specified.

		Returns:
			`true` is returned $(I iff) the timer was fired.
	*/
	bool wait()
	{
		auto cb = m_driver.timers.userData!Callback(m_id);
		assert(cb is null, "Cannot wait on a timer that was created with a callback.");

		auto res = asyncAwait!(TimerCallback2,
			cb => m_driver.timers.wait(m_id, cb),
			cb => m_driver.timers.cancelWait(m_id)
		);
		return res[1];
	}

	/** Waits until the timer fires.

		Same as `wait`, except that `Task.interrupt` has no effect on the wait.
	*/
	bool waitUninterruptible()
	nothrow {
		auto cb = m_driver.timers.userData!Callback(m_id);
		assert(cb is null, "Cannot wait on a timer that was created with a callback.");

		auto res = asyncAwaitUninterruptible!(TimerCallback2,
			cb => m_driver.timers.wait(m_id, cb)
		);
		return res[1];
	}
}

private struct TimerCallbackHandler(CALLABLE) {
	static __gshared TimerCallbackHandler ms_instance;
	static @property ref TimerCallbackHandler instance() @trusted nothrow { return ms_instance; }

	void handle(TimerID timer, bool fired)
	@safe nothrow {
		if (fired) {
			auto l = yieldLock();
			auto cb = () @trusted { return &eventDriver.timers.userData!CALLABLE(timer); } ();
			static if (is(typeof(CALLABLE.init(Timer.init)))) {
				Timer tm;
				tm.m_driver = eventDriver;
				tm.m_id = timer;
				eventDriver.timers.addRef(timer);
				(*cb)(tm);
			} else (*cb)();
		}

		if (!eventDriver.timers.isUnique(timer) || eventDriver.timers.isPending(timer))
			eventDriver.timers.wait(timer, () @trusted { return &handle; } ());
	}
}


/** Returns an object that ensures that no task switches happen during its life time.

	Any attempt to run the event loop or switching to another task will cause
	an assertion to be thrown within the scope that defines the lifetime of the
	returned object.

	Multiple yield locks can appear in nested scopes.
*/
auto yieldLock(string file = __FILE__, int line = __LINE__)
@safe nothrow {
	static struct YieldLock {
	@safe nothrow:
		private {
			TaskFiber m_fiber;
		}

		private this(TaskFiber fiber) {
			m_fiber = fiber;
			inc();
		}
		@disable this(this);
		~this() { if (m_fiber) dec(); }

		private void inc()
		{
			m_fiber.acquireYieldLock();
		}

		private void dec()
		{
			m_fiber.releaseYieldLock();
		}
	}

	auto fiber = TaskFiber.getThis();
	fiber.setYieldLockContext(file, line);
	return YieldLock(fiber);
}

unittest {
	auto tf = TaskFiber.getThis();
	assert(!tf.isInYieldLock());
	{
		auto lock = yieldLock();
		assert(tf.isInYieldLock());
		{
			auto lock2 = yieldLock();
			assert(tf.isInYieldLock());
		}
		assert(tf.isInYieldLock());
	}
	assert(!tf.isInYieldLock());

	{
		typeof(yieldLock()) l;
		assert(!tf.isInYieldLock());
	}
	assert(!tf.isInYieldLock());
}


/** Less strict version of `yieldLock` that only locks if called within a task.
*/
auto taskYieldLock(string file = __FILE__, int line = __LINE__)
@safe nothrow {
	if (!Fiber.getThis()) return typeof(yieldLock()).init;
	return yieldLock(file, line);
}

debug (VibeRunningTasks) {
	/** Dumps a list of all active tasks of the calling thread.
	*/
	void printRunningTasks()
	@safe nothrow {
		string threadname = "unknown";
		try threadname = Thread.getThis.name;
		catch (Exception e) {}
		size_t cnt = 0;
		foreach (kv; TaskFiber.s_runningTasks.byKeyValue) {
			auto t = kv.key.task;
			logInfo("%s (%s): %s", t.getDebugID, threadname, kv.value);
			cnt++;
		}
		logInfo("===================================================");
		logInfo("%s: %s tasks currently active, %s available",
			threadname, cnt, s_availableFibers.length);
	}
}


/**************************************************************************************************/
/* private types                                                                                  */
/**************************************************************************************************/


private void setupGcTimer()
{
	s_gcTimer = createTimer(() @trusted {
		import core.memory;
		logTrace("gc idle collect");
		GC.collect();
		GC.minimize();
		s_ignoreIdleForGC = true;
	});
	s_gcCollectTimeout = dur!"seconds"(2);
}

package(vibe) void performIdleProcessing(bool force_process_events = false)
@safe nothrow {
	debug (VibeTaskLog) logTrace("Performing idle processing...");

	bool again = !getExitFlag();
	while (again) {
		again = performIdleProcessingOnce(force_process_events);
		force_process_events = true;
	}

	if (s_scheduler.scheduledTaskCount) logDebug("Exiting from idle processing although there are still yielded tasks");

	if (s_exitEventLoop) return;

	if (!s_ignoreIdleForGC && s_gcTimer) {
		s_gcTimer.rearm(s_gcCollectTimeout);
	} else s_ignoreIdleForGC = false;
}

private bool performIdleProcessingOnce(bool process_events)
@safe nothrow {
	if (process_events) {
		auto er = eventDriver.core.processEvents(0.seconds);
		if (er.among!(ExitReason.exited, ExitReason.outOfWaiters) && s_scheduler.scheduledTaskCount == 0) {
			if (s_eventLoopRunning) {
				logDebug("Setting exit flag due to driver signalling exit: %s", er);
				s_exitEventLoop = true;
			}
			return false;
		}
	}

	bool again;
	if (s_idleHandler)
		again = s_idleHandler();

	return (s_scheduler.schedule() == ScheduleStatus.busy || again) && !getExitFlag();
}


private struct ThreadContext {
	Thread thread;
}

/**************************************************************************************************/
/* private functions                                                                              */
/**************************************************************************************************/

private {
	Duration s_gcCollectTimeout;
	Timer s_gcTimer;
	bool s_ignoreIdleForGC = false;

	__gshared core.sync.mutex.Mutex st_threadsMutex;
	shared TaskPool st_workerPool;
	shared TaskPool st_ioWorkerPool;
	shared ManualEvent st_threadsSignal;
	__gshared ThreadContext[] st_threads;
	__gshared Condition st_threadShutdownCondition;
	shared bool st_term = false;

	bool s_isMainThread = false; // set in shared static this
	bool s_exitEventLoop = false;
	package bool s_eventLoopRunning = false;
	bool delegate() @safe nothrow s_idleHandler;

	TaskScheduler s_scheduler;
	RingBuffer!TaskFiber s_availableFibers;
	size_t s_maxRecycledFibers = 100;

	string s_privilegeLoweringUserName;
	string s_privilegeLoweringGroupName;
	__gshared bool s_disableSignalHandlers = false;
}

private bool getExitFlag()
@trusted nothrow {
	return s_exitEventLoop || atomicLoad(st_term);
}

package @property bool isEventLoopRunning() @safe nothrow @nogc { return s_eventLoopRunning; }
package @property ref TaskScheduler taskScheduler() @safe nothrow @nogc { return s_scheduler; }

package bool recycleFiber(TaskFiber fiber)
@safe nothrow {
	if (s_availableFibers.length >= s_maxRecycledFibers)
		return false;

	if (s_availableFibers.full)
		s_availableFibers.capacity = 2 * s_availableFibers.capacity;

	s_availableFibers.put(fiber);
	return true;
}

@safe nothrow unittest { // check fiber recycling and recycling overflow
	auto tasks = new Task[](s_maxRecycledFibers+1);
	foreach (i; 0 .. 2) {
		int nrunning = 0;
		bool all_running = false;
		foreach (ref t; tasks) t = runTask({
			if (++nrunning == tasks.length) all_running = true;
			while (!all_running)
				yieldUninterruptible();
			nrunning--;
		});
		foreach (t; tasks) t.joinUninterruptible();
	}
}

private void setupSignalHandlers()
@trusted nothrow {
	scope (failure) assert(false); // _d_monitorexit is not nothrow
	__gshared bool s_setup = false;

	// only initialize in main thread
	synchronized (st_threadsMutex) {
		if (s_setup) return;
		s_setup = true;

		if (s_disableSignalHandlers) return;

		logTrace("setup signal handler");
		version(Posix){
			// support proper shutdown using signals
			sigset_t sigset;
			sigemptyset(&sigset);
			sigaction_t siginfo;
			siginfo.sa_handler = &onSignal;
			siginfo.sa_mask = sigset;
			siginfo.sa_flags = SA_RESTART;
			sigaction(SIGINT, &siginfo, null);
			sigaction(SIGTERM, &siginfo, null);

			siginfo.sa_handler = &onBrokenPipe;
			sigaction(SIGPIPE, &siginfo, null);
		}

		version(Windows){
			// WORKAROUND: we don't care about viral @nogc attribute here!
			import std.traits;
			signal(SIGTERM, cast(ParameterTypeTuple!signal[1])&onSignal);
			signal(SIGINT, cast(ParameterTypeTuple!signal[1])&onSignal);
		}
	}
}

// per process setup
shared static this()
{
	s_isMainThread = true;

	// COMPILER BUG: Must be some kind of module constructor order issue:
	//    without this, the stdout/stderr handles are not initialized before
	//    the log module is set up.
	import std.stdio; File f; f.close();

	initializeLogModule();

	logTrace("create driver core");

	st_threadsMutex = new Mutex;
	st_threadShutdownCondition = new Condition(st_threadsMutex);

	auto thisthr = Thread.getThis();
	thisthr.name = "main";
	assert(st_threads.length == 0, "Main thread not the first thread!?");
	st_threads ~= ThreadContext(thisthr);

	st_threadsSignal = createSharedManualEvent();

	version(VibeIdleCollect) {
		logTrace("setup gc");
		setupGcTimer();
	}

	version (VibeNoDefaultArgs) {}
	else {
		readOption("uid|user", &s_privilegeLoweringUserName, "Sets the user name or id used for privilege lowering.");
		readOption("gid|group", &s_privilegeLoweringGroupName, "Sets the group name or id used for privilege lowering.");
	}

	import std.concurrency;
	scheduler = new VibedScheduler;
}

shared static ~this()
{
	destroy(st_threadsSignal);

	shutdownDriver();

	size_t tasks_left = s_scheduler.scheduledTaskCount;

	if (tasks_left > 0) {
		logWarn("There were still %d tasks running at exit.", tasks_left);

		debug (VibeRunningTasks)
			printRunningTasks();
	}
}

// per thread setup
static this()
{
	/// workaround for:
	// object.Exception@src/rt/minfo.d(162): Aborting: Cycle detected between modules with ctors/dtors:
	// vibe.core.core -> vibe.core.drivers.native -> vibe.core.drivers.libasync -> vibe.core.core
	if (Thread.getThis().isDaemon && Thread.getThis().name == "CmdProcessor") return;

	auto thisthr = Thread.getThis();
	synchronized (st_threadsMutex)
		if (!st_threads.any!(c => c.thread is thisthr))
			st_threads ~= ThreadContext(thisthr);
}

static ~this()
{
	auto thisthr = Thread.getThis();

	bool is_main_thread = s_isMainThread;

	synchronized (st_threadsMutex) {
		auto idx = st_threads.countUntil!(c => c.thread is thisthr);
		logDebug("Thread exit %s (index %s) (main=%s)", thisthr.name, idx, is_main_thread);
	}

	if (is_main_thread) {
		logDiagnostic("Main thread exiting");
		shutdownWorkerPool();
	}

	foreach (f; s_availableFibers)
		f.shutdown();

	import vibe.core.internal.threadlocalwaiter : freeThreadResources;
	freeThreadResources();

	synchronized (st_threadsMutex) {
		auto idx = st_threads.countUntil!(c => c.thread is thisthr);
		assert(idx >= 0, "No more threads registered");
		if (idx >= 0) {
			st_threads[idx] = st_threads[$-1];
			st_threads.length--;
		}
	}

	// delay deletion of the main event driver to "~shared static this()"
	if (!is_main_thread) shutdownDriver();

	st_threadShutdownCondition.notifyAll();
}

private void shutdownWorkerPool()
nothrow {
	shared(TaskPool) tpool;

	try synchronized (st_threadsMutex) swap(tpool, st_workerPool);
	catch (Exception e) assert(false, e.msg);

	if (tpool) {
		logDiagnostic("Still waiting for worker threads to exit.");
		tpool.terminate();
	}

	tpool = null;

	try synchronized (st_threadsMutex) swap(tpool, st_ioWorkerPool);
	catch (Exception e) assert(false, e.msg);

	if (tpool) {
		logDiagnostic("Still waiting for I/O worker threads to exit.");
		tpool.terminate();
	}
}

private void shutdownDriver()
{
	static if (is(typeof(tryGetEventDriver()))) {
		// avoid creating an event driver on threads that don't actually have one
		if (auto drv = tryGetEventDriver())
			drv.dispose();
	} else eventDriver.dispose();
}


private void watchExitFlag()
nothrow {
	auto emit_count = st_threadsSignal.emitCount;
	while (true) {
		{
			st_threadsMutex.lock_nothrow();
			scope (exit) st_threadsMutex.unlock_nothrow();
			if (getExitFlag()) break;
		}

		try emit_count = st_threadsSignal.wait(emit_count);
		catch (InterruptException e) return;
		catch (Exception e) assert(false, e.msg);
	}

	logDebug("main thread exit");
	eventDriver.core.exit();
}

private extern(C) void extrap()
@safe nothrow {
	logTrace("exception trap");
}

private extern(C) void onSignal(int signal)
nothrow {
	logInfo("Received signal %d. Shutting down.", signal);
	atomicStore(st_term, true);
	try st_threadsSignal.emit();
	catch (Throwable th) {
		logDebug("Failed to notify for event loop exit: %s", th.msg);
	}

	// Stop the event loop of the current thread directly instead of relying on
	// the st_term mechanic, as the event loop might be in a waiting state, so
	// that no tasks can get scheduled before an event arrives. Explicitly
	// exiting the event loop on the other hand always terminates the wait state.
	if (auto drv = tryGetEventDriver())
		drv.core.exit();
}

private extern(C) void onBrokenPipe(int signal)
nothrow {
	logTrace("Broken pipe.");
}

version(Posix)
{
	private bool isRoot() @trusted { return geteuid() == 0; }

	private void setUID(int uid, int gid)
	@trusted {
		logInfo("Lowering privileges to uid=%d, gid=%d...", uid, gid);
		if (gid >= 0) {
			enforce(getgrgid(gid) !is null, "Invalid group id!");
			enforce(setegid(gid) == 0, "Error setting group id!");
		}
		//if( initgroups(const char *user, gid_t group);
		if (uid >= 0) {
			enforce(getpwuid(uid) !is null, "Invalid user id!");
			enforce(seteuid(uid) == 0, "Error setting user id!");
		}
	}

	private int getUID(string name)
	@trusted {
		auto pw = getpwnam(name.toStringz());
		enforce(pw !is null, "Unknown user name: "~name);
		return pw.pw_uid;
	}

	private int getGID(string name)
	@trusted {
		auto gr = getgrnam(name.toStringz());
		enforce(gr !is null, "Unknown group name: "~name);
		return gr.gr_gid;
	}
} else version(Windows){
	private bool isRoot() @safe { return false; }

	private void setUID(int uid, int gid)
	@safe {
		enforce(false, "UID/GID not supported on Windows.");
	}

	private int getUID(string name)
	@safe {
		enforce(false, "Privilege lowering not supported on Windows.");
		assert(false);
	}

	private int getGID(string name)
	@safe {
		enforce(false, "Privilege lowering not supported on Windows.");
		assert(false);
	}
}
