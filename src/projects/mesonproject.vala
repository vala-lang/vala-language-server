using Gee;

/**
 * A project with a Meson backend
 */
class Vls.MesonProject : Project {
    private bool build_files_have_changed = true;
    private HashMap<File, FileMonitor> meson_build_files = new HashMap<File, FileMonitor> (Util.file_hash, Util.file_equal);
    private string root_path;
    private string build_dir;

    public const string OUTDIR = "meson-out";

    public override void reconfigure_if_stale (Cancellable? cancellable = null) throws Error {
        if (!build_files_have_changed) {
            return;
        }

        foreach (var file_monitor in meson_build_files.values) {
            file_monitor.cancel ();
            file_monitor.changed.disconnect (file_changed_event);
        }
        meson_build_files.clear ();
        build_targets.clear ();
        build_files_have_changed = false;

        // 1. configure new build directory
        var root_meson_build = File.new_build_filename (root_path, "meson.build");
        meson_build_files[root_meson_build] = root_meson_build.monitor_file (FileMonitorFlags.WATCH_HARD_LINKS, cancellable);
        build_dir = DirUtils.make_tmp (@"vls-meson-$(str_hash (root_path))-XXXXXX");

        string[] spawn_args = {"meson", "setup", ".", root_path};
        string proc_stdout, proc_stderr;
        int proc_status;
        debug ("MesonProject: configuring build dir %s ...", build_dir);
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

        // 2. create build targets
        var targets_parser = new Json.Parser.immutable_new ();
        var targets_file = File.new_build_filename (build_dir, "meson-info", "intro-targets.json");
        debug ("MesonProject: loading file %s ...", targets_file.get_path ());
        targets_parser.load_from_stream (targets_file.read (cancellable), cancellable);
        Json.Node? tg_json_root = targets_parser.get_root ();
        if (tg_json_root == null) {
            warning ("MesonProject: JSON root is null! Bailing out");
            throw new ProjectError.INTROSPECTION (@"JSON root of $(targets_file.get_path ()) is null!");
        } else if (tg_json_root.get_node_type () != Json.NodeType.ARRAY) {
            warning ("MesonProject: JSON root is not an array! Bailing out");
            throw new ProjectError.INTROSPECTION (@"JSON root of $(targets_file.get_path ()) is not an array!");
        }
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
            if (first_source.language == "vala")
                build_targets.add (new Compilation (build_dir,
                                                    meson_target_info.name, 
                                                    meson_target_info.id, 
                                                    elem_idx,
                                                    first_source.compiler, 
                                                    first_source.parameters, 
                                                    first_source.sources,
                                                    first_source.generated_sources));
            else if (first_source.language == "unknown")
                build_targets.add (new BuildTask (build_dir,
                                                  meson_target_info.name, 
                                                  meson_target_info.id, 
                                                  elem_idx,
                                                  first_source.compiler, 
                                                  first_source.parameters, 
                                                  first_source.sources,
                                                  first_source.generated_sources));
            else {
                debug ("MesonProject: ignoring target #%d because first target source has language `%s'", elem_idx, first_source.language);
                continue;
            }

            // finally, monitor the file that this build target was defined in
            var defined_in = File.new_for_path (meson_target_info.defined_in);
            if (!meson_build_files.has_key (defined_in)) {
                debug ("MesonProject: obtaining a file monitor for %s ...", defined_in.get_path ());
                meson_build_files[defined_in] = defined_in.monitor_file (FileMonitorFlags.WATCH_HARD_LINKS, cancellable);
            }
        }

        // 3. analyze $build_dir/compile_commands.json for additional information
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
                    if (/[A-Z0-9a-z]+@@\S+@\w+/.match (cc.output, 0, out match_info)) {
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

        // 4. perform final analysis and sanity checking
        analyze_build_targets ();
    }

    public MesonProject (string root_path, Cancellable? cancellable = null) throws Error {
        this.root_path = root_path;
        reconfigure_if_stale (cancellable);
    }

    private void file_changed_event (File src, File? dest, FileMonitorEvent event_type) {
        if ((event_type & FileMonitorEvent.CHANGED) != 0) {
            debug ("MesonProject: watched file %s was changed", src.get_path ());
            build_files_have_changed = true;
        } else if ((event_type & FileMonitorEvent.DELETED) != 0) {
            debug ("MesonProject: watched file %s was deleted", src.get_path ());
            build_files_have_changed = true;
        }
    }
}
