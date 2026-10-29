/+ dub.sdl:
	name "test"
	dependency "vibe-core" path=".."
+/
module test;

import core.time: msecs, seconds;

import vibe.core.core: runTask, sleep;
import vibe.core.net: TCPConnection, connectTCP, listenTCP;
import vibe.core.stream: ConnectionStream;
import vibe.internal.interfaceproxy: InterfaceProxy, interfaceProxy;

void main()
{
	// keep the accepted side open, so that the only event that can complete
	// the pending read is the close below
	TCPConnection accepted;
	auto listener = listenTCP(0, (TCPConnection conn) nothrow { accepted = conn; }, "127.0.0.1");
	scope (exit) listener.stopListening();
	scope (exit) accepted.close();

	auto client = connectTCP("127.0.0.1", listener.bindAddress.port);
	auto connection = interfaceProxy!ConnectionStream(client);

	// pass a pointer, so that the task reads the very same storage that gets
	// destroyed below and not a reference-counted copy
	auto reader = runTask(&waitForClose, &connection);

	// let the reader park in the pending socket read
	sleep(100.msecs);

	// close the connection and then destroy it while the completion that the
	// close triggered is still in flight
	connection.close();
	connection = InterfaceProxy!ConnectionStream.init;

	reader.joinUninterruptible();
}

private void waitForClose(InterfaceProxy!ConnectionStream* connection) @safe nothrow
{
	try {
		// no data can arrive before the close, and the close means "no more
		// data", so either return value is fine as long as it does not abort
		(*connection).waitForData(10.seconds);
	} catch (Exception e) {
		assert(false, e.msg);
	}
}
