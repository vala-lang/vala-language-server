using LanguageServer;
using Gee;

class Meson.TargetSource : Object {
    public string language { get; set; }
    public string[] compiler { get; set; }
    public string[] parameters { get; set; }
    public string[] sources { get; set; }
}

// currently unused
class Meson.Target : Object {
    public string name { get; set; }
    public string id { get; set; }
    public string defined_in { get; set; }
    public string[] filename { get; set; }
    public bool build_by_default { get; set; }
}

class Vls.TextDocument : Object {
    private Context ctx;
    private string filename;

    public Vala.SourceFile file;
    public string uri;
    public int version;

    public TextDocument (Context ctx, 
                         string filename, 
                         string? content = null,
                         int version = 0) throws ConvertError, FileError {

        if (!FileUtils.test (filename, FileTest.EXISTS)) {
            throw new FileError.NOENT ("file %s does not exist".printf (filename));
        }

        this.uri = Filename.to_uri (filename);
        this.filename = filename;
        this.version = version;
        this.ctx = ctx;

        var type = Vala.SourceFileType.NONE;
        if (uri.has_suffix (".vala") || uri.has_suffix (".gs"))
            type = Vala.SourceFileType.SOURCE;
        else if (uri.has_suffix (".vapi"))
            type = Vala.SourceFileType.PACKAGE;


        file = new Vala.SourceFile (ctx.code_context, type, filename, content);
        if (type == Vala.SourceFileType.SOURCE) {
            var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, "GLib", null));
            file.add_using_directive (ns_ref);
            ctx.add_using ("GLib");
        }
    }
}

class Vls.Server {
    Jsonrpc.Server server;
    MainLoop loop;
    HashTable<string, string> cc;
    Context ctx;
    HashTable<string, NotificationHandler> notif_handlers;
    HashTable<string, CallHandler> call_handlers;

    [CCode (has_target = false)]
    delegate void NotificationHandler (Vls.Server self, Jsonrpc.Client client, Variant @params);

    [CCode (has_target = false)]
    delegate void CallHandler (Vls.Server self, Jsonrpc.Server server, Jsonrpc.Client client, string method, Variant id, Variant @params);

    private void log_handler (string? log_domain, LogLevelFlags log_levels, string message) {
        stderr.printf ("%s: %s\n", log_domain == null ? "vls" : log_domain, message);
    }

    public Server (MainLoop loop) {
        // capture logging
        Log.set_handler (null, LogLevelFlags.LEVEL_MASK, log_handler);
        Log.set_handler ("jsonrpc-server", LogLevelFlags.LEVEL_MASK, log_handler);

        this.loop = loop;

        this.cc = new HashTable<string, string> (str_hash, str_equal);

        Timeout.add (10000, () => {
            debug (@"listening...");
            return true;
        });

        // libvala setup
        this.ctx = new Vls.Context ();

        this.server = new Jsonrpc.Server ();

        // hack to prevent other things from corrupting JSON-RPC pipe:
        // create a new handle to stdout, and close the old one (or move it to stderr)
        var new_stdout_fd = Posix.dup(Posix.STDOUT_FILENO);
        Posix.close(Posix.STDOUT_FILENO);
        Posix.dup2(Posix.STDERR_FILENO, Posix.STDOUT_FILENO);

        var stdin = new UnixInputStream (Posix.STDIN_FILENO, false);
        var stdout = new UnixOutputStream (new_stdout_fd, false);

        // set nonblocking
        try {
            if (!Unix.set_fd_nonblocking (Posix.STDIN_FILENO, true)
             || !Unix.set_fd_nonblocking (new_stdout_fd, true))
             error ("could not set pipes to nonblocking.\n");
        } catch (Error e) {
            debug ("failed to set FDs to nonblocking");
            loop.quit ();
            return;
        }

        // disable SIGPIPE?
        // Process.@signal (ProcessSignal.PIPE, signum => {} );


        server.accept_io_stream (new SimpleIOStream (stdin, stdout));

        notif_handlers = new HashTable <string, NotificationHandler> (str_hash, str_equal);
        call_handlers = new HashTable <string, CallHandler> (str_hash, str_equal);

        server.notification.connect ((client, method, @params) => {
            debug (@"Got notification! $method");
            if (notif_handlers.contains (method))
                ((NotificationHandler) notif_handlers[method]) (this, client, @params);
            else
                debug (@"no notification handler for $method");
        });

        server.handle_call.connect ((client, method, id, @params) => {
            debug (@"Got call! $method");
            if (call_handlers.contains (method)) {
                ((CallHandler) call_handlers[method]) (this, server, client, method, id, @params);
                return true;
            } else {
                debug (@"no call handler for $method");
                return false;
            }
        });

        call_handlers["initialize"] = this.initialize;
        call_handlers["shutdown"] = this.shutdown;
        notif_handlers["exit"] = this.exit;

        call_handlers["textDocument/definition"] = this.textDocumentDefinition;
        notif_handlers["textDocument/didOpen"] = this.textDocumentDidOpen;
        notif_handlers["textDocument/didChange"] = this.textDocumentDidChange;
        call_handlers["textDocument/documentSymbol"] = this.textDocumentDocumentSymbol;

        debug ("Finished constructing");
    }

