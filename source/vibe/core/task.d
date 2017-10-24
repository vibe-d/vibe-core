/**
	Contains interfaces and enums for evented I/O drivers.

	Copyright: © 2012-2016 RejectedSoftware e.K.
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.task;

import vibe.core.log;
import vibe.core.sync;

import core.thread;
import std.exception;
import std.traits;
import std.typecons;
import std.variant;


/** Represents a single task as started using vibe.core.runTask.

	Note that the Task type is considered weakly isolated and thus can be
	passed between threads using vibe.core.concurrency.send or by passing
	it as a parameter to vibe.core.core.runWorkerTask.
*/
struct Task {
	private {
		shared(TaskFiber) m_fiber;
		size_t m_taskCounter;
		import std.concurrency : ThreadInfo, Tid;
		static ThreadInfo s_tidInfo;
	}

	private this(TaskFiber fiber, size_t task_counter)
	@safe nothrow {
		() @trusted { m_fiber = cast(shared)fiber; } ();
		m_taskCounter = task_counter;
	}

	this(in Task other)
	@safe nothrow {
		m_fiber = () @trusted { return cast(shared(TaskFiber))other.m_fiber; } ();
		m_taskCounter = other.m_taskCounter;
	}

	/** Returns the Task instance belonging to the calling task.
	*/
	static Task getThis() @safe nothrow
	{
		// In 2067, synchronized statements where annotated nothrow.
		// DMD#4115, Druntime#1013, Druntime#1021, Phobos#2704
		// However, they were "logically" nothrow before.
		static if (__VERSION__ <= 2066)
			scope (failure) assert(0, "Internal error: function should be nothrow");

		auto fiber = () @trusted { return Fiber.getThis(); } ();
		if (!fiber) return Task.init;
		auto tfiber = cast(TaskFiber)fiber;
		if (!tfiber) return Task.init;
		// FIXME: returning a non-.init handle for a finished task might break some layered logic
		return () @trusted { return Task(tfiber, tfiber.m_taskCounter); } ();
	}

	nothrow {
		package @property inout(TaskFiber) taskFiber() inout @system { return cast(inout(TaskFiber))m_fiber; }
		@property inout(Fiber) fiber() inout @system { return this.taskFiber; }
		@property size_t taskCounter() const @safe { return m_taskCounter; }
		@property inout(Thread) thread() inout @trusted { if (m_fiber) return this.taskFiber.thread; return null; }

		/** Determines if the task is still running.
		*/
		@property bool running() // FIXME: this is NOT thread safe
		const @trusted {
			assert(m_fiber !is null, "Invalid task handle");
			try if (this.taskFiber.state == Fiber.State.TERM) return false; catch (Throwable) {}
			return this.taskFiber.m_running && this.taskFiber.m_taskCounter == m_taskCounter;
		}

		package @property ref inout(ThreadInfo) tidInfo() inout @system { return m_fiber ? taskFiber.tidInfo : s_tidInfo; } // FIXME: this is not thread safe!

		/** Gets the `Tid` associated with this task for use with
			`std.concurrency`.
		*/
		@property inout(Tid) tid() inout @trusted { return tidInfo.ident; }
	}

	T opCast(T)() const @safe nothrow if (is(T == bool)) { return m_fiber !is null; }

	void join() @trusted { if (running) taskFiber.join!true(m_taskCounter); } // FIXME: this is NOT thread safe
	void joinUninterruptible() @trusted nothrow { if (running) taskFiber.join!false(m_taskCounter); } // FIXME: this is NOT thread safe
	void interrupt() @trusted nothrow { if (running) taskFiber.interrupt(m_taskCounter); } // FIXME: this is NOT thread safe

	string toString() const @safe { import std.string; return format("%s:%s", () @trusted { return cast(void*)m_fiber; } (), m_taskCounter); }

	void getDebugID(R)(ref R dst)
	{
		import std.digest.md : MD5;
		import std.bitmanip : nativeToLittleEndian;
		import std.base64 : Base64;

		if (!m_fiber) {
			dst.put("----");
			return;
		}

		MD5 md;
		md.start();
		md.put(nativeToLittleEndian(() @trusted { return cast(size_t)cast(void*)m_fiber; } ()));
		md.put(nativeToLittleEndian(m_taskCounter));
		Base64.encode(md.finish()[0 .. 3], dst);
		if (!this.running) dst.put("-fin");
	}
	string getDebugID()
	@trusted {
		import std.array : appender;
		auto app = appender!string;
		getDebugID(app);
		return app.data;
	}

