using Gee;

/**
 * Represents a build target when it is an arbitrary command.
 */
class Vls.BuildTask : BuildTarget {
    private string[] arguments = {};
    private string exe_name = "";
    private SubprocessLauncher launcher;
    private bool failed_last = false;

    /**
     * Because a built task could be any command, we don't know whether the files
     * that appear in the arg list are inputs or outputs initially.
     */
    public ArrayList<File> used_files { get; private set; default = new ArrayList<File> (); }

    public BuildTask (string build_dir, string name, string id, int no,
                      string[] compiler, string[] args, string[] sources, string[] generated_sources) {
        base (build_dir, name, id, no);
        // don't pipe stderr since we want to print that if something goes wrong
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

        foreach (string arg in arguments)
            if (Util.arg_is_file (arg))
                used_files.add (File.new_for_commandline_arg_and_cwd (arg, build_dir));

        foreach (string arg in sources) {
            // we don't need to add arg to arguments here since we've already substituted
            // the arguments in [compiler] and [args] from the sources
            used_files.add (File.new_for_commandline_arg_and_cwd (arg, build_dir));
        }

        foreach (string arg in generated_sources) {
            arguments += arg;
            used_files.add (File.new_for_commandline_arg_and_cwd (arg, build_dir));
        }
    }

    public override void build_if_stale (Cancellable? cancellable = null) throws Error {
        if (failed_last)
            return;

        // don't run this task if our inputs haven't changed
        if (!input.is_empty && !output.is_empty) {
            bool inputs_modified_after = false;

            foreach (File file in input) {
                FileInfo info = file.query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE, cancellable);
                DateTime? file_last_modified = info.get_modification_date_time ();
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
        process.wait (cancellable);
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
            failed_last = true;
        } else {
            last_updated = new DateTime.now ();
        }
    }
}
