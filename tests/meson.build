lstf = find_program('lstf')

# unit tests
test('diagnostics', lstf,
  workdir: meson.current_source_dir(),
  args: ['diagnostics.lstf', '-e', 'server-path', vls])

# bugs

test('57-suggest-overridable-symbols', lstf,
  workdir: meson.current_source_dir(),
  args: ['57-suggest-overridable-symbols.lstf', '-e', 'server-path', vls])

test('106-autocompletion-in-string-literals', lstf,
  workdir: meson.current_source_dir(),
  args: ['106-autocompletion-in-string-literals.lstf', '-e', 'server-path', vls])

test('138-suggest-overridable-symbols', lstf,
  workdir: meson.current_source_dir(),
  args: ['138-suggest-overridable-symbols.lstf', '-e', 'server-path', vls])

test('153-signaturehelp-shared-prefix', lstf,
  workdir: meson.current_source_dir(),
  args: ['153-signaturehelp-shared-prefix.lstf', '-e', 'server-path', vls])