	bool opEquals(in ref Task other) const @safe nothrow { return m_fiber is other.m_fiber && m_taskCounter == other.m_taskCounter; }
	bool opEquals(in Task other) const @safe nothrow { return m_fiber is other.m_fiber && m_taskCounter == other.m_taskCounter; }
}

/**
	Implements a task local storage variable.

	Task local variables, similar to thread local variables, exist separately
	in each task. Consequently, they do not need any form of synchronization
	when accessing them.

	Note, however, that each TaskLocal variable will increase the memory footprint
	of any task that uses task local storage. There is also an overhead to access
	TaskLocal variables, higher than for thread local variables, but generelly
	still O(1) (since actual storage acquisition is done lazily the first access
	can require a memory allocation with unknown computational costs).

	Notice:
		FiberLocal instances MUST be declared as static/global thread-local
		variables. Defining them as a temporary/stack variable will cause
		crashes or data corruption!

	Examples:
		---
		TaskLocal!string s_myString = "world";

		void taskFunc()
		{
			assert(s_myString == "world");
			s_myString = "hello";
			assert(s_myString == "hello");
		}

		shared static this()
		{
			// both tasks will get independent storage for s_myString
			runTask(&taskFunc);
			runTask(&taskFunc);
		}
		---
*/
struct TaskLocal(T)
{
	private {
		size_t m_offset = size_t.max;
		size_t m_id;
		T m_initValue;
		bool m_hasInitValue = false;
	}

	this(T init_val) { m_initValue = init_val; m_hasInitValue = true; }

	@disable this(this);

	void opAssign(T value) { this.storage = value; }

	@property ref T storage()
	@safe {
		import std.conv : emplace;

		auto fiber = TaskFiber.getThis();

		// lazily register in FLS storage
		if (m_offset == size_t.max) {
			static assert(T.alignof <= 8, "Unsupported alignment for type "~T.stringof);
			assert(TaskFiber.ms_flsFill % 8 == 0, "Misaligned fiber local storage pool.");
			m_offset = TaskFiber.ms_flsFill;
			m_id = TaskFiber.ms_flsCounter++;


			TaskFiber.ms_flsFill += T.sizeof;
			while (TaskFiber.ms_flsFill % 8 != 0)
				TaskFiber.ms_flsFill++;
		}

		// make sure the current fiber has enough FLS storage
		if (fiber.m_fls.length < TaskFiber.ms_flsFill) {
			fiber.m_fls.length = TaskFiber.ms_flsFill + 128;
			() @trusted { fiber.m_flsInit.length = TaskFiber.ms_flsCounter + 64; } ();
		}

		// return (possibly default initialized) value
		auto data = () @trusted { return fiber.m_fls.ptr[m_offset .. m_offset+T.sizeof]; } ();
		if (!() @trusted { return fiber.m_flsInit[m_id]; } ()) {
			() @trusted { fiber.m_flsInit[m_id] = true; } ();
			import std.traits : hasElaborateDestructor, hasAliasing;
			static if (hasElaborateDestructor!T || hasAliasing!T) {
				void function(void[], size_t) destructor = (void[] fls, size_t offset){
					static if (hasElaborateDestructor!T) {
						auto obj = cast(T*)&fls[offset];
						// call the destructor on the object if a custom one is known declared
						obj.destroy();
					}
					else static if (hasAliasing!T) {
						// zero the memory to avoid false pointers
						foreach (size_t i; offset .. offset + T.sizeof) {
							ubyte* u = cast(ubyte*)&fls[i];
							*u = 0;
						}
					}
				};
				FLSInfo fls_info;
				fls_info.fct = destructor;
				fls_info.offset = m_offset;

				// make sure flsInfo has enough space
				if (TaskFiber.ms_flsInfo.length <= m_id)
					TaskFiber.ms_flsInfo.length = m_id + 64;

				TaskFiber.ms_flsInfo[m_id] = fls_info;
			}

			if (m_hasInitValue) {
				static if (__traits(compiles, () @trusted { emplace!T(data, m_initValue); } ()))
					() @trusted { emplace!T(data, m_initValue); } ();
				else assert(false, "Cannot emplace initialization value for type "~T.stringof);
			} else () @trusted { emplace!T(data); } ();
		}
		return *() @trusted { return cast(T*)data.ptr; } ();
	}

