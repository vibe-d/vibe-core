/**
	Central logging facility for vibe.

	Copyright: © 2012-2014 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.log;

import vibe.core.args;
import vibe.core.concurrency : ScopedLock, lock, isWeaklyIsolated;
import vibe.core.sync;

import std.algorithm;
import std.array;
import std.datetime;
import std.format;
import std.stdio;
import core.atomic;
import core.thread;

import std.traits : isSomeString;
import std.range.primitives : isInputRange, isOutputRange;

// support string interpolation on modern compiler versions
static if (__VERSION__ >= 2108) import core.interpolation;
else private struct InterpolationHeader;


/**
	Sets the minimum log level to be printed using the default console logger.

	This level applies to the default stdout/stderr logger only.
*/
void setLogLevel(LogLevel level)
@safe nothrow {
	if (ss_stdoutLogger)
		ss_stdoutLogger.lock().minLevel = level;
}

/// Gets the minimum log level used for stdout/stderr logging.
LogLevel getLogLevel()
@safe nothrow {
	return ss_stdoutLogger ? ss_stdoutLogger.lock().minLevel : LogLevel.none;
}


/**
	Sets the log format used for the default console logger.

	This level applies to the default stdout/stderr logger only.

	Params:
		fmt = The log format for the stderr (default is `FileLogger.Format.thread`)
		infoFmt = The log format for the stdout (default is `FileLogger.Format.plain`)
*/
void setLogFormat(FileLogger.Format fmt, FileLogger.Format infoFmt = FileLogger.Format.plain)
nothrow @safe {
	if (ss_stdoutLogger) {
		auto l = ss_stdoutLogger.lock();
		l.format = fmt;
		l.infoFormat = infoFmt;
	}
}


/**
	Sets a log file for disk file logging.

	Multiple calls to this function will register multiple log
	files for output.
*/
void setLogFile(string filename, LogLevel min_level = LogLevel.error)
{
	auto logger = cast(shared)new FileLogger(filename);
	{
		auto l = logger.lock();
		l.minLevel = min_level;
		l.format = FileLogger.Format.threadTime;
	}
	registerLogger(logger);
}


/**
	Registers a new logger instance.

	The specified Logger will receive all log messages in its Logger.log
	method after it has been registered.

	Examples:
	---
	auto logger = cast(shared)new HTMLLogger("log.html");
	logger.lock().format = FileLogger.Format.threadTime;
	registerLogger(logger);
	---

	See_Also: deregisterLogger
*/
void registerLogger(shared(Logger) logger)
nothrow {
	ss_loggers ~= logger;
}


/**
	Deregisters an active logger instance.

	See_Also: registerLogger
*/
void deregisterLogger(shared(Logger) logger)
nothrow {
	for (size_t i = 0; i < ss_loggers.length; ) {
		if (ss_loggers[i] !is logger) i++;
		else ss_loggers = ss_loggers[0 .. i] ~ ss_loggers[i+1 .. $];
	}
}


/**
	Logs a message.

	Params:
		level = The log level for the logged message
		fmt = See http://dlang.org/phobos/std_format.html#format-string
		args = Any input values needed for formatting
*/
void log(LogLevel level, S, T...)(S fmt, lazy T args, string mod = __MODULE__,
	string func = __FUNCTION__, string file = __FILE__, int line = __LINE__,)
	nothrow if ((isSomeString!S || is(S == InterpolationHeader)) && level != LogLevel.none)
{
	doLog(level, mod, func, file, line, fmt, args);
}

/// ditto
void logTrace(S, T...)(S fmt, lazy T args, string mod = __MODULE__,
	string func = __FUNCTION__, string file = __FILE__, int line = __LINE__,)
	nothrow if (isSomeString!S || is(S == InterpolationHeader))
{
	doLog(LogLevel.trace, mod, func, file, line, fmt, args);
}

/// ditto
void logDebugV(S, T...)(S fmt, lazy T args, string mod = __MODULE__,
	string func = __FUNCTION__, string file = __FILE__, int line = __LINE__,)
	nothrow if (isSomeString!S || is(S == InterpolationHeader))
{
	doLog(LogLevel.debugV, mod, func, file, line, fmt, args);
}

/// ditto
void logDebug(S, T...)(S fmt, lazy T args, string mod = __MODULE__,
	string func = __FUNCTION__, string file = __FILE__, int line = __LINE__,)
	nothrow if (isSomeString!S || is(S == InterpolationHeader))
{
	doLog(LogLevel.debug_, mod, func, file, line, fmt, args);
}

/// ditto
void logDiagnostic(S, T...)(S fmt, lazy T args, string mod = __MODULE__,
	string func = __FUNCTION__, string file = __FILE__, int line = __LINE__,)
	nothrow if (isSomeString!S || is(S == InterpolationHeader))
{
	doLog(LogLevel.diagnostic, mod, func, file, line, fmt, args);
}

/// ditto
void logInfo(S, T...)(S fmt, lazy T args, string mod = __MODULE__,
	string func = __FUNCTION__, string file = __FILE__, int line = __LINE__,)
	nothrow if (isSomeString!S || is(S == InterpolationHeader))
{
	doLog(LogLevel.info, mod, func, file, line, fmt, args);
}

