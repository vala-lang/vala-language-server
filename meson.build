project('vala-language-server', 'vala', 'c')

libvala = dependency('libvala-0.42')

deps = [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-unix-2.0'),
    dependency('gee-0.8'),
    dependency('jsonrpc-glib-1.0'),
    libvala,
]

#conf = configuration_data()
#conf.set('LIBVALA_VERSION', libvala.version())

#conf_vapi = configure_file(input: 'config.vala.in',
#                           output: 'config.vala',
#                           configuration: conf)

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
           sources: src,
           vala_args: ['--pkg=posix', '--enable-gobject-tracing'],
           install: true)
