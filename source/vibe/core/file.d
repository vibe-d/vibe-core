/**
	File handling functions and types.

	Copyright: © 2012-2019 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.file;

import eventcore.core : NativeEventDriver, eventDriver;
import eventcore.driver;
import vibe.core.internal.release;
import vibe.core.log;
import vibe.core.path;
import vibe.core.stream;
import vibe.core.task : Task, TaskSettings;
import vibe.internal.async : asyncAwait, asyncAwaitUninterruptible;

import core.stdc.stdio;
import core.sys.posix.unistd;
import core.sys.posix.fcntl;
import core.sys.posix.sys.stat;
import core.time;
import std.conv : octal;
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.string;
import std.typecons : Flag, No;


version(Posix){
	private extern(C) int mkstemps(char* templ, int suffixlen);
}

@safe:


/**
	Opens a file stream with the specified mode.
*/
FileStream openFile(NativePath path, FileMode mode = FileMode.read)
{
	auto fil = eventDriver.files.open(path.toNativeString(), cast(FileOpenMode)mode);
	enforce(fil != FileFD.invalid, "Failed to open file '"~path.toNativeString~"'");
	return FileStream(fil, path, mode);
}
/// ditto
FileStream openFile(string path, FileMode mode = FileMode.read)
{
	return openFile(NativePath(path), mode);
}


/**
	Read a whole file into a buffer.

	If the supplied buffer is large enough, it will be used to store the
	contents of the file. Otherwise, a new buffer will be allocated.

	Params:
		path = The path of the file to read
		buffer = An optional buffer to use for storing the file contents
*/
ubyte[] readFile(NativePath path, ubyte[] buffer = null, size_t max_size = size_t.max)
{
	auto fil = openFile(path);
	scope (exit) fil.close();
	enforce(fil.size <= max_size, "File is too big.");
	auto sz = cast(size_t)fil.size;
	auto ret = sz <= buffer.length ? buffer[0 .. sz] : new ubyte[sz];
	fil.read(ret);
	return ret;
}
/// ditto
ubyte[] readFile(string path, ubyte[] buffer = null, size_t max_size = size_t.max)
{
	return readFile(NativePath(path), buffer, max_size);
}


/**
	Write a whole file at once.
*/
void writeFile(NativePath path, in ubyte[] contents)
{
	auto fil = openFile(path, FileMode.createTrunc);
	scope (exit) fil.close();
	fil.write(contents);
}
/// ditto
void writeFile(string path, in ubyte[] contents)
{
	writeFile(NativePath(path), contents);
}

/**
	Convenience function to append to a file.
*/
void appendToFile(NativePath path, string data) {
	auto fil = openFile(path, FileMode.append);
	scope(exit) fil.close();
	fil.write(data);
}
/// ditto
void appendToFile(string path, string data)
{
	appendToFile(NativePath(path), data);
}

/**
	Read a whole UTF-8 encoded file into a string.

	The resulting string will be sanitized and will have the
	optional byte order mark (BOM) removed.
*/
string readFileUTF8(NativePath path)
{
	import vibe.internal.string;

	auto data = readFile(path);
	auto idata = () @trusted { return data.assumeUnique; } ();
	return stripUTF8Bom(sanitizeUTF8(idata));
}
/// ditto
string readFileUTF8(string path)
{
	return readFileUTF8(NativePath(path));
}


/**
	Write a string into a UTF-8 encoded file.

	The file will have a byte order mark (BOM) prepended.
*/
void writeFileUTF8(NativePath path, string contents)
{
	static immutable ubyte[] bom = [0xEF, 0xBB, 0xBF];
	auto fil = openFile(path, FileMode.createTrunc);
	scope (exit) fil.close();
	fil.write(bom);
	fil.write(contents);
}

