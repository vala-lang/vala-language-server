libunwind_dep = dependency('libunwind', required: false)
libdl_dep = cc.find_library('dl')

if libunwind_dep.found()
  add_project_arguments(['-DHAVE_LIBUNWIND'], language: 'c')
endif

libgobject_list = static_library('gobject-list',
  sources: ['gobject-list/gobject-list.c'],
  dependencies: [libunwind_dep, libgobject_dep, libdl_dep],
)

libgobject_list_dep = declare_dependency(
  link_with: libgobject_list,
)
