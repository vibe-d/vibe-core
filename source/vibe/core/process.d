/**
	Functions and structures for dealing with subprocesses and pipes.

	This module is modeled after std.process, but provides a fiber-aware
	alternative to it. All blocking operations will yield the calling fiber
	instead of blocking it.
*/
module vibe.core.process;

public import std.process : Pid, Redirect;
static import std.process;

import core.time;
import std.array;
import std.typecons;
import std.exception : enforce;
import std.algorithm;
import eventcore.core;
import vibe.core.path;
import vibe.core.log;
import vibe.core.stream;
import vibe.internal.async;
import vibe.internal.array : BatchBuffer;
import vibe.core.internal.release;

@safe:

/**
	Register a process with vibe for fibre-aware handling. This process can be
	started from anywhere including external libraries or std.process.

	Params:
		pid = A Pid or OS process id
*/
Process adoptProcessID(Pid pid)
@trusted {
	return adoptProcessID(pid.processID);
}

/// ditto
Process adoptProcessID(int pid)
{
	auto p = eventDriver.processes.adopt(pid);
	if (p == ProcessID.invalid)
		throw new Exception("Failed to adopt process ID");
	return Process(p);
}

/**
	Path to the user's preferred command interpreter.

	See_Also: `nativeShell`
*/
@property NativePath userShell() { return NativePath(std.process.userShell); }

/**
	The platform specific native shell path.

	See_Also: `userShell`
*/
const NativePath nativeShell = NativePath(std.process.nativeShell);

/**
	Equivalent to `std.process.Config` except with less flag support
*/
enum Config {
	none = ProcessConfig.none,
	newEnv = ProcessConfig.newEnv,
	suppressConsole = ProcessConfig.suppressConsole,
	detached = ProcessConfig.detached,
}

/**
	Equivalent to `std.process.spawnProcess`.

	Returns:
		A reference to the running process.

	See_Also: `pipeProcess`, `execute`
*/
Process spawnProcess(
	scope string[] args,
	const string[string] env = null,
	Config config = Config.none,
	scope NativePath workDir = NativePath.init)
@trusted {
	auto process = eventDriver.processes.spawn(
		args,
		ProcessStdinFile(ProcessRedirect.inherit),
		ProcessStdoutFile(ProcessRedirect.inherit),
		ProcessStderrFile(ProcessRedirect.inherit),
		env,
		config,
		workDir.toNativeString());

	if (process.pid == ProcessID.invalid)
		throw new Exception("Failed to spawn process");

	return Process(process.pid);
}

/// ditto
Process spawnProcess(
	scope string program,
	const string[string] env = null,
	Config config = Config.none,
	scope NativePath workDir = NativePath.init)
{
	return spawnProcess(
		[program],
		env,
		config,
		workDir
	);
}

/// ditto
Process spawnShell(
	scope string command,
	const string[string] env = null,
	Config config = Config.none,
	scope NativePath workDir = NativePath.init,
	scope NativePath shellPath = nativeShell)
{
	return spawnProcess(
		shellCommand(command, shellPath),
		env,
		config,
		workDir);
}

private string[] shellCommand(string command, NativePath shellPath)
{
	version (Windows)
	{
		// CMD does not parse its arguments like other programs.
		// It does not use CommandLineToArgvW.
		// Instead, it treats the first and last quote specially.
		// See CMD.EXE /? for details.
		return [
			std.process.escapeShellFileName(shellPath.toNativeString())
				~ ` /C "` ~ command ~ `"`
		];
	}
	else version (Posix)
	{
		return [
			shellPath.toNativeString(),
			"-c",
			command,
		];
	}
}

/**
	Represents a running process.
*/
struct Process {
	private static struct Context {
		//Duration waitTimeout;
		shared(NativeEventDriver) driver;
	}

	private {
		ProcessID m_pid;
		Context* m_context;
	}

	private this(ProcessID p)
	nothrow {
		assert(p != ProcessID.invalid);
		m_pid = p;
		m_context = () @trusted { return &eventDriver.processes.userData!Context(p); } ();
		m_context.driver = () @trusted { return cast(shared)eventDriver; } ();
	}

	this(this)
	nothrow {
		if (m_pid != ProcessID.invalid)
			eventDriver.processes.addRef(m_pid);
	}

