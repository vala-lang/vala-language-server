conf = configuration_data()
conf.set('BUILDER_ABI', get_option('builder_abi'))
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
