using LanguageServer;

struct CompileCommand {
    string path;
    string directory;
    string command;
}

class Vls.TextDocument : Object {
    public Vala.SourceFile file { get; construct; }
    public string uri { get; construct; }
    public int version { get; construct set; }

    public TextDocument (Vala.SourceFile file, string uri, int version = 0) {
        Object (file: file, uri: uri, version: version);
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

    void initialize (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var dict = new VariantDict (@params);

        int64 pid;
        dict.lookup ("processId", "x", out pid);

        string root_path;
        dict.lookup ("rootPath", "s", out root_path);

        client.reply (id, buildDict(
            capabilities: buildDict (
                textDocumentSync: new Variant.int16 (TextDocumentSyncKind.Full)
            )
        ));
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
        } while (r == null && p != "/");
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

        var type = Vala.SourceFileType.NONE;
        if (uri.has_suffix (".vala"))
            type = Vala.SourceFileType.SOURCE;
        else if (uri.has_suffix (".vapi"))
            type = Vala.SourceFileType.PACKAGE;
        var filename = Filename.from_uri (uri);

        string ccjson = findCompileCommands (filename);
        if (ccjson != null) {
            var parser = new Json.Parser.immutable_new ();
            try {
                parser.load_from_file (ccjson);
                var node = parser.get_root ().get_array ();
                node.foreach_element ((arr, index, node) => {
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

        // Vala.CodeContext.push (ctx);
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

        var source = new Vala.SourceFile (ctx.code_context, type, filename, fileContents);
        var doc = new TextDocument (source, uri);
        ctx.add_source_file (doc);

        // this.check ();
        // Vala.CodeContext.pop ();
        publishDiagnostics (client, doc);
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
        publishDiagnostics (client, source);
    }

    void publishDiagnostics (Jsonrpc.Client client, TextDocument document) {
        var source = document.file;
        ctx.invalidate ();
        Vala.CodeContext.push (ctx.code_context);
        this.check ();
        Vala.CodeContext.pop ();

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

            var result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
            client.send_notification ("textDocument/publishDiagnostics", buildDict(
                uri: new Variant.string (uri),
                diagnostics: result
            ));

            log.printf (@"textDocument/publishDiagnostics: $uri\n");
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
        client.reply (id, buildDict());
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
