/**
	Extensions to `std.traits` module of Phobos. Some may eventually make it into Phobos,
	some are dirty hacks that work only for vibe.d

	Copyright: © 2012 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig, Михаил Страшун
*/

module vibe.internal.traits;

import vibe.internal.typetuple;


/**
	Checks if given type is a getter function type

	Returns: `true` if argument is a getter
 */
template isPropertyGetter(T...)
	if (T.length == 1)
{
	import std.traits : functionAttributes, FunctionAttribute, ReturnType,
		isSomeFunction;
	static if (isSomeFunction!(T[0])) {
		enum isPropertyGetter =
			(functionAttributes!(T[0]) & FunctionAttribute.property) != 0
			&& !is(ReturnType!T == void);
	}
	else
		enum isPropertyGetter = false;
}

///
unittest
{
	interface Test
	{
		@property int getter();
		@property void setter(int);
		int simple();
	}

	static assert(isPropertyGetter!(typeof(&Test.getter)));
	static assert(!isPropertyGetter!(typeof(&Test.setter)));
	static assert(!isPropertyGetter!(typeof(&Test.simple)));
	static assert(!isPropertyGetter!int);
}

/**
	Checks if given type is a setter function type

	Returns: `true` if argument is a setter
 */
template isPropertySetter(T...)
	if (T.length == 1)
{
	import std.traits : functionAttributes, FunctionAttribute, ReturnType,
		isSomeFunction;

	static if (isSomeFunction!(T[0])) {
		enum isPropertySetter =
			(functionAttributes!(T) & FunctionAttribute.property) != 0
			&& is(ReturnType!(T[0]) == void);
	}
	else
		enum isPropertySetter = false;
}

///
unittest
{
	interface Test
	{
		@property int getter();
		@property void setter(int);
		int simple();
	}

	static assert(isPropertySetter!(typeof(&Test.setter)));
	static assert(!isPropertySetter!(typeof(&Test.getter)));
	static assert(!isPropertySetter!(typeof(&Test.simple)));
	static assert(!isPropertySetter!int);
}

/**
	Deduces single base interface for a type. Multiple interfaces
	will result in compile-time error.

	Params:
		T = interface or class type

	Returns:
		T if it is an interface. If T is a class, interface it implements.
*/
template baseInterface(T)
	if (is(T == interface) || is(T == class))
{
	import std.traits : InterfacesTuple;

	static if (is(T == interface)) {
		alias baseInterface = T;
	}
	else
	{
		alias Ifaces = InterfacesTuple!T;
		static assert (
			Ifaces.length == 1,
			"Type must be either provided as an interface or implement only one interface"
		);
		alias baseInterface = Ifaces[0];
	}
}

///
unittest
{
	interface I1 { }
	class A : I1 { }
	interface I2 { }
	class B : I1, I2 { }

	static assert (is(baseInterface!I1 == I1));
	static assert (is(baseInterface!A == I1));
	static assert (!is(typeof(baseInterface!B)));
}


/**
	Determins if a member is a public, non-static data field.
*/
template isRWPlainField(T, string M)
{
	static if (!isRWField!(T, M)) enum isRWPlainField = false;
	else {
		//pragma(msg, T.stringof~"."~M~":"~typeof(__traits(getMember, T, M)).stringof);
		enum isRWPlainField = __traits(compiles, *(&__traits(getMember, Tgen!T(), M)) = *(&__traits(getMember, Tgen!T(), M)));
	}
}

