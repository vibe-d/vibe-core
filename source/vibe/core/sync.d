/**
	Event loop compatible task synchronization facilities.

	This module provides replacement primitives for the modules in `core.sync`
	that do not block vibe.d's event loop in their wait states. These should
	always be preferred over the ones in Druntime under usual circumstances.

	Using a standard `Mutex` is possible as long as it is ensured that no event
	loop based functionality (I/O, task interaction or anything that implicitly
	calls `vibe.core.core.yield`) is executed within a section of code that is
	protected by the mutex. $(B Failure to do so may result in dead-locks and
	high-level race-conditions!)

	Copyright: © 2012-2019 Sönke Ludwig
	Authors: Leonid Kramer, Sönke Ludwig, Manuel Frischknecht
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.sync;

import vibe.core.log;
import vibe.core.task;
import vibe.core.internal.threadlocalwaiter;

import core.atomic;
import core.sync.mutex;
import core.sync.condition;
import eventcore.core;
import std.exception;
import std.stdio;
import std.traits : ReturnType;


/** Creates a new signal that can be shared between fibers.
*/
LocalManualEvent createManualEvent()
@safe nothrow {
	LocalManualEvent ret;
	ret.initialize();
	return ret;
}
/// ditto
shared(ManualEvent) createSharedManualEvent()
@trusted nothrow {
	shared(ManualEvent) ret;
	ret.initialize();
	return ret;
}

/** Creates a new semaphore object.

	These implementations are a task/fiber compatible replacement for `core.sync.semaphore`.
*/
LocalTaskSemaphore createTaskSemaphore(int max_locks)
{
	return new LocalTaskSemaphore(max_locks);
}
/// ditto
shared(TaskSemaphore) createSharedTaskSemaphore(int max_locks)
{
	return new shared TaskSemaphore(max_locks);
}


/** Performs RAII based locking/unlocking of a mutex.

	Note that while `TaskMutex` can be used with D's built-in `synchronized`
	statement, `InterruptibleTaskMutex` cannot. This function provides a
	library based alternative that is suitable for use with all mutex types.
*/
ScopedMutexLock!M scopedMutexLock(M)(M mutex, LockMode mode = LockMode.lock)
	if (is(M : Mutex) || is(M : Lockable))
{
	return ScopedMutexLock!M(mutex, mode);
}
/// ditto
ScopedMutexLock!(shared(M)) scopedMutexLock(M)(shared(M) mutex, LockMode mode = LockMode.lock)
	if (is(M : Mutex) || is(M : Lockable))
{
	return ScopedMutexLock!(shared(M))(mutex, mode);
}

///
unittest {
	import vibe.core.core : runWorkerTaskH;

	__gshared int counter;
	__gshared TaskMutex mutex;

	mutex = new TaskMutex;

	Task[] tasks;

	foreach (i; 0 .. 100) {
		tasks ~= runWorkerTaskH(() nothrow {
			auto l = scopedMutexLock(mutex);
			counter++;
		});
	}

	foreach (t; tasks) t.join();

	assert(counter == 100);
}

unittest {
	scopedMutexLock(new Mutex);
	scopedMutexLock(new TaskMutex);
	scopedMutexLock(new InterruptibleTaskMutex);
	scopedMutexLock(new shared Mutex);
	scopedMutexLock(new shared TaskMutex);
	scopedMutexLock(new shared InterruptibleTaskMutex);
}

enum LockMode {
	lock,
	tryLock,
	defer
}

interface Lockable {
	@safe:
	void lock();
	void unlock();
	bool tryLock();
}

/** RAII lock for the Mutex class.
*/
struct ScopedMutexLock(M)
	if (is(shared(M) : shared(Mutex)) || is(shared(M) : shared(Lockable)))
{
	@disable this(this);
	private {
		M m_mutex;
		bool m_locked;
		LockMode m_mode;
	}

	this(M mutex, LockMode mode = LockMode.lock)
	{
		assert(mutex !is null);
		m_mutex = mutex;

		final switch (mode) {
			case LockMode.lock: lock(); break;
			case LockMode.tryLock: tryLock(); break;
			case LockMode.defer: break;
		}
	}

	~this()
	{
		if (m_locked) unlock();
	}

	@property bool locked() const { return m_locked; }

	void unlock()
	in { assert(this.locked); }
	do {
		assert(m_locked, "Unlocking unlocked scoped mutex lock");
		static if (is(typeof(m_mutex.unlock_nothrow())))
			m_mutex.unlock_nothrow();
		else
			m_mutex.unlock();
		m_locked = false;
	}

	bool tryLock()
	in { assert(!this.locked); }
	do {
		static if (is(typeof(m_mutex.tryLock_nothrow())))
			return m_locked = m_mutex.tryLock_nothrow();
		else
			return m_locked = m_mutex.tryLock();
	}

	void lock()
	in { assert(!this.locked); }
	do {
		m_locked = true;
		static if (is(typeof(m_mutex.lock_nothrow())))
			m_mutex.lock_nothrow();
		else
			m_mutex.lock();
	}
}


/*
	Only for internal use:
	Ensures that a mutex is locked while executing the given procedure.

	This function works for all kinds of mutexes, in particular for
	$(D core.sync.mutex.Mutex), $(D TaskMutex) and $(D InterruptibleTaskMutex).

	Returns:
		Returns the value returned from $(D PROC), if any.
*/
/// private
ReturnType!PROC performLocked(alias PROC, MUTEX)(MUTEX mutex)
{
	auto l = scopedMutexLock(mutex);
	return PROC();
}

///
unittest {
	int protected_var = 0;
	auto mtx = new TaskMutex;
	mtx.performLocked!({
		protected_var++;
	});
}

/**
	Thread-local semaphore implementation for tasks.

	When the semaphore runs out of concurrent locks, it will suspend. This class
	is used in `vibe.core.connectionpool` to limit the number of concurrent
	connections.
*/
final class LocalTaskSemaphore
{
	import std.container.binaryheap; // priority queue
	import std.container.array;

	private {
		static struct ThreadWaiter {
			byte priority;
			uint seq;
			ulong id;
		}

		BinaryHeap!(Array!ThreadWaiter, asc) m_waiters;
		uint m_maxLocks;
		uint m_locks;
		uint m_seq;
		ulong m_idCounter;
		LocalManualEvent m_signal;
	}

@safe nothrow:

	this(uint max_locks)
	{
		m_maxLocks = max_locks;
		m_signal = createManualEvent();
	}

	/// Maximum number of concurrent locks
	@property void maxLocks(uint max_locks) { m_maxLocks = max_locks; }
	/// ditto
	@property uint maxLocks() const { return m_maxLocks; }

	/// Number of concurrent locks still available
	@property uint available() const { return m_maxLocks - m_locks; }

	/** Try to acquire a lock.

		If a lock cannot be acquired immediately, returns `false` and leaves the
		semaphore in its previous state.

		Returns:
			`true` is returned $(I iff) the number of available locks is greater
			than one.
	*/
	bool tryLock()
	{
		if (available > 0) {
			m_locks++;
			return true;
		}
		return false;
	}

	/** Acquires a lock.

		Once the limit of concurrent locks is reached, this method will block
		until the number of locks drops below the limit.

		Params:
			priority = Optional priority modifier - any lock requests with a
				higher priority will be served before all requests with a lower
				priority, FIFO order is applied within a priority class.
	*/
	void lock(byte priority = 0)
	{
		import std.algorithm.comparison : min;

		if (tryLock())
			return;

		auto ec = m_signal.emitCount;

		if (m_seq == uint.max) {
			rewindSeq();
			assert(m_seq != uint.max, "Semaphore queue overflow");
		}

		ThreadWaiter w;
		w.priority = priority;
		w.seq = m_seq++;
		w.id = m_idCounter++;

		() @trusted { m_waiters.insert(w); } ();

		while (true) {
			ec = m_signal.waitUninterruptible(ec);
			// NOTE: BinaryHeap.front is not nothrow on older compiler versions
			try if (m_waiters.front.id == w.id && tryLock()) {
				() @trusted { m_waiters.removeFront(); } ();
				return;
			}
			catch (Exception e) assert(false, e.msg);
		}
	}

	/** Gives up an existing lock.
	*/
	void unlock()
	{
		assert(m_locks >= 1, "Unlocking semaphore with no active locks");
		m_locks--;
		if (m_waiters.length > 0)
			m_signal.emit(); // notify waiters so that the next one can resume
	}

	// if true, a goes after b. ie. b comes out front()
	/// private
	static bool asc(ref ThreadWaiter a, ref ThreadWaiter b)
	{
		if (a.priority != b.priority)
			return a.priority < b.priority;
		return a.seq > b.seq;
	}

	private void rewindSeq()
	@trusted {
		import std.algorithm : min;

		Array!ThreadWaiter waiters = m_waiters.release();
		auto min_seq = m_seq;
		foreach (ref waiter; waiters[])
			min_seq = min(waiter.seq, min_seq);
		foreach (ref waiter; waiters[])
			waiter.seq -= min_seq;
		m_seq -= min_seq;
		m_waiters.assume(waiters);
	}
}

