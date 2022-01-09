/* buildtask.vala
 *
 * Copyright 2020 Princeton Ferro <princetonferro@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Gee;

/**
 * Represents a build target when it is an arbitrary command.
 */
class Vls.BuildTask : BuildTarget {
    private string[] arguments = {};
    private string exe_name = "";
    private string build_dir;
    private SubprocessLauncher launcher;

    /**
     * Because a built task could be any command, we don't know whether the files
     * that appear in the arg list are inputs or outputs initially.
     */
    public ArrayList<File> used_files { get; private set; default = new ArrayList<File> (); }

    /**
     * Candidate inputs are files that _may_ be inputs (and only inputs) to
     * this task but that we cannot determine yet. They may not exist now, but
     * they are expected to exist at the time this target is built.
     */
    public ArrayList<File> candidate_inputs { get; private set; default = new ArrayList<File> (); }

    public async BuildTask (string build_dir, string output_dir, string name, string id, int no,
                            string[] compiler, string[] args, string[] sources, string[] generated_sources,
                            string[] target_output_files,
                            string language, Cancellable? cancellable = null) throws Error {
        base (output_dir, name, id, no);
        // don't pipe stderr since we want to print that if something goes wrong
        this.build_dir = build_dir;
        launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE);
        launcher.set_cwd (build_dir);

        foreach (string arg in compiler) {
            if (arguments.length > 0)
                exe_name += " ";
            exe_name += arg;
            arguments += arg;
        }

        foreach (string arg in args) {
            if (arguments.length > 0)
                exe_name += " ";
            exe_name += arg;
            arguments += arg;
        }

        foreach (string arg in arguments) {
            if (Util.arg_is_vala_file (arg)) {
                var file = File.new_for_commandline_arg_and_cwd (arg, output_dir);
                used_files.add (file);
            }
        }

        // if this is a C compilation, avoid colored output, which comes out badly when piped
        if (language == "c") {
            // this is a synthetic argument, so don't add it to exe_name, which is used for debug output
            arguments += "-fdiagnostics-color=never";
        }

        foreach (string arg in sources) {
            // we don't need to add arg to arguments here since we've probably already substituted
            // the arguments in [compiler] and [args] from the sources, unless this is
            // a C code target
            if (language == "c") {
                if (arguments.length > 0)
                    exe_name += " ";
                exe_name += arg;
                arguments += arg;
            }
            input.add (File.new_for_commandline_arg_and_cwd (arg, output_dir));
        }

        foreach (string arg in generated_sources) {
            arguments += arg;
            input.add (File.new_for_commandline_arg_and_cwd (arg, output_dir));
        }

        string? cmd_basename = compiler.length > 0 ? Path.get_basename (compiler[0]) : null;

        if (cmd_basename == "vapigen") {
            string? library_name = null;
            string? directory = null;

            string? flag_name, arg_value;           // --<flag_name>[=<arg_value>]
            // it turns out we can reuse this function for vapigen
            for (int arg_i = -1; (arg_i = Util.iterate_valac_args (arguments, out flag_name, out arg_value, arg_i)) < arguments.length;) {
                if (flag_name == "directory")
                    directory = arg_value;
                else if (flag_name == "library")
                    library_name = arg_value;
            }

            if (library_name != null) {
                if (directory == null) {
                    warning ("BuildTask(%s): no --directory for vapigen, assuming %s", id, output_dir);
                    directory = output_dir;
                }
                output.add (File.new_for_commandline_arg_and_cwd (@"$library_name.vapi", directory));
            }
        } else {
            // add all outputs for the target otherwise
            foreach (string? output_filename in target_output_files) {
                if (output_filename != null) {
                    output.add (File.new_for_commandline_arg_and_cwd (output_filename, output_dir));
                    debug ("BuildTask(%s): outputs %s", id, output_filename);
                }
            }
        }