	alias storage this;
}


/** Exception that is thrown by Task.interrupt.
*/
class InterruptException : Exception {
	this()
	@safe nothrow {
		super("Task interrupted.");
	}
}

/**
	High level state change events for a Task
*/
enum TaskEvent {
	preStart,  /// Just about to invoke the fiber which starts execution
	postStart, /// After the fiber has returned for the first time (by yield or exit)
	start,     /// Just about to start execution
	yield,     /// Temporarily paused
	resume,    /// Resumed from a prior yield
	end,       /// Ended normally
	fail       /// Ended with an exception
}

struct TaskCreationInfo {
	Task handle;
	const(void)* functionPointer;
}

alias TaskEventCallback = void function(TaskEvent, Task) nothrow;
alias TaskCreationCallback = void function(ref TaskCreationInfo) nothrow @safe;

/**
	The maximum combined size of all parameters passed to a task delegate

	See_Also: runTask
*/
enum maxTaskParameterSize = 128;


/** The base class for a task aka Fiber.

	This class represents a single task that is executed concurrently
	with other tasks. Each task is owned by a single thread.
*/
final package class TaskFiber : Fiber {
	static if ((void*).sizeof >= 8) enum defaultTaskStackSize = 16*1024*1024;
	else enum defaultTaskStackSize = 512*1024;

	private {
		import std.concurrency : ThreadInfo;
		import std.bitmanip : BitArray;

		// task queue management (TaskScheduler.m_taskQueue)
		TaskFiber m_prev, m_next;
		TaskFiberQueue* m_queue;

		Thread m_thread;
		ThreadInfo m_tidInfo;
		shared size_t m_taskCounter;
		shared bool m_running;
		bool m_shutdown = false;

		shared(ManualEvent) m_onExit;

		// task local storage
		BitArray m_flsInit;
		void[] m_fls;

		bool m_interrupt; // Task.interrupt() is progress
		package int m_yieldLockCount;

		static TaskFiber ms_globalDummyFiber;
		static FLSInfo[] ms_flsInfo;
		static size_t ms_flsFill = 0; // thread-local
		static size_t ms_flsCounter = 0;
	}


	package TaskFuncInfo m_taskFunc;
	package __gshared size_t ms_taskStackSize = defaultTaskStackSize;
	package __gshared debug TaskEventCallback ms_taskEventCallback;
	package __gshared debug TaskCreationCallback ms_taskCreationCallback;

	this()
	@trusted nothrow {
		super(&run, ms_taskStackSize);
		m_thread = Thread.getThis();
	}

	static TaskFiber getThis()
	@safe nothrow {
		auto f = () @trusted nothrow { return Fiber.getThis(); } ();
		if (auto tf = cast(TaskFiber)f) return tf;
		if (!ms_globalDummyFiber) ms_globalDummyFiber = new TaskFiber;
		return ms_globalDummyFiber;
	}

	// expose Fiber.state as @safe on older DMD versions
	static if (!__traits(compiles, () @safe { return Fiber.init.state; } ()))
		@property State state() @trusted const nothrow { return super.state; }

	private void run()
	nothrow {
		import std.algorithm.mutation : swap;
		import std.concurrency : Tid, thisTid;
		import std.encoding : sanitize;
		import vibe.core.core : isEventLoopRunning, recycleFiber, taskScheduler, yield;

		version (VibeDebugCatchAll) alias UncaughtException = Throwable;
		else alias UncaughtException = Exception;
		try {
			while (true) {
				while (!m_taskFunc.func) {
					try {
						logTrace("putting fiber to sleep waiting for new task...");
						Fiber.yield();
					} catch (Exception e) {
						logWarn("CoreTaskFiber was resumed with exception but without active task!");
						logDiagnostic("Full error: %s", e.toString().sanitize());
					}
					if (m_shutdown) return;
				}

				TaskFuncInfo task;
				swap(task, m_taskFunc);
				Task handle = this.task;
				try {
					m_running = true;
					scope(exit) m_running = false;

					thisTid; // force creation of a message box

					debug if (ms_taskEventCallback) ms_taskEventCallback(TaskEvent.start, handle);
					if (!isEventLoopRunning) {
						logTrace("Event loop not running at task start - yielding.");
						taskScheduler.yieldUninterruptible();
						logTrace("Initial resume of task.");
					}
					task.call();
					debug if (ms_taskEventCallback) ms_taskEventCallback(TaskEvent.end, handle);
				} catch (Exception e) {
					debug if (ms_taskEventCallback) ms_taskEventCallback(TaskEvent.fail, handle);
					import std.encoding;
					logCritical("Task terminated with uncaught exception: %s", e.msg);
					logDebug("Full error: %s", e.toString().sanitize());
				}

				if (m_interrupt) {
					logDebug("Task exited while an interrupt was in flight.");
					m_interrupt = false;
				}

				this.tidInfo.ident = Tid.init; // clear message box

				logTrace("Notifying joining tasks.");
				m_onExit.emit();

				// make sure that the task does not get left behind in the yielder queue if terminated during yield()
				if (m_queue) m_queue.remove(this);

				// zero the fls initialization ByteArray for memory safety
				foreach (size_t i, ref bool b; m_flsInit) {
					if (b) {
						if (ms_flsInfo !is null && ms_flsInfo.length >= i && ms_flsInfo[i] != FLSInfo.init)
							ms_flsInfo[i].destroy(m_fls);
						b = false;
					}
				}

				// make the fiber available for the next task
				recycleFiber(this);
			}
		} catch(UncaughtException th) {
			logCritical("CoreTaskFiber was terminated unexpectedly: %s", th.msg);
			logDiagnostic("Full error: %s", th.toString().sanitize());
		} catch (Throwable th) {
			import std.stdio : stderr, writeln;
			import core.stdc.stdlib : abort;
			try stderr.writeln(th);
			catch (Exception e) {
				try stderr.writeln(th.msg);
				catch (Exception e) {}
			}
			abort();
		}
	}


	/** Returns the thread that owns this task.
	*/
	@property inout(Thread) thread() inout @safe nothrow { return m_thread; }

	/** Returns the handle of the current Task running on this fiber.
	*/
	@property Task task() @safe nothrow { return Task(this, m_taskCounter); }

	@property ref inout(ThreadInfo) tidInfo() inout @safe nothrow { return m_tidInfo; }

	@property size_t taskCounter() const @safe nothrow { return m_taskCounter; }

	/** Shuts down the task handler loop.
	*/
	void shutdown()
	@safe nothrow {
		assert(!m_running);
		m_shutdown = true;
		while (state != Fiber.State.TERM)
			() @trusted {
				try call(Fiber.Rethrow.no);
				catch (Exception e) assert(false, e.msg);
			} ();
	}

	/** Blocks until the task has ended.
	*/
	void join(bool interruptiple)(size_t task_counter)
	@trusted {
		auto cnt = m_onExit.emitCount;
		while (m_running && m_taskCounter == task_counter) {
			static if (interruptiple)
				cnt = m_onExit.wait(cnt);
			else
				cnt = m_onExit.waitUninterruptible(cnt);
		}
	}

	/** Throws an InterruptExeption within the task as soon as it calls an interruptible function.
	*/
	void interrupt(size_t task_counter)
	@safe nothrow {
		import vibe.core.core : taskScheduler;

		if (m_taskCounter != task_counter)
			return;

		auto caller = Task.getThis();
		if (caller != Task.init) {
			assert(caller != this.task, "A task cannot interrupt itself.");
			assert(caller.thread is this.thread, "Interrupting tasks in different threads is not yet supported.");
		} else assert(() @trusted { return Thread.getThis(); } () is this.thread, "Interrupting tasks in different threads is not yet supported.");
		logTrace("Resuming task with interrupt flag.");
		m_interrupt = true;
		taskScheduler.switchTo(this.task);
	}

	void bumpTaskCounter()
	@safe nothrow {
		import core.atomic : atomicOp;
		() @trusted { atomicOp!"+="(this.m_taskCounter, 1); } ();
	}

	package void handleInterrupt(scope void delegate() @safe nothrow on_interrupt)
	@safe nothrow {
		assert(() @trusted { return Task.getThis().fiber; } () is this, "Handling interrupt outside of the corresponding fiber.");
		if (m_interrupt && on_interrupt) {
			logTrace("Handling interrupt flag.");
			m_interrupt = false;
			on_interrupt();
		}
	}

	package void handleInterrupt()
	@safe {
		if (m_interrupt) {
			m_interrupt = false;
			throw new InterruptException;
		}
	}
}

