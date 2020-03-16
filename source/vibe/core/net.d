/**
	TCP/UDP connection and server handling.

	Copyright: © 2012-2016 Sönke Ludwig
	Authors: Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.net;

import eventcore.core;
import std.exception : enforce;
import std.format : format;
import std.functional : toDelegate;
import std.socket : AddressFamily, UnknownAddress;
import vibe.core.internal.release;
import vibe.core.log;
import vibe.core.stream;
import vibe.internal.async;
import core.time : Duration;

@safe:


/**
	Resolves the given host name/IP address string.

	Setting use_dns to false will only allow IP address strings but also guarantees
	that the call will not block.
*/
NetworkAddress resolveHost(string host, AddressFamily address_family = AddressFamily.UNSPEC, bool use_dns = true, Duration timeout = Duration.max)
{
	return resolveHost(host, cast(ushort)address_family, use_dns, timeout);
}
/// ditto
NetworkAddress resolveHost(string host, ushort address_family, bool use_dns = true, Duration timeout = Duration.max)
{
	import std.socket : parseAddress;
	version (Windows) import core.sys.windows.winsock2 : sockaddr_in, sockaddr_in6;
	else import core.sys.posix.netinet.in_ : sockaddr_in, sockaddr_in6;

	enforce(host.length > 0, "Host name must not be empty.");
	if (isMaybeIPAddress(host)) {
		auto addr = parseAddress(host);
		enforce(address_family == AddressFamily.UNSPEC || addr.addressFamily == address_family);
		NetworkAddress ret;
		ret.family = addr.addressFamily;
		switch (addr.addressFamily) with(AddressFamily) {
			default: throw new Exception("Unsupported address family");
			case INET: *ret.sockAddrInet4 = () @trusted { return *cast(sockaddr_in*)addr.name; } (); break;
			case INET6: *ret.sockAddrInet6 = () @trusted { return *cast(sockaddr_in6*)addr.name; } (); break;
		}
		return ret;
	} else {
		enforce(use_dns, "Malformed IP address string.");
		NetworkAddress res;
		bool success = false;
		alias waitable = Waitable!(DNSLookupCallback,
			cb => eventDriver.dns.lookupHost(host, cb),
			(cb, id) => eventDriver.dns.cancelLookup(id),
			(DNSLookupID, DNSStatus status, scope RefAddress[] addrs) {
				if (status == DNSStatus.ok) {
					foreach (addr; addrs) {
						if (address_family != AddressFamily.UNSPEC && addr.addressFamily != address_family) continue;
						try res = NetworkAddress(addr);
						catch (Exception e) { logDiagnostic("Failed to store address from DNS lookup: %s", e.msg); }
						success = true;
						break;
					}
				}
			}
		);

		asyncAwaitAny!(true, waitable)(timeout);

		enforce(success, "Failed to lookup host '"~host~"'.");
		return res;
	}
}


/**
	Starts listening on the specified port.

	'connection_callback' will be called for each client that connects to the
	server socket. Each new connection gets its own fiber. The stream parameter
	then allows to perform blocking I/O on the client socket.

	The address parameter can be used to specify the network
	interface on which the server socket is supposed to listen for connections.
	By default, all IPv4 and IPv6 interfaces will be used.
*/
TCPListener[] listenTCP(ushort port, TCPConnectionDelegate connection_callback, TCPListenOptions options = TCPListenOptions.defaults)
{
	TCPListener[] ret;
	try ret ~= listenTCP(port, connection_callback, "::", options);
	catch (Exception e) logDiagnostic("Failed to listen on \"::\": %s", e.msg);
	try ret ~= listenTCP(port, connection_callback, "0.0.0.0", options);
	catch (Exception e) logDiagnostic("Failed to listen on \"0.0.0.0\": %s", e.msg);
	enforce(ret.length > 0, format("Failed to listen on all interfaces on port %s", port));
	return ret;
}
/// ditto
TCPListener listenTCP(ushort port, TCPConnectionDelegate connection_callback, string address, TCPListenOptions options = TCPListenOptions.defaults)
{
	auto addr = resolveHost(address);
	addr.port = port;
	StreamListenOptions sopts = StreamListenOptions.defaults;
	if (options & TCPListenOptions.reuseAddress)
		sopts |= StreamListenOptions.reuseAddress;
	else
		sopts &= ~StreamListenOptions.reuseAddress;
	if (options & TCPListenOptions.reusePort)
		sopts |= StreamListenOptions.reusePort;
	else
		sopts &= ~StreamListenOptions.reusePort;
	scope addrc = new RefAddress(addr.sockAddr, addr.sockAddrLen);
	auto sock = eventDriver.sockets.listenStream(addrc, sopts,
		(StreamListenSocketFD ls, StreamSocketFD s, scope RefAddress addr) @safe nothrow {
			import vibe.core.core : runTask;
			auto conn = TCPConnection(s, addr);
			runTask(connection_callback, conn);
		});
	enforce(sock != StreamListenSocketFD.invalid, "Failed to listen on "~addr.toString());
	return TCPListener(sock);
}

