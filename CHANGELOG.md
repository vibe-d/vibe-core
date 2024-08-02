2.9.0 - 2024-08-02
==================

- Added `createStreamConnection` for creating a `TCPConnection` from an existing `StreamSocketFD` - [issue #151][issue151], [pull #405][issue405]
- `runTask` and related functions now accept `immutable` arguments - [issue #138][issue138], [pull #403][issue403]
- `parallel(Unordered)Map` now forwards the `length` property of the input range - [pull #404][issue404]
- Fixed `SyslogLogger` to behave properly w.r.t. concurrency and added `createSyslogLogger` - [issue #176][issue176], [pull #406][issue406], [pull #407][issue407], [pull #409][issue409]
- Fixed a compile error when building with `-profile` or when calling `asyncAwait` with a `noreturn` `cancel` callback - [issue #299][issue299], [issue #319][issue319], [pull #408][issue408]

[issue138]: https://github.com/vibe-core/vibe-core/issues/138
[issue151]: https://github.com/vibe-core/vibe-core/issues/151
[issue176]: https://github.com/vibe-core/vibe-core/issues/176
[issue299]: https://github.com/vibe-core/vibe-core/issues/299
[issue319]: https://github.com/vibe-core/vibe-core/issues/319
[issue403]: https://github.com/vibe-core/vibe-core/issues/403
[issue404]: https://github.com/vibe-core/vibe-core/issues/404
[issue405]: https://github.com/vibe-core/vibe-core/issues/405
[issue406]: https://github.com/vibe-core/vibe-core/issues/406
[issue407]: https://github.com/vibe-core/vibe-core/issues/407
[issue408]: https://github.com/vibe-core/vibe-core/issues/408
[issue409]: https://github.com/vibe-core/vibe-core/issues/409


2.8.5 - 2024-06-18
==================

- Fixes log arguments not being evaluated when no logger is logging the message - [pull #399][issue399]
- Fixes `relativeTo` to work with `const` arguments - [pull #400][issue400]

[issue399]: https://github.com/vibe-d/vibe-core/issues/399
[issue400]: https://github.com/vibe-d/vibe-core/issues/400


2.8.4 - 2024-04-06
==================

- Adds file/line number information to uncaught throwable diagnostic output - [pull #398][issue398]

[issue398]: https://github.com/vibe-d/vibe-core/issues/398


2.8.3 - 2024-04-03
==================

- Fixed some scope related deprecation warnings (by Mathias Lang aka Geod24) - [pull #392][issue392], [pull #393][issue393], [pull #393][issue393]
- Fixed temporary file creation on iOS - [pull #394][issue394]
- Uncaught throwables in tasks are now properly logged and generate an error message box on Windows for GUI applications - [pull #397][issue397]

[issue392]: https://github.com/vibe-d/vibe-core/issues/392
[issue393]: https://github.com/vibe-d/vibe-core/issues/393
[issue393]: https://github.com/vibe-d/vibe-core/issues/393
[issue394]: https://github.com/vibe-d/vibe-core/issues/394
[issue397]: https://github.com/vibe-d/vibe-core/issues/397


2.8.2 - 2024-02-19
==================

- Contains some purely internal API changes


2.8.1 - 2024-02-15
==================

- Contains some purely internal API changes


2.7.4 - 2024-02-12
==================

- Removed an assertion in `LockedConnection` that could be triggered from valid code - [pull #384][issue384]

[issue384]: https://github.com/vibe-d/vibe-core/issues/384


2.7.3 - 2024-01-17
==================

- Fixed a crash that could happen when a `ManualEvent` is still in waiting state at runtime shutdown


2.7.2 - 2024-01-15
==================

- `performInWorker` now compiles for callbacks returning `void` - [pull #377][issue377]
- Fixed a possible assertion failure in `TaskMutex` caused by a race condition in debug mode - [pull #378][issue378]
- `pipe` now avoids using the GC for buffer allocations in order to avoid pseudo memory leaks - [pull #381][issue381]

[issue376]: https://github.com/vibe-d/vibe-core/issues/376


2.7.1 - 2023-12-19
==================

- Fixed a regression introduced in 2.7.1 that caused a crash after using more than 100 concurrent fibers in a single thread - [issue376][pull #376]

[issue376]: https://github.com/vibe-d/vibe-core/issues/376


2.7.0 - 2023-12-19
==================

- Added `PipeConfig` for advanced `pipe()` behavior configuration - [issue371][pull #371]
- Added `vibe.core.concurrency.performInWorker` - [issue374][pull #374]
- Removed an assertion that failed at process exit when leaking `ManualEvent`/`TaskCondition` to the GC - [issue373][pull #373]
- Fixed a potential crash at process shutdown when leaking a `Channel!T` to the GC - [issue374][pull #374]
- Fixed uneven scheduling of worker tasks - [issue372][pull #372]
- Fixed a regression introduced by 2.6.0 causing rare crashes at process exit - [issue374][pull #374]
- Fixed an issue where hidden argument ownership in `runWorkerTaskH` resulted in a resource leak - [issue374][pull #374]

[issue371]: https://github.com/vibe-d/vibe-core/issues/371
[issue372]: https://github.com/vibe-d/vibe-core/issues/372
[issue373]: https://github.com/vibe-d/vibe-core/issues/373
[issue374]: https://github.com/vibe-d/vibe-core/issues/374


2.6.0 - 2023-12-14
==================

- Heavily reduced the overhead for `ManualEvent` and derived primitives when many waiters are present - [pull #370][issue370]
- `TaskPool` now allows to customize thread names - [pull #370][issue370]
- Added `TaskEvent.schedule` - [pull #370][issue370]

[issue370]: https://github.com/vibe-d/vibe-core/issues/370


2.5.1 - 2023-11-24
==================

- Increased the maximum size an `InterfaceProxy`


2.5.0 - 2023-11-24
==================

- Added `TaskSemaphore`, along with `createTaskSemaphore` and `createLocalTaskSemaphore` - [pull #368][issue368], [pull #369][issue369]
- Fixed `TCPConnection.read` to throw a `ReadTimeoutException` (by dushibaiyu) - [pull #359][issue359], [pull #366][issue366]
- Fixed the behavior of `LocalTaskSemaphore` and made the `priority` argument a type signed - [pull #369][issue369]

[issue359]: https://github.com/vibe-d/vibe-core/issues/359
[issue366]: https://github.com/vibe-d/vibe-core/issues/366
[issue368]: https://github.com/vibe-d/vibe-core/issues/368
[issue369]: https://github.com/vibe-d/vibe-core/issues/369


2.4.0 - 2023-10-01
==================

- Added `yieldUninterruptible` - [pull #364][issue364]
- Improved debugging `yieldLock` violations - [pull #364][issue364]
- Now depends on `vibe-container` instead of having to rely on private container implementations - [pull #365][issue365]

[issue364]: https://github.com/vibe-d/vibe-core/issues/364
[issue365]: https://github.com/vibe-d/vibe-core/issues/365


2.3.0 - 2023-09-29
==================

- Added `Monitor` primitive for statically checked mutex protection of data - [pull #360][issue360]
- Thread based I/O functions, such as directory listing, are now executed in a dedicated thread pool - [pull #361][issue362]
- `workerTaskPool` and `logicalProcessorCount` are now `nothrow` - [pull #361][issue361]
- Fixed `async()` erroneously running in a worker thread for non-isolated return types - [pull #363][issue363]

[issue360]: https://github.com/vibe-d/vibe-core/issues/360
[issue361]: https://github.com/vibe-d/vibe-core/issues/361
[issue362]: https://github.com/vibe-d/vibe-core/issues/362
[issue363]: https://github.com/vibe-d/vibe-core/issues/363


2.2.1 - 2023-09-15
==================

- Tested up to DMD 2.105.0/LDC 1.34.0
- Fixes a number of warnings related to `scope`, `in ref` and deprecated APIs - [pull #357][issue357], [pull #358][issue358]

[issue357]: https://github.com/vibe-d/vibe-core/issues/357
[issue358]: https://github.com/vibe-d/vibe-core/issues/358


2.2.0 - 2023-03-31
==================

- Made most synchronization primitives (e.g. `TaskMutex`) constructible/usable as `shared` - [pull #354][issue354]

[issue354]: https://github.com/vibe-d/vibe-core/issues/354


2.1.0 - 2023-03-17
==================

- Improved compilation speed both for vibe-core and its dependencies - [pull #350][issue350], [pull #353][issue353]
- `openFile` now doesn't bock the calling thread if eventcore 0.9.4 or newer is used - [pull #351][issue351]
- Added `FileMode.create` - [pull #351][issue351]
- Added `TCPListenOptions.ipTransparent` (by Adam Williams aka Tusanga) - [pull #349][issue349]

[issue349]: https://github.com/vibe-d/vibe-core/issues/349
[issue350]: https://github.com/vibe-d/vibe-core/issues/350
[issue351]: https://github.com/vibe-d/vibe-core/issues/351
[issue353]: https://github.com/vibe-d/vibe-core/issues/353


2.0.1 - 2023-03-08
==================

- Fixes `GenericPath.Segment.toString` - [pull #346][issue346]

[issue346]: https://github.com/vibe-d/vibe-core/issues/346


2.0.0 - 2023-03-04
==================


- Fixes all deprecation warnings related to DIP1000/DIP1021 (as of DMD 1.102.1) - [pull #329][issue329], [pull #339][issue339], [pull #340][issue340]
- Replaces `GenericPath.Segment` with `GenericPath.Segment2` from 1.x.x - [pull #336][issue336], [pull #342][issue342]
- Enforces `nothrow` callbacks as arguments to `runTask`/`runWorkerTask` - [pull #335][issue335]
- `OutputStream.write` now takes a `scope const` argument instead of `in` - [pull #329][issue329]
- Added `OutputStream.outputStreamVersion` (equal to `2`)
- Fixed a crash that could be caused by concurrently closing a TCP connection that was still being read from - [pull #338][issue338]
- Deprecated `Channel.empty` and `Channel.consumeOne` - [pull #344][issue344]

[issue329]: https://github.com/vibe-d/vibe-core/issues/329
[issue335]: https://github.com/vibe-d/vibe-core/issues/335
[issue336]: https://github.com/vibe-d/vibe-core/issues/336
[issue339]: https://github.com/vibe-d/vibe-core/issues/339
[issue340]: https://github.com/vibe-d/vibe-core/issues/340
[issue342]: https://github.com/vibe-d/vibe-core/issues/342
[issue344]: https://github.com/vibe-d/vibe-core/issues/344


1.23.0 - 2023-02-28
===================

- Deprecated the use of `GenericPath.Segment` in preparation to the changes coming to 2.0.0 - [pull #341][issue341]
- Added `OutputStream.outputStreamVersion` (equal to `1`)

[issue341]: https://github.com/vibe-d/vibe-core/issues/341


1.22.7 - 2023-02-20
===================

- (backported) Fixed a crash possibly caused by concurrent closing of a TCP connection that was still being read - [pull #338][issue338]

[issue338]: https://github.com/vibe-d/vibe-core/issues/338


1.22.6 - 2023-01-23
===================

- Updates compiler frontend support to range from 2.090.0 up to 2.101.2 - [pull #330][issue330]
- Fixes a socket descriptor leak after a connect timeout - [issue #331][issue331], [pull #332][issue332]
- Fixed a Windows issue when closing a TCP connection while concurrently reading from it - [pull #330][issue330]

[issue330]: https://github.com/vibe-d/vibe-core/issues/330
[issue331]: https://github.com/vibe-d/vibe-core/issues/331
[issue332]: https://github.com/vibe-d/vibe-core/issues/332


1.22.5 - 2022-11-04
===================

- Added an optional `timeout` parameter to `runEventLoopOnce` (by Grillo del Mal) - [pull #325][issue325]
- Marked `peer_address` parameters of the `UDPConnection` API as `scope` - [pull #321][issue321]
- Fixed compilation errors on iOS - [pull #323][issue323]
- Fixed an issue with non-deterministic destruction in `FixedRingBuffer` - [pull #321][issue321]
- Fixed a possible infinite recursion when using `yield()` outside of a task - [pull #326][issue326]

[issue321]: https://github.com/vibe-d/vibe-core/issues/321
[issue323]: https://github.com/vibe-d/vibe-core/issues/323
[issue325]: https://github.com/vibe-d/vibe-core/issues/325
[issue326]: https://github.com/vibe-d/vibe-core/issues/326


1.22.4 - 2022-05-26
===================

- Annotate `inout` functions with `return` (By Dennis Korpel) - [pull #313][issue313]
- Better error message for GenericPath.fromTrustedString - [pull #314][issue314]

[issue313]: https://github.com/vibe-d/vibe-core/issues/313
[issue314]: https://github.com/vibe-d/vibe-core/issues/314


1.22.3 - 2022-04-01
===================

- Added `ConnectionPool.add()/remove()` (by Ömer Faruk Irmak) - [pull #303][issue303]
- Added a timeout based overload of `TaskMutex.wait` (by Ömer Faruk Irmak) - [pull #303][issue303]
- Fixed compilation on DMD frontend/runtime version prior to 2.090.0

[issue303]: https://github.com/vibe-d/vibe-core/issues/303


1.22.2 - 2022-03-26
===================

- Fixed `parallelMap` to clean up processed elements without relying on the GC - [pull #311][issue311]
- Fixed `runWorkerTaskH`/`TaskPool.runTaskH` to not create a GC closure with the passed arguments - [pull #312][issue312]
- Fixed `isWeaklyIsolated` to consider dynamic arrays of `shared` values weakly isolated - [pull #312][issue312]

[issue311]: https://github.com/vibe-d/vibe-core/issues/311
[issue312]: https://github.com/vibe-d/vibe-core/issues/312


1.22.1 - 2022-03-04
===================

- Reduced resource overhead for tasks that don't use `std.concurrency` - [pull #309][issue309]
- Added `Future.task` property - [pull #308][issue308]
- `shared`/`immutable` delegates are now treated as (weakly) isolated - [pull #309][issue309]

[issue308]: https://github.com/vibe-d/vibe-core/issues/308
[issue309]: https://github.com/vibe-d/vibe-core/issues/309


1.22.0 - 2021-12-16
===================

- Fixed `FileStream.leastSize` in case the file pointer is past the file size - [pull #304][issue304]
- Added `TCPConnection.fd` and `UDPConnection.fd` properties (by Hiroki Noda aka kubo39) - [pull #296][issue296]

[issue296]: https://github.com/vibe-d/vibe-core/issues/296
[issue304]: https://github.com/vibe-d/vibe-core/issues/304


1.21.0 - 2021-08-31
===================

- Added `TruncatableStream` and `ClosableRandomAccessStream` - `FileStream` now implements the latter - [pull #294][issue294]

[issue294]: https://github.com/vibe-d/vibe-core/issues/294


1.20.0 - 2021-08-25
===================

- `core.file`: Fix `-preview=in` support - [pull #290][issue290]
- Mark `TaskFiberQueue.insert` functions `@trusted` (By Dennis Korpel) - [pull #291][issue291]
- Fix possibly hanging process after SIGINT/SIGTERM - [pull #292][issue292]

[issue290]: https://github.com/vibe-d/vibe-core/issues/290
[issue291]: https://github.com/vibe-d/vibe-core/issues/291
[issue292]: https://github.com/vibe-d/vibe-core/issues/292


1.19.0 - 2021-08-14
===================

- Adds a `UDPListenOptions` argument to `listenUDP` - [pull #286][issue286]

[issue286]: https://github.com/vibe-d/vibe-core/issues/286


1.18.1 - 2021-07-04
===================

- Fixes compilation on Android - [pull #281][issue281]

[issue281]: https://github.com/vibe-d/vibe-core/issues/281


1.18.0 - 2021-05-21
===================

- Deprecated calling `runTask` and its variants with non-`nothrow` task callables - [pull #279][issue279]
	- Uncaught exceptions in tasks are highly error prone due to the often undetected termination of such a task
	- Alternative approaches, such as re-throwing from `join` is neither thread-safe, nor statically checkable
	- Using `nothrow` callables will be mandatory for vibe-core 2.x.x
- Made more parts of the API `nothrow`
- Added `getLogLevel` - [issue #235][issue235], [pull #280][issue280]

[issue235]: https://github.com/vibe-d/vibe-core/issues/235
[issue279]: https://github.com/vibe-d/vibe-core/issues/279
[issue280]: https://github.com/vibe-d/vibe-core/issues/280


1.17.1 - 2021-05-18
===================

- Fixed a regression in `listDirectory` caused by the linker fix for macOS/M1 - [pull #277][issue277]

[issue277]: https://github.com/vibe-d/vibe-core/issues/277


1.17.0 - 2021-05-17
===================

- Made more parts of the API `nothrow` - [pull #274][issue274]
- Added support for debugging currently running tasks via debug version `VibeRunningTasks` and `printRunningTasks` - [pull #275][issue275]
- Added a `NativePath` based overload for recursive `createDirectory` - [pull #272][issue272]
- Fixed linking `fstatat` on macOS/ARM (by kookman) - [pull #271][issue271], [issue #269][issue269]
- Fixed `pipe()` to not close the pipe file descriptors before returning (by Tomáš Chaloupka) - [pull #268][issue268], [issue #267][issue267]
- Fixed unnecessary creation of event drivers during shutdown for threads that didn't have one - [pull #276][issue276]

[issue267]: https://github.com/vibe-d/vibe-core/issues/267
[issue268]: https://github.com/vibe-d/vibe-core/issues/268
[issue269]: https://github.com/vibe-d/vibe-core/issues/269
[issue271]: https://github.com/vibe-d/vibe-core/issues/271
[issue272]: https://github.com/vibe-d/vibe-core/issues/272
[issue274]: https://github.com/vibe-d/vibe-core/issues/274
[issue275]: https://github.com/vibe-d/vibe-core/issues/275
[issue276]: https://github.com/vibe-d/vibe-core/issues/276


1.16.0 - 2021-03-26
===================

- Added a sub directory predicate for recursive directory listing - [pull #266][issue266]

[issue266]: https://github.com/vibe-d/vibe-core/issues/266


1.15.0 - 2021-03-24
===================

- Added a batch overload of `getFileInfo` - [pull #265][issue265]
- `TaskMutex`' constructor is now `nothrow` - [pull #264][issue264]

[issue264]: https://github.com/vibe-d/vibe-core/issues/264
[issue265]: https://github.com/vibe-d/vibe-core/issues/265


1.14.0 - 2021-03-15
===================

- Compatibility fixes for POSIX-based platforms, notable Musl-based ones - [pull #249][issue249]
- Added a CI task to ensure compatibility with Musl - [pull #250][issue250]
- Various optimizations to `vibe.core.path: InetPath` - [pull #251][issue251]
- `GenericPath.Segment[2].opCast` is now `const`  - [pull #252][issue252]
- Compatibility fix for upcoming (v2.097.0) deprecation - [pull #253][issue253]
- Improve documentation for `setTimer` and `sleep` - [pull #255][issue255]
- Ensure that a timer callback is never invoked concurrently - [pull #256][issue256], [pull #260][issue260], [pull #262][issue262]
- Make `LocalTaskSemaphore.this` `nothrow` for compatibility with v2.096.0 - [pull #259][issue259]

[issue249]: https://github.com/vibe-d/vibe-core/issues/249
[issue250]: https://github.com/vibe-d/vibe-core/issues/250
[issue251]: https://github.com/vibe-d/vibe-core/issues/251
[issue252]: https://github.com/vibe-d/vibe-core/issues/252
[issue253]: https://github.com/vibe-d/vibe-core/issues/253
[issue255]: https://github.com/vibe-d/vibe-core/issues/255
[issue256]: https://github.com/vibe-d/vibe-core/issues/256
[issue259]: https://github.com/vibe-d/vibe-core/issues/259
[issue260]: https://github.com/vibe-d/vibe-core/issues/260
[issue262]: https://github.com/vibe-d/vibe-core/issues/262


1.13.0 - 2021-01-15
===================

- Added `parallelMap` and `parallelUnorderedMap` - [pull #247][issue247]
- Added `GenericPath.filenameExtension`, as well as `Segment2.extension` and `.withoutExtension` properties - [pull #246][issue246]
- Added `workerTaskPool` accessor to get the default task pool - [pull #247][issue247]
- Added `GenericPath.normalized` - [pull #246][issue246]

[issue246]: https://github.com/vibe-d/vibe-core/issues/246
[issue247]: https://github.com/vibe-d/vibe-core/issues/247


1.12.0 - 2021-01-12
===================

- Added `ChannelConfig` and a channel mode to minimize synchronization overhead - [pull #241][issue241]
- Added `DirectoryListMode` and optimized `listDirectory`/`iterateDirectory` - [pull #242][issue242], [pull #244][issue244]
- Optimized `PipeMode.concurrent` for fast streams - [pull #243][issue243]

[issue241]: https://github.com/vibe-d/vibe-core/issues/241
[issue242]: https://github.com/vibe-d/vibe-core/issues/242
[issue243]: https://github.com/vibe-d/vibe-core/issues/243
[issue244]: https://github.com/vibe-d/vibe-core/issues/244


1.11.3 - 2020-12-18
===================

- Fixed a task scheduling issue for busy worker tasks that call `yield()` periodically - [pull #240][issue240]
- Fixed a compilation error on DMD 2.079.0

[issue240]: https://github.com/vibe-d/vibe-core/issues/240


1.11.2 - 2020-12-12
===================

- `ScopedMutexLock` is now `nothrow`, using assertions instead of `Exception` in case of misuse
- Fixes a possible "access denied" error for directories that have been iterated using `listDirectory` on Windows - [pull #239][issue239]

[issue239]: https://github.com/vibe-d/vibe-core/issues/239


1.11.1 - 2020-11-25
===================

- Fixed a bogus assertion failure ("A task cannot interrupt itself") - [pull #236][issue236]
- Fixed a deprecation warning triggered in vibe:http - [pull #234][issue234]

[issue234]: https://github.com/vibe-d/vibe-core/issues/234
[issue236]: https://github.com/vibe-d/vibe-core/issues/236


1.11.0 - 2020-10-24
===================

- Added a concurrent mode to `pipe()` using `PipeMode.concurrent` to improve throughput in I/O limited situations - [pull #233][issue233]

[issue233]: https://github.com/vibe-d/vibe-core/issues/233


1.10.3 - 2020-10-15
===================

- Fixed `waitForDataEx` to return `WaitForDataStatus.timeout` for zero-timeouts if the connection is still alive [pull #232][issue232]

[issue232]: https://github.com/vibe-d/vibe-core/issues/232


1.10.2 - 2020-09-18
===================

- Fixed a critical data corruption bug caused by eventcore's `cancelRead`/`cancelWrite` - note that this fix makes `File.read` and `write` uninterruptible - [pull #227][issue227]
- Fixed `InterfaceProxy!T` to behave correctly for `null` target instances - [pull #228][issue228]

[issue227]: https://github.com/vibe-d/vibe-core/issues/227
[issue228]: https://github.com/vibe-d/vibe-core/issues/228


1.10.1 - 2020-08-31
===================

- Added support for upcoming DMD 2.094.0's `-preview=in` switch - [pull #225][pull225]

[pull225]: https://github.com/vibe-d/vibe-core/issues/225


1.10.0 - 2020-08-24
===================

- The minimum supported compiler has been raised to v2.079.0
- The `log` (`log`, `logTrace`, `logInfo`...) in `vibe.core.log` have been simplified
	to take the module/file/line as default runtime argument as opposed to compile-time - 
	this could cause breakage if you were explicitly forwarding those arguments
- Some places were previously using `logDebug` for full exception error message,
	and were using various method to ensure `nothrow`ness.
	All full exception stacktrace are now printed only in diagnostic mode.
- Full details are available in [pull #212][pull212].

[pull212]: https://github.com/vibe-d/vibe-core/issues/212


1.9.4 - 2020-08-21
==================

- Add optional timeout parameter to resolveHost - [pull #220][issue220]
- Fix exclusion list to properly exclude broken LDC releases - [pull #221][issue221]
- Workaround dub build by using `--single` in the test - [pull #223][issue223]
- Cleanup deprecations in test-suite and update release notes - [pull #222][issue222]

[issue220]: https://github.com/vibe-d/vibe-core/issues/220
[issue221]: https://github.com/vibe-d/vibe-core/issues/221
[issue222]: https://github.com/vibe-d/vibe-core/issues/222
[issue223]: https://github.com/vibe-d/vibe-core/issues/223


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
