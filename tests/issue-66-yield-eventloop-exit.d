/+ dub.sdl:
	name "tests"
	dependency "vibe-core" path=".."
+/
module tests;

import vibe.core.core;

void main()
{
	bool visited = false;
	runTask({
		try yield();
		catch (Exception e) assert(false, e.msg);
		visited = true;
		exitEventLoop();
	});
	runApplication();
	assert(visited);
}