/// Compatibility overload - use an `@safe nothrow` callback instead.
deprecated("Use a @safe nothrow callback instead.")
TCPListener[] listenTCP(ushort port, void delegate(TCPConnection) connection_callback, TCPListenOptions options = TCPListenOptions.defaults)
{
	TCPListener[] ret;
	try ret ~= listenTCP(port, connection_callback, "::", options);
	catch (Exception e) logDiagnostic("Failed to listen on \"::\": %s", e.msg);
	try ret ~= listenTCP(port, connection_callback, "0.0.0.0", options);
	catch (Exception e) logDiagnostic("Failed to listen on \"0.0.0.0\": %s", e.msg);
	enforce(ret.length > 0, format("Failed to listen on all interfaces on port %s", port));
	return ret;
}
/// ditto
deprecated("Use a @safe nothrow callback instead.")
TCPListener listenTCP(ushort port, void delegate(TCPConnection) connection_callback, string address, TCPListenOptions options = TCPListenOptions.defaults)
{
	return listenTCP(port, (conn) @trusted nothrow {
		try connection_callback(conn);
		catch (Exception e) {
			logError("Handling of connection failed: %s", e.msg);
			conn.close();
			logDebug("Full error: %s", e);
		}
	}, address, options);
}

/**
	Starts listening on the specified port.

	This function is the same as listenTCP but takes a function callback instead of a delegate.
*/
TCPListener[] listenTCP_s(ushort port, TCPConnectionFunction connection_callback, TCPListenOptions options = TCPListenOptions.defaults) @trusted
{
	return listenTCP(port, toDelegate(connection_callback), options);
}
/// ditto
TCPListener listenTCP_s(ushort port, TCPConnectionFunction connection_callback, string address, TCPListenOptions options = TCPListenOptions.defaults) @trusted
{
	return listenTCP(port, toDelegate(connection_callback), address, options);
}

/**
	Establishes a connection to the given host/port.
*/
TCPConnection connectTCP(string host, ushort port, string bind_interface = null,
	ushort bind_port = 0, Duration timeout = Duration.max)
{
	NetworkAddress addr = resolveHost(host);
	addr.port = port;
	if (addr.family != AddressFamily.UNIX)
		addr.port = port;

	NetworkAddress bind_address;
	if (bind_interface.length) bind_address = resolveHost(bind_interface, addr.family);
	else {
		bind_address.family = addr.family;
		if (bind_address.family == AddressFamily.INET) bind_address.sockAddrInet4.sin_addr.s_addr = 0;
		else if (bind_address.family != AddressFamily.UNIX) bind_address.sockAddrInet6.sin6_addr.s6_addr[] = 0;
	}
	if (addr.family != AddressFamily.UNIX)
		bind_address.port = bind_port;

	return connectTCP(addr, bind_address, timeout);
}
/// ditto
TCPConnection connectTCP(NetworkAddress addr, NetworkAddress bind_address = anyAddress,
	Duration timeout = Duration.max)
{
	import std.conv : to;

	if (bind_address.family == AddressFamily.UNSPEC) {
		bind_address.family = addr.family;
		if (bind_address.family == AddressFamily.INET) bind_address.sockAddrInet4.sin_addr.s_addr = 0;
		else if (bind_address.family != AddressFamily.UNIX) bind_address.sockAddrInet6.sin6_addr.s6_addr[] = 0;
		if (bind_address.family != AddressFamily.UNIX)
			bind_address.port = 0;
	}
	enforce(addr.family == bind_address.family, "Destination address and bind address have different address families.");

	return () @trusted { // scope
		scope uaddr = new RefAddress(addr.sockAddr, addr.sockAddrLen);
		scope baddr = new RefAddress(bind_address.sockAddr, bind_address.sockAddrLen);

		bool cancelled;
		StreamSocketFD sock;
		ConnectStatus status;

		alias waiter = Waitable!(ConnectCallback,
			cb => eventDriver.sockets.connectStream(uaddr, baddr, cb),
			(cb, sock_fd) {
				cancelled = true;
				if (sock_fd != SocketFD.invalid)
					eventDriver.sockets.cancelConnectStream(sock_fd);
			},
			(fd, st) { sock = fd; status = st; }
		);

		asyncAwaitAny!(true, waiter)(timeout);

		enforce(!cancelled, "Failed to connect to " ~ addr.toString() ~
			": timeout");

		if (status != ConnectStatus.connected) {
			if (sock != SocketFD.invalid)
				eventDriver.sockets.releaseRef(sock);

			enforce(false, "Failed to connect to "~addr.toString()~": "~status.to!string);
			assert(false);
		}

		return TCPConnection(sock, uaddr);
	} ();
}


/**
	Creates a bound UDP socket suitable for sending and receiving packets.
*/
UDPConnection listenUDP(ref NetworkAddress addr)
{
	return UDPConnection(addr);
}
/// ditto
UDPConnection listenUDP(ushort port, string bind_address = "0.0.0.0")
{
	auto addr = resolveHost(bind_address, AddressFamily.UNSPEC, false);
	addr.port = port;
	return UDPConnection(addr);
}

NetworkAddress anyAddress()
{
	NetworkAddress ret;
	ret.family = AddressFamily.UNSPEC;
	return ret;
}


