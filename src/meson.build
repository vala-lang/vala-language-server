vls_src = files([
  'cnamemapper.vala',
  'list_symbols.vala',
  'codehelp/codehelp.vala',
  'codehelp/completionengine.vala',
  'codehelp/find_scope.vala',
  'codehelp/find_symbol.vala',
  'codehelp/signaturehelpengine.vala',
  'codehelp/symbolextractor.vala',
  'projects/buildtarget.vala',
  'projects/buildtask.vala',
  'projects/ccproject.vala',
  'projects/compilation.vala',
  'projects/defaultproject.vala',
  'projects/mesonproject.vala',
  'projects/project.vala',
  'projects/textdocument.vala',
  'projects/types.vala',
  'protocol.vala',
  'reporter.vala',
  'server.vala',
  'servertypes.vala',
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
  c_args: ['-DG_LOG_DOMAIN="vls"'],
  install: true)
