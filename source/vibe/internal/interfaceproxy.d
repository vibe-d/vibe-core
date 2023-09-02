module vibe.internal.interfaceproxy;

import vibe.internal.traits;
import vibe.internal.freelistref;
import vibe.internal.allocator;
import std.algorithm.mutation : move, swap;
import std.meta : staticMap;
import std.traits : BaseTypeTuple;


O asInterface(I, O)(O obj) if (is(I == interface) && is(O : I)) { return obj; }
InterfaceProxyClass!(I, O) asInterface(I, O)(O obj) if (is(I == interface) && !is(O : I)) { return new InterfaceProxyClass!(I, O)(obj); }

InterfaceProxyClass!(I, O) asInterface(I, O)(O obj, IAllocator allocator)
@trusted if (is(I == interface) && !is(O : I))
{
	alias R = InterfaceProxyClass!(I, O);
	return allocator.makeGCSafe!R(obj);
}

void freeInterface(I, O)(InterfaceProxyClass!(I, O) inst, IAllocator allocator)
{
	allocator.disposeGCSafe(inst);
}

FreeListRef!(InterfaceProxyClass!(I, O)) asInterfaceFL(I, O)(O obj) { return FreeListRef!(InterfaceProxyClass!(I, O))(obj); }

InterfaceProxy!I interfaceProxy(I, O)(O o) { return InterfaceProxy!I(o); }

private final class InterfaceProxyClass(I, O) : I
{
	import std.meta : AliasSeq;
	import std.traits : FunctionAttribute, MemberFunctionsTuple, ReturnType, ParameterTypeTuple, functionAttributes;

	private {
		O m_obj;
	}

	this(ref O obj) { swap(m_obj, obj); }

	mixin methodDefs!0;

	private mixin template methodDefs(size_t idx) {
		alias Members = AliasSeq!(__traits(allMembers, I));
		static if (idx < Members.length) {
			mixin overloadDefs!(Members[idx]);
			mixin methodDefs!(idx+1);
		}
	}

	mixin template overloadDefs(string mem) {
		alias Overloads = MemberFunctionsTuple!(I, mem);

		private static string impl()
		{
			string ret;
			foreach (idx, F; Overloads) {
				alias R = ReturnType!F;
				enum attribs = functionAttributeString!F(false);
				static if (__traits(isVirtualMethod, F)) {
					static if (is(R == void))
						ret ~= "override "~attribs~" void "~mem~"(ParameterTypeTuple!(Overloads["~idx.stringof~"]) params) { m_obj."~mem~"(params); }";
					else
						ret ~= "override "~attribs~" ReturnType!(Overloads["~idx.stringof~"]) "~mem~"(ParameterTypeTuple!(Overloads["~idx.stringof~"]) params) { return m_obj."~mem~"(params); }";
				}
			}
			return ret;
		}

		mixin(impl());
	}
}



struct InterfaceProxy(I) if (is(I == interface)) {
	import std.meta : AliasSeq;
	import std.traits : FunctionAttribute, MemberFunctionsTuple, ReturnType, ParameterTypeTuple, functionAttributes;
	import vibe.internal.traits : checkInterfaceConformance;

	private {
		void*[4] m_value;
		enum maxSize = m_value.length * m_value[0].sizeof;
		Proxy m_intf;
	}

	this(IP : InterfaceProxy!J, J)(IP proxy) @safe
	{
		() @trusted {
			m_intf = proxy.m_intf;
			swap(proxy.m_value, m_value);
			proxy.m_intf = null;
		} ();
	}

	this(O)(O object) @trusted
		if (is(O == struct) || is(O == class) || is(O == interface))
	{
		static assert(O.sizeof % m_value[0].sizeof == 0, "Sizeof object ("~O.stringof~") must be a multiple of a pointer size.");
		static assert(O.sizeof <= maxSize, "Object ("~O.stringof~") is too big to be stored in an InterfaceProxy.");
		import std.conv : emplace;

		static if (is(O == class) || is(O == interface)) {
			if (!object) return;
		}

		m_intf = ProxyImpl!O.get();
		static if (is(O == struct))
			emplace!O(m_value[0 .. O.sizeof/m_value[0].sizeof]);
		swap((cast(O[])m_value[0 .. O.sizeof/m_value[0].sizeof])[0], object);
	}

	this(typeof(null))
	{
	}

	~this() @safe scope
	{
		clear();
	}

	this(this) @safe scope
	{
		if (m_intf) m_intf._postblit(m_value);
	}

