/+ dub.sdl:
	name "tests"
	dependency "vibe-core" path=".."
+/
module tests;
import core.time, vibe.core.core, vibe.core.process;

void main()
{
	version (Windows) {
		import vibe.core.log : logInfo;
		logInfo("Skipping pipe test on Windows");
	} else {
		auto p = pipe();
		runTask(()
		{
			sleep(10.msecs);
			exitEventLoop();
		});
		runEventLoop();
	}
}
