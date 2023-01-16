/+ dub.sdl:
	name "test"
	dependency "vibe-core" path=".."
+/
module test;

import vibe.core.core;
import vibe.core.stream;
import std.algorithm : min;
import std.array : Appender, appender;
import std.exception;
import std.random;
import core.time : Duration, msecs;

void main()
{
	auto datau = new uint[](2 * 1024 * 1024);
	foreach (ref u; datau)
		u = uniform!uint();
	auto data = cast(ubyte[])datau;

	test(data, 0,         0.msecs, 0,         0.msecs);
	test(data, 32768,     1.msecs, 32768,     1.msecs);

	test(data, 32768,     0.msecs, 0,         0.msecs);
	test(data, 0,         0.msecs, 32768,     0.msecs);
	test(data, 32768,     0.msecs, 32768,     0.msecs);

	test(data, 1023*967, 10.msecs, 0,         0.msecs);
	test(data, 0,         0.msecs, 1023*967, 20.msecs);
	test(data, 1023*967, 10.msecs, 1023*967, 10.msecs);

	test(data, 1023*967, 10.msecs, 32768,     0.msecs);
	test(data, 32768,     0.msecs, 1023*967, 10.msecs);

	test(data, 1023*967, 10.msecs, 65535,     0.msecs);
	test(data, 65535,     0.msecs, 1023*967, 10.msecs);
}

void test(ubyte[] data, ulong read_sleep_freq, Duration read_sleep,
	ulong write_sleep_freq, Duration write_sleep)
{
	test(data, ulong.max, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
	test(data, data.length * 2, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
	test(data, data.length / 2, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
	test(data, 64 * 1024, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
	test(data, 64 * 1024 - 57, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
	test(data, 557, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
}

void test(ubyte[] data, ulong chunk_limit, ulong read_sleep_freq,
	Duration read_sleep, ulong write_sleep_freq, Duration write_sleep)
{
	test(data, ulong.max, chunk_limit, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
	test(data, 8 * 1024 * 1024, chunk_limit, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
	test(data, 8 * 1024 * 1024 - 37, chunk_limit, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
	test(data, 37, chunk_limit, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
}

void test(ubyte[] data, ulong data_limit, ulong chunk_limit, ulong read_sleep_freq,
	Duration read_sleep, ulong write_sleep_freq, Duration write_sleep)
{
	import std.traits : EnumMembers;
	foreach (m; EnumMembers!PipeMode)
		test(data, m, data_limit, chunk_limit, read_sleep_freq, read_sleep, write_sleep_freq, write_sleep);
}

void test(ubyte[] data, PipeMode mode, ulong data_limit, ulong chunk_limit,
	ulong read_sleep_freq, Duration read_sleep, ulong write_sleep_freq,
	Duration write_sleep)
{
	import vibe.core.log;
	logInfo("test RF=%s RS=%sms WF=%s WS=%sms CL=%s DL=%s M=%s", read_sleep_freq, read_sleep.total!"msecs", write_sleep_freq, write_sleep.total!"msecs", chunk_limit, data_limit, mode);

	auto input = TestInputStream(data, chunk_limit, read_sleep_freq, read_sleep);
	auto output = TestOutputStream(write_sleep_freq, write_sleep);
	auto datacmp = data[0 .. min(data.length, data_limit)];

	input.pipe(output, data_limit, mode);
	if (output.m_data.data != datacmp) {
		logError("MISMATCH: %s b vs. %s b ([%(%s, %) ... %(%s, %)] vs. [%(%s, %) ... %(%s, %)])",
			output.m_data.data.length, datacmp.length,
			output.m_data.data[0 .. 6], output.m_data.data[$-6 .. $],
			datacmp[0 .. 6], datacmp[$-6 .. $]);
		assert(false);
	}

	// avoid leaking memory due to false pointers
	output.freeData();
}


struct TestInputStream {
	private {
		const(ubyte)[] m_data;
		ulong m_chunkLimit = size_t.max;
		ulong m_sleepFrequency = 0;
		Duration m_sleepAmount;
	}

	this(const(ubyte)[] data, ulong chunk_limit, ulong sleep_frequency, Duration sleep_amount)
	{
		m_data = data;
		m_chunkLimit = chunk_limit;
		m_sleepFrequency = sleep_frequency;
		m_sleepAmount = sleep_amount;
	}

	@safe:

	@property bool empty() @blocking { return m_data.length == 0; }

	@property ulong leastSize() @blocking { return min(m_data.length, m_chunkLimit); }

	@property bool dataAvailableForRead() { assert(false); }

	const(ubyte)[] peek() { assert(false); } // currently not used by pipe()

	size_t read(scope ubyte[] dst, IOMode mode)
	@blocking {
		assert(mode == IOMode.all || mode == IOMode.once);
		if (mode == IOMode.once)
			dst = dst[0 .. min($, m_chunkLimit)];
		auto oldsleeps = m_sleepFrequency ? m_data.length / m_sleepFrequency : 0;
		dst[] = m_data[0 .. dst.length];
		m_data = m_data[dst.length .. $];
		auto newsleeps = m_sleepFrequency ? m_data.length / m_sleepFrequency : 0;
		if (oldsleeps != newsleeps) {
			if (m_sleepAmount > 0.msecs)
				sleep(m_sleepAmount * (oldsleeps - newsleeps));
			else yield();
		}
		return dst.length;
	}
	void read(scope ubyte[] dst) @blocking { auto n = read(dst, IOMode.all); assert(n == dst.length); }
}

mixin validateInputStream!TestInputStream;

struct TestOutputStream {
	private {
		Appender!(ubyte[]) m_data;
		ulong m_sleepFrequency = 0;
		Duration m_sleepAmount;
	}

	this(ulong sleep_frequency, Duration sleep_amount)
	{
		m_data = appender!(ubyte[]);
		m_data.reserve(2*1024*1024);
		m_sleepFrequency = sleep_frequency;
		m_sleepAmount = sleep_amount;
	}

	void freeData()
	{
		import core.memory : GC;
		auto d = m_data.data;
		m_data.clear();
		GC.free(d.ptr);
	}

	@safe:

	void finalize() @safe @blocking {}
	void flush() @safe @blocking {}

	size_t write(in ubyte[] bytes, IOMode mode)
	@safe @blocking {
		assert(mode == IOMode.all);

		auto oldsleeps = m_sleepFrequency ? m_data.data.length / m_sleepFrequency : 0;
		m_data.put(bytes);
		auto newsleeps = m_sleepFrequency ? m_data.data.length / m_sleepFrequency : 0;
		if (oldsleeps != newsleeps) {
			if (m_sleepAmount > 0.msecs)
				sleep(m_sleepAmount * (newsleeps - oldsleeps));
			else yield();
		}
		return bytes.length;
	}
	void write(scope const(ubyte)[] bytes) @blocking { auto n = write(bytes, IOMode.all); assert(n == bytes.length); }
	void write(scope const(char)[] bytes) @blocking { write(cast(const(ubyte)[])bytes); }
}

mixin validateOutputStream!TestOutputStream;
