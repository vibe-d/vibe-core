# Meson file for Vibe Core
project(
    'Vibe Core', 
    'd',
    version: '1.13.1'
)

project_soversion      = '0'
project_version_suffix = ''
project_version        = meson.project_version()
project_version_full   = project_version + project_version_suffix

source_root = meson.source_root()
build_root = meson.build_root()

pkgc = import('pkgconfig')

# Dependencies
eventcore_dep = dependency('eventcore', version: '>=0.9.2')
stdx_allocator_dep = dependency('stdx-allocator', version: '>=2.77.0')

vibe_core_deps = [eventcore_dep, stdx_allocator_dep]
vibe_core_src_dir = include_directories('source')

vibe_core_src = [
    'source/vibe/appmain.d',
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
]

#
# Install Includes
#
install_subdir('source/vibe/', install_dir: 'include/d/vibe/')


#
# Build Targets
#

# Basic I/O and concurrency primitives, as well as low level utility functions
vibe_core_lib = library('vibe-core',
    [vibe_core_src],
    include_directories: vibe_core_src_dir,
    install: true,
    dependencies: vibe_core_deps,
    version: project_version,
    soversion: project_soversion
)
pkgc.generate(name: 'vibe-core',
    libraries: [vibe_core_lib],
    requires: ['eventcore', 'stdx-allocator'],
    subdirs: 'd/vibe',
    version: project_version,
    description: 'Basic I/O and concurrency primitives, as well as low level utility functions of Vibe.'
)

vibe_core_dep = declare_dependency(
    link_with: vibe_core_lib,
    include_directories: vibe_core_src_dir,
    dependencies: vibe_core_deps,
)

#
# Tests
#
vibe_test_core_exe = executable('vibe-test_core',
    [vibe_core_src],
    d_unittest: true,
    dependencies: [vibe_core_dep],
    d_args: meson.get_compiler('d').unittest_args(),
    link_args: '-main'
)
test('vibe-test_core', vibe_test_core_exe)