    // a{sv} only
    Variant buildDict (...) {
        var builder = new VariantBuilder (new VariantType ("a{sv}"));
        var l = va_list ();
        while (true) {
            string? key = l.arg ();
            if (key == null) {
                break;
            }
            Variant val = l.arg ();
            builder.add ("{sv}", key, val);
        }
        return builder.end ();
    }

    void showMessage (Jsonrpc.Client client, string message, MessageType type) {
        try {
            client.send_notification ("window/showMessage", buildDict(
                type: new Variant.int16 (type),
                message: new Variant.string (message)
            ));
        } catch (Error e) {
            GLib.debug (@"showMessage: failed to notify client: $(e.message)");
        }
    }

    bool is_source_file (string filename) {
        return filename.has_suffix (".vapi") || filename.has_suffix (".vala")
            || filename.has_suffix (".gs");
    }

//    bool is_c_source_file (string filename) {
//        return filename.has_suffix (".c") || filename.has_suffix (".h");
//    }

    void meson_analyze_build_dir (Jsonrpc.Client client, string rootdir, string builddir) {
        string[] spawn_args = {"meson", "introspect", builddir, "--targets"};
        string[]? spawn_env = null; // Environ.get ();
        string proc_stdout;
        string proc_stderr;
        int proc_status;

        debug (@"analyzing build directory $rootdir ...");
        try {
            Process.spawn_sync (rootdir, 
                spawn_args, spawn_env,
                SpawnFlags.SEARCH_PATH,
                null,
                out proc_stdout,
                out proc_stderr,
                out proc_status
            );
        } catch (SpawnError e) {
            showMessage (client, @"Failed to spawn $(spawn_args[0]): $(e.message)", MessageType.Error);
            debug (@"failed to spawn process: $(e.message)");
            return;
        }

        if (proc_status != 0) {
            showMessage (client, 
                @"Failed to analyze build dir: meson terminated with error code $proc_status. Output:\n $proc_stderr", 
                MessageType.Error);
            debug (@"failed to analyze build dir: meson terminated with error code $proc_status. Output:\n $proc_stderr");
            return;
        }

        // we should have a list of targets in JSON format
        string targets_json = proc_stdout;
        var targets_parser = new Json.Parser.immutable_new ();
        try {
            targets_parser.load_from_data (targets_json);
        } catch (Error e) {
            debug (@"failed to load targets for build dir $(builddir): $(e.message)");
            return;
        }

        // for every target, get all target_files
        targets_parser.get_root ().get_array().foreach_element ((_1, _2, node) => {
            var target_obj = node.get_object ();
            Json.Node target_sources_array = target_obj.get_member ("target_sources");
            if (target_sources_array == null)
                return;
            target_sources_array.get_array ().foreach_element ((_1, _2, node) => {
                var target_source = Json.gobject_deserialize (typeof (Meson.TargetSource), node) as Meson.TargetSource;
                if (target_source.language != "vala") return;

                // get all packages
                for (int i=0; i<target_source.parameters.length; i++) {
                    string param = target_source.parameters[i];
                    if (param.index_of ("--pkg") == 0) {
                        if (param == "--pkg") {
                            if (i+1 < target_source.parameters.length) {
                                // the next argument is the package name
                                ctx.add_package (target_source.parameters[i+1]);
                                i++;
                            }
                        } else {
                            int idx = param.index_of ("=");
                            if (idx != -1) {
                                // --pkg={package}
                                ctx.add_package (param.substring (idx + 1));
                            }
                        }
                    }
                }

                // get all source files
                foreach (string source in target_source.sources) {
                    if (!Path.is_absolute (source))
                        source = Path.build_filename (builddir, source);
                    try {
                        ctx.add_source_file (new TextDocument (ctx, source));
                        debug (@"Adding text document: $source");
                    } catch (Error e) {
                        debug (@"Failed to create text document: $(e.message)");
                    }
                }
            });
        });
    }

