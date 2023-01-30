/+ dub.sdl:
	name "tests"
	description "Invalid ref count after runTask"
	dependency "vibe-core" path="../"
+/
module test;
import vibe.core.core;
import std.stdio;

struct RC {
	int* rc;
	this(int* rc) nothrow { this.rc = rc; }
	this(this) nothrow {
		if (rc) {
			(*rc)++;
			try writefln("addref %s", *rc);
			catch (Exception e) assert(false, e.msg);
		}
	}
	~this() nothrow {
		if (rc) {
			(*rc)--;
			try writefln("release %s", *rc);
			catch (Exception e) assert(false, e.msg);
		}
	}
}

void main()
{
	int rc = 1;
	bool done = false;

	{
		auto s = RC(&rc);
		assert(rc == 1);
		runTask((RC st) nothrow {
			assert(rc == 2);
			st = RC.init;
			assert(rc == 1);
			exitEventLoop();
			done = true;
		}, s);
		assert(rc == 2);
	}

	assert(rc == 1);

	runEventLoop();

	assert(rc == 0);
	assert(done);
}
