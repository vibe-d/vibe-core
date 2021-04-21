/+ dub.sdl:
	name "tests"
	dependency "vibe-core" path=".."
+/
module tests;
import core.time, vibe.core.core, vibe.core.process;

void main()
{
    auto p = pipe();
    runTask(()
    {
        sleep(10.msecs);
        exitEventLoop();
    });
    runEventLoop();
}
