/**
	Contains interfaces and enums for evented I/O drivers.

	Copyright: © 2012-2020 Sönke Ludwig
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.task;

import vibe.core.log;
import vibe.core.sync;

import core.atomic : atomicOp, atomicLoad, cas;
import core.thread;
import std.exception;
import std.traits;
import std.typecons;


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

	enum basePriority = 0x00010000;

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
		return Task(tfiber, tfiber.getTaskStatusFromOwnerThread().counter);
	}

	nothrow {
		package @property inout(TaskFiber) taskFiber() inout @system { return cast(inout(TaskFiber))m_fiber; }
		@property inout(Fiber) fiber() inout @system { return this.taskFiber; }
		@property size_t taskCounter() const @safe { return m_taskCounter; }
		@property inout(Thread) thread() inout @trusted { if (m_fiber) return this.taskFiber.thread; return null; }

		/** Determines if the task is still running or scheduled to be run.
		*/
		@property bool running()
		const @trusted {
			assert(m_fiber !is null, "Invalid task handle");
			auto tf = this.taskFiber;
			try if (tf.state == Fiber.State.TERM) return false; catch (Throwable) {}
			auto st = m_fiber.getTaskStatus();
			if (st.counter != m_taskCounter)
				return false;
			return st.initialized;
		}

		package @property ref ThreadInfo tidInfo() @system { return m_fiber ? taskFiber.tidInfo : s_tidInfo; } // FIXME: this is not thread safe!
		package @property ref const(ThreadInfo) tidInfo() const @system { return m_fiber ? taskFiber.tidInfo : s_tidInfo; } // FIXME: this is not thread safe!

		/** Gets the `Tid` associated with this task for use with
			`std.concurrency`.
		*/
		@property Tid tid() @trusted { return tidInfo.ident; }
		/// ditto
		@property const(Tid) tid() const @trusted { return tidInfo.ident; }
	}

	T opCast(T)() const @safe nothrow if (is(T == bool)) { return m_fiber !is null; }

	void join() @trusted { if (m_fiber) m_fiber.join!true(m_taskCounter); }
	void joinUninterruptible() @trusted nothrow { if (m_fiber) m_fiber.join!false(m_taskCounter); }
	void interrupt() @trusted nothrow { if (m_fiber) m_fiber.interrupt(m_taskCounter); }

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


/** Settings to control the behavior of newly started tasks.
*/
struct TaskSettings {
	/** Scheduling priority of the task

		The priority of a task is roughly proportional to the amount of
		times it gets scheduled in comparison to competing tasks. For
		example, a task with priority 100 will be scheduled every 10 rounds
		when competing against a task with priority 1000.

		The default priority is defined by `basePriority` and has a value
		of 65536. Priorities should be computed relative to `basePriority`.

		A task with a priority of zero will only be executed if no other
		non-zero task is competing.
	*/
	uint priority = Task.basePriority;
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

	private enum Flags {
		running = 1UL << 0,
		initialized = 1UL << 1,
		interrupt = 1UL << 2,

		shiftAmount = 3,
		flagsMask = (1<<shiftAmount) - 1
	}

