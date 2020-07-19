class Vls.GirDocumentation {
    private Vala.CodeContext context;
    private Gee.HashMap<string, string?> added = new Gee.HashMap<string, string?> ();
    private Gee.HashMap<string, Vala.Symbol> cname_to_sym = new Gee.HashMap<string, Vala.Symbol> ();

    private static uint source_file_hash (Vala.SourceFile source_file) {
        return source_file.filename.hash ();
    }

    private static bool source_file_equal (Vala.SourceFile source_file1, Vala.SourceFile source_file2) {
        return source_file1.filename == source_file2.filename;
    }

    private HashTable<Vala.SourceFile, string> gtkdoc_dirs = new HashTable<Vala.SourceFile, string> (source_file_hash, source_file_equal);

    private class Sink : Vala.Report {
        public override void depr (Vala.SourceReference? sr, string message) { /* do nothing */ }
        public override void err (Vala.SourceReference? sr, string message) { /* do nothing */ }
        public override void warn (Vala.SourceReference? sr, string message) { /* do nothing */ }
        public override void note (Vala.SourceReference? sr, string message) { /* do nothing */ }
    }

    private void add_gir (string gir_package, string? vapi_package) {
        string? girpath = context.get_gir_path (gir_package);
        if (girpath != null) {
            context.add_source_file (new Vala.SourceFile (context, Vala.SourceFileType.PACKAGE, girpath));
            added[gir_package] = vapi_package;
        }
    }

    /**
     * Create a new holder for GIR docs by adding all GIRs found in
     * `/usr/share/gir-1.0` and `/usr/local/share/gir-1.0`
     */
    public GirDocumentation (Gee.Collection<Vala.SourceFile> packages) {
        context = new Vala.CodeContext ();
        context.report = new Sink ();
        Vala.CodeContext.push (context);
#if VALA_0_50
        context.set_target_profile (Vala.Profile.GOBJECT, false);
#else
        context.profile = Vala.Profile.GOBJECT;
        context.add_define ("GOBJECT");
#endif

        // add packages
        add_gir ("GLib-2.0", "glib-2.0");
        add_gir ("GObject-2.0", "gobject-2.0");

        foreach (string data_dir in Environment.get_system_data_dirs ()) {
            File dir = File.new_for_path (Path.build_filename (data_dir, "gir-1.0"));
            if (!dir.query_exists ())
                continue;
            try {
                var enumerator = dir.enumerate_children (
                    "standard::*",
                    FileQueryInfoFlags.NONE);
                FileInfo? file_info;
                while ((file_info = enumerator.next_file ()) != null) {
                    if ((file_info.get_file_type () != FileType.REGULAR &&
                        file_info.get_file_type () != FileType.SYMBOLIC_LINK) ||
                        file_info.get_is_backup () || file_info.get_is_hidden () ||
                        !file_info.get_name ().has_suffix (".gir"))
                        continue;
                    string gir_pkg = Path.get_basename (file_info.get_name ());
                    gir_pkg = gir_pkg.substring (0, gir_pkg.length - ".gir".length);
                    Vala.SourceFile? vapi_pkg_match = packages.first_match (
                        pkg => pkg.gir_version != null && @"$(pkg.gir_namespace)-$(pkg.gir_version)" == gir_pkg);
                    if (!added.has_key (gir_pkg) && vapi_pkg_match != null) {
                        debug (@"adding GIR $gir_pkg for package $(vapi_pkg_match.package_name)");
                        add_gir (gir_pkg, vapi_pkg_match.package_name);
                    }
                }
            } catch (Error e) {
                debug (@"could not enumerate $(dir.get_uri ()): $(e.message)");
            }
        }

        string missed = "";
        packages.filter (pkg => !added.keys.any_match (pkg_name => pkg.gir_version != null && pkg_name == @"$(pkg.gir_namespace)-$(pkg.gir_version)"))
            .foreach (vapi_pkg => {
                if (missed.length > 0)
                    missed += ", ";
                missed += vapi_pkg.package_name;
                return true;
            });
        if (missed.length > 0)
            debug (@"did not add GIRs for these packages: $missed");

        // add some types manually
        Vala.SourceFile? sr_file = null;
        foreach (var source_file in context.get_source_files ()) {
            if (source_file.filename.has_suffix ("GLib-2.0.gir"))
                sr_file = source_file;
        }
        var sr_begin = Vala.SourceLocation (null, 1, 1);
        var sr_end = sr_begin;

        // ... add string
        var string_class = new Vala.Class ("string", new Vala.SourceReference (sr_file, sr_begin, sr_end));
        context.root.add_class (string_class);

        // ... add bool
        var bool_type = new Vala.Struct ("bool", new Vala.SourceReference (sr_file, sr_begin, sr_end));
        bool_type.add_method (new Vala.Method ("to_string", new Vala.ClassType (string_class)));
        context.root.add_struct (bool_type);

        // ... add GLib namespace
        var glib_ns = new Vala.Namespace ("GLib", new Vala.SourceReference (sr_file, sr_begin, sr_end));
        context.root.add_namespace (glib_ns);

        // compile once
        var parser = new Vala.Parser ();
        parser.parse (context);
        var gir_parser = new Vala.GirParser ();
        gir_parser.parse (context);
        // context.check ();

        // build a cache of all CodeNodes with a C name
        context.accept (new CNameMapper (cname_to_sym));

        Vala.CodeContext.pop ();
    }

    /**
     * Decide to render a GTK-Doc formatted comment into Markdown.
     *
     * see https://developer.gnome.org/gtk-doc-manual/stable/documenting_syntax.html.en
     */
    public string render_gtk_doc_comment (Vala.Comment comment, Compilation compilation) throws GLib.RegexError {
        string comment_data = comment.content;

        // replace code blocks
        comment_data = /\|\[(<!-- language="(\w+)" -->)?((.|\s)*?)\]\|/
            .replace_eval (comment_data, comment_data.length, 0, 0, (match_info, result) => {
                string language = match_info.fetch (2) ?? "";
                string code = match_info.fetch (3) ?? "";

                result.append ("```");
                result.append (language.down ());
                result.append (code);
                result.append ("```");
                return false;
            });

        string? gtkdoc_dir = null;

        if (gtkdoc_dirs.contains (comment.source_reference.file))
            gtkdoc_dir = (!) gtkdoc_dirs[comment.source_reference.file];
        else {
            var data_dir = File.new_for_commandline_arg (comment.source_reference.file.filename);
            data_dir = (!) data_dir.get_parent ();
            if (data_dir.get_basename () == "gir-1.0")
                data_dir = (!) data_dir.get_parent ();

            var gtkdoc_dir_file = data_dir.get_child ("gtk-doc").get_child ("html");
            string? gir_package_name = comment.source_reference.file.package_name;

            if (gir_package_name != null) {
                var dir = gtkdoc_dir_file.get_child (added[gir_package_name] ?? gir_package_name);
                if (dir.query_exists ())
                    gtkdoc_dir = (!) dir.get_path ();
                else {
                    MatchInfo match_info;

                    if (/((\w+(-[a-zA-Z_]+)*)\+?)(-((\d+)(\.\d+)*))?/
                        .match (added[gir_package_name] ?? gir_package_name, 0, out match_info)) {
                        string package = (!) match_info.fetch (1);
                        string package_wo_plus = (!) match_info.fetch (2);
                        string? full_version = match_info.fetch (5);
                        // the first number of the version
                        string? abbrev_version = match_info.fetch (6);

                        // 1. try package name without version
                        dir = gtkdoc_dir_file.get_child (package);
                        if (dir.query_exists ())
                            gtkdoc_dir = (!) dir.get_path ();

                        // 2. try package name without plus and with full version
                        if (gtkdoc_dir == null && full_version != null) {
                            dir = gtkdoc_dir_file.get_child ("%s-%s".printf (package_wo_plus, full_version));
                            if (dir.query_exists ())
                                gtkdoc_dir = (!) dir.get_path ();
                        }

                        // 3. try package name without plus and with abbreviated version
                        if (gtkdoc_dir == null && abbrev_version != null) {
                            dir = gtkdoc_dir_file.get_child ("%s%s".printf (package_wo_plus, abbrev_version));
                            if (dir.query_exists ())
                                gtkdoc_dir = (!) dir.get_path ();
                        }
                    }
                }
            }

            // save the directory so that we don't have to do I/O every time
            if (gtkdoc_dir != null && comment.source_reference.file in context.get_source_files ()) {
                gtkdoc_dirs[comment.source_reference.file] = gtkdoc_dir;
                string? vapi_pkg_name = added[gir_package_name];
                debug ("found new GTK-Doc dir for GIR %s%s: %s", gir_package_name, vapi_pkg_name != null ? @" (VAPI $vapi_pkg_name)" : "", gtkdoc_dir);
            }
        }

        if (gtkdoc_dir != null) {
            // substitute image URLs
            // substitute relative paths in GIR comments for absolute paths to GTK-Doc resources
            comment_data = /!\[(.*?)\]\(([~:\/\\\w-.]+)\)/
                .replace_eval (comment_data, comment_data.length, 0, 0, (match_info, result) => {
                    string link_label = match_info.fetch (1) ?? "";
                    string link_href = match_info.fetch (2) ?? "";

                    result.append ("![");
                    result.append (link_label);
                    result.append ("](");
                    if (!Path.is_absolute (link_href))
                        link_href = Path.build_filename (gtkdoc_dir, link_href);
                    result.append (link_href);
                    result.append_c (')');
                    return false;
                });

            // first, find (and remove) all section headers in the document
            var headers = new Gee.ArrayList<string> ();

            comment_data = /(\s*?#*?\s*?)?\{#([\w-]+)\}/
                .replace_eval (comment_data, comment_data.length, 0, 0, (match_info, result) => {
                    string? header = match_info.fetch (2);

                    if (header != null)
                        headers.add (header);

                    return false;
                });

            // now, substitute references to sections
            comment_data = /\[(.*?)\]\[([\w-\s]+)\]/
                .replace_eval (comment_data, comment_data.length, 0, 0, (match_info, result) => {
                    string link_label = match_info.fetch (1) ?? "";
                    string section = match_info.fetch (2) ?? "";

                    if (section in headers) {
                        result.append_c ('[');
                        result.append (link_label);
                        result.append ("](");
                        result.append_c ('#');
                        result.append (section);
                        result.append_c (')');
                    } else {
                        // if the reference is to an external section
                        var section_html_file = File.new_build_filename (gtkdoc_dir, @"$section.html");
                        if (section_html_file.query_exists ()) {
                            result.append_c ('[');
                            result.append (link_label);
                            result.append ("](");
                            result.append ((!) section_html_file.get_path ());
                            result.append_c (')');
                        } else {
                            result.append (link_label);
                        }
                    }

                    return false;
                });
        }

        // substitute references to C names with their Vala symbol names
        comment_data = /([`])?([#%]([A-Za-z_]\w+)|([A-Za-z_]\w+)(\(\)))([`])?/
            .replace_eval (comment_data, comment_data.length, 0, 0, (match_info, result) => {
                string? begin_tick = match_info.fetch (1);
                string? group3 = match_info.fetch (3);
                string? group4 = match_info.fetch (4);
                string c_symbol = group3 != null && group3.length > 0 ? group3 : group4;
                string parameters = match_info.fetch (5) ?? "";
                string? end_tick = match_info.fetch (6);
                Vala.Symbol? vala_symbol = compilation.cname_to_sym[c_symbol];

                bool inside_code = begin_tick != null && begin_tick.length > 0 || end_tick != null && end_tick.length > 0;

                if (vala_symbol == null) {
                    if (c_symbol == "NULL" || c_symbol == "TRUE" || c_symbol == "FALSE") {
                        result.append ("**");
                        result.append (c_symbol.down ());
                        result.append ("**");
                    } else
                        result.append ((!) match_info.fetch (0));
                } else {
                    // debug ("replacing %s in documentation with %s", c_symbol, vala_symbol.get_full_name ());
                    var sym_sb = new StringBuilder ();
                    Vala.Symbol? previous_sym = null;
                    for (var current_sym = vala_symbol;
                            current_sym != null && current_sym.name != null; 
                            current_sym = current_sym.parent_symbol) {
                        if (current_sym is Vala.CreationMethod) {
                            sym_sb.prepend (current_sym.name == ".new" ? current_sym.parent_symbol.name : current_sym.name);
                        } else {
                            if (current_sym != vala_symbol) {
                                if (previous_sym is Vala.CreationMethod)
                                    sym_sb.prepend ("::");
                                else
                                    sym_sb.prepend_c ('.');
                            }
                            sym_sb.prepend (current_sym.name);
                        }
                        previous_sym = current_sym;
                    }
                    if (!inside_code)
                        result.append ("**");
                    result.append (sym_sb.str);
                    result.append (parameters);
                    if (!inside_code)
                        result.append ("**");
                }
                return false;
            });

        // substitute references to struct fields that are C virtual methods
        comment_data = /#(\w+)Class\.(\w+)(\(\))?/
            .replace_eval (comment_data, comment_data.length, 0, 0, (match_info, result) => {
                string class_or_iface_name = (!) match_info.fetch (1);
                string vmethod_name = (!) match_info.fetch (2);
                string parens = match_info.fetch (3) ?? "()";
                Vala.Symbol? sym = compilation.cname_to_sym[class_or_iface_name];
                Vala.Method? method_sym = null;

                if (sym != null && (method_sym = sym.scope.lookup (vmethod_name) as Vala.Method) != null) {
                    result.append ("**");
                    result.append (method_sym.get_full_name ());
                    result.append (parens);
                    result.append ("**");
                } else {
                    result.append ((!) match_info.fetch (0));
                }

                return false;
            });

        // highlight references to parameters
        comment_data = /(?<=\s|^|(?<!\w)\W)@([A-Za-z_]\w*)(?=\s|$|[^a-zA-Z0-9_.]|\.(?!\w))/
            .replace (comment_data, comment_data.length, 0, "`\\1`");

        return comment_data;
    }

    /**
     * Find the GIR symbol related to @sym
     */
    public Vala.Symbol? find_gir_symbol (Vala.Symbol sym) {
        var found_sym = Util.find_matching_symbol (context, sym);

        // fallback to C name
        if (found_sym == null) {
            string cname = CodeHelp.get_symbol_cname (sym);
            // debug ("could not find matching symbol, looking up C name %s for %s", cname, sym.to_string ());
            found_sym = cname_to_sym[cname];
        }

        return found_sym;
    }
}