/**
	Determines if a member is a public, non-static, de-facto data field.

	In addition to plain data fields, R/W properties are also accepted.
*/
template isRWField(T, string M)
{
	import std.traits;
	import std.typetuple;

	static void testAssign()() {
		T t = void;
		__traits(getMember, t, M) = __traits(getMember, t, M);
	}

	// reject type aliases
	static if (is(TypeTuple!(__traits(getMember, T, M)))) enum isRWField = false;
	// reject non-public members
	else static if (!isPublicMember!(T, M)) enum isRWField = false;
	// reject static members
	else static if (!isNonStaticMember!(T, M)) enum isRWField = false;
	// reject non-typed members
	else static if (!is(typeof(__traits(getMember, T, M)))) enum isRWField = false;
	// reject void typed members (includes templates)
	else static if (is(typeof(__traits(getMember, T, M)) == void)) enum isRWField = false;
	// reject non-assignable members
	else static if (!__traits(compiles, testAssign!()())) enum isRWField = false;
	else static if (anySatisfy!(isSomeFunction, __traits(getMember, T, M))) {
		// If M is a function, reject if not @property or returns by ref
		private enum FA = functionAttributes!(__traits(getMember, T, M));
		enum isRWField = (FA & FunctionAttribute.property) != 0;
	} else {
		enum isRWField = true;
	}
}

unittest {
	import std.algorithm;

	struct S {
		alias a = int; // alias
		int i; // plain RW field
		enum j = 42; // manifest constant
		static int k = 42; // static field
		private int privateJ; // private RW field

		this(Args...)(Args args) {}

		// read-write property (OK)
		@property int p1() { return privateJ; }
		@property void p1(int j) { privateJ = j; }
		// read-only property (NO)
		@property int p2() { return privateJ; }
		// write-only property (NO)
		@property void p3(int value) { privateJ = value; }
		// ref returning property (OK)
		@property ref int p4() return { return i; }
		// parameter-less template property (OK)
		@property ref int p5()() { return i; }
		// not treated as a property by DMD, so not a field
		@property int p6()() { return privateJ; }
		@property void p6(int j)() { privateJ = j; }

		static @property int p7() { return k; }
		static @property void p7(int value) { k = value; }

		ref int f1() return { return i; } // ref returning function (no field)

		int f2(Args...)(Args args) { return i; }

		ref int f3(Args...)(Args args) { return i; }

		void someMethod() {}

		ref int someTempl()() { return i; }
	}

	enum plainFields = ["i"];
	enum fields = ["i", "p1", "p4", "p5"];

	foreach (mem; __traits(allMembers, S)) {
		static if (isRWField!(S, mem)) static assert(fields.canFind(mem), mem~" detected as field.");
		else static assert(!fields.canFind(mem), mem~" not detected as field.");

		static if (isRWPlainField!(S, mem)) static assert(plainFields.canFind(mem), mem~" not detected as plain field.");
		else static assert(!plainFields.canFind(mem), mem~" not detected as plain field.");
	}
}

package T Tgen(T)(){ return T.init; }


/**
	Tests if the protection of a member is public.
*/
template isPublicMember(T, string M)
{
	import std.algorithm, std.typetuple : TypeTuple;

	static if (!__traits(compiles, TypeTuple!(__traits(getMember, T, M)))) enum isPublicMember = false;
	else {
		alias MEM = TypeTuple!(__traits(getMember, T, M));
		enum isPublicMember = __traits(getProtection, MEM).among("public", "export");
	}
}

unittest {
	class C {
		int a;
		export int b;
		protected int c;
		private int d;
		package int e;
		void f() {}
		static void g() {}
		private void h() {}
		private static void i() {}
	}

	static assert (isPublicMember!(C, "a"));
	static assert (isPublicMember!(C, "b"));
	static assert (!isPublicMember!(C, "c"));
	static assert (!isPublicMember!(C, "d"));
	static assert (!isPublicMember!(C, "e"));
	static assert (isPublicMember!(C, "f"));
	static assert (isPublicMember!(C, "g"));
	static assert (!isPublicMember!(C, "h"));
	static assert (!isPublicMember!(C, "i"));

	struct S {
		int a;
		export int b;
		private int d;
		package int e;
	}
	static assert (isPublicMember!(S, "a"));
	static assert (isPublicMember!(S, "b"));
	static assert (!isPublicMember!(S, "d"));
	static assert (!isPublicMember!(S, "e"));

	S s;
	s.a = 21;
	assert(s.a == 21);
}