	~this()
	nothrow {
		if (m_pid != ProcessID.invalid)
			releaseHandle!"processes"(m_pid, m_context.driver);
	}

	/**
		Check whether this is a valid process handle. The process may have
		exited already.
	*/
	bool opCast(T)() const nothrow if (is(T == bool)) { return m_pid != ProcessID.invalid; }

	///
	unittest {
		Process p;

		assert(!p);
	}

	/**
		An operating system handle to the process.
	*/
	@property int pid() const nothrow @nogc { return cast(int)m_pid; }

	/**
		Whether the process has exited.
	*/
	@property bool exited() const nothrow { return eventDriver.processes.hasExited(m_pid); }

	/**
		Wait for the process to exit, allowing other fibers to continue in the
		meantime.

		Params:
			timeout = Optionally wait until a timeout is reached.

		Returns:
			The exit code of the process. If a timeout is given and reached, a
			null value is returned.
	*/
	int wait()
	@blocking {
		return asyncAwaitUninterruptible!(ProcessWaitCallback,
			cb => eventDriver.processes.wait(m_pid, cb)
		)[1];
	}

	/// Ditto
	Nullable!int wait(Duration timeout)
	@blocking {
		size_t waitId;
		bool cancelled = false;

		int code = asyncAwaitUninterruptible!(ProcessWaitCallback,
			(cb) nothrow @safe {
				waitId = eventDriver.processes.wait(m_pid, cb);
			},
			(cb) nothrow @safe {
				eventDriver.processes.cancelWait(m_pid, waitId);
				cancelled = true;
			},
		)(timeout)[1];

		if (cancelled) {
			return Nullable!int.init;
		} else {
			return code.nullable;
		}
	}

	/**
		Kill the process.

		By default on Linux this sends SIGTERM to the process.

		Params:
			signal = Optional parameter for the signal to send to the process.
	*/
	void kill()
	{
		version (Posix)
		{
			import core.sys.posix.signal : SIGTERM;
			eventDriver.processes.kill(m_pid, SIGTERM);
		}
		else
		{
			eventDriver.processes.kill(m_pid, 1);
		}
	}

	/// ditto
	void kill(int signal)
	{
		eventDriver.processes.kill(m_pid, signal);
	}

	/**
		Terminate the process immediately.

		On Linux this sends SIGKILL to the process.
	*/
	void forceKill()
	{
		version (Posix)
		{
			import core.sys.posix.signal : SIGKILL;
			eventDriver.processes.kill(m_pid, SIGKILL);
		}
		else
		{
			eventDriver.processes.kill(m_pid, 1);
		}
	}

	/**
		Wait for the process to exit until a timeout is reached. If the process
		doesn't exit before the timeout, force kill it.

		Returns:
			The process exit code.
	*/
	int waitOrForceKill(Duration timeout)
	@blocking {
		auto code = wait(timeout);

		if (code.isNull) {
			forceKill();
			return wait();
		} else {
			return code.get;
		}
	}
}

/**
	A stream for tBatchBufferhe write end of a pipe.
*/
struct PipeInputStream {
	private static struct Context {
		BatchBuffer!ubyte readBuffer;
		shared(NativeEventDriver) driver;
	}

	private {
		PipeFD m_pipe;
		Context* m_context;
	}

	private this(PipeFD pipe)
	nothrow {
		m_pipe = pipe;
		if (pipe != PipeFD.invalid) {
			m_context = () @trusted { return &eventDriver.pipes.userData!Context(pipe); } ();
			m_context.readBuffer.capacity = 4096;
			m_context.driver = () @trusted { return cast(shared)eventDriver; } ();
		}
	}

	this(this)
	nothrow {
		if (m_pipe != PipeFD.invalid)
			eventDriver.pipes.addRef(m_pipe);
	}

