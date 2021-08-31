/**
	File handling functions and types.

	Copyright: © 2012-2021 Sönke Ludwig
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
import taggedalgebraic.taggedunion;


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
		src.pipe(dst, PipeMode.concurrent);
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

/** Returns file information about multiple files at once.

	This version of `getFileInfo` is more efficient than many individual calls
	to the singular version.
*/
FileInfoResult[] getFileInfo(const(NativePath)[] paths)
nothrow {
	import vibe.core.channel : Channel, ChannelConfig, ChannelPriority, createChannel;
	import vibe.core.core : runTask, runWorkerTask;

	if (!paths.length) return null;

	ChannelConfig cc;
	cc.priority = ChannelPriority.overhead;

	Channel!NativePath inch;
	Channel!FileInfoResult outch;

	try {
		inch = createChannel!NativePath(cc);
		outch = createChannel!FileInfoResult(cc);
	} catch (Exception e) assert(false, e.msg);

	static void getInfos(Channel!NativePath inch, Channel!FileInfoResult outch) nothrow {
		NativePath p;
		while (inch.tryConsumeOne(p)) {
			FileInfoResult fi;
			if (!existsFile(p)) fi = FileInfoResult.missing;
			else {
				try {
					auto ent = DirEntry(p.toString);
					fi = FileInfoResult.info(makeFileInfo(ent));
				} catch (Exception e) {
					fi = FileInfoResult.error(e.msg.length ? e.msg : "Failed to get file information");
				}
			}
			try outch.put(fi);
			catch (Exception e) assert(false, e.msg);
		}
		outch.close();
	}

	try runWorkerTask(&getInfos, inch, outch);
	catch (Exception e) assert(false, e.msg);

	runTask(() nothrow {
		foreach (p; paths) {
			try inch.put(p);
			catch (Exception e) assert(false, e.msg);
		}
		inch.close();
	});

	auto ret = new FileInfoResult[](paths.length);
	size_t i = 0;
	foreach (ref fi; ret) {
		if (!outch.tryConsumeOne(fi))
			assert(false);
	}
	assert(outch.empty);

	return ret;
}

struct FileInfoResultFields {
	Void missing;
	string error;
	FileInfo info;
}
alias FileInfoResult = TaggedUnion!FileInfoResultFields;


