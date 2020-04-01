vls_src = files([
  'main.vala',
  'find_symbol.vala',
  'list_symbols.vala',
  'projects/buildtarget.vala',
  'projects/buildtask.vala',
  'projects/compilation.vala',
  'projects/defaultproject.vala',
  'projects/mesonproject.vala',
  'projects/project.vala',
  'projects/textdocument.vala',
  'projects/types.vala',
  'protocol.vala',
  'reporter.vala',
])

if get_option('parse_system_girs')
  vls_src += 'girdocumentation.vala'
  add_project_arguments(['--define=PARSE_SYSTEM_GIRS'], language: 'vala')
endif

if get_option('active_parameter')
  add_project_arguments(['--define=VALA_FEATURE_INITIAL_ARGUMENT_COUNT'], language: 'vala')
endif

executable('vala-language-server',
  dependencies: deps,
  sources: [vls_src, conf_file, extra_vala_sources],
  install: true)
