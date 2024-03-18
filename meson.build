project(
    'vibe-core',
    ['d'],
    license: 'MIT',
    meson_version: '>=1.3.1',
)

subdir('source/vibe')

eventcore_dep = dependency('eventcore', fallback : ['eventcore', 'eventcore_dep'])
stdx_allocator_dep = dependency('stdx-allocator', fallback : ['stdx-allocator', 'allocator_dep'])

vibe_core_dep = declare_dependency(
    dependencies: [
        eventcore_dep,
        stdx_allocator_dep,
    ],
    sources: sources,
    include_directories: imports_dir,
)

vibe_core_test_exe = executable('vibe-test_core',
    d_unittest: true,
    dependencies: [vibe_core_dep],
    link_args: '-main'
)

test('vibe-test_core', vibe_core_test_exe)