	void clear() @safe nothrow scope
	{
		if (m_intf) {
			m_intf._destroy(m_value);
			m_intf = null;
			m_value[] = null;
		}
	}

	T extract(T)()
	@trusted nothrow {
		if (!m_intf || m_intf._typeInfo() !is typeid(T))
			assert(false, "Extraction of wrong type from InterfaceProxy.");
		return (cast(T[])m_value[0 .. T.sizeof/m_value[0].sizeof])[0];
	}

	void opAssign(IP : InterfaceProxy!J, J)(IP proxy) @safe
	{
		static assert(is(J : I), "Can only assign InterfaceProxy instances of derived interfaces.");

		clear();
		if (proxy.m_intf) {
			m_intf = proxy.m_intf;
			m_value[] = proxy.m_value[];
			proxy.m_intf = null;
		}
	}

	void opAssign(O)(O object) @trusted
		if (checkInterfaceConformance!(O, I) is null)
	{
		static assert(O.sizeof % m_value[0].sizeof == 0, "Sizeof object ("~O.stringof~") must be a multiple of a pointer size.");
		static assert(O.sizeof <= maxSize, "Object is too big to be stored in an InterfaceProxy.");
		import std.conv : emplace;
		clear();
		m_intf = ProxyImpl!O.get();
		static if (is(O == class))
			(cast(O[])m_value[0 .. O.sizeof/m_value[0].sizeof])[0] = object;
		else emplace!O(m_value[0 .. O.sizeof/m_value[0].sizeof]);
		swap((cast(O[])m_value[0 .. O.sizeof/m_value[0].sizeof])[0], object);
	}

	bool opCast(T)() const @safe nothrow if (is(T == bool)) { return m_intf !is null; }

	mixin allMethods!0;

	private mixin template allMethods(size_t idx) {
		alias Members = AliasSeq!(__traits(allMembers, I));
		static if (idx < Members.length) {
			static if (__traits(compiles, __traits(getMember, I, Members[idx])))
				mixin overloadMethods!(Members[idx]);
			mixin allMethods!(idx+1);
		}
	}

	private mixin template overloadMethods(string member) {
		alias Overloads = AliasSeq!(__traits(getOverloads, I, member));

		private static string impl()
		{
			string ret;
			foreach (idx, F; Overloads) {
				enum attribs = functionAttributeString!F(false);
				enum is_prop = functionAttributes!F & FunctionAttribute.property;
				ret ~= attribs~" ReturnType!(Overloads["~idx.stringof~"]) "~member~"("~parameterDecls!(F, idx)~") { return m_intf."~member~"(m_value, "~parameterNames!F~"); }";
			}
			return ret;
		}

		mixin(impl());
	}

	private interface Proxy : staticMap!(ProxyOf, BaseTypeTuple!I) {
		import std.meta : AliasSeq;
		import std.traits : FunctionAttribute, MemberFunctionsTuple, ReturnType, ParameterTypeTuple, functionAttributes;

		void _destroy(scope void[] stor) @safe nothrow scope;
		void _postblit(scope void[] stor) @safe nothrow scope;
		TypeInfo _typeInfo() @safe nothrow scope;

		mixin methodDecls!0;

		private mixin template methodDecls(size_t idx) {
			alias Members = AliasSeq!(__traits(derivedMembers, I));
			static if (idx < Members.length) {
				static if (__traits(compiles, __traits(getMember, I, Members[idx])))
					mixin overloadDecls!(Members[idx]);
				mixin methodDecls!(idx+1);
			}
		}

		private mixin template overloadDecls(string mem) {
			alias Overloads = AliasSeq!(__traits(getOverloads, I, mem));

			private static string impl()
			{
				string ret;
				foreach (idx, F; Overloads) {
					enum attribs = functionAttributeString!F(false);
					enum vtype = functionAttributeThisType!F("void[]");
					ret ~= "ReturnType!(Overloads["~idx.stringof~"]) "~mem~"(scope "~vtype~" obj, "~parameterDecls!(F, idx)~") "~attribs~";";
				}
				return ret;
			}

			mixin(impl());
		}
	}

	static final class ProxyImpl(O) : Proxy {
		static auto get()
		{
			static ProxyImpl impl;
			if (!impl) impl = new ProxyImpl;
			return impl;
		}

