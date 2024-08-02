module vibe.internal.async;

import std.traits : ParameterTypeTuple, ReturnType;
import std.typecons : tuple;
import vibe.core.core : hibernate, switchToTask;
import vibe.core.task : InterruptException, Task, TaskSwitchPriority;
import vibe.core.log;
import core.time : Duration, seconds;


auto asyncAwait(Callback, alias action, alias cancel)(string func = __FUNCTION__)
if (!is(Object == Duration)) {
	ParameterTypeTuple!Callback results;
	alias waitable = Waitable!(Callback, action, cancel, (ParameterTypeTuple!Callback r) { results = r; });
	asyncAwaitAny!(true, waitable)(func);
	return tuple(results);
}

auto asyncAwait(Callback, alias action, alias cancel)(Duration timeout, string func = __FUNCTION__)
{
	static struct R {
		bool completed = true;
		ParameterTypeTuple!Callback results;
	}
	R ret;
	static if (is(ReturnType!action == void)) {
		alias waitable = Waitable!(Callback,
			action,
			(cb) { ret.completed = false; cancel(cb); },
			(ParameterTypeTuple!Callback r) { ret.results = r; }
		);
	}
	else {
		alias waitable = Waitable!(Callback,
			action,
			(cb, waitres) { ret.completed = false; cancel(cb, waitres); },
			(ParameterTypeTuple!Callback r) { ret.results = r; }
		);
	}
	asyncAwaitAny!(true, waitable)(timeout, func);
	return ret;
}

auto asyncAwaitUninterruptible(Callback, alias action)(string func = __FUNCTION__)
nothrow {
	static if (is(typeof(action(Callback.init)) == void)) void cancel(Callback) { assert(false, "Action cannot be cancelled."); }
	else void cancel(Callback, typeof(action(Callback.init))) @safe @nogc nothrow { assert(false, "Action cannot be cancelled."); }
	ParameterTypeTuple!Callback results;
	alias waitable = Waitable!(Callback, action, cancel, (ParameterTypeTuple!Callback r) { results = r; });
	asyncAwaitAny!(false, waitable)(func);
	return tuple(results);
}

auto asyncAwaitUninterruptible(Callback, alias action, alias cancel)(Duration timeout, string func = __FUNCTION__)
nothrow {
	ParameterTypeTuple!Callback results;
	alias waitable = Waitable!(Callback, action, cancel, (ParameterTypeTuple!Callback r) { results = r; });
	asyncAwaitAny!(false, waitable)(timeout, func);
	return tuple(results);
}

template Waitable(CB, alias WAIT, alias CANCEL, alias DONE)
{
	import std.traits : ReturnType;

	static assert(is(typeof(WAIT(CB.init))), "WAIT must be callable with a parameter of type "~CB.stringof);
	static if (is(typeof(WAIT(CB.init)) == void))
		static assert(is(typeof(CANCEL(CB.init))),
			"CANCEL must be callable with a parameter of type "~CB.stringof);
	else
		static assert(is(typeof(CANCEL(CB.init, typeof(WAIT(CB.init)).init))),
			"CANCEL must be callable with parameters "~CB.stringof~
			" and "~typeof(WAIT(CB.init)).stringof);
	static assert(is(typeof(DONE(ParameterTypeTuple!CB.init))),
		"DONE must be callable with types "~ParameterTypeTuple!CB.stringof);

	alias Callback = CB;
	alias wait = WAIT;
	alias cancel = CANCEL;
	alias done = DONE;
}

void asyncAwaitAny(bool interruptible, Waitables...)(Duration timeout, string func = __FUNCTION__)
{
	if (timeout == Duration.max) asyncAwaitAny!(interruptible, Waitables)(func);
	else {
		import eventcore.core;

		auto tm = eventDriver.timers.create();
		eventDriver.timers.set(tm, timeout, 0.seconds);
		scope (exit) eventDriver.timers.releaseRef(tm);
		alias timerwaitable = Waitable!(TimerCallback,
			cb => eventDriver.timers.wait(tm, cb),
			cb => eventDriver.timers.cancelWait(tm),
			(tid) {}
		);
		asyncAwaitAny!(interruptible, timerwaitable, Waitables)(func);
	}
}