package struct TaskFuncInfo {
	void function(ref TaskFuncInfo) func;
	void[2*size_t.sizeof] callable;
	void[maxTaskParameterSize] args;
	debug ulong functionPointer;

	void set(CALLABLE, ARGS...)(ref CALLABLE callable, ref ARGS args)
	{
		assert(!func, "Setting TaskFuncInfo that is already set.");

		import std.algorithm : move;
		import std.traits : hasElaborateAssign;
		import std.conv : to;

		static struct TARGS { ARGS expand; }

		static assert(CALLABLE.sizeof <= TaskFuncInfo.callable.length,
			"Storage required for task callable is too large ("~CALLABLE.sizeof~" vs max "~callable.length~"): "~CALLABLE.stringof);
		static assert(TARGS.sizeof <= maxTaskParameterSize,
			"The arguments passed to run(Worker)Task must not exceed "~
			maxTaskParameterSize.to!string~" bytes in total size: "~TARGS.sizeof.stringof~" bytes");

		debug functionPointer = callPointer(callable);

		static void callDelegate(ref TaskFuncInfo tfi) {
			assert(tfi.func is &callDelegate, "Wrong callDelegate called!?");

			// copy original call data to stack
			CALLABLE c;
			TARGS args;
			move(*(cast(CALLABLE*)tfi.callable.ptr), c);
			move(*(cast(TARGS*)tfi.args.ptr), args);

			// reset the info
			tfi.func = null;

			// make the call
			mixin(callWithMove!ARGS("c", "args.expand"));
		}

		func = &callDelegate;

		() @trusted {
			static if (hasElaborateAssign!CALLABLE) initCallable!CALLABLE();
			static if (hasElaborateAssign!TARGS) initArgs!TARGS();
			typedCallable!CALLABLE = callable;
			foreach (i, A; ARGS) {
				static if (needsMove!A) args[i].move(typedArgs!TARGS.expand[i]);
				else typedArgs!TARGS.expand[i] = args[i];
			}
		} ();
	}

	void call()
	{
		this.func(this);
	}

	@property ref C typedCallable(C)()
	{
		static assert(C.sizeof <= callable.sizeof);
		return *cast(C*)callable.ptr;
	}

	@property ref A typedArgs(A)()
	{
		static assert(A.sizeof <= args.sizeof);
		return *cast(A*)args.ptr;
	}

	void initCallable(C)()
	nothrow {
		static const C cinit;
		this.callable[0 .. C.sizeof] = cast(void[])(&cinit)[0 .. 1];
	}

	void initArgs(A)()
	nothrow {
		static const A ainit;
		this.args[0 .. A.sizeof] = cast(void[])(&ainit)[0 .. 1];
	}
}