/// ditto
void logWarn(S, T...)(S fmt, lazy T args, string mod = __MODULE__,
	string func = __FUNCTION__, string file = __FILE__, int line = __LINE__,)
	nothrow if (isSomeString!S || is(S == InterpolationHeader))
{
	doLog(LogLevel.warn, mod, func, file, line, fmt, args);
}

/// ditto
void logError(S, T...)(S fmt, lazy T args, string mod = __MODULE__,
	string func = __FUNCTION__, string file = __FILE__, int line = __LINE__,)
	nothrow if (isSomeString!S || is(S == InterpolationHeader))
{
	doLog(LogLevel.error, mod, func, file, line, fmt, args);
}

/// ditto
void logCritical(S, T...)(S fmt, lazy T args, string mod = __MODULE__,
	string func = __FUNCTION__, string file = __FILE__, int line = __LINE__,)
	nothrow if (isSomeString!S || is(S == InterpolationHeader))
{
	doLog(LogLevel.critical, mod, func, file, line, fmt, args);
}

/// ditto
void logFatal(S, T...)(S fmt, lazy T args, string mod = __MODULE__,
	string func = __FUNCTION__, string file = __FILE__, int line = __LINE__,)
	nothrow if (isSomeString!S || is(S == InterpolationHeader))
{
	doLog(LogLevel.fatal, mod, func, file, line, fmt, args);
}

///
@safe unittest {
	void test() nothrow
	{
		logInfo("Hello, World!");
		logWarn("This may not be %s.", "good");
		log!(LogLevel.info)("This is a %s.", "test");

		// NOTE: interpolated strings are available starting with DMD 2.108.0
		static if (__VERSION__ >= 2108) mixin(q{
			logInfo(i"Answer: $(2*21)");
		});
	}
}


/** Logs an exception, including a debug stack trace.
*/
void logException(LogLevel level = LogLevel.error)(Throwable exception,
	string error_description, string mod = __MODULE__, string func = __FUNCTION__,
	string file = __FILE__, int line = __LINE__)
@safe nothrow {
	doLog(level, mod, func, file, line, "%s: %s", error_description, exception.msg);
	try () @trusted {
		auto diaglvl = min(level, LogLevel.diagnostic);
		doLog(diaglvl, mod, func, file, line, "%s", exception);
	} ();
	catch (Exception e) logDiagnostic("Failed to print full exception: %s", e.msg);
}

///
unittest {
	void test() nothrow
	{
		try {
			throw new Exception("Something failed!");
		} catch (Exception e) {
			logException(e, "Failed to carry out some operation");
		}
	}
}


/// Specifies the log level for a particular log message.
enum LogLevel {
	trace,      /// Developer information for locating events when no useful stack traces are available
	debugV,     /// Developer information useful for algorithm debugging - for verbose output
	debug_,     /// Developer information useful for algorithm debugging
	diagnostic, /// Extended user information (e.g. for more detailed error information)
	info,       /// Informational message for normal user education
	warn,       /// Unexpected condition that could indicate an error but has no direct consequences
	error,      /// Normal error that is handled gracefully
	critical,   /// Error that severely influences the execution of the application
	fatal,      /// Error that forces the application to terminate
	none,       /// Special value used to indicate no logging when set as the minimum log level

	verbose1 = diagnostic, /// Alias for diagnostic messages
	verbose2 = debug_,     /// Alias for debug messages
	verbose3 = debugV,     /// Alias for verbose debug messages
	verbose4 = trace,      /// Alias for trace messages
}

/// Represents a single logged line
struct LogLine {
	string mod;
	string func;
	string file;
	int line;
	LogLevel level;
	Thread thread;
	string threadName;
	uint threadID;
	Fiber fiber;
	uint fiberID;
	SysTime time;
	string text; /// Legacy field used in `Logger.log`
}

/** Abstract base class for all loggers

	Concurrency_requirements:

	Classes derived from `Logger` must be implemented in a thread-safe way.
	Although the methods of `Logger` are not annotated with `shared` due to
	historic reasons, they should be treated as if they were.

	Also, none of the methods must, explicitly or implicitly, yield
	execution (e.g. by calling `vibe.core.yield` or performing vibe.d based
	I/O or wait operations). In cases where a logger needs to perform
	blocking I/O that may degrade performance of the calling thread, for
	example by sending over the network, a separate writer thread should be
	used in conjunction with a queue. The synchronization of this queue must
	use classical synchronization primitives, such as `core.sync.Mutex`,
	instead of the ones in `vibe.core.sync`. See `SyslogLogger` for an
	example of such an implementation.
*/
class Logger {
	LogLevel minLevel = LogLevel.min;

	/** Whether the logger can handle multiple lines in a single beginLine/endLine.

	   By default log text with newlines gets split into multiple log lines.
	 */
	protected bool multilineLogger = false;

	private {
		LogLine m_curLine;
		Appender!string m_curLineText;
	}