/// Callback invoked for incoming TCP connections.
@safe nothrow alias TCPConnectionDelegate = void delegate(TCPConnection stream);
/// ditto
@safe nothrow alias TCPConnectionFunction = void function(TCPConnection stream);


/**
	Represents a network/socket address.
*/
struct NetworkAddress {
	import std.algorithm.comparison : max;
	import std.socket : Address;

	version (Windows) import core.sys.windows.winsock2;
	else import core.sys.posix.netinet.in_;

	version(Posix) import core.sys.posix.sys.un : sockaddr_un;

	@safe:

	private union {
		sockaddr addr;
		version (Posix) sockaddr_un addr_unix;
		sockaddr_in addr_ip4;
		sockaddr_in6 addr_ip6;
	}

	enum socklen_t sockAddrMaxLen = max(addr.sizeof, addr_ip6.sizeof);


	this(Address addr)
		@trusted
	{
		assert(addr !is null);
		switch (addr.addressFamily) {
			default: throw new Exception("Unsupported address family.");
			case AddressFamily.INET:
				this.family = AddressFamily.INET;
				assert(addr.nameLen >= sockaddr_in.sizeof);
				*this.sockAddrInet4 = *cast(sockaddr_in*)addr.name;
				break;
			case AddressFamily.INET6:
				this.family = AddressFamily.INET6;
				assert(addr.nameLen >= sockaddr_in6.sizeof);
				*this.sockAddrInet6 = *cast(sockaddr_in6*)addr.name;
				break;
			version (Posix) {
				case AddressFamily.UNIX:
					this.family = AddressFamily.UNIX;
					assert(addr.nameLen >= sockaddr_un.sizeof);
					*this.sockAddrUnix = *cast(sockaddr_un*)addr.name;
					break;
			}
		}
	}

	/** Family of the socket address.
	*/
	@property ushort family() const pure nothrow { return addr.sa_family; }
	/// ditto
	@property void family(AddressFamily val) pure nothrow { addr.sa_family = cast(ubyte)val; }
	/// ditto
	@property void family(ushort val) pure nothrow { addr.sa_family = cast(ubyte)val; }

	/** The port in host byte order.
	*/
	@property ushort port()
	const pure nothrow {
		ushort nport;
		switch (this.family) {
			default: assert(false, "port() called for invalid address family.");
			case AF_INET: nport = addr_ip4.sin_port; break;
			case AF_INET6: nport = addr_ip6.sin6_port; break;
		}
		return () @trusted { return ntoh(nport); } ();
	}
	/// ditto
	@property void port(ushort val)
	pure nothrow {
		auto nport = () @trusted { return hton(val); } ();
		switch (this.family) {
			default: assert(false, "port() called for invalid address family.");
			case AF_INET: addr_ip4.sin_port = nport; break;
			case AF_INET6: addr_ip6.sin6_port = nport; break;
		}
	}

	/** A pointer to a sockaddr struct suitable for passing to socket functions.
	*/
	@property inout(sockaddr)* sockAddr() inout pure nothrow { return &addr; }

	/** Size of the sockaddr struct that is returned by sockAddr().
	*/
	@property socklen_t sockAddrLen()
	const pure nothrow {
		switch (this.family) {
			default: assert(false, "sockAddrLen() called for invalid address family.");
			case AF_INET: return addr_ip4.sizeof;
			case AF_INET6: return addr_ip6.sizeof;
			version (Posix) {
				case AF_UNIX: return addr_unix.sizeof;
			}
		}
	}

	@property inout(sockaddr_in)* sockAddrInet4() inout pure nothrow
		in { assert (family == AF_INET); }
		do { return &addr_ip4; }

	@property inout(sockaddr_in6)* sockAddrInet6() inout pure nothrow
		in { assert (family == AF_INET6); }
		do { return &addr_ip6; }

	version (Posix) {
		@property inout(sockaddr_un)* sockAddrUnix() inout pure nothrow
			in { assert (family == AddressFamily.UNIX); }
			do { return &addr_unix; }
	}