    bool cc_analyze (string root_dir) {
        debug ("looking for compile_commands.json in %s", root_dir);
        string ccjson = findCompileCommands (root_dir);
        if (ccjson != null) {
            debug ("found at %s", ccjson);
            var parser = new Json.Parser.immutable_new ();
            try {
                parser.load_from_file (ccjson);
                var ccnode = parser.get_root ().get_array ();
                ccnode.foreach_element ((arr, index, node) => {
                    var o = node.get_object ();
                    string dir = o.get_string_member ("directory");
                    string file = o.get_string_member ("file");
                    string path = File.new_for_path (Path.build_filename (dir, file)).get_path ();
                    string cmd = o.get_string_member ("command");
                    debug ("got args for %s", path);
                    cc.insert (path, cmd);
                });
            } catch (Error e) {
                debug ("failed to parse %s: %s", ccjson, e.message);
                return false;
            }
        } else
            return false;

        // analyze compile_commands.json
        foreach (string filename in ctx.get_filenames ()) {
            debug ("analyzing args for %s", filename);
            string command = cc[filename];
            if (command != null) {
                MatchInfo minfo;
                if (/--pkg[= ](\S+)/.match (command, 0, out minfo)) {
                    try {
                        do {
                            ctx.add_package (minfo.fetch (1));
                            debug (@"adding package $(minfo.fetch (1))");
                        } while (minfo.next ());
                    } catch (Error e) {
                        debug (@"regex match error: $(e.message)");
                    }
                }

                if (/--vapidir[= ](\S+)/.match (command, 0, out minfo)) {
                    try {
                        do {
                            ctx.add_vapidir (minfo.fetch (1));
                            debug (@"adding package $(minfo.fetch (1))");
                        } while (minfo.next ());
                    } catch (Error e) {
                        debug (@"regex match error: $(e.message)");
                    }
                }
            }
        }

        return true;
    }