	~this()
	nothrow {
		if (m_pipe != PipeFD.invalid)
			releaseHandle!"pipes"(m_pipe, m_context.driver);
	}

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_pipes != PipeFD.invalid; }

	@property bool empty() @blocking { return leastSize == 0; }
	@property ulong leastSize()
	@blocking {
		waitForData();
		return m_context ? m_context.readBuffer.length : 0;
	}
	@property bool dataAvailableForRead() { return waitForData(0.seconds); }

	bool waitForData(Duration timeout = Duration.max)
	@blocking {
		if (!m_context) return false;
		if (m_context.readBuffer.length > 0) return true;
		auto mode = timeout <= 0.seconds ? IOMode.immediate : IOMode.once;

		bool cancelled;
		IOStatus status;
		size_t nbytes;

		alias waiter = Waitable!(PipeIOCallback,
			cb => eventDriver.pipes.read(m_pipe, m_context.readBuffer.peekDst(), mode, cb),
			(cb) {
				cancelled = true;
				eventDriver.pipes.cancelRead(m_pipe);
			},
			(pipe, st, nb) {
				// Handle closed pipes
				if (m_pipe == PipeFD.invalid) {
					cancelled = true;
					return;
				}

				assert(pipe == m_pipe);
				status = st;
				nbytes = nb;
			}
		);

		asyncAwaitAny!(true, waiter)(timeout);

		if (cancelled || !m_context) return false;

		logTrace("Pipe %s, read %s bytes: %s", m_pipe, nbytes, status);

		assert(m_context.readBuffer.length == 0);
		m_context.readBuffer.putN(nbytes);
		switch (status) {
			case IOStatus.ok: break;
			case IOStatus.disconnected: break;
			case IOStatus.wouldBlock:
				assert(mode == IOMode.immediate);
				break;
			default:
				logDebug("Error status when waiting for data: %s", status);
				break;
		}

		return m_context.readBuffer.length > 0;
	}

	const(ubyte)[] peek() { return m_context ? m_context.readBuffer.peek() : null; }

	size_t read(scope ubyte[] dst, IOMode mode)
	@blocking {
		if (dst.empty) return 0;

		if (m_context.readBuffer.length >= dst.length) {
			m_context.readBuffer.read(dst);
			return dst.length;
		}

		size_t nbytes = 0;

		while (true) {
			if (m_context.readBuffer.length == 0) {
				if (mode == IOMode.immediate || mode == IOMode.once && nbytes > 0)
					break;

				enforce(waitForData(), "Reached end of stream while reading data.");
			}

			assert(m_context.readBuffer.length > 0);
			auto l = min(dst.length, m_context.readBuffer.length);
			m_context.readBuffer.read(dst[0 .. l]);
			dst = dst[l .. $];
			nbytes += l;
			if (dst.length == 0)
				break;
		}

		return nbytes;
	}

	void read(scope ubyte[] dst)
	@blocking {
		auto r = read(dst, IOMode.all);
		assert(r == dst.length);
	}

	/**
		Close the read end of the pipe immediately.

		Make sure that the pipe is not used after this is called and is released
		as soon as possible. Due to implementation detail in eventcore this
		reference could conflict with future pipes.
	*/
	void close()
	nothrow {
		if (m_pipe == PipeFD.invalid) return;

		asyncAwaitUninterruptible!(PipeCloseCallback,
			cb => eventDriver.pipes.close(m_pipe, cb)
		);

		eventDriver.pipes.releaseRef(m_pipe);
		m_pipe = PipeFD.invalid;
	}
}

mixin validateInputStream!PipeInputStream;

/**
	Stream for the read end of a pipe.
*/
struct PipeOutputStream {
	private static struct Context {
		shared(NativeEventDriver) driver;
	}

	private {
		PipeFD m_pipe;
		Context* m_context;
	}

	private this(PipeFD pipe)
	nothrow {
		m_pipe = pipe;
		if (pipe != PipeFD.invalid) {
			m_context = () @trusted { return &eventDriver.pipes.userData!Context(pipe); } ();
			m_context.driver = () @trusted { return cast(shared)eventDriver; } ();
		}
	}

	this(this)
	nothrow {
		if (m_pipe != PipeFD.invalid)
			eventDriver.pipes.addRef(m_pipe);
	}

