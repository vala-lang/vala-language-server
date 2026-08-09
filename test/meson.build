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

test('plain text completions', vls_testclient,
  args: [
    '--server', vls.full_path(),
    '--root-path', meson.project_source_root(),
    '--completions',
  ],
  suite: 'vls',
  timeout: 120)

test('snippet completions', vls_testclient,
  args: [
    '--server', vls.full_path(),
    '--root-path', meson.project_source_root(),
    '--completions',
    '--snippet-support',
  ],
  suite: 'vls',
  timeout: 120)

source_reference_test = executable('source-reference-test',
  dependencies: deps,
  sources: files('source-reference.vala') + vls_util_src,
  install: false)

test('source reference keys', source_reference_test,
  suite: 'vls')
