/+ dub.sdl:
name "test"
dependency "vibe-core" path=".."
+/
module test;

import core.time;
import vibe.core.core;
import vibe.core.log;
import vibe.core.net;
import std.stdio;

void main()
{
	// warm up event loop to ensure any lazily created file descriptors are
	// there
	sleep(10.msecs);

	auto initial_count = determineSocketCount();

	TCPConnection conn;
	try {
		conn = connectTCP("192.168.0.152", 1234, null, 0, 1.seconds); // some ip:port that would cause connection timeout
		assert(false);
	} catch (Exception e) {
		logInfo("Connection failed as expected...");
	}

	// give the driver some time to actually cancel, if needed
	sleep(100.msecs);

	assert(determineSocketCount() == initial_count, "Socket leaked during connect timeout");
}

size_t determineSocketCount()
{
	import std.algorithm.searching : count;
	import std.exception : enforce;
	import std.range : iota;

	version (Posix) {
		import core.sys.posix.sys.resource : getrlimit, rlimit, RLIMIT_NOFILE;
		import core.sys.posix.fcntl : fcntl, F_GETFD;

		rlimit rl;
		enforce(getrlimit(RLIMIT_NOFILE, &rl) == 0);
		return iota(rl.rlim_cur).count!((fd) => fcntl(cast(int)fd, F_GETFD) != -1);
	} else {
		import core.sys.windows.winsock2 : getsockopt, SOL_SOCKET, SO_TYPE;

		int st;
		int stlen = st.sizeof;
		return iota(65536).count!(s => getsockopt(s, SOL_SOCKET, SO_TYPE, cast(void*)&st, &stlen) == 0);
	}
}
