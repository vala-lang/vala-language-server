project('vala-language-server', 'vala', 'c',
  version: '0.48.4',
  license: 'LGPL2.1+',
  default_options: [
    'default_library=static',
    'c_std=gnu11'       # for C subprojects
  ]
)

valac = meson.get_compiler('vala')
libvala_version = run_command(valac, '--api-version').stdout().strip()
if not libvala_version.version_compare('>=0.48' )
  error('libvala needs to be 0.48 or above')
endif

extra_vala_sources = []

libvala = dependency('libvala-@0@'.format(libvala_version), version: '>= 0.48.12')

libgobject_dep = dependency('gobject-2.0')
libjsonrpc_glib_dep = dependency('jsonrpc-glib-1.0', version: '>= 3.28', required: false)
if not libjsonrpc_glib_dep.found()
    # don't use introspection with static library as it requires a recent version of GIR
    jsonrpc_glib = subproject('jsonrpc-glib', default_options: ['with_introspection=false'])
    libjsonrpc_glib_dep = jsonrpc_glib.get_variable('libjsonrpc_glib_dep')
    extra_vala_sources += files('vapi/jsonrpc-glib-1.0.vapi')
endif

deps = [
    dependency('glib-2.0'),
    libgobject_dep,
    dependency('gio-2.0'),
    dependency('gee-0.8'),
    dependency('json-glib-1.0'),
    libjsonrpc_glib_dep,
    libvala,
    valac.find_library('posix'),
]

if libjsonrpc_glib_dep.version() >= '3.30'
  add_project_arguments(['--define=WITH_JSONRPC_GLIB_3_30'], language: 'vala')
endif

# let Vala add the appropriate defines for GLIB_X_X
add_project_arguments(['--target-glib=auto'], language: 'vala')

if get_option('debug_mem')
  libgobject_list_proj = subproject('gobject-list-prince781')
  deps += libgobject_list_proj.get_variable('libgobject_list_dep')
endif

conf = configuration_data()
conf.set('LIBVALA_VERSION', libvala.version())
conf.set('PROJECT_BUGSITE', 'https://github.com/vala-lang/vala-language-server/issues')
conf.set('PROJECT_NAME', meson.project_name())

conf_file = configure_file(input: 'config.vala.in',
                           output: 'config.vala',
                           configuration: conf)

version_file = vcs_tag(input: 'version.vala.in',
                       output: 'version.vala',
                       command: ['git', 'describe', '--tags', '--dirty'])

add_project_arguments(['--enable-gobject-tracing', '--fatal-warnings'], language: 'vala')

extra_vala_sources += files([
  'src/util.vala'
])

if host_machine.system() == 'windows'
    deps += dependency('gio-windows-2.0')
    extra_vala_sources += files(['src/windows.vapi'])
    add_project_arguments(['--define=WINDOWS'], language: 'vala')
else
    deps += dependency('gio-unix-2.0')
endif

subdir('data')
subdir('src')

if get_option('plugins')
  subdir('plugins/gnome-builder')
endif

if get_option('tests')
  subdir('test')
endif
