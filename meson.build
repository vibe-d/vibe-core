project(
    'vibe-core',
    'd',
    license: 'MIT',
    version: '1.22.4'
)

src = files(
    'source/vibe/core/args.d',
    'source/vibe/core/channel.d',
    'source/vibe/core/concurrency.d',
    'source/vibe/core/connectionpool.d',
    'source/vibe/core/core.d',
    'source/vibe/core/file.d',
    'source/vibe/core/internal/release.d',
    'source/vibe/core/log.d',
    'source/vibe/core/net.d',
    'source/vibe/core/parallelism.d',
    'source/vibe/core/path.d',
    'source/vibe/core/process.d',
    'source/vibe/core/stream.d',
    'source/vibe/core/sync.d',
    'source/vibe/core/task.d',
    'source/vibe/core/taskpool.d',
    'source/vibe/internal/allocator.d',
    'source/vibe/internal/array.d',
    'source/vibe/internal/async.d',
    'source/vibe/internal/freelistref.d',
    'source/vibe/internal/hashmap.d',
    'source/vibe/internal/interfaceproxy.d',
    'source/vibe/internal/list.d',
    'source/vibe/internal/string.d',
    'source/vibe/internal/traits.d',
    'source/vibe/internal/typetuple.d',
)

allocator_dep = dependency('stdx-allocator')
eventcore_dep = dependency('eventcore')
#~ eventcore_dep = subproject('eventcore').get_variable('eventcore_dep')

vibe_core_lib = library(
	'vibe-core',
    sources: src,
    include_directories: include_directories('source'),
    dependencies: [allocator_dep, eventcore_dep],
)

vibe_core_dep = declare_dependency(
    link_with: vibe_core_lib,
)

meson.override_dependency('vibe-core', vibe_core_dep)