/**
	Tests if a member requires $(D this) to be used.
*/
template isNonStaticMember(T, string M)
{
	import std.typetuple;
	import std.traits;

	alias MF = TypeTuple!(__traits(getMember, T, M));
	static if (M.length == 0) {
		enum isNonStaticMember = false;
	} else static if (anySatisfy!(isSomeFunction, MF)) {
		enum isNonStaticMember = !__traits(isStaticFunction, MF);
	} else {
		enum isNonStaticMember = !__traits(compiles, (){ auto x = __traits(getMember, T, M); }());
	}
}

unittest { // normal fields
	struct S {
		int a;
		static int b;
		enum c = 42;
		void f();
		static void g();
		ref int h() return { return a; }
		static ref int i() { return b; }
	}
	static assert(isNonStaticMember!(S, "a"));
	static assert(!isNonStaticMember!(S, "b"));
	static assert(!isNonStaticMember!(S, "c"));
	static assert(isNonStaticMember!(S, "f"));
	static assert(!isNonStaticMember!(S, "g"));
	static assert(isNonStaticMember!(S, "h"));
	static assert(!isNonStaticMember!(S, "i"));
}

unittest { // tuple fields
	struct S(T...) {
		T a;
		static T b;
	}

	alias T = S!(int, float);
	auto p = T.b;
	static assert(isNonStaticMember!(T, "a"));
	static assert(!isNonStaticMember!(T, "b"));

	alias U = S!();
	static assert(!isNonStaticMember!(U, "a"));
	static assert(!isNonStaticMember!(U, "b"));
}


/**
	Tests if a Group of types is implicitly convertible to a Group of target types.
*/
bool areConvertibleTo(alias TYPES, alias TARGET_TYPES)()
	if (isGroup!TYPES && isGroup!TARGET_TYPES)
{
	static assert(TYPES.expand.length == TARGET_TYPES.expand.length,
		"Argument count does not match.");
	foreach (i, V; TYPES.expand)
		if (!is(V : TARGET_TYPES.expand[i]))
			return false;
	return true;
}

/// Test if the type $(D DG) is a correct delegate for an opApply where the
/// key/index is of type $(D TKEY) and the value of type $(D TVALUE).
template isOpApplyDg(DG, TKEY, TVALUE) {
	import std.traits;
	static if (is(DG == delegate) && is(ReturnType!DG : int)) {
		private alias PTT = ParameterTypeTuple!(DG);
		private alias PSCT = ParameterStorageClassTuple!(DG);
		private alias STC = ParameterStorageClass;
		// Just a value
		static if (PTT.length == 1) {
			enum isOpApplyDg = (is(PTT[0] == TVALUE));
		} else static if (PTT.length == 2) {
			enum isOpApplyDg = (is(PTT[0] == TKEY))
				&& (is(PTT[1] == TVALUE));
		} else
			enum isOpApplyDg = false;
	} else {
		enum isOpApplyDg = false;
	}
}

unittest {
	static assert(isOpApplyDg!(int delegate(int, string), int, string));
	static assert(isOpApplyDg!(int delegate(ref int, ref string), int, string));
	static assert(isOpApplyDg!(int delegate(int, ref string), int, string));
	static assert(isOpApplyDg!(int delegate(ref int, string), int, string));
}

// Synchronized statements are logically nothrow but dmd still marks them as throwing.
// DMD#4115, Druntime#1013, Druntime#1021, Phobos#2704
import core.sync.mutex : Mutex;
enum synchronizedIsNothrow = __traits(compiles, (Mutex m) nothrow { synchronized(m) {} });


