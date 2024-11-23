/+ dub.sdl:
	dependency "vibe-core" path=".."
+/
module test;

import vibe.core.file;


// this test ensures that leaking an open FileStream will not crash the
// application
void main()
{
	auto fil = new FileStream;
	*fil = openFile("test.tmp", FileMode.createTrunc);
	fil = null;

	ubyte[] arr;
	foreach (i; 0 .. 1000)
		arr ~= "1234567890";
}
