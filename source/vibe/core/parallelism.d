/**
	Contains parallel computation primitives.

	Copyright: © 2021 Sönke Ludwig
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.parallelism;

public import vibe.core.taskpool;

import vibe.core.channel;
import vibe.core.concurrency : isWeaklyIsolated;
import vibe.core.log;
import std.range : ElementType, isInputRange;


/** Processes a range of items in worker tasks and returns them as an unordered
	range.

	The order of the result stream can deviate from the order of the input
	items, but the approach is more efficient that an ordered map.#

	See_also: `parallelMap`
*/
auto parallelUnorderedMap(alias fun, R)(R items, shared(TaskPool) task_pool, ChannelConfig channel_config = ChannelConfig.init)
	if (isInputRange!R && isWeaklyIsolated!(ElementType!R) && isWeaklyIsolated!(typeof(fun(ElementType!R.init))))
{
	import vibe.core.core : runTask;
	import core.atomic : atomicOp, atomicStore;

	alias I = ElementType!R;
	alias O = typeof(fun(I.init));

	ChannelConfig inconfig;
	inconfig.priority = ChannelPriority.overhead;
	auto chin = createChannel!I(inconfig);
	auto chout = createChannel!O(channel_config);

	// TODO: discard all operations if the result range is not referenced anymore

	static void senderFun(R items, Channel!I chin)
	nothrow {
		foreach (itm; items) {
			try chin.put(itm);
			catch (Exception e) {
				logException(e, "Failed to send parallel mapped input");
				break;
			}
		}
		chin.close();
	}

	static void workerFun(Channel!I chin, Channel!O chout, shared(int)* rc)
	nothrow {
		I item;
		while (chin.tryConsumeOne(item)) {
			try chout.put(fun(item));
			catch (Exception e) {
				logException(e, "Failed to send back parallel mapped result");
				break;
			}
		}
		if (!atomicOp!"-="(*rc, 1))
			chout.close();
	}

	runTask(&senderFun, items, chin);

	auto rc = new shared int;
	atomicStore(*rc, cast(int)task_pool.threadCount);

	task_pool.runTaskDist(&workerFun, chin, chout, rc);

	static struct Result {
		private {
			Channel!O m_channel;
			O m_front;
			bool m_gotFront = false;
		}

		@property bool empty()
		{
			fetchFront();
			return !m_gotFront;
		}

		@property ref O front()
		{
			fetchFront();
			assert(m_gotFront, "Accessing empty prallelMap range.");
			return m_front;
		}

		void popFront()
		{
			fetchFront();
			m_gotFront = false;
		}

		private void fetchFront()
		{
			if (m_gotFront) return;
			m_gotFront = m_channel.tryConsumeOne(m_front);
		}
	}

	return Result(chout);
}

/// ditto
auto parallelUnorderedMap(alias fun, R)(R items, ChannelConfig channel_config = ChannelConfig.init)
	if (isInputRange!R && isWeaklyIsolated!(ElementType!R) && isWeaklyIsolated!(typeof(fun(ElementType!R.init))))
{
	import vibe.core.core : workerTaskPool;
	return parallelUnorderedMap!(fun, R)(items, workerTaskPool, channel_config);
}

///
unittest {
	import std.algorithm : isPermutation, map;
	import std.array : array;
	import std.range : iota;

	auto res = iota(100)
		.parallelMap!(i => 2 * i)
		.array;
	assert(res.isPermutation(iota(100).map!(i => 2 * i).array));
}


/** Processes a range of items in worker tasks and returns them as an ordered
	range.

	The items of the returned stream are in the same order as input. Note that
	this may require dynamic buffering of results, so it is recommended to
	use unordered mapping if possible.

	See_also: `parallelUnorderedMap`
*/
auto parallelMap(alias fun, R)(R items, shared(TaskPool) task_pool, ChannelConfig channel_config)
	if (isInputRange!R && isWeaklyIsolated!(ElementType!R) && isWeaklyIsolated!(typeof(fun(ElementType!R.init))))
{
	import std.algorithm : canFind, countUntil, move, remove;
	import std.container.array : Array;
	import std.range : enumerate;
	import std.typecons : RefCounted, Tuple;

	alias I = ElementType!R;
	alias O = typeof(fun(I.init));
	static struct SR { size_t index; O value; }

	auto resunord = items
		.enumerate
		.parallelUnorderedMap!(itm => SR(itm.index, fun(itm.value)))(task_pool);

	static struct State {
		typeof(resunord) m_source;
		size_t m_index = 0, m_minIndex = -1;
		Array!SR m_buffer;
		int m_refCount = 0;

		@property bool empty()
		{
			return m_source.empty && m_buffer.length == 0;
		}
		@property ref O front()
		{
			fetchFront();
			auto idx = m_buffer[].countUntil!(sr => sr.index == m_index);
			if (idx < 0) {
				assert(m_source.front.index == m_index);
				return m_source.front.value;
			}
			return m_buffer[idx].value;
		}
		void popFront()
		{
			m_index++;

			auto idx = m_buffer[].countUntil!(sr => sr.index == m_index-1);
			if (idx < 0) {
				assert(m_source.front.index == m_index-1);
				m_source.popFront();
			} else {
				if (idx < m_buffer.length-1)
					m_buffer[idx] = m_buffer[$-1];
				m_buffer.removeBack();
			}
		}

		private void fetchFront()
		{
			if (m_buffer[].canFind!(sr => sr.index == m_index))
				return;

			while (m_source.front.index != m_index) {
				m_buffer ~= m_source.front;
				m_source.popFront();
			}
		}
	}

	static struct Result {
		private RefCounted!State state;

		@property bool empty() { return state.empty; }
		@property ref O front() { return state.front; }
		void popFront() { state.popFront; }
	}

	return Result(RefCounted!State(resunord.move));
}

/// ditto
auto parallelMap(alias fun, R)(R items, ChannelConfig channel_config = ChannelConfig.init)
	if (isInputRange!R && isWeaklyIsolated!(ElementType!R) && isWeaklyIsolated!(typeof(fun(ElementType!R.init))))
{
	import vibe.core.core : workerTaskPool;
	return parallelMap!(fun, R)(items, workerTaskPool, channel_config);
}

///
unittest {
	import std.algorithm : map;
	import std.array : array;
	import std.range : iota;

	auto res = iota(100)
		.parallelMap!(i => 2 * i)
		.array;
	assert(res == iota(100).map!(i => 2 * i).array);
}

///
unittest {
	import std.algorithm : isPermutation, map;
	import std.array : array;
	import std.random : uniform;
	import std.range : iota;
	import core.time : msecs;
	import vibe.core.core : sleep;

	// forcing a random computation result order still results in the same
	// output order
	auto res = iota(100)
		.parallelMap!((i) {
			sleep(uniform(0, 100).msecs);
			return 2 * i;
		})
		.array;
	assert(res == iota(100).map!(i => 2 * i).array);
}