/**
	Creates and opens a temporary file for writing.
*/
FileStream createTempFile(string suffix = null)
{
	version(Windows){
		import std.conv : to;
		string tmpname;
		() @trusted {
			auto fn = tmpnam(null);
			enforce(fn !is null, "Failed to generate temporary name.");
			tmpname = to!string(fn);
		} ();
		if (tmpname.startsWith("\\")) tmpname = tmpname[1 .. $];
		tmpname ~= suffix;
		return openFile(tmpname, FileMode.createTrunc);
	} else {
		enum pattern ="/tmp/vtmp.XXXXXX";
		scope templ = new char[pattern.length+suffix.length+1];
		templ[0 .. pattern.length] = pattern;
		templ[pattern.length .. $-1] = (suffix)[];
		templ[$-1] = '\0';
		assert(suffix.length <= int.max);
		auto fd = () @trusted { return mkstemps(templ.ptr, cast(int)suffix.length); } ();
		enforce(fd >= 0, "Failed to create temporary file.");
		auto efd = eventDriver.files.adopt(fd);
		return FileStream(efd, NativePath(templ[0 .. $-1].idup), FileMode.createTrunc);
	}
}

/**
	Moves or renames a file.

	Params:
		from = Path to the file/directory to move/rename.
		to = The target path
		copy_fallback = Determines if copy/remove should be used in case of the
			source and destination path pointing to different devices.
*/
void moveFile(NativePath from, NativePath to, bool copy_fallback = false)
{
	moveFile(from.toNativeString(), to.toNativeString(), copy_fallback);
}
/// ditto
void moveFile(string from, string to, bool copy_fallback = false)
{
	auto fail = performInWorker((string from, string to) {
		try {
			std.file.rename(from, to);
		} catch (Exception e) {
			return e.msg.length ? e.msg : "Failed to move file.";
		}
		return null;
	}, from, to);

	if (!fail.length) return;

	if (!copy_fallback) throw new Exception(fail);

	copyFile(from, to);
	removeFile(from);
}

/**
	Copies a file.

	Note that attributes and time stamps are currently not retained.

	Params:
		from = Path of the source file
		to = Path for the destination file
		overwrite = If true, any file existing at the destination path will be
			overwritten. If this is false, an exception will be thrown should
			a file already exist at the destination path.

	Throws:
		An Exception if the copy operation fails for some reason.
*/
void copyFile(NativePath from, NativePath to, bool overwrite = false)
{
	DirEntry info;
	static if (__VERSION__ < 2078) {
		() @trusted {
			info = DirEntry(from.toString);
			enforce(info.isFile, "The source path is not a file and cannot be copied.");
		} ();
	} else {
		info = DirEntry(from.toString);
		enforce(info.isFile, "The source path is not a file and cannot be copied.");
	}

	{
		auto src = openFile(from, FileMode.read);
		scope(exit) src.close();
		enforce(overwrite || !existsFile(to), "Destination file already exists.");
		auto dst = openFile(to, FileMode.createTrunc);
		scope(exit) dst.close();
		dst.truncate(src.size);
		dst.write(src);
	}

	// TODO: also retain creation time on windows

	static if (__VERSION__ < 2078) {
		() @trusted {
			setTimes(to.toString, info.timeLastAccessed, info.timeLastModified);
			setAttributes(to.toString, info.attributes);
		} ();
	} else {
		setTimes(to.toString, info.timeLastAccessed, info.timeLastModified);
		setAttributes(to.toString, info.attributes);
	}
}
/// ditto
void copyFile(string from, string to)
{
	copyFile(NativePath(from), NativePath(to));
}

/**
	Removes a file
*/
void removeFile(NativePath path)
{
	removeFile(path.toNativeString());
}
/// ditto
void removeFile(string path)
{
	auto fail = performInWorker((string path) {
		try {
			std.file.remove(path);
		} catch (Exception e) {
			return e.msg.length ? e.msg : "Failed to delete file.";
		}
		return null;
	}, path);

	if (fail.length) throw new Exception(fail);
}