	final bool acceptsLevel(LogLevel value) nothrow pure @safe { return value >= this.minLevel; }

	/** Legacy logging interface relying on dynamic memory allocation.

		Override `beginLine`, `put`, `endLine` instead for a more efficient and
		possibly allocation-free implementation.
	*/
	void log(ref LogLine line) @safe {}

	/// Starts a new log line.
	void beginLine(ref LogLine line_info)
	@safe {
		m_curLine = line_info;
		m_curLineText = appender!string();
	}

	/// Writes part of a log line message.
	void put(scope const(char)[] text)
	@safe {
		m_curLineText.put(text);
	}

	/// Finalizes a log line.
	void endLine()
	@safe {
		m_curLine.text = m_curLineText.data;
		log(m_curLine);
		m_curLine.text = null;
		m_curLineText = Appender!string.init;
	}
}


/**
	Plain-text based logger for logging to regular files or stdout/stderr
*/
final class FileLogger : Logger {
	/// The log format used by the FileLogger
	enum Format {
		plain,      /// Output only the plain log message
		thread,     /// Prefix "[thread-id:fiber-id loglevel]"
		threadTime  /// Prefix "[thread-id:fiber-id timestamp loglevel]"
	}

	private {
		File m_infoFile;
		File m_diagFile;
		File m_curFile;
	}

	Format format = Format.thread;
	Format infoFormat = Format.thread;

	/** Use escape sequences to color log output.

		Note that the terminal must support 256-bit color codes.
	*/
	bool useColors = false;

	this(File info_file, File diag_file)
	{
		m_infoFile = info_file;
		m_diagFile = diag_file;
	}

	this(string filename)
	{
		auto f = File(filename, "ab");
		this(f, f);
	}

	override void beginLine(ref LogLine msg)
		@trusted // FILE isn't @safe (as of DMD 2.065)
	{
		string pref;
		final switch (msg.level) {
			case LogLevel.trace: pref = "trc"; m_curFile = m_diagFile; break;
			case LogLevel.debugV: pref = "dbv"; m_curFile = m_diagFile; break;
			case LogLevel.debug_: pref = "dbg"; m_curFile = m_diagFile; break;
			case LogLevel.diagnostic: pref = "dia"; m_curFile = m_diagFile; break;
			case LogLevel.info: pref = "INF"; m_curFile = m_infoFile; break;
			case LogLevel.warn: pref = "WRN"; m_curFile = m_diagFile; break;
			case LogLevel.error: pref = "ERR"; m_curFile = m_diagFile; break;
			case LogLevel.critical: pref = "CRITICAL"; m_curFile = m_diagFile; break;
			case LogLevel.fatal: pref = "FATAL"; m_curFile = m_diagFile; break;
			case LogLevel.none: assert(false);
		}

		auto fmt = (m_curFile is m_diagFile) ? this.format : this.infoFormat;

		auto dst = m_curFile.lockingTextWriter;

		if (this.useColors) {
			version (Posix) {
				final switch (msg.level) {
					case LogLevel.trace: dst.put("\x1b[49;38;5;243m"); break;
					case LogLevel.debugV: dst.put("\x1b[49;38;5;245m"); break;
					case LogLevel.debug_: dst.put("\x1b[49;38;5;180m"); break;
					case LogLevel.diagnostic: dst.put("\x1b[49;38;5;143m"); break;
					case LogLevel.info: dst.put("\x1b[49;38;5;29m"); break;
					case LogLevel.warn: dst.put("\x1b[49;38;5;220m"); break;
					case LogLevel.error: dst.put("\x1b[49;38;5;9m"); break;
					case LogLevel.critical: dst.put("\x1b[41;38;5;15m"); break;
					case LogLevel.fatal: dst.put("\x1b[48;5;9;30m"); break;
					case LogLevel.none: assert(false);
				}
			}
		}

		final switch (fmt) {
			case Format.plain: break;
			case Format.thread:
				dst.put('[');
				if (msg.threadName.length) dst.put(msg.threadName);
				else dst.formattedWrite("%08X", msg.threadID);
				dst.put('(');
				import vibe.core.task : Task;
				Task.getThis().getDebugID(dst);
				dst.formattedWrite(") %s] ", pref);
				break;
			case Format.threadTime:
				dst.put('[');
				auto tm = msg.time;
				auto msecs = tm.fracSecs.total!"msecs";
				m_curFile.writef("%d-%02d-%02d %02d:%02d:%02d.%03d ", tm.year, tm.month, tm.day, tm.hour, tm.minute, tm.second, msecs);

				if (msg.threadName.length) dst.put(msg.threadName);
				else dst.formattedWrite("%08X", msg.threadID);
				dst.put('(');
				import vibe.core.task : Task;
				Task.getThis().getDebugID(dst);
				dst.formattedWrite(") %s] ", pref);
				break;
		}
	}

	override void put(scope const(char)[] text)
	{
		// NOTE: (DMD 2.101.2) File.write parameters are not annotated scope
		m_curFile.write(() @trusted { return text; } ());
	}

	override void endLine()
	{
		if (useColors) {
			version (Posix) {
				m_curFile.write("\x1b[0m");
			}
		}

		m_curFile.writeln();
		m_curFile.flush();
	}
}

