/**
	This module contains the core functionality of the vibe.d framework.

	Copyright: © 2012-2017 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.core;

public import vibe.core.task;

import eventcore.core;
import vibe.core.args;
import vibe.core.concurrency;
import vibe.core.log;
import vibe.core.sync : ManualEvent, createSharedManualEvent;
import vibe.core.taskpool : TaskPool;
import vibe.internal.async;
import vibe.internal.array : FixedRingBuffer;
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
import std.variant;
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
	try if (!() @trusted { return finalizeCommandLineOptions(); } () ) return 0;
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
		} catch( Throwable th ){
			logError("Unhandled exception in event loop: %s", th.msg);
			logDiagnostic("Full exception: %s", th.toString().sanitize());
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
		s_eventLoopRunning = false;
		s_exitEventLoop = false;
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
	// TODO: would be niced to do this without exceptions
	if (exit_task && exit_task.running)
		exit_task.interrupt();

	logDebug("Event loop done (scheduled tasks=%s, waiters=%s, thread exit=%s).",
		s_scheduler.scheduledTaskCount, eventDriver.core.waiterCount, s_exitEventLoop);
	eventDriver.core.clearExitFlag();
	s_exitEventLoop = false;
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
*/
ExitReason runEventLoopOnce()
@safe nothrow {
	auto ret = s_scheduler.waitAndProcess();
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
Task runTask(ARGS...)(void delegate(ARGS) @safe task, auto ref ARGS args)
{
	return runTask_internal!((ref tfi) { tfi.set(task, args); });
}
///
Task runTask(ARGS...)(void delegate(ARGS) @system task, auto ref ARGS args)
@system {
	return runTask_internal!((ref tfi) { tfi.set(task, args); });
}
/// ditto
Task runTask(CALLABLE, ARGS...)(CALLABLE task, auto ref ARGS args)
	if (!is(CALLABLE : void delegate(ARGS)) && is(typeof(CALLABLE.init(ARGS.init))))
{
	return runTask_internal!((ref tfi) { tfi.set(task, args); });
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
		s_availableFibers.popBack();
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

	debug if (TaskFiber.ms_taskEventCallback) {
		() @trusted { TaskFiber.ms_taskEventCallback(TaskEvent.preStart, handle); } ();
	}

	s_scheduler.switchTo(handle, TaskFiber.getThis().m_yieldLockCount > 0 ? Flag!"defer".yes : Flag!"defer".no);

	debug if (TaskFiber.ms_taskEventCallback) {
		() @trusted { TaskFiber.ms_taskEventCallback(TaskEvent.postStart, handle); } ();
	}

	return handle;
}

/**
	Runs a new asynchronous task in a worker thread.

	Only function pointers with weakly isolated arguments are allowed to be
	able to guarantee thread-safety.
*/
void runWorkerTask(FT, ARGS...)(FT func, auto ref ARGS args)
	if (isFunctionPointer!FT)
{
	setupWorkerThreads();
	st_workerPool.runTask(func, args);
}

/// ditto
void runWorkerTask(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
	if (is(typeof(__traits(getMember, object, __traits(identifier, method)))))
{
	setupWorkerThreads();
	st_workerPool.runTask!method(object, args);
}

/**
	Runs a new asynchronous task in a worker thread, returning the task handle.

	This function will yield and wait for the new task to be created and started
	in the worker thread, then resume and return it.

	Only function pointers with weakly isolated arguments are allowed to be
	able to guarantee thread-safety.
*/
Task runWorkerTaskH(FT, ARGS...)(FT func, auto ref ARGS args)
	if (isFunctionPointer!FT)
{
	setupWorkerThreads();
	return st_workerPool.runTaskH(func, args);
}
/// ditto
Task runWorkerTaskH(alias method, T, ARGS...)(shared(T) object, auto ref ARGS args)
	if (is(typeof(__traits(getMember, object, __traits(identifier, method)))))
{
	setupWorkerThreads();
	return st_workerPool.runTaskH!method(object, args);
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
		shared {
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
	{
		int counter = 10;
		while (receiveOnly!string() == "ping" && --counter) {
			logInfo("pong");
			caller.send("pong");
		}
		caller.send("goodbye");

	}

	static void test()
	{
		Task callee = runWorkerTaskH(&workerFunc, Task.getThis);
		do {
			logInfo("ping");
			callee.send("ping");
		} while (receiveOnly!string() == "pong");
	}

	static void work719(int) {}
	static void test719() { runWorkerTaskH(&work719, cast(ubyte)42); }
}

/// Running a worker task using a class method and communicating with it
unittest {
	static class Test {
		void workerMethod(Task caller) shared {
			int counter = 10;
			while (receiveOnly!string() == "ping" && --counter) {
				logInfo("pong");
				caller.send("pong");
			}
			caller.send("goodbye");
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
		void work(int) shared {}
	}
	static void test719() {
		auto cls = new shared Class719;
		runWorkerTaskH!(Class719.work)(cls, cast(ubyte)42);
	}
}

unittest { // run and join local task from outside of a task
	int i = 0;
	auto t = runTask({ sleep(1.msecs); i = 1; });
	t.join();
	assert(i == 1);
}

unittest { // run and join worker task from outside of a task
	__gshared int i = 0;
	auto t = runWorkerTaskH({ sleep(5.msecs); i = 1; });
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
	if (is(typeof(*func) == function))
{
	setupWorkerThreads();
	return st_workerPool.runTaskDist(func, args);
}
/// ditto
void runWorkerTaskDist(alias method, T, ARGS...)(shared(T) object, ARGS args)
{
	setupWorkerThreads();
	return st_workerPool.runTaskDist!method(object, args);
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
public void setupWorkerThreads(uint num = logicalProcessorCount())
{
	static bool s_workerThreadsStarted = false;
	if (s_workerThreadsStarted) return;
	s_workerThreadsStarted = true;

	synchronized (st_threadsMutex) {
		if (!st_workerPool)
			st_workerPool = new shared TaskPool;
	}
}


/**
	Determines the number of logical processors in the system.

	This number includes virtual cores on hyper-threading enabled CPUs.
*/
public @property uint logicalProcessorCount()
{
	version (linux) {
		import core.sys.linux.sys.sysinfo;
		return get_nprocs();
	} else version (OSX) {
		int count;
		size_t count_len = count.sizeof;
		sysctlbyname("hw.logicalcpu", &count, &count_len, null, 0);
		return cast(uint)count_len;
        } else version (FreeBSD) {
                int count;
                size_t count_len = count.sizeof;
                sysctlbyname("hw.logicalcpu", &count, &count_len, null, 0);
                return cast(uint)count_len;
        } else version (NetBSD) {
                int count;
                size_t count_len = count.sizeof;
                sysctlbyname("hw.logicalcpu", &count, &count_len, null, 0);
                return cast(uint)count_len;
	} else version (Windows) {
		import core.sys.windows.windows;
		SYSTEM_INFO sysinfo;
		GetSystemInfo(&sysinfo);
		return sysinfo.dwNumberOfProcessors;
	} else static assert(false, "Unsupported OS!");
}
version (OSX) private extern(C) int sysctlbyname(const(char)* name, void* oldp, size_t* oldlen, void* newp, size_t newlen);
version (FreeBSD) private extern(C) int sysctlbyname(const(char)* name, void* oldp, size_t* oldlen, void* newp, size_t newlen);
version (NetBSD) private extern(C) int sysctlbyname(const(char)* name, void* oldp, size_t* oldlen, void* newp, size_t newlen);
version (linux) static if (__VERSION__ <= 2066) private extern(C) int get_nprocs();

/**
	Suspends the execution of the calling task to let other tasks and events be
	handled.

	Calling this function in short intervals is recommended if long CPU
	computations are carried out by a task. It can also be used in conjunction
	with Signals to implement cross-fiber events with no polling.

	Throws:
		May throw an `InterruptException` if `Task.interrupt()` gets called on
		the calling task.
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
		// Let yielded tasks execute
		assert(TaskFiber.getThis().m_yieldLockCount == 0, "May not yield within an active yieldLock()!");
		() @safe nothrow { performIdleProcessing(); } ();
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
		assert(TaskFiber.getThis().m_yieldLockCount == 0, "May not yield within an active yieldLock!");
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

	See_Also: `hibernate`
*/
void switchToTask(Task t)
@safe nothrow {
	s_scheduler.switchTo(t);
}


/**
	Suspends the execution of the calling task for the specified amount of time.

	Note that other tasks of the same thread will continue to run during the
	wait time, in contrast to $(D core.thread.Thread.sleep), which shouldn't be
	used in vibe.d applications.

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


/**
	Returns a new armed timer.

	Note that timers can only work if an event loop is running.

	Params:
		timeout = Determines the minimum amount of time that elapses before the timer fires.
		callback = This delegate will be called when the timer fires
		periodic = Speficies if the timer fires repeatedly or only once

	Returns:
		Returns a Timer object that can be used to identify and modify the timer.

	See_also: createTimer
*/
Timer setTimer(Duration timeout, void delegate() nothrow @safe callback, bool periodic = false)
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
			logWarn("Timer callback failed: %s", e.msg);
			scope (failure) assert(false);
			logDebug("Full error: %s", e.toString().sanitize);
		}
	});
}

/**
	Creates a new timer without arming it.

	See_also: setTimer
*/
Timer createTimer(void delegate() nothrow @safe callback)
@safe nothrow {
	auto ret = Timer(eventDriver.timers.create());
	if (callback !is null) {
		runTask((void delegate() nothrow @safe cb, Timer tm) {
			while (!tm.unique || tm.pending) {
				tm.wait();
				cb();
			}
		}, callback, ret);
	}
	return ret;
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
@property size_t workerThreadCount()
	out(count) { assert(count > 0, "No worker threads started after setupWorkerThreads!?"); }
body {
	setupWorkerThreads();
	return st_threads.count!(c => c.isWorker);
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
	A version string representing the current vibe version
*/
enum vibeVersionString = "1.0.0";


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
		StreamSocketFD m_socket;
		Trigger m_trigger;
	}

	@safe:

	private this(int fd, Trigger event_mask)
	nothrow {
		m_socket = eventDriver.sockets.adoptStream(fd);
	}

	this(this)
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			eventDriver.sockets.addRef(m_socket);
	}

	~this()
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			eventDriver.sockets.releaseRef(m_socket);
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
		if ((which & m_trigger) == Trigger.none) return true;

		assert((which & m_trigger) == Trigger.read, "Waiting for write event not yet supported.");

		Waitable!(IOCallback,
			cb => eventDriver.sockets.waitForData(m_socket, cb),
			(cb) { assert(false, "timeout not supported."); }
		) readwaiter;

		asyncAwaitAny!true(timeout, readwaiter);

		return true;
	}
}