    void add_vala_files (File dir) throws Error {
        var enumerator = dir.enumerate_children ("standard::*", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        FileInfo info;

        try {
            while ((info = enumerator.next_file (null)) != null) {
                if (info.get_file_type () == FileType.DIRECTORY)
                    add_vala_files (enumerator.get_child (info));
                else {
                    var file = enumerator.get_child (info);
                    string fname = file.get_path ();
                    if (is_source_file (fname)) {
                        try {
                            var doc = new TextDocument (ctx, fname);
                            ctx.add_source_file (doc);
                            debug (@"Adding text document: $fname");
                        } catch (Error e) {
                            debug (@"Failed to create text document: $(e.message)");
                        }
                    }
                }
            }
        } catch (Error e) {
            debug (@"Error adding files: $(e.message)");
        }
    }

    void default_analyze_build_dir (Jsonrpc.Client client, string root_dir) {
        try {
            add_vala_files (File.new_for_path (root_dir));
        } catch (Error e) {
            debug (@"Error adding files $(e.message)n");
        }
    }

    void initialize (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var dict = new VariantDict (@params);

        string? root_path;
        dict.lookup ("rootPath", "s", out root_path);
        if (root_path != null)
            debug (@"Root path is $root_path");

        string? meson = findFile (root_path, "meson.build");
        if (meson != null) {
            string? ninja = findFile (root_path, "build.ninja");

            if (ninja == null) {
                // TODO: build again
                // ninja = findFile (root_path, "build.ninja");
            }
            
            // test again
            if (ninja != null) {
                debug ("Found meson project: %s\nninja: %s", meson, ninja);
                meson_analyze_build_dir (client, root_path, Path.get_dirname (ninja));
            } else {
                debug ("Found meson.build but not build.ninja: %s", meson);
            }
        } else {
            // this isn't a Meson project
            // 1. but do we have compiler_commands.json?
            if (!cc_analyze (root_path)) {
                debug ("No meson project and compile_commands found. Adding all Vala files in %s", root_path);
                default_analyze_build_dir (client, root_path);
            }
        }

        // compile everything ahead of time
        if (ctx.dirty) {
            ctx.check ();
        }

        try {
            client.reply (id, buildDict(
                capabilities: buildDict (
                    textDocumentSync: new Variant.int16 (TextDocumentSyncKind.Full),
                    definitionProvider: new Variant.boolean (true),
                    documentSymbolProvider: new Variant.boolean (true)
                )
            ));
        } catch (Error e) {
            debug (@"initialize: failed to reply to client: $(e.message)");
        }
    }

    // BFS for file
    string? findFile (string dirname, string target) {
        Dir dir = null;
        try {
            dir = Dir.open (dirname, 0);
        } catch (FileError e) {
            debug ("dirname=%s, target=%s, error=%s", dirname, target, e.message);
            return null;
        }

        string name;
        var dirs_to_search = new GLib.List<string>();
        while ((name = dir.read_name ()) != null) {
            string path = Path.build_filename (dirname, name);
            if (name == target)
                return path;

            if (FileUtils.test (path, FileTest.IS_DIR))
                dirs_to_search.append (path);
        }

        foreach (string path in dirs_to_search) {
            string r = findFile(path, target);
            if (r != null)
                return r;
        }
        return null;
    }

    string findCompileCommands (string filename) {
        string r = null, p = filename;
        do {
            r = findFile (p, "compile_commands.json");
            p = Path.get_dirname (p);
        } while (r == null && p != "/" && p != ".");
        return r;
    }

    T? parse_variant<T> (Variant variant) {
        var json = Json.gvariant_serialize(variant);
        return Json.gobject_deserialize(typeof(T), json);
    }

    Variant object_to_variant (Object object) throws Error {
        var json = Json.gobject_serialize (object);
        return Json.gvariant_deserialize (json, null);
    }

    public static size_t get_string_pos (string str, uint lineno, uint charno) {
        int linepos = -1;

        for (uint lno = 0; lno < lineno; ++lno) {
            int pos = str.index_of_char ('\n', linepos + 1);
            if (pos == -1)
                break;
            linepos = pos;
        }

        return linepos+1 + charno;
    }

    void textDocumentDidOpen (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);

        string uri          = (string) document.lookup_value ("uri",        VariantType.STRING);
        string languageId   = (string) document.lookup_value ("languageId", VariantType.STRING);
        string fileContents = (string) document.lookup_value ("text",       VariantType.STRING);

        if (languageId != "vala") {
            warning (@"$languageId file sent to vala language server");
            return;
        }

        string filename;
        try {
            filename = Filename.from_uri (uri);
        } catch (Error e) {
            debug (@"failed to convert URI $uri to filename: $(e.message)");
            return;
        }

        var file = File.new_for_uri (uri);
        foreach (string vapidir in ctx.code_context.vapi_directories) {
            if (file.get_path ().has_prefix (vapidir)) {
                debug ("%s is in vapidir %s. Not adding", filename, vapidir);
                return;
            }
        }
        if (file.get_path ().has_prefix ("/usr/share/vala")
         || file.get_path ().has_prefix ("/usr/share/vala-0.40")) { // TODO: don't hardcode these
            debug ("%s is in system vapidir. Not adding", filename);
            return;
        }


        if (ctx.get_source_file (uri) == null) {
            TextDocument doc;
            try {
                doc = new TextDocument (ctx, filename, fileContents);
            } catch (Error e) {
                debug (@"failed to create text document: $(e.message)");
                return;
            }

            debug ("adding source file %s", uri);
            ctx.add_source_file (doc);
        } else {
            debug ("updating contents of %s", uri);
            ctx.get_source_file (uri).file.content = fileContents;
        }

        // compile everything if context is dirty
        if (ctx.dirty) {
            ctx.check ();
        }

        publishDiagnostics (client);
    }