/**
	Thread-local semaphore implementation for tasks.

	When the semaphore runs out of concurrent locks, it will suspend. This class
	is used in `vibe.core.connectionpool` to limit the number of concurrent
	connections.
*/
final shared class TaskSemaphore
{
	import std.container.binaryheap; // priority queue
	import std.container.array;

	private {
		static struct ThreadWaiter {
			byte priority;
			uint seq;
			ulong id;
		}

		static struct State {
			BinaryHeap!(Array!ThreadWaiter, asc) waiters;
			uint maxLocks;
			uint locks;
			uint seq;
			ulong idCounter;
		}

		shared(TaskMutex) m_mutex;
		shared(TaskCondition) m_condition;
		shared(vibe.core.sync.Monitor!(State, shared(TaskMutex))) m_state;
	}

@safe shared nothrow:

	this(uint max_locks)
	{
		m_mutex = new shared TaskMutex;
		static if (__VERSION__ >= 2093) {
			m_condition = new shared TaskCondition(m_mutex);
		} else {
			m_condition = () @trusted { return cast(shared)new TaskCondition(cast()m_mutex); } ();
		}
		m_state = createMonitor!State(m_mutex);
		scope st = m_state.lock;
		st.maxLocks = max_locks;
	}

	/// Maximum number of concurrent locks
	@property void maxLocks(uint max_locks) { m_state.lock.maxLocks = max_locks; }
	/// ditto
	@property uint maxLocks() const { return m_state.lock.maxLocks; }

	/// Number of concurrent locks still available
	@property uint available() const { scope st = m_state.lock; return st.maxLocks - st.locks; }

	/** Try to acquire a lock.

		If a lock cannot be acquired immediately, returns `false` and leaves the
		semaphore in its previous state.

		Returns:
			`true` is returned $(I iff) the number of available locks is greater
			than one.
	*/
	bool tryLock()
	{
		scope st = m_state.lock;
		if (st.locks < st.maxLocks) {
			st.locks++;
			return true;
		}
		return false;
	}

	/** Acquires a lock.

		Once the limit of concurrent locks is reached, this method will block
		until the number of locks drops below the limit.

		Params:
			priority = Optional priority modifier - any lock requests with a
				higher priority will be served before all requests with a lower
				priority, FIFO order is applied within a priority class.
	*/
	void lock(byte priority = 0)
	{
		import std.algorithm.comparison : min;

		if (tryLock())
			return;

		scope st = m_state.lock;

		if (st.seq == uint.max) {
			rewindSeq(st);
			assert(st.seq != uint.max, "Semaphore queue overflow");
		}

		ThreadWaiter w;
		w.priority = priority;
		w.seq = st.seq++;
		w.id = st.idCounter++;

		() @trusted { st.waiters.insert(w); } ();

		while (true) {
			m_condition.wait();
			// NOTE: BinaryHeap.front is not nothrow on older compiler versions
			try if (st.waiters.front.id == w.id && st.locks < st.maxLocks) {
				() @trusted { st.waiters.removeFront(); } ();
				st.locks++;
				return;
			}
			catch (Exception e) assert(false, e.msg);
		}
	}

	/** Gives up an existing lock.
	*/
	void unlock()
	{
		scope st = m_state.lock;
		assert(st.locks >= 1, "Unlocking semaphore with no active locks");
		st.locks--;
		if (st.waiters.length > 0)
			m_condition.notifyAll();
	}

	// if true, a goes after b. ie. b comes out front()
	/// private
	static bool asc(ref ThreadWaiter a, ref ThreadWaiter b)
	{
		if (a.priority != b.priority)
			return a.priority < b.priority;
		return a.seq > b.seq;
	}

	private void rewindSeq(scope ref typeof(m_state).Locked st)
	@trusted {
		import std.algorithm : min;

		Array!ThreadWaiter waiters = st.waiters.release();
		auto min_seq = st.seq;
		foreach (ref waiter; waiters[])
			min_seq = min(waiter.seq, min_seq);
		foreach (ref waiter; waiters[])
			waiter.seq -= min_seq;
		st.seq -= min_seq;
		st.waiters.assume(waiters);
	}
}

unittest {
	import vibe.core.core : runTask, sleep;

	void test(S)(S sem)
	{
		assert(sem.available == 2);
		assert(sem.tryLock());
		assert(sem.available == 1);
		assert(sem.tryLock());
		assert(sem.available == 0);

		int seq = 0;
		auto t1 = runTask({
			sem.lock(0);
			assert(seq++ == 2);
			sem.lock(2);
			assert(seq++ == 3);
			sem.lock(-1);
			assert(seq++ == 6);
		});
		auto t2 = runTask({
			sem.lock(1);
			assert(seq++ == 0);
			sem.lock(1);
			assert(seq++ == 1);
			sem.lock(-1);
			assert(seq++ == 4);
			sem.lock(0);
			assert(seq++ == 5);
		});
		foreach (i; 0 .. 9) {
			sleep(10.msecs);
			sem.unlock();
		}
		assert(sem.available == 2);
		t1.join();
		t2.join();
	}

	test(createTaskSemaphore(2));
	test(createSharedTaskSemaphore(2));
}


/**
	Mutex implementation for fibers.

	This mutex type can be used in exchange for a core.sync.mutex.Mutex, but
	does not block the event loop when contention happens. Note that this
	mutex does not allow recursive locking.

	Notice:
		Because this class is annotated nothrow, it cannot be interrupted
		using $(D vibe.core.task.Task.interrupt()). The corresponding
		$(D InterruptException) will be deferred until the next blocking
		operation yields the event loop.

		Use $(D InterruptibleTaskMutex) as an alternative that can be
		interrupted.

	See_Also: InterruptibleTaskMutex, RecursiveTaskMutex, core.sync.mutex.Mutex
*/
final class TaskMutex : core.sync.mutex.Mutex, Lockable {
@safe:
	private shared(TaskMutexImpl!false) m_impl;

	// non-shared compatibility API
	this(Object o) nothrow { m_impl.setup(); super(o); }
	this() nothrow { m_impl.setup(); }

	override bool tryLock() nothrow { return m_impl.tryLock(); }
	override void lock() nothrow { m_impl.lock(); }
	override void unlock() nothrow { m_impl.unlock(); }
	bool lock(Duration timeout) nothrow { return m_impl.lock(timeout); }

	// new shared API
	this(Object o) shared nothrow { m_impl.setup(); super(o); }
	this() shared nothrow { m_impl.setup(); }

	override bool tryLock() shared nothrow { return m_impl.tryLock(); }
	override void lock() shared nothrow { m_impl.lock(); }
	override void unlock() shared nothrow { m_impl.unlock(); }
	bool lock(Duration timeout) shared nothrow { return m_impl.lock(timeout); }
}

unittest {
	auto mutex = new TaskMutex;

	{
		auto lock = scopedMutexLock(mutex);
		assert(lock.locked);
		assert(mutex.m_impl.m_locked);

		auto lock2 = scopedMutexLock(mutex, LockMode.tryLock);
		assert(!lock2.locked);
	}
	assert(!mutex.m_impl.m_locked);

	auto lock = scopedMutexLock(mutex, LockMode.tryLock);
	assert(lock.locked);
	lock.unlock();
	assert(!lock.locked);

	synchronized(mutex){
		assert(mutex.m_impl.m_locked);
	}
	assert(!mutex.m_impl.m_locked);

	mutex.performLocked!({
		assert(mutex.m_impl.m_locked);
	});
	assert(!mutex.m_impl.m_locked);

	with(mutex.scopedMutexLock) {
		assert(mutex.m_impl.m_locked);
	}
}

unittest { // test deferred throwing
	import vibe.core.core;

	auto mutex = new TaskMutex;
	auto t1 = runTask({
		scope (failure) assert(false, "No exception expected in first task!");
		mutex.lock();
		scope (exit) mutex.unlock();
		sleep(20.msecs);
	});

	auto t2 = runTask({
		mutex.lock();
		scope (exit) mutex.unlock();
		try {
			yield();
			assert(false, "Yield is supposed to have thrown an InterruptException.");
		} catch (InterruptException) {
			// as expected!
		} catch (Exception) {
			assert(false, "Only InterruptException supposed to be thrown!");
		}
	});

	runTask({
		// mutex is now locked in first task for 20 ms
		// the second tasks is waiting in lock()
		t2.interrupt();
		t1.joinUninterruptible();
		t2.joinUninterruptible();
		assert(!mutex.m_impl.m_locked); // ensure that the scope(exit) has been executed
		exitEventLoop();
	});

	runEventLoop();
}

unittest {
	runMutexUnitTests!TaskMutex();
}


/**
	Alternative to $(D TaskMutex) that supports interruption.

	This class supports the use of $(D vibe.core.task.Task.interrupt()) while
	waiting in the $(D lock()) method. However, because the interface is not
	$(D nothrow), it cannot be used as an object monitor.

	See_Also: $(D TaskMutex), $(D InterruptibleRecursiveTaskMutex)
*/
final class InterruptibleTaskMutex : Lockable {
@safe:

	private shared(TaskMutexImpl!true) m_impl;

	// non-shared compatibility API
	this()
	{
		m_impl.setup();

		// detects invalid usage within synchronized(...)
		() @trusted { this.__monitor = cast(void*)&NoUseMonitor.instance(); } ();
	}

	bool tryLock() nothrow { return m_impl.tryLock(); }
	void lock() { m_impl.lock(); }
	void unlock() nothrow { m_impl.unlock(); }