/**
	Logger implementation for logging to an HTML file with dynamic filtering support.
*/
final class HTMLLogger : Logger {
	private {
		File m_logFile;
	}

	this(string filename = "log.html")
	{
		m_logFile = File(filename, "wt");
		writeHeader();
	}

	~this()
	{
		//version(FinalizerDebug) writeln("HtmlLogWritet.~this");
		writeFooter();
		m_logFile.close();
		//version(FinalizerDebug) writeln("HtmlLogWritet.~this out");
	}

	@property void minLogLevel(LogLevel value) pure nothrow @safe { this.minLevel = value; }

	override void beginLine(ref LogLine msg)
		@trusted // FILE isn't @safe (as of DMD 2.065)
	{
		if( !m_logFile.isOpen ) return;

		final switch (msg.level) {
			case LogLevel.none: assert(false);
			case LogLevel.trace: m_logFile.write(`<div class="trace">`); break;
			case LogLevel.debugV: m_logFile.write(`<div class="debugv">`); break;
			case LogLevel.debug_: m_logFile.write(`<div class="debug">`); break;
			case LogLevel.diagnostic: m_logFile.write(`<div class="diagnostic">`); break;
			case LogLevel.info: m_logFile.write(`<div class="info">`); break;
			case LogLevel.warn: m_logFile.write(`<div class="warn">`); break;
			case LogLevel.error: m_logFile.write(`<div class="error">`); break;
			case LogLevel.critical: m_logFile.write(`<div class="critical">`); break;
			case LogLevel.fatal: m_logFile.write(`<div class="fatal">`); break;
		}
		m_logFile.writef(`<div class="timeStamp">%s</div>`, msg.time.toISOExtString());
		if (msg.thread)
			m_logFile.writef(`<div class="threadName">%s</div>`, msg.thread.name);
		if (msg.fiber)
			m_logFile.writef(`<div class="taskID">%s</div>`, msg.fiberID);
		m_logFile.write(`<div class="message">`);
	}

	override void put(scope const(char)[] text)
	{
		auto dst = () @trusted { return m_logFile.lockingTextWriter(); } (); // LockingTextWriter not @safe for DMD 2.066
		while (!text.empty && (text.front == ' ' || text.front == '\t')) {
			foreach (i; 0 .. text.front == ' ' ? 1 : 4)
				() @trusted { dst.put("&nbsp;"); } (); // LockingTextWriter not @safe for DMD 2.066
			text.popFront();
		}
		() @trusted { filterHTMLEscape(dst, text); } (); // LockingTextWriter not @safe for DMD 2.066
	}

	override void endLine()
	{
		() @trusted { // not @safe for DMD 2.066
			m_logFile.write(`</div>`);
			m_logFile.writeln(`</div>`);
		} ();
		m_logFile.flush();
	}

	private void writeHeader(){
		if( !m_logFile.isOpen ) return;

		m_logFile.writeln(
`<html>
<head>
	<title>HTML Log</title>
	<style content="text/css">
		.trace { position: relative; color: #E0E0E0; font-size: 9pt; }
		.debugv { position: relative; color: #E0E0E0; font-size: 9pt; }
		.debug { position: relative; color: #808080; }
		.diagnostic { position: relative; color: #808080; }
		.info { position: relative; color: black; }
		.warn { position: relative; color: #E08000; }
		.error { position: relative; color: red; }
		.critical { position: relative; color: red; background-color: black; }
		.fatal { position: relative; color: red; background-color: black; }

		.log { margin-left: 10pt; }
		.code {
			font-family: "Courier New";
			background-color: #F0F0F0;
			border: 1px solid gray;
			margin-bottom: 10pt;
			margin-left: 30pt;
			margin-right: 10pt;
			padding-left: 0pt;
		}

		div.timeStamp {
			position: absolute;
			width: 150pt;
		}
		div.threadName {
			position: absolute;
			top: 0pt;
			left: 150pt;
			width: 100pt;
		}
		div.taskID {
			position: absolute;
			top: 0pt;
			left: 250pt;
			width: 70pt;
		}
		div.message {
			position: relative;
			top: 0pt;
			left: 320pt;
		}
		body {
			font-family: Tahoma, Arial, sans-serif;
			font-size: 10pt;
		}
	</style>
	<script language="JavaScript">
		function enableStyle(i){
			var style = document.styleSheets[0].cssRules[i].style;
			style.display = "block";
		}

		function disableStyle(i){
			var style = document.styleSheets[0].cssRules[i].style;
			style.display = "none";
		}

		function updateLevels(){
			var sel = document.getElementById("Level");
			var level = sel.value;
			for( i = 0; i < level; i++ ) disableStyle(i);
			for( i = level; i < 5; i++ ) enableStyle(i);
		}
	</script>
</head>
<body style="padding: 0px; margin: 0px;" onLoad="updateLevels(); updateCode();">
	<div style="position: fixed; z-index: 100; padding: 4pt; width:100%; background-color: lightgray; border-bottom: 1px solid black;">
		<form style="margin: 0px;">
			Minimum Log Level:
			<select id="Level" onChange="updateLevels()">
				<option value="0">Trace</option>
				<option value="1">Verbose</option>
				<option value="2">Debug</option>
				<option value="3">Diagnostic</option>
				<option value="4">Info</option>
				<option value="5">Warn</option>
				<option value="6">Error</option>
				<option value="7">Critical</option>
				<option value="8">Fatal</option>
			</select>
		</form>
	</div>
	<div style="height: 30pt;"></div>
	<div class="log">`);
		m_logFile.flush();
	}

