project('vala-language-server', 'vala', 'c')

valac = meson.get_compiler('vala')
libvala_version = run_command(valac, '--api-version').stdout().strip()

libvala = dependency('libvala-@0@'.format(libvala_version))

deps = [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-unix-2.0'),
    dependency('gee-0.8'),
    dependency('jsonrpc-glib-1.0'),
    libvala,
]

conf = configuration_data()
conf.set('LIBVALA_VERSION', libvala.version())

conf_file = configure_file(input: 'config.vala.in',
                           output: 'config.vala',
                           configuration: conf)

subdir('gnome-builder')

util = files([
    'reporter.vala',
    'context.vala',
    'vala038_workarounds.vala',
    'text_document.vala',
])

src = files([
    'main.vala',
    'protocol.vala',
    'iterator.vala',
])

executable('vala-language-server',
           dependencies: deps,
           sources: [src, util, conf_file],
           vala_args: ['--pkg=posix', '--enable-gobject-tracing', '--fatal-warnings'],
           install: true)

subdir('debug-ui')