	// new shared API
	this()
	shared {
		m_impl.setup();

		// detects invalid usage within synchronized(...)
		() @trusted { this.__monitor = cast(void*)&NoUseMonitor.instance(); } ();
	}

	bool tryLock() shared nothrow { return m_impl.tryLock(); }
	void lock() shared { m_impl.lock(); }
	void unlock() shared nothrow { m_impl.unlock(); }
}

unittest {
	runMutexUnitTests!InterruptibleTaskMutex();
}



/**
	Recursive mutex implementation for tasks.

	This mutex type can be used in exchange for a `core.sync.mutex.Mutex`, but
	does not block the event loop when contention happens.

	Notice:
		Because this class is annotated `nothrow`, it cannot be interrupted
		using $(D vibe.core.task.Task.interrupt()). The corresponding
		$(D InterruptException) will be deferred until the next blocking
		operation yields the event loop.

		Use $(D InterruptibleRecursiveTaskMutex) as an alternative that can be
		interrupted.

	See_Also: `TaskMutex`, `core.sync.mutex.Mutex`
*/
final class RecursiveTaskMutex : core.sync.mutex.Mutex, Lockable {
@safe:

	private shared(RecursiveTaskMutexImpl!false) m_impl;

	// non-shared compatibility API
	this(Object o) nothrow { m_impl.setup(); super(o); }
	this() nothrow { m_impl.setup(); }

	override bool tryLock() nothrow { return m_impl.tryLock(); }
	override void lock() nothrow { m_impl.lock(); }
	override void unlock() nothrow { m_impl.unlock(); }

	// new shared API
	this(Object o) shared nothrow { m_impl.setup(); super(o); }
	this() shared nothrow { m_impl.setup(); }

	override bool tryLock() shared nothrow { return m_impl.tryLock(); }
	override void lock() shared nothrow { m_impl.lock(); }
	override void unlock() shared nothrow { m_impl.unlock(); }
}

unittest {
	runMutexUnitTests!RecursiveTaskMutex();
}

@safe nothrow unittest {
	import vibe.core.core : runTask;

	auto m = new RecursiveTaskMutex;
	m.lock();
	assert(m.tryLock());
	m.unlock();
	runTask({
		assert(!m.tryLock());
	}).joinUninterruptible();
	m.unlock();
	runTask({
		assert(m.tryLock());
		assert(m.tryLock());
		m.unlock();
		m.unlock();
	}).joinUninterruptible();
}


/**
	Alternative to $(D RecursiveTaskMutex) that supports interruption.

	This class supports the use of $(D vibe.core.task.Task.interrupt()) while
	waiting in the $(D lock()) method. However, because the interface is not
	$(D nothrow), it cannot be used as an object monitor.

	See_Also: $(D RecursiveTaskMutex), $(D InterruptibleTaskMutex)
*/
final class InterruptibleRecursiveTaskMutex : Lockable {
@safe:
	private shared(RecursiveTaskMutexImpl!true) m_impl;

	this()
	nothrow {
		m_impl.setup();

		// detects invalid usage within synchronized(...)
		() @trusted { this.__monitor = cast(void*)&NoUseMonitor.instance(); } ();
	}

	bool tryLock() nothrow { return m_impl.tryLock(); }
	void lock() { m_impl.lock(); }
	void unlock() nothrow { m_impl.unlock(); }

	this()
	nothrow shared {
		m_impl.setup();

		// detects invalid usage within synchronized(...)
		() @trusted { this.__monitor = cast(void*)&NoUseMonitor.instance(); } ();
	}

	bool tryLock() shared nothrow { return m_impl.tryLock(); }
	void lock() shared { m_impl.lock(); }
	void unlock() shared nothrow { m_impl.unlock(); }
}

unittest {
	runMutexUnitTests!InterruptibleRecursiveTaskMutex();
}


// Helper class to ensure that the non Object.Monitor compatible interruptible
// mutex classes are not accidentally used with the `synchronized` statement
private final class NoUseMonitor : Object.Monitor {
	private static shared Proxy st_instance;

    static struct Proxy {
        Object.Monitor monitor;
    }

	static @property ref shared(Proxy) instance()
	@safe nothrow {
		static shared(Proxy)* inst = null;
		if (inst) return *inst;

		() @trusted { // synchronized {} not @safe for DMD <= 2.078.3
			synchronized {
				if (!st_instance.monitor)
					st_instance.monitor = new shared NoUseMonitor;
				inst = &st_instance;
			}
		} ();

		return *inst;
	}

	override void lock() @safe @nogc nothrow {
		assert(false, "Interruptible task mutexes cannot be used with synchronized(), use scopedMutexLock instead.");
	}

	override void unlock() @safe @nogc nothrow {}
}


private void runMutexUnitTests(M)()
{
	import vibe.core.core;

	auto m = new M;
	Task t1, t2;
	void runContendedTasks(bool interrupt_t1, bool interrupt_t2) {
		assert(!m.m_impl.m_locked);

		// t1 starts first and acquires the mutex for 20 ms
		// t2 starts second and has to wait in m.lock()
		t1 = runTask(() nothrow {
			assert(!m.m_impl.m_locked);
			try m.lock();
			catch (Exception e) assert(false, e.msg);
			assert(m.m_impl.m_locked);
			if (interrupt_t1) {
				try assertThrown!InterruptException(sleep(100.msecs));
				catch (Exception e) assert(false, e.msg);
			} else assertNotThrown(sleep(20.msecs));
			m.unlock();
		});
		t2 = runTask(() nothrow {
			assert(!m.tryLock());
			if (interrupt_t2) {
				try m.lock();
				catch (InterruptException) return;
				catch (Exception e) assert(false, e.msg);
				try yield(); // rethrows any deferred exceptions
				catch (InterruptException) {
					m.unlock();
					return;
				}
				catch (Exception e) assert(false, e.msg);
				assert(false, "Supposed to have thrown an InterruptException.");
			} else assertNotThrown(m.lock());
			assert(m.m_impl.m_locked);
			try sleep(20.msecs);
			catch (Exception e) assert(false, e.msg);
			m.unlock();
			assert(!m.m_impl.m_locked);
		});
	}

	// basic lock test
	m.performLocked!({
		assert(m.m_impl.m_locked);
	});
	assert(!m.m_impl.m_locked);

	// basic contention test
	runContendedTasks(false, false);
	auto t3 = runTask({
		assert(t1.running && t2.running);
		assert(m.m_impl.m_locked);
		t1.joinUninterruptible();
		assert(!t1.running && t2.running);
		try yield(); // give t2 a chance to take the lock
		catch (Exception e) assert(false, e.msg);
		assert(m.m_impl.m_locked);
		t2.joinUninterruptible();
		assert(!t2.running);
		assert(!m.m_impl.m_locked);
		exitEventLoop();
	});
	runEventLoop();
	assert(!t3.running);
	assert(!m.m_impl.m_locked);

	// interruption test #1
	runContendedTasks(true, false);
	t3 = runTask({
		assert(t1.running && t2.running);
		assert(m.m_impl.m_locked);
		t1.interrupt();
		t1.joinUninterruptible();
		assert(!t1.running && t2.running);
		try yield(); // give t2 a chance to take the lock
		catch (Exception e) assert(false, e.msg);
		assert(m.m_impl.m_locked);
		t2.joinUninterruptible();
		assert(!t2.running);
		assert(!m.m_impl.m_locked);
		exitEventLoop();
	});
	runEventLoop();
	assert(!t3.running);
	assert(!m.m_impl.m_locked);

	// interruption test #2
	runContendedTasks(false, true);
	t3 = runTask({
		assert(t1.running && t2.running);
		assert(m.m_impl.m_locked);
		t2.interrupt();
		t2.joinUninterruptible();
		assert(!t2.running);
		static if (is(M == InterruptibleTaskMutex) || is (M == InterruptibleRecursiveTaskMutex))
			assert(t1.running && m.m_impl.m_locked);
		t1.joinUninterruptible();
		assert(!t1.running);
		assert(!m.m_impl.m_locked);
		exitEventLoop();
	});
	runEventLoop();
	assert(!t3.running);
	assert(!m.m_impl.m_locked);
}


/**
	Event loop based condition variable or "event" implementation.

	This class can be used in exchange for a $(D core.sync.condition.Condition)
	to avoid blocking the event loop when waiting.

	Notice:
		Because this class is annotated nothrow, it cannot be interrupted
		using $(D vibe.core.task.Task.interrupt()). The corresponding
		$(D InterruptException) will be deferred until the next blocking
		operation yields to the event loop.

		Use $(D InterruptibleTaskCondition) as an alternative that can be
		interrupted.

		Note that it is generally not safe to use a `TaskCondition` together with an
		interruptible mutex type.

	See_Also: `InterruptibleTaskCondition`
*/
final class TaskCondition : core.sync.condition.Condition {
@safe:

	private shared(TaskConditionImpl!(false, Mutex)) m_impl;

	// non-shared compatibility API
	this(core.sync.mutex.Mutex mtx)
	nothrow {
		assert(mtx.classinfo is Mutex.classinfo || mtx.classinfo is TaskMutex.classinfo,
			"TaskCondition can only be used with Mutex or TaskMutex");

		m_impl.setup(() @trusted { return cast(shared)mtx; } ());
		super(mtx);
	}
	override @property Mutex mutex() nothrow { return () @trusted { return cast(Mutex)m_impl.mutex; } (); }
	override void wait() nothrow { m_impl.wait(); }
	override bool wait(Duration timeout) nothrow { return m_impl.wait(timeout); }
	override void notify() nothrow { m_impl.notify(); }
	override void notifyAll() nothrow  { m_impl.notifyAll(); }

