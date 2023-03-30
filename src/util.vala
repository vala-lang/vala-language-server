/* util.vala
 *
 * Copyright 2020-2022 Princeton Ferro <princetonferro@gmail.com>
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

namespace Vls.Util {
    public static T? parse_variant<T> (Variant variant) {
        var json = Json.gvariant_serialize (variant);
        return Json.gobject_deserialize (typeof (T), json);
    }

    public static Variant object_to_variant (Object object) throws Error {
        var json = Json.gobject_serialize (object);
        return Json.gvariant_deserialize (json, null);
    }

    /**
     * Gets the offset, in bytes, of the UTF-8 character at the given line and
     * position.
     * Both lineno and charno must be zero-indexed.
     */
    public static size_t get_string_pos (string str, uint lineno, uint charno) {
        int pos = 0;
        unowned string curstr = str;

        for (uint lno = 0; lno < lineno; ++lno) {
            int rel_idx = curstr.index_of_char ('\n');
            if (rel_idx == -1)
                break;
            pos += rel_idx;
            curstr = curstr.offset (rel_idx);
            if (curstr[1] != '\0') {
                // skip past the newline
                pos++;
                curstr = curstr.offset (1);
            } else {
                break;
            }
        }

        return pos + curstr.index_of_nth_char (charno);
    }

    /**
     * Gets the line and column of the pattern in [str]. Advances [lineno] and [charno] past the end of the pattern.
     */
    public static void advance_past (string str, Regex pattern, ref uint lineno, ref uint charno) {
        MatchInfo match_info;
        if (pattern.match (str, 0, out match_info)) {
            int end_pos;
            if (match_info.fetch_pos (0, null, out end_pos)) {
                char *p;
                for (p = str; *p != '\0' && end_pos-- >= 0; p++) {
                    if (is_newline (*p)) {
                        lineno++;
                        charno = 0;
                    } else {
                        charno++;
                    }
                }
            }
        }
    }

    /**
     * Parses arguments from a command string, taking care of escaped spaces
     * and single quotations.
     */
    public static string[] get_arguments_from_command_str (string str) throws RegexError {
        MatchInfo match_info;
        string[] args = {};

        // XXX: while this regex handles special cases, it can probably still be simplified, or transformed into a more-readable parser
        if (/(?(?<=')((\\\\|[^'\\\s]|\\')(\\\\|[^'\\]|\\')*(?='))|(?(?<=")((\\\\|[^"\\\s]|\\")(\\\\|[^"\\]|\\["abfnrtv])*(?="))|((?!["'])((?!\\ )(\\\\|[^\s;])|\\ ))+))/
            .match (str, 0, out match_info)) {
            while (match_info.matches ()) {
                args += match_info.fetch (0);
                match_info.next ();
            }
        }

        return args;
    }

    public static int iterate_valac_args (string[] args, out string? flag_name, out string? arg_value, int last_arg_index) {
        last_arg_index = last_arg_index + 1;

        if (last_arg_index >= args.length) {
            flag_name = null;
            arg_value = null;
            return last_arg_index;
        }

        string param = args[last_arg_index];

        do {
            MatchInfo match_info;
            if (/^--(\w*[\w-]*\w+)(=.+)?$/.match (param, 0, out match_info)) {
                // this is a lone flag
                flag_name = match_info.fetch (1);
                arg_value = match_info.fetch (2);

                if (arg_value != null && arg_value.length > 0)
                    arg_value = arg_value.substring (1);

                if (arg_value == null || arg_value.length == 0) {
                    arg_value = null;
                    // depending on the type of flag, we may need to parse another argument,
                    // since arg_value is NULL
                    if (flag_name == "vapidir" || flag_name == "girdir" ||
                        flag_name == "metadatadir" || flag_name == "pkg" ||
                        flag_name == "vapi" || flag_name == "library" ||
                        flag_name == "shared-library" || flag_name == "gir" ||
                        flag_name == "basedir" || flag_name == "directory" ||
                        flag_name == "header" || flag_name == "includedir" ||
                        flag_name == "internal-header" || flag_name == "internal-vapi" ||
                        flag_name == "symbols" || flag_name == "output" ||
                        flag_name == "define" || flag_name == "main" ||
                        flag_name == "cc" || flag_name == "Xcc" || flag_name == "pkg-config" ||
                        flag_name == "dump-tree" || flag_name == "profile" ||
                        flag_name == "color" || flag_name == "target-glib" ||
                        flag_name == "gresources" || flag_name == "gresourcesdir") {
                        if (last_arg_index < args.length - 1)
                            last_arg_index++;
                        arg_value = args[last_arg_index];
                    }
                }
            } else if (/^-(\w)(.+)?$/.match (param, 0, out match_info)) {
                string short_flag = match_info.fetch (1);
                string? short_arg = match_info.fetch (2);

                if (short_arg != null && short_arg.length == 0)
                    short_arg = null;

                if (short_flag == "b") {
                    param = "--basedir" + (short_arg != null ? @"=$short_arg" : "");
                    continue;
                } else if (short_flag == "d") {
                    param = "--directory" + (short_arg != null ? @"=$short_arg" : "");
                    continue;
                } else if (short_flag == "C") {
                    param = "--ccode";
                    continue;
                } else if (short_flag == "H") {
                    param = "--header" + (short_arg != null ? @"=$short_arg" : "");
                    continue;
                } else if (short_flag == "h") {
                    param = "--internal-header" + (short_arg != null ? @"=$short_arg" : "");
                    continue;
                } else if (short_flag == "c") {
                    param = "--compile";
                    continue;
                } else if (short_flag == "o") {
                    param = "--output" + (short_arg != null ? @"=$short_arg" : "");
                    continue;
                } else if (short_flag == "g") {
                    param = "--debug";
                    continue;
                } else if (short_flag == "D") {
                    param = "--define" + (short_arg != null ? @"=$short_arg" : "");
                    continue;
                } else if (short_flag == "k") {
                    param = "--keep-going";
                    continue;
                } else if (short_flag == "X") {
                    param = "--Xcc" + (short_arg != null ? @"=$short_arg" : "");
                    continue;
                } else if (short_flag == "q") {
                    param = "--quiet";
                    continue;
                } else if (short_flag == "v") {
                    param = "--verbose";
                    continue;
                }

                flag_name = null;
                arg_value = short_arg;
            } else {
                flag_name = null;
                arg_value = param;
            }
            break;
        } while (true);

        return last_arg_index;
    }

    public bool arg_is_vala_file (string arg) {
        return /^.*\.(vala|vapi|gir|gs)(\.in)?$/.match (arg);
    }

    static bool ends_with_dir_separator (string s) {
        return Path.is_dir_separator (s.get_char (s.length - 1));
    }

    /**
     * Copied from libvala
     *
     * @see Vala.CodeContext.realpath
     */
    public static string realpath (string name, string? cwd = null) {
        string rpath;

        // start of path component
        weak string start;
        // end of path component
        weak string end;

        if (!Path.is_absolute (name)) {
            // relative path
            rpath = cwd == null ? Environment.get_current_dir () : cwd;

            start = end = name;
        } else {
            // set start after root
            start = end = Path.skip_root (name);

            // extract root
            rpath = name.substring (0, (int) ((char*) start - (char*) name));
        }

        long root_len = (long) ((char*) Path.skip_root (rpath) - (char*) rpath);

        for (; start.get_char () != 0; start = end) {
            // skip sequence of multiple path-separators
            while (Path.is_dir_separator (start.get_char ())) {
                start = start.next_char ();
            }

            // find end of path component
            long len = 0;
            for (end = start; end.get_char () != 0 && !Path.is_dir_separator (end.get_char ()); end = end.next_char ()) {
                len++;
            }

            if (len == 0) {
                break;
            } else if (len == 1 && start.get_char () == '.') {
                // do nothing
            } else if (len == 2 && start.has_prefix ("..")) {
                // back up to previous component, ignore if at root already
                if (rpath.length > root_len) {
                    do {
                        rpath = rpath.substring (0, rpath.length - 1);
                    } while (!ends_with_dir_separator (rpath));
                }
            } else {
                if (!ends_with_dir_separator (rpath)) {
                    rpath += Path.DIR_SEPARATOR_S;
                }

                // don't use len, substring works on bytes
                rpath += start.substring (0, (long)((char*)end - (char*)start));
            }
        }

        if (rpath.length > root_len && ends_with_dir_separator (rpath)) {
            rpath = rpath.substring (0, rpath.length - 1);
        }

        if (Path.DIR_SEPARATOR != '/') {
            // don't use backslashes internally,
            // to avoid problems in #include directives
            string[] components = rpath.split ("\\");
            // casefold drive letters on Windows (c: -> C:)
            if (components.length > 0 && components[0].length > 1 && components[0].data[1] == ':') {
                components[0].data[0] = ((char)components[0].data[0]).toupper ();
            }
            rpath = string.joinv ("/", components);
        }

        return rpath;
    }

    /**
     * Like a cross-platform `rm -rf`
     */
    public void remove_dir (string path) {
        try {
            var dir = File.new_for_path (path);
            FileEnumerator enumerator = dir.enumerate_children (FileAttribute.ID_FILE, FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? finfo;

            while ((finfo = enumerator.next_file ()) != null) {
                File child = dir.get_child (finfo.get_name ());
                try {
                    if (finfo.get_file_type () == FileType.DIRECTORY)
                        remove_dir (child.get_path ());
                    else
                        child.@delete ();
                } catch (Error e) {
                    // ignore error
                }
            }
            dir.@delete ();
        } catch (Error e) {
            // ignore error
        }
    }

    public ArrayList<File> find_files (File dir, Regex basename_pattern, 
                                       uint max_depth = 1, Cancellable? cancellable = null,
                                       ArrayList<File> found = new ArrayList<File> ()) throws Error {
        assert (max_depth >= 1);
        FileEnumerator enumerator = dir.enumerate_children (
            "standard::*",
            FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
            cancellable);

        try {
            FileInfo? finfo;
            while ((finfo = enumerator.next_file (cancellable)) != null) {
                if (finfo.get_file_type () == FileType.DIRECTORY) {
                    if (max_depth > 1) {
                        find_files (enumerator.get_child (finfo), basename_pattern, max_depth - 1, cancellable, found);
                    }
                } else if (basename_pattern.match (finfo.get_name ())) {
                    found.add (enumerator.get_child (finfo));
                }
            }
        } catch (Error e) {
            warning ("could not get next file in dir %s", dir.get_path ());
        }

        return found;
    }

    public uint file_hash (File file) {
        string? path = file.get_path ();
        if (path != null)
            return realpath (path).hash ();
        return file.get_uri ().hash ();
    }

    public bool file_equal (File file1, File file2) {
        return file_hash (file1) == file_hash (file2);
    }

    public uint source_file_hash (Vala.SourceFile source_file) {
        return str_hash (source_file.filename);
    }

    public bool source_file_equal (Vala.SourceFile source_file1, Vala.SourceFile source_file2) {
        return source_file_hash (source_file1) == source_file_hash (source_file2);
    }

    public bool source_ref_equal (Vala.SourceReference source_ref1, Vala.SourceReference source_ref2) {
        return source_ref1.contains (source_ref2.begin) && source_ref1.contains (source_ref2.end) &&
            source_ref2.contains (source_ref1.begin) && source_ref2.contains (source_ref1.end);
    }

    /**
     * (stolen from VersionAttribute.cmp_versions in `vala/valaversionattribute.vala`)
     * A simple version comparison function.
     *
     * @param v1str a version number
     * @param v2str a version number
     * @return an integer less than, equal to, or greater than zero, if v1str is <, == or > than v2str
     * @see GLib.CompareFunc
     */
    public static int compare_versions (string v1str, string v2str) {
        string[] v1arr = v1str.split (".");
        string[] v2arr = v2str.split (".");
        int i = 0;

        while (v1arr[i] != null && v2arr[i] != null) {
            int v1num = int.parse (v1arr[i]);
            int v2num = int.parse (v2arr[i]);

            if (v1num < 0 || v2num < 0) {
                // invalid format
                return 0;
            }

            if (v1num > v2num) {
                return 1;
            }

            if (v1num < v2num) {
                return -1;
            }

            i++;
        }

        if (v1arr[i] != null && v2arr[i] == null) {
            return 1;
        }

        if (v1arr[i] == null && v2arr[i] != null) {
            return -1;
        }

        return 0;
    }

    /**
     * Counts the number of occurrences of @character in @str
     *
     * @param str           the string to search
     * @param character     the character to search for
     * @param last_char_pos the position of the last occurrence of @character in @str
     */
    public uint count_chars_in_string (string str, char character, out int last_char_pos = null) {
        uint count = 0;
        last_char_pos = -1;
        for (int i = 0; i < str.length; i++) {
            if (str[i] == character) {
                count++;
                last_char_pos = i;
            }
        }
        return count;
    }

    private class GresourceParser {
        private const MarkupParser parser = {
            null,
            null,
            visit_text
        };

        private MarkupParseContext context;

        private File[] source_dirs = {};
        public File[] files = {};

        private void visit_text (MarkupParseContext context, string text, size_t text_len) throws MarkupError {
            if (context.get_element () == "file") {
                foreach (var dir in source_dirs) {
                    var child = dir.get_child (text);
                    files += child;
                }
            }
        }

        public GresourceParser (File[] source_dirs) {
            this.source_dirs = source_dirs;
            context = new MarkupParseContext (parser, 0, this, null);
        }

        public void parse (string content) throws MarkupError {
            context.parse (content, -1);
        }
    }

    /**
     * Discover all {@link GLib.Resource}s that `glib-compile-resources` will
     * lookup when parsing `gresources_xml`. This includes files that may not
     * exist.
     *
     * @param gresources_xml    Well-formed XML that would be parsed by `glib-compile-resources`.
     * @param source_dirs       A list of source dirs to search in. If empty, the return array is guaranteed to be empty.
     * @return A list of files pointing to searched resources.
     */
    public File[] discover_gresources_xml_input_files (string gresources_xml, File[] source_dirs) throws MarkupError {
        var parser = new GresourceParser (source_dirs);
        parser.parse (gresources_xml);
        return parser.files;
    }

    public bool is_newline (char character) {
        return character == '\n' || character == '\r';
    }
}