/**
	Checks if a file exists
*/
bool existsFile(NativePath path) nothrow
{
	return existsFile(path.toNativeString());
}
/// ditto
bool existsFile(string path) nothrow
{
	// This was *annotated* nothrow in 2.067.
	static if (__VERSION__ < 2067)
		scope(failure) assert(0, "Error: existsFile should never throw");

	try return performInWorker((string p) => std.file.exists(p), path);
	catch (Exception e) {
		logDebug("Failed to determine file existence for '%s': %s", path, e.msg);
		return false;
	}
}

/** Stores information about the specified file/directory into 'info'

	Throws: A `FileException` is thrown if the file does not exist.
*/
FileInfo getFileInfo(NativePath path)
@trusted {
	return getFileInfo(path.toNativeString);
}
/// ditto
FileInfo getFileInfo(string path)
{
	import std.typecons : tuple;

	auto ret = performInWorker((string p) {
		try {
			auto ent = DirEntry(p);
			return tuple(makeFileInfo(ent), "");
		} catch (Exception e) {
			return tuple(FileInfo.init, e.msg.length ? e.msg : "Failed to get file information");
		}
	}, path);
	if (ret[1].length) throw new Exception(ret[1]);
	return ret[0];
}

/**
	Creates a new directory.
*/
void createDirectory(NativePath path)
{
	createDirectory(path.toNativeString);
}
/// ditto
void createDirectory(string path, Flag!"recursive" recursive = No.recursive)
{
	auto fail = performInWorker((string p, bool rec) {
		try {
			if (rec) mkdirRecurse(p);
			else mkdir(p);
		} catch (Exception e) {
			return e.msg.length ? e.msg : "Failed to create directory.";
		}
		return null;
	}, path, !!recursive);

	if (fail) throw new Exception(fail);
}

/**
	Enumerates all files in the specified directory.
*/
void listDirectory(NativePath path, scope bool delegate(FileInfo info) @safe del)
{
	listDirectory(path.toNativeString, del);
}
/// ditto
void listDirectory(string path, scope bool delegate(FileInfo info) @safe del)
{
	import vibe.core.core : runWorkerTaskH;
	import vibe.core.channel : Channel, createChannel;

	struct S {
		FileInfo info;
		string error;
	}

	auto ch = createChannel!S();
	TaskSettings ts;
	ts.priority = 10 * Task.basePriority;
	runWorkerTaskH(ioTaskSettings, (string path, Channel!S ch) nothrow {
		scope (exit) ch.close();
		try {
			foreach (DirEntry ent; dirEntries(path, SpanMode.shallow)) {
				auto nfo = makeFileInfo(ent);
				try ch.put(S(nfo, null));
				catch (Exception e) break; // channel got closed
			}
		} catch (Exception e) {
			try ch.put(S(FileInfo.init, e.msg.length ? e.msg : "Failed to iterate directory"));
			catch (Exception e) {} // channel got closed
		}
	}, path, ch);

	S itm;
	while (ch.tryConsumeOne(itm)) {
		if (itm.error.length)
			throw new Exception(itm.error);

		if (!del(itm.info)) {
			ch.close();
			break;
		}
	}
}
/// ditto
void listDirectory(NativePath path, scope bool delegate(FileInfo info) @system del)
@system {
	listDirectory(path, (nfo) @trusted => del(nfo));
}
/// ditto
void listDirectory(string path, scope bool delegate(FileInfo info) @system del)
@system {
	listDirectory(path, (nfo) @trusted => del(nfo));
}
/// ditto
int delegate(scope int delegate(ref FileInfo)) iterateDirectory(NativePath path)
{
	int iterator(scope int delegate(ref FileInfo) del){
		int ret = 0;
		listDirectory(path, (fi){
			ret = del(fi);
			return ret == 0;
		});
		return ret;
	}
	return &iterator;
}
/// ditto
int delegate(scope int delegate(ref FileInfo)) iterateDirectory(string path)
{
	return iterateDirectory(NativePath(path));
}

/**
	Starts watching a directory for changes.
*/
DirectoryWatcher watchDirectory(NativePath path, bool recursive = true)
{
	return DirectoryWatcher(path, recursive);
}
// ditto
DirectoryWatcher watchDirectory(string path, bool recursive = true)
{
	return watchDirectory(NativePath(path), recursive);
}