	// new shared API
	static if (__VERSION__ >= 2093) {
		this(shared(core.sync.mutex.Mutex) mtx)
		shared nothrow {
			assert(mtx.classinfo is Mutex.classinfo || mtx.classinfo is TaskMutex.classinfo,
				"TaskCondition can only be used with Mutex or TaskMutex");

			m_impl.setup(mtx);
			super(mtx);
		}

		shared override @property shared(Mutex) mutex() nothrow { return m_impl.mutex; }
		shared override void wait() nothrow { m_impl.wait(); }
		shared override bool wait(Duration timeout) nothrow { return m_impl.wait(timeout); }
		shared override void notify() nothrow { m_impl.notify(); }
		shared override void notifyAll() nothrow  { m_impl.notifyAll(); }
	} else {
		shared @property shared(Mutex) mutex() nothrow { return m_impl.mutex; }
		shared void wait() nothrow { m_impl.wait(); }
		shared bool wait(Duration timeout) nothrow { return m_impl.wait(timeout); }
		shared void notify() nothrow { m_impl.notify(); }
		shared void notifyAll() nothrow  { m_impl.notifyAll(); }
	}
}

unittest {
	new TaskCondition(new Mutex);
	new TaskCondition(new TaskMutex);
	static if (__VERSION__ >= 2093) {
		new shared TaskCondition(new shared Mutex);
		new shared TaskCondition(new shared TaskMutex);
	}
}


/** This example shows the typical usage pattern using a `while` loop to make
	sure that the final condition is reached.
*/
unittest {
	import vibe.core.core;
	import vibe.core.log;

	__gshared Mutex mutex;
	__gshared TaskCondition condition;
	__gshared int workers_still_running = 0;

	// setup the task condition
	mutex = new Mutex;
	condition = new TaskCondition(mutex);

	logDebug("SETTING UP TASKS");

	// start up the workers and count how many are running
	foreach (i; 0 .. 4) {
		workers_still_running++;
		runWorkerTask(() nothrow {
			// simulate some work
			try sleep(100.msecs);
			catch (Exception e) {}

			// notify the waiter that we're finished
			{
				auto l = scopedMutexLock(mutex);
				workers_still_running--;
			logDebug("DECREMENT %s", workers_still_running);
			}
			logDebug("NOTIFY");
			condition.notify();
		});
	}

	logDebug("STARTING WAIT LOOP");

	// wait until all tasks have decremented the counter back to zero
	synchronized (mutex) {
		while (workers_still_running > 0) {
			logDebug("STILL running %s", workers_still_running);
			condition.wait();
		}
	}
}


/**
	Alternative to `TaskCondition` that supports interruption.

	This class supports the use of `vibe.core.task.Task.interrupt()` while
	waiting in the `wait()` method.

	See `TaskCondition` for an example.

	Notice:
		Note that it is generally not safe to use an
		`InterruptibleTaskCondition` together with an interruptible mutex type.

	See_Also: `TaskCondition`
*/
final class InterruptibleTaskCondition {
@safe:

	private shared(TaskConditionImpl!(true, Lockable)) m_impl;

	// non-shared compatibility API
	this(M)(M mutex)
		if (is(M : Mutex) || is (M : Lockable))
	{
		static if (is(M : Lockable))
			m_impl.setup(() @trusted { return cast(shared)mutex; } ());
		else
			m_impl.setupForMutex(() @trusted { return cast(shared)mutex; } ());
	}

	@property Lockable mutex() { return () @trusted { return cast(Lockable)m_impl.mutex; } (); }
	void wait() { m_impl.wait(); }
	bool wait(Duration timeout) { return m_impl.wait(timeout); }
	void notify() nothrow { m_impl.notify(); }
	void notifyAll() nothrow { m_impl.notifyAll(); }

	// new shared API
	this(M)(shared(M) mutex) shared
		if (is(M : Mutex) || is (M : Lockable))
	{
		static if (is(M : Lockable))
			m_impl.setup(mutex);
		else
			m_impl.setupForMutex(mutex);
	}

	@property shared(Lockable) mutex() shared { return m_impl.mutex; }
	void wait() shared { m_impl.wait(); }
	bool wait(Duration timeout) shared { return m_impl.wait(timeout); }
	void notify() shared nothrow { m_impl.notify(); }
	void notifyAll() shared nothrow { m_impl.notifyAll(); }
}

unittest {
	new InterruptibleTaskCondition(new Mutex);
	new InterruptibleTaskCondition(new TaskMutex);
	new InterruptibleTaskCondition(new InterruptibleTaskMutex);
	new shared InterruptibleTaskCondition(new shared Mutex);
	new shared InterruptibleTaskCondition(new shared TaskMutex);
	new shared InterruptibleTaskCondition(new shared InterruptibleTaskMutex);
}


/** A manually triggered single threaded cross-task event.

	Note: the ownership can be shared between multiple fibers of the same thread.
*/
struct LocalManualEvent {
	@safe:

	private {
		ThreadLocalWaiter!false m_waiter;
	}

	private void initialize()
	nothrow {
		m_waiter = allocPlainThreadLocalWaiter();
	}

	this(this)
	nothrow {
		if (m_waiter)
			return m_waiter.addRef();
	}

	~this()
	nothrow {
		if (m_waiter) m_waiter.releaseRef();
	}

	bool opCast (T : bool) () const nothrow { return m_waiter !is null; }

	/// A counter that is increased with every emit() call
	int emitCount() const nothrow { return m_waiter.emitCount; }

	/// Emits the signal, waking up all owners of the signal.
	int emit()
	nothrow {
		assert(m_waiter !is null, "LocalManualEvent is not initialized - use createManualEvent()");
		logTrace("unshared emit");
		auto ec = m_waiter.emitCount;
		m_waiter.emit();
		return ec;
	}

	/// Emits the signal, waking up a single owners of the signal.
	int emitSingle()
	nothrow {
		assert(m_waiter !is null, "LocalManualEvent is not initialized - use createManualEvent()");
		logTrace("unshared single emit");
		auto ec = m_waiter.emitCount;
		m_waiter.emitSingle();
		return ec;
	}

	/** Acquires ownership and waits until the signal is emitted.

		Note that in order not to miss any emits it is necessary to use the
		overload taking an integer.

		Throws:
			May throw an $(D InterruptException) if the task gets interrupted
			using $(D Task.interrupt()).
	*/
	int wait() { return wait(this.emitCount); }

	/** Acquires ownership and waits until the signal is emitted and the emit
		count is larger than a given one.

		Throws:
			May throw an $(D InterruptException) if the task gets interrupted
			using $(D Task.interrupt()).
	*/
	int wait(int emit_count) { return doWait!true(Duration.max, emit_count); }
	/// ditto
	int wait(Duration timeout, int emit_count) { return doWait!true(timeout, emit_count); }

	/** Same as $(D wait), but defers throwing any $(D InterruptException).

		This method is annotated $(D nothrow) at the expense that it cannot be
		interrupted.
	*/
	int waitUninterruptible() nothrow { return waitUninterruptible(this.emitCount); }
	/// ditto
	int waitUninterruptible(int emit_count) nothrow { return doWait!false(Duration.max, emit_count); }
	/// ditto
	int waitUninterruptible(Duration timeout, int emit_count) nothrow { return doWait!false(timeout, emit_count); }

	bool opEquals(ref const LocalManualEvent other)
	const nothrow {
		return this.m_waiter is other.m_waiter;
	}

	private int doWait(bool interruptible)(Duration timeout, int emit_count)
	{
		import core.time : MonoTime;

		assert(m_waiter !is null, "LocalManualEvent is not initialized - use createManualEvent()");

		MonoTime target_timeout, now;
		if (timeout != Duration.max) {
			try now = MonoTime.currTime();
			catch (Exception e) { assert(false, e.msg); }
			target_timeout = now + timeout;
		}

		while (m_waiter.emitCount - emit_count <= 0) {
			m_waiter.wait!interruptible(timeout != Duration.max ? target_timeout - now : Duration.max);
			try now = MonoTime.currTime();
			catch (Exception e) { assert(false, e.msg); }
			if (now >= target_timeout) break;
		}

		return m_waiter.emitCount;
	}
}

unittest {
	import vibe.core.core : exitEventLoop, runEventLoop, runTask, sleep;

	auto e = createManualEvent();
	auto w1 = runTask({ e.waitUninterruptible(100.msecs, e.emitCount); });
	auto w2 = runTask({ e.waitUninterruptible(500.msecs, e.emitCount); });
	runTask({
		try sleep(50.msecs);
		catch (Exception e) assert(false, e.msg);
		e.emit();
		try sleep(50.msecs);
		catch (Exception e) assert(false, e.msg);
		assert(!w1.running && !w2.running);
		exitEventLoop();
	});
	runEventLoop();
}

