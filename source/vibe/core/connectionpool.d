/**
	Generic connection pool for reusing persistent connections across fibers.

	Copyright: © 2012-2016 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.connectionpool;

import vibe.core.log;

import core.thread;
import vibe.core.sync;
import vibe.internal.freelistref;

/**
	Generic connection pool class.

	The connection pool is creating connections using the supplied factory
	function as needed whenever `lockConnection` is called. Connections are
	associated to the calling fiber, as long as any copy of the returned
	`LockedConnection` object still exists. Connections that are not associated
	to any fiber will be kept in a pool of open connections for later reuse.

	Note that, after retrieving a connection with `lockConnection`, the caller
	has to make sure that the connection is actually physically open and to
	reopen it if necessary. The `ConnectionPool` class has no knowledge of the
	internals of the connection objects.
*/
final class ConnectionPool(Connection)
{
	private {
		Connection delegate() @safe m_connectionFactory;
		Connection[] m_connections;
		int[const(Connection)] m_lockCount;
		FreeListRef!LocalTaskSemaphore m_sem;
		debug Thread m_thread;
	}

	this(Connection delegate() @safe connection_factory, uint max_concurrent = uint.max)
	{
		m_connectionFactory = connection_factory;
		() @trusted { m_sem = FreeListRef!LocalTaskSemaphore(max_concurrent); } ();
		debug m_thread = () @trusted { return Thread.getThis(); } ();
	}

	deprecated("Use an @safe callback instead")
	this(Connection delegate() connection_factory, uint max_concurrent = uint.max)
	@system {
		this(cast(Connection delegate() @safe)connection_factory, max_concurrent);
	}

	/** Determines the maximum number of concurrently open connections.

		Attempting to lock more connections that this number will cause the
		calling fiber to be blocked until one of the locked connections
		becomes available for reuse.
	*/
	@property void maxConcurrency(uint max_concurrent) {
		m_sem.maxLocks = max_concurrent;
	}
	/// ditto
	@property uint maxConcurrency() nothrow {
		return m_sem.maxLocks;
	}

	/** Retrieves a connection to temporarily associate with the calling fiber.

		The returned `LockedConnection` object uses RAII and reference counting
		to determine when to unlock the connection.
	*/
	LockedConnection!Connection lockConnection()
	@safe {
		debug assert(m_thread is () @trusted { return Thread.getThis(); } (), "ConnectionPool was called from a foreign thread!");

		() @trusted { m_sem.lock(); } ();
		scope (failure) () @trusted { m_sem.unlock(); } ();

		size_t cidx = size_t.max;
		foreach( i, c; m_connections ){
			auto plc = c in m_lockCount;
			if( !plc || *plc == 0 ){
				cidx = i;
				break;
			}
		}

		Connection conn;
		if( cidx != size_t.max ){
			logTrace("returning %s connection %d of %d", Connection.stringof, cidx, m_connections.length);
			conn = m_connections[cidx];
		} else {
			logDebug("creating new %s connection, all %d are in use", Connection.stringof, m_connections.length);
			conn = m_connectionFactory(); // NOTE: may block
			static if (is(typeof(cast(void*)conn)))
				logDebug(" ... %s", () @trusted { return cast(void*)conn; } ());
		}
		m_lockCount[conn] = 1;
		if( cidx == size_t.max ){
			m_connections ~= conn;
			logDebug("Now got %d connections", m_connections.length);
		}
		auto ret = LockedConnection!Connection(this, conn);
		return ret;
	}

	/** Removes all currently unlocked connections from the pool.

		Params:
			disconnect_callback = Gets called for every removed connection to
				allow closing connections and freeing associated resources.
	*/
	void removeUnused(scope void delegate(Connection conn) @safe nothrow disconnect_callback)
	{
		Connection[] remaining_conns, removed_conns;
		foreach (c; m_connections) {
			if (m_lockCount.get(c, 0) > 0)
				remaining_conns ~= c;
			else
				removed_conns ~= c;
		}

		m_connections = remaining_conns;

		foreach (c; removed_conns)
			disconnect_callback(c);
	}

	/** Removes an existing connection from the pool
		It can be called with a locked connection, same connection
		can be added back to the pool anytime. Any fibers that hold
		a lock on this connection will keep behaving as expected.

		Params:
			conn = connection to remove from the pool
	*/
	void remove(Connection conn) @safe
	{
		foreach (idx, c; m_connections)
			if (c is conn)
			{
				m_connections = m_connections[0 .. idx] ~ m_connections[idx + 1 .. $];
				auto plc = conn in m_lockCount;
				assert(plc !is null);
				assert(*plc >= 0);
				if (*plc > 0)
					*plc *= -1; // invert the plc to signal LockedConnection that this connection is no longer in the pool
				else
					m_lockCount.remove(conn);
				return;
			}
		assert(0, "Removing non existing conn");
	}