/**
	Represents a timer.
*/
struct Timer {
	private {
		typeof(eventDriver.timers) m_driver;
		TimerID m_id;
		debug uint m_magicNumber = 0x4d34f916;
	}

	@safe:

	private this(TimerID id)
	nothrow {
		assert(id != TimerID.init, "Invalid timer ID.");
		m_driver = eventDriver.timers;
		m_id = id;
	}

	this(this)
	nothrow {
		debug assert(m_magicNumber == 0x4d34f916, "Timer corrupted.");
		if (m_driver) m_driver.addRef(m_id);
	}

	~this()
	nothrow {
		debug assert(m_magicNumber == 0x4d34f916, "Timer corrupted.");
		if (m_driver) m_driver.releaseRef(m_id);
	}

	/// True if the timer is yet to fire.
	@property bool pending() nothrow { return m_driver.isPending(m_id); }

	/// The internal ID of the timer.
	@property size_t id() const nothrow { return m_id; }

	bool opCast() const nothrow { return m_driver !is null; }

	/// Determines if this reference is the only one
	@property bool unique() const nothrow { return m_driver ? m_driver.isUnique(m_id) : false; }

	/** Resets the timer to the specified timeout
	*/
	void rearm(Duration dur, bool periodic = false) nothrow 
		in { assert(dur > 0.seconds, "Negative timer duration specified."); }
		body { m_driver.set(m_id, dur, periodic ? dur : 0.seconds); }

