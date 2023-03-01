/* defaultproject.vala
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
 * A project without any backend. Mainly useful for editing one file.
 */
class Vls.DefaultProject : Project {
    // we have these functions to prevent a ref to this

    static uint str_hash (string s) {
        return GLib.str_hash (s);
    }

    static bool str_equal (string s1, string s2) {
        return GLib.str_equal (s1, s2);
    }

    /**
     * List of opened files (path names) for each compilation. Single-file 
     * compilations actually include multiple VAPI files, so we need to handle
     * cases where the user tries to open/close a VAPI that belongs to another
     * compilation.
     */
    private HashMultiMap<Compilation, string> opened = new HashMultiMap<Compilation, string> (
        null,
        null, 
        str_hash, 
        str_equal
    );

    public DefaultProject (string root_path, FileCache file_cache) {
        base (root_path, file_cache);
    }

    public override bool reconfigure_if_stale (Cancellable? cancellable = null) throws Error {
        // this should do nothing, since we don't have a backend
        return false;
    }

    public override ArrayList<Pair<Vala.SourceFile, Compilation>> open (string escaped_uri, string? content = null, Cancellable? cancellable = null) throws Error {
        // create a new compilation
        var file = File.new_for_uri (Uri.unescape_string (escaped_uri));
        string uri = file.get_uri ();
        string[] args = {};

        var results = lookup_compile_input_source_file (escaped_uri);
        // if the file is already open (ex: glib.vapi)
        if (!results.is_empty) {
            foreach (var item in results) {
                // we may be opening a VAPI that is already a part of another 
                // compilation, so ensure this file is marked as open
                opened[item.second] = item.first.filename;
                debug ("returning %s for %s", item.first.filename, uri);
            }
            return results;
        }

        // analyze interpeter line
        if (content != null && (content.has_prefix ("#!") || content.has_prefix ("//"))) {
            try {
                args = Util.get_arguments_from_command_str (content.substring (2, content.index_of_char ('\n')));
                debug ("parsed %d argument(s) from interpreter line ...", args.length);
                for (int i = 0; i < args.length; i++)
                    debug ("[arg %d] %s", i, args[i]);
            } catch (RegexError rerror) {
                warning ("failed to parse interpreter line");
            }
        }
        var btarget = new Compilation (file_cache, root_path, uri, uri, build_targets.size,
                                       {"valac"}, args, {uri}, {}, {},
                                       content != null ? new string[]{content} : null);
        // build it now so that information is available immediately on
        // file open (other projects compile on LSP initialize(), so they don't
        // need to do this)
        btarget.build_if_stale (cancellable);
        // make sure this comes after, that way btarget only gets added
        // if the build succeeds
        build_targets.add (btarget);
        debug ("added %s", uri);

        results = lookup_compile_input_source_file (escaped_uri);
        // mark only the requested filename as opened in this compilation
        foreach (var item in results)
            if (item.first.filename == file.get_path ())
                opened[item.second] = item.first.filename;
        return results;
    }

    public override bool close (string escaped_uri) {
        bool targets_removed = false;
        foreach (var result in lookup_compile_input_source_file (escaped_uri)) {
            // we need to remove this target only if all of its open files have been closed
            if (opened.remove (result.second, result.first.filename) && !(result.second in opened)) {
                build_targets.remove (result.second);
                targets_removed = true;
            }
        }
        return targets_removed;
    }
}