/**
	Returns the current working directory.
*/
NativePath getWorkingDirectory()
{
	return NativePath(() @trusted { return std.file.getcwd(); } ());
}


/** Contains general information about a file.
*/
struct FileInfo {
	/// Name of the file (not including the path)
	string name;

	/// Size of the file (zero for directories)
	ulong size;

	/// Time of the last modification
	SysTime timeModified;

	/// Time of creation (not available on all operating systems/file systems)
	SysTime timeCreated;

	/// True if this is a symlink to an actual file
	bool isSymlink;

	/// True if this is a directory or a symlink pointing to a directory
	bool isDirectory;

	/// True if this is a file. On POSIX if both isFile and isDirectory are false it is a special file.
	bool isFile;

	/** True if the file's hidden attribute is set.

		On systems that don't support a hidden attribute, any file starting with
		a single dot will be treated as hidden.
	*/
	bool hidden;
}

/**
	Specifies how a file is manipulated on disk.
*/
enum FileMode {
	/// The file is opened read-only.
	read = FileOpenMode.read,
	/// The file is opened for read-write random access.
	readWrite = FileOpenMode.readWrite,
	/// The file is truncated if it exists or created otherwise and then opened for read-write access.
	createTrunc = FileOpenMode.createTrunc,
	/// The file is opened for appending data to it and created if it does not exist.
	append = FileOpenMode.append
}

/**
	Accesses the contents of a file as a stream.
*/
struct FileStream {
	@safe:

	private struct CTX {
		NativePath path;
		ulong size;
		FileMode mode;
		ulong ptr;
		shared(NativeEventDriver) driver;
	}

	private {
		FileFD m_fd;
		CTX* m_ctx;
	}

	private this(FileFD fd, NativePath path, FileMode mode)
	{
		assert(fd != FileFD.invalid, "Constructing FileStream from invalid file descriptor.");
		m_fd = fd;
		m_ctx = new CTX; // TODO: use FD custom storage
		m_ctx.path = path;
		m_ctx.mode = mode;
		m_ctx.size = eventDriver.files.getSize(fd);
		m_ctx.driver = () @trusted { return cast(shared)eventDriver; } ();

		if (mode == FileMode.append)
			m_ctx.ptr = m_ctx.size;
	}

	this(this)
	{
		if (m_fd != FileFD.invalid)
			eventDriver.files.addRef(m_fd);
	}

	~this()
	{
		if (m_fd != FileFD.invalid)
			releaseHandle!"files"(m_fd, m_ctx.driver);
	}

	@property int fd() { return cast(int)m_fd; }

	/// The path of the file.
	@property NativePath path() const { return ctx.path; }

	/// Determines if the file stream is still open
	@property bool isOpen() const { return m_fd != FileFD.invalid; }
	@property ulong size() const nothrow { return ctx.size; }
	@property bool readable() const nothrow { return ctx.mode != FileMode.append; }
	@property bool writable() const nothrow { return ctx.mode != FileMode.read; }

	bool opCast(T)() if (is (T == bool)) { return m_fd != FileFD.invalid; }

	void takeOwnershipOfFD()
	{
		assert(false, "TODO!");
	}

	void seek(ulong offset)
	{
		enforce(ctx.mode != FileMode.append, "File opened for appending, not random access. Cannot seek.");
		ctx.ptr = offset;
	}

	ulong tell() nothrow { return ctx.ptr; }

	void truncate(ulong size)
	{
		enforce(ctx.mode != FileMode.append, "File opened for appending, not random access. Cannot truncate.");

		auto res = asyncAwaitUninterruptible!(FileIOCallback,
			cb => eventDriver.files.truncate(m_fd, size, cb)
		);
		enforce(res[1] == IOStatus.ok, "Failed to resize file.");
		m_ctx.size = size;
	}