		override void _destroy(scope void[] stor)
		@trusted nothrow scope {
			static if (is(O == struct)) {
				try destroy(*_extract(stor));
				catch (Exception e) assert(false, "Destructor has thrown: "~e.msg);
			}
		}

		override void _postblit(scope void[] stor)
		@trusted nothrow scope {
			static if (is(O == struct)) {
				try typeid(O).postblit(stor.ptr);
				catch (Exception e) assert(false, "Postblit contructor has thrown: "~e.msg);
			}
		}

		override TypeInfo _typeInfo()
		@safe nothrow scope {
			return typeid(O);
		}

		static inout(O)* _extract(return inout(void)[] stor)
		@trusted nothrow pure @nogc {
			if (stor.length < O.sizeof) assert(false);
			return cast(inout(O)*)stor.ptr;
		}

		mixin methodDefs!0;

		private mixin template methodDefs(size_t idx) {
			alias Members = AliasSeq!(__traits(allMembers, I));
			static if (idx < Members.length) {
				static if (__traits(compiles, __traits(getMember, I, Members[idx])))
					mixin overloadDefs!(Members[idx]);
				mixin methodDefs!(idx+1);
			}
		}

		private mixin template overloadDefs(string mem) {
			alias Overloads = AliasSeq!(__traits(getOverloads, I, mem));

			private static string impl()
			{
				string ret;
				foreach (idx, F; Overloads) {
					alias R = ReturnType!F;
					alias P = ParameterTypeTuple!F;
					enum attribs = functionAttributeString!F(false);
					enum vtype = functionAttributeThisType!F("void[]");

					static if (is(R == void))
						ret ~= "override void "~mem~"(scope "~vtype~" obj, "~parameterDecls!(F, idx)~") "~attribs~" { _extract(obj)."~mem~"("~parameterNames!F~"); }";
					else
						ret ~= "override ReturnType!(Overloads["~idx.stringof~"]) "~mem~"(scope "~vtype~" obj, "~parameterDecls!(F, idx)~") "~attribs~" { return _extract(obj)."~mem~"("~parameterNames!F~"); }";
				}
				return ret;
			}

			mixin(impl());
		}
	}
}

unittest {
	static interface I {}
	assert(!InterfaceProxy!I(null));
	assert(!InterfaceProxy!I(cast(I)null));
}

private string parameterDecls(alias F, size_t idx)()
{
	import std.traits : ParameterTypeTuple, ParameterStorageClass, ParameterStorageClassTuple;

	string ret;
	alias PST = ParameterStorageClassTuple!F;
	foreach (i, PT; ParameterTypeTuple!F) {
		static if (i > 0) ret ~= ", ";
		static if (PST[i] & ParameterStorageClass.scope_) ret ~= "scope ";
		static if (PST[i] & ParameterStorageClass.out_) ret ~= "out ";
		static if (PST[i] & ParameterStorageClass.ref_) ret ~= "ref ";
		static if (PST[i] & ParameterStorageClass.lazy_) ret ~= "lazy ";
		ret ~= "ParameterTypeTuple!(Overloads["~idx.stringof~"])["~i.stringof~"] param_"~i.stringof;
	}
	return ret;
}

private string parameterNames(alias F)()
{
	import std.traits : ParameterTypeTuple;

	string ret;
	foreach (i, PT; ParameterTypeTuple!F) {
		static if (i > 0) ret ~= ", ";
		ret ~= "param_"~i.stringof;
	}
	return ret;
}

private alias ProxyOf(I) = InterfaceProxy!I.Proxy;


unittest {
	static interface I {
		@property int count() const;
	}

	static struct S {
		int* cnt;
		this(bool) { cnt = new int; *cnt = 1; }
		this(this) { if (cnt) (*cnt)++; }
		~this() { if (cnt) (*cnt)--; }
		@property int count() const { return cnt ? *cnt : 0; }
	}

	auto s = S(true);
	assert(s.count == 1);

	auto t = interfaceProxy!I(s);
	assert(s.count == 2);

	t = interfaceProxy!I(s);
	assert(s.count == 2);

	t = s;
	assert(s.count == 2);

	s = S.init;
	assert(t.count == 1);

	s = t.extract!S;
	assert(s.count == 2);

	t = InterfaceProxy!I.init;
	assert(s.count == 1);

	t = s;
	assert(s.count == 2);

	s = S(true);
	assert(s.count == 1);
	assert(t.count == 1);

	{
		InterfaceProxy!I u;
		u = s;
		assert(u.count == 2);
	}
	assert(s.count == 1);
}