private ulong callPointer(C)(ref C callable)
@trusted nothrow @nogc {
	alias IP = ulong;
	static if (is(C == function)) return cast(IP)cast(void*)callable;
	else static if (is(C == delegate)) return cast(IP)callable.funcptr;
	else static if (is(typeof(&callable.opCall) == function)) return cast(IP)cast(void*)&callable.opCall;
	else static if (is(typeof(&callable.opCall) == delegate)) return cast(IP)(&callable.opCall).funcptr;
	else return cast(IP)&callable;
}

package struct TaskScheduler {
	import eventcore.driver : ExitReason;
	import eventcore.core : eventDriver;

	private {
		TaskFiberQueue m_taskQueue;
		TaskFiber m_markerTask;
	}

	@safe:

	@disable this(this);

	@property size_t scheduledTaskCount() const nothrow { return m_taskQueue.length; }

	/** Lets other pending tasks execute before continuing execution.

		This will give other tasks or events a chance to be processed. If
		multiple tasks call this function, they will be processed in a
		fírst-in-first-out manner.
	*/
	void yield()
	{
		auto t = Task.getThis();
		if (t == Task.init) return; // not really a task -> no-op
		auto tf = () @trusted { return t.taskFiber; } ();
		logTrace("Yielding (interrupt=%s)", tf.m_interrupt);
		tf.handleInterrupt();
		if (tf.m_queue !is null) return; // already scheduled to be resumed
		m_taskQueue.insertBack(tf);
		doYield(t);
		tf.handleInterrupt();
	}

	nothrow:

	/** Performs a single round of scheduling without blocking.

		This will execute scheduled tasks and process events from the
		event queue, as long as possible without having to wait.

		Returns:
			A reason is returned:
			$(UL
				$(LI `ExitReason.exit`: The event loop was exited due to a manual request)
				$(LI `ExitReason.outOfWaiters`: There are no more scheduled
					tasks or events, so the application would do nothing from
					now on)
				$(LI `ExitReason.idle`: All scheduled tasks and pending events
					have been processed normally)
				$(LI `ExitReason.timeout`: Scheduled tasks have been processed,
					but there were no pending events present.)
			)
	*/
	ExitReason process()
	{
		assert(TaskFiber.getThis().m_yieldLockCount == 0, "May not process events within an active yieldLock()!");

		bool any_events = false;
		while (true) {
			// process pending tasks
			bool any_tasks_processed = schedule() != ScheduleStatus.idle;

			logTrace("Processing pending events...");
			ExitReason er = eventDriver.core.processEvents(0.seconds);
			logTrace("Done.");

			final switch (er) {
				case ExitReason.exited: return ExitReason.exited;
				case ExitReason.outOfWaiters:
					if (!scheduledTaskCount)
						return ExitReason.outOfWaiters;
					break;
				case ExitReason.timeout:
					if (!scheduledTaskCount)
						return any_events || any_tasks_processed ? ExitReason.idle : ExitReason.timeout;
					break;
				case ExitReason.idle:
					any_events = true;
					if (!scheduledTaskCount)
						return ExitReason.idle;
					break;
			}
		}
	}

	/** Performs a single round of scheduling, blocking if necessary.

		Returns:
			A reason is returned:
			$(UL
				$(LI `ExitReason.exit`: The event loop was exited due to a manual request)
				$(LI `ExitReason.outOfWaiters`: There are no more scheduled
					tasks or events, so the application would do nothing from
					now on)
				$(LI `ExitReason.idle`: All scheduled tasks and pending events
					have been processed normally)
			)
	*/
	ExitReason waitAndProcess()
	{
		// first, process tasks without blocking
		auto er = process();

		final switch (er) {
			case ExitReason.exited, ExitReason.outOfWaiters: return er;
			case ExitReason.idle: return ExitReason.idle;
			case ExitReason.timeout: break;
		}

		// if the first run didn't process any events, block and
		// process one chunk
		logTrace("Wait for new events to process...");
		er = eventDriver.core.processEvents(Duration.max);
		logTrace("Done.");
		final switch (er) {
			case ExitReason.exited: return ExitReason.exited;
			case ExitReason.outOfWaiters:
				if (!scheduledTaskCount)
					return ExitReason.outOfWaiters;
				break;
			case ExitReason.timeout: assert(false, "Unexpected return code");
			case ExitReason.idle: break;
		}

		// finally, make sure that all scheduled tasks are run
		er = process();
		if (er == ExitReason.timeout) return ExitReason.idle;
		else return er;
	}

	void yieldUninterruptible()
	{
		auto t = Task.getThis();
		if (t == Task.init) return; // not really a task -> no-op
		auto tf = () @trusted { return t.taskFiber; } ();
		if (tf.m_queue !is null) return; // already scheduled to be resumed
		m_taskQueue.insertBack(tf);
		doYield(t);
	}

	/** Holds execution until the task gets explicitly resumed.


	*/
	void hibernate()
	{
		import vibe.core.core : isEventLoopRunning;
		auto thist = Task.getThis();
		if (thist == Task.init) {
			assert(!isEventLoopRunning, "Event processing outside of a fiber should only happen before the event loop is running!?");
			static import vibe.core.core;
			vibe.core.core.runEventLoopOnce();
		} else {
			doYield(thist);
		}
	}

	/** Immediately switches execution to the specified task without giving up execution privilege.

		This forces immediate execution of the specified task. After the tasks finishes or yields,
		the calling task will continue execution.
	*/
	void switchTo(Task t, Flag!"defer" defer = No.defer)
	{
		auto thist = Task.getThis();

		if (t == thist) return;

		auto thisthr = thist ? thist.thread : () @trusted { return Thread.getThis(); } ();
		assert(t.thread is thisthr, "Cannot switch to a task that lives in a different thread.");
		if (thist == Task.init && defer == No.defer) {
			assert(TaskFiber.getThis().m_yieldLockCount == 0, "Cannot yield within an active yieldLock()!");
			logTrace("switch to task from global context");
			resumeTask(t);
			logTrace("task yielded control back to global context");
		} else {
			auto tf = () @trusted { return t.taskFiber; } ();
			auto thistf = () @trusted { return thist.taskFiber; } ();
			assert(!thistf || !thistf.m_queue, "Calling task is running, but scheduled to be resumed!?");
			if (tf.m_queue) {
				logTrace("Task to switch to is already scheduled. Moving to front of queue.");
				assert(tf.m_queue is &m_taskQueue, "Task is already enqueued, but not in the main task queue.");
				m_taskQueue.remove(tf);
				assert(!tf.m_queue, "Task removed from queue, but still has one set!?");
			}

			logDebugV("Switching tasks (%s already in queue)", m_taskQueue.length);
			if (defer) {
				m_taskQueue.insertFront(tf);
			} else {
				m_taskQueue.insertFront(thistf);
				m_taskQueue.insertFront(tf);
				doYield(thist);
			}
		}
	}

	/** Runs any pending tasks.

		A pending tasks is a task that is scheduled to be resumed by either `yield` or
		`switchTo`.

		Returns:
			Returns `true` $(I iff) there are more tasks left to process.
	*/
	ScheduleStatus schedule()
	nothrow {
		if (m_taskQueue.empty)
			return ScheduleStatus.idle;


		if (!m_markerTask) m_markerTask = new TaskFiber; // TODO: avoid allocating an actual task here!

		scope (exit) assert(!m_markerTask.m_queue, "Marker task still in queue!?");

		assert(Task.getThis() == Task.init, "TaskScheduler.schedule() may not be called from a task!");
		assert(!m_markerTask.m_queue, "TaskScheduler.schedule() was called recursively!");

		// keep track of the end of the queue, so that we don't process tasks
		// infinitely
		m_taskQueue.insertBack(m_markerTask);

		while (m_taskQueue.front !is m_markerTask) {
			auto t = m_taskQueue.front;
			m_taskQueue.popFront();
			logTrace("resuming task");
			resumeTask(t.task);
			logTrace("task out");

			assert(!m_taskQueue.empty, "Marker task got removed from tasks queue!?");
			if (m_taskQueue.empty) return ScheduleStatus.idle; // handle gracefully in release mode
		}

		// remove marker task
		m_taskQueue.popFront();

		logDebugV("schedule finished - %s tasks left in queue", m_taskQueue.length);

		return m_taskQueue.empty ? ScheduleStatus.allProcessed : ScheduleStatus.busy;
	}

	/// Resumes execution of a yielded task.
	private void resumeTask(Task t)
	nothrow {
		import std.encoding : sanitize;

		logTrace("task fiber resume");
		auto uncaught_exception = () @trusted nothrow { return t.fiber.call!(Fiber.Rethrow.no)(); } ();
		logTrace("task fiber yielded");

		if (uncaught_exception) {
			auto th = cast(Throwable)uncaught_exception;
			assert(th, "Fiber returned exception object that is not a Throwable!?");

			assert(() @trusted nothrow { return t.fiber.state; } () == Fiber.State.TERM);
			logError("Task terminated with unhandled exception: %s", th.msg);
			logDebug("Full error: %s", () @trusted { return th.toString().sanitize; } ());

			// always pass Errors on
			if (auto err = cast(Error)th) throw err;
		}
	}

	private void doYield(Task task)
	{
		assert(() @trusted { return task.taskFiber; } ().m_yieldLockCount == 0, "May not yield while in an active yieldLock()!");
		debug if (TaskFiber.ms_taskEventCallback) () @trusted { TaskFiber.ms_taskEventCallback(TaskEvent.yield, task); } ();
		() @trusted { Fiber.yield(); } ();
		debug if (TaskFiber.ms_taskEventCallback) () @trusted { TaskFiber.ms_taskEventCallback(TaskEvent.resume, task); } ();
	}
}