	/** Returns a string representation of the IP address
	*/
	string toAddressString()
	const nothrow {
		import std.array : appender;
		auto ret = appender!string();
		ret.reserve(40);
		toAddressString(str => ret.put(str));
		return ret.data;
	}
	/// ditto
	void toAddressString(scope void delegate(const(char)[]) @safe sink)
	const nothrow {
		import std.array : appender;
		import std.format : formattedWrite;
		ubyte[2] _dummy = void; // Workaround for DMD regression in master

		scope (failure) assert(false);

		switch (this.family) {
			default: assert(false, "toAddressString() called for invalid address family.");
			case AF_UNSPEC:
				sink("<UNSPEC>");
				break;
			case AF_INET: {
				ubyte[4] ip = () @trusted { return (cast(ubyte*)&addr_ip4.sin_addr.s_addr)[0 .. 4]; } ();
				sink.formattedWrite("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3]);
				} break;
			case AF_INET6: {
				ubyte[16] ip = addr_ip6.sin6_addr.s6_addr;
				foreach (i; 0 .. 8) {
					if (i > 0) sink(":");
					_dummy[] = ip[i*2 .. i*2+2];
					sink.formattedWrite("%x", bigEndianToNative!ushort(_dummy));
				}
				} break;
			version (Posix) {
				case AddressFamily.UNIX:
					import std.traits : hasMember;
					import std.string : fromStringz;
					static if (hasMember!(sockaddr_un, "sun_len"))
						sink(() @trusted { return cast(char[])addr_unix.sun_path[0..addr_unix.sun_len]; } ());
					else
						sink(() @trusted { return (cast(char*)addr_unix.sun_path.ptr).fromStringz; } ());
					break;
			}
		}
	}

	/** Returns a full string representation of the address, including the port number.
	*/
	string toString()
	const nothrow {
		import std.array : appender;
		auto ret = appender!string();
		toString(str => ret.put(str));
		return ret.data;
	}
	/// ditto
	void toString(scope void delegate(const(char)[]) @safe sink)
	const nothrow {
		import std.format : formattedWrite;
		try {
			switch (this.family) {
				default: assert(false, "toString() called for invalid address family.");
				case AF_UNSPEC:
					sink("<UNSPEC>");
					break;
				case AF_INET:
					toAddressString(sink);
					sink.formattedWrite(":%s", port);
					break;
				case AF_INET6:
					sink("[");
					toAddressString(sink);
					sink.formattedWrite("]:%s", port);
					break;
				case AddressFamily.UNIX:
					toAddressString(sink);
					break;
			}
		} catch (Exception e) {
			assert(false, "Unexpected exception: "~e.msg);
		}
	}

	version(Have_libev) {}
	else {
		unittest {
			void test(string ip) {
				auto res = () @trusted { return resolveHost(ip, AF_UNSPEC, false); } ().toAddressString();
				assert(res == ip,
					   "IP "~ip~" yielded wrong string representation: "~res);
			}
			test("1.2.3.4");
			test("102:304:506:708:90a:b0c:d0e:f10");
		}
	}
}

/**
	Represents a single TCP connection.
*/
struct TCPConnection {
	@safe:

	import core.time : seconds;
	import vibe.internal.array : BatchBuffer;
	//static assert(isConnectionStream!TCPConnection);

	static struct Context {
		BatchBuffer!ubyte readBuffer;
		bool tcpNoDelay = false;
		bool keepAlive = false;
		Duration readTimeout = Duration.max;
		string remoteAddressString;
		shared(NativeEventDriver) driver;
	}

	private {
		StreamSocketFD m_socket;
		Context* m_context;
	}

	private this(StreamSocketFD socket, scope RefAddress remote_address)
	nothrow {
		import std.exception : enforce;

		m_socket = socket;
		m_context = () @trusted { return &eventDriver.sockets.userData!Context(socket); } ();
		m_context.readBuffer.capacity = 4096;
		m_context.driver = () @trusted { return cast(shared)eventDriver; } ();
	}

	this(this)
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			eventDriver.sockets.addRef(m_socket);
	}

