/** Implementation of the wait/notify base logic used for most concurrency
	primitives
*/
module vibe.core.internal.threadlocalwaiter;

import vibe.container.internal.utilallocator : Mallocator, disposeGCSafe, makeGCSafe;
import vibe.core.log;
import vibe.internal.list : StackSList;

import eventcore.core : NativeEventDriver, eventDriver;
import eventcore.driver : EventCallback, EventID;


package(vibe.core):

static StackSList!(ThreadLocalWaiter!true) s_free; // free-list of reusable waiter structs for the calling thread

ThreadLocalWaiter!false allocPlainThreadLocalWaiter()
@safe nothrow {
	return () @trusted { return Mallocator.instance.makeGCSafe!(ThreadLocalWaiter!false); } ();
}

ThreadLocalWaiter!true allocEventThreadLocalWaiter()
@safe nothrow {
	auto drv = eventDriver;

	ThreadLocalWaiter!true w;
	if (!s_free.empty) {
		w = s_free.first;
		s_free.remove(w);
		assert(w.m_refCount == 0);
		assert(w.m_driver is drv);
		w.addRef();
	} else {
		w = new ThreadLocalWaiter!true;
	}
	assert(w.m_refCount == 1);
	return w;
}

void freeThreadResources()
@safe nothrow {
	s_free.filter((w) @trusted {
		try destroy(w);
		catch (Exception e) assert(false, e.msg);
		return false;
	});
}


/** An object able to wait in a single thread
*/
final class ThreadLocalWaiter(bool EVENT_TRIGGERED) {
	import vibe.internal.list : CircularDList;
	import core.time : Duration;

	private {
		static struct TaskWaiter {
			TaskWaiter* prev, next;
			void delegate() @safe nothrow notifier;

			void wait(void delegate() @safe nothrow del) @safe nothrow {
				assert(notifier is null, "Local waiter is used twice!");
				notifier = del;
			}
			void cancel() @safe nothrow { notifier = null; }
			void emit() @safe nothrow { auto n = notifier; notifier = null; n(); }
		}

		static if (EVENT_TRIGGERED) {
			package(vibe) ThreadLocalWaiter next; // queue of other waiters in the active/free list of the manual event
			NativeEventDriver m_driver;
			EventID m_event = EventID.invalid;
		} else {
			version (unittest) package(vibe.core) int m_emitCount = 0;
			else int m_emitCount = 0;
		}
		int m_refCount = 1;
		TaskWaiter m_pivot;
		TaskWaiter m_emitPivot;
		CircularDList!(TaskWaiter*) m_waiters;
	}

	this()
	{
		m_waiters = CircularDList!(TaskWaiter*)(() @trusted { return &m_pivot; } ());
		static if (EVENT_TRIGGERED) {
			m_driver = eventDriver;
			m_event = m_driver.events.create();
			assert(m_event != EventID.invalid, "Failed to create event!");
		}
	}

	static if (EVENT_TRIGGERED) {
		~this()
		{
			import vibe.core.internal.release : releaseHandle;
			import core.memory : GC;
			import core.stdc.stdlib : abort;

			if (m_event != EventID.invalid) {
				if (m_driver !is eventDriver) {
					logError("ThreadWaiter destroyed in foreign thread");
					// handle GC finalization at process exit gracefully, as
					// this can happen when tasks/threads have not been properly
					// shut down before application exit
					if (!GC.inFinalizer()) abort();
				} else m_driver.events.releaseRef(m_event);
				m_event = EventID.invalid;
			}
		}
	}

	@property bool unused() const @safe nothrow { return m_waiters.empty; }
	@property bool unique() const @safe nothrow { return m_refCount == 1; }

	static if (!EVENT_TRIGGERED) {
		@property int emitCount() const @safe nothrow { return m_emitCount; }
	} else {
		@property NativeEventDriver driver() @safe nothrow { return m_driver; }
	}

	void addRef() @safe nothrow { assert(m_refCount >= 0); m_refCount++; }
	bool releaseRef()
	@safe nothrow {
		assert(m_refCount > 0, "Releasing unreferenced thread local waiter");
		if (--m_refCount == 0) {
			static if (EVENT_TRIGGERED) {
				s_free.add(this);
				// TODO: cap size of m_freeWaiters
			} else {
				static if (__VERSION__ < 2087) scope (failure) assert(false);
				() @trusted { Mallocator.instance.disposeGCSafe(this); } ();
			}
			return false;
		}
		return true;
	}

