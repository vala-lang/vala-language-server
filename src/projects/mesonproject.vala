using Gee;

/**
 * A project with a Meson backend
 */
class Vls.MesonProject : Project {
    private bool build_files_have_changed = true;
    private HashMap<File, FileMonitor> meson_build_files = new HashMap<File, FileMonitor> (Util.file_hash, Util.file_equal);
    private string root_path;
    private string build_dir;
    private bool configured_once;

    public const string OUTDIR = "meson-out";

    private string[] substitute_target_args (Meson.TargetInfo meson_target_info, 
                                             Meson.TargetSourceInfo target_source, 
                                             string[] args) throws RegexError {
        var substituted_args = new LinkedList<string> ();
        for (int i = 0; i < args.length; i++) {
            MatchInfo match_info;
            if (/^@([A-Za-z]+)(\d+)?@$/.match (args[i], 0, out match_info)) {
                string special_arg_name = match_info.fetch (1);
                string? arg_num_str = match_info.fetch (2);
                int arg_num;
                bool has_arg_num = int.try_parse (arg_num_str == null ? "" : arg_num_str, out arg_num);
                if (special_arg_name == "INPUT") {
                    string substitute = "";

                    if (has_arg_num) {
                        if (arg_num < target_source.sources.length) {
                            substitute = target_source.sources[arg_num];
                            substituted_args.add (substitute);
                            debug ("MesonProject: for target %s, source #0, subtituted arg #%d (%s) for %s",
                                   meson_target_info.id, i, args[i], substitute);
                        } else {
                            warning ("MesonProject: for target %s, source #0, could not substitute special arg `%s'", 
                                     meson_target_info.id, args[i]);
                        }
                    } else {
                        foreach (string input_arg in target_source.sources) {
                            substituted_args.add(input_arg);
                            if (substitute != "")
                                substitute += " ";
                            substitute += input_arg;
                        }
                        debug ("MesonProject: for target %s, source #0, subtituted arg #%d (%s) for %s",
                               meson_target_info.id, i, args[i], substitute);
                    }
                } else if (special_arg_name == "OUTPUT") {
                    string substitute = "";

                    if (has_arg_num) {
                        if (arg_num < meson_target_info.filename.length) {
                            substitute = meson_target_info.filename[arg_num];
                            substituted_args.add (substitute);
                            debug ("MesonProject: for target %s, source #0, subtituted arg #%d (%s) for %s",
                                   meson_target_info.id, i, args[i], substitute);
                        } else {
                            warning ("MesonProject: for target %s, source #0, could not substitute special arg `%s'", 
                                     meson_target_info.id, args[i]);
                        }
                    } else {
                        foreach (string output_arg in meson_target_info.filename) {
                            substituted_args.add (output_arg);
                            if (substitute != "")
                                substitute += " ";
                            substitute += output_arg;
                        }
                        debug ("MesonProject: for target %s, source #0, subtituted arg #%d (%s) for %s",
                               meson_target_info.id, i, args[i], substitute);
                    }
                } else {
                    warning ("MesonProject: for target %s, source #0, could not substitute special arg `%s'", 
                             meson_target_info.id, special_arg_name);
                    substituted_args.add (args[i]);
                }
            } else {
                string substitute = args[i];
                bool replaced = false;
                var regex1 = /@PRIVATE_OUTDIR_ABS_?(\S*)@/;
                substitute = regex1.replace_eval (substitute, substitute.length, 0, 0, (match, result) => {
                    string? build_id = match.fetch (1);

                    if (build_id == null || build_id == meson_target_info.id) {
                        result.append (meson_target_info.id);
                        replaced = true;
                    } else {
                        BuildTarget? found = build_targets.first_match (t => t.id == build_id);
                        if (found != null) {
                            result.append (found.build_dir);
                        } else {
                            warning ("MesonProject: for target %s, source #0, could not substitute special arg `%s' (could not find build target with ID %s)", 
                                     meson_target_info.id, match.get_string (), build_id);
                        }
                    }

                    return false;
                });
                var regex2 = /@\w+@/;
                substitute = regex2.replace_eval (substitute, substitute.length, 0, 0, (match, result) => {
                    if (match.fetch (0) == "@BUILD_ROOT@") {
                        result.append (build_dir);
                        replaced = true;
                    } else if (match.fetch (0) == "@SOURCE_ROOT@") {
                        result.append (root_path);
                        replaced = true;
                    } else {
                        warning ("MesonProject: for target %s, source #0, could not substitute special arg `%s'", 
                                 meson_target_info.id, match.fetch (0));
                        result.append (match.fetch (0));
                        return true;
                    }
                    return false;
                });
                if (replaced) {
                    debug ("MesonProject: for target %s, source #0, subtituted arg #%d (%s) for %s",
                           meson_target_info.id, i, args[i], substitute);
                }
                substituted_args.add (substitute);
            }
        }
        return substituted_args.to_array ();
    }