void asyncAwaitAny(bool interruptible, Waitables...)(string func = __FUNCTION__)
	if (Waitables.length >= 1)
{
	import std.meta : staticMap;
	import std.algorithm.searching : any;
	import std.meta : AliasSeq;
	import std.traits : ReturnType;

	bool[Waitables.length] fired;
	bool any_fired = false;
	Task t;

	bool still_inside = true;
	scope (exit) still_inside = false;

	debug(VibeAsyncLog) logDebugV("Performing %s async operations in %s", Waitables.length, func);

	static foreach (i, W; Waitables) {
		mixin("alias PT"~i.stringof~" = ParameterTypeTuple!(Waitables["~i.stringof~"].Callback);\n"
			~ "scope callback_"~i.stringof~" = ("~generateParamDecls!(CBDel!W)("PT"~i.stringof)~") @safe nothrow {\n"
			~ "	// NOTE: this triggers DigitalMars/optlink#18\n"
			~ "	//() @trusted { logDebugV(\"siw %%x\", &still_inside); } ();\n"
			~ "	debug(VibeAsyncLog) logDebugV(\"Waitable %%s in %%s fired (istask=%%s).\", "~i.stringof~", func, t != Task.init);\n"
			~ "	assert(still_inside, \"Notification fired after asyncAwait had already returned!\");\n"
			~ "	fired["~i.stringof~"] = true;\n"
			~ "	any_fired = true;\n"
			~ "	Waitables["~i.stringof~"].done("~generateParamNames!(CBDel!W)~");\n"
			~ "	if (t != Task.init) {\n"
			~ "		version (VibeHighEventPriority) switchToTask(t);\n"
			~ "		else switchToTask(t, TaskSwitchPriority.normal);\n"
			~ "	}\n"
			~ "};\n"
			~ "debug(VibeAsyncLog) logDebugV(\"Starting operation %%s\", "~i.stringof~");\n"
			~ "alias WR"~i.stringof~" = typeof(Waitables["~i.stringof~"].wait(() @trusted { return callback_"~i.stringof~"; } ()));\n"
			~ "static if (is(WR"~i.stringof~" == void)) Waitables["~i.stringof~"].wait(() @trusted { return callback_"~i.stringof~"; } ());\n"
			~ "else auto wr"~i.stringof~" = Waitables["~i.stringof~"].wait(() @trusted { return callback_"~i.stringof~"; } ());\n"
			~ "scope (exit) {\n"
			~ "	if (!fired["~i.stringof~"]) {\n"
			~ "		debug(VibeAsyncLog) logDebugV(\"Cancelling operation %%s\", "~i.stringof~");\n"
			~ "		any_fired = true;\n"
			~ "		fired["~i.stringof~"] = true;\n"
			~ "		static if (is(WR"~i.stringof~" == void)) Waitables["~i.stringof~"].cancel(() @trusted { return callback_"~i.stringof~"; } ());\n"
			~ "		else Waitables["~i.stringof~"].cancel(() @trusted { return callback_"~i.stringof~"; } (), wr"~i.stringof~");\n"
			~ "	}\n"
			~ "}\n"
			~ "if (any_fired) {\n"
			~ "	debug(VibeAsyncLog) logDebugV(\"Returning to %%s without waiting.\", func);\n"
			~ "	return;\n"
			~ "}\n"
		);
	}

	debug(VibeAsyncLog) logDebugV("Need to wait in %s (%s)...", func, interruptible ? "interruptible" : "uninterruptible");

	t = Task.getThis();

	debug (VibeAsyncLog) scope (failure) logDebugV("Aborting wait due to exception");

	do {
		static if (interruptible) {
			bool interrupted = false;
			hibernate(() @safe nothrow {
				debug(VibeAsyncLog) logDebugV("Got interrupted in %s.", func);
				interrupted = true;
			});
			debug(VibeAsyncLog) logDebugV("Task resumed (fired=%s, interrupted=%s)", fired, interrupted);
			if (interrupted)
				throw new InterruptException;
		} else {
			hibernate();
			debug(VibeAsyncLog) logDebugV("Task resumed (fired=%s)", fired);
		}
	} while (!any_fired);

	debug(VibeAsyncLog) logDebugV("Return result for %s.", func);
}

private alias CBDel(alias Waitable) = Waitable.Callback;

@safe nothrow /*@nogc*/ unittest {
	int cnt = 0;
	auto ret = asyncAwaitUninterruptible!(void delegate(int) @safe nothrow, (cb) { cnt++; cb(42); });
	assert(ret[0] == 42);
	assert(cnt == 1);
}

@safe nothrow /*@nogc*/ unittest {
	int a, b, c;
	int w1r, w2r;
	alias w1 = Waitable!(
		void delegate(int) @safe nothrow,
		(cb) { a++; cb(42); },
		(cb) { assert(false); },
		(i) { w1r = i; }
	);
	alias w2 = Waitable!(
		void delegate(int) @safe nothrow,
		(cb) { b++; },
		(cb) { c++; },
		(i) { w2r = i; }
	);
	alias w3 = Waitable!(
		void delegate(int) @safe nothrow,
		(cb) { c++; cb(42); },
		(cb) { assert(false); },
		(int n) { assert(n == 42); }
	);

	asyncAwaitAny!(false, w1, w2);
	assert(w1r == 42 && w2r == 0);
	assert(a == 1 && b == 0 && c == 0);

	asyncAwaitAny!(false, w2, w1);
	assert(w1r == 42 && w2r == 0);
	assert(a == 2 && b == 1 && c == 1);

	asyncAwaitAny!(false, w3);
	assert(c == 2);
}

private string generateParamDecls(Fun)(string ptypes_name = "PTypes")
{
	import std.traits : ParameterTypeTuple, ParameterStorageClass, ParameterStorageClassTuple;

	if (!__ctfe) assert(false);

	alias Types = ParameterTypeTuple!Fun;
	alias SClasses = ParameterStorageClassTuple!Fun;
	string ret;
	foreach (i, T; Types) {
		static if (i > 0) ret ~= ", ";
		static if (SClasses[i] & ParameterStorageClass.lazy_) ret ~= "lazy ";
		static if (SClasses[i] & ParameterStorageClass.scope_) ret ~= "scope ";
		static if (SClasses[i] & ParameterStorageClass.out_) ret ~= "out ";
		static if (SClasses[i] & ParameterStorageClass.ref_) ret ~= "ref ";
		ret ~= ptypes_name~"["~i.stringof~"] param_"~i.stringof;
	}
	return ret;
}

private string generateParamNames(Fun)()
{
	if (!__ctfe) assert(false);

	string ret;
	foreach (i, T; ParameterTypeTuple!Fun) {
		static if (i > 0) ret ~= ", ";
		ret ~= "param_"~i.stringof;
	}
	return ret;
}

private template hasAnyScopeParameter(Callback) {
	import std.algorithm.searching : any;
	import std.traits : ParameterStorageClass, ParameterStorageClassTuple;
	alias SC = ParameterStorageClassTuple!Callback;
	static if (SC.length == 0) enum hasAnyScopeParameter = false;
	else enum hasAnyScopeParameter = any!(c => c & ParameterStorageClass.scope_)([SC]);
}
