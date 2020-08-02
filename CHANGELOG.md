1.9.3 - 2020-08-02
==================

- Removed dead import of deprecated symbol `enforceEx` - [pull #214][issue214]
- Improved error messages for non-implemented interfaces - [pull #216][issue216]
- Improved internal unittests to be forward-compatible - [pull #213][pull213] and [pull #215][pull215]

[issue213]: https://github.com/vibe-d/vibe-core/issues/213
[issue214]: https://github.com/vibe-d/vibe-core/issues/214
[issue215]: https://github.com/vibe-d/vibe-core/issues/215
[issue216]: https://github.com/vibe-d/vibe-core/issues/216


1.9.2 - 2020-05-28
==================

- Updated tested compiler range to DMD 2.078.3-2.092.0 and LDC 1.15.0-1.21.0
- Added support for a `CFRunLoop` based configuration on macOS to enable efficient UI integration - [pull #211][issue211]
- Removed potentially blocking file I/O code - [pull #210][issue210]
- Added error handling for process creation - [pull #210][issue210]

[issue210]: https://github.com/vibe-d/vibe-core/issues/210
[issue211]: https://github.com/vibe-d/vibe-core/issues/211


1.9.1 - 2020-03-18
==================

- Compiler support updated to DMD 2.078.3-2.091.0 and LDC 1.15.0-1.20.1 - [pull #192][issue192]
- Fixed SysLogger to compile again (was broken since the first vibe-core release) - [issue #203][issue203], [pull #204][issue204]
- Fixed `relativeTo` to be `nothrow` - [pull #206][issue206]

[issue192]: https://github.com/vibe-d/vibe-core/issues/192
[issue203]: https://github.com/vibe-d/vibe-core/issues/203
[issue204]: https://github.com/vibe-d/vibe-core/issues/204
[issue206]: https://github.com/vibe-d/vibe-core/issues/206


1.9.0 - 2020-03-18
==================

- Implemented priority based task scheduling - [pull #196][issue196], [pull #197][issue197]
	- Each task can be given a non-default priority that controls the relative frequency with which the task gets resumed in concurrent situations
	- Events are now handled according to the calling task's priority instead of being handled immediately (can be reverted by defining a `VibeHighEventPriority` version)
- Fixed a bogus contract violation error in `Timer.rearm` - [pull #195][issue195]

[issue195]: https://github.com/vibe-d/vibe-core/issues/195
[issue196]: https://github.com/vibe-d/vibe-core/issues/196
[issue197]: https://github.com/vibe-d/vibe-core/issues/197


1.8.1 - 2019-12-17
==================

- Fixes a documentation generation error (by Mathias Lang aka Geod24) - [pull #187][issue187]

[issue187]: https://github.com/vibe-d/vibe-core/issues/187


1.8.0 - 2019-12-07
==================

- Added a new path segment API that works without GC allocations (`GenericPath.bySegment2`/`.head2`) - this will replace the old API in version 2.x.x of the library - [pull #179][issue179]
- Added `GenericPath.byPrefix` to iterate over all ancestor paths from root to leaf - [pull #181][issue181]
- Fixed a bug with uninitialized `YieldLock` instances (which can happen even with `@disable this()`) - [pull #180][issue180]
- Heavily improved performance of `readFileUTF8` for large files by using a more efficient `sanitizyUTF8` implementation - [pull #182][issue182]
- CI tests now also run on macOS in addition to Linux and Windows - [pull #183][issue183]

[issue179]: https://github.com/vibe-d/vibe-core/issues/179
[issue180]: https://github.com/vibe-d/vibe-core/issues/180
[issue181]: https://github.com/vibe-d/vibe-core/issues/181
[issue182]: https://github.com/vibe-d/vibe-core/issues/182
[issue183]: https://github.com/vibe-d/vibe-core/issues/183


1.7.0 - 2019-09-17
==================

- Supports DMD 2.077.1 up to DMD 2.088.0 and LDC 1.7.0 to LDC 1.17.0 - [pull #166][issue166], [pull #177][issue177]
- Added `vibe.core.process` for task based process handling similar to `std.process` (by Benjamin Schaaf) - [pull #154][issue154]
- Added `ConnectionPool.removeUnused` to enable closing all unused connections - [pull #143][issue143]
- Added `logException` to log exceptions in a standard and `nothrow` way - [pull #155][issue155]
- Added `TCPListenOptions.reuseAddress` for explicitly control of `SO_REUSEADDR` for listening sockets (by Radu Racariu) - [pull #150][issue150]
- Added `TCPConnection.waitForDataEx` - [pull #159][issue159], [pull #153][issue153]
- Fixed `TCPConnection.leastSize` to adhere to the `readTimeout` set - [pull #160][issue160]
- Updated compiler support to DMD 2.086.0 and LDC 1.5.0
- The logging functions now log verbatim if no additional argument is passed (by Denis Feklushkin aka dennizzzka) - [issue #87][issue87], [pull #152][issue152]
- Made `GenericPath.parentPath` `pure` - [pull #165][issue165]
- All remaining operations in `vibe.core.file` are now done asynchronously (using worker tasks) - [pull #172][issue172]
- Fixed a potential range violation in `iterateDirectory`/`getFileInfo` - [pull #144][issue144]
- Fixed thread-safety of `Task.join` and `Task.interrupt` when operating cross-thread - [pull #145][issue145]
- Fixed `copyFile` for write protected files - failed to set file times
- Fixed hanging `Task.yield()` calls in case of multiple waiters - [issue #161][issue161], [pull #162][issue162]
- Fixed `Channel!T.empty` to guarantee a successful `consumeOne` for `false` in case of a single reader - [issue #157][issue157], [pull #163][issue163]
- Fixed a crash when deleting a handle from a foreign thread after the original thread has terminated - [issue #135][issue135], [pull #164][issue164]
- Fixed an issue in `ConnectionPool` where the pool became unusable after connection failures (by Tomáš Chaloupka) - [pull #169][issue169]
- Fixed `FileStream` in append mode to report correct file offsets and disallow seeking (by v1ne) - [pull #168][issue168]

[issue87]: https://github.com/vibe-d/vibe-core/issues/87
[issue135]: https://github.com/vibe-d/vibe-core/issues/135
[issue143]: https://github.com/vibe-d/vibe-core/issues/143
[issue144]: https://github.com/vibe-d/vibe-core/issues/144
[issue145]: https://github.com/vibe-d/vibe-core/issues/145
[issue150]: https://github.com/vibe-d/vibe-core/issues/150
[issue152]: https://github.com/vibe-d/vibe-core/issues/152
[issue153]: https://github.com/vibe-d/vibe-core/issues/153
[issue154]: https://github.com/vibe-d/vibe-core/issues/154
[issue155]: https://github.com/vibe-d/vibe-core/issues/155
[issue157]: https://github.com/vibe-d/vibe-core/issues/157
[issue159]: https://github.com/vibe-d/vibe-core/issues/159
[issue160]: https://github.com/vibe-d/vibe-core/issues/160
[issue161]: https://github.com/vibe-d/vibe-core/issues/161
[issue162]: https://github.com/vibe-d/vibe-core/issues/162
[issue163]: https://github.com/vibe-d/vibe-core/issues/163
[issue164]: https://github.com/vibe-d/vibe-core/issues/164
[issue165]: https://github.com/vibe-d/vibe-core/issues/165
[issue166]: https://github.com/vibe-d/vibe-core/issues/166
[issue168]: https://github.com/vibe-d/vibe-core/issues/168
[issue169]: https://github.com/vibe-d/vibe-core/issues/169
[issue172]: https://github.com/vibe-d/vibe-core/issues/172
[issue177]: https://github.com/vibe-d/vibe-core/issues/177


1.6.2 - 2019-03-26
==================

- Fixed `listDirectory`/`iterateDirectory` to not throw when encountering inaccessible files - [pull #142][issue142]
- Added `FileInfo.isFile` to be able to distinguish between regular and special files (by Francesco Mecca) - [pull #141][issue141]

[issue141]: https://github.com/vibe-d/vibe-core/issues/141
[issue142]: https://github.com/vibe-d/vibe-core/issues/142


1.6.1 - 2019-03-10
==================

- Fixed handling of the `args_out` parameter of `runApplication` (by Joseph Rushton Wakeling) - [pull #134][issue134]
- Fixed `TCPConnectionFunction` to be actually defined as a function pointer (by Steven Dwy) - [pull #136][issue136], [issue #109][issue109]
- Fixed execution interleaving of busy `yield` loops inside and outside of a task - [pull #139][issue139]

[issue109]: https://github.com/vibe-d/vibe-core/issues/109
[issue134]: https://github.com/vibe-d/vibe-core/issues/134
[issue136]: https://github.com/vibe-d/vibe-core/issues/136
[issue139]: https://github.com/vibe-d/vibe-core/issues/139


1.6.0 - 2019-01-26
==================

- Improved the Channel!T API - [pull #127][issue127], [pull #130][issue130]
	- Usable as a `shared(Channel!T)`
	- Most of the API is now `nothrow`
	- `createChannel` is now `@safe`
- `yieldLock` is now `@safe nothrow` - [pull #127][issue127]
- `Task.interrupt` can now be called from within a `yieldLock` section - [pull #127][issue127]
- Added `createLeanTimer` and reverted the task behavior back to pre-1.4.4 - []
- Fixed a bogus assertion failure in `connectTCP` on Posix systems - [pull #128][issue128]
- Added `runWorkerTaskDistH`, a variant of `runWorkerTaskDist` that returns all task handles - [pull #129][issue129]
- `TaskCondition.wait`, `notify` and `notifyAll` are now `nothrow` - [pull #130][issue130]

[issue127]: https://github.com/vibe-d/vibe-core/issues/127
[issue128]: https://github.com/vibe-d/vibe-core/issues/128
[issue129]: https://github.com/vibe-d/vibe-core/issues/129
[issue130]: https://github.com/vibe-d/vibe-core/issues/130


1.5.0 - 2019-01-20
==================

- Supports DMD 2.078.3 up to DMD 2.084.0 and LDC up to 1.13.0
- Added statically typed CSP style cross-task channels - [pull #25][issue25]
	- The current implementation is buffered and supports multiple senders and multiple readers

[issue25]: https://github.com/vibe-d/vibe-core/issues/25


1.4.7 - 2019-01-20
==================

- Improved API robustness and documentation for `InterruptibleTaskMutex` - [issue #118][issue118], [pull #119][issue119]
	- `synchronized(iterriptible_mutex)` now results in a runtime error instead of silently using the automatically created object monitor
	- resolved an overload conflict when passing a `TaskMutex` to `InterruptibleTaskCondition`
	- `scopedMutexLock` now accepts `InterruptibleTaskMutex`
- Fixed a socket file descriptor leak in `connectTCP` when the connection fails (by Jan Jurzitza aka WebFreak001) - [issue #115][issue115], [pull #116][issue116], [pull #123][issue123]
- Fixed `resolveHost` to not treat qualified host names starting with a digit as an IP address - [issue #117][issue117], [pull #121][issue121]
- Fixed `copyFile` to retain attributes and modification time - [pull #120][issue120]
- Fixed the copy+delete path of `moveFile` to use `copyFile` instead of the blocking `std.file.copy` - [pull #120][issue120]
- Fixed `createDirectoryWatcher` to properly throw an exception in case of failure - [pull #120][issue120]
- Fixed ddoc warnings - [issue #103][issue103], [pull #119][issue119]
- Fixed the exception error message issued by `FileStream.write` (by Benjamin Schaaf) - [pull #114][issue114]

[issue103]: https://github.com/vibe-d/vibe-core/issues/103
[issue114]: https://github.com/vibe-d/vibe-core/issues/114
[issue115]: https://github.com/vibe-d/vibe-core/issues/115
[issue116]: https://github.com/vibe-d/vibe-core/issues/116
[issue117]: https://github.com/vibe-d/vibe-core/issues/117
[issue118]: https://github.com/vibe-d/vibe-core/issues/118
[issue119]: https://github.com/vibe-d/vibe-core/issues/119
[issue120]: https://github.com/vibe-d/vibe-core/issues/120
[issue121]: https://github.com/vibe-d/vibe-core/issues/121
[issue123]: https://github.com/vibe-d/vibe-core/issues/123


1.4.6 - 2018-12-28
==================

- Added `FileStream.truncate` - [pull #113][issue113]
- Using `MonoTime` instead of `Clock` for timeout functionality (by Hiroki Noda aka kubo39) - [pull #112][issue112]
- Fixed `UDPConnection.connect` to handle the port argument properly (by Mathias L. Baumann aka Marenz) - [pull #108][issue108]
- Fixed a bogus assertion failure in `TCPConnection.waitForData` when the connection gets closed concurrently (by Jan Jurzitza aka WebFreak001) - [pull #111][issue111]

[issue108]: https://github.com/vibe-d/vibe-core/issues/108
[issue111]: https://github.com/vibe-d/vibe-core/issues/111
[issue112]: https://github.com/vibe-d/vibe-core/issues/112
[issue113]: https://github.com/vibe-d/vibe-core/issues/113


1.4.5 - 2018-11-23
==================

- Compile fix for an upcoming Phobos version - [pull #100][issue100]
- Fixed as assertion error in the internal spin lock implementation when pressing Ctrl+C on Windows - [pull #99][issue99]
- Fixed host name string conversion for `SyslogLogger` - [issue vibe-d/vibe.d#2220][vibe.d-issue2220], [pull #102][issue102]
- Fixed callback invocation for unreferenced periodic timers - [issue #104][issue104], [pull #106][issue106]

[issue99]: https://github.com/vibe-d/vibe-core/issues/99
[issue100]: https://github.com/vibe-d/vibe-core/issues/100
[issue102]: https://github.com/vibe-d/vibe-core/issues/102
[issue104]: https://github.com/vibe-d/vibe-core/issues/104
[issue106]: https://github.com/vibe-d/vibe-core/issues/106
[vibe-issue2220]: https://github.com/vibe-d/vibe.d/issues/2220


1.4.4 - 2018-10-27
==================

- Compiler support updated to DMD 2.076.1 up to DMD 2.082.1 and LDC 1.6.0 up to 1.12.0 - [pull #92][issue92], [pull #97][issue97]
- Simplified worker task logic by avoiding an explicit event loop - [pull #95][issue95]
- Fixed an issue in `WindowsPath`, where an empty path was converted to "/" when cast to another path type - [pull #91][issue91]
- Fixed two hang issues in `TaskPool` causing the worker task processing to possibly hang at shutdown or to temporarily hang during run time - [pull #96][issue96]
- Fixed internal timer callback tasks leaking memory - [issue #86][issue86], [pull #98][issue98]

[issue91]: https://github.com/vibe-d/vibe-core/issues/91
[issue92]: https://github.com/vibe-d/vibe-core/issues/92
[issue95]: https://github.com/vibe-d/vibe-core/issues/95
[issue96]: https://github.com/vibe-d/vibe-core/issues/96
[issue97]: https://github.com/vibe-d/vibe-core/issues/97
[issue98]: https://github.com/vibe-d/vibe-core/issues/98


1.4.3 - 2018-09-03
==================

- Allows `switchToTask` to be called within a yield lock (deferred until the lock is elided)

1.4.2 - 2018-09-03
==================

- Fixed a potential infinite loop in the task scheduler causing 100% CPU use - [pull #88][issue88]
- Fixed `waitForDataAsync` when using in conjunction with callbacks that have scoped destruction - [pull #89][issue89]

[issue88]: https://github.com/vibe-d/vibe-core/issues/88
[issue89]: https://github.com/vibe-d/vibe-core/issues/89


1.4.1 - 2018-07-09
==================

- Fixed compilation errors for `ConnectionPool!TCPConnection` - [issue vibe.d#2109][vibe.d-issue2109], [pull #70][issue70]
- Fixed destruction behavior when destructors are run in foreign threads by the GC - [issue #69][issue69], [pull #74][issue74]
- Fixed a possible assertion failure for failed `connectTCP` calls - [pull #75][issue75]
- Added missing `setCommandLineArgs` API (by Thomas Weyn) - [pull #72][issue72]
- Using `MonoTime` for `TCPConnection` timeouts (by Boris Barboris) - [pull #76][issue76]
- Fixed the `Task.running` state of tasks that are scheduled to be run after an active `yieldLock` - [pull #79][issue79]
- Fixed an integer overflow bug in `(Local)ManualEvent.wait` (by Boris Barboris) - [pull #77][issue77]
- Disabled handling of `SIGABRT` on Windows to keep the default process termination behavior - [commit 463f4e4][commit463f4e4]
- Fixed event processing for `yield()` calls outside of a running event loop - [pull #81][issue81]

[issue69]: https://github.com/vibe-d/vibe-core/issues/69
[issue70]: https://github.com/vibe-d/vibe-core/issues/70
[issue72]: https://github.com/vibe-d/vibe-core/issues/72
[issue74]: https://github.com/vibe-d/vibe-core/issues/74
[issue75]: https://github.com/vibe-d/vibe-core/issues/75
[issue76]: https://github.com/vibe-d/vibe-core/issues/76
[issue77]: https://github.com/vibe-d/vibe-core/issues/77
[issue79]: https://github.com/vibe-d/vibe-core/issues/79
[issue81]: https://github.com/vibe-d/vibe-core/issues/81
[commit463f4e4]: https://github.com/vibe-d/vibe-core/commit/463f4e4efbd7ab919aaed55e07cd7c8012bf3e2c
[vibe.d-issue2109]: https://github.com/vibe-d/vibe.d/issues/2109


1.4.0 - 2018-03-08
==================

- Compiles on DMD 2.072.2 up to 2.079.0
- Uses the stdx-allocator package instead of `std.experimental.allocator` - note that this change requires version 0.8.3 of vibe-d to be used
- Added `TCPConnection.waitForDataAsync` to enable temporary detachment of a TCP connection from a fiber (by Francesco Mecca) - [pull #62][issue62]
- Fixed `TCPConnection.leastSize` to return numbers greater than one (by Pavel Chebotarev aka nexor) - [pull #52][issue52]
- Fixed a task scheduling assertion happening when worker tasks and timers were involved - [issue #58][issue58], [pull #60][issue60]
- Fixed a race condition in `TaskPool` leading to random assertion failures - [7703cc6][commit7703cc6]
- Fixed an issue where the event loop would exit prematurely when calling `yield` - [issue #66][issue66], [pull #67][issue67]
- Fixed/worked around a linker error on LDC/macOS - [issue #65][issue65], [pull #68][issue68]

[issue52]: https://github.com/vibe-d/vibe-core/issues/52
[issue58]: https://github.com/vibe-d/vibe-core/issues/58
[issue60]: https://github.com/vibe-d/vibe-core/issues/60
[issue62]: https://github.com/vibe-d/vibe-core/issues/62
[issue65]: https://github.com/vibe-d/vibe-core/issues/65
[issue66]: https://github.com/vibe-d/vibe-core/issues/66
[issue67]: https://github.com/vibe-d/vibe-core/issues/67
[issue68]: https://github.com/vibe-d/vibe-core/issues/68
[commit7703cc6]: https://github.com/vibe-d/vibe-core/commit/7703cc675f5ce56c1c8b4948e3f040453fd09791


1.3.0 - 2017-12-03
==================

- Compiles on DMD 2.071.2 up to 2.077.0
- Added a `timeout` parameter in `connectTCP` (by Boris Baboris) - [pull #44][issue44], [pull #41][issue41]
- Fixes the fiber event scheduling mechanism to not cause any heap allocations - this alone gives a performance boost of around 20% in the bench-dummy-http example - [pull #27][issue27]
- Added `FileInfo.hidden` property
- `pipe()` now returns the actual number of bytes written
- Fixed `TCPListener.bindAddress`
- Fixed a segmentation fault when logging from a non-D thread
- Fixed `setupWorkerThreads` and `workerThreadCount` - [issue #35][issue35]
- Added `TaskPool.threadCount` property
- Added an `interface_index` parameter to `UDPConnection.addMembership`
- `Task.tid` can now be called on a `const(Task)`

[issue27]: https://github.com/vibe-d/vibe-core/issues/27
[issue35]: https://github.com/vibe-d/vibe-core/issues/35
[issue41]: https://github.com/vibe-d/vibe-core/issues/41
[issue44]: https://github.com/vibe-d/vibe-core/issues/44


1.2.0 - 2017-09-05
==================

- Compiles on DMD 2.071.2 up to 2.076.0
- Marked a number of classes as `final` that were accidentally left as overridable
- Un-deprecated `GenericPath.startsWith` due to the different semantics compared to the replacement suggestion
- Added a `listenUDP(ref NetworkAddress)` overload
- Implemented the multicast related methods of `UDPConnection` - [pull #34][issue34]
- `HTMLLogger` now logs the fiber/task ID
- Fixed a deadlock caused by an invalid lock count in `LocalTaskSemaphore` (by Boris-Barboris) - [pull #31][issue31]
- Fixed `FileDescriptorEvent` to adhere to the given event mask
- Fixed `FileDescriptorEvent.wait` in conjunction with a finite timeout
- Fixed the return value of `FileDescriptorEvent.wait`
- Fixed handling of the `periodic` argument to the `@system` overload of `setTimer`

[issue31]: https://github.com/vibe-d/vibe-core/issues/31
[issue34]: https://github.com/vibe-d/vibe-core/issues/34


1.1.1 - 2017-07-20
==================

- Fixed/implemented `TCPListener.stopListening`
- Fixed a crash when using `NullOutputStream` or other class based streams
- Fixed a "dwarfeh(224) fatal error" when the process gets terminated due to an `Error` - [pull #24][issue24]
- Fixed assertion error when `NetworkAddress.to(Address)String` is called with no address set
- Fixed multiple crash and hanging issues with `(Local)ManualEvent` - [pull #26][issue26]

[issue24]: https://github.com/vibe-d/vibe-core/issues/24
[issue26]: https://github.com/vibe-d/vibe-core/issues/26


1.1.0 - 2017-07-16
==================

- Added a new debug hook `setTaskCreationCallback`
- Fixed a compilation error for `VibeIdleCollect`
- Fixed a possible double-free in `ManualEvent` that resulted in an endless loop - [pull #23][issue23]

[issue23]: https://github.com/vibe-d/vibe-core/issues/23


1.0.0 - 2017-07-10
==================

This is the initial release of the `vibe-core` package. The source code was derived from the original `:core` sub package of vibe.d and received a complete work over, mostly under the surface, but also in parts of the API. The changes have been made in a way that is usually backwards compatible from the point of view of an application developer. At the same time, vibe.d 0.8.0 contains a number of forward compatibility declarations, so that switching back and forth between the still existing `vibe-d:core` and `vibe-core` is possible without changing the application code.

To use this package, it is currently necessary to put an explicit dependency with a sub configuration directive in the DUB package recipe:
```
// for dub.sdl:
dependency "vibe-d:core" version="~>0.8.0"
subConfiguration "vibe-d:core" "vibe-core"

// for dub.json:
"dependencies": {
	"vibe-d:core": "~>0.8.0"
},
"subConfigurations": {
	"vibe-d:core": "vibe-core"
}
```
During the development of the 0.8.x branch of vibe.d, the default will eventually be changed, so that `vibe-core` is the default instead.


Major changes
-------------

- The high-level event and task scheduling abstraction has been replaced by the low level Proactor abstraction [eventcore][eventcore], which also means that there is no dependency to libevent anymore.
- GC allocated classes have been replaced by reference counted `struct`s, with their storage backed by a compact array together with event loop specific data.
- `@safe` and `nothrow` have been added throughout the code base, `@nogc` in some parts where no user callbacks are involved.
- The task/fiber scheduling logic has been unified, leading to a major improvement in robustness in case of exceptions or other kinds of interruptions.
- The single `Path` type has been replaced by `PosixPath`, `WindowsPath`, `InetPath` and `NativePath`, where the latter is an alias to either `PosixPath` or `WindowsPath`. This greatly improves the robustness of path handling code, since it is no longer possible to blindly mix different path types (especially file system paths and URI paths).
- Streams (`InputStream`, `OutputStream` etc.) can now also be implemented as `struct`s instead of classes. All API functions accept stream types as generic types now, meaning that allocations and virtual function calls can be eliminated in many cases and function inlining can often work across stream boundaries.
- There is a new `IOMode` parameter for read and write operations that enables a direct translation of operating system provided modes ("write as much as possible in one go" or "write only if possible without blocking").

[eventcore]: https://github.com/vibe-d/eventcore
