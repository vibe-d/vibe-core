import vibe.core.core : runApplication;
import vibe.core.log;
import vibe.core.net : listenTCP;
import vibe.core.stream : pipe;

void main()
{
	auto listeners = listenTCP(7000, (conn) @safe nothrow {
			try pipe(conn, conn);
			catch (Exception e)
				logError("Error: %s", e.msg);
	});

	// closes the listening sockets
	scope (exit)
		foreach (l; listeners)
			l.stopListening();

	runApplication();
}
