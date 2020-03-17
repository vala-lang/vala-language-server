using Gee;

/**
 * Represents a build target when it is an arbitrary command.
 */
class Vls.BuildTask : BuildTarget {
    private string[] arguments = {};
    private string exe_name = "";

    /**
     * Because a built task could be any command, we don't know whether the files
     * that appear in the arg list are inputs or outputs initially.
     */
    public ArrayList<File> used_files { get; private set; default = new ArrayList<File> (); }

    public BuildTask (string build_dir, string name, string id, int no,
                      string[] compiler, string[] args, string[] sources, string[] generated_sources) {
        base (build_dir, name, id, no);

        foreach (string arg in compiler) {
            arguments += arg;
            exe_name += arg;
        }

        foreach (string arg in args)
            arguments += arg;

        foreach (string arg in arguments)
            if (Util.arg_is_file (arg))
                used_files.add (File.new_for_commandline_arg_and_cwd (arg, build_dir));

        foreach (string arg in sources) {
            arguments += arg;
            used_files.add (File.new_for_commandline_arg_and_cwd (arg, build_dir));
        }

        foreach (string arg in generated_sources) {
            arguments += arg;
            used_files.add (File.new_for_commandline_arg_and_cwd (arg, build_dir));
        }
    }

    public override void build_if_stale (Cancellable? cancellable = null) throws Error {
        var process = new Subprocess.newv (arguments, SubprocessFlags.NONE);
        process.wait (cancellable);
        if (cancellable != null && cancellable.is_cancelled ()) {
            process.force_exit ();
            cancellable.set_error_if_cancelled ();
        } else if (!process.get_successful ()) {
            if (process.get_if_exited ()) {
                throw new ProjectError.TASK_FAILED (@"BuildTask($id) `$exe_name' returned with status $(process.get_exit_status ())");
            } else
                throw new ProjectError.TASK_FAILED (@"BuildTask($id) `$exe_name' terminated");
        }
        last_updated = new DateTime.now ();
    }
}