	/// Closes the file handle.
	void close()
	{
		if (m_fd == FileFD.invalid) return;
		if (!eventDriver.files.isValid(m_fd)) return;

		auto res = asyncAwaitUninterruptible!(FileCloseCallback,
			cb => eventDriver.files.close(m_fd, cb)
		);
		releaseHandle!"files"(m_fd, m_ctx.driver);
		m_fd = FileFD.invalid;
		m_ctx = null;

		if (res[1] != CloseStatus.ok)
			throw new Exception("Failed to close file");
	}

	@property bool empty() const { assert(this.readable); return ctx.ptr >= ctx.size; }
	@property ulong leastSize() const { assert(this.readable); return ctx.size - ctx.ptr; }
	@property bool dataAvailableForRead() { return true; }

	const(ubyte)[] peek()
	{
		return null;
	}

	size_t read(ubyte[] dst, IOMode mode)
	{
		auto res = asyncAwait!(FileIOCallback,
			cb => eventDriver.files.read(m_fd, ctx.ptr, dst, mode, cb),
			cb => eventDriver.files.cancelRead(m_fd)
		);
		ctx.ptr += res[2];
		enforce(res[1] == IOStatus.ok, "Failed to read data from disk.");
		return res[2];
	}

	void read(ubyte[] dst)
	{
		auto ret = read(dst, IOMode.all);
		assert(ret == dst.length, "File.read returned less data than requested for IOMode.all.");
	}

	size_t write(in ubyte[] bytes, IOMode mode)
	{
		auto res = asyncAwait!(FileIOCallback,
			cb => eventDriver.files.write(m_fd, ctx.ptr, bytes, mode, cb),
			cb => eventDriver.files.cancelWrite(m_fd)
		);
		ctx.ptr += res[2];
		if (ctx.ptr > ctx.size) ctx.size = ctx.ptr;
		enforce(res[1] == IOStatus.ok, "Failed to write data to disk.");
		return res[2];
	}

	void write(in ubyte[] bytes)
	{
		write(bytes, IOMode.all);
	}

	void write(in char[] bytes)
	{
		write(cast(const(ubyte)[])bytes);
	}

	void write(InputStream)(InputStream stream, ulong nbytes = ulong.max)
		if (isInputStream!InputStream)
	{
		writeDefault(this, stream, nbytes);
	}

	void flush()
	{
		assert(this.writable);
	}

	void finalize()
	{
		flush();
	}

	private inout(CTX)* ctx() inout nothrow { return m_ctx; }
}

mixin validateRandomAccessStream!FileStream;


private void writeDefault(OutputStream, InputStream)(ref OutputStream dst, InputStream stream, ulong nbytes = ulong.max)
	if (isOutputStream!OutputStream && isInputStream!InputStream)
{
	import vibe.internal.allocator : theAllocator, make, dispose;
	import std.algorithm.comparison : min;

	static struct Buffer { ubyte[64*1024] bytes = void; }
	auto bufferobj = () @trusted { return theAllocator.make!Buffer(); } ();
	scope (exit) () @trusted { theAllocator.dispose(bufferobj); } ();
	auto buffer = bufferobj.bytes[];

	//logTrace("default write %d bytes, empty=%s", nbytes, stream.empty);
	if (nbytes == ulong.max) {
		while (!stream.empty) {
			size_t chunk = min(stream.leastSize, buffer.length);
			assert(chunk > 0, "leastSize returned zero for non-empty stream.");
			//logTrace("read pipe chunk %d", chunk);
			stream.read(buffer[0 .. chunk]);
			dst.write(buffer[0 .. chunk]);
		}
	} else {
		while (nbytes > 0) {
			size_t chunk = min(nbytes, buffer.length);
			//logTrace("read pipe chunk %d", chunk);
			stream.read(buffer[0 .. chunk]);
			dst.write(buffer[0 .. chunk]);
			nbytes -= chunk;
		}
	}
}