/**
	Creates a new directory.
*/
void createDirectory(NativePath path)
{
	createDirectory(path.toNativeString);
}
/// ditto
void createDirectory(NativePath path, Flag!"recursive" recursive)
{
	createDirectory(path.toNativeString, recursive);
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

/** Enumerates all files in the specified directory.

	Note that unless an explicit `mode` is given, `DirectoryMode.shallow` is the
	default and only items directly contained in the specified folder will be
	returned.

	Params:
		path = Path to the (root) folder to list
		mode = Defines how files and sub directories are treated during the enumeration
		del = Callback to invoke for each directory entry
		directory_predicate = Optional predicate used to determine whether to
			descent into a sub directory (only available in the recursive
			`DirectoryListMode` modes)
*/
void listDirectory(NativePath path, DirectoryListMode mode,
	scope bool delegate(FileInfo info) @safe del,
	scope bool function(ref const FileInfo) @safe nothrow directory_predicate = null)
{
	import vibe.core.channel : ChannelConfig, ChannelPriority, createChannel;
	import vibe.core.core : runWorkerTask;

	ChannelConfig cc;
	cc.priority = ChannelPriority.overhead;

	ListDirectoryRequest req;
	req.path = path;
	req.channel = createChannel!ListDirectoryData(cc);
	req.spanMode = mode;
	req.directoryPredicate = directory_predicate;

	runWorkerTask(ioTaskSettings, &performListDirectory, req);

	ListDirectoryData itm;
	while (req.channel.tryConsumeOne(itm)) {
		if (itm.error.length)
			throw new Exception(itm.error);

		if (!del(itm.info)) {
			req.channel.close();
			// makes sure that the directory handle is closed before returning
			while (!req.channel.empty) req.channel.tryConsumeOne(itm);
			break;
		}
	}
}
/// ditto
void listDirectory(string path, DirectoryListMode mode,
	scope bool delegate(FileInfo info) @safe del)
{
	listDirectory(NativePath(path), mode, del);
}
void listDirectory(NativePath path, scope bool delegate(FileInfo info) @safe del)
{
	listDirectory(path, DirectoryListMode.shallow, del);
}
/// ditto
void listDirectory(string path, scope bool delegate(FileInfo info) @safe del)
{
	listDirectory(path, DirectoryListMode.shallow, del);
}
/// ditto
void listDirectory(NativePath path, DirectoryListMode mode, scope bool delegate(FileInfo info) @system del,
	scope bool function(ref const FileInfo) @safe nothrow directory_predicate = null)
@system {
	listDirectory(path, mode, (nfo) @trusted => del(nfo), directory_predicate);
}
/// ditto
void listDirectory(string path, DirectoryListMode mode, scope bool delegate(FileInfo info) @system del)
@system {
	listDirectory(path, mode, (nfo) @trusted => del(nfo));
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
int delegate(scope int delegate(ref FileInfo)) iterateDirectory(NativePath path,
	DirectoryListMode mode = DirectoryListMode.shallow,
	bool function(ref const FileInfo) @safe nothrow directory_predicate = null)
{
	int iterator(scope int delegate(ref FileInfo) del){
		int ret = 0;
		listDirectory(path, mode, (fi) {
			ret = del(fi);
			return ret == 0;
		}, directory_predicate);
		return ret;
	}
	return &iterator;
}
/// ditto
int delegate(scope int delegate(ref FileInfo)) iterateDirectory(string path,
	DirectoryListMode mode = DirectoryListMode.shallow)
{
	return iterateDirectory(NativePath(path), mode);
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

	/// The directory containing the file
	NativePath directory;

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

enum DirectoryListMode {
	/// Only iterate the directory itself
	shallow = 0,
	/// Only iterate over directories directly within the given directory
	shallowDirectories = 1<<1,
	/// Iterate recursively (depth-first, pre-order)
	recursive = 1<<0,
	/// Iterate only directories recursively (depth-first, pre-order)
	recursiveDirectories = recursive | shallowDirectories,
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
	nothrow {
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
	nothrow {
		if (m_fd != FileFD.invalid)
			eventDriver.files.addRef(m_fd);
	}

	~this()
	nothrow {
		if (m_fd != FileFD.invalid)
			releaseHandle!"files"(m_fd, m_ctx.driver);
	}

	@property int fd() const nothrow { return cast(int)m_fd; }

	/// The path of the file.
	@property NativePath path() const nothrow { return ctx.path; }

	/// Determines if the file stream is still open
	@property bool isOpen() const nothrow { return m_fd != FileFD.invalid; }
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
		// NOTE: cancelRead is currently not behaving as specified and cannot
		//       be relied upon. For this reason, we MUST use the uninterruptible
		//       version of asyncAwait here!
		auto res = asyncAwaitUninterruptible!(FileIOCallback,
			cb => eventDriver.files.read(m_fd, ctx.ptr, dst, mode, cb)
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
		// NOTE: cancelWrite is currently not behaving as specified and cannot
		//       be relied upon. For this reason, we MUST use the uninterruptible
		//       version of asyncAwait here!
		auto res = asyncAwaitUninterruptible!(FileIOCallback,
			cb => eventDriver.files.write(m_fd, ctx.ptr, bytes, mode, cb)
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
		pipe(stream, this, nbytes, PipeMode.concurrent);
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

mixin validateClosableRandomAccessStream!FileStream;


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
			void onChange(WatcherID id, const scope ref FileChange change) nothrow {
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
	if (fullname.length) {
		if (ent.name[$-1].among('/', '\\'))
			fullname = ent.name[0 .. $-1];
		ret.name = baseName(fullname);
		ret.directory = NativePath.fromTrustedString(dirName(fullname));
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

private void performListDirectory(ListDirectoryRequest req)
@trusted nothrow {
	scope (exit) req.channel.close();

	auto dirs_only = !!(req.spanMode & DirectoryListMode.shallowDirectories);
	auto rec = !!(req.spanMode & DirectoryListMode.recursive);

	bool scanRec(NativePath path)
	{
		import std.algorithm.comparison : among;
		import std.algorithm.searching : countUntil;

		version (Windows) {
			import core.sys.windows.windows : FILE_ATTRIBUTE_DIRECTORY,
				FILE_ATTRIBUTE_DEVICE, FILE_ATTRIBUTE_HIDDEN,
				FILE_ATTRIBUTE_REPARSE_POINT, FINDEX_INFO_LEVELS, FINDEX_SEARCH_OPS,
				INVALID_HANDLE_VALUE, WIN32_FIND_DATAW,
				FindFirstFileExW, FindNextFileW, FindClose;
			import std.conv : to;
			import std.utf : toUTF16z;
			import std.windows.syserror : wenforce;

			static immutable timebase = SysTime(DateTime(1601, 1, 1), UTC());

			WIN32_FIND_DATAW fd;
			FINDEX_INFO_LEVELS lvl;
			static if (is(typeof(FINDEX_INFO_LEVELS.FindExInfoBasic)))
				lvl = FINDEX_INFO_LEVELS.FindExInfoBasic;
			else lvl = cast(FINDEX_INFO_LEVELS)1;
			auto fh = FindFirstFileExW((path.toString ~ "\\*").toUTF16z,
				lvl, &fd, dirs_only ? FINDEX_SEARCH_OPS.FindExSearchLimitToDirectories
					: FINDEX_SEARCH_OPS.FindExSearchNameMatch,
				null, 2/*FIND_FIRST_EX_LARGE_FETCH*/);
			wenforce(fh != INVALID_HANDLE_VALUE, path.toString);
			scope (exit) FindClose(fh);
			do {
				// skip non-directories if requested
				if (dirs_only && !(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
					continue;

				FileInfo fi;
				auto zi = fd.cFileName[].representation.countUntil(0);
				if (zi < 0) zi = fd.cFileName.length;
				if (fd.cFileName[0 .. zi].among("."w, ".."w))
					continue;
				fi.name = fd.cFileName[0 .. zi].to!string;
				fi.directory = path;
				fi.size = (ulong(fd.nFileSizeHigh) << 32) + fd.nFileSizeLow;
				fi.timeModified = timebase + hnsecs((ulong(fd.ftLastWriteTime.dwHighDateTime) << 32) + fd.ftLastWriteTime.dwLowDateTime);
				fi.timeCreated = timebase + hnsecs((ulong(fd.ftCreationTime.dwHighDateTime) << 32) + fd.ftCreationTime.dwLowDateTime);
				fi.isSymlink = !!(fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT);
				fi.isDirectory = !!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY);
				fi.isFile = !fi.isDirectory && !(fd.dwFileAttributes & FILE_ATTRIBUTE_DEVICE);
				fi.hidden = !!(fd.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN);

				try req.channel.put(ListDirectoryData(fi, null));
				catch (Exception e) return false; // channel got closed

				if (fi.isDirectory && req.directoryPredicate)
					if (!req.directoryPredicate(fi))
						continue;

				if (rec && fi.isDirectory) {
					if (fi.isSymlink && !req.followSymlinks)
						continue;
					try {
						if (!scanRec(path ~ NativePath.Segment2(fi.name)))
							return false;
					} catch (Exception e) {}
				}
			} while (FindNextFileW(fh, &fd));
		} else {
			import core.sys.posix.dirent : DT_DIR, DT_LNK, DT_UNKNOWN,
				dirent, opendir, closedir, readdir;
			import std.string : toStringz;

			static immutable timebase = SysTime(DateTime(1970, 1, 1), UTC());

			auto dir = opendir(path.toString.toStringz);
			errnoEnforce(dir !is null, path.toString);
			scope (exit) closedir(dir);

			auto dfd = dirfd(dir);

			dirent* de;
			while ((de = readdir(dir)) !is null) {
				// skip non-directories early, if possible
				if (dirs_only && !de.d_type.among(DT_DIR, DT_LNK, DT_UNKNOWN))
					continue;

				FileInfo fi;
				auto zi = de.d_name[].representation.countUntil(0);
				if (zi < 0) zi = de.d_name.length;
				if (de.d_name[0 .. zi].among(".", ".."))
					continue;

				fi.name = de.d_name[0 .. zi].idup;
				fi.directory = path;
				fi.hidden = de.d_name[0] == '.';

				static SysTime getTimeField(string f)(ref const stat_t st)
				{
					long secs, nsecs;
					static if (is(typeof(__traits(getMember, st, f)))) {
						secs = __traits(getMember, st, f).tv_sec;
						nsecs = __traits(getMember, st, f).tv_nsec;
					} else {
						secs = __traits(getMember, st, f ~ "e");
						static if (is(typeof(__traits(getMember, st, f ~ "ensec"))))
							nsecs = __traits(getMember, st, f ~ "ensec");
						else static if (is(typeof(__traits(getMember, st, "__" ~ f ~ "ensec"))))
							nsecs = __traits(getMember, st, "__" ~ f ~ "ensec");
						else static if (is(typeof(__traits(getMember, st, f ~ "e_nsec"))))
							nsecs = __traits(getMember, st, f ~ "e_nsec");
						else static if (is(typeof(__traits(getMember, st, "__" ~ f ~ "e_nsec"))))
							nsecs = __traits(getMember, st, "__" ~ f ~ "e_nsec");
						else static assert(false, "Found no nanoseconds fields in struct stat");
					}
					return timebase + secs.seconds + (nsecs / 100).hnsecs;
				}

				stat_t st;
				if (fstatat(dfd, fi.name.toStringz, &st, AT_SYMLINK_NOFOLLOW) == 0) {
					fi.isSymlink = S_ISLNK(st.st_mode);

					// apart from the symlink flag, get the rest of the information from the link target
					if (fi.isSymlink) fstatat(dfd, fi.name.toStringz, &st, 0);

					fi.size = st.st_size;
					fi.timeModified = getTimeField!"st_mtim"(st);
					fi.timeCreated = getTimeField!"st_ctim"(st);
					fi.isDirectory = S_ISDIR(st.st_mode);
					fi.isFile = S_ISREG(st.st_mode);
				}

				// skip non-directories if requested
				if (dirs_only && !fi.isDirectory)
					continue;

				try req.channel.put(ListDirectoryData(fi, null));
				catch (Exception e) return false; // channel got closed

				if (fi.isDirectory && req.directoryPredicate)
					if (!req.directoryPredicate(fi))
						continue;

				if (rec && fi.isDirectory) {
					if (fi.isSymlink && !req.followSymlinks)
						continue;
					try {
						if (!scanRec(path ~ NativePath.Segment2(fi.name)))
							return false;
					} catch (Exception e) {}
				}
			}
		}

		return true;
	}

	try scanRec(req.path);
	catch (Exception e) {
		logException(e, "goo");
		try req.channel.put(ListDirectoryData(FileInfo.init, e.msg.length ? e.msg : "Failed to iterate directory"));
		catch (Exception e2) {} // channel got closed
	}
}

version (Posix) {
	import core.sys.posix.dirent : DIR;
	import core.sys.posix.sys.stat : stat;
	extern(C) @safe nothrow @nogc {
		static if (!is(typeof(dirfd)))
			 int dirfd(DIR*);
		static if (!is(typeof(fstatat))) {
			version (OSX) {
    				version (AArch64) {
        				int fstatat(int dirfd, const(char)* pathname, stat_t *statbuf, int flags);
        			} else {
						pragma(mangle, "fstatat$INODE64")
						int fstatat(int dirfd, const(char)* pathname, stat_t *statbuf, int flags);
    				}
			} else int fstatat(int dirfd, const(char)* pathname, stat_t *statbuf, int flags);
		}
	}

	version (darwin) {
		static if (!is(typeof(AT_SYMLINK_NOFOLLOW)))
			enum AT_SYMLINK_NOFOLLOW = 0x0020;
	}

	version (CRuntime_Musl) {
		static if (!is(typeof(AT_SYMLINK_NOFOLLOW)))
			enum AT_SYMLINK_NOFOLLOW = 0x0100;
	}

	version (Android) {
		static if (!is(typeof(AT_SYMLINK_NOFOLLOW)))
			enum AT_SYMLINK_NOFOLLOW = 0x0100;
	}
}

private immutable TaskSettings ioTaskSettings = { priority: 20 * Task.basePriority };

private struct ListDirectoryData {
	FileInfo info;
	string error;
}

private struct ListDirectoryRequest {
	import vibe.core.channel : Channel;

	NativePath path;
	DirectoryListMode spanMode;
	Channel!ListDirectoryData channel;
	bool followSymlinks;
	bool function(ref const FileInfo) @safe nothrow directoryPredicate;
}