	/** Resets the timer and avoids any firing.
	*/
	void stop() nothrow { if (m_driver) m_driver.stop(m_id); }

	/** Waits until the timer fires.
	*/
	void wait()
	{
		asyncAwait!(TimerCallback,
			cb => m_driver.wait(m_id, cb),
			cb => m_driver.cancelWait(m_id)
		);
	}
}


/** Returns an object that ensures that no task switches happen during its life time.

	Any attempt to run the event loop or switching to another task will cause
	an assertion to be thrown within the scope that defines the lifetime of the
	returned object.

	Multiple yield locks can appear in nested scopes.
*/
auto yieldLock()
{
	static struct YieldLock {
		private this(bool) { inc(); }
		@disable this();
		@disable this(this);
		~this() { dec(); }

		private void inc()
		{
			TaskFiber.getThis().m_yieldLockCount++;
		}

		private void dec()
		{
			TaskFiber.getThis().m_yieldLockCount--;
		}
	}

	return YieldLock(true);
}

unittest {
	auto tf = TaskFiber.getThis();
	assert(tf.m_yieldLockCount == 0);
	{
		auto lock = yieldLock();
		assert(tf.m_yieldLockCount == 1);
		{
			auto lock2 = yieldLock();
			assert(tf.m_yieldLockCount == 2);
		}
		assert(tf.m_yieldLockCount == 1);
	}
	assert(tf.m_yieldLockCount == 0);
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

package(vibe) void performIdleProcessing()
@safe nothrow {
	bool again = !getExitFlag();
	while (again) {
		if (s_idleHandler)
			again = s_idleHandler();
		else again = false;

		again = (s_scheduler.schedule() == ScheduleStatus.busy || again) && !getExitFlag();

		if (again) {
			auto er = eventDriver.core.processEvents(0.seconds);
			if (er.among!(ExitReason.exited, ExitReason.outOfWaiters)) {
				logDebug("Setting exit flag due to driver signalling exit");
				s_exitEventLoop = true;
				return;
			}
		}
	}

	if (s_scheduler.scheduledTaskCount) logDebug("Exiting from idle processing although there are still yielded tasks");

	if (!s_ignoreIdleForGC && s_gcTimer) {
		s_gcTimer.rearm(s_gcCollectTimeout);
	} else s_ignoreIdleForGC = false;
}


private struct ThreadContext {
	Thread thread;
	bool isWorker;

	this(Thread thr, bool worker) { this.thread = thr; this.isWorker = worker; }
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
	shared ManualEvent st_threadsSignal;
	__gshared ThreadContext[] st_threads;
	__gshared Condition st_threadShutdownCondition;
	shared bool st_term = false;

	bool s_isMainThread = false; // set in shared static this
	bool s_exitEventLoop = false;
	package bool s_eventLoopRunning = false;
	bool delegate() @safe nothrow s_idleHandler;

	TaskScheduler s_scheduler;
	FixedRingBuffer!TaskFiber s_availableFibers;
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

package void recycleFiber(TaskFiber fiber)
@safe nothrow {
	if (s_availableFibers.length >= s_maxRecycledFibers) {
		auto fl = s_availableFibers.front;
		s_availableFibers.popFront();
		fl.shutdown();
		() @trusted {
			try destroy(fl);
			catch (Exception e) logWarn("Failed to destroy fiber: %s", e.msg);
		} ();
	}

	if (s_availableFibers.full)
		s_availableFibers.capacity = 2 * s_availableFibers.capacity;

	s_availableFibers.put(fiber);
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
			signal(SIGABRT, cast(ParameterTypeTuple!signal[1])&onSignal);
			signal(SIGTERM, cast(ParameterTypeTuple!signal[1])&onSignal);
			signal(SIGINT, cast(ParameterTypeTuple!signal[1])&onSignal);
		}
	}
}