	bool wait(bool interruptible)(Duration timeout, scope bool delegate() @safe nothrow exit_condition = null)
	@safe {
		import core.time : MonoTime;
		import vibe.internal.async : Waitable, asyncAwaitAny;

		TaskWaiter waiter_store;
		TaskWaiter* waiter = () @trusted { return &waiter_store; } ();

		m_waiters.insertBack(waiter);
		assert(waiter.next !is null);
		scope (exit)
			if (waiter.next !is null) {
				m_waiters.remove(waiter);
				assert(!waiter.next);
			}

		MonoTime target_timeout, now;
		if (timeout != Duration.max) {
			try now = MonoTime.currTime();
			catch (Exception e) { assert(false, e.msg); }
			target_timeout = now + timeout;
		}

		bool cancelled;

		alias waitable = Waitable!(typeof(TaskWaiter.notifier),
			(cb) { waiter.wait(cb); },
			(cb) { cancelled = true; waiter.cancel(); },
			() {}
		);

		static if (EVENT_TRIGGERED) {
			alias ewaitable = Waitable!(EventCallback,
				(cb) {
					eventDriver.events.wait(m_event, cb);
					// check for exit condition *after* starting to wait for the event
					// to avoid a race condition
					if (exit_condition()) {
						eventDriver.events.cancelWait(m_event, cb);
						cb(m_event);
					}
				},
				(cb) { eventDriver.events.cancelWait(m_event, cb); },
				(EventID) {}
			);

			assert(m_event != EventID.invalid);
			asyncAwaitAny!(interruptible, waitable, ewaitable)(timeout);
		} else {
			asyncAwaitAny!(interruptible, waitable)(timeout);
		}

		if (cancelled) {
			assert(waiter.next !is null, "Cancelled waiter not in queue anymore!?");
			return false;
		} else {
			assert(waiter.next is null, "Triggered waiter still in queue!?");
			return true;
		}
	}

	void emit()
	@safe nothrow {
		import std.algorithm.mutation : swap;
		import vibe.core.core : yield;

		static if (!EVENT_TRIGGERED)
			m_emitCount++;

		if (m_waiters.empty) return;

		TaskWaiter* pivot = () @trusted { return &m_emitPivot; } ();

		if (pivot.next) { // another emit in progress?
			// shift pivot to the end, so that the other emit call will process all pending waiters
			if (pivot !is m_waiters.back) {
				m_waiters.remove(pivot);
				m_waiters.insertBack(pivot);
			}
			return;
		}

		m_waiters.insertBack(pivot);
		scope (exit) m_waiters.remove(pivot);

		foreach (w; m_waiters) {
			if (w is pivot) break;
			emitWaiter(w);
		}
	}

	bool emitSingle()
	@safe nothrow {
		static if (!EVENT_TRIGGERED)
			m_emitCount++;

		if (m_waiters.empty) return false;

		TaskWaiter* pivot = () @trusted { return &m_emitPivot; } ();

		if (pivot.next) { // another emit in progress?
			// shift pivot to the right, so that the other emit call will process another waiter
			if (pivot !is m_waiters.back) {
				auto n = pivot.next;
				m_waiters.remove(pivot);
				m_waiters.insertAfter(pivot, n);
			}
			return true;
		}

		emitWaiter(m_waiters.front);
		return true;
	}

	static if (EVENT_TRIGGERED) {
		void triggerEvent()
		{
			try {
				assert(m_event != EventID.invalid);
				() @trusted { return cast(shared)m_driver; } ().events.trigger(m_event, true);
			} catch (Exception e) assert(false, e.msg);
		}
	}

	private void emitWaiter(TaskWaiter* w)
	@safe nothrow {
		m_waiters.remove(w);

		if (w.notifier !is null) {
			logTrace("notify task %s %s %s", cast(void*)w, () @trusted { return cast(void*)w.notifier.funcptr; } (), w.notifier.ptr);
			w.emit();
		} else logTrace("notify callback is null");
	}
}