	private void writeFooter(){
		if( !m_logFile.isOpen ) return;

		m_logFile.writeln(
`	</div>
</body>
</html>`);
		m_logFile.flush();
	}

	private static void filterHTMLEscape(R, S)(ref R dst, S str)
	{
		for (;!str.empty;str.popFront()) {
			auto ch = str.front;
			switch (ch) {
				default: dst.put(ch); break;
				case '<': dst.put("&lt;"); break;
				case '>': dst.put("&gt;"); break;
				case '&': dst.put("&amp;"); break;
			}
		}
	}
}


/**
	Construct a SyslogLogger.

	The log messages are sent to the given OutputStream stream using the given
	Facility facility.Optionally the appName and hostName can be set. The
	appName defaults to null. The hostName defaults to hostName().

	Note that the passed stream's write function must not use logging with
	a level for that this Logger's acceptsLevel returns true. Because this
	Logger uses the stream's write function when it logs and would hence
	log forevermore.
*/
shared(SyslogLogger!StreamCallback) createSyslogLogger(StreamCallback)(StreamCallback stream_callback,
	SyslogFacility facility, string app_name = null, string host_name = hostName())
	if (isWeaklyIsolated!StreamCallback)
{
	return cast(shared)new SyslogLogger!StreamCallback(stream_callback, facility, app_name, host_name);
}