    void textDocumentDidChange (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        var changes = @params.lookup_value ("contentChanges", VariantType.ARRAY);

        var uri = (string) document.lookup_value ("uri", VariantType.STRING);
        var version = (int64) document.lookup_value ("version", VariantType.INT64);
        TextDocument? source = ctx.get_source_file (uri);

        if (source == null) {
            debug (@"no document found for $uri");
            return;
        }

        if (source.file.content == null) {
            char* ptr = source.file.get_mapped_contents ();

            if (ptr == null) {
                debug (@"$uri: get_mapped_contents() failed");
            }
            source.file.content = (string) ptr;

            if (source.file.content == null) {
                debug (@"$uri: content is NULL");
                return;
            }
        }

        if (source.version >= version) {
            debug (@"rejecting outdated version of $uri");
            return;
        }

        source.version = (int) version;

        var iter = changes.iterator ();
        Variant? elem = null;
        var sb = new StringBuilder (source.file.content);
        while ((elem = iter.next_value ()) != null) {
            var changeEvent = parse_variant<TextDocumentContentChangeEvent> (elem);

            if (changeEvent.range == null /* && changeEvent.rangeLength == 0*/) {
                sb.assign (changeEvent.text);
            } else {
                var start = changeEvent.range.start;
                size_t pos = get_string_pos (sb.str, start.line, start.character);
                sb.erase ((ssize_t) pos, changeEvent.rangeLength);
                sb.insert ((ssize_t) pos, changeEvent.text);
            }
        }
        source.file.content = sb.str;

        // if we're at this point, the file is present in the context
        // any change we make invalidates the context
        ctx.invalidate ();

        // we have to update everything
        ctx.check ();

        publishDiagnostics (client);
    }

    void publishDiagnostics (Jsonrpc.Client client, string? doc_uri = null) {
        Collection<TextDocument> docs;
        TextDocument? doc = doc_uri == null ? null : ctx.get_source_file (doc_uri);

        if (doc != null) {
            docs = new ArrayList<TextDocument>();
            docs.add (doc);
        } else {
            docs = ctx.get_source_files ();
        }

        foreach (var document in docs) {
            var source = document.file;
            string uri = document.uri;
            var array = new Json.Array ();

            ctx.report.errorlist.foreach (err => {
                if (err.loc != null) {
                    if (err.loc.file != source)
                        return;

                    var diag = new Diagnostic () {
                        range = new Range () {
                            start = new Position () {
                                line = err.loc.begin.line - 1,
                                character = err.loc.begin.column - 1
                            },
                            end = new Position () {
                                line = err.loc.end.line - 1,
                                character = err.loc.end.column
                            }
                        },
                        severity = DiagnosticSeverity.Error,
                        message = err.message
                    };

                    var node = Json.gobject_serialize (diag);
                    array.add_element (node);
                } else
                    array.add_element (Json.gobject_serialize (new Diagnostic() {
                        severity = DiagnosticSeverity.Error,
                        message = err.message
                    }));
            });

            ctx.report.warnlist.foreach (err => {
                if (err.loc != null) {
                    if (err.loc.file != source)
                        return;

                    var diag = new Diagnostic () {
                        range = new Range () {
                            start = new Position () {
                                line = err.loc.begin.line - 1,
                                character = err.loc.begin.column - 1
                            },
                            end = new Position () {
                                line = err.loc.end.line - 1,
                                character = err.loc.end.column
                            }
                        },
                        severity = DiagnosticSeverity.Warning,
                        message = err.message
                    };

                    var node = Json.gobject_serialize (diag);
                    array.add_element (node);
                } else
                    array.add_element (Json.gobject_serialize (new Diagnostic() {
                        severity = DiagnosticSeverity.Warning,
                        message = err.message
                    }));
            });

            Variant result;
            try {
                result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
            } catch (Error e) {
                debug (@"failed to create diagnostics: $(e.message)");
                continue;
            }

            try {
                client.send_notification ("textDocument/publishDiagnostics", buildDict(
                    uri: new Variant.string (uri),
                    diagnostics: result
                ));
            } catch (Error e) {
                debug (@"publishDiagnostics: failed to notify client: $(e.message)");
                continue;
            }

            debug (@"textDocument/publishDiagnostics: $uri");
        }
    }