unittest {
	import vibe.core.core : exitEventLoop, runEventLoop, runTask, sleep;
	auto e = createManualEvent();
	// integer overflow test
	e.m_waiter.m_emitCount = int.max;
	auto w1 = runTask({ e.waitUninterruptible(50.msecs, e.emitCount); });
	runTask({
		try sleep(5.msecs);
		catch (Exception e) assert(false, e.msg);
		e.emit();
		try sleep(50.msecs);
		catch (Exception e) assert(false, e.msg);
		assert(!w1.running);
		exitEventLoop();
	});
	runEventLoop();
}

unittest { // ensure that cancelled waiters are properly handled and that a FIFO order is implemented
	import vibe.core.core : exitEventLoop, runEventLoop, runTask, sleep;

	LocalManualEvent l = createManualEvent();

	Task t2;
	runTask({
		l.waitUninterruptible();
		t2.interrupt();
		try sleep(20.msecs);
		catch (Exception e) assert(false, e.msg);
		exitEventLoop();
	});
	t2 = runTask({
		try {
			l.wait();
			assert(false, "Shouldn't reach this.");
		}
		catch (InterruptException e) {}
		catch (Exception e) assert(false, e.msg);
	});
	runTask({
		l.emit();
	});
	runEventLoop();
}

unittest { // ensure that LocalManualEvent behaves correctly after being copied
	import vibe.core.core : exitEventLoop, runEventLoop, runTask, sleep;

	LocalManualEvent l = createManualEvent();
	runTask(() nothrow {
		auto lc = l;
		try sleep(100.msecs);
		catch (Exception e) assert(false, e.msg);
		lc.emit();
	});
	runTask({
		assert(l.waitUninterruptible(1.seconds, l.emitCount));
		exitEventLoop();
	});
	runEventLoop();
}


/** A manually triggered multi threaded cross-task event.

	Note: the ownership can be shared between multiple fibers and threads.
*/
struct ManualEvent {
	import core.thread : Thread;
	import vibe.internal.list : StackSList;

	@safe:

	private {
		alias ThreadWaiter = ThreadLocalWaiter!true;

		int m_emitCount;
		static struct Waiters {
			StackSList!ThreadWaiter active; // actively waiting
		}
		Monitor!(Waiters, shared(Mutex)) m_waiters;
	}

	enum EmitMode {
		single,
		all
	}

	@disable this(this);

	private bool canBeFreed()
	shared nothrow {
		import core.memory : GC;
		if (GC.inFinalizer) return true;
		return m_waiters.lock.active.empty;
	}

	private void initialize()
	shared nothrow {
		m_waiters.initialize(new shared Mutex);
	}

	deprecated("ManualEvent is always non-null!")
	bool opCast (T : bool) () const shared nothrow { return true; }

	/// A counter that is increased with every emit() call
	int emitCount() const shared nothrow @trusted { return atomicLoad(m_emitCount); }

	/// Emits the signal, waking up all owners of the signal.
	int emit()
	shared nothrow @trusted {
		import core.atomic : atomicOp, cas;

		debug (VibeMutexLog) () @trusted { logTrace("emit shared %s", cast(void*)&this); } ();

		auto ec = atomicOp!"+="(m_emitCount, 1);
		auto thisthr = Thread.getThis();

		ThreadWaiter lw;
		auto drv = tryGetEventDriver;
		m_waiters.lock.active.iterate((ThreadWaiter w) {
			debug (VibeMutexLog) () @trusted { logTrace("waiter %s", cast(void*)w); } ();
			if (w.driver is drv) {
				lw = w;
				lw.addRef();
			} else {
				w.triggerEvent();
			}
			return true;
		});
		debug (VibeMutexLog) () @trusted { logTrace("lw %s", cast(void*)lw); } ();
		if (lw) {
			lw.emit();
			releaseWaiter(lw);
		}

		debug (VibeMutexLog) logTrace("emit shared done");

		return ec;
	}

	/// Emits the signal, waking up at least one waiting task
	int emitSingle()
	shared nothrow @trusted {
		import core.atomic : atomicOp, cas;

		() @trusted { logTrace("emit shared single %s", cast(void*)&this); } ();

		auto ec = atomicOp!"+="(m_emitCount, 1);
		auto thisthr = Thread.getThis();

		ThreadWaiter lw;
		auto drv = tryGetEventDriver;
		m_waiters.lock.active.iterate((ThreadWaiter w) {
			() @trusted { logTrace("waiter %s", cast(void*)w); } ();
			if (w.driver is drv) {
				if (w.unused) return true;
				lw = w;
				lw.addRef();
			} else {
				w.triggerEvent();
			}
			return false;
		});
		() @trusted { logTrace("lw %s", cast(void*)lw); } ();
		if (lw) {
			lw.emitSingle();
			releaseWaiter(lw);
		}

		logTrace("emit shared done");

		return ec;
	}

	/** Acquires ownership and waits until the signal is emitted.

		Note that in order not to miss any emits it is necessary to use the
		overload taking an integer.

		Throws:
			May throw an $(D InterruptException) if the task gets interrupted
			using $(D Task.interrupt()).
	*/
	int wait() shared { return wait(this.emitCount); }

	/** Acquires ownership and waits until the emit count differs from the
		given one or until a timeout is reached.

		Throws:
			May throw an $(D InterruptException) if the task gets interrupted
			using $(D Task.interrupt()).
	*/
	int wait(int emit_count) shared { return doWaitShared!true(Duration.max, emit_count); }
	/// ditto
	int wait(Duration timeout, int emit_count) shared { return doWaitShared!true(timeout, emit_count); }

	/** Same as $(D wait), but defers throwing any $(D InterruptException).

		This method is annotated $(D nothrow) at the expense that it cannot be
		interrupted.
	*/
	int waitUninterruptible() shared nothrow { return waitUninterruptible(this.emitCount); }
	/// ditto
	int waitUninterruptible(int emit_count) shared nothrow { return doWaitShared!false(Duration.max, emit_count); }
	/// ditto
	int waitUninterruptible(Duration timeout, int emit_count) shared nothrow { return doWaitShared!false(timeout, emit_count); }

	private int doWaitShared(bool interruptible)(Duration timeout, int emit_count)
	shared {
		import core.time : MonoTime;

		() @trusted { logTrace("wait shared %s", cast(void*)&this); } ();

		MonoTime target_timeout, now;
		if (timeout != Duration.max) {
			try now = MonoTime.currTime();
			catch (Exception e) { assert(false, e.msg); }
			target_timeout = now + timeout;
		}

		int ec = this.emitCount;

		acquireThreadWaiter((scope ThreadWaiter w) {
			while (ec - emit_count <= 0) {
				w.wait!interruptible(timeout != Duration.max ? target_timeout - now : Duration.max, () => (this.emitCount - emit_count) > 0);
				ec = this.emitCount;

				if (timeout != Duration.max) {
					try now = MonoTime.currTime();
					catch (Exception e) { assert(false, e.msg); }
					if (now >= target_timeout) break;
				}
			}
		});

		return ec;
	}

	private void acquireThreadWaiter(DEL)(scope DEL del)
	shared {
		ThreadWaiter w;
		auto drv = tryGetEventDriver;

		with (m_waiters.lock) {
			active.iterate((aw) {
				if (aw.driver is drv) {
					w = aw;
					w.addRef();
					return false;
				}
				return true;
			});

			if (!w) {
				w = allocEventThreadLocalWaiter();
				assert(w.unique == 1);
				active.add(w);
			}
		}

		scope (exit) releaseWaiter(w);

		del(w);
	}

	private void releaseWaiter(ThreadWaiter w)
	shared nothrow {
		assert(w.driver is eventDriver, "Waiter was reassigned a different driver!?");
		if (w.unique) {
			assert(w.unused, "Waiter still used, but not referenced!?");
			with (m_waiters.lock) {
				auto rmvd = active.remove(w);
				assert(rmvd, "Waiter not in active queue anymore!?");
			}
		}
		w.releaseRef();
	}
}

unittest {
	import vibe.core.core : exitEventLoop, runEventLoop, runTask, runWorkerTaskH, sleep;

	auto e = createSharedManualEvent();
	auto w1 = runTask({ e.waitUninterruptible(100.msecs, e.emitCount); });
	static void w(shared(ManualEvent)* e) { e.waitUninterruptible(500.msecs, e.emitCount); }
	auto w2 = runWorkerTaskH(&w, &e);
	runTask({
		try sleep(50.msecs);
		catch (Exception e) assert(false, e.msg);
		e.emit();
		try sleep(50.msecs);
		catch (Exception e) assert(false, e.msg);
		assert(!w1.running && !w2.running);
		exitEventLoop();
	});
	runEventLoop();
}

