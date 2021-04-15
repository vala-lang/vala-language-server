scdoc = dependency('scdoc', version: '>=1.9.2', native: true, required: get_option('man_pages'))
if scdoc.found()
    scdoc_prog = find_program(scdoc.get_pkgconfig_variable('scdoc'), native: true)
    sh = find_program('sh', native: true)
    man_files = [
        'man/vala-language-server.1.scd',
    ]
    foreach filename : man_files
        topic = filename.split('.')[-3].split('/')[-1]
        if topic.contains('_')
            topic = topic.split('_')[0] + '.' + topic.split('_')[1]
        endif
        section = filename.split('.')[-2]
        output_filename = '@0@.@1@'.format(topic, section)

        man_file = configure_file(
            input: filename,
            output: output_filename,
            command: [sh, '-c', '@0@ < @INPUT@ > @1@'.format(scdoc_prog.path(), output_filename)],
        )

        install_man(man_file)
    endforeach
endif