	~this()
	nothrow {
		if (m_socket != StreamSocketFD.invalid)
			releaseHandle!"sockets"(m_socket, m_context.driver);
	}

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_socket != StreamSocketFD.invalid; }

	@property void tcpNoDelay(bool enabled) nothrow { eventDriver.sockets.setTCPNoDelay(m_socket, enabled); m_context.tcpNoDelay = enabled; }
	@property bool tcpNoDelay() const nothrow { return m_context.tcpNoDelay; }
	@property void keepAlive(bool enabled) nothrow { eventDriver.sockets.setKeepAlive(m_socket, enabled); m_context.keepAlive = enabled; }
	@property bool keepAlive() const nothrow { return m_context.keepAlive; }
	@property void readTimeout(Duration duration) { m_context.readTimeout = duration; }
	@property Duration readTimeout() const nothrow { return m_context.readTimeout; }
	@property string peerAddress() const nothrow { return this.remoteAddress.toString(); }
	@property NetworkAddress localAddress() const nothrow {
		NetworkAddress naddr;
		scope addr = new RefAddress(naddr.sockAddr, naddr.sockAddrMaxLen);
		if (!eventDriver.sockets.getLocalAddress(m_socket, addr))
			logWarn("Failed to get local address for TCP connection");
		return naddr;
	}
	@property NetworkAddress remoteAddress() const nothrow {
		NetworkAddress naddr;
		scope addr = new RefAddress(naddr.sockAddr, naddr.sockAddrMaxLen);
		if (!eventDriver.sockets.getRemoteAddress(m_socket, addr))
			logWarn("Failed to get remote address for TCP connection");
		return naddr;
	}
	@property bool connected()
	const nothrow {
		if (m_socket == StreamSocketFD.invalid) return false;
		auto s = eventDriver.sockets.getConnectionState(m_socket);
		return s >= ConnectionState.connected && s < ConnectionState.activeClose;
	}
	@property bool empty() { return leastSize == 0; }

	@property ulong leastSize()
	{
		if (!m_context) return 0;

		auto res = waitForDataEx(m_context.readTimeout);
		if (res == WaitForDataStatus.timeout)
			throw new ReadTimeoutException("Read operation timed out");

		return m_context.readBuffer.length;
	}

	@property bool dataAvailableForRead() { return waitForData(0.seconds); }

	void close()
	nothrow {
		//logInfo("close %s", cast(int)m_fd);
		if (m_socket != StreamSocketFD.invalid) {
			eventDriver.sockets.shutdown(m_socket, true, true);
			releaseHandle!"sockets"(m_socket, m_context.driver);
			m_socket = StreamSocketFD.invalid;
			m_context = null;
		}
	}

	bool waitForData(Duration timeout = Duration.max)
	{
		return waitForDataEx(timeout) == WaitForDataStatus.dataAvailable;
	}

	WaitForDataStatus waitForDataEx(Duration timeout = Duration.max)
	{
mixin(tracer);
		if (!m_context) return WaitForDataStatus.noMoreData;
		if (m_context.readBuffer.length > 0) return WaitForDataStatus.dataAvailable;
		auto mode = timeout <= 0.seconds ? IOMode.immediate : IOMode.once;

		bool cancelled;
		IOStatus status;
		size_t nbytes;

		alias waiter = Waitable!(IOCallback,
			cb => eventDriver.sockets.read(m_socket, m_context.readBuffer.peekDst(), mode, cb),
			(cb) { cancelled = true; eventDriver.sockets.cancelRead(m_socket); },
			(sock, st, nb) {
				if (m_socket == StreamSocketFD.invalid) {
					cancelled = true;
					return;
				}
				assert(sock == m_socket); status = st; nbytes = nb;
			}
		);

		asyncAwaitAny!(true, waiter)(timeout);

		if (!m_context) return WaitForDataStatus.noMoreData;
		if (cancelled) return WaitForDataStatus.timeout;

		logTrace("Socket %s, read %s bytes: %s", m_socket, nbytes, status);

		assert(m_context.readBuffer.length == 0);
		m_context.readBuffer.putN(nbytes);
		switch (status) {
			default:
				logDebug("Error status when waiting for data: %s", status);
				break;
			case IOStatus.ok: break;
			case IOStatus.wouldBlock: assert(mode == IOMode.immediate); break;
			case IOStatus.disconnected: break;
		}

		return m_context.readBuffer.length > 0 ? WaitForDataStatus.dataAvailable : WaitForDataStatus.noMoreData;
	}


	/** Waits asynchronously for new data to arrive.

		This function can be used to detach the `TCPConnection` from a
		running task while waiting for data, so that the associated memory
		resources are available for other operations.

		Note that `read_ready_callback` may be called from outside of a
		task, so no blocking operations may be performed. Instead, an existing
		task should be notified, or a new one started with `runTask`.

		Params:
			read_ready_callback = A callback taking a `bool` parameter that
				signals the read-readiness of the connection
			timeout = Optional timeout to limit the maximum wait time

		Returns:
			If the read readiness can be determined immediately, it will be
			returned as `WaitForDataAsyncStatus.dataAvailable` or
			`WaitForDataAsyncStatus.noModeData` and the callback will not be
			invoked. Otherwise `WaitForDataAsyncStatus.waiting` is returned
			and the callback will be invoked once the status can be
			determined or the specified timeout is reached.
	*/
	WaitForDataAsyncStatus waitForDataAsync(CALLABLE)(CALLABLE read_ready_callback, Duration timeout = Duration.max)
		if (is(typeof(() @safe { read_ready_callback(true); } ())))
	{
mixin(tracer);
		import vibe.core.core : Timer, setTimer;

		if (!m_context)
			return WaitForDataAsyncStatus.noMoreData;

		if (m_context.readBuffer.length > 0)
			return WaitForDataAsyncStatus.dataAvailable;

		if (timeout <= 0.seconds) {
			auto rs = waitForData(0.seconds);
			return rs ? WaitForDataAsyncStatus.dataAvailable : WaitForDataAsyncStatus.noMoreData;
		}

		static final class WaitContext {
			import std.algorithm.mutation : move;

			CALLABLE callback;
			TCPConnection connection;
			Timer timer;

			this(CALLABLE callback, TCPConnection connection, Duration timeout)
			{
				this.callback = callback;
				this.connection = connection;
				if (timeout < Duration.max)
					this.timer = setTimer(timeout, &onTimeout);
			}

			void onTimeout()
			{
				eventDriver.sockets.cancelRead(connection.m_socket);
				invoke(false);
			}

			void onData(StreamSocketFD, IOStatus st, size_t nb)
			{
				if (timer) timer.stop();
				assert(connection.m_context.readBuffer.length == 0);
				connection.m_context.readBuffer.putN(nb);
				invoke(connection.m_context.readBuffer.length > 0);
			}

			void invoke(bool status)
			{
				auto cb = move(callback);
				connection = TCPConnection.init;
				timer = Timer.init;
				cb(status);
			}
		}

		// FIXME: make this work without a heap allocation!
		auto context = new WaitContext(read_ready_callback, this, timeout);

		eventDriver.sockets.read(m_socket, m_context.readBuffer.peekDst(),
			IOMode.once, &context.onData);

		return WaitForDataAsyncStatus.waiting;
	}

	const(ubyte)[] peek() { return m_context ? m_context.readBuffer.peek() : null; }

	void skip(ulong count)
	{
		import std.algorithm.comparison : min;

		m_context.readTimeout.loopWithTimeout!((remaining) {
			waitForData(remaining);
			auto n = min(count, m_context.readBuffer.length);
			m_context.readBuffer.popFrontN(n);
			count -= n;
			return count == 0;
		}, ReadTimeoutException);
	}

	size_t read(scope ubyte[] dst, IOMode mode)
	{
mixin(tracer);
		import std.algorithm.comparison : min;
		if (!dst.length) return 0;
		if (m_context.readBuffer.length >= dst.length) {
			m_context.readBuffer.read(dst);
			return dst.length;
		}
		size_t nbytes = 0;
		m_context.readTimeout.loopWithTimeout!((remaining) {
			if (m_context.readBuffer.length == 0) {
				if (mode == IOMode.immediate || mode == IOMode.once && nbytes > 0)
					return true;
				enforce(waitForData(remaining), "Reached end of stream while reading data.");
			}
			assert(m_context.readBuffer.length > 0);
			auto l = min(dst.length, m_context.readBuffer.length);
			m_context.readBuffer.read(dst[0 .. l]);
			dst = dst[l .. $];
			nbytes += l;
			return dst.length == 0;
		}, ReadTimeoutException);
		return nbytes;
	}

	void read(scope ubyte[] dst) { auto r = read(dst, IOMode.all); assert(r == dst.length); }

	size_t write(in ubyte[] bytes, IOMode mode)
	{
mixin(tracer);
		if (bytes.length == 0) return 0;

		auto res = asyncAwait!(IOCallback,
			cb => eventDriver.sockets.write(m_socket, bytes, mode, cb),
			cb => eventDriver.sockets.cancelWrite(m_socket));

		switch (res[1]) {
			default:
				throw new Exception("Error writing data to socket.");
			case IOStatus.ok:
				assert(mode != IOMode.all || res[2] == bytes.length);
				break;
			case IOStatus.disconnected:
				if (mode == IOMode.all && res[2] != bytes.length)
					throw new Exception("Connection closed while writing data.");
				break;
		}

		return res[2];
	}

	void write(in ubyte[] bytes) { auto r = write(bytes, IOMode.all); assert(r == bytes.length); }
	void write(in char[] bytes) { write(cast(const(ubyte)[])bytes); }
	void write(InputStream stream) { write(stream, 0); }

	void flush() {
mixin(tracer);
	}
	void finalize() {}
	void write(InputStream)(InputStream stream, ulong nbytes = 0) if (isInputStream!InputStream) { writeDefault(stream, nbytes); }

	private void writeDefault(InputStream)(InputStream stream, ulong nbytes = 0)
		if (isInputStream!InputStream)
	{
		import std.algorithm.comparison : min;
		import vibe.internal.allocator : theAllocator, makeArray, dispose;

		scope buffer = () @trusted { return cast(ubyte[]) theAllocator.allocate(64*1024); }();
		scope (exit) () @trusted { theAllocator.dispose(buffer); }();

		//logTrace("default write %d bytes, empty=%s", nbytes, stream.empty);
		if( nbytes == 0 ){
			while( !stream.empty ){
				size_t chunk = min(stream.leastSize, buffer.length);
				assert(chunk > 0, "leastSize returned zero for non-empty stream.");
				//logTrace("read pipe chunk %d", chunk);
				stream.read(buffer[0 .. chunk]);
				write(buffer[0 .. chunk]);
			}
		} else {
			while( nbytes > 0 ){
				size_t chunk = min(nbytes, buffer.length);
				//logTrace("read pipe chunk %d", chunk);
				stream.read(buffer[0 .. chunk]);
				write(buffer[0 .. chunk]);
				nbytes -= chunk;
			}
		}
	}
}

