[![vibe.d](https://vibed.org/images/title-new.png)](https://vibed.org)

vibe.d core package
===================

The core package provides the low level I/O and concurrency primitives that are used to implement the higher level systems:

 - Event loop management
 - Fiber based lightweight tasks, including task local storage and `std.concurrency` integration
 - Files, sockets, timers
 - Stream type definitions (used for files, sockets and higher level stream types)
 - Synchronization primitives (mutexes, condition variables, semaphores, cross task/cross thread events)
 - Logging facilities
 - Command line argument parsing
 - Various smaller utilities

The fundamental building block is the fiber based task concept, together with the event based asynchronous I/O model. This enables developing highly scalable I/O concurrent applications without running into the complexities and design implications that asynchronous I/O programming models usually impose. See the [features page](https://vibed.org/features) for a more detailed explanation.

[![DUB Package](https://img.shields.io/dub/v/vibe-core.svg)](https://code.dlang.org/packages/vibe-core)
[![Posix and Windows Build Status](https://github.com/vibe-d/vibe-core/actions/workflows/test.yml/badge.svg)](https://github.com/vibe-d/vibe-core/actions/workflows/test.yml)
[![Musl Build Status](https://github.com/vibe-d/vibe-core/actions/workflows/musl.yml/badge.svg)](https://github.com/vibe-d/vibe-core/actions/workflows/musl.yml)

Supported compilers
-------------------

The following compilers are tested and supported:

- DMD 2.101.2
- DMD 2.092.0
- DMD 2.091.1
- LDC 1.30.0
- LDC 1.20.1

Supported up to 1.22.5:
- DMD 2.085.1
- DMD 2.079.0
- LDC 1.15.0
- LDC 1.14.0
- LDC 1.9.0

Supported up to 1.6.2:
- DMD 2.078.3
- LDC 1.8.0

Supported up to 1.4.7:

- DMD 2.077.1
- DMD 2.076.1
- LDC 1.7.0
- LDC 1.6.0

Supported up to 1.4.3:

- DMD 2.075.1
- DMD 2.074.1
- DMD 2.073.2
- DMD 2.072.2
- LDC 1.5.0
- LDC 1.4.0
- LDC 1.3.0
- LDC 1.2.0

Supported up to 1.3.0:

- DMD 2.071.2
- LDC 1.1.0

Supported up to 1.1.1:

- DMD 2.070.2
- LDC 1.0.0


Separation of the former `vibe-d:core` package
----------------------------------------------

This is the successor of the `vibe-d:core` sub package of [vibe.d 0.7.x](https://github.com/rejectedsoftware/vibe.d.git). The API is mostly compatible from a library user point of view, but the whole library has received some heavy lifting under the surface, close to a rewrite. Most classes have been replaced by reference counting structs and `@safe nothrow` attributes are now used throughout the library, whenever possible. Adding `@nogc` on the other hand could only be done in a very limited context due to its viral nature and the lack of an `@trusted` equivalent.

Another major design change is that instead of the previous driver model, there is now a separate, lower-level event loop abstraction ([eventcore](https://github.com/vibe-d/eventcore.git)) which follows a callback based Proactor pattern. The logic to schedule fibers based on events has been pulled out of this abstraction and is now maintained as a single function, leading to a huge improvment in terms of robustness (most issues in the previous implementation have probably never surfaced in practice, but there turned out to be lots of them).

Finally, the stream design has received two big changes. Streams can now either be implemented as classes, as usual, or they can be implemented as structs in a duck typing/DbC fashion. This, coupled with templated wrapper stream types, allows to eliminate the overhead of virtual function calls, enables reference counting instead of GC allocations, and allows the compiler to inline across stream boundaries. The second change to streams is the added support for an [`IOMode`](https://github.com/vibe-d/eventcore/blob/c242fdae16470ae4dc4e7e6578d582c1d3ba57ec/source/eventcore/driver.d#L533) parameter that enables I/O patterns as they are possible when using OS sockets directly. The `leastSize` and `dataAvailableForRead` properties will in turn be deprecated.
