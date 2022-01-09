/* ccproject.vala
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
 * A backend for `compile_commands.json` files. 
 */
class Vls.CcProject : Project {
    private bool build_files_have_changed = true;
    private File cc_json_file;
    private HashMap<File, FileMonitor> build_files = new HashMap<File, FileMonitor> (Util.file_hash, Util.file_equal);

    private string build_dir;

    public override async bool reconfigure_async (Cancellable? cancellable = null) throws Error {
        if (!build_files_have_changed) {
            return false;
        }

        build_targets.clear ();
        build_files_have_changed = false;

        debug ("CcProject: configuring in build dir %s ...", build_dir);

        if (!build_files.has_key (cc_json_file)) {
            debug ("CcProject: obtaining a new file monitor for %s ...", cc_json_file.get_path ());
            FileMonitor file_monitor = cc_json_file.monitor_file (FileMonitorFlags.NONE, cancellable);
            file_monitor.changed.connect (file_changed_event);
            build_files[cc_json_file] = file_monitor;
        }

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

            if (cc.command.length == 0) {
                warning ("CC#%d has empty command list", i);
                continue;
            }

            if (cc.command[0].contains ("valac"))
                build_targets.add (new Compilation (cc.directory, cc.file ?? @"CC#$i", @"CC#$i", i,
                                                    cc.command[0:1], cc.command[1:cc.command.length],
                                                    new string[]{}, new string[]{}, new string[]{}));
            else
                build_targets.add (yield new BuildTask (cc.directory, cc.directory, cc.file ?? @"CC#$i", @"CC#$i", i,
                                                        cc.command[0:1], cc.command[1:cc.command.length], 
                                                        new string[]{}, new string[]{},
                                                        new string[]{}, "unknown"));
        }

        analyze_build_targets (cancellable);

        return true;
    }

    public async CcProject (string root_path, string cc_location, Cancellable? cancellable = null) throws Error {
        base (root_path);

        var root_dir = File.new_for_path (root_path);
        var cc_json_file = File.new_for_commandline_arg_and_cwd (cc_location, root_path);
        string? relative_path = root_dir.get_relative_path (cc_json_file);

        if (relative_path == null) {
            throw new ProjectError.INTROSPECTION (@"$cc_location is not relative to project root");
        }

        this.build_dir = cc_json_file.get_parent ().get_path ();
        this.cc_json_file = cc_json_file;

        yield reconfigure_async (cancellable);
    }

    private void file_changed_event (File src, File? dest, FileMonitorEvent event_type) {
        if (FileMonitorEvent.ATTRIBUTE_CHANGED in event_type) {
            debug ("CcProject: watched file %s had an attribute changed", src.get_path ());
            build_files_have_changed = true;
            changed ();
        }
        if (FileMonitorEvent.CHANGED in event_type) {
            debug ("CcProject: watched file %s was changed", src.get_path ());
            build_files_have_changed = true;
            changed ();
        }
        if (FileMonitorEvent.DELETED in event_type) {
            debug ("CcProject: watched file %s was deleted", src.get_path ());
            // remove this file monitor since the file was deleted
            FileMonitor file_monitor;
            if (build_files.unset (src, out file_monitor)) {
                file_monitor.cancel ();
                file_monitor.changed.disconnect (file_changed_event);
            }
            build_files_have_changed = true;
            changed ();
        }
    }
}