    void textDocumentDefinition (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = parse_variant <LanguageServer.TextDocumentPositionParams> (@params);
        debug ("get definition in %s at %u,%u", p.textDocument.uri,
            p.position.line, p.position.character);
        var sourcefile = ctx.get_source_file (p.textDocument.uri);
        if (sourcefile == null) {
            debug ("unknown file %s", p.textDocument.uri);
            try {
                client.reply (id, null);
            } catch (Error e) {
                debug("[textDocument/definition] failed to reply to client: %s", e.message);
            }
            return;
        }
        var file = sourcefile.file;
        var fs = new FindSymbol (file, p.position.to_libvala ());

        if (fs.result.size == 0) {
            try {
                client.reply (id, null);
            } catch (Error e) {
                debug("[textDocument/definition] failed to reply to client: %s", e.message);
            }
            return;
        }

        Vala.CodeNode best = null;

        foreach (var node in fs.result) {
            if (best == null) {
                best = node;
            } else if (best.source_reference.begin.column <= node.source_reference.begin.column &&
                       node.source_reference.end.column <= best.source_reference.end.column) {
                best = node;
            }
        }

        {
            assert (best != null);
            var sr = best.source_reference;
            var from = (long)Server.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
            var to = (long)Server.get_string_pos (file.content, sr.end.line-1, sr.end.column);
            string contents = file.content [from:to];
            debug ("Got node: %s @ %s = %s", best.type_name, sr.to_string(), contents);
        }

        if (best is Vala.Expression && !(best is Vala.Literal)) {
            var b = (Vala.Expression)best;
            debug ("best (%p) is a Expression", best);
            if (b.symbol_reference != null && b.symbol_reference.source_reference != null) {
                best = b.symbol_reference;
                debug ("best is now the symbol_referenece => %p (%s)", best, best.to_string ());
            }
        } else {
            try {
                client.reply (id, null);
            } catch (Error e) {
                debug("[textDocument/definition] failed to reply to client: %s", e.message);
            }
            return;
        }

        /*
        string uri = null;
        foreach (var sourcefile in ctx.code_context.get_source_files ()) {
            if (best.source_reference.file == sourcefile) {
                uri = "file://" + sourcefile.filename;
                break;
            }
        }
        if (uri == null) {
            debug ("error: couldn't find source file for %s", best.source_reference.file.filename);
            client.reply (id, null);
            return;
        }
        */

        debug (@"replying... $(best.source_reference.file.filename)");
        try {
            client.reply (id, object_to_variant (new LanguageServer.Location () {
                uri = "file://" + best.source_reference.file.filename,
                range = new Range () {
                    start = new Position () {
                        line = best.source_reference.begin.line - 1,
                        character = best.source_reference.begin.column - 1
                    },
                    end = new Position () {
                        line = best.source_reference.end.line - 1,
                        character = best.source_reference.end.column
                    }
                }
            }));
        } catch (Error e) {
            debug("[textDocument/definition] failed to reply to client: %s", e.message);
        }
    }

    void textDocumentDocumentSymbol (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = parse_variant<LanguageServer.DocumentSymbolParams> (@params);

        if (ctx.dirty)
            ctx.check ();

        var sourcefile = ctx.get_source_file (p.textDocument.uri);
        if (sourcefile == null) {
            debug ("unknown file %s", p.textDocument.uri);
            try {
                client.reply (id, null);
            } catch (Error e) {
                debug("[textDocument/documentSymbol] failed to reply to client: %s", e.message);
            }
            return;
        }

        var array = new Json.Array ();
        foreach (var entry in (new ListSymbols (sourcefile.file))) {
            var range = entry.key;
            var result = entry.value;

            debug(@"found $(result.symbol.name)");
            array.add_element (Json.gobject_serialize (new LanguageServer.SymbolInformation () {
                name = result.symbol.name,
                kind = result.symbol_kind,
                location = new LanguageServer.Location() {
                    uri = p.textDocument.uri,
                    range = range
                },
                containerName = result.container != null ? result.container.symbol.name : null
            }));
        }

        try {
            Variant result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
            client.reply (id, result);
        } catch (Error e) {
            debug (@"[textDocument/documentSymbol] failed to reply to client: $(e.message)");
        }
    }

    void shutdown (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        ctx.clear ();
        try {
            client.reply (id, buildDict(null));
        } catch (Error e) {
            debug (@"shutdown: failed to reply to client: $(e.message)");
        }
        debug ("shutting down...n");
    }

    void exit (Jsonrpc.Client client, Variant @params) {
        loop.quit ();
    }
}

void main () {
    var loop = new MainLoop ();
    new Vls.Server (loop);
    loop.run ();
}