	private {
		import std.concurrency : ThreadInfo;
		import std.bitmanip : BitArray;

		// task queue management (TaskScheduler.m_taskQueue)
		TaskFiber m_prev, m_next;
		TaskFiberQueue* m_queue;

		Thread m_thread;
		ThreadInfo m_tidInfo;
		uint m_staticPriority, m_dynamicPriority;
		shared ulong m_taskCounterAndFlags = 0; // bits 0-Flags.shiftAmount are flags

		bool m_shutdown = false;

		shared(ManualEvent) m_onExit;

		// task local storage
		BitArray m_flsInit;
		void[] m_fls;

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
		m_onExit = createSharedManualEvent();
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
		import vibe.core.core : isEventLoopRunning, recycleFiber, taskScheduler, yield, yieldLock;

		version (VibeDebugCatchAll) alias UncaughtException = Throwable;
		else alias UncaughtException = Exception;
		try {
			while (true) {
				while (!m_taskFunc.func) {
					try {
						debug (VibeTaskLog) logTrace("putting fiber to sleep waiting for new task...");
						Fiber.yield();
					} catch (Exception e) {
						e.logException!(LogLevel.warn)(
							"CoreTaskFiber was resumed with exception but without active task");
					}
					if (m_shutdown) return;
				}

				debug assert(Thread.getThis() is m_thread, "Fiber moved between threads!?");

				TaskFuncInfo task;
				swap(task, m_taskFunc);
				m_dynamicPriority = m_staticPriority = task.settings.priority;
				Task handle = this.task;
				try {
					atomicOp!"|="(m_taskCounterAndFlags, Flags.running); // set running
					scope(exit) atomicOp!"&="(m_taskCounterAndFlags, ~Flags.flagsMask); // clear running/initialized

					thisTid; // force creation of a message box

					debug if (ms_taskEventCallback) ms_taskEventCallback(TaskEvent.start, handle);
					if (!isEventLoopRunning) {
						debug (VibeTaskLog) logTrace("Event loop not running at task start - yielding.");
						taskScheduler.yieldUninterruptible();
						debug (VibeTaskLog) logTrace("Initial resume of task.");
					}
					task.call();
					debug if (ms_taskEventCallback) ms_taskEventCallback(TaskEvent.end, handle);

					debug if (() @trusted { return (cast(shared)this); } ().getTaskStatus().interrupt)
						logDebug("Task exited while an interrupt was in flight.");
				} catch (Exception e) {
					debug if (ms_taskEventCallback) ms_taskEventCallback(TaskEvent.fail, handle);
					e.logException!(LogLevel.critical)("Task terminated with uncaught exception");
				}

				debug assert(Thread.getThis() is m_thread, "Fiber moved?");

				this.tidInfo.ident = Tid.init; // clear message box

				debug (VibeTaskLog) logTrace("Notifying joining tasks.");

				// Issue #161: This fiber won't be resumed before the next task
				// is assigned, because it is already marked as de-initialized.
				// Since ManualEvent.emit() will need to switch tasks, this
				// would mean that only the first waiter is notified before
				// this fiber gets a new task assigned.
				// Using a yield lock forces all corresponding tasks to be
				// enqueued into the schedule queue and resumed in sequence
				// at the end of the scope.
				auto l = yieldLock();

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

				assert(!m_queue, "Fiber done but still scheduled to be resumed!?");

				debug assert(Thread.getThis() is m_thread, "Fiber moved between threads!?");

				// make the fiber available for the next task
				recycleFiber(this);
			}
		} catch (UncaughtException th) {
			th.logException("CoreTaskFiber was terminated unexpectedly");
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
	@property Task task()
	@safe nothrow {
		auto ts = getTaskStatusFromOwnerThread();
		if (!ts.initialized) return Task.init;
		return Task(this, ts.counter);
	}

	@property ref inout(ThreadInfo) tidInfo() inout @safe nothrow { return m_tidInfo; }

	/** Shuts down the task handler loop.
	*/
	void shutdown()
	@safe nothrow {
		debug assert(Thread.getThis() is m_thread);

		assert(!() @trusted { return cast(shared)this; } ().getTaskStatus().initialized);

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
	shared @trusted {
		auto cnt = m_onExit.emitCount;
		while (true) {
			auto st = getTaskStatus();
			if (!st.initialized || st.counter != task_counter)
				break;
			static if (interruptiple)
				cnt = m_onExit.wait(cnt);
			else
				cnt = m_onExit.waitUninterruptible(cnt);
		}
	}

	/** Throws an InterruptExeption within the task as soon as it calls an interruptible function.
	*/
	void interrupt(size_t task_counter)
	shared @safe nothrow {
		import vibe.core.core : taskScheduler;

		auto caller = () @trusted { return cast(shared)TaskFiber.getThis(); } ();

		assert(caller !is this, "A task cannot interrupt itself.");

		while (true) {
			auto tcf = atomicLoad(m_taskCounterAndFlags);
			auto st = getTaskStatus(tcf);
			if (!st.initialized || st.interrupt || st.counter != task_counter)
				return;
			auto tcf_int = tcf | Flags.interrupt;
			if (cas(&m_taskCounterAndFlags, tcf, tcf_int))
				break;
		}

		if (caller.m_thread is m_thread) {
			auto thisus = () @trusted { return cast()this; } ();
			debug (VibeTaskLog) logTrace("Resuming task with interrupt flag.");
			auto defer = caller.m_yieldLockCount > 0;
			taskScheduler.switchTo(thisus.task, defer ? TaskSwitchPriority.prioritized : TaskSwitchPriority.immediate);
		} else {
			debug (VibeTaskLog) logTrace("Set interrupt flag on task without resuming.");
		}
	}

	/** Sets the fiber to initialized state and increments the task counter.

		Note that the task information needs to be set up first.
	*/
	void bumpTaskCounter()
	@safe nothrow {
		debug {
			auto ts = atomicLoad(m_taskCounterAndFlags);
			assert((ts & Flags.flagsMask) == 0, "bumpTaskCounter() called on fiber with non-zero flags");
			assert(m_taskFunc.func !is null, "bumpTaskCounter() called without initializing the task function");
		}

		() @trusted { atomicOp!"+="(m_taskCounterAndFlags, (1 << Flags.shiftAmount) + Flags.initialized); } ();
	}

	private auto getTaskStatus()
	shared const @safe nothrow {
		return getTaskStatus(atomicLoad(m_taskCounterAndFlags));
	}

	private auto getTaskStatusFromOwnerThread()
	const @safe nothrow {
		debug assert(Thread.getThis() is m_thread);
		return getTaskStatus(atomicLoad(m_taskCounterAndFlags));
	}

	private static auto getTaskStatus(ulong counter_and_flags)
	@safe nothrow {
		static struct S {
			size_t counter;
			bool running;
			bool initialized;
			bool interrupt;
		}
		S ret;
		ret.counter = cast(size_t)(counter_and_flags >> Flags.shiftAmount);
		ret.running = (counter_and_flags & Flags.running) != 0;
		ret.initialized = (counter_and_flags & Flags.initialized) != 0;
		ret.interrupt = (counter_and_flags & Flags.interrupt) != 0;
		return ret;
	}

	package void handleInterrupt(scope void delegate() @safe nothrow on_interrupt)
	@safe nothrow {
		assert(() @trusted { return Task.getThis().fiber; } () is this,
			"Handling interrupt outside of the corresponding fiber.");
		if (getTaskStatusFromOwnerThread().interrupt && on_interrupt) {
			debug (VibeTaskLog) logTrace("Handling interrupt flag.");
			clearInterruptFlag();
			on_interrupt();
		}
	}

	package void handleInterrupt()
	@safe {
		assert(() @trusted { return Task.getThis().fiber; } () is this,
			"Handling interrupt outside of the corresponding fiber.");
		if (getTaskStatusFromOwnerThread().interrupt) {
			clearInterruptFlag();
			throw new InterruptException;
		}
	}

	private void clearInterruptFlag()
	@safe nothrow {
		auto tcf = atomicLoad(m_taskCounterAndFlags);
		auto st = getTaskStatus(tcf);
		while (true) {
			assert(st.initialized);
			if (!st.interrupt) break;
			auto tcf_int = tcf & ~Flags.interrupt;
			if (cas(&m_taskCounterAndFlags, tcf, tcf_int))
				break;
		}
	}
}


/** Controls the priority to use for switching execution to a task.
*/
enum TaskSwitchPriority {
	/** Rescheduled according to the tasks priority
	*/
	normal,

	/** Rescheduled with maximum priority.

		The task will resume as soon as the current task yields.
	*/
	prioritized,

	/** Switch to the task immediately.
	*/
	immediate
}

package struct TaskFuncInfo {
	void function(ref TaskFuncInfo) func;
	void[2*size_t.sizeof] callable;
	void[maxTaskParameterSize] args;
	debug ulong functionPointer;
	TaskSettings settings;

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
		debug (VibeTaskLog) logTrace("Yielding (interrupt=%s)", () @trusted { return (cast(shared)tf).getTaskStatus().interrupt; } ());
		tf.handleInterrupt();
		if (tf.m_queue !is null) return; // already scheduled to be resumed
		doYieldAndReschedule(t);
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

			debug (VibeTaskLog) logTrace("Processing pending events...");
			ExitReason er = eventDriver.core.processEvents(0.seconds);
			debug (VibeTaskLog) logTrace("Done.");

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
		debug (VibeTaskLog) logTrace("Wait for new events to process...");
		er = eventDriver.core.processEvents(Duration.max);
		debug (VibeTaskLog) logTrace("Done.");
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
		doYieldAndReschedule(t);
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
	void switchTo(Task t, TaskSwitchPriority priority)
	{
		auto thist = Task.getThis();

		if (t == thist) return;

		auto thisthr = thist ? thist.thread : () @trusted { return Thread.getThis(); } ();
		assert(t.thread is thisthr, "Cannot switch to a task that lives in a different thread.");

		auto tf = () @trusted { return t.taskFiber; } ();
		if (tf.m_queue) {
			// don't reset the position of already scheduled tasks
			if (priority == TaskSwitchPriority.normal) return;

			debug (VibeTaskLog) logTrace("Task to switch to is already scheduled. Moving to front of queue.");
			assert(tf.m_queue is &m_taskQueue, "Task is already enqueued, but not in the main task queue.");
			m_taskQueue.remove(tf);
			assert(!tf.m_queue, "Task removed from queue, but still has one set!?");
		}

		if (thist == Task.init && priority == TaskSwitchPriority.immediate) {
			assert(TaskFiber.getThis().m_yieldLockCount == 0, "Cannot yield within an active yieldLock()!");
			debug (VibeTaskLog) logTrace("switch to task from global context");
			resumeTask(t);
			debug (VibeTaskLog) logTrace("task yielded control back to global context");
		} else {
			auto thistf = () @trusted { return thist.taskFiber; } ();
			assert(!thistf || !thistf.m_queue, "Calling task is running, but scheduled to be resumed!?");

			debug (VibeTaskLog) logDebugV("Switching tasks (%s already in queue)", m_taskQueue.length);
			final switch (priority) {
				case TaskSwitchPriority.normal:
					reschedule(tf);
					break;
				case TaskSwitchPriority.prioritized:
					tf.m_dynamicPriority = uint.max;
					reschedule(tf);
					break;
				case TaskSwitchPriority.immediate:
					tf.m_dynamicPriority = uint.max;
					m_taskQueue.insertFront(thistf);
					m_taskQueue.insertFront(tf);
					doYield(thist);
					break;
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


		assert(Task.getThis() == Task.init, "TaskScheduler.schedule() may not be called from a task!");

		if (m_taskQueue.empty) return ScheduleStatus.idle;

		foreach (i; 0 .. m_taskQueue.length) {
			auto t = m_taskQueue.front;
			m_taskQueue.popFront();

			// reset priority
			t.m_dynamicPriority = t.m_staticPriority;

			debug (VibeTaskLog) logTrace("resuming task");
			auto task = t.task;
			if (task != Task.init)
				resumeTask(t.task);
			debug (VibeTaskLog) logTrace("task out");

			if (m_taskQueue.empty) break;
		}

		debug (VibeTaskLog) logDebugV("schedule finished - %s tasks left in queue", m_taskQueue.length);

		return m_taskQueue.empty ? ScheduleStatus.allProcessed : ScheduleStatus.busy;
	}

	/// Resumes execution of a yielded task.
	private void resumeTask(Task t)
	nothrow {
		import std.encoding : sanitize;

		assert(t != Task.init, "Resuming null task");

		debug (VibeTaskLog) logTrace("task fiber resume");
		auto uncaught_exception = () @trusted nothrow { return t.fiber.call!(Fiber.Rethrow.no)(); } ();
		debug (VibeTaskLog) logTrace("task fiber yielded");

		if (uncaught_exception) {
			auto th = cast(Throwable)uncaught_exception;
			assert(th, "Fiber returned exception object that is not a Throwable!?");

			assert(() @trusted nothrow { return t.fiber.state; } () == Fiber.State.TERM);
			th.logException("Task terminated with unhandled exception");

			// always pass Errors on
			if (auto err = cast(Error)th) throw err;
		}
	}

	private void reschedule(TaskFiber tf)
	{
		import std.algorithm.comparison : min;

		// insert according to priority, limited to a priority
		// factor of 1:10 in case of heavy concurrency
		m_taskQueue.insertBackPred(tf, 10, (t) {
			if (t.m_dynamicPriority >= tf.m_dynamicPriority)
				return true;

			// increase dynamic priority each time a task gets overtaken to
			// ensure a fair schedule
			t.m_dynamicPriority += min(t.m_staticPriority, uint.max - t.m_dynamicPriority);
			return false;
		});
	}

	private void doYieldAndReschedule(Task task)
	{
		auto tf = () @trusted { return task.taskFiber; } ();

		reschedule(tf);

		doYield(task);
	}

	private void doYield(Task task)
	{
		assert(() @trusted { return task.taskFiber; } ().m_yieldLockCount == 0, "May not yield while in an active yieldLock()!");
		debug if (TaskFiber.ms_taskEventCallback) () @trusted { TaskFiber.ms_taskEventCallback(TaskEvent.yield, task); } ();
		() @trusted { Fiber.yield(); } ();
		debug if (TaskFiber.ms_taskEventCallback) () @trusted { TaskFiber.ms_taskEventCallback(TaskEvent.resume, task); } ();
		assert(!task.m_fiber.m_queue, "Task is still scheduled after resumption.");
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

	// inserts a task after the first task for which the predicate yields `true`,
	// starting from the back. a maximum of max_skip tasks will be skipped
	// before the task is inserted regardless of the predicate.
	void insertBackPred(TaskFiber task, size_t max_skip,
		scope bool delegate(TaskFiber) @safe nothrow pred)
	{
		assert(task.m_queue is null, "Task is already scheduled to be resumed!");
		assert(task.m_prev is null, "Task has m_prev set without being in a queue!?");
		assert(task.m_next is null, "Task has m_next set without being in a queue!?");

		for (auto t = last; t; t = t.m_prev) {
			if (!max_skip-- || pred(t)) {
				task.m_queue = &this;
				task.m_next = t.m_next;
				if (task.m_next) task.m_next.m_prev = task;
				t.m_next = task;
				task.m_prev = t;
				if (!task.m_next) last = task;
				length++;
				return;
			}
		}

		insertFront(task);
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
		length--;
	}
}

unittest {
	auto f1 = new TaskFiber;
	auto f2 = new TaskFiber;

	TaskFiberQueue q;
	assert(q.empty && q.length == 0);
	q.insertFront(f1);
	assert(!q.empty && q.length == 1);
	q.insertFront(f2);
	assert(!q.empty && q.length == 2);
	q.popFront();
	assert(!q.empty && q.length == 1);
	q.popFront();
	assert(q.empty && q.length == 0);
	q.insertFront(f1);
	q.remove(f1);
	assert(q.empty && q.length == 0);
}

unittest {
	auto f1 = new TaskFiber;
	auto f2 = new TaskFiber;
	auto f3 = new TaskFiber;
	auto f4 = new TaskFiber;
	auto f5 = new TaskFiber;
	auto f6 = new TaskFiber;
	TaskFiberQueue q;

	void checkQueue()
	{
		TaskFiber p;
		for (auto t = q.front; t; t = t.m_next) {
			assert(t.m_prev is p);
			assert(t.m_next || t is q.last);
			p = t;
		}

		TaskFiber n;
		for (auto t = q.last; t; t = t.m_prev) {
			assert(t.m_next is n);
			assert(t.m_prev || t is q.first);
			n = t;
		}
	}

	q.insertBackPred(f1, 0, delegate bool(tf) { assert(false); });
	assert(q.first is f1 && q.last is f1);
	checkQueue();

	q.insertBackPred(f2, 0, delegate bool(tf) { assert(false); });
	assert(q.first is f1 && q.last is f2);
	checkQueue();

	q.insertBackPred(f3, 1, (tf) => false);
	assert(q.first is f1 && q.last is f2);
	assert(f1.m_next is f3);
	assert(f3.m_prev is f1);
	checkQueue();

	q.insertBackPred(f4, 10, (tf) => false);
	assert(q.first is f4 && q.last is f2);
	checkQueue();

	q.insertBackPred(f5, 10, (tf) => true);
	assert(q.first is f4 && q.last is f5);
	checkQueue();

	q.insertBackPred(f6, 10, (tf) => tf is f4);
	assert(q.first is f4 && q.last is f5);
	assert(f4.m_next is f6);
	checkQueue();
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