/** Represents possible return values for
	TCPConnection.waitForDataAsync.
*/
enum WaitForDataAsyncStatus {
	noMoreData,
	dataAvailable,
	waiting,
}

enum WaitForDataStatus {
	dataAvailable,
	noMoreData,
	timeout
}

unittest { // test compilation of callback with scoped destruction
	static struct CB {
		~this() {}
		this(this) {}
		void opCall(bool) {}
	}

	void test() {
		TCPConnection c;
		CB cb;
		c.waitForDataAsync(cb);
	}
}


mixin validateConnectionStream!TCPConnection;

private void loopWithTimeout(alias LoopBody, ExceptionType = Exception)(Duration timeout,
	immutable string timeoutMsg = "Operation timed out.")
{
	import core.time : seconds, MonoTime;

	MonoTime now;
	if (timeout != Duration.max)
		now = MonoTime.currTime();

	do {
		if (LoopBody(timeout))
			return;

		if (timeout != Duration.max) {
			auto prev = now;
			now = MonoTime.currTime();
			if (now > prev) timeout -= now - prev;
		}
	} while (timeout > 0.seconds);

	throw new ExceptionType(timeoutMsg);
}


/**
	Represents a listening TCP socket.
*/
struct TCPListener {
	// FIXME: copying may lead to dangling FDs - this somehow needs to employ reference counting without breaking
	//        the previous behavior of keeping the socket alive when the listener isn't stored. At the same time,
	//        stopListening() needs to keep working.
	private {
		static struct Context {
			shared(NativeEventDriver) driver;
		}

		StreamListenSocketFD m_socket;
		Context* m_context;
	}

