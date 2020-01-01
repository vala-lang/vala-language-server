/**
 * Represents a build target without any backend.
 */
class Vls.SimpleTarget : BuildTarget {
    public SimpleTarget (string root_dir, Cancellable? cancellable = null) throws Error {
        base (root_dir, root_dir, root_dir);

        add_compilations_for_dir (File.new_for_path (root_dir), cancellable);
    }

    private void add_compilations_for_dir (File dir, Cancellable? cancellable = null) throws Error {
        FileEnumerator enumerator = dir.enumerate_children (
            "standard::*",
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
            cancellable);

        FileInfo? info = null;
        var compilation = new Compilation (this, false, false, Vala.Profile.GOBJECT, false);
        int num_sources = 0;

        while ((cancellable == null ||
               !cancellable.is_cancelled ()) &&
               (info = enumerator.next_file (cancellable)) != null) {
            if (info.get_file_type () == FileType.DIRECTORY) {
                add_compilations_for_dir (enumerator.get_child (info), cancellable);
            } else {
                var file = enumerator.get_child (info);
                string fname = file.get_path ();
                if ((fname.has_suffix (".vala") || fname.has_suffix (".gs") ||
                    fname.has_suffix (".vapi") || fname.has_suffix (".gir")) &&
                    !info.get_is_backup ()) {
                    debug (@"SimpleTarget: adding text document `$fname'");
                    compilation.add_source_file (fname);
                    num_sources ++;
                }
            }
        }

        if (cancellable != null && cancellable.is_cancelled ()) {
            throw new IOError.CANCELLED ("Operation was cancelled");
        }

        if (num_sources > 0) {
            debug (@"SimpleTarget: adding compilation for $(dir.get_path ())");
            compilations.add (compilation);
        }
    }
}