unittest {
	import vibe.core.core : runTask, runWorkerTaskH, setTimer, sleep;
	import vibe.core.taskpool : TaskPool;
	import core.time : msecs, usecs;
	import std.concurrency : send, receiveOnly;
	import std.random : uniform;

	auto tpool = new shared TaskPool(4);
	scope (exit) tpool.terminate();

	static void test(shared(ManualEvent)* evt, Task owner)
	nothrow {
		try owner.tid.send(Task.getThis());
		catch (Exception e) assert(false, e.msg);

		int ec = evt.emitCount;
		auto thist = Task.getThis();
		auto tm = setTimer(500.msecs, { thist.interrupt(); }); // watchdog
		scope (exit) tm.stop();
		while (ec < 5_000) {
			tm.rearm(500.msecs);
			try sleep(uniform(0, 10_000).usecs);
			catch (Exception e) assert(false, e.msg);
			try if (uniform(0, 10) == 0) evt.emit();
			catch (Exception e) assert(false, e.msg);
			auto ecn = evt.waitUninterruptible(ec);
			assert(ecn > ec);
			ec = ecn;
		}
	}

	auto watchdog = setTimer(30.seconds, { assert(false, "ManualEvent test has hung."); });
	scope (exit) watchdog.stop();

	auto e = createSharedManualEvent();
	Task[] tasks;

	runTask(() nothrow {
		auto thist = Task.getThis();

		// start 25 tasks in each thread
		foreach (i; 0 .. 25) tpool.runTaskDist(&test, &e, thist);
		// collect all task handles
		try foreach (i; 0 .. 4*25) tasks ~= receiveOnly!Task;
		catch (Exception e) assert(false, e.msg);

		auto tm = setTimer(500.msecs, { thist.interrupt(); }); // watchdog
		scope (exit) tm.stop();
		int pec = 0;
		while (e.emitCount < 5_000) {
			tm.rearm(500.msecs);
			try sleep(50.usecs);
			catch (Exception e) assert(false, e.msg);
			e.emit();
		}

		// wait for all worker tasks to finish
		foreach (t; tasks) t.joinUninterruptible();
	}).join();
}


/** Creates a new monitor primitive for type `T`.
*/
shared(Monitor!(T, M)) createMonitor(T, M)(M mutex)
@trusted {
	shared(Monitor!(T, M)) ret;
	ret.initialize(cast(shared)mutex);
	return ret;
}

///
unittest {
	import core.thread : Thread;
	import std.algorithm.iteration : sum;
	import vibe.core.core : runWorkerTaskH;

	shared items = createMonitor!(int[])(new Mutex);

	// Run 64 tasks with read-modify-write operations that would
	// quickly lead to race-conditions if performed unprotected
	Task[64] tasks;
	foreach (i; 0 .. tasks.length) {
		tasks[i] = runWorkerTaskH((shared(Monitor!(int[], Mutex))* itms) nothrow {
			// The monitor ensures that all access to the data
			// is protected by the mutex
			auto litems = itms.lock();
			auto newentry = sum(litems[]) + 1;
			Thread.sleep(10.msecs);
			litems ~= newentry;
		}, &items);
	}

	// finish up all tasks
	foreach (t; tasks) t.joinUninterruptible();

	// verify that the results are as expected
	auto litms = items.lock();
	assert(litms.length == tasks.length);
	foreach (idx, i; litms)
		assert(i == sum(litms[0 .. idx]) + 1);
}


/** Synchronization primitive to ensure accessing a piece of data is always
	protected by a locked mutex.

	This struct ensures through its API that the encapsulated data cannot be
	accessed without the associated mutex being locked. It should always be
	preferred over manually locking a mutex and casting away `shared`.

	See_also: `createMonitor`
*/
shared struct Monitor(T, M)
{
	alias Mutex = M;
	alias Data = T;

	private {
		Mutex mutex;
		Data data;
	}

	static struct Locked {
		shared(Monitor)* m;
		@disable this(this);
		~this() {
			() @trusted {
				static if (is(typeof(Mutex.init.unlock_nothrow())))
					(cast(Mutex)m.mutex).unlock_nothrow();
				else (cast(Mutex)m.mutex).unlock();
			} ();
		}
		ref inout(Data) get() inout return @trusted { return *cast(inout(Data)*)&m.data; }
		alias get this;
	}

	@disable this(this);

	private void initialize(shared(Mutex) m)
	{
		this.mutex = m;
	}

	Locked lock() {
		() @trusted {
			static if (is(typeof(Mutex.init.lock_nothrow())))
				(cast(Mutex)mutex).lock_nothrow();
			else (cast(Mutex)mutex).lock();
		} ();
		return Locked(() @trusted { return &this; } ());
	}

	const(Locked) lock() const {
		() @trusted {
			static if (is(typeof(Mutex.init.lock_nothrow())))
				(cast(Mutex)mutex).lock_nothrow();
			else (cast(Mutex)mutex).lock();
		} ();
		return const(Locked)(() @trusted { return &this; } ());
	}
}


private struct TaskMutexImpl(bool INTERRUPTIBLE) {
	private {
		shared(bool) m_locked = false;
		shared(uint) m_waiters = 0;
		shared(ManualEvent) m_signal;
		debug align(16) shared Task m_owner;
	}

	shared:

	void setup()
	{
		m_signal.initialize();
	}

	@trusted bool tryLock()
	nothrow {
		if (cas(&m_locked, false, true)) {
			debug {
				auto swapped = cas(&m_owner, Task.init, Task.getThis());
				assert(swapped);
			}
			debug(VibeMutexLog) logTrace("mutex %s lock %s", cast(void*)&this, atomicLoad(m_waiters));
			return true;
		}
		return false;
	}

	@trusted bool lock(Duration timeout = Duration.max)
	{
		if (tryLock()) return true;
		debug {
			auto thist = Task.getThis();
			auto owner = atomicLoad(m_owner);
			assert(owner == Task.init || owner != thist, "Recursive mutex lock.");
		}
		atomicOp!"+="(m_waiters, 1);
		debug(VibeMutexLog) logTrace("mutex %s wait %s", cast(void*)&this, atomicLoad(m_waiters));
		scope(exit) atomicOp!"-="(m_waiters, 1);
		auto ecnt = m_signal.emitCount();
		MonoTime target = MonoTime.currTime + timeout;
		while (!tryLock()) {
			auto now = MonoTime.currTime;
			if (timeout != Duration.max && now >= target)
				return false;

			auto remaining = timeout != Duration.max ? target - now : Duration.max;
			static if (INTERRUPTIBLE) ecnt = m_signal.wait(remaining, ecnt);
			else ecnt = m_signal.waitUninterruptible(remaining, ecnt);
		}
		return true;
	}

	@trusted void unlock()
	{
		assert(m_locked);
		debug {
			auto thist = Task.getThis();
			auto swapped = cas(&m_owner, thist, Task());
			assert(swapped);
		}
		atomicStore!(MemoryOrder.rel)(m_locked, false);
		debug(VibeMutexLog) logTrace("mutex %s unlock %s", cast(void*)&this, atomicLoad(m_waiters));
		if (atomicLoad(m_waiters) > 0)
			m_signal.emit();
	}
}

private struct RecursiveTaskMutexImpl(bool INTERRUPTIBLE) {
	import std.stdio;
	private static struct State {
		TaskFiber m_owner;
		size_t m_recCount = 0;
	}

	private {
		Monitor!(State, shared(core.sync.mutex.Mutex)) m_state;
		shared(uint) m_waiters = 0;
		shared(ManualEvent) m_signal;
		@property bool m_locked() const shared { return m_state.lock().m_recCount > 0; }
	}

	shared:

	void setup()
	{
		m_state.initialize(new shared core.sync.mutex.Mutex);
		m_signal.initialize();
	}

	@trusted bool tryLock()
	nothrow {
		auto self = TaskFiber.getThis();
		with (m_state.lock()) {
			if (!m_owner) {
				assert(m_recCount == 0, "Recursion count > 0 without lock owner!?");
				m_recCount = 1;
				m_owner = self;
				return true;
			} else if (m_owner is self) {
				m_recCount++;
				return true;
			}
			return false;
		}
	}

	@trusted void lock()
	{
		if (tryLock()) return;
		atomicOp!"+="(m_waiters, 1);
		debug(VibeMutexLog) logTrace("mutex %s wait %s", cast(void*)&this, atomicLoad(m_waiters));
		scope(exit) atomicOp!"-="(m_waiters, 1);
		auto ecnt = m_signal.emitCount();
		while (!tryLock()) {
			static if (INTERRUPTIBLE) ecnt = m_signal.wait(ecnt);
			else ecnt = m_signal.waitUninterruptible(ecnt);
		}
	}

	@trusted void unlock()
	{
		auto self = TaskFiber.getThis();
		with (m_state.lock()) {
			assert(m_owner is self);
			assert(m_recCount > 0);
			m_recCount--;
			if (m_recCount == 0) {
				m_owner = TaskFiber.init;
			}
		}
		debug(VibeMutexLog) logTrace("mutex %s unlock %s", cast(void*)&this, atomicLoad(m_waiters));
		if (atomicLoad(m_waiters) > 0)
			m_signal.emit();
	}
}

private struct TaskConditionImpl(bool INTERRUPTIBLE, LOCKABLE) {
	private {
		shared(LOCKABLE) m_mutex;
		static if (is(LOCKABLE == Mutex))
			shared(TaskMutex) m_taskMutex;
		shared(ManualEvent) m_signal;
	}

	static if (is(LOCKABLE == Lockable)) {
		final class MutexWrapper : Lockable {
			private shared(core.sync.mutex.Mutex) m_mutex;
			this(shared(core.sync.mutex.Mutex) mtx) shared { m_mutex = mtx; }
			@trusted void lock() { m_mutex.lock(); }
			@trusted void unlock() { m_mutex.unlock(); }
			@trusted bool tryLock() { return m_mutex.tryLock(); }
			@trusted void lock() shared { m_mutex.lock(); }
			@trusted void unlock() shared nothrow { m_mutex.unlock_nothrow(); }
			@trusted bool tryLock() shared nothrow { return m_mutex.tryLock_nothrow(); }
		}

		void setupForMutex(shared(core.sync.mutex.Mutex) mtx)
		shared {
			setup(new shared MutexWrapper(mtx));
		}
	}

