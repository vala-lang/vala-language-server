using LanguageServer;
using Gee;

struct CompileCommand {
    string path;
    string directory;
    string command;
}

class Vls.TextDocument : Object {
    private Context _ctx;
    private Vala.SourceFileType _type;
    private string _filename;

    private Vala.SourceFile? _file;
    public Vala.SourceFile file { 
        get {
            if (_ctx.dirty)
                _file.context = _ctx.code_context;
            return _file;
        }
    }

    public string uri { get; construct; }
    public int version { get; construct set; }

    public TextDocument (Context ctx, 
                         string filename, 
                         string? content = null,
                         int version = 0) throws ConvertError {
        Object (uri: Filename.to_uri (filename), version: version);
        _ctx = ctx;
        _type = Vala.SourceFileType.NONE;
        if (uri.has_suffix (".vala") || uri.has_suffix (".gs"))
            _type = Vala.SourceFileType.SOURCE;
        else if (uri.has_suffix (".vapi"))
            _type = Vala.SourceFileType.PACKAGE;
        _filename = filename;
        _file = new Vala.SourceFile (ctx.code_context, _type, _filename, content);
        if (_type == Vala.SourceFileType.SOURCE) {
            var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, "GLib", null));
            _file.add_using_directive (ns_ref);
            ctx.add_using ("GLib");
        }
    }
}

class Vls.Server {
    FileStream log;
    Jsonrpc.Server server;
    MainLoop loop;
    HashTable<string, CompileCommand?> cc;
    Context ctx;