/**
	A logger that logs in syslog format according to RFC 5424.

	Messages can be logged to files (via file streams) or over the network (via
	TCP or SSL streams).

	Params:
		StreamCallback = Callable that takes no arguments and returns an
			`OutputStream` of some kind that will be used to write the log
			output in Syslog format.

	Known_issues:
		The current implementation does not write individual lines atomically.
		Thus, when logging from multiple tasks or threads concurrently, log
		lines may get mixed up.

	Standards: Conforms to RFC 5424.
*/
final class SyslogLogger(StreamCallback) : Logger
	if (isWeaklyIsolated!StreamCallback)
{
	import std.conv : hexString;
	import core.sync.condition : Condition;
	import core.sync.mutex : Mutex;
	import vibe.container.ringbuffer : RingBuffer;

	private {
		string m_hostName;
		string m_appName;
		SyslogFacility m_facility;
		Thread m_writeThread;
		StreamCallback m_streamCallback;
		Mutex m_bufferMutex;
		Condition m_bufferCondition;
		RingBuffer!ubyte m_buffer;
	}

	deprecated("Use `SyslogFacility` instead.")
	alias Facility = SyslogFacility;

	/// Severities
	private enum Severity {
		emergency,   /// system is unusable
		alert,       /// action must be taken immediately
		critical,    /// critical conditions
		error,       /// error conditions
		warning,     /// warning conditions
		notice,      /// normal but significant condition
		info,        /// informational messages
		debug_,      /// debug-level messages
	}

	/// syslog message format (version 1)
	/// see section 6 in RFC 5424
	private enum SYSLOG_MESSAGE_FORMAT_VERSION1 = "<%.3s>1 %s %.255s %.48s %.128s %.32s %s %s";
	///
	private enum NILVALUE = "-";
	///
	private enum BOM = hexString!"EFBBBF";

	private this(StreamCallback stream_callback, SyslogFacility facility, string appName = null, string hostName = hostName())
	{
		m_hostName = hostName != "" ? hostName : NILVALUE;
		m_appName = appName != "" ? appName : NILVALUE;
		m_facility = facility;
		m_streamCallback = stream_callback;
		this.minLevel = LogLevel.debug_;

		m_buffer.capacity = 1024;
		m_bufferMutex = new Mutex;
		m_bufferCondition = new Condition(m_bufferMutex);

		m_writeThread = new Thread(&writeThreadFunc);
		m_writeThread.start();
	}

	void dispose()
	shared {
		auto thisus = cast()this;

		{
			auto l = scopedMutexLock(m_bufferMutex);
			while (!thisus.m_buffer.empty) thisus.m_bufferCondition.wait();
			thisus.m_buffer.capacity = 0;
		}
		thisus.m_bufferCondition.notifyAll();
		thisus.m_writeThread.join();
	}

	/**
		Logs the given LogLine msg.

		It uses the msg's time, level, and text field.
	*/
	override void beginLine(ref LogLine msg)
	@trusted { // OutputStream isn't @safe
		auto tm = msg.time;
		import core.time;
		// at most 6 digits for fractional seconds according to RFC
		static if (is(typeof(tm.fracSecs))) tm.fracSecs = tm.fracSecs.total!"usecs".dur!"usecs";
		else tm.fracSec = FracSec.from!"usecs"(tm.fracSec.usecs);
		auto timestamp = tm.toISOExtString();

		Severity syslogSeverity;
		// map LogLevel to syslog's severity
		final switch(msg.level) {
			case LogLevel.none: assert(false);
			case LogLevel.trace: return;
			case LogLevel.debugV: return;
			case LogLevel.debug_: syslogSeverity = Severity.debug_; break;
			case LogLevel.diagnostic: syslogSeverity = Severity.info; break;
			case LogLevel.info: syslogSeverity = Severity.notice; break;
			case LogLevel.warn: syslogSeverity = Severity.warning; break;
			case LogLevel.error: syslogSeverity = Severity.error; break;
			case LogLevel.critical: syslogSeverity = Severity.critical; break;
			case LogLevel.fatal: syslogSeverity = Severity.alert; break;
		}

		assert(msg.level >= LogLevel.debug_);
		import std.conv : to; // temporary workaround for issue 1016 (DMD cross-module template overloads error out before second attempted module)
		auto priVal = m_facility * 8 + syslogSeverity;

		alias procId = NILVALUE;
		alias msgId = NILVALUE;
		alias structuredData = NILVALUE;

		auto text = msg.text;
		import std.format : formattedWrite;
		auto str = BufferOutputRange(this);
		str.formattedWrite(SYSLOG_MESSAGE_FORMAT_VERSION1, priVal,
			timestamp, m_hostName, BOM ~ m_appName, procId, msgId,
			structuredData, BOM);
	}

	override void put(scope const(char)[] text)
	@trusted {
		writeToBuffer(cast(const(ubyte)[])text);
	}

	override void endLine()
	@trusted {
		writeToBuffer(cast(const(ubyte)[])"\n");
	}

	private void writeToBuffer(scope const(ubyte)[] bts)
	@safe {
		while (bts.length > 0) {
			bool was_empty;
			{
				auto l = scopedMutexLock(m_bufferMutex);
				while (m_buffer.full) {
					if (m_buffer.capacity == 0) return; // write thread failed
					() @trusted { m_bufferCondition.wait(); } ();
				}
				was_empty = m_buffer.empty;
				auto chunk = min(bts.length, m_buffer.freeSpace);
				m_buffer.putBack(bts[0 .. chunk]);
				bts = bts[chunk .. $];
			}
			if (was_empty) () @trusted { m_bufferCondition.notifyAll(); } ();
		}
	}

	private void writeThreadFunc()
	@safe nothrow {
		ubyte[4096] buf;

		try {
			auto ostr = m_streamCallback();

			while (true) {
				size_t chunk;
				bool was_full, is_empty;

				{
					auto l = scopedMutexLock(m_bufferMutex);
					while (m_buffer.empty) {
						if (m_buffer.capacity == 0) {
							ostr.finalize();
							static if (is(typeof(ostr.close())))
								ostr.close();
							return;
						}
						() @trusted { m_bufferCondition.wait(); } ();
					}
					chunk = min(buf.length, m_buffer.length);
					was_full = m_buffer.full;
					m_buffer.read(buf[0 .. chunk]);
					is_empty = m_buffer.empty;
				}

				if (was_full || is_empty) () @trusted { m_bufferCondition.notifyAll(); } ();

				ostr.write(buf[0 .. chunk]);
			}
		} catch (Exception e) {
			logException(e, "SyslogLogger failed to write output");
			auto l = scopedMutexLock(m_bufferMutex);
			m_buffer.capacity = 0;
			try () @trusted { m_bufferCondition.notifyAll(); } ();
			catch (Exception e2) assert(false, e2.msg);
		}
	}

	private static struct BufferOutputRange
	{
		private {
			SyslogLogger m_logger;
		}

		@safe:

		this(SyslogLogger logger) { m_logger = logger; }

		void put(char bt)
		{
			ubyte[1] bts;
			bts[0] = bt;
			m_logger.writeToBuffer(bts[]);
		}

		void put(const(char)[] bts)
		{
			m_logger.writeToBuffer(cast(const(ubyte)[])bts);
		}
	}
}

/// Syslog facilities
enum SyslogFacility {
	kern,        /// kernel messages
	user,        /// user-level messages
	mail,        /// mail system
	daemon,      /// system daemons
	auth,        /// security/authorization messages
	syslog,      /// messages generated internally by syslogd
	lpr,         /// line printer subsystem
	news,        /// network news subsystem
	uucp,        /// UUCP subsystem
	clockDaemon, /// clock daemon
	authpriv,    /// security/authorization messages
	ftp,         /// FTP daemon
	ntp,         /// NTP subsystem
	logAudit,    /// log audit
	logAlert,    /// log alert
	cron,        /// clock daemon
	local0,      /// local use 0
	local1,      /// local use 1
	local2,      /// local use 2
	local3,      /// local use 3
	local4,      /// local use 4
	local5,      /// local use 5
	local6,      /// local use 6
	local7,      /// local use 7
}