// per process setup
shared static this()
{
	version(Windows){
		version(VibeLibeventDriver) enum need_wsa = true;
		else version(VibeWin32Driver) enum need_wsa = true;
		else enum need_wsa = false;
		static if (need_wsa) {
			logTrace("init winsock");
			// initialize WinSock2
			import std.c.windows.winsock;
			WSADATA data;
			WSAStartup(0x0202, &data);

		}
	}

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
	st_threads ~= ThreadContext(thisthr, false);

	st_threadsSignal = createSharedManualEvent();

	version(VibeIdleCollect) {
		logTrace("setup gc");
		driverCore.setupGcTimer();
	}

	version (VibeNoDefaultArgs) {}
	else {
		readOption("uid|user", &s_privilegeLoweringUserName, "Sets the user name or id used for privilege lowering.");
		readOption("gid|group", &s_privilegeLoweringGroupName, "Sets the group name or id used for privilege lowering.");
	}

	import std.concurrency;
	scheduler = new VibedScheduler;

	import vibe.core.sync : SpinLock;
	SpinLock.setup();
}

shared static ~this()
{
	shutdownDriver();

	size_t tasks_left = s_scheduler.scheduledTaskCount;

	if (tasks_left > 0)
		logWarn("There were still %d tasks running at exit.", tasks_left);
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
			st_threads ~= ThreadContext(thisthr, false);


	import vibe.core.sync : SpinLock;
	SpinLock.setup();
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
		shared(TaskPool) tpool;
		synchronized (st_threadsMutex) swap(tpool, st_workerPool);
		if (tpool) {
			logDiagnostic("Main thread still waiting for worker threads.");
			tpool.terminate();
		}
		logDiagnostic("Main thread exiting");
	}

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

private void shutdownDriver()
{
	if (ManualEvent.ms_threadEvent != EventID.init) {
		eventDriver.events.releaseRef(ManualEvent.ms_threadEvent);
		ManualEvent.ms_threadEvent = EventID.init;
	}

	eventDriver.dispose();
}


private void watchExitFlag()
{
	auto emit_count = st_threadsSignal.emitCount;
	while (true) {
		synchronized (st_threadsMutex) {
			if (getExitFlag()) break;
		}

		try emit_count = st_threadsSignal.wait(emit_count);
		catch (InterruptException e) return;
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
	atomicStore(st_term, true);
	try st_threadsSignal.emit(); catch (Throwable) {}

	logInfo("Received signal %d. Shutting down.", signal);
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

// DMD currently has no option to set merging of coverage files at compile-time
// This needs to be done via a Druntime API
// As this option is solely for Vibed's internal testsuite, it's hidden behind
// a long version
version(VibedCoreSetCoverageMerge)
shared static this() {
	import core.runtime : dmd_coverSetMerge;
	dmd_coverSetMerge(true);
}