    public Server (MainLoop loop) {
        this.loop = loop;

        this.cc = new HashTable<string, CompileCommand?> (str_hash, str_equal);

        // initialize logging
        log = FileStream.open (@"vls-$(new DateTime.now_local()).log", "a");
        Posix.dup2 (log.fileno (), Posix.STDERR_FILENO);
        Timeout.add (3000, () => {
            log.printf (@"$(new DateTime.now_local()): listening...\n");
            return log.flush() != Posix.FILE.EOF;
        });

        // libvala setup
        this.ctx = new Vls.Context ();

        this.server = new Jsonrpc.Server ();
        var stdin = new UnixInputStream (Posix.STDIN_FILENO, false);
        var stdout = new UnixOutputStream (Posix.STDOUT_FILENO, false);
        server.accept_io_stream (new SimpleIOStream (stdin, stdout));

        server.notification.connect ((client, method, @params) => {
            log.printf (@"Got notification! $method\n");
            if (method == "textDocument/didOpen")
                this.textDocumentDidOpen(client, @params);
            else if (method == "textDocument/didChange")
                this.textDocumentDidChange(client, @params);
            else if (method == "exit")
                this.exit (client, @params);
            else
                log.printf (@"no handler for $method\n");
        });

        server.add_handler ("initialize", this.initialize);
        server.add_handler ("shutdown", this.shutdown);

        log.printf ("Finished constructing\n");
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
            log.printf (@"showMessage: failed to notify client: $(e.message)\n");
        }
    }

    void meson_analyze_build_dir (Jsonrpc.Client client, string rootdir, string builddir) {
        string[] spawn_args = {"meson", "introspect", builddir, "--targets"};
        string[]? spawn_env = null; // Environ.get ();
        string proc_stdout;
        string proc_stderr;
        int proc_status;

        log.printf (@"analyzing build directory $rootdir ...\n");
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
            log.printf (@"failed to spawn process: $(e.message)\n");
            return;
        }

        if (proc_status != 0) {
            showMessage (client, 
                @"Failed to analyze build dir: meson terminated with error code $proc_status. Output:\n $proc_stderr", 
                MessageType.Error);
            log.printf (@"failed to analyze build dir: meson terminated with error code $proc_status. Output:\n $proc_stderr\n");
            return;
        }

        // we should have a list of targets in JSON format
        string targets_json = proc_stdout;
        var targets_parser = new Json.Parser.immutable_new ();
        try {
            targets_parser.load_from_data (targets_json);
        } catch (Error e) {
            log.printf (@"failed to load targets for build dir $(builddir): $(e.message)\n");
            return;
        }

        // for every target, get all files
        var node = targets_parser.get_root ().get_array ();
        node.foreach_element ((arr, index, node) => {
            var o = node.get_object ();
            string id = o.get_string_member ("id");
            string fname = o.get_string_member ("filename");
            string[] args = {"meson", "introspect", builddir, "--target-files", id};

            if (fname.has_suffix (".vapi")) {
                if (!Path.is_absolute (fname)) {
                    fname = Path.build_path (Path.DIR_SEPARATOR_S, builddir, fname);
                }
                try {
                    var doc = new TextDocument (ctx, fname);
                    ctx.add_source_file (doc);
                    log.printf (@"Adding text document: $fname\n");
                } catch (Error e) {
                    log.printf (@"Failed to create text document: $(e.message)\n");
                }
            }
            
            try {
                Process.spawn_sync (rootdir, 
                    args, spawn_env,
                    SpawnFlags.SEARCH_PATH,
                    null,
                    out proc_stdout,
                    out proc_stderr,
                    out proc_status
                );
            } catch (SpawnError e) {
                log.printf (@"Failed to analyze target $id: $(e.message)\n");
                return;
            }

            // proc_stdout is a collection of files
            // add all source files to the project
            string files_json = proc_stdout;
            var files_parser = new Json.Parser.immutable_new ();
            try {
                files_parser.load_from_data (files_json);
            } catch (Error e) {
                log.printf (@"failed to get target files for $id (ID): $(e.message)\n");
                return;
            }
            var fnode = files_parser.get_root ().get_array ();
            fnode.foreach_element ((arr, index, node) => {
                var filename = node.get_string ();
                if (!Path.is_absolute (filename)) {
                    filename = Path.build_path (Path.DIR_SEPARATOR_S, rootdir, filename);
                }
                try {
                    var doc = new TextDocument (ctx, filename);
                    ctx.add_source_file (doc);
                    log.printf (@"Adding text document: $filename\n");
                } catch (Error e) {
                    log.printf (@"Failed to create text document: $(e.message)\n");
                }
            });
        });

        // get all dependencies
        spawn_args = {"meson", "introspect", builddir, "--dependencies"};
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
            showMessage (client, e.message, MessageType.Error);
            log.printf (@"failed to spawn process: $(e.message)\n");
            return;
        }

        // we should have a list of dependencies in JSON format
        string deps_json = proc_stdout;
        var deps_parser = new Json.Parser.immutable_new ();
        try {
            deps_parser.load_from_data (deps_json);
        } catch (Error e) {
            log.printf (@"failed to load dependencies for build dir $(builddir): $(e.message)\n");
            return;
        }

        var deps_node = deps_parser.get_root ().get_array ();
        deps_node.foreach_element ((arr, index, node) => {
            var o = node.get_object ();
            var name = o.get_string_member ("name");
            ctx.add_package (name);
            log.printf (@"adding package $name\n");
        });
    }

    void cc_analyze () {
        // analyze compile_commands.json
        foreach (var doc in ctx.get_source_files ()) {
            string filename = doc.file.filename;
            string ccjson = findCompileCommands (filename);
            if (ccjson != null) {
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
                        log.printf ("got args for %s\n", path);
                        cc.insert (path, CompileCommand() {
                            path = path,
                            directory = dir,
                            command = cmd
                        });
                    });
                } catch (Error e) {
                    log.printf ("failed to parse %s: %s\n", ccjson, e.message);
                }
            }

            log.printf ("finding args for %s\n", filename);
            CompileCommand? command = cc[filename];
            if (command != null) {
                string[] args = command.command.split (" ");
                for (int i = 0; i < args.length; ++i) {
                    if (args[i] == "--pkg") {
                        log.printf ("%s, --pkg %s\n", filename, args[i+1]);
                        ctx.add_package (args[i+1]);
                        ++i;
                    }
                }
            }
        }
    }

    void initialize (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var dict = new VariantDict (@params);

        int64 pid;
        dict.lookup ("processId", "x", out pid);

        string? root_path;
        dict.lookup ("rootPath", "s", out root_path);

        string? meson = findFile (root_path, "meson.build");
        if (meson != null) {
            string? ninja = findFile (root_path, "build.ninja");

            if (ninja == null) {
                // TODO: build again
                // ninja = findFile (root_path, "build.ninja");
            }
            
            // test again
            if (ninja != null)
                meson_analyze_build_dir (client, root_path, Path.get_dirname (ninja));
        }

        cc_analyze ();

        // compile everything ahead of time
        if (ctx.dirty) {
            Vala.CodeContext.push (ctx.code_context);
            this.check ();
            Vala.CodeContext.pop ();
        }

        try {
            client.reply (id, buildDict(
                capabilities: buildDict (
                    textDocumentSync: new Variant.int16 (TextDocumentSyncKind.Full)
                )
            ));
        } catch (Error e) {
            log.printf (@"initialize: failed to reply to client: $(e.message)");
        }
    }

    string? findFile (string dirname, string target) {
        Dir dir = null;
        try {
            dir = Dir.open (dirname, 0);
        } catch (FileError e) {
            log.printf ("dirname=%s, target=%s, error=%s\n", dirname, target, e.message);
            return null;
        }

        string name;
        while ((name = dir.read_name ()) != null) {
            string path = Path.build_filename (dirname, name);
            if (name == target)
                return path;

            if (FileUtils.test (path, FileTest.IS_DIR)) {
                string r = findFile (path, target);
                if (r != null)
                    return r;
            }
        }
        return null;
    }

    string findCompileCommands (string filename) {
        string r = null, p = filename;
        do {
            p = Path.get_dirname (p);
            r = findFile (p, "compile_commands.json");
        } while (r == null && p != "/" && p != ".");
        return r;
    }

    T? parse_variant<T> (Variant variant) {
        var json = Json.gvariant_serialize(variant);
        return Json.gobject_deserialize(typeof(T), json);
    }

    size_t get_string_pos (string str, uint lineno, uint charno) {
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
            log.printf (@"failed to convert URI $uri to filename: $(e.message)\n");
            return;
        }

        TextDocument doc;
        try {
            doc = new TextDocument (ctx, filename, fileContents);
        } catch (Error e) {
            log.printf (@"failed to create text document: $(e.message)\n");
            return;
        }

        ctx.add_source_file (doc);

        // compile everything if context is dirty
        if (ctx.dirty) {
            Vala.CodeContext.push (ctx.code_context);
            this.check ();
            Vala.CodeContext.pop ();
        }

        publishDiagnostics (client, uri);
    }

    void textDocumentDidChange (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        var changes = @params.lookup_value ("contentChanges", VariantType.ARRAY);

        var uri = (string) document.lookup_value ("uri", VariantType.STRING);
        var version = (int) document.lookup_value ("version", VariantType.INT64);
        TextDocument? source = ctx.get_source_file (uri);

        if (source == null) {
            log.printf (@"no document found for $uri\n");
            return;
        }

        if (source.file.content == null) {
            char* ptr = source.file.get_mapped_contents ();

            if (ptr == null) {
                log.printf (@"$uri: get_mapped_contents() failed\n");
            }
            source.file.content = (string) ptr;

            if (source.file.content == null) {
                log.printf (@"$uri: content is NULL\n");
                return;
            }
        }

        if (source.version > version) {
            log.printf (@"rejecting outdated version of $uri\n");
            return;
        }

        source.version = version;

        var iter = changes.iterator ();
        Variant? elem = null;
        var sb = new StringBuilder (source.file.content);
        while ((elem = iter.next_value ()) != null) {
            var changeEvent = parse_variant<TextDocumentContentChangeEvent> (elem);

            if (changeEvent.range == null && changeEvent.rangeLength == null) {
                sb.assign (changeEvent.text);
            } else {
                var start = changeEvent.range.start;
                size_t pos = get_string_pos (sb.str, start.line, start.character);
                sb.overwrite (pos, changeEvent.text);
            }
        }
        source.file.content = sb.str;

        // if we're at this point, the file is present in the context
        // any change we make invalidates the context
        ctx.invalidate ();

        // we have to update everything
        Vala.CodeContext.push (ctx.code_context);
        this.check ();
        Vala.CodeContext.pop ();

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
            if (ctx.code_context.report.get_errors () + ctx.code_context.report.get_warnings () > 0) {
                var array = new Json.Array ();

                ((Vls.Reporter) ctx.code_context.report).errorlist.foreach (err => {
                    if (err.loc.file != source)
                        return;
                    var from = new Position (err.loc.begin.line-1, err.loc.begin.column-1);
                    var to = new Position (err.loc.end.line-1, err.loc.end.column);

                    var diag = new Diagnostic ();
                    diag.range = new Range (from, to);
                    diag.severity = DiagnosticSeverity.Error;
                    diag.message = err.message;

                    var node = Json.gobject_serialize (diag);
                    array.add_element (node);
                });

                ((Vls.Reporter) ctx.code_context.report).warnlist.foreach (err => {
                    if (err.loc.file != source)
                        return;
                    var from = new Position (err.loc.begin.line-1, err.loc.begin.column-1);
                    var to = new Position (err.loc.end.line-1, err.loc.end.column);

                    var diag = new Diagnostic ();
                    diag.range = new Range (from, to);
                    diag.severity = DiagnosticSeverity.Warning;
                    diag.message = err.message;

                    var node = Json.gobject_serialize (diag);
                    array.add_element (node);
                });

                Variant result;
                try {
                    result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
                } catch (Error e) {
                    log.printf (@"failed to create diagnostics: $(e.message)");
                    continue;
                }

                try {
                    client.send_notification ("textDocument/publishDiagnostics", buildDict(
                        uri: new Variant.string (uri),
                        diagnostics: result
                    ));
                } catch (Error e) {
                    log.printf (@"publishDiagnostics: failed to notify client: $(e.message)\n");
                    continue;
                }

                log.printf (@"textDocument/publishDiagnostics: $uri\n");
            }
        }
    }

    void check () {
        if (ctx.code_context.report.get_errors () > 0) {
            return;
        }

        var parser = new Vala.Parser ();
        parser.parse (ctx.code_context);

        if (ctx.code_context.report.get_errors () > 0) {
            return;
        }

        ctx.code_context.check ();
    }

    void shutdown (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        ctx.clear ();
        try {
            client.reply (id, buildDict(null));
        } catch (Error e) {
            log.printf (@"shutdown: failed to reply to client: $(e.message)\n");
        }
        log.printf ("shutting down...\n");
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
