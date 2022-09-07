lstf = find_program('lstf', required: false)

if not lstf.found()
  meson.override_find_program('lstf', subproject('lstf').get_variable('lstf'))
  lstf = find_program('lstf')
endif

test('57-suggest-overridable-symbols', lstf,
  workdir: meson.current_source_dir(),
  args: ['57-suggest-overridable-symbols.lstf', '--server-path', vls])

test('106-autocompletion-in-string-literals', lstf,
  workdir: meson.current_source_dir(),
  args: ['106-autocompletion-in-string-literals.lstf', '--server-path', vls])

test('138-suggest-overridable-symbols', lstf,
  workdir: meson.current_source_dir(),
  args: ['138-suggest-overridable-symbols.lstf', '--server-path', vls])

test('153-signaturehelp-shared-prefix', lstf,
  workdir: meson.current_source_dir(),
  args: ['153-signaturehelp-shared-prefix.lstf', '--server-path', vls])
