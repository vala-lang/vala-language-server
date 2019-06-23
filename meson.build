project('vala-language-server', 'vala', 'c')

add_project_arguments(['--vapidir', join_paths(meson.source_root(), 'vapi')],
            language: 'vala')

valac = meson.get_compiler('vala')
libvala_version = run_command(valac, '--api-version').stdout().strip()

libvala = dependency('libvala-@0@'.format(libvala_version))

os_type = host_machine.system()
if os_type == 'windows'
    io_vapi = meson.get_compiler('vala').find_library('win32io', dirs: join_paths(meson.source_root(), 'vapi'))    
    io_dep = dependency('gio-windows-2.0')
    io_dep = declare_dependency(dependencies: [io_dep, io_vapi])
else
    io_dep = dependency('gio-unix-2.0')
endif

deps = [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gee-0.8'),
    dependency('jsonrpc-glib-1.0'),
    io_dep,
    libvala,
]

conf = configuration_data()
conf.set('LIBVALA_VERSION', libvala.version())

conf_file = configure_file(input: 'config.vala.in',
                           output: 'config.vala',
                           configuration: conf)

src = files([
    'main.vala',
    'protocol.vala',
    'reporter.vala',
    'context.vala',
    'iterator.vala',
    'vala038_workarounds.vala',
])

executable('vala-language-server',
           dependencies: deps,
           sources: [src, conf_file],
           vala_args: ['-D', os_type.to_upper(), '--pkg=posix', '--enable-gobject-tracing'],
           install: true)
