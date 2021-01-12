/+ dub.sdl:
	name "test"
	dependency "vibe-core" path=".."
+/
module test;

import vibe.core.file;
import std.exception;

enum ubyte[] bytes(BYTES...) = [BYTES];

void main()
{
	auto f = openFile("têst.dat", FileMode.createTrunc);
	assert(f.size == 0);
	assert(f.tell == 0);
	f.write(bytes!(1, 2, 3, 4, 5));
	assert(f.size == 5);
	assert(f.tell == 5);
	f.seek(0);
	assert(f.tell == 0);
	f.write(bytes!(1, 2, 3, 4, 5));
	assert(f.size == 5);
	assert(f.tell == 5);
	f.write(bytes!(6, 7, 8, 9, 10));
	assert(f.size == 10);
	assert(f.tell == 10);
	ubyte[5] dst;
	f.seek(2);
	assert(f.tell == 2);
	f.read(dst);
	assert(f.tell == 7);
	assert(dst[] == bytes!(3, 4, 5, 6, 7));
	f.close();

	auto fi = getFileInfo("têst.dat");
	assert(fi.name == "têst.dat");
	assert(fi.isFile);
	assert(!fi.isDirectory);
	assert(!fi.isSymlink);
	assert(!fi.hidden);
	assert(fi.size == 10);

	assertThrown(getFileInfo("*impossible:file?"));

	bool found = false;
	listDirectory(".", (fi) {
		if (fi.name != "têst.dat") return true;
		assert(fi.isFile);
		assert(!fi.isDirectory);
		assert(!fi.isSymlink);
		assert(!fi.hidden);
		assert(fi.size == 10);
		found = true;
		return true;
	});
	assert(found, "listDirectory did not find test file.");

	removeFile("têst.dat");
}