	~this()
	nothrow {
		if (m_pipe != PipeFD.invalid)
			releaseHandle!"pipes"(m_pipe, m_context.driver);
	}

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_pipes != PipeFD.invalid; }

	size_t write(in ubyte[] bytes, IOMode mode)
	@blocking {
		if (bytes.empty) return 0;

		auto res = asyncAwait!(PipeIOCallback,
			cb => eventDriver.pipes.write(m_pipe, bytes, mode, cb),
			cb => eventDriver.pipes.cancelWrite(m_pipe));

		switch (res[1]) {
			case IOStatus.ok: break;
			case IOStatus.disconnected: break;
			default:
				throw new Exception("Error writing data to pipe.");
		}

		return res[2];
	}

	void write(in ubyte[] bytes) @blocking { auto r = write(bytes, IOMode.all); assert(r == bytes.length); }
	void write(in char[] bytes) @blocking { write(cast(const(ubyte)[])bytes); }

	void flush() {}
	void finalize() {}

	/**
		Close the write end of the pipe immediately.

		Make sure that the pipe is not used after this is called and is released
		as soon as possible. Due to implementation detail in eventcore this
		reference could conflict with future pipes.
	*/
	void close()
	nothrow {
		if (m_pipe == PipeFD.invalid) return;

		asyncAwaitUninterruptible!(PipeCloseCallback,
			cb => eventDriver.pipes.close(m_pipe, cb)
		);

		eventDriver.pipes.releaseRef(m_pipe);
		m_pipe = PipeFD.invalid;
	}
}

mixin validateOutputStream!PipeOutputStream;

/**
	A pipe created by `pipe`.
*/
struct Pipe {
	/// Read end of the pipe
	PipeInputStream readEnd;
	/// Write end of the pipe
	PipeOutputStream writeEnd;

	/**
		Close both ends of the pipe
	*/
	void close()
	nothrow {
		writeEnd.close();
		readEnd.close();
	}
}

/**
	Create a pipe, async equivalent of `std.process.pipe`.

	Returns:
		A stream for each end of the pipe.
*/
Pipe pipe()
{
	import std.stdio : StdioException;

	version (Posix) {
		import core.sys.posix.unistd : pipe;
		int[2] fds;
		if (pipe(fds) != 0)
			throw new StdioException("Unable to create pipe");
		int readFD = fds[0];
		int writeFD = fds[1];
	}
	else version (Windows) {
		import core.sys.windows.winbase : CreatePipe, GetLastError;
		import core.sys.windows.windef;
		import std.windows.syserror : sysErrorString;
		HANDLE readHandle;
		HANDLE writeHandle;
		if (!() @trusted { return CreatePipe(&readHandle, &writeHandle, null, 0); }()) {
			throw new StdioException(
				"Error creating pipe (" ~ sysErrorString(GetLastError()) ~ ')',
				0);
		}
		version (CRuntime_DigitalMars) {
			import core.stdc.stdio : _handleToFD, FHND_DEVICE;
			int readFD = _handleToFD(readHandle, FHND_DEVICE);
			int writeFD = _handleToFD(writeHandle, FHND_DEVICE);
		} else {
			import core.stdc.stdint : intptr_t;
			import core.stdc.stdio : _open_osfhandle, O_RDONLY, O_APPEND;
			int readFD = () @trusted { return _open_osfhandle(cast(intptr_t)readHandle, O_RDONLY); }();
			int writeFD = () @trusted { return _open_osfhandle(cast(intptr_t)writeHandle, O_APPEND); }();
		}
	}

	auto read = eventDriver.pipes.adopt(readFD);
	auto write = eventDriver.pipes.adopt(writeFD);
	return Pipe(PipeInputStream(read), PipeOutputStream(write));
}

/**
	Returned from `pipeProcess`.

	See_Also: `pipeProcess`, `pipeShell`
*/
struct ProcessPipes {
	Process process;
	PipeOutputStream stdin;
	PipeInputStream stdout;
	PipeInputStream stderr;
}

/**
	Equivalent to `std.process.pipeProcess`.

	Returns:
		A struct containing the process and created pipes.

	See_Also: `spawnProcess`, `execute`
*/
ProcessPipes pipeProcess(
	scope string[] args,
	Redirect redirect = Redirect.all,
	const string[string] env = null,
	Config config = Config.none,
	scope NativePath workDir = NativePath.init)