/// Mixin template that checks a particular aggregate type for conformance with a specific interface.
template validateInterfaceConformance(T, I)
{
	import vibe.internal.traits : checkInterfaceConformance;
	static assert(checkInterfaceConformance!(T, I) is null, checkInterfaceConformance!(T, I));
}

/** Checks an aggregate type for conformance with a specific interface.

	The value of this template is either `null`, or an error message indicating the first method
	of the interface that is not properly implemented by `T`.
*/
template checkInterfaceConformance(T, I) {
	import std.meta : AliasSeq;
	import std.traits : FunctionAttribute, FunctionTypeOf, MemberFunctionsTuple, ParameterTypeTuple, ReturnType, functionAttributes, fullyQualifiedName;

	alias Members = AliasSeq!(__traits(allMembers, I));

	template checkMemberConformance(string mem) {
		alias Overloads = AliasSeq!(__traits(getOverloads, I, mem));
		template impl(size_t i) {
			static if (i < Overloads.length) {
				alias F = Overloads[i];
				alias FT = FunctionTypeOf!F;
				alias PT = ParameterTypeTuple!F;
				alias RT = ReturnType!F;
				enum attribs = functionAttributeString!F(true);
				static if (functionAttributes!F & FunctionAttribute.property) {
					static if (PT.length > 0) {
						static if (!is(typeof(mixin("function RT (ref T t)"~attribs~"{ return t."~mem~" = PT.init; }"))))
							enum impl = "`" ~ fullyQualifiedName!T ~ "` does not implement property setter `" ~
								mem ~ "` of type `" ~ FT.stringof ~ "` from `" ~ fullyQualifiedName!I ~ "`";
						else enum string impl = impl!(i+1);
					} else {
						static if (!is(typeof(mixin("function RT(ref T t)"~attribs~"{ return t."~mem~"; }"))))
							enum impl = "`" ~ fullyQualifiedName!T ~ "` does not implement property getter `" ~
								mem ~ "` of type `" ~ FT.stringof ~ "` from `" ~ fullyQualifiedName!I ~ "`";
						else enum string impl = impl!(i+1);
					}
				} else {
					static if (is(RT == void)) {
						static if (!is(typeof(mixin("function void(ref T t, ref PT p)"~attribs~"{ t."~mem~"(p); }")))) {
							static if (mem == "write" && PT.length == 2) {
								auto f = mixin("function void(ref T t, ref PT p)"~attribs~"{ t."~mem~"(p); }");
							}
							enum impl = "`" ~ fullyQualifiedName!T ~ "` does not implement method `" ~
								mem ~ "` of type `" ~ FT.stringof ~ "` from `" ~ fullyQualifiedName!I ~ "`";
						}
						else enum string impl = impl!(i+1);
					} else {
						static if (!is(typeof(mixin("function RT(ref T t, ref PT p)"~attribs~"{ return t."~mem~"(p); }"))))
							enum impl = "`" ~ fullyQualifiedName!T ~ "` does not implement method `" ~
								mem ~ "` of type `" ~ FT.stringof ~ "` from `" ~ fullyQualifiedName!I ~ "`";
						else enum string impl = impl!(i+1);
					}
				}
			} else enum string impl = null;
		}
		alias checkMemberConformance = impl!0;
	}

	template impl(size_t i) {
		static if (i < Members.length) {
			static if (__traits(compiles, __traits(getMember, I, Members[i])))
				enum mc = checkMemberConformance!(Members[i]);
			else enum mc = null;
			static if (mc is null) enum impl = impl!(i+1);
			else enum impl = mc;
		} else enum string impl = null;
	}

	static if (is(T : I))
		enum checkInterfaceConformance = null;
	else static if (is(T == struct) || is(T == class) || is(T == interface))
		enum checkInterfaceConformance = impl!0;
	else
		enum checkInterfaceConformance = "Aggregate type expected, not " ~ T.stringof;
}