	@disable this(this);

	~this()
	nothrow {
		assert(m_signal.canBeFreed());
		destroy(m_signal);
	}

	shared:

	void setup(shared(LOCKABLE) mtx)
	{
		m_mutex = mtx;
		static if (is(typeof(m_taskMutex)))
			m_taskMutex = cast(shared(TaskMutex))mtx;
		m_signal.initialize();
	}

	@property shared(LOCKABLE) mutex() { return m_mutex; }

	@trusted void wait()
	{
		if (auto tm = cast(TaskMutex)m_mutex) {
			assert(tm.m_impl.m_locked);
			debug assert(tm.m_impl.m_owner == Task.getThis());
		}

		auto refcount = m_signal.emitCount;

		static if (is(LOCKABLE == Mutex)) {
			if (m_taskMutex) m_taskMutex.unlock();
			else m_mutex.unlock_nothrow();
		} else static if (is(LOCKABLE : Lockable)) {
			() @trusted { return cast(Lockable)m_mutex; } ().unlock();
		} else m_mutex.unlock();

		scope(exit) {
			static if (is(LOCKABLE == Mutex)) {
				if (m_taskMutex) m_taskMutex.lock();
				else m_mutex.lock_nothrow();
			} else static if (is(LOCKABLE : Lockable)) {
				() @trusted { return cast(Lockable)m_mutex; } ().lock();
			} else m_mutex.lock();
		}
		static if (INTERRUPTIBLE) m_signal.wait(refcount);
		else m_signal.waitUninterruptible(refcount);
	}

	@trusted bool wait(Duration timeout)
	{
		assert(!timeout.isNegative());
		if (auto tm = cast(TaskMutex)m_mutex) {
			assert(tm.m_impl.m_locked);
			debug assert(tm.m_impl.m_owner == Task.getThis());
		}

		auto refcount = m_signal.emitCount;

		static if (is(LOCKABLE == Mutex)) {
			if (m_taskMutex) m_taskMutex.unlock();
			else m_mutex.unlock_nothrow();
		} else static if (is(LOCKABLE : Lockable)) {
			() @trusted { return cast(Lockable)m_mutex; } ().unlock();
		} else m_mutex.unlock();

		scope(exit) {
			static if (is(LOCKABLE == Mutex)) {
				if (m_taskMutex) m_taskMutex.lock();
				else m_mutex.lock_nothrow();
			} else static if (is(LOCKABLE : Lockable)) {
				() @trusted { return cast(Lockable)m_mutex; } ().lock();
			} else m_mutex.lock();
		}

		static if (INTERRUPTIBLE) return m_signal.wait(timeout, refcount) != refcount;
		else return m_signal.waitUninterruptible(timeout, refcount) != refcount;
	}

	@trusted void notify()
	{
		m_signal.emit();
	}

	@trusted void notifyAll()
	{
		m_signal.emit();
	}
}

/** Contains the shared state of a $(D TaskReadWriteMutex).
 *
 *  Since a $(D TaskReadWriteMutex) consists of two actual Mutex
 *  objects that rely on common memory, this class implements
 *  the actual functionality of their method calls.
 *
 *  The method implementations are based on two static parameters
 *  ($(D INTERRUPTIBLE) and $(D INTENT)), which are configured through
 *  template arguments:
 *
 *  - $(D INTERRUPTIBLE) determines whether the mutex implementation
 *    are interruptible by vibe.d's $(D vibe.core.task.Task.interrupt())
 *    method or not.
 *
 *  - $(D INTENT) describes the intent, with which a locking operation is
 *    performed (i.e. $(D READ_ONLY) or $(D READ_WRITE)). RO locking allows for
 *    multiple Tasks holding the mutex, whereas RW locking will cause
 *    a "bottleneck" so that only one Task can write to the protected
 *    data at once.
 */
private struct ReadWriteMutexState(bool INTERRUPTIBLE)
{
    /** The policy with which the mutex should operate.
     *
     *  The policy determines how the acquisition of the locks is
     *  performed and can be used to tune the mutex according to the
     *  underlying algorithm in which it is used.
     *
     *  According to the provided policy, the mutex will either favor
     *  reading or writing tasks and could potentially starve the
     *  respective opposite.
     *
     *  cf. $(D core.sync.rwmutex.ReadWriteMutex.Policy)
     */
    enum Policy : int
    {
        /** Readers are prioritized, writers may be starved as a result. */
        PREFER_READERS = 0,
        /** Writers are prioritized, readers may be starved as a result. */
        PREFER_WRITERS
    }

    /** The intent with which a locking operation is performed.
     *
     *  Since both locks share the same underlying algorithms, the actual
     *  intent with which a lock operation is performed (i.e read/write)
     *  are passed as a template parameter to each method.
     */
    enum LockingIntent : bool
    {
        /** Perform a read lock/unlock operation. Multiple reading locks can be
         *  active at a time. */
        READ_ONLY = 0,
        /** Perform a write lock/unlock operation. Only a single writer can
         *  hold a lock at any given time. */
        READ_WRITE = 1
    }

    private {
        //Queue counters
        /** The number of reading tasks waiting for the lock to become available. */
        shared(uint)  m_waitingForReadLock = 0;
        /** The number of writing tasks waiting for the lock to become available. */
        shared(uint)  m_waitingForWriteLock = 0;

        //Lock counters
        /** The number of reading tasks that currently hold the lock. */
        uint  m_activeReadLocks = 0;
        /** The number of writing tasks that currently hold the lock (binary). */
        ubyte m_activeWriteLocks = 0;

        /** The policy determining the lock's behavior. */
        Policy m_policy;

        //Queue Events
        /** The event used to wake reading tasks waiting for the lock while it is blocked. */
        shared(ManualEvent) m_readyForReadLock;
        /** The event used to wake writing tasks waiting for the lock while it is blocked. */
        shared(ManualEvent) m_readyForWriteLock;

        /** The underlying mutex that gates the access to the shared state. */
        Mutex m_counterMutex;
    }

    this(Policy policy)
    {
        m_policy = policy;
        m_counterMutex = new Mutex();
        m_readyForReadLock  = createSharedManualEvent();
        m_readyForWriteLock = createSharedManualEvent();
    }

    @disable this(this);

    /** The policy with which the lock has been created. */
    @property policy() const { return m_policy; }

    version(RWMutexPrint)
    {
        /** Print out debug information during lock operations. */
        void printInfo(string OP, LockingIntent INTENT)() nothrow
        {
        	import std.string;
            try
            {
                import std.stdio;
                writefln("RWMutex: %s (%s), active: RO: %d, RW: %d; waiting: RO: %d, RW: %d",
                    OP.leftJustify(10,' '),
                    INTENT == LockingIntent.READ_ONLY ? "RO" : "RW",
                    m_activeReadLocks,    m_activeWriteLocks,
                    m_waitingForReadLock, m_waitingForWriteLock
                    );
            }
            catch (Throwable t){}
        }
    }

    /** An internal shortcut method to determine the queue event for a given intent. */
    @property ref auto queueEvent(LockingIntent INTENT)()
    {
        static if (INTENT == LockingIntent.READ_ONLY)
            return m_readyForReadLock;
        else
            return m_readyForWriteLock;
    }

    /** An internal shortcut method to determine the queue counter for a given intent. */
    @property ref auto queueCounter(LockingIntent INTENT)()
    {
        static if (INTENT == LockingIntent.READ_ONLY)
            return m_waitingForReadLock;
        else
            return m_waitingForWriteLock;
    }

    /** An internal shortcut method to determine the current emitCount of the queue counter for a given intent. */
    int emitCount(LockingIntent INTENT)()
    {
        return queueEvent!INTENT.emitCount();
    }

    /** An internal shortcut method to determine the active counter for a given intent. */
    @property ref auto activeCounter(LockingIntent INTENT)()
    {
        static if (INTENT == LockingIntent.READ_ONLY)
            return m_activeReadLocks;
        else
            return m_activeWriteLocks;
    }

    /** An internal shortcut method to wait for the queue event for a given intent.
     *
     *  This method is used during the `lock()` operation, after a
     *  `tryLock()` operation has been unsuccessfully finished.
     *  The active fiber will yield and be suspended until the queue event
     *  for the given intent will be fired.
     */
    int wait(LockingIntent INTENT)(int count)
    {
        static if (INTERRUPTIBLE)
            return queueEvent!INTENT.wait(count);
        else
            return queueEvent!INTENT.waitUninterruptible(count);
    }

    /** An internal shortcut method to notify tasks waiting for the lock to become available again.
     *
     *  This method is called whenever the number of owners of the mutex hits
     *  zero; this is basically the counterpart to `wait()`.
     *  It wakes any Task currently waiting for the mutex to be released.
     */
    @trusted void notify(LockingIntent INTENT)()
    {
        static if (INTENT == LockingIntent.READ_ONLY)
        { //If the last reader unlocks the mutex, notify all waiting writers
            if (atomicLoad(m_waitingForWriteLock) > 0)
                m_readyForWriteLock.emit();
        }
        else
        { //If a writer unlocks the mutex, notify both readers and writers
            if (atomicLoad(m_waitingForReadLock) > 0)
                m_readyForReadLock.emit();

            if (atomicLoad(m_waitingForWriteLock) > 0)
                m_readyForWriteLock.emit();
        }
    }