@trusted {
	auto stdin = ProcessStdinFile(ProcessRedirect.inherit);
	if (Redirect.stdin & redirect) {
		stdin = ProcessStdinFile(ProcessRedirect.pipe);
	}

	auto stdout = ProcessStdoutFile(ProcessRedirect.inherit);
	if (Redirect.stdoutToStderr & redirect) {
		stdout = ProcessStdoutFile(ProcessStdoutRedirect.toStderr);
	} else if (Redirect.stdout & redirect) {
		stdout = ProcessStdoutFile(ProcessRedirect.pipe);
	}

	auto stderr = ProcessStderrFile(ProcessRedirect.inherit);
	if (Redirect.stderrToStdout & redirect) {
		stderr = ProcessStderrFile(ProcessStderrRedirect.toStdout);
	} else if (Redirect.stderr & redirect) {
		stderr = ProcessStderrFile(ProcessRedirect.pipe);
	}

	auto process = eventDriver.processes.spawn(
		args,
		stdin,
		stdout,
		stderr,
		env,
		config,
		workDir.toNativeString());

	if (process.pid == ProcessID.invalid)
		throw new Exception("Failed to spawn process");

	return ProcessPipes(
		Process(process.pid),
		PipeOutputStream(cast(PipeFD)process.stdin),
		PipeInputStream(cast(PipeFD)process.stdout),
		PipeInputStream(cast(PipeFD)process.stderr)
	);
}

/// ditto
ProcessPipes pipeProcess(
	scope string program,
	Redirect redirect = Redirect.all,
	const string[string] env = null,
	Config config = Config.none,
	scope NativePath workDir = NativePath.init)
{
	return pipeProcess(
		[program],
		redirect,
		env,
		config,
		workDir
	);
}

/// ditto
ProcessPipes pipeShell(
	scope string command,
	Redirect redirect = Redirect.all,
	const string[string] env = null,
	Config config = Config.none,
	scope NativePath workDir = NativePath.init,
	scope NativePath shellPath = nativeShell)
{
	return pipeProcess(
		shellCommand(command, nativeShell),
		redirect,
		env,
		config,
		workDir);
}

/**
	Equivalent to `std.process.execute`.

	Returns:
		Tuple containing the exit status and process output.

	See_Also: `spawnProcess`, `pipeProcess`
*/
auto execute(
	scope string[] args,
	const string[string] env = null,
	Config config = Config.none,
	size_t maxOutput = size_t.max,
	scope NativePath workDir = NativePath.init)
@blocking {
	return executeImpl!pipeProcess(args, env, config, maxOutput, workDir);
}

/// ditto
auto execute(
	scope string program,
	const string[string] env = null,
	Config config = Config.none,
	size_t maxOutput = size_t.max,
	scope NativePath workDir = NativePath.init)
@blocking @trusted {
	return executeImpl!pipeProcess(program, env, config, maxOutput, workDir);
}

/// ditto
auto executeShell(
	scope string command,
	const string[string] env = null,
	Config config = Config.none,
	size_t maxOutput = size_t.max,
	scope NativePath workDir = null,
	NativePath shellPath = nativeShell)
@blocking {
	return executeImpl!pipeShell(command, env, config, maxOutput, workDir, shellPath);
}

private auto executeImpl(alias spawn, Cmd, Args...)(
	Cmd command,
	const string[string] env,
	Config config,
	size_t maxOutput,
	scope NativePath workDir,
	Args args)
@blocking {
	Redirect redirect = Redirect.stdout;

	auto processPipes = spawn(command, redirect, env, config, workDir, args);

	auto stringOutput = processPipes.stdout.collectOutput(maxOutput);

	return Tuple!(int, "status", string, "output")(processPipes.process.wait(), stringOutput);
}

/*
	Collect the string output of a stream in a blocking fashion.

	Params:
		stream = The input stream to collect from.
		nbytes = The maximum number of bytes to collect.

	Returns:
		The collected data from the stream as a string.
*/
/// private
string collectOutput(InputStream)(InputStream stream, size_t nbytes = size_t.max)
@blocking @trusted if (isInputStream!InputStream) {
	auto output = appender!string();
	if (nbytes != size_t.max) {
		output.reserve(nbytes);
	}

	import vibe.internal.allocator : theAllocator, dispose;

	scope buffer = cast(ubyte[]) theAllocator.allocate(64*1024);
	scope (exit) theAllocator.dispose(buffer);

	while (!stream.empty && nbytes > 0) {
		size_t chunk = min(nbytes, stream.leastSize, buffer.length);
		assert(chunk > 0, "leastSize returned zero for non-empty stream.");

		stream.read(buffer[0..chunk]);
		output.put(buffer[0..chunk]);
	}

	return output.data;
}
