project('vala-language-server', 'vala', 'c',
  version: '0.1-alpha',
  license: 'LGPL2.1+')

valac = meson.get_compiler('vala')
cc = meson.get_compiler('c')
# libvala_version = run_command(valac, '--api-version').stdout().strip()
# 
# libvala = dependency('libvala-@0@'.format(libvala_version))

libvala = dependency('libvala-0.48')
libgobject_dep = dependency('gobject-2.0')

deps = [
    dependency('glib-2.0'),
    libgobject_dep,
    dependency('gio-2.0'),
    dependency('gee-0.8'),
    dependency('jsonrpc-glib-1.0'),
    libvala,
    valac.find_library('posix'),
]

conf = configuration_data()
conf.set('LIBVALA_VERSION', libvala.version())

conf_file = configure_file(input: 'config.vala.in',
                           output: 'config.vala',
                           configuration: conf)

subdir('plugins/gnome-builder')

vls_src = files([
    'main.vala',
    'find_symbol.vala',
    'list_symbols.vala',
    'projects/buildtarget.vala',
    'projects/compilation.vala',
    'projects/mesontarget.vala',
    'projects/simpletarget.vala',
    'protocol.vala',
    'reporter.vala',
    'textdocument.vala',
    'util.vala'
])

if host_machine.system() == 'windows'
    deps += dependency('gio-windows-2.0')
    vls_src += 'windows.vapi'
    add_project_arguments(['--define=WINDOWS'], language: 'vala')
else
    deps += dependency('gio-unix-2.0')
endif

if get_option('parse_system_girs')
  vls_src += 'girdocumentation.vala'
  add_project_arguments(['--define=PARSE_SYSTEM_GIRS'], language: 'vala')
endif

if get_option('active_parameter')
  add_project_arguments(['--define=VALA_FEATURE_INITIAL_ARGUMENT_COUNT'], language: 'vala')
endif

add_project_arguments(['--enable-gobject-tracing', '--fatal-warnings'], language: 'vala')

if get_option('debug_mem')
  subdir('lib')
  deps += libgobject_list_dep
endif

executable('vala-language-server',
  dependencies: deps,
  sources: [vls_src, conf_file],
  install: true)

executable('vls-testclient',
  dependencies: deps,
  sources: files(['tests/testclient.vala', 'util.vala']),
  install: false)
