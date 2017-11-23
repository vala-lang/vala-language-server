project('vala-language-server', 'vala', 'c')

jsonrpc_sp = subproject('jsonrpc-glib')

libvala = dependency('libvala-0.38')

deps = [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-unix-2.0'),
    libvala,
    jsonrpc_sp.get_variable('libjsonrpc_glib_dep'),
    jsonrpc_sp.get_variable('libjsonrpc_glib_vapi'),
]

#conf = configuration_data()
#conf.set('LIBVALA_VERSION', libvala.version())

#conf_vapi = configure_file(input: 'config.vala.in',
#                           output: 'config.vala',
#                           configuration: conf)

src = files([
    'main.vala',
    'protocol.vala',
    'report.vala',
])

executable('vala-language-server',
           dependencies: deps,
           sources: src,
           vala_args: ['--pkg', 'posix'])