    private void load_introspection_json (Json.Parser parser, string build_dir, string command, 
                                          Cancellable? cancellable = null) throws Error {
        // first, try to load the file in ${build_dir}/meson-info/intro-${command}.json
        try {
            var input_file = File.new_build_filename (build_dir, "meson-info", @"intro-$command.json");
            debug ("MesonProject: loading file %s ...", input_file.get_path ());
            parser.load_from_stream (input_file.read (cancellable), cancellable);
        } catch (IOError e) {
            if (e is IOError.NOT_FOUND) {
                // retry with the other method: get output of `meson introspect --${command} ${build_dir}`
                string subst_command = command.replace("_", "-");
                string[] spawn_args = {"meson", "introspect", @"--$subst_command", "."};
                string proc_stdout, proc_stderr;
                int proc_status;

                string command_str = "";
                foreach (string part in spawn_args) {
                    if (command_str != "")
                        command_str += " ";
                    command_str += part;
                }

                debug ("MesonProject: file does not exist, fallback to %s", command_str);

                Process.spawn_sync (
                    build_dir,
                    spawn_args,
                    null,
                    SpawnFlags.SEARCH_PATH,
                    null,
                    out proc_stdout,
                    out proc_stderr,
                    out proc_status);

                if (proc_status != 0) {
                    warning ("MesonProject: command `%s' in %s failed with exit code %d\n----stdout:\n%s\n----stderr:\n%s", 
                             command_str, build_dir, proc_status, proc_stdout, proc_stderr);
                    throw new ProjectError.INTROSPECTION (@"meson command `$command_str' failed with exit code $proc_status");
                }

                parser.load_from_data (proc_stdout);
            } else {
                // otherwise, rethrow
                throw e;
            }
        }
    }

