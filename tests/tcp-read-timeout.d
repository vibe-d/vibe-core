module tests;

import vibe.core.core ;
import vibe.core.log;
import vibe.core.net;
import vibe.core.stream : pipe;


import std.exception;
import std.datetime;
import std.stdio;
import std.datetime.stopwatch;
import  std.algorithm.comparison;
import eventcore.driver : IOMode;



scope const(ubyte[]) readTcpOnce(ref TCPConnection stream,scope ubyte[] dst){
    ubyte[] ret = null;
    auto sw = StopWatch(AutoStart.yes);
    auto e = collectException!ReadTimeoutException({
        auto len = stream.read(dst, IOMode.once);
        if(len == 0)
            return null;
        else
            return dst[0..len];
    }(),ret);
    sw.stop();
    if(e) {
        long msecs = sw.peek.total!"msecs";
        collectException({logInfo("%d : %s ",msecs,e.msg);}());
        if(msecs < 500){
             logError("Test failed:read time out should >= timeout time : %d", msecs);
        }
    }

    return ret;
}

void handleTcp(ref TCPConnection stream) @trusted nothrow {
    auto e = collectException({
        stream.readTimeout = dur!"msecs"(500);
        ubyte[] buffer = new ubyte[2048];
        while(stream.connected){
            auto tmp = stream.readTcpOnce(buffer);
            if(tmp !is null){
                if(cmp(tmp,"end") == 0){
                    stream.close();
                    break;
                }
                stream.write(tmp);
            }
        }
    }());
    if(e){
        logError("Test failed:read not should has other exception : %s", e.toString());
    }
}
void main()
{
    auto listeners = listenTCP(17000,  (conn) @safe nothrow {handleTcp(conn);});

    // closes the listening sockets
    scope (exit)
        foreach (l; listeners)
            l.stopListening();

    runTask(() @trusted
    {
        collectExceptionMsg({
        // sleep one seconds let server start
            sleep(dur!"seconds"(1));
            ubyte[] buffer = new ubyte[512];
            auto client = connectTCP("127.0.0.1",17000);
            assert(client.connected,"connect server error!");
            auto send = "hello word";
            client.write(send);
            auto readed = client.read(buffer,IOMode.once);
            auto tmp = buffer[0..readed];
            if(cmp(tmp,send) != 0){
                logError("Test failed: client read echo error!");
            }
            sleep(dur!"seconds"(5));
            client.write("end");
            sleep(dur!"msecs"(800));
        }());
        
        exitEventLoop();
        // writeln("connect tcp ----2222 exit tt 2-!");
    });
    runEventLoop();
}
