using LanguageServer;
using Gee;

struct CompileCommand {
    string path;
    string directory;
    string command;
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
                         int version = 0) throws ConvertError {
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
    HashTable<string, CompileCommand?> cc;
    Context ctx;
    HashTable<string, NotificationHandler> notif_handlers;
    HashTable<string, CallHandler> call_handlers;

    [CCode (has_target = false)]
    delegate void NotificationHandler (Vls.Server self, Jsonrpc.Client client, Variant @params);

    [CCode (has_target = false)]
    delegate void CallHandler (Vls.Server self, Jsonrpc.Server server, Jsonrpc.Client client, string method, Variant id, Variant @params);

    public Server (MainLoop loop) {
        this.loop = loop;

        this.cc = new HashTable<string, CompileCommand?> (str_hash, str_equal);

        Timeout.add (10000, () => {
            message (@"listening...");
            return true;
        });

        // libvala setup
        this.ctx = new Vls.Context ();

        this.server = new Jsonrpc.Server ();
        var stdin = new UnixInputStream (Posix.STDIN_FILENO, false);
        var stdout = new UnixOutputStream (Posix.STDOUT_FILENO, false);
        server.accept_io_stream (new SimpleIOStream (stdin, stdout));

        notif_handlers = new HashTable <string, NotificationHandler> (str_hash, str_equal);
        call_handlers = new HashTable <string, CallHandler> (str_hash, str_equal);

        server.notification.connect ((client, method, @params) => {
            message (@"Got notification! $method");
            if (notif_handlers.contains (method))
                ((NotificationHandler) notif_handlers[method]) (this, client, @params);
            else
                message (@"no notification handler for $method");
        });

        server.handle_call.connect ((client, method, id, @params) => {
            message (@"Got call! $method");
            if (call_handlers.contains (method)) {
                ((CallHandler) call_handlers[method]) (this, server, client, method, id, @params);
                return true;
            } else {
                message (@"no call handler for $method");
                return false;
            }
        });

        call_handlers["initialize"] = this.initialize;
        call_handlers["shutdown"] = this.shutdown;
        notif_handlers["exit"] = this.exit;

        call_handlers["textDocument/definition"] = this.textDocumentDefinition;
        notif_handlers["textDocument/didOpen"] = this.textDocumentDidOpen;
        notif_handlers["textDocument/didChange"] = this.textDocumentDidChange;

        message ("Finished constructing");
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
            GLib.message (@"showMessage: failed to notify client: $(e.message)");
        }
    }

    bool is_source_file (string filename) {
        return filename.has_suffix (".vapi") || filename.has_suffix (".vala")
            || filename.has_suffix (".gs");
    }

    bool is_c_source_file (string filename) {
        return filename.has_suffix (".c") || filename.has_suffix (".h");
    }

    void meson_analyze_build_dir (Jsonrpc.Client client, string rootdir, string builddir) {
        string[] spawn_args = {"meson", "introspect", builddir, "--targets"};
        string[]? spawn_env = null; // Environ.get ();
        string proc_stdout;
        string proc_stderr;
        int proc_status;

        message (@"analyzing build directory $rootdir ...");
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
            message (@"failed to spawn process: $(e.message)");
            return;
        }

        if (proc_status != 0) {
            showMessage (client, 
                @"Failed to analyze build dir: meson terminated with error code $proc_status. Output:\n $proc_stderr", 
                MessageType.Error);
            message (@"failed to analyze build dir: meson terminated with error code $proc_status. Output:\n $proc_stderr");
            return;
        }

        // we should have a list of targets in JSON format
        string targets_json = proc_stdout;
        var targets_parser = new Json.Parser.immutable_new ();
        try {
            targets_parser.load_from_data (targets_json);
        } catch (Error e) {
            message (@"failed to load targets for build dir $(builddir): $(e.message)");
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
                    fname = Path.build_filename (builddir, fname);
                }
                try {
                    var doc = new TextDocument (ctx, fname);
                    ctx.add_source_file (doc);
                    message (@"Adding text document: $fname");
                } catch (Error e) {
                    message (@"Failed to create text document: $(e.message)");
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
                message (@"Failed to analyze target $id: $(e.message)");
                return;
            }

            // proc_stdout is a collection of files
            // add all source files to the project
            string files_json = proc_stdout;
            var files_parser = new Json.Parser.immutable_new ();
            try {
                files_parser.load_from_data (files_json);
            } catch (Error e) {
                message (@"failed to get target files for $id (ID): $(e.message)");
                return;
            }
            var fnode = files_parser.get_root ().get_array ();
            fnode.foreach_element ((arr, index, node) => {
                var filename = node.get_string ();
                if (!Path.is_absolute (filename)) {
                    filename = Path.build_filename (rootdir, filename);
                }
                if (is_source_file (filename)) {
                    try {
                        var doc = new TextDocument (ctx, filename);
                        ctx.add_source_file (doc);
                        message (@"Adding text document: $filename");
                    } catch (Error e) {
                        message (@"Failed to create text document: $(e.message)");
                    }
                } else if (is_c_source_file (filename)) {
                    try {
                        ctx.add_c_source_file (Filename.to_uri (filename));
                        message (@"Adding C source file: $filename");
                    } catch (Error e) {
                        message (@"Failed to add C source file: $(e.message)");
                    }
                } else {
                    message (@"Unknown file type: $filename");
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
            message (@"failed to spawn process: $(e.message)");
            return;
        }

        // we should have a list of dependencies in JSON format
        string deps_json = proc_stdout;
        var deps_parser = new Json.Parser.immutable_new ();
        try {
            deps_parser.load_from_data (deps_json);
        } catch (Error e) {
            message (@"failed to load dependencies for build dir $(builddir): $(e.message)");
            return;
        }

        var deps_node = deps_parser.get_root ().get_array ();
        deps_node.foreach_element ((arr, index, node) => {
            var o = node.get_object ();
            var name = o.get_string_member ("name");
            ctx.add_package (name);
            message (@"adding package $name");
        });
    }

    void cc_analyze (string root_dir) {
        message ("looking for compile_commands.json in %s", root_dir);
        string ccjson = findCompileCommands (root_dir);
        if (ccjson != null) {
            message ("found at %s", ccjson);
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
                    message ("got args for %s", path);
                    cc.insert (path, CompileCommand() {
                        path = path,
                        directory = dir,
                        command = cmd
                    });
                });
            } catch (Error e) {
                message ("failed to parse %s: %s", ccjson, e.message);
            }
        }

        // analyze compile_commands.json
        foreach (string filename in ctx.get_filenames ()) {
            message ("analyzing args for %s", filename);
            CompileCommand? command = cc[filename];
            if (command != null) {
                MatchInfo minfo;
                if (/--pkg[= ](\S+)/.match (command.command, 0, out minfo)) {
                    try {
                        do {
                            ctx.add_package (minfo.fetch (1));
                            message (@"adding package $(minfo.fetch (1))");
                        } while (minfo.next ());
                    } catch (Error e) {
                        message (@"regex match error: $(e.message)");
                    }
                }

                if (/--vapidir[= ](\S+)/.match (command.command, 0, out minfo)) {
                    try {
                        do {
                            ctx.add_vapidir (minfo.fetch (1));
                            message (@"adding package $(minfo.fetch (1))");
                        } while (minfo.next ());
                    } catch (Error e) {
                        message (@"regex match error: $(e.message)");
                    }
                }
            }
        }
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
                            message (@"Adding text document: $fname");
                        } catch (Error e) {
                            message (@"Failed to create text document: $(e.message)");
                        }
                    }
                }
            }
        } catch (Error e) {
            message (@"Error adding files: $(e.message)");
        }
    }

    void default_analyze_build_dir (Jsonrpc.Client client, string root_dir) {
        try {
            add_vala_files (File.new_for_path (root_dir));
        } catch (Error e) {
            message (@"Error adding files $(e.message)n");
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
            if (ninja != null) {
                message ("Found meson project: %s\nninja: %s", meson, ninja);
                meson_analyze_build_dir (client, root_path, Path.get_dirname (ninja));
            } else {
                message ("Found meson.build but not build.ninja: %s", meson);
            }
        } else {
            /* if this isn't a Meson project, we should 
             * just take every single file
             */
            message ("No meson project found. Adding all Vala files in %s", root_path);
            default_analyze_build_dir (client, root_path);
        }

        cc_analyze (root_path);

        // compile everything ahead of time
        if (ctx.dirty) {
            ctx.check ();
        }

        try {
            client.reply (id, buildDict(
                capabilities: buildDict (
                    textDocumentSync: new Variant.int16 (TextDocumentSyncKind.Full),
                    definitionProvider: new Variant.boolean (true)
                )
            ));
        } catch (Error e) {
            message (@"initialize: failed to reply to client: $(e.message)");
        }
    }

    string? findFile (string dirname, string target) {
        Dir dir = null;
        try {
            dir = Dir.open (dirname, 0);
        } catch (FileError e) {
            message ("dirname=%s, target=%s, error=%s", dirname, target, e.message);
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
            message (@"failed to convert URI $uri to filename: $(e.message)");
            return;
        }

        if (ctx.get_source_file (uri) == null) {
            TextDocument doc;
            try {
                doc = new TextDocument (ctx, filename, fileContents);
            } catch (Error e) {
                message (@"failed to create text document: $(e.message)");
                return;
            }

            message ("adding source file %s", uri);
            ctx.add_source_file (doc);
        } else {
            message ("updating contents of %s", uri);
            ctx.get_source_file (uri).file.content = fileContents;
        }

        // compile everything if context is dirty
        if (ctx.dirty) {
            ctx.check ();
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
            message (@"no document found for $uri");
            return;
        }

        if (source.file.content == null) {
            char* ptr = source.file.get_mapped_contents ();

            if (ptr == null) {
                message (@"$uri: get_mapped_contents() failed");
            }
            source.file.content = (string) ptr;

            if (source.file.content == null) {
                message (@"$uri: content is NULL");
                return;
            }
        }

        if (source.version > version) {
            message (@"rejecting outdated version of $uri");
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
            if (ctx.report.get_errors () + ctx.report.get_warnings () > 0) {
                var array = new Json.Array ();

                ctx.report.errorlist.foreach (err => {
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
                });

                ctx.report.warnlist.foreach (err => {
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
                });

                Variant result;
                try {
                    result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
                } catch (Error e) {
                    message (@"failed to create diagnostics: $(e.message)");
                    continue;
                }

                try {
                    client.send_notification ("textDocument/publishDiagnostics", buildDict(
                        uri: new Variant.string (uri),
                        diagnostics: result
                    ));
                } catch (Error e) {
                    message (@"publishDiagnostics: failed to notify client: $(e.message)");
                    continue;
                }

                message (@"textDocument/publishDiagnostics: $uri");
            }
        }
    }

    void textDocumentDefinition (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = parse_variant <LanguageServer.TextDocumentPositionParams> (@params);
        message ("get definition in %s at %u,%u", p.textDocument.uri,
            p.position.line, p.position.character);
        var file = ctx.get_source_file (p.textDocument.uri).file;
        var fs = new FindSymbol (file, p.position.to_libvala ());

        if (fs.result.size == 0) {
            client.reply (id, null);
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
            var sr = best.source_reference;
            var from = (long)Server.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
            var to = (long)Server.get_string_pos (file.content, sr.end.line-1, sr.end.column);
            string contents = file.content [from:to];
            message ("Got node: %s @ %s = %s", best.type_name, sr.to_string(), contents);
        }

        if (best is Vala.MemberAccess) {
            best = ((Vala.MemberAccess)best).symbol_reference;
        }

        string uri = null;
        foreach (var sourcefile in ctx.get_source_files ()) {
            if (best.source_reference.file == sourcefile.file) {
                uri = sourcefile.uri;
                break;
            }
        }
        if (uri == null) {
            message ("error: couldn't find source file for %s", best.source_reference.file.filename);
            client.reply (id, null);
            return;
        }

        message (@"replying... $(best.source_reference.file.filename)");
        client.reply (id, object_to_variant (new LanguageServer.Location () {
            uri = uri,
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
    }

    void shutdown (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        ctx.clear ();
        try {
            client.reply (id, buildDict(null));
        } catch (Error e) {
            message (@"shutdown: failed to reply to client: $(e.message)");
        }
        message ("shutting down...n");
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
