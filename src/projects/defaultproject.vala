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
        Compilation btarget;
        string filename = file.get_path ();
        string[] sources = {};
        // glib-2.0.vapi and gobject-2.0.vapi are already added
        if (!filename.has_suffix ("glib-2.0.vapi") && !filename.has_suffix ("gobject-2.0.vapi")) {
            sources += filename;
        }
        btarget = new Compilation (root_path, filename, filename, build_targets.size,
                                   new string[] {"valac"}, new string[]{}, sources, new string[]{});
        // build it now so that information is available immediately on
        // file open (other projects compile on LSP initialize(), so they don't
        // need to do this)
        btarget.build_if_stale (cancellable);
        build_targets.add (btarget);
        debug ("DefaultProject: added file %s", filename);
    }

    public override bool close (string escaped_uri) {
        bool files_removed = false;
        foreach (Pair<Vala.SourceFile, Compilation> result in lookup_compile_input_source_file (escaped_uri)) {
            build_targets.remove (result.second);
            files_removed = true;
        }
        return files_removed;
    }
}
