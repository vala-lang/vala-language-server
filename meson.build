project('vala-language-server', 'vala', 'c',
  version: '0.48-alpha',
  license: 'LGPL2.1+',
  default_options: [
    'default_library=static'
  ]
)

valac = meson.get_compiler('vala')
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
    dependency('json-glib-1.0'),
    libvala,
    valac.find_library('posix'),
]

libjsonrpc_glib_dep = dependency('jsonrpc-glib-1.0', version: '>= 3.30', required: false)
if not libjsonrpc_glib_dep.found()
  libjsonrpc_glib_proj = subproject('jsonrpc-glib-3.34.0-prince781')
  libjsonrpc_glib_dep = libjsonrpc_glib_proj.get_variable('libjsonrpc_glib_dep')
  deps += libjsonrpc_glib_proj.get_variable('libjsonrpc_glib_vapi')
endif
deps += libjsonrpc_glib_dep

if get_option('debug_mem')
  libgobject_list_proj = subproject('gobject-list-prince781')
  deps += libgobject_list_proj.get_variable('libgobject_list_dep')
endif

conf = configuration_data()
conf.set('LIBVALA_VERSION', libvala.version())

conf_file = configure_file(input: 'config.vala.in',
                           output: 'config.vala',
                           configuration: conf)

add_project_arguments(['--enable-gobject-tracing', '--fatal-warnings'], language: 'vala')

extra_vala_sources = files([
  'src/util.vala',
])

if host_machine.system() == 'windows'
    deps += dependency('gio-windows-2.0')
    extra_vala_sources += 'windows.vapi'
    add_project_arguments(['--define=WINDOWS'], language: 'vala')
else
    deps += dependency('gio-unix-2.0')
endif

subdir('plugins/gnome-builder')
subdir('src')
subdir('test')