unittest
{
	import vibe.core.file;
	align(16) static __gshared string gpath;
	static FileStream createOutput() @trusted {
		auto fstream = createTempFile();
		atomicStore(gpath, fstream.path.toString());
		return fstream;
	}
	auto logger = createSyslogLogger(&createOutput, SyslogFacility.local1, "appname", null);
	LogLine msg;
	import std.datetime;
	import core.thread;
	static if (is(typeof(SysTime.init.fracSecs))) auto fs = 1.dur!"usecs";
	else auto fs = FracSec.from!"usecs"(1);
	msg.time = SysTime(DateTime(0, 1, 1, 0, 0, 0), fs);

	foreach (lvl; [LogLevel.debug_, LogLevel.diagnostic, LogLevel.info, LogLevel.warn, LogLevel.error, LogLevel.critical, LogLevel.fatal]) {
		msg.level = lvl;
		(cast()logger).beginLine(msg);
		(cast()logger).put("αβγ");
		(cast()logger).endLine();
	}
	logger.dispose();
	auto path = atomicLoad(gpath);

	import std.file;
	import std.string;
	auto txt = readText(path);
	auto lines = splitLines(txt, KeepTerminator.yes);
	alias BOM = logger.BOM;
	assert(lines.length == 7);
	assert(lines[0] == "<143>1 0000-01-01T00:00:00.000001 - " ~ BOM ~ "appname - - - " ~ BOM ~ "αβγ\n");
	assert(lines[1] == "<142>1 0000-01-01T00:00:00.000001 - " ~ BOM ~ "appname - - - " ~ BOM ~ "αβγ\n");
	assert(lines[2] == "<141>1 0000-01-01T00:00:00.000001 - " ~ BOM ~ "appname - - - " ~ BOM ~ "αβγ\n");
	assert(lines[3] == "<140>1 0000-01-01T00:00:00.000001 - " ~ BOM ~ "appname - - - " ~ BOM ~ "αβγ\n");
	assert(lines[4] == "<139>1 0000-01-01T00:00:00.000001 - " ~ BOM ~ "appname - - - " ~ BOM ~ "αβγ\n");
	assert(lines[5] == "<138>1 0000-01-01T00:00:00.000001 - " ~ BOM ~ "appname - - - " ~ BOM ~ "αβγ\n");
	assert(lines[6] == "<137>1 0000-01-01T00:00:00.000001 - " ~ BOM ~ "appname - - - " ~ BOM ~ "αβγ\n");
	removeFile(path);
}


/// Returns: this host's host name.
///
/// If the host name cannot be determined the function returns null.
private string hostName()
{
	import std.conv : to;

	string hostName;

	version (Posix) {
		import core.sys.posix.sys.utsname : uname, utsname;
		utsname name;
		if (uname(&name)) return hostName;
		hostName = name.nodename.ptr.to!string;

		import std.socket;
		auto ih = new InternetHost;
		if (!ih.getHostByName(hostName)) return hostName;
		hostName = ih.name;
	}
	// TODO: determine proper host name on windows

	return hostName;
}

private {
	__gshared shared(Logger)[] ss_loggers;
	shared(FileLogger) ss_stdoutLogger;
}

/**
Returns a list of all registered loggers.
*/
shared(Logger)[] getLoggers() nothrow @trusted { return ss_loggers; }

package void initializeLogModule()
{
	version (Windows) {
		version (VibeWinrtDriver) enum disable_stdout = true;
		else {
			enum disable_stdout = false;
			if (!GetStdHandle(STD_OUTPUT_HANDLE) || !GetStdHandle(STD_ERROR_HANDLE)) return;
		}
	} else enum disable_stdout = false;

	static if (!disable_stdout) {
		auto stdoutlogger = new FileLogger(stdout, stderr);
		version (Posix) {
			import core.sys.posix.unistd : isatty;
			if (isatty(stdout.fileno))
				stdoutlogger.useColors = true;
		}
		stdoutlogger.minLevel = LogLevel.info;
		stdoutlogger.infoFormat = FileLogger.Format.plain;
		ss_stdoutLogger = cast(shared)stdoutlogger;

		registerLogger(ss_stdoutLogger);

		bool[4] verbose;
		version (VibeNoDefaultArgs) {}
		else {
			readOption("verbose|v"  , &verbose[0], "Enables diagnostic messages (verbosity level 1).");
			readOption("vverbose|vv", &verbose[1], "Enables debugging output (verbosity level 2).");
			readOption("vvv"        , &verbose[2], "Enables high frequency debugging output (verbosity level 3).");
			readOption("vvvv"       , &verbose[3], "Enables high frequency trace output (verbosity level 4).");
		}

		foreach_reverse (i, v; verbose)
			if (v) {
				setLogFormat(FileLogger.Format.thread);
				setLogLevel(cast(LogLevel)(LogLevel.diagnostic - i));
				break;
			}

		if (verbose[3]) setLogFormat(FileLogger.Format.threadTime, FileLogger.Format.threadTime);
	}
}

