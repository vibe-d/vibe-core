module vibe.internal.allocator;

public import std.experimental.allocator;
public import std.experimental.allocator.building_blocks.allocator_list;
public import std.experimental.allocator.building_blocks.null_allocator;
public import std.experimental.allocator.building_blocks.region;
public import std.experimental.allocator.building_blocks.stats_collector;
public import std.experimental.allocator.gc_allocator;
public import std.experimental.allocator.mallocator;

alias VibeAllocator = RCIAllocator;

@property VibeAllocator vibeThreadAllocator()
@safe nothrow @nogc {
	return theAllocator();
}

auto makeGCSafe(T, Allocator, A...)(Allocator allocator, A args)
{
	import core.memory : GC;
	import std.traits : hasIndirections;

	auto ret = allocator.make!T(args);
	static if (is (T == class)) enum tsize = __traits(classInstanceSize, T);
	else enum tsize = T.sizeof;
	static if (hasIndirections!T)
		() @trusted { GC.addRange(cast(void*)ret, tsize, typeid(T)); } ();
	return ret;
}

void disposeGCSafe(T, Allocator)(Allocator allocator, T obj)
{
	import core.memory : GC;
	import std.traits : hasIndirections;

	static if (hasIndirections!T)
		GC.removeRange(cast(void*)obj);
	allocator.dispose(obj);
}

void ensureNotInGC(T)(string info = null) nothrow
{
    import core.exception : InvalidMemoryOperationError;
    try
    {
        import core.memory : GC;
        cast(void) GC.malloc(1);
        return;
    }
    catch(InvalidMemoryOperationError e)
    {
        import core.stdc.stdio : fprintf, stderr;
        import core.stdc.stdlib : exit;
        fprintf(stderr,
                "Error: clean-up of %s incorrectly depends on destructors called by the GC.\n",
                T.stringof.ptr);
        if (info)
            fprintf(stderr, "Info: %s\n", info.ptr);
        assert(false);
    }
}
