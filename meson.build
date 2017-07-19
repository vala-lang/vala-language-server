project('vala-language-server', 'vala', 'c')

jsonrpc_sp = subproject('jsonrpc-glib')

deps = [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-unix-2.0'),
    jsonrpc_sp.get_variable('libjsonrpc_glib_dep'),
    jsonrpc_sp.get_variable('libjsonrpc_glib_vapi'),
]

src = files([
    'main.vala',
])

executable('vala-language-server',
           dependencies: deps,
           sources: src,
           vala_args: ['--pkg', 'posix'])
