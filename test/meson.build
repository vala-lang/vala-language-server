testclient_src = files([
  'testclient.vala',
])

vls_testclient = executable('vls-testclient',
  dependencies: deps,
  sources: testclient_src,
  install: false)

test('document symbols', vls_testclient,
  args: [
    '--server', vls.full_path(),
    '--root-path', meson.project_source_root(),
    '--document-symbols', join_paths(meson.project_source_root(), 'src', 'server.vala'),
  ],
  suite: 'vls',
  timeout: 120)
