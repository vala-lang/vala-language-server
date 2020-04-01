using Gee;

/**
 * A project without any backend. Mainly useful for editing one file.
 */
class Vls.DefaultProject : Project {
    private string root_path;

    public DefaultProject (string root_path) {
        this.root_path = root_path;
    }

    public override bool reconfigure_if_stale (Cancellable? cancellable = null) throws Error {
        // this should do nothing, since we don't have a backend
        return false;
    }

    public override void open (string escaped_uri, Cancellable? cancellable = null) throws Error {
        // create a new compilation
        var file = File.new_for_uri (Uri.unescape_string (escaped_uri));
        string filename = file.get_path ();
        var btarget = new Compilation (root_path, filename, filename, build_targets.size,
                                       new string[] {"valac"}, new string[]{}, new string[] {filename}, new string[]{});
        btarget.input.add (file);
        // build it now so that information is available immediately on
        // file open (other projects compile on LSP initialize(), so they don't
        // need to do this)
        btarget.build_if_stale (cancellable);
        build_targets.add (btarget);
        debug ("DefaultProject: added file %s", filename);
    }

    public override void close (string escaped_uri) {
        foreach (Pair<Vala.SourceFile, Compilation> result in lookup_compile_input_source_file (escaped_uri)) {
            build_targets.remove (result.second);
        }
    }
}