    public override bool reconfigure_if_stale (Cancellable? cancellable = null) throws Error {
        if (!build_files_have_changed) {
            return false;
        }

        build_targets.clear ();
        build_files_have_changed = false;

        // 0. we support only Meson >= 0.50
        string meson_version_proc_stdout, meson_version_proc_stderr;
        int meson_version_proc_status;

        Process.spawn_sync (
            build_dir,
            "meson --version".split (" "),
            null,
            SpawnFlags.SEARCH_PATH,
            null,
            out meson_version_proc_stdout,
            out meson_version_proc_stderr,
            out meson_version_proc_status);

        if (meson_version_proc_status != 0) {
            warning ("MesonProject: failed to get version, exit code %d\n----stdout:\n%s\n----stderr:\n%s", 
                     meson_version_proc_status, meson_version_proc_stdout, meson_version_proc_stderr);
            throw new ProjectError.CONFIGURATION (@"meson --version failed with exit code $meson_version_proc_status");
        }

        meson_version_proc_stdout = meson_version_proc_stdout.strip ();

        if (Util.compare_versions (meson_version_proc_stdout, "0.50.0") < 0) {
            warning ("MesonProject: meson < 0.50.0 not supported (version was '%s')", meson_version_proc_stdout);
            throw new ProjectError.VERSION_UNSUPPORTED (@"meson < 0.50.0 not supported");
        }

        // 1. configure new build directory
        var root_meson_build = File.new_build_filename (root_path, "meson.build");
        if (!meson_build_files.has_key (root_meson_build)) {
            debug ("MesonProject: obtaining a new file monitor for %s ...", root_meson_build.get_path ());
            FileMonitor file_monitor = root_meson_build.monitor_file (FileMonitorFlags.NONE, cancellable);
            file_monitor.changed.connect (file_changed_event);
            meson_build_files[root_meson_build] = file_monitor;
        }

        string[] spawn_args = {"meson", "setup", ".", root_path};
        string proc_stdout, proc_stderr;
        int proc_status;
        debug ("MesonProject: %sconfiguring build dir %s ...", configured_once ? "re" : "", build_dir);
        if (configured_once)
            spawn_args += "--reconfigure";
        Process.spawn_sync (
            build_dir,
            spawn_args, 
            null, 
            SpawnFlags.SEARCH_PATH, 
            null,
            out proc_stdout,
            out proc_stderr,
            out proc_status);

        if (proc_status != 0) {
            warning ("MesonProject: configuration failed with exit code %d\n----stdout:\n%s\n----stderr:\n%s", 
                     proc_status, proc_stdout, proc_stderr);
            throw new ProjectError.CONFIGURATION (@"meson configuration failed with exit code $proc_status");
        }

        // 2. load project dependencies, which may be of use to C build targets
        var raw_dependencies = new ArrayList<Meson.Dependency> ();
        var dependencies_parser = new Json.Parser.immutable_new ();
        load_introspection_json (dependencies_parser, build_dir, "dependencies", cancellable);
        Json.Node? rd_json_root = dependencies_parser.get_root ();
        if (rd_json_root == null) {
            warning ("MesonProject: JSON root is null! C code targets may fail to build.");
        } else if (rd_json_root.get_node_type () != Json.NodeType.ARRAY) {
            warning ("MesonProject: JSON root is not an array! C code targets may fail to build.");
        } else {
            int elem_idx = -1;
            foreach (Json.Node elem_node in rd_json_root.get_array ().get_elements ()) {
                elem_idx++;
                var raw_dependency = Json.gobject_deserialize (typeof (Meson.Dependency), elem_node) as Meson.Dependency?;
                if (raw_dependency == null) {
                    warning ("MesonProject: could not deserialize raw dependency/element #%d", elem_idx);
                    continue;
                }
                raw_dependencies.add (raw_dependency);
            }

        }

        // 3. create build targets
        var targets_parser = new Json.Parser.immutable_new ();
        load_introspection_json(targets_parser, build_dir, "targets", cancellable);
        Json.Node? tg_json_root = targets_parser.get_root ();
        if (tg_json_root == null) {
            warning ("MesonProject: JSON root is null! Bailing out");
            throw new ProjectError.INTROSPECTION (@"Meson targets: JSON root is null!");
        } else if (tg_json_root.get_node_type () != Json.NodeType.ARRAY) {
            warning ("MesonProject: JSON root is not an array! Bailing out");
            throw new ProjectError.INTROSPECTION (@"Meson targets: JSON root is not an array!");
        }
        var root_dir = File.new_for_path (root_path);
        int elem_idx = -1;
        foreach (Json.Node elem_node in tg_json_root.get_array ().get_elements ()) {
            elem_idx++;
            var meson_target_info = Json.gobject_deserialize (typeof (Meson.TargetInfo), elem_node) as Meson.TargetInfo?;
            if (meson_target_info == null) {
                warning ("MesonProject: could not deserialize target/element #%d", elem_idx);
                continue;
            } else if (meson_target_info.target_sources.is_empty) {
                warning ("MesonProject: target #%d has no target sources", elem_idx);
                continue;
            }

            // ignore additional sources in target
            Meson.TargetSourceInfo first_source = meson_target_info.target_sources[0];

            // first, compute target's build directory
            string target_build_dir;
            string? src_relative_path = root_dir.get_relative_path (File.new_for_path (meson_target_info.defined_in));

            if (src_relative_path != null) {
                src_relative_path = Path.get_dirname (src_relative_path);
                // for some reason, the arguments passed to Vala targets are relative to
                // the root build dir
                if (first_source.language != "vala")
                    target_build_dir = build_dir + Path.DIR_SEPARATOR_S + src_relative_path;
                else
                    target_build_dir = build_dir;
                // if (meson_target_info.target_type == "executable"
                //     || meson_target_info.target_type == "shared library"
                //     || meson_target_info.target_type == "static library")
                //     target_build_dir += Path.DIR_SEPARATOR_S + meson_target_info.id;
            } else {
                throw new ProjectError.INTROSPECTION (@"defined-in for $(meson_target_info.id) is not relative to source dir $(root_dir.get_path ())");
            }

            bool swap_with_previous_target = false;
            // second, fix sources
            var fixed_sources = new ArrayList<string> ();

            if (first_source.compiler.length > 0 && Path.get_basename (first_source.compiler[0]) == "glib-mkenums") {
                // hack for bug in Meson introspection with gnome.mkenums() targets, where source
                // files defined in the meson.build file for this target show up as
                // source files in the project root directory, regardless of where they
                // actually are
                foreach (string source in first_source.sources) {
                    var input_file = File.new_for_commandline_arg_and_cwd (source, target_build_dir);
                    if (root_dir.get_relative_path (input_file) == input_file.get_basename ())
                        input_file = File.new_build_filename (root_path, src_relative_path, input_file.get_basename ());
                    debug ("MesonProject: fixed glib-mkenums source: from %s --> %s", source, input_file.get_path ());
                    fixed_sources.add (input_file.get_path ());
                }

                // also, add --output argument if it doesn't exist, since glib-mkenums
                // outputs to stdout by default
                var compiler_args = new ArrayList<string> ();
                compiler_args.add_all_array (first_source.compiler);
                if (!compiler_args.any_match (compiler_arg => compiler_arg == "--output")) {
                    if (meson_target_info.filename.length > 0) {
                        compiler_args.add ("--output");
                        compiler_args.add (meson_target_info.filename[0]);
                    } else {
                        throw new ProjectError.INTROSPECTION (@"MesonProject: expected at least one filename for glib-mkenums target $(meson_target_info.id)");
                    }
                }
                first_source.compiler = compiler_args.to_array ();

                // Finally, another hack: a gnome.mkenums() target may show up in introspection
                // as two targets, with the outputted C header file coming right AFTER the target for
                // the outputted C file. This violates the topological ordering, so swap the two if
                // our current target is applicable.
                if (meson_target_info.name.has_suffix (".h") 
                    && build_targets.size > 0
                    && build_targets[build_targets.size - 1].name.has_suffix (".c")
                    && meson_target_info.name.substring (0, meson_target_info.name.length - 2) 
                        == build_targets[build_targets.size - 1].name.substring (0, build_targets[build_targets.size - 1].name.length - 2))
                    swap_with_previous_target = true;
            } else {
                fixed_sources.add_all_array (first_source.sources);
            }
            first_source.sources = fixed_sources.to_array ();

            // third, substitute special arguments
            first_source.parameters = substitute_target_args (meson_target_info, 
                                                              first_source, 
                                                              first_source.parameters);
            first_source.compiler = substitute_target_args (meson_target_info,
                                                            first_source,
                                                            first_source.compiler);

            // fourth, add additional link arguments for C targets
            if (first_source.language == "c") {
                var fixed_parameters = new ArrayList<string> ();
                fixed_parameters.add_all_array (first_source.parameters);

                // the order of link args tends to be very important, so we cannot use a HashSet
                var link_args = new ArrayList<string> ();

                // Find all of the dependencies we need based on the compiler
                // arguments we're using so far. If our target uses all of the include arguments that
                // a raw dependency requires, then that dependency probably belongs to our target.
                foreach (Meson.Dependency raw_dep in raw_dependencies) {
                    bool is_subset_of_compile_args = true;
                    foreach (string compile_arg in raw_dep.compile_args) {
                        if (!(compile_arg in first_source.parameters)) {
                            is_subset_of_compile_args = false;
                            break;
                        }
                    }

                    if (is_subset_of_compile_args) {
                        // only add unique arguments
                        foreach (string link_arg in raw_dep.link_args) {
                            if (!(link_arg in link_args)) {
                                link_args.add (link_arg);
                                debug ("MesonProject: adding link arg `%s' to C target %s", link_arg, meson_target_info.id);
                            }
                        }
                    }
                }
                fixed_parameters.add_all (link_args);

                // hack: since Meson introspect doesn't include the link args of the target,
                // we also must add this if we're compiling a shared object
                // XXX: what about static libraries?
                if (meson_target_info.target_type == "shared library") {
                    if (!("-shared" in fixed_parameters))
                        fixed_parameters.add ("-shared");
                    if (!fixed_parameters.any_match (p => p.has_prefix ("-o"))) {
                        if (meson_target_info.filename.length > 0) {
                            fixed_parameters.add ("-o");
                            fixed_parameters.add (meson_target_info.filename[0]);
                        } else {
                            throw new ProjectError.INTROSPECTION (@"MesonProject: expected at least one filename for C shared-library target $(meson_target_info.id)");
                        }
                    }
                }

                first_source.parameters = fixed_parameters.to_array ();
            }

            // finally, construct the build target
            if (first_source.language == "vala")
                build_targets.add (new Compilation (target_build_dir,
                                                    meson_target_info.name, 
                                                    meson_target_info.id, 
                                                    elem_idx,
                                                    first_source.compiler, 
                                                    first_source.parameters, 
                                                    first_source.sources,
                                                    first_source.generated_sources));
            else {
                BuildTarget? previous_target = null;
                if (swap_with_previous_target)
                    previous_target = build_targets.remove_at (build_targets.size - 1);
                build_targets.add (new BuildTask (target_build_dir,
                                                  meson_target_info.name, 
                                                  meson_target_info.id, 
                                                  elem_idx + (swap_with_previous_target ? -1 : 0),
                                                  first_source.compiler, 
                                                  first_source.parameters, 
                                                  first_source.sources,
                                                  first_source.generated_sources,
                                                  meson_target_info.filename,
                                                  first_source.language));
                if (previous_target != null) {
                    previous_target.no = elem_idx;
                    build_targets.add (previous_target);
                    debug ("MesonTarget: swapping previous target %s after target %s", previous_target.id, meson_target_info.id);
                }
            }

            // finally, monitor the file that this build target was defined in
            var defined_in = File.new_for_path (meson_target_info.defined_in);
            if (!meson_build_files.has_key (defined_in)) {
                debug ("MesonProject: obtaining a new file monitor for %s ...", defined_in.get_path ());
                FileMonitor file_monitor = defined_in.monitor_file (FileMonitorFlags.NONE, cancellable);
                file_monitor.changed.connect (file_changed_event);
                meson_build_files[defined_in] = file_monitor;
            }
        }

        // 4. analyze $build_dir/compile_commands.json for additional information
        //    about target inputs and outputs
        var ccs_parser = new Json.Parser.immutable_new ();
        var ccs_file = File.new_build_filename (build_dir, "compile_commands.json");
        debug ("MesonProject: loading file %s ...", ccs_file.get_path ());
        ccs_parser.load_from_stream (ccs_file.read (cancellable), cancellable);
        Json.Node? ccs_json_root = ccs_parser.get_root ();
        // don't fail hard if we can't read compile_commands.json
        if (ccs_json_root == null)
            warning ("MesonProject: JSON root is null! Bailing out");
        else if (ccs_json_root.get_node_type () != Json.NodeType.ARRAY)
            warning ("MesonProject: JSON root is not an array! Bailing out");
        else {
            int nth_cc = -1;
            foreach (Json.Node elem_node in ccs_json_root.get_array ().get_elements ()) {
                nth_cc++;
                var cc = Json.gobject_deserialize (typeof (CompileCommand), elem_node) as CompileCommand;
                if (cc == null) {
                    warning ("MesonProject: could not deserialize compile command #%d", nth_cc);
                    continue;
                }
                // attempt to match cc["file"] to a build target
                var cc_file = File.new_for_path (Util.realpath (cc.file, cc.directory));
                var target_matches = lookup_compile_input_source_file (cc_file.get_uri ());
                Compilation compilation;
                if (target_matches.size == 1)
                    compilation = target_matches[0].second;
                else {
                    // try again: attempt to match ...${meson_target_id}...
                    Compilation? found_comp = null;
                    MatchInfo match_info;
                    if (/[^\\\/]+(@@[^\\\/]+)?@\w+/.match (cc.output, 0, out match_info)) {
                        string id = match_info.fetch (0);

                        BuildTarget? btarget_found = build_targets.first_match (t => t.id == id);
                        if (btarget_found != null && (btarget_found is Compilation))
                            found_comp = (Compilation) btarget_found;
                        else {
                            warning ("MesonProject: could not associate CC #%d (meson target-id: %s) with a compilation", nth_cc, id);
                            continue;
                        }
                    }
                    if (found_comp != null)
                        compilation = (!) found_comp;
                    else
                        continue;
                }
                // parse the compile command for additional arguments not found in Meson introspection
                string? flag_name, arg_value;   // --<flag_name>[=<arg_value>]
                for (int arg_i = -1; (arg_i = Util.iterate_valac_args (cc.command, out flag_name, out arg_value, arg_i)) < cc.command.length;) {
                    // we only care about input VAPI files
                    if (flag_name != null || arg_value == null)
                        continue;
                    if (!arg_value.has_suffix (".vapi")/* && TODO: .gir */)
                        continue;
                    var vapi_file = File.new_for_path (Util.realpath (arg_value, cc.directory));
                    if (!compilation.input.contains (vapi_file))
                        debug ("MesonProject: discovered extra VAPI file %s used by compilation %s", 
                               vapi_file.get_path (), compilation.id);
                    else
                        debug ("MesonProject: found VAPI %s for compilation %s", vapi_file.get_path (), compilation.id);
                    // Add vapi_file to the list of input files. If it is
                    // already present, then nothing happens.
                    compilation.input.add (vapi_file);
                }
            }
        }

        // 5. look for more file monitors
        var bs_files_parser = new Json.Parser.immutable_new ();
        try {
            load_introspection_json(bs_files_parser, build_dir, "buildsystem_files", cancellable);
            Json.Node? bsf_json_root = bs_files_parser.get_root ();
            if (bsf_json_root == null) {
                throw new ProjectError.INTROSPECTION (@"Meson buildsystem files: JSON root is null!");
            } else if (bsf_json_root.get_node_type () != Json.NodeType.ARRAY) {
                throw new ProjectError.INTROSPECTION (@"Meson buildsystem files: JSON root is not an array!");
            }

            foreach (Json.Node elem_node in bsf_json_root.get_array ().get_elements ()) {
                string? path = elem_node.get_string ();
                if (path != null && (path.has_suffix ("meson.build") || path.has_suffix ("meson_options.txt"))) {
                    var build_file = File.new_for_path ((!) path);
                    if (!meson_build_files.has_key (build_file)) {
                        debug ("MesonProject: obtaining a new file monitor for %s ...", build_file.get_path ());
                        try {
                            FileMonitor file_monitor = build_file.monitor_file (FileMonitorFlags.NONE, cancellable);
                            file_monitor.changed.connect (file_changed_event);
                            meson_build_files[build_file] = file_monitor;
                        } catch (Error e) {
                            warning ("MesonProject: ... failed - %s", e.message);
                        }
                    }
                }
            }
        } catch (Error e) {
            warning ("MesonProject: ... failed to load file - %s", e.message);
        }

        // 6. perform final analysis and sanity checking
        analyze_build_targets (cancellable);

        configured_once = true;

        return true;
    }

