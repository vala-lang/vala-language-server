project('vala-language-server', 'vala', 'c',
  version: '0.56.0',
  license: 'LGPL2.1+',
  default_options: [
    'default_library=static',
    'c_std=gnu11'       # for C subprojects
  ]
)

valac = meson.get_compiler('vala')
libvala_version = run_command(valac, '--api-version').stdout().strip()
if not libvala_version.version_compare('>=0.56')
  error('libvala needs to be 0.56 or above')
endif

platform_vala_sources = []

libvala = dependency('libvala-@0@'.format(libvala_version), version: '>= 0.56')

libgobject_dep = dependency('gobject-2.0')
lsp_glib_dep = dependency(
  'lsp-glib-3.0',
  version: '>= 3.18.0-alpha',
  required: false,
  default_options: [
    'enable_valadoc=false',
    'gi-docgen=false',
  ],
)
lsp_glib_vala_dep = []
if not lsp_glib_dep.found()
  lsp_glib = subproject(
    'lsp-glib',
    default_options: [
      'enable_valadoc=false',
      'gi-docgen=false',
    ],
  )
  lsp_glib_dep = lsp_glib.get_variable('lsp_glib_dep')
  lsp_glib_vala_dep = lsp_glib.get_variable('lsp_glib_vala_dep')
elif lsp_glib_dep.type_name() == 'internal'
  lsp_glib = subproject('lsp-glib')
  lsp_glib_vala_dep = lsp_glib.get_variable('lsp_glib_vala_dep')
endif

deps = [
    dependency('glib-2.0', version: '>= 2.66'),
    libgobject_dep,
    dependency('gio-2.0'),
    dependency('gee-0.8'),
    dependency('json-glib-1.0'),
    lsp_glib_dep,
    libvala,
    valac.find_library('posix'),
] + lsp_glib_vala_dep

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

if host_machine.system() == 'windows'
    deps += dependency('gio-windows-2.0')
    platform_vala_sources += files(['src/windows.vapi'])
    add_project_arguments(['--define=WINDOWS'], language: 'vala')
else
    deps += dependency('gio-unix-2.0')
endif

subdir('data')
subdir('src')

if get_option('tests')
  subdir('test')
endif