private void doLog(S, T...)(LogLevel level, string mod, string func, string file,
							int line, S fmt, lazy T args)
	nothrow
{
	try {
		static if(T.length != 0) {
			if (!getLoggers().any!(l => l.minLevel <= level))
				return;

			T args_copy = args;
		}

		FormatSpec!char fmtspec;

		foreach (l; getLoggers())
			if (l.minLevel <= level) { // WARNING: TYPE SYSTEM HOLE: accessing field of shared class!
				auto ll = l.lock();
				auto rng = LogOutputRange(ll, file, line, level);

				static if (is(S == InterpolationHeader))
					foreach (i, A; T) rng.formatValue(args_copy[i], fmtspec);
				else static if(T.length != 0)
					/*() @trusted {*/ rng.formattedWrite(fmt, args_copy); //} (); // formattedWrite is not @safe at least up to 2.068.0
				else
					rng.put(fmt);
				rng.finalize();
			}
	} catch(Exception e) debug assert(false, e.msg);
}

unittest { // ensure arguments are evaluated lazily
	int i = 0;
	setLogLevel(LogLevel.info);
	logDebug("not visible: %s", i++);
	assert(i == 0);
}

private struct LogOutputRange {
	import vibe.core.core : taskYieldLock;

	LogLine info;
	ScopedLock!Logger* logger;

	@safe:

	this(ref ScopedLock!Logger logger, string file, int line, LogLevel level)
	{
		auto l = taskYieldLock();

		() @trusted { this.logger = &logger; } ();
		try {
			() @trusted { this.info.time = Clock.currTime(UTC()); }(); // not @safe as of 2.065
			//this.info.mod = mod;
			//this.info.func = func;
			this.info.file = file;
			this.info.line = line;
			this.info.level = level;
			this.info.thread = () @trusted { return Thread.getThis(); }(); // not @safe as of 2.065
			this.info.threadID = makeid(this.info.thread);
			this.info.threadName = () @trusted { return this.info.thread ? this.info.thread.name : ""; } ();
			this.info.fiber = () @trusted { return Fiber.getThis(); }(); // not @safe as of 2.065
			this.info.fiberID = makeid(this.info.fiber);
		} catch (Exception e) {
			try {
				() @trusted { writefln("Error during logging: %s", e.toString()); }(); // not @safe as of 2.065
			} catch(Exception) {}
			assert(false, "Exception during logging: "~e.msg);
		}

		this.logger.beginLine(info);
	}

	void finalize()
	{
		auto l = taskYieldLock();

		logger.endLine();
	}

	void put(scope const(char)[] text)
	{
		if (text.empty)
			return;

		auto l = taskYieldLock();

		if (logger.multilineLogger) {
			logger.put(text);
		} else {
			auto rng = text.splitter('\n');
			// NOTE: (DMD 2.101.2) splitter() appears to return a range that has
			//       non-scope this parameters for all of its methods
			logger.put(() @trusted { return rng.front; } ());
			() @trusted { rng.popFront(); } ();
			while (!() @trusted { return rng.empty; } ()) {
				logger.endLine();
				logger.beginLine(info);
				logger.put(() @trusted { return rng.front; } ());
				() @trusted { rng.popFront(); } ();
			}
		}
	}

	void put(char ch) @trusted { put((&ch)[0 .. 1]); }

	void put(dchar ch)
	{
		static import std.utf;
		if (ch < 128) put(cast(char)ch);
		else {
			char[4] buf;
			auto len = std.utf.encode(buf, ch);
			put(buf[0 .. len]);
		}
	}

	private uint makeid(T)(T ptr) @trusted { return (cast(ulong)cast(void*)ptr & 0xFFFFFFFF) ^ (cast(ulong)cast(void*)ptr >> 32); }
}

private version (Windows) {
	import core.sys.windows.windows;
	enum STD_OUTPUT_HANDLE = cast(DWORD)-11;
	enum STD_ERROR_HANDLE = cast(DWORD)-12;
	extern(System) HANDLE GetStdHandle(DWORD nStdHandle);
}

unittest
{
	static class TestLogger : Logger
	{
		string[] lines;
		override void beginLine(ref LogLine msg) { lines.length += 1; }
		override void put(scope const(char)[] text) { lines[$-1] ~= text; }
		override void endLine() { }
	}
	auto logger = new TestLogger;
	auto ll = (cast(shared(Logger))logger).lock();
	auto rng = LogOutputRange(ll, __FILE__, __LINE__, LogLevel.info);
	rng.formattedWrite("text\nwith\nnewlines");
	rng.finalize();

	assert(logger.lines == ["text", "with", "newlines"]);
	logger.lines = null;
	logger.multilineLogger = true;

	rng = LogOutputRange(ll, __FILE__, __LINE__, LogLevel.info);
	rng.formattedWrite("text\nwith\nnewlines");
	rng.finalize();
	assert(logger.lines == ["text\nwith\nnewlines"]);
}

unittest { // make sure the default logger doesn't allocate/is usable within finalizers
	bool destroyed = false;

	class Test {
		~this()
		{
			logInfo("logInfo doesn't allocate.");
			destroyed = true;
		}
	}

	auto t = new Test;
	destroy(t);
	assert(destroyed);
}
