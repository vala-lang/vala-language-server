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
        int linepos = -1;

        for (uint lno = 0; lno < lineno; ++lno) {
            int pos = str.index_of_char ('\n', linepos + 1);
            if (pos == -1)
                break;
            linepos = pos;
        }

        string remaining_str = str.substring (linepos + 1);

        return linepos + 1 + remaining_str.index_of_nth_char (charno);
    }

    /**
     * Parses arguments from a command string, taking care of escaped spaces
     * and single quotations.
     */
    public static string[] get_arguments_from_command_str (string str) throws RegexError {
        MatchInfo match_info;
        string[] args = {};

        if (/(?(?<=')((\\\\|[^'\\]|\\')*(?='))|((?!')((?!\\ )(\\\\|\S)|\\ ))+)/.match (str, 0, out match_info)) {
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

                if (arg_value != null)
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

    public bool arg_is_file (string arg) {
        return /\.(vala|vapi|gir|gs)(\.in)?$/.match (arg);
    }


    static bool ends_with_dir_separator (string s) {
        return Path.is_dir_separator (s.get_char (s.length - 1));
    }

    /**
     * Copied from libvala (see Vala.CodeContext.realpath ())
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
            if (components.length > 0)
                components[0] = components[0].up ();
            rpath = string.joinv ("/", components);
        }

        return rpath;
    }

    public uint file_hash (File file) {
        return realpath (file.get_path ()).hash ();
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
}