        if (cmd_basename == "glib-mkenums" ||
            cmd_basename == "g-ir-scanner" ||
            cmd_basename == "glib-compile-resources") {
            File output_file;
            // just assume the target is well-formed here
            if (target_output_files.length >= 1) {
                output_file = File.new_for_path (target_output_files[0]);
                // If this glib-mkenums target outputs a C file, it might be paired with a
                // glib-mkenums target that outputs a C header. 
                if (cmd_basename == "glib-mkenums" && target_output_files[0].has_suffix (".c"))
                    input.add (File.new_for_path (target_output_files[0].substring (0, target_output_files[0].length - 2) + ".h"));
            } else {
                throw new ProjectError.INTROSPECTION (@"BuildTask($id) expected at least one output file for target");
            }

            if (cmd_basename == "g-ir-scanner") {
                // for g-ir-scanner, look for --library [library name] and add this to our input
                string? last_arg = null;
                string? gir_library_name = null;
                File? gir_library_dir = output_file.get_parent ();
                foreach (string arg in arguments) {
                    if (last_arg == "--library")
                        gir_library_name = arg;
                    last_arg = arg;
                }

                if (gir_library_name != null) {
                    if (gir_library_dir != null) {
                        // XXX: how will the shared library suffix differ on other operating systems?
                        var tried = new ArrayList<File> ();
                        bool success = false;
                        File? library_file = null;
                        foreach (string shlib_suffix in new string[]{"so", "dll"}) {
                            library_file = gir_library_dir.get_child (@"lib$gir_library_name.$shlib_suffix");
                            if (library_file.query_exists ()) {
                                input.add (library_file);
                                debug ("BuildTask(%s) found input %s", id, library_file.get_path ());
                                success = true;
                                break;
                            }

                            // Meson 0.55: try also looking for directory with .p suffix,
                            // which will indicate where the library file is expected to be.
                            File libdir = gir_library_dir.get_child (@"lib$gir_library_name.$shlib_suffix.p");
                            if (libdir.query_exists ()) {
                                input.add (library_file);
                                debug ("BuildTask(%s) found input %s", id, library_file.get_path ());
                                success = true;
                                break;
                            }

                            tried.add (library_file);
                        }
                        if (!success) {
                            warning ("BuildTask(%s) failed to determine g-ir-scanner input because all options don't exist (tried %s)",
                                     id, tried.map<string> (f => f.get_path ())
                                         .fold<string> ((rightacc, elem) => elem != "" ? @"$elem, $rightacc" : rightacc, ""));
                        } else {
                            // The library file referenced by g-ir-scanner may be a symlink to 
                            // the actual library generated by another target. In order to make
                            // later dependency resolution work, we need to add a dependency for the
                            // real file. To do this, we read the location pointed to by the symlink.
                            File real_file = library_file;
                            try {
                                FileInfo? info = yield real_file.query_info_async (
                                    "standard::*",
                                    FileQueryInfoFlags.NONE,
                                    Priority.DEFAULT,
                                    cancellable
                                );
                                // sometimes there can be symlinks to symlinks,
                                // such as libthing.so -> libthing.so.0 -> libthing.so.0.0.0
                                while (info.get_is_symlink ()) {
                                    real_file = gir_library_dir.get_child (info.get_symlink_target ());
                                    try {
                                        info = yield real_file.query_info_async (
                                            "standard::*",
                                            FileQueryInfoFlags.NONE,
                                            Priority.DEFAULT,
                                            cancellable
                                        );
                                    } catch (Error e) {
                                        // if this file does not exist, then it's probably the real file,
                                        // yet-to-be-created
                                        info = null;
                                        break;
                                    }
                                }
                                if ((info == null || !info.get_is_symlink ()) && real_file != library_file) {
                                    input.add (real_file);
                                    debug ("BuildTask(%s): found input from symlink - %s", id, real_file.get_path ());
                                }
                            } catch (Error e) {
                                // we don't care if the file doesn't exist, since that probably means
                                // it has yet to be generated by the target, and it's not a symlink
                            }
                        }
                    } else {
                        warning ("BuildTask(%s): could not get directory for .gir file", id);
                    }
                } else {
                    warning ("BuildTask(%s): could not get library for g-ir-scanner task", id);
                }
            } else if (cmd_basename == "glib-compile-resources") {
                File[] source_dirs = {};
                string? last_arg = null;

                foreach (string arg in arguments) {
                    if (last_arg == "--sourcedir")
                        source_dirs += File.new_for_commandline_arg_and_cwd (arg, output_dir);
                    last_arg = arg;
                }

                foreach (var input_file in input) {
                    if (!input_file.get_path ().has_suffix (".gresources.xml"))
                        break;

                    string gresources_xml;
                    FileUtils.get_contents (input_file.get_path (), out gresources_xml);
                    var potential_gresources = Util.discover_gresources_xml_input_files (gresources_xml, source_dirs);
                    candidate_inputs.add_all_array (potential_gresources);
                    used_files.add_all_array (potential_gresources);
                }
            }
        }
    }

    public override async void rebuild_async (Cancellable? cancellable = null) throws Error {
        // don't run this task if our inputs haven't changed
        if (!input.is_empty && !output.is_empty) {
            bool inputs_modified_after = false;

            foreach (File file in input) {
                FileInfo info = yield file.query_info_async (
                    FileAttribute.TIME_MODIFIED,
                    FileQueryInfoFlags.NONE,
                    Priority.DEFAULT,
                    cancellable
                );
                DateTime? file_last_modified;
#if GLIB_2_62
                file_last_modified = info.get_modification_date_time ();
#else
                TimeVal time_last_modified = info.get_modification_time ();
                file_last_modified = new DateTime.from_iso8601 (time_last_modified.to_iso8601 (), null);
#endif
                if (file_last_modified == null)
                    warning ("BuildTask(%s) could not get last modified time of %s", id, file.get_path ());
                else if (file_last_modified.compare (last_updated) > 0) {
                    inputs_modified_after = true;
                    break;
                }
            }

            if (!inputs_modified_after)
                return;
        }

        Subprocess process = launcher.spawnv (arguments);
        yield process.wait_async (cancellable);
        if (cancellable.is_cancelled ()) {
            process.force_exit ();
            cancellable.set_error_if_cancelled ();
        } else if (!process.get_successful ()) {
            string failed_msg = "";
            if (process.get_if_exited ()) {
                failed_msg = @"BuildTask($id) `$exe_name' returned with status $(process.get_exit_status ()) (launched from $build_dir)";
            } else {
                failed_msg = @"BuildTask($id) `$exe_name' terminated (launched from $build_dir)";
            }
            // TODO: fix these Meson issues before enabling the following line:
            // 1. gnome.compile_resources() with depfile produces @DEPFILE@ in
            //    targets without reference to depfle file (see plugins/files/meson.build in gitg)
            // 2. possible issue with how arguments to glib-compile-resources are introspected
            //    when using gnome.compile_resources() (again, see plugins/files/meson.build in gitg)

            // throw new ProjectError.TASK_FAILED (failed_msg);
            warning (failed_msg);
        } else {
            if (output.size == 1 && !output[0].query_exists (cancellable)) {
                // write contents of stdout to the output file if it was not created
                var output_file = output[0];
                var process_output_istream = process.get_stdout_pipe ();
                if (process_output_istream != null) {
                    var outfile_ostream = yield output_file.replace_async (
                        null,
                        false,
                        FileCreateFlags.NONE,
                        Priority.DEFAULT,
                        cancellable
                    );
                    yield outfile_ostream.splice_async (
                        process_output_istream,
                        OutputStreamSpliceFlags.NONE,
                        Priority.DEFAULT,
                        cancellable
                    );
                }
            }
            last_updated = new DateTime.now ();
        }
    }
}
