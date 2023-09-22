import vibe.core.core : runApplication;
import vibe.core.log;
import vibe.core.net;
import vibe.core.stream : pipe;


version(READ_WRITE)
{
	import std.exception;
	import std.datetime;
	import std.stdio;
	
	scope const(ubyte[]) readTcpOnce(ref TCPConnection stream,scope ubyte[] dst){
		ubyte[] ret = null;
        auto e = collectException!ReadTimeoutException({
			import eventcore.driver : IOMode;
			auto len = stream.read(dst, IOMode.once);
			if(len == 0)
				return null;
			else
				return dst[0..len];
        }(),ret);
		if(e)
			collectException({writeln(e.msg);}());
        return ret;
	}

	void handleTcp(ref TCPConnection stream) @trusted nothrow {
		auto e = collectException({
			stream.readTimeout = dur!"seconds"(30);
			ubyte[] buffer = new ubyte[2048];
			while(stream.connected){
				auto tmp = stream.readTcpOnce(buffer);
				if(tmp is null){
					writefln("[%s] read time out!",
        			Clock.currTime);
				} else {
					stream.write(tmp);
				}
			}
		}());
		if(e)
			collectException({writeln(e.msg);}());
	}
	void main()
	{
		auto listeners = listenTCP(7000,  (conn) @safe nothrow {handleTcp(conn);});

		// closes the listening sockets
		scope (exit) 
			foreach (l; listeners)
				l.stopListening();

		runApplication();
	}
} else {
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
}