	/** Add a connection to the pool explicitly

		Params:
			conn = new connection to add to the pool

		Returns:
			success/failure
	*/
	bool add(Connection conn) @safe nothrow
	{
		if (m_connections.length < this.maxConcurrency)
		{
			auto plc = conn in m_lockCount;
			if (plc is null)
				m_lockCount[conn] = 0;
			else if (*plc < 0)
				*plc *= -1; // invert the plc back to positive
			m_connections ~= conn;
			return true;
		}
		return false;
	}
}

///
unittest {
	class Connection {
		void write() {}
	}

	auto pool = new ConnectionPool!Connection({
		return new Connection; // perform the connection here
	});

	// create and lock a first connection
	auto c1 = pool.lockConnection();
	c1.write();

	// create and lock a second connection
	auto c2 = pool.lockConnection();
	c2.write();

	// writing to c1 will still write to the first connection
	c1.write();

	// free up the reference to the first connection, so that it can be reused
	destroy(c1);

	// locking a new connection will reuse the first connection now instead of creating a new one
	auto c3 = pool.lockConnection();
	c3.write();
}

unittest { // issue vibe-d#2109
	import vibe.core.net : TCPConnection, connectTCP;
	new ConnectionPool!TCPConnection({ return connectTCP("127.0.0.1", 8080); });
}

unittest { // removeUnused
	class Connection {}

	auto pool = new ConnectionPool!Connection({
		return new Connection; // perform the connection here
	});

	auto c1 = pool.lockConnection();
	auto c1i = c1.__conn;

	auto c2 = pool.lockConnection();
	auto c2i = c2.__conn;


	assert(pool.m_connections == [c1i, c2i]);

	c2 = LockedConnection!Connection.init;
	pool.removeUnused((c) { assert(c is c2i); });
	assert(pool.m_connections == [c1i]);

	c1 = LockedConnection!Connection.init;
	pool.removeUnused((c) { assert(c is c1i); });
	assert(pool.m_connections == []);
}


struct LockedConnection(Connection) {
	import vibe.core.task : Task;

	private {
		ConnectionPool!Connection m_pool;
		Task m_task;
		Connection m_conn;
		debug uint m_magic = 0xB1345AC2;
	}

	@safe:

	private this(ConnectionPool!Connection pool, Connection conn)
	{
		assert(!!conn);
		m_pool = pool;
		m_conn = conn;
		m_task = Task.getThis();
	}

	this(this)
	{
		debug assert(m_magic == 0xB1345AC2, "LockedConnection value corrupted.");
		if (!!m_conn) {
			auto fthis = Task.getThis();
			assert(fthis is m_task);
			m_pool.m_lockCount[m_conn]++;
			static if (is(typeof(cast(void*)conn)))
				logTrace("conn %s copy %d", () @trusted { return cast(void*)m_conn; } (), m_pool.m_lockCount[m_conn]);
		}
	}

	~this()
	{
		debug assert(m_magic == 0xB1345AC2, "LockedConnection value corrupted.");
		if (!!m_conn) {
			auto fthis = Task.getThis();
			assert(fthis is m_task, "Locked connection destroyed in foreign task.");
			auto plc = m_conn in m_pool.m_lockCount;
			assert(plc !is null);
			assert(*plc != 0);
			//logTrace("conn %s destroy %d", cast(void*)m_conn, *plc-1);
			if( *plc > 0 && --*plc == 0 ){
				() @trusted { m_pool.m_sem.unlock(); } ();
				//logTrace("conn %s release", cast(void*)m_conn);
			}
			else if (*plc < 0 && ++*plc == 0) // connection was removed from the pool and no lock remains on it
			{
				m_pool.m_lockCount.remove(m_conn);
			}
			m_conn = Connection.init;
		}
	}


	@property int __refCount() const { return m_pool.m_lockCount.get(m_conn, 0); }
	@property inout(Connection) __conn() inout { return m_conn; }

	alias __conn this;
}

///
unittest {
	int id = 0;
	class Connection {
		public int id;
	}

	auto pool = new ConnectionPool!Connection({
		auto conn = new Connection(); // perform the connection here
		conn.id = id++;
		return conn;
	});

	// create and lock a first connection
	auto c1 = pool.lockConnection();
	assert(c1.id == 0);
	pool.remove(c1);
	destroy(c1);

	auto c2 = pool.lockConnection();
	assert(c2.id == 1); // assert that we got a new connection
	pool.remove(c2);
	pool.add(c2);
	destroy(c2);

	auto c3 = pool.lockConnection();
	assert(c3.id == 1); // should get the same connection back
}
