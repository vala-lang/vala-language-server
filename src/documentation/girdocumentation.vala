/* girdocumentation.vala
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

    private bool requires_rebuild;

    private class Sink : Vala.Report {
        public override void depr (Vala.SourceReference? sr, string message) { /* do nothing */ }
        public override void err (Vala.SourceReference? sr, string message) { /* do nothing */ }
        public override void warn (Vala.SourceReference? sr, string message) { /* do nothing */ }
        public override void note (Vala.SourceReference? sr, string message) { /* do nothing */ }
    }

    private bool add_gir (string gir_package, string? vapi_package) {
        string? girpath = context.get_gir_path (gir_package);
        if (girpath != null && !added.has (gir_package, vapi_package)) {
            Vala.CodeContext.push (context);
            context.add_source_file (new Vala.SourceFile (context, Vala.SourceFileType.PACKAGE, girpath));
            Vala.CodeContext.pop ();
            added[gir_package] = vapi_package;
            debug ("adding GIR %s for package %s", gir_package, vapi_package);
            return true;
        }
        return false;
    }

    private void create_context () {
        context = new Vala.CodeContext ();
        context.report = new Sink ();
        Vala.CodeContext.push (context);
#if VALA_0_50
        context.set_target_profile (Vala.Profile.GOBJECT, false);
#else
        context.profile = Vala.Profile.GOBJECT;
        context.add_define ("GOBJECT");
#endif
        Vala.CodeContext.pop ();
    }

    private void add_types () {
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
    }

    /**
     * Create a new holder for GIR docs by adding all GIRs found in
     * `/usr/share/gir-1.0` and `/usr/local/share/gir-1.0`, as well as
     * additional directories in `custom_gir_dirs`.
     *
     * @param vala_packages     set of VAPIs to find matching GIRs for
     * @param custom_gir_dirs   set of directories to search for additional GIRs in
     */
    public GirDocumentation (Gee.Collection<Vala.SourceFile> vala_packages,
                             Gee.Collection<File> custom_gir_dirs) {
        create_context ();
        Vala.CodeContext.push (context);

        // add additional dirs
        string[] gir_directories = context.gir_directories;
        foreach (var additional_gir_dir in custom_gir_dirs)
            gir_directories += additional_gir_dir.get_path ();
        context.gir_directories = gir_directories;

        // add packages
        add_gir ("GLib-2.0", "glib-2.0");
        add_gir ("GObject-2.0", "gobject-2.0");

        foreach (var vapi_pkg in vala_packages) {
            if (vapi_pkg.gir_namespace != null && vapi_pkg.gir_version != null)
                add_gir (@"$(vapi_pkg.gir_namespace)-$(vapi_pkg.gir_version)", vapi_pkg.package_name);
        }

        string missed = "";
        vala_packages.filter (pkg => !added.keys.any_match (pkg_name => pkg.gir_namespace != null && pkg.gir_version != null && pkg_name == @"$(pkg.gir_namespace)-$(pkg.gir_version)"))
            .foreach (vapi_pkg => {
                if (missed.length > 0)
                    missed += ", ";
                missed += vapi_pkg.package_name;
                return true;
            });
        if (missed.length > 0)
            debug (@"did not add GIRs for these packages: $missed");

        add_types ();

        // parse once
        var gir_parser = new Vala.GirParser ();
        gir_parser.parse (context);

        // build a cache of all CodeNodes with a C name
        context.accept (new CNameMapper (cname_to_sym));

        Vala.CodeContext.pop ();
    }

    /**
     * If `vapi_pkg` is a VAPI with an associated GIR that has not yet been
     * added, adds the GIR. Otherwise this does nothing.
     * {@link GirDocumentation.rebuild_context} must be called after adding a
     * new package.
     */
    public void add_package_from_source_file (Vala.SourceFile vapi_pkg) {
        if (vapi_pkg.gir_namespace != null && vapi_pkg.gir_version != null) {
            if (add_gir (@"$(vapi_pkg.gir_namespace)-$(vapi_pkg.gir_version)", vapi_pkg.package_name))
                requires_rebuild = true;
        }
    }

    /**
     * Rebuilds (parses) all of the packages in the context if necessary.
     * Otherwise, will do nothing.
     */
    public void rebuild_if_stale () {
        if (!requires_rebuild)
            return;

        requires_rebuild = false;
        // start rebuilding the context
        debug ("rebuilding context ...");

        // save custom GIR dirs
        string[] gir_directories = context.gir_directories;
        // save added
        var old_added = this.added;
        this.added = new Gee.HashMap<string, string?> ();

        create_context ();
        Vala.CodeContext.push (context);
        context.gir_directories = gir_directories;

        foreach (var entry in old_added)
            add_gir (entry.key, entry.value);

        add_types ();

        // parse once
        var gir_parser = new Vala.GirParser ();
        gir_parser.parse (context);

        // build a cache of all CodeNodes with a C name
        cname_to_sym.clear ();
        context.accept (new CNameMapper (cname_to_sym));

        Vala.CodeContext.pop ();
    }

    /**
     * Renders a gi-docgen formatted comment into Markdown.
     *
     * see [[https://gnome.pages.gitlab.gnome.org/gi-docgen/linking.html]]
     */
    public string render_gi_docgen_comment (Vala.Comment comment, Compilation compilation) throws GLib.RegexError {
        string comment_data = comment.content;

        comment_data = /\[(\w+)@(\w+(\.\w+)*)(::?([\w+\-]+))?\]/
            .replace_eval (comment_data, comment_data.length, 0, 0, (match_info, result) => {
                // string link_type = (!) match_info.fetch (1);
                string symbol_full = (!) match_info.fetch (2);
                string? signal_or_property_name = match_info.fetch (5);
                if (signal_or_property_name != null && signal_or_property_name.length > 0)
                    symbol_full += "." + signal_or_property_name.replace ("-", "_");
                Vala.Symbol? vala_symbol = CodeHelp.lookup_symbol_full_name (symbol_full, compilation.code_context.root.scope);

                if (vala_symbol == null) {
                    result.append ("**");
                    result.append (symbol_full);
                    result.append ("**");
                } else {
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
                    string? package_name = null;
                    if (vala_symbol.source_reference != null)
                        package_name = vala_symbol.source_reference.file.package_name;
                    if (package_name != null)
                        result.append_c ('[');
                    result.append ("**");
                    result.append (sym_sb.str);
                    if (vala_symbol is Vala.Callable && !(vala_symbol is Vala.Delegate))
                        result.append ("()");
                    result.append ("**");
                    if (package_name != null) {
                        result.append ("](");
                        result.append ("https://valadoc.org/");
                        result.append (package_name);
                        result.append_c ('/');
                        result.append (vala_symbol.get_full_name ());
                        result.append (".html");
                        result.append_c (')');
                    }
                }
                return false;
            });

        return render_gtk_doc_content (comment_data, comment, compilation);
    }

    /**
     * Gets the prefix of a ValaDoc file for a given symbol
     */
    string get_symbol_valadoc_full_name (Vala.Symbol symbol) {
        if (symbol is Vala.CreationMethod && symbol.parent_symbol != null) {
            var builder = new StringBuilder ();
            builder.append_printf ("%s.%s", symbol.parent_symbol.get_full_name (), symbol.parent_symbol.name);
            if (symbol.name != ".new")
                builder.append_printf (".%s", symbol.name);
            return builder.str;
        } else {
            return symbol.get_full_name ();
        }
    }

    /**
     * Renders a GTK-Doc formatted comment into Markdown, after it has already
     * been processed.
     *
     * see [[https://developer.gnome.org/gtk-doc-manual/stable/documenting_syntax.html.en]]
     */
    public string render_gtk_doc_content (string content, Vala.Comment comment, Compilation compilation) throws GLib.RegexError {
        string comment_data = content.dup();  // FIXME: workaround for valac codegen bug

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
            comment_data = /!\[(.*?)\]\(([~:\/\\\w\-.]+)\)/
                .replace_eval (comment_data, comment_data.length, 0, 0, (match_info, result) => {
                    string link_label = match_info.fetch (1) ?? "";
                    string link_href = match_info.fetch (2) ?? "";

                    result.append ("![");
                    result.append (link_label);
                    result.append ("](");
                    if (link_href.length > 0 && !Path.is_absolute (link_href))
                        link_href = Path.build_filename (gtkdoc_dir, link_href);
                    result.append (link_href);
                    result.append_c (')');
                    return false;
                });
        }

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
        comment_data = /\[(.*?)\]\[([\w\-\s]+)\]/
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
                } else if (gtkdoc_dir != null) {
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
                } else {
                    result.append (link_label);
                }

                return false;
            });

        // substitute references to C names with their Vala symbol names
        comment_data = /[#%]([A-Za-z_]\w+)(?:([:]{0,2})([A-Za-z_][A-Za-z_\-]+))?|([A-Za-z_]\w+)\(\)|`([A-Za-z_]\w+)`/
            .replace_eval (comment_data, comment_data.length, 0, 0, (match_info, result) => {
                string? group1 = match_info.fetch (1);
                string? member = match_info.fetch (3);
                string? group4 = match_info.fetch (4);
                string? group5 = match_info.fetch (5);
                string c_symbol = group1 != null && group1.length > 0 ? group1 : (group4 != null && group4.length > 0 ? group4 : group5);
                bool is_method = group4 != null && group4.length > 0;
                bool is_plural = false;
                bool member_is_signal = match_info.fetch (2) == "::";

                Vala.Symbol? vala_symbol = compilation.cname_to_sym[c_symbol];
                if (vala_symbol == null && !is_method && c_symbol.has_suffix ("s")) {
                    vala_symbol = compilation.cname_to_sym[c_symbol.substring (0, c_symbol.length-1)];
                    if (vala_symbol != null)
                        is_plural = true;
                }

                Vala.Symbol? vala_member = null;
                if (vala_symbol != null && member != null && member.length > 0) {
                    vala_member = vala_symbol.scope.lookup (member);
                }

                if (c_symbol.down() == "null" || c_symbol.down() == "true" || c_symbol.down() == "false") {
                    result.append ("**");
                    result.append (c_symbol.down ());
                    result.append ("**");
                } else if (vala_symbol != null) {
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
                    string? package_name = null;
                    string full_name;
                    if (vala_member != null) {
                        sym_sb.append_c ('.');
                        sym_sb.append (vala_member.name);
                        if (vala_member.source_reference != null)
                            package_name = vala_member.source_reference.file.package_name;
                        full_name = get_symbol_valadoc_full_name (vala_member);
                    } else {
                        if (vala_symbol.source_reference != null)
                            package_name = vala_symbol.source_reference.file.package_name;
                        full_name = get_symbol_valadoc_full_name (vala_symbol);
                    }
                    if (package_name != null)
                        result.append_c ('[');
                    result.append ("**");
                    result.append (sym_sb.str);
                    if (is_method || member_is_signal) {
                        result.append ("()");
                    } else if (vala_member != null) {
                        var property = vala_member as Vala.Property;
                        if (property != null) {
                            result.append (" {");
                            if (property.get_accessor != null)
                                result.append (" get; ");
                            if (property.set_accessor != null)
                                result.append (" set; ");
                            result.append_c ('}');
                        }
                    }
                    result.append ("**");
                    if (package_name != null) {
                        result.append ("](");
                        result.append ("https://valadoc.org/");
                        result.append (package_name);
                        result.append_c ('/');
                        result.append (full_name);
                        result.append (".html");
                        result.append_c (')');
                    }
                    if (is_plural)
                        result.append_c ('s');
                } else {
                    // debug ("C symbol does not match anything: %s", c_symbol);
                    result.append ((!) match_info.fetch (0));
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
                    string? package_name = null;
                    if (method_sym.source_reference != null)
                        package_name = method_sym.source_reference.file.package_name;
                    if (package_name != null)
                        result.append_c ('[');
                    result.append ("**");
                    result.append (method_sym.get_full_name ());
                    result.append (parens);
                    result.append ("**");
                    if (package_name != null) {
                        result.append ("](");
                        result.append ("https://valadoc.org/");
                        result.append (package_name);
                        result.append_c ('/');
                        result.append (get_symbol_valadoc_full_name (method_sym));
                        result.append (".html");
                        result.append_c (')');
                    }
                } else {
                    result.append ((!) match_info.fetch (0));
                }

                return false;
            });
        
        // highlight references to parameters and other symbols
        comment_data = /(?<=\s|^|(?<!\w)\W)@([A-Za-z_]\w*)(?=\s|$|[^a-zA-Z0-9_.]|\.(?!\w))/
            .replace_eval (comment_data, comment_data.length, 0, 0, (match_info, result) => {
                string c_symbol = match_info.fetch (1);
                Vala.Symbol? sym = compilation.cname_to_sym[c_symbol];

                if (sym != null) {
                    string? package_name = null;
                    if (sym.source_reference != null)
                        package_name = sym.source_reference.file.package_name;
                    if (package_name != null)
                        result.append_c ('[');
                    result.append ("**");
                    result.append (sym.get_full_name ());
                    result.append ("**");
                    if (package_name != null) {
                        result.append ("](");
                        result.append ("https://valadoc.org/");
                        result.append (package_name);
                        result.append_c ('/');
                        result.append (get_symbol_valadoc_full_name (sym));
                        result.append (".html");
                        result.append_c (')');
                    }
                } else {
                    result.append_c ('`');
                    result.append (c_symbol);
                    result.append_c ('`');
                }
                return false;
            });

        return comment_data;
    }

    /**
     * Renders a GTK-Doc formatted comment into Markdown.
     *
     * see [[https://developer.gnome.org/gtk-doc-manual/stable/documenting_syntax.html.en]]
     */
    public string render_gtk_doc_comment (Vala.Comment comment, Compilation compilation) throws GLib.RegexError {
        return render_gtk_doc_content (comment.content, comment, compilation);
    }

    /**
     * Find the GIR symbol related to @sym
     */
    public Vala.Symbol? find_gir_symbol (Vala.Symbol sym) {
        var found_sym = SymbolReferences.find_matching_symbol (context, sym);

        // fallback to C name
        if (found_sym == null) {
            string cname = CodeHelp.get_symbol_cname (sym);
            // debug ("could not find matching symbol, looking up C name %s for %s", cname, sym.to_string ());
            found_sym = cname_to_sym[cname];
        }

        return found_sym;
    }
}