package enum ScheduleStatus {
	idle,
	allProcessed,
	busy
}

private struct TaskFiberQueue {
	@safe nothrow:

	TaskFiber first, last;
	size_t length;

	@disable this(this);

	@property bool empty() const { return first is null; }

	@property TaskFiber front() { return first; }

	void insertFront(TaskFiber task)
	{
		assert(task.m_queue is null, "Task is already scheduled to be resumed!");
		assert(task.m_prev is null, "Task has m_prev set without being in a queue!?");
		assert(task.m_next is null, "Task has m_next set without being in a queue!?");
		task.m_queue = &this;
		if (empty) {
			first = task;
			last = task;
		} else {
			first.m_prev = task;
			task.m_next = first;
			first = task;
		}
		length++;
	}

	void insertBack(TaskFiber task)
	{
		assert(task.m_queue is null, "Task is already scheduled to be resumed!");
		assert(task.m_prev is null, "Task has m_prev set without being in a queue!?");
		assert(task.m_next is null, "Task has m_next set without being in a queue!?");
		task.m_queue = &this;
		if (empty) {
			first = task;
			last = task;
		} else {
			last.m_next = task;
			task.m_prev = last;
			last = task;
		}
		length++;
	}

	void popFront()
	{
		if (first is last) last = null;
		assert(first && first.m_queue == &this, "Popping from empty or mismatching queue");
		auto next = first.m_next;
		if (next) next.m_prev = null;
		first.m_next = null;
		first.m_queue = null;
		first = next;
		length--;
	}