unittest {
	interface InputStream {
		@safe:
		@property bool empty() nothrow;
		void read(ubyte[] dst);
	}

	interface OutputStream {
		@safe:
		void write(scope const(ubyte)[] bytes);
		void flush();
		void finalize();
		void write(InputStream stream, ulong nbytes = 0);
	}

	static class OSClass : OutputStream {
		override void write(scope const(ubyte)[] bytes) {}
		override void flush() {}
		override void finalize() {}
		override void write(InputStream stream, ulong nbytes) {}
	}

	mixin validateInterfaceConformance!(OSClass, OutputStream);

	static struct OSStruct {
		@safe:
		void write(scope const(ubyte)[] bytes) {}
		void flush() {}
		void finalize() {}
		void write(IS)(IS stream, ulong nbytes) {}
	}

	mixin validateInterfaceConformance!(OSStruct, OutputStream);

	static struct NonOSStruct {
		@safe:
		void write(scope const(ubyte)[] bytes) {}
		void flush(bool) {}
		void finalize() {}
		void write(InputStream stream, ulong nbytes) {}
	}

	string removeUnittestLineNumbers(string s) {
		import std.string;

		string ret;
		size_t start;
		while (true)
		{
			size_t next = s.indexOf("__unittest_L", start);
			if (next == -1)
				break;
			size_t dot = s.indexOf('.', next);
			if (dot == -1)
				dot = s.length;
			else
				ret ~= s[start .. next + "__unittest".length];
			start = dot;
		}
		return ret ~ s[start .. $];
	}

	static assert(removeUnittestLineNumbers(checkInterfaceConformance!(NonOSStruct, OutputStream)) ==
		"`vibe.internal.traits.__unittest.NonOSStruct` does not implement method `flush` of type `@safe void()` from `vibe.internal.traits.__unittest.OutputStream`");

	static struct NonOSStruct2 {
		void write(scope const(ubyte)[] bytes) {} // not @safe
		void flush(bool) {}
		void finalize() {}
		void write(InputStream stream, ulong nbytes) {}
	}

    // `in` used to show up as `const` / `const scope`.
    // With dlang/dmd#11474 it shows up as `in`.
    // Remove when support for v2.093.0 is dropped
    static if (removeUnittestLineNumbers(checkInterfaceConformance!(NonOSStruct2, OutputStream)) !=
        "`vibe.internal.traits.__unittest.NonOSStruct2` does not implement method `write` of type `@safe void(scope const(ubyte)[] bytes)` from `vibe.internal.traits.__unittest.OutputStream`")
    {
        // Fallback to pre-2.092+
        static assert(removeUnittestLineNumbers(checkInterfaceConformance!(NonOSStruct2, OutputStream)) ==
            "`vibe.internal.traits.__unittest.NonOSStruct2` does not implement method `write` of type `@safe void(const(ubyte[]) bytes)` from `vibe.internal.traits.__unittest.OutputStream`");
    }
}

string functionAttributeString(alias F)(bool restrictions_only)
{
	import std.traits : FunctionAttribute, functionAttributes;

	auto attribs = functionAttributes!F;
	string ret;
	with (FunctionAttribute) {
		if (attribs & nogc) ret ~= " @nogc";
		if (attribs & nothrow_) ret ~= " nothrow";
		if (attribs & pure_) ret ~= " pure";
		if (attribs & safe) ret ~= " @safe";
		if (!restrictions_only) {
			if (attribs & property) ret ~= " @property";
			if (attribs & ref_) ret ~= " ref";
			if (attribs & shared_) ret ~= " shared";
			if (attribs & const_) ret ~= " const";
		}
	}
	return ret;
}

string functionAttributeThisType(alias F)(string tname)
{
	import std.traits : FunctionAttribute, functionAttributes;

	auto attribs = functionAttributes!F;
	string ret = tname;
	with (FunctionAttribute) {
		if (attribs & shared_) ret = "shared("~ret~")";
		if (attribs & const_) ret = "const("~ret~")";
	}
	return ret;
}
