/**
 * A backend for `compile_commands.json` files. 
 */
class Vls.CcProject : Project {
    private string root_path;
    private string build_dir;
    private File cc_json_file;

    public override bool reconfigure_if_stale (Cancellable? cancellable = null) throws Error {
        debug ("CcProject: configuring in build dir %s ...", build_dir);

        var parser = new Json.Parser.immutable_new ();
        parser.load_from_stream (cc_json_file.read (cancellable), cancellable);
        Json.Node? cc_json_root = parser.get_root ();

        if (cc_json_root == null)
            throw new ProjectError.INTROSPECTION (@"JSON root is null. Bailing out!");

        // iterate over all compile commands
        int i = -1;
        foreach (Json.Node cc_node in cc_json_root.get_array ().get_elements ()) {
            i++;
            if (cc_node.get_node_type () != Json.NodeType.OBJECT)
                throw new ProjectError.INTROSPECTION (@"JSON node is not an object. Bailing out!");
            var cc = Json.gobject_deserialize (typeof (CompileCommand), cc_node) as CompileCommand?;
            if (cc == null)
                throw new ProjectError.INTROSPECTION (@"JSON node is null. Bailing out!");

            if (cc.command.length > 0 && cc.command[0].contains ("valac"))
                build_targets.add (new Compilation (cc.directory, cc.file ?? @"CC#$i", @"CC#$i", i,
                                                    cc.command[0:1], cc.command[1:cc.command.length],
                                                    new string[]{}, new string[]{}));
            else
                build_targets.add (new BuildTask (cc.directory, cc.file ?? @"CC#$i", @"CC#$i", i,
                                                  cc.command[0:1], cc.command[1:cc.command.length], 
                                                  new string[]{}, new string[]{},
                                                  new string[]{}, "unknown"));
        }

        analyze_build_targets (cancellable);

        return true;
    }

    public CcProject (string root_path, string cc_location, Cancellable? cancellable = null) throws Error {
        var root_dir = File.new_for_path (root_path);
        var cc_json_file = File.new_for_commandline_arg_and_cwd (cc_location, root_path);
        string? relative_path = root_dir.get_relative_path (cc_json_file);

        if (relative_path == null) {
            throw new ProjectError.INTROSPECTION (@"$cc_location is not relative to project root");
        }

        this.root_path = root_path;
        this.build_dir = cc_json_file.get_parent ().get_path ();
        this.cc_json_file = cc_json_file;

        reconfigure_if_stale (cancellable);
    }
}