/**
	Interface for directory watcher implementations.

	Directory watchers monitor the contents of a directory (wither recursively or non-recursively)
	for changes, such as file additions, deletions or modifications.
*/
struct DirectoryWatcher { // TODO: avoid all those heap allocations!
	import std.array : Appender, appender;
	import vibe.core.sync : LocalManualEvent, createManualEvent;

	@safe:

	private static struct Context {
		NativePath path;
		bool recursive;
		Appender!(DirectoryChange[]) changes;
		LocalManualEvent changeEvent;
		shared(NativeEventDriver) driver;

		// Support for `-preview=in`
		static if (!is(typeof(mixin(q{(in ref int a) => a}))))
		{
			void onChange(WatcherID id, in FileChange change) nothrow {
				this.onChangeImpl(id, change);
			}
		} else {
			mixin(q{
			void onChange(WatcherID id, in ref FileChange change) nothrow {
				this.onChangeImpl(id, change);
			}});
		}

		void onChangeImpl(WatcherID, const scope ref FileChange change)
		nothrow {
			DirectoryChangeType ct;
			final switch (change.kind) {
				case FileChangeKind.added: ct = DirectoryChangeType.added; break;
				case FileChangeKind.removed: ct = DirectoryChangeType.removed; break;
				case FileChangeKind.modified: ct = DirectoryChangeType.modified; break;
			}

			static if (is(typeof(change.baseDirectory))) {
				// eventcore 0.8.23 and up
				this.changes ~= DirectoryChange(ct, NativePath.fromTrustedString(change.baseDirectory) ~ NativePath.fromTrustedString(change.directory) ~ NativePath.fromTrustedString(change.name.idup));
			} else {
				this.changes ~= DirectoryChange(ct, NativePath.fromTrustedString(change.directory) ~ NativePath.fromTrustedString(change.name.idup));
			}
			this.changeEvent.emit();
		}
	}

	private {
		WatcherID m_watcher;
		Context* m_context;
	}

	private this(NativePath path, bool recursive)
	{
		m_context = new Context; // FIME: avoid GC allocation (use FD user data slot)
		m_context.changeEvent = createManualEvent();
		m_watcher = eventDriver.watchers.watchDirectory(path.toNativeString, recursive, &m_context.onChange);
		enforce(m_watcher != WatcherID.invalid, "Failed to watch directory.");
		m_context.path = path;
		m_context.recursive = recursive;
		m_context.changes = appender!(DirectoryChange[]);
		m_context.driver = () @trusted { return cast(shared)eventDriver; } ();
	}

	this(this) nothrow { if (m_watcher != WatcherID.invalid) eventDriver.watchers.addRef(m_watcher); }
	~this()
	nothrow {
		if (m_watcher != WatcherID.invalid)
			releaseHandle!"watchers"(m_watcher, m_context.driver);
	}

	/// The path of the watched directory
	@property NativePath path() const nothrow { return m_context.path; }

	/// Indicates if the directory is watched recursively
	@property bool recursive() const nothrow { return m_context.recursive; }

	/** Fills the destination array with all changes that occurred since the last call.

		The function will block until either directory changes have occurred or until the
		timeout has elapsed. Specifying a negative duration will cause the function to
		wait without a timeout.

		Params:
			dst = The destination array to which the changes will be appended
			timeout = Optional timeout for the read operation. A value of
				`Duration.max` will wait indefinitely.

		Returns:
			If the call completed successfully, true is returned.
	*/
	bool readChanges(ref DirectoryChange[] dst, Duration timeout = Duration.max)
	{
		if (timeout == Duration.max) {
			while (!m_context.changes.data.length)
				m_context.changeEvent.wait(Duration.max, m_context.changeEvent.emitCount);
		} else {
			MonoTime now = MonoTime.currTime();
			MonoTime final_time = now + timeout;
			while (!m_context.changes.data.length) {
				m_context.changeEvent.wait(final_time - now, m_context.changeEvent.emitCount);
				now = MonoTime.currTime();
				if (now >= final_time) break;
			}
			if (!m_context.changes.data.length) return false;
		}

		dst = m_context.changes.data;
		m_context.changes = appender!(DirectoryChange[]);
		return true;
	}
}


