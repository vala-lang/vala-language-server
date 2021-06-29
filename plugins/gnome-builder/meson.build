BUILDER_VERSION_LATEST = '3.38'

conf = configuration_data()
builder_abi = get_option('builder_abi')
if builder_abi == 'auto'
  # attempt to guess the correct ABI from the installed GNOME Builder
  sh = find_program('sh', native: true, required: false)
  sed = find_program('sed', native: true, required: false)
  gnome_builder = find_program('gnome-builder', native: true, required: false)
  if gnome_builder.found() and sed.found() and sh.found()
    r = run_command(sh, 'get_builder_abi.sh', gnome_builder, sed, check: true)
    builder_abi = r.stdout().strip()
  else
    warning('Assuming version ' + BUILDER_VERSION_LATEST + ' for GNOME Builder plugin ABI')
    builder_abi = BUILDER_VERSION_LATEST
  endif
endif

if builder_abi != 'auto'
  conf.set('BUILDER_ABI', builder_abi)
  configure_file(
    input: 'vala_langserv.plugin.in',
    output: 'vala_langserv.plugin',
    configuration: conf,
    install_dir: get_option('prefix') / get_option('libdir') / 'gnome-builder' / 'plugins'
  )
  install_data(
    files(
      'vala_langserv.py'
    ),
    install_dir: get_option('prefix') / get_option('libdir') / 'gnome-builder' / 'plugins'
  )
endif