	this(StreamListenSocketFD socket)
	{
		m_socket = socket;
		m_context = () @trusted { return &eventDriver.sockets.userData!Context(m_socket); } ();
		m_context.driver = () @trusted { return cast(shared)eventDriver; } ();
	}

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_socket != StreamListenSocketFD.invalid; }

	/// The local address at which TCP connections are accepted.
	@property NetworkAddress bindAddress()
	{
		NetworkAddress ret;
		scope ra = new RefAddress(ret.sockAddr, ret.sockAddrMaxLen);
		enforce(eventDriver.sockets.getLocalAddress(m_socket, ra),
			"Failed to query bind address of listening socket.");
		return ret;
	}

	/// Stops listening and closes the socket.
	void stopListening()
	{
		if (m_socket != StreamListenSocketFD.invalid) {
			releaseHandle!"sockets"(m_socket, m_context.driver);
			m_socket = StreamListenSocketFD.invalid;
		}
	}
}


/**
	Represents a bound and possibly 'connected' UDP socket.
*/
struct UDPConnection {
	static struct Context {
		bool canBroadcast;
		shared(NativeEventDriver) driver;
	}

	private {
		DatagramSocketFD m_socket;
		Context* m_context;
	}

	private this(ref NetworkAddress bind_address)
	{
		scope baddr = new RefAddress(bind_address.sockAddr, bind_address.sockAddrLen);
		m_socket = eventDriver.sockets.createDatagramSocket(baddr, null);
		enforce(m_socket != DatagramSocketFD.invalid, "Failed to create datagram socket.");
		m_context = () @trusted { return &eventDriver.sockets.userData!Context(m_socket); } ();
		m_context.driver = () @trusted { return cast(shared)eventDriver; } ();
	}


	this(this)
	nothrow {
		if (m_socket != DatagramSocketFD.invalid)
			eventDriver.sockets.addRef(m_socket);
	}

	~this()
	nothrow {
		if (m_socket != DatagramSocketFD.invalid)
			releaseHandle!"sockets"(m_socket, m_context.driver);
	}

	bool opCast(T)() const nothrow if (is(T == bool)) { return m_socket != DatagramSocketFD.invalid; }

	/** Returns the address to which the UDP socket is bound.
	*/
	@property string bindAddress() const { return localAddress.toString(); }

	/** Determines if the socket is allowed to send to broadcast addresses.
	*/
	@property bool canBroadcast() const { return m_context.canBroadcast; }
	/// ditto
	@property void canBroadcast(bool val) { enforce(eventDriver.sockets.setBroadcast(m_socket, val), "Failed to set UDP broadcast flag."); m_context.canBroadcast = val; }

	/// The local/bind address of the underlying socket.
	@property NetworkAddress localAddress() const nothrow {
		NetworkAddress naddr;
		scope addr = new RefAddress(naddr.sockAddr, naddr.sockAddrMaxLen);
		try {
			enforce(eventDriver.sockets.getLocalAddress(m_socket, addr), "Failed to query socket address.");
		} catch (Exception e) { logWarn("Failed to get local address for TCP connection: %s", e.msg); }
		return naddr;
	}

	/** Set IP multicast loopback mode.

		This is on by default. All packets send will also loopback if enabled.
		Useful if more than one application is running on same host and both need each other's packets.
	*/
	@property void multicastLoopback(bool loop)
	{
		enforce(eventDriver.sockets.setOption(m_socket, DatagramSocketOption.multicastLoopback, loop),
			"Failed to set multicast loopback mode.");
	}

	/** Become a member of an IP multicast group.

		The multiaddr parameter should be in the range 239.0.0.0-239.255.255.255.
		See https://www.iana.org/assignments/multicast-addresses/multicast-addresses.xml#multicast-addresses-12
		and https://www.iana.org/assignments/ipv6-multicast-addresses/ipv6-multicast-addresses.xhtml
	*/
	void addMembership(ref NetworkAddress multiaddr, uint interface_index = 0)
	{
		scope addr = new RefAddress(multiaddr.sockAddr, multiaddr.sockAddrMaxLen);
		enforce(eventDriver.sockets.joinMulticastGroup(m_socket, addr, interface_index),
			"Failed to add multicast membership.");
	}

	/** Stops listening for datagrams and frees all resources.
	*/
	void close()
	{
		if (m_socket != DatagramSocketFD.invalid) {
			releaseHandle!"sockets"(m_socket, m_context.driver);
			m_socket = DatagramSocketFD.init;
			m_context = null;
		}
	}

	/** Locks the UDP connection to a certain peer.

		Once connected, the UDPConnection can only communicate with the specified peer.
		Otherwise communication with any reachable peer is possible.
	*/
	void connect(string host, ushort port)
	{
		auto address = resolveHost(host);
		address.port = port;
		connect(address);
	}
	/// ditto
	void connect(NetworkAddress address)
	{
		scope addr = new RefAddress(address.sockAddr, address.sockAddrLen);
		eventDriver.sockets.setTargetAddress(m_socket, addr);
	}