	void remove(TaskFiber task)
	{
		assert(task.m_queue is &this, "Task is not contained in task queue.");
		if (task.m_prev) task.m_prev.m_next = task.m_next;
		else first = task.m_next;
		if (task.m_next) task.m_next.m_prev = task.m_prev;
		else last = task.m_prev;
		task.m_queue = null;
		task.m_prev = null;
		task.m_next = null;
	}
}

private struct FLSInfo {
	void function(void[], size_t) fct;
	size_t offset;
	void destroy(void[] fls) {
		fct(fls, offset);
	}
}

// mixin string helper to call a function with arguments that potentially have
// to be moved
package string callWithMove(ARGS...)(string func, string args)
{
	import std.string;
	string ret = func ~ "(";
	foreach (i, T; ARGS) {
		if (i > 0) ret ~= ", ";
		ret ~= format("%s[%s]", args, i);
		static if (needsMove!T) ret ~= ".move";
	}
	return ret ~ ");";
}

private template needsMove(T)
{
	template isCopyable(T)
	{
		enum isCopyable = __traits(compiles, (T a) { return a; });
	}

	template isMoveable(T)
	{
		enum isMoveable = __traits(compiles, (T a) { return a.move; });
	}

	enum needsMove = !isCopyable!T;

	static assert(isCopyable!T || isMoveable!T,
				  "Non-copyable type "~T.stringof~" must be movable with a .move property.");
}

unittest {
	enum E { a, move }
	static struct S {
		@disable this(this);
		@property S move() { return S.init; }
	}
	static struct T { @property T move() { return T.init; } }
	static struct U { }
	static struct V {
		@disable this();
		@disable this(this);
		@property V move() { return V.init; }
	}
	static struct W { @disable this(); }

	static assert(needsMove!S);
	static assert(!needsMove!int);
	static assert(!needsMove!string);
	static assert(!needsMove!E);
	static assert(!needsMove!T);
	static assert(!needsMove!U);
	static assert(needsMove!V);
	static assert(!needsMove!W);
}
