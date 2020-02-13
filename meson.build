project('vala-language-server', 'vala', 'c')

valac = meson.get_compiler('vala')
# libvala_version = run_command(valac, '--api-version').stdout().strip()
# 
# libvala = dependency('libvala-@0@'.format(libvala_version))

libvala = dependency('libvala-0.48')

deps = [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-2.0'),
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

src = files([
    'main.vala',
    'find_symbol.vala',
    'girdocumentation.vala',
    'list_symbols.vala',
    'projects/buildtarget.vala',
    'projects/compilation.vala',
    'projects/mesontarget.vala',
    'projects/simpletarget.vala',
    'protocol.vala',
    'reporter.vala',
    'textdocument.vala'
])

if host_machine.system() == 'windows'
    deps += dependency('gio-windows-2.0')
    src += 'windows.vapi'
    add_project_arguments(['--define=WINDOWS'], language: 'vala')
else
    deps += dependency('gio-unix-2.0')
endif

executable('vala-language-server',
           dependencies: deps,
           sources: [src, conf_file],
           vala_args: ['--pkg=posix', '--enable-gobject-tracing', '--fatal-warnings'],
           install: true)