    /** An internal method that performs the acquisition attempt in different variations.
     *
     *  Since both locks rely on a common TaskMutex object which gates the access
     *  to their common data acquisition attempts for this lock are more complex
     *  than for simple mutex variants. This method will thus be performing the
     *  `tryLock()` operation in two variations, depending on the callee:
     *
     *  If called from the outside ($(D WAIT_FOR_BLOCKING_MUTEX) = false), the method
     *  will instantly fail if the underlying mutex is locked (i.e. during another
     *  `tryLock()` or `unlock()` operation), in order to guarantee the fastest
     *  possible locking attempt.
     *
     *  If used internally by the `lock()` method ($(D WAIT_FOR_BLOCKING_MUTEX) = true),
     *  the operation will wait for the mutex to be available before deciding if
     *  the lock can be acquired, since the attempt would anyway be repeated until
     *  it succeeds. This will prevent frequent retries under heavy loads and thus
     *  should ensure better performance.
     */
    @trusted bool tryLock(LockingIntent INTENT, bool WAIT_FOR_BLOCKING_MUTEX)()
    {
        //Log a debug statement for the attempt
        version(RWMutexPrint)
            printInfo!("tryLock",INTENT)();

        //Try to acquire the lock
        static if (!WAIT_FOR_BLOCKING_MUTEX)
        {
            if (!m_counterMutex.tryLock())
                return false;
        }
        else
            m_counterMutex.lock();

        scope(exit)
            m_counterMutex.unlock();

        //Log a debug statement for the attempt
        version(RWMutexPrint)
            printInfo!("checkCtrs",INTENT)();

        //Check if there's already an active writer
        if (m_activeWriteLocks > 0)
            return false;

        //If writers are preferred over readers, check whether there
        //currently is a writer in the waiting queue and abort if
        //that's the case.
        static if (INTENT == LockingIntent.READ_ONLY)
            if (m_policy.PREFER_WRITERS && m_waitingForWriteLock > 0)
                return false;

        //If we are locking the mutex for writing, make sure that
        //there's no reader active.
        static if (INTENT == LockingIntent.READ_WRITE)
            if (m_activeReadLocks > 0)
                return false;

        //We can successfully acquire the lock!
        //Log a debug statement for the success.
        version(RWMutexPrint)
            printInfo!("lock",INTENT)();

        //Increase the according counter
        //(number of active readers/writers)
        //and return a success code.
        activeCounter!INTENT += 1;
        return true;
    }

    /** Attempt to acquire the lock for a given intent.
     *
     *  Returns:
     *      `true`, if the lock was successfully acquired;
     *      `false` otherwise.
     */
    @trusted bool tryLock(LockingIntent INTENT)()
    {
        //Try to lock this mutex without waiting for the underlying
        //TaskMutex - fail if it is already blocked.
        return tryLock!(INTENT,false)();
    }

    /** Acquire the lock for the given intent; yield and suspend until the lock has been acquired. */
    @trusted void lock(LockingIntent INTENT)()
    {
        //Prepare a waiting action before the first
        //`tryLock()` call in order to avoid a race
        //condition that could lead to the queue notification
        //not being fired.
        auto count = emitCount!INTENT;
        atomicOp!"+="(queueCounter!INTENT,1);
        scope(exit)
            atomicOp!"-="(queueCounter!INTENT,1);

        //Try to lock the mutex
        auto locked = tryLock!(INTENT,true)();
        if (locked)
            return;

        //Retry until we successfully acquired the lock
        while(!locked)
        {
            version(RWMutexPrint)
                printInfo!("wait",INTENT)();

            count  = wait!INTENT(count);
            locked = tryLock!(INTENT,true)();
        }
    }

    /** Unlock the mutex after a successful acquisition. */
    @trusted void unlock(LockingIntent INTENT)()
    {
        version(RWMutexPrint)
            printInfo!("unlock",INTENT)();

        debug assert(activeCounter!INTENT > 0);

        synchronized(m_counterMutex)
        {
            //Decrement the counter of active lock holders.
            //If the counter hits zero, notify waiting Tasks
            activeCounter!INTENT -= 1;
            if (activeCounter!INTENT == 0)
            {
                version(RWMutexPrint)
                    printInfo!("notify",INTENT)();

                notify!INTENT();
            }
        }
    }
}

/** A ReadWriteMutex implementation for fibers.
 *
 *  This mutex can be used in exchange for a $(D core.sync.mutex.ReadWriteMutex),
 *  but does not block the event loop in contention situations. The `reader` and `writer`
 *  members are used for locking. Locking the `reader` mutex allows access to multiple
 *  readers at once, while the `writer` mutex only allows a single writer to lock it at
 *  any given time. Locks on `reader` and `writer` are mutually exclusive (i.e. whenever a
 *  writer is active, no readers can be active at the same time, and vice versa).
 *
 *  Notice:
 *      Mutexes implemented by this class cannot be interrupted
 *      using $(D vibe.core.task.Task.interrupt()). The corresponding
 *      InterruptException will be deferred until the next blocking
 *      operation yields the event loop.
 *
 *      Use $(D InterruptibleTaskReadWriteMutex) as an alternative that can be
 *      interrupted.
 *
 *  cf. $(D core.sync.mutex.ReadWriteMutex)
 */
final class TaskReadWriteMutex
{
    private {
        alias State = ReadWriteMutexState!false;
        alias LockingIntent = State.LockingIntent;
        alias READ_ONLY  = LockingIntent.READ_ONLY;
        alias READ_WRITE = LockingIntent.READ_WRITE;

        /** The shared state used by the reader and writer mutexes. */
        State m_state;
    }

    /** The policy with which the mutex should operate.
     *
     *  The policy determines how the acquisition of the locks is
     *  performed and can be used to tune the mutex according to the
     *  underlying algorithm in which it is used.
     *
     *  According to the provided policy, the mutex will either favor
     *  reading or writing tasks and could potentially starve the
     *  respective opposite.
     *
     *  cf. $(D core.sync.rwmutex.ReadWriteMutex.Policy)
     */
    alias Policy = State.Policy;

    /** A common baseclass for both of the provided mutexes.
     *
     *  The intent for the according mutex is specified through the
     *  $(D INTENT) template argument, which determines if a mutex is
     *  used for read or write locking.
     */
    final class Mutex(LockingIntent INTENT): core.sync.mutex.Mutex, Lockable
    {
        /** Try to lock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override bool tryLock() { return m_state.tryLock!INTENT(); }
        /** Lock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override void lock()    { m_state.lock!INTENT(); }
        /** Unlock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override void unlock()  { m_state.unlock!INTENT(); }
    }
    alias Reader = Mutex!READ_ONLY;
    alias Writer = Mutex!READ_WRITE;

    Reader reader;
    Writer writer;

    this(Policy policy = Policy.PREFER_WRITERS)
    {
        m_state = State(policy);
        reader = new Reader();
        writer = new Writer();
    }

    /** The policy with which the lock has been created. */
    @property Policy policy() const { return m_state.policy; }
}

/** Alternative to $(D TaskReadWriteMutex) that supports interruption.
 *
 *  This class supports the use of $(D vibe.core.task.Task.interrupt()) while
 *  waiting in the `lock()` method.
 *
 *  cf. $(D core.sync.mutex.ReadWriteMutex)
 */
final class InterruptibleTaskReadWriteMutex
{
	@safe:

    private {
        alias State = ReadWriteMutexState!true;
        alias LockingIntent = State.LockingIntent;
        alias READ_ONLY  = LockingIntent.READ_ONLY;
        alias READ_WRITE = LockingIntent.READ_WRITE;

        /** The shared state used by the reader and writer mutexes. */
        State m_state;
    }

    /** The policy with which the mutex should operate.
     *
     *  The policy determines how the acquisition of the locks is
     *  performed and can be used to tune the mutex according to the
     *  underlying algorithm in which it is used.
     *
     *  According to the provided policy, the mutex will either favor
     *  reading or writing tasks and could potentially starve the
     *  respective opposite.
     *
     *  cf. $(D core.sync.rwmutex.ReadWriteMutex.Policy)
     */
    alias Policy = State.Policy;

    /** A common baseclass for both of the provided mutexes.
     *
     *  The intent for the according mutex is specified through the
     *  $(D INTENT) template argument, which determines if a mutex is
     *  used for read or write locking.
     *
     */
    final class Mutex(LockingIntent INTENT): core.sync.mutex.Mutex, Lockable
    {
        /** Try to lock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override bool tryLock() { return m_state.tryLock!INTENT(); }
        /** Lock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override void lock()    { m_state.lock!INTENT(); }
        /** Unlock the mutex. cf. $(D core.sync.mutex.Mutex) */
        override void unlock()  { m_state.unlock!INTENT(); }
    }
    alias Reader = Mutex!READ_ONLY;
    alias Writer = Mutex!READ_WRITE;

    Reader reader;
    Writer writer;

    this(Policy policy = Policy.PREFER_WRITERS)
    {
        m_state = State(policy);
        reader = new Reader();
        writer = new Writer();
    }

    /** The policy with which the lock has been created. */
    @property Policy policy() const { return m_state.policy; }
}
