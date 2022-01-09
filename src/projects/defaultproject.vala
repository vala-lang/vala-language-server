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
    public DefaultProject (string root_path) {
        base (root_path);
    }

    public override async bool reconfigure_async (Cancellable? cancellable = null) throws Error {
        // this should do nothing, since we don't have a backend
        return false;
    }

    public override async ArrayList<Pair<Vala.SourceFile, Compilation>> open (
        string escaped_uri,
        string? content = null,
        Cancellable? cancellable = null
    ) throws Error {
        // create a new compilation
        var file = File.new_for_uri (Uri.unescape_string (escaped_uri));
        Compilation btarget;
        string uri = file.get_uri ();
        string[] sources = {};
        string[] args = {};
        // glib-2.0.vapi and gobject-2.0.vapi are already added
        if (!uri.has_suffix ("glib-2.0.vapi") && !uri.has_suffix ("gobject-2.0.vapi")) {
            sources += uri;
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
        btarget = new Compilation (root_path, uri, uri, build_targets.size,
                                   {"valac"}, args, sources, {}, {}, content != null ? new string[]{content} : null);
        // build it now so that information is available immediately on
        // file open (other projects compile on LSP initialize(), so they don't
        // need to do this)
        yield btarget.rebuild_async (cancellable);
        // make sure this comes after, that way btarget only gets added
        // if the build succeeds
        build_targets.add (btarget);
        debug ("DefaultProject: added %s", uri);

        return lookup_compile_input_source_file (escaped_uri);
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