/** Specifies the kind of change in a watched directory.
*/
enum DirectoryChangeType {
	/// A file or directory was added
	added,
	/// A file or directory was deleted
	removed,
	/// A file or directory was modified
	modified
}


/** Describes a single change in a watched directory.
*/
struct DirectoryChange {
	/// The type of change
	DirectoryChangeType type;

	/// Path of the file/directory that was changed
	NativePath path;
}


private FileInfo makeFileInfo(DirEntry ent)
@trusted nothrow {
	import std.algorithm.comparison : among;

	FileInfo ret;
	string fullname = ent.name;
	if (ent.name.length) {
		if (ent.name[$-1].among('/', '\\'))
			fullname = ent.name[0 .. $-1];
		ret.name = baseName(fullname);
		if (ret.name.length == 0) ret.name = fullname;
	}

	try {
		ret.isFile = ent.isFile;
		ret.isDirectory = ent.isDir;
		ret.isSymlink = ent.isSymlink;
		ret.timeModified = ent.timeLastModified;
		version(Windows) ret.timeCreated = ent.timeCreated;
		else ret.timeCreated = ent.timeLastModified;
		ret.size = ent.size;
	} catch (Exception e) {
		logDebug("Failed to get information for file '%s': %s", fullname, e.msg);
	}

	version (Windows) {
		import core.sys.windows.windows : FILE_ATTRIBUTE_HIDDEN;
		ret.hidden = (ent.attributes & FILE_ATTRIBUTE_HIDDEN) != 0;
	}
	else ret.hidden = ret.name.length > 1 && ret.name[0] == '.' && ret.name != "..";

	return ret;
}

version (Windows) {} else unittest {
	void test(string name_in, string name_out, bool hidden) {
		auto de = DirEntry(name_in);
		assert(makeFileInfo(de).hidden == hidden);
		assert(makeFileInfo(de).name == name_out);
	}

	void testCreate(string name_in, string name_out, bool hidden)
	{
		if (name_in.endsWith("/"))
			createDirectory(name_in);
		else writeFileUTF8(NativePath(name_in), name_in);
		scope (exit) removeFile(name_in);
		test(name_in, name_out, hidden);
	}

	test(".", ".", false);
	test("..", "..", false);
	testCreate(".test_foo", ".test_foo", true);
	test("./", ".", false);
	testCreate(".test_foo/", ".test_foo", true);
	test("/", "", false);
}

unittest {
	auto name = "toAppend.txt";
	scope(exit) removeFile(name);

	{
		auto handle = openFile(name, FileMode.createTrunc);
		handle.write("create,");
		assert(handle.tell() == "create,".length);
		handle.close();
	}
	{
		auto handle = openFile(name, FileMode.append);
		handle.write(" then append");
		assert(handle.tell() == "create, then append".length);
		handle.close();
	}

	assert(readFile(name) == "create, then append");
}


private auto performInWorker(C, ARGS...)(C callable, auto ref ARGS args)
{
	version (none) {
		import vibe.core.concurrency : asyncWork;
		return asyncWork(callable, args).getResult();
	} else {
		import vibe.core.core : runWorkerTask;
		import core.atomic : atomicFence;
		import std.concurrency : Tid, send, receiveOnly, thisTid;

		struct R {}

		alias RET = typeof(callable(args));
		shared(RET) ret;
		runWorkerTask(ioTaskSettings, (shared(RET)* r, Tid caller, C c, ref ARGS a) nothrow {
			*() @trusted { return cast(RET*)r; } () = c(a);
			// Just as a precaution, because ManualEvent is not well defined in
			// terms of fence semantics
			atomicFence();
			try caller.send(R.init);
			catch (Exception e) assert(false, e.msg);
		}, () @trusted { return &ret; } (), thisTid, callable, args);
		() @trusted { receiveOnly!R(); } ();
		atomicFence();
		return ret;
	}
}

private immutable TaskSettings ioTaskSettings = { priority: 20 * Task.basePriority };
