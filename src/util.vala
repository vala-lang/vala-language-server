using Gee;

namespace Vls {
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

    public static int iterate_valac_args (string[] args, out string? flag_name, out string? arg_value, int last_arg_index = -1) {
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
}