    public MesonProject (string root_path, Cancellable? cancellable = null) throws Error {
        this.root_path = root_path;
        this.build_dir = DirUtils.make_tmp (@"vls-meson-$(str_hash (root_path))-XXXXXX");
        reconfigure_if_stale (cancellable);
    }

    ~MesonProject () {
        Util.remove_dir (build_dir);
    }

    private void file_changed_event (File src, File? dest, FileMonitorEvent event_type) {
        if (FileMonitorEvent.ATTRIBUTE_CHANGED in event_type) {
            debug ("MesonProject: watched file %s had an attribute changed", src.get_path ());
            build_files_have_changed = true;
            changed ();
        }
        if (FileMonitorEvent.CHANGED in event_type) {
            debug ("MesonProject: watched file %s was changed", src.get_path ());
            build_files_have_changed = true;
            changed ();
        }
        if (FileMonitorEvent.DELETED in event_type) {
            debug ("MesonProject: watched file %s was deleted", src.get_path ());
            // remove this file monitor since the file was deleted
            FileMonitor file_monitor;
            if (meson_build_files.unset (src, out file_monitor)) {
                file_monitor.cancel ();
                file_monitor.changed.disconnect (file_changed_event);
            }
            build_files_have_changed = true;
            changed ();
        }
    }
}