	/** Sends a single packet.

		If peer_address is given, the packet is send to that address. Otherwise the packet
		will be sent to the address specified by a call to connect().
	*/
	void send(in ubyte[] data, in NetworkAddress* peer_address = null)
	{
		scope addrc = new RefAddress;
		if (peer_address)
			addrc.set(() @trusted { return (cast(NetworkAddress*)peer_address).sockAddr; } (), peer_address.sockAddrLen);

		IOStatus status;
		size_t nbytes;
		bool cancelled;

		alias waitable = Waitable!(DatagramIOCallback,
			cb => eventDriver.sockets.send(m_socket, data, IOMode.once, peer_address ? addrc : null, cb),
			(cb) { cancelled = true; eventDriver.sockets.cancelSend(m_socket); },
			(DatagramSocketFD, IOStatus status_, size_t nbytes_, scope RefAddress addr)
			{
				status = status_;
				nbytes = nbytes_;
			}
		);

		asyncAwaitAny!(true, waitable);

		enforce(!cancelled && status == IOStatus.ok, "Failed to send packet.");
		enforce(nbytes == data.length, "Packet was only sent partially.");
	}

	/** Receives a single packet.

		If a buffer is given, it must be large enough to hold the full packet.

		The timeout overload will throw an Exception if no data arrives before the
		specified duration has elapsed.
	*/
	ubyte[] recv(ubyte[] buf = null, NetworkAddress* peer_address = null)
	{
		return recv(Duration.max, buf, peer_address);
	}
	/// ditto
	ubyte[] recv(Duration timeout, ubyte[] buf = null, NetworkAddress* peer_address = null)
	{
		import std.socket : Address;
		if (buf.length == 0) buf = new ubyte[65536];

		IOStatus status;
		size_t nbytes;
		bool cancelled;

		alias waitable = Waitable!(DatagramIOCallback,
			cb => eventDriver.sockets.receive(m_socket, buf, IOMode.once, cb),
			(cb) { cancelled = true; eventDriver.sockets.cancelReceive(m_socket); },
			(DatagramSocketFD, IOStatus status_, size_t nbytes_, scope RefAddress addr)
			{
				status = status_;
				nbytes = nbytes_;
				if (status_ == IOStatus.ok && peer_address) {
					try *peer_address = NetworkAddress(addr);
					catch (Exception e) logWarn("Failed to store datagram source address: %s", e.msg);
				}
			}
		);

		asyncAwaitAny!(true, waitable)(timeout);
		enforce(!cancelled, "Receive timeout.");
		enforce(status == IOStatus.ok, "Failed to receive packet.");
		return buf[0 .. nbytes];
	}
}


/**
	Flags to control the behavior of listenTCP.
*/
enum TCPListenOptions {
	/// Don't enable any particular option
	none = 0,
	/// Deprecated: causes incoming connections to be distributed across the thread pool
	distribute = 1<<0,
	/// Disables automatic closing of the connection when the connection callback exits
	disableAutoClose = 1<<1,
	/** Enable port reuse on linux kernel version >=3.9, do nothing on other OS
		Does not affect libasync driver because it is always enabled by libasync.
	*/
	reusePort = 1<<2,
	/// Enable address reuse
	reuseAddress = 1<<3,
	///
	defaults = reuseAddress
}

private pure nothrow {
	import std.bitmanip;

	ushort ntoh(ushort val)
	{
		version (LittleEndian) return swapEndian(val);
		else version (BigEndian) return val;
		else static assert(false, "Unknown endianness.");
	}

	ushort hton(ushort val)
	{
		version (LittleEndian) return swapEndian(val);
		else version (BigEndian) return val;
		else static assert(false, "Unknown endianness.");
	}
}

private enum tracer = "";


/// Thrown by TCPConnection read-alike operations when timeout is reached.
class ReadTimeoutException: Exception
{
	@safe pure nothrow this(string message,
							Throwable next,
							string file =__FILE__,
							size_t line = __LINE__)
	{
		super(message, next, file, line);
	}

	@safe pure nothrow this(string message,
							string file =__FILE__,
							size_t line = __LINE__,
							Throwable next = null)
	{
		super(message, file, line, next);
	}
}


// check whether the given name is not a valid host name, but may instead
// be a valid IP address. This is used as a quick check to avoid
// unnecessary address parsing or DNS queries
private bool isMaybeIPAddress(in char[] name)
{
	import std.algorithm.searching : all, canFind;
	import std.ascii : isDigit;

	// could be an IPv6 address, but ':' is invalid in host names
	if (name.canFind(':')) return true;

	// an IPv4 address is at least 7 characters (0.0.0.0)
	if (name.length < 7) return false;

	// no valid TLD consists of only digits
	return name.canFind('.') && name.all!(ch => ch.isDigit || ch == '.');
}

unittest {
	assert(isMaybeIPAddress("0.0.0.0"));
	assert(isMaybeIPAddress("::1"));
	assert(isMaybeIPAddress("aabb::1f"));
	assert(!isMaybeIPAddress("example.com"));
	assert(!isMaybeIPAddress("12.com"));
	assert(!isMaybeIPAddress("1.1.1.t12"));
}
