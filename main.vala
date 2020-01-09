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
    const uint check_update_context_period_ms = 400;
    const int64 update_context_delay_inc_us = check_update_context_period_ms * 1000;
    const int64 update_context_delay_max_us = 1000 * 1000;

    HashTable<string, NotificationHandler> notif_handlers;
    HashTable<string, CallHandler> call_handlers;
    InitializeParams init_params;

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
            debug ("listening...");
            return true;
        });

        // libvala setup
        this.ctx = new Vls.Context ();

        this.server = new Jsonrpc.Server ();

        // hack to prevent other things from corrupting JSON-RPC pipe:
        // create a new handle to stdout, and close the old one (or move it to stderr)
#if WINDOWS
        var new_stdout_fd = Windows._dup (Posix.STDOUT_FILENO);
        Windows._close (Posix.STDOUT_FILENO);
        Windows._dup2 (Posix.STDERR_FILENO, Posix.STDOUT_FILENO);
        void* new_stdin_handle = Windows._get_osfhandle (Posix.STDIN_FILENO);
        void* new_stdout_handle = Windows._get_osfhandle (new_stdout_fd);

        // we can't use the names 'stdin' or 'stdout' for these variables
        // since it causes build problems for mingw-w64-x86_64-gcc
        var input_stream = new Win32InputStream (new_stdin_handle, false);
        var output_stream = new Win32OutputStream (new_stdout_handle, false);
#else
        var new_stdout_fd = Posix.dup (Posix.STDOUT_FILENO);
        Posix.close (Posix.STDOUT_FILENO);
        Posix.dup2 (Posix.STDERR_FILENO, Posix.STDOUT_FILENO);

        var input_stream = new UnixInputStream (Posix.STDIN_FILENO, false);
        var output_stream = new UnixOutputStream (new_stdout_fd, false);

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
#endif

        // disable SIGPIPE?
        // Process.@signal (ProcessSignal.PIPE, signum => {} );


        server.accept_io_stream (new SimpleIOStream (input_stream, output_stream));

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
        call_handlers["textDocument/completion"] = this.textDocumentCompletion;
        call_handlers["textDocument/signatureHelp"] = this.textDocumentSignatureHelp;
        call_handlers["textDocument/hover"] = this.textDocumentHover;

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
            client.send_notification ("window/showMessage", buildDict (
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
        targets_parser.get_root ().get_array ().foreach_element ((_1, _2, node) => {
            var target_obj = node.get_object ();
            Json.Node target_sources_array = target_obj.get_member ("target_sources");
            if (target_sources_array == null)
                return;
            target_sources_array.get_array ().foreach_element ((_1, _2, node) => {
                var target_source = Json.gobject_deserialize (typeof (Meson.TargetSource), node) as Meson.TargetSource;
                if (target_source.language != "vala") return;

                // get all packages
                for (int i = 0; i < target_source.parameters.length; i++) {
                    string param = target_source.parameters[i];
                    if (param.index_of ("--pkg") == 0) {
                        if (param == "--pkg") {
                            if (i + 1 < target_source.parameters.length) {
                                // the next argument is the package name
                                ctx.add_package (target_source.parameters[i + 1]);
                                i++;
                            }
                        } else {
                            int idx = param.index_of ("=");
                            if (idx != -1) {
                                // --pkg={package}
                                ctx.add_package (param.substring (idx + 1));
                            }
                        }
                    } else if (param.index_of ("--vapidir") == 0) {
                        if (param == "--vapidir") {
                            if (i + 1 < target_source.parameters.length) {
                                ctx.add_vapidir (target_source.parameters[i + 1]);
                                i++;
                            }
                        } else {
                            int idx = param.index_of ("=");
                            if (idx != -1) {
                                // --vapidir={vapidir}
                                ctx.add_vapidir (param.substring (idx + 1));
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

    string? mesonConfigure (Jsonrpc.Client client, string mesonBuild) {
        string configDir;
        try {
            configDir = DirUtils.make_tmp ("vls-meson-XXXXXX");
        } catch (FileError e) {
            debug (@"error: $(e.message)");
            return null;
        }

        string[] spawn_args = {"meson", "setup", ".", Path.get_dirname (mesonBuild)};
        string[]? spawn_env = null; // Environ.get ();
        string proc_stdout;
        string proc_stderr;
        int proc_status;

        debug (@"Running meson for $mesonBuild in dir $configDir");

        try {
            Process.spawn_sync (configDir, spawn_args, spawn_env, SpawnFlags.SEARCH_PATH, null,
                                out proc_stdout, out proc_stderr, out proc_status);
        } catch (SpawnError e) {
            debug (@"error: $(e.message)");
            return null;
        }

        if (proc_status != 0) {
            showMessage (client,
                @"Failed to set up build dir: meson terminated with error code $proc_status. Output:\n$proc_stdout\n$proc_stderr",
                MessageType.Error);
            debug (@"failed to set up build dir: meson terminated with error code $proc_status. Output:\n$proc_stdout\n$proc_stderr");
            return null;
        }

        debug (@"meson exited with 0. stdout:\n$proc_stdout\n\nstderr:\n$proc_stderr");

        return configDir;
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
        init_params = parse_variant<InitializeParams> (@params);

        string root_path = init_params.rootPath != null ? init_params.rootPath : init_params.rootUri;
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
                string? configDir = mesonConfigure (client, meson);
                if (configDir != null) {
                    meson_analyze_build_dir (client, root_path, configDir);
                }
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
            client.reply (id, buildDict (
                capabilities: buildDict (
                    textDocumentSync: new Variant.int16 (TextDocumentSyncKind.Incremental),
                    definitionProvider: new Variant.boolean (true),
                    documentSymbolProvider: new Variant.boolean (true),
                    completionProvider: buildDict(
                        triggerCharacters: new Variant.strv (new string[] {".", ">"})
                    ),
                    signatureHelpProvider: buildDict(
                        triggerCharacters: new Variant.strv (new string[] {"(", ","})
                    ),
                    hoverProvider: new Variant.boolean (true)
                )
            ));
        } catch (Error e) {
            debug (@"initialize: failed to reply to client: $(e.message)");
        }

        // listen for context update requests
        Timeout.add(check_update_context_period_ms, () => {
            check_update_context ();
            return true;
        });
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
        var dirs_to_search = new GLib.List<string> ();
        while ((name = dir.read_name ()) != null) {
            string path = Path.build_filename (dirname, name);
            if (name == target)
                return path;

            if (FileUtils.test (path, FileTest.IS_DIR))
                dirs_to_search.append (path);
        }

        foreach (string path in dirs_to_search) {
            string r = findFile (path, target);
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
        var json = Json.gvariant_serialize (variant);
        return Json.gobject_deserialize (typeof (T), json);
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

        return linepos + 1 + charno;
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
            ctx.invalidate ();
        }

        request_context_update (client);
    }

    Jsonrpc.Client? update_context_client = null;
    int64 update_context_requests = 0;
    int64 update_context_time_us = 0;

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

        request_context_update (client);
    }

    void request_context_update (Jsonrpc.Client client) {
        update_context_client = client;
        update_context_requests += 1;
        int64 delay_us = int64.min (update_context_delay_inc_us * update_context_requests, update_context_delay_max_us);
        update_context_time_us = get_monotonic_time () + delay_us;
        debug (@"Context update (re-)scheduled in $((int) (delay_us / 1000)) ms");
    }

    void check_update_context () {
        if (update_context_requests > 0 && get_monotonic_time () >= update_context_time_us) {
            update_context_requests = 0;
            update_context_time_us = 0;
            ctx.invalidate ();
            ctx.check ();
            publishDiagnostics (update_context_client);
        }
    }

    void require_updated_context () {
        if (update_context_requests > 0) {
            update_context_requests = 0;
            update_context_time_us = 0;
            ctx.invalidate ();
            ctx.check ();
            publishDiagnostics (update_context_client);
        }
    }

    void publishDiagnostics (Jsonrpc.Client client, string? doc_uri = null) {
        Collection<TextDocument> docs;
        TextDocument? doc = doc_uri == null ? null : ctx.get_source_file (doc_uri);

        if (doc != null) {
            docs = new ArrayList<TextDocument> ();
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
                    array.add_element (Json.gobject_serialize (new Diagnostic () {
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
                    array.add_element (Json.gobject_serialize (new Diagnostic () {
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
                client.send_notification ("textDocument/publishDiagnostics", buildDict (
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

    Vala.CodeNode get_best (FindSymbol fs, Vala.SourceFile file) {
        Vala.CodeNode? best = null;

        foreach (var node in fs.result) {
            if (best == null) {
                best = node;
            } else if (best.source_reference.begin.column <= node.source_reference.begin.column &&
                       node.source_reference.end.column <= best.source_reference.end.column &&
                       // don't get implicit `this` accesses
                       !(best.source_reference.begin.column == node.source_reference.begin.column &&
                         node.source_reference.end.column == best.source_reference.end.column &&
                         node is Vala.MemberAccess && 
                         ((Vala.MemberAccess)node).member_name == "this" &&
                         ((Vala.MemberAccess)node).inner == null)) {
                best = node;
            }
        }

        assert (best != null);
        var sr = best.source_reference;
        var from = (long)Server.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
        var to = (long)Server.get_string_pos (file.content, sr.end.line-1, sr.end.column);
        string contents = file.content [from:to];
        debug ("Got best node: %s @ %s = %s", best.type_name, sr.to_string(), contents);

        return (!) best;
    }

    Vala.Scope get_current_scope (Vala.CodeNode code_node) {
        Vala.Scope? best = null;

        for (Vala.CodeNode? node = code_node; node != null; node = node.parent_node) {
            if (node is Vala.Symbol) {
                var sym = (Vala.Symbol) node;
                best = sym.scope;
                break;
            }
        }

        assert (best != null);

        return (!) best;
    }

    void textDocumentDefinition (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = parse_variant <LanguageServer.TextDocumentPositionParams> (@params);
        debug ("get definition in %s at %u,%u", p.textDocument.uri,
            p.position.line, p.position.character);
        var sourcefile = ctx.get_source_file (p.textDocument.uri);
        if (sourcefile == null) {
            debug ("unknown file %s", p.textDocument.uri);
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/definition] failed to reply to client: %s", e.message);
            }
            return;
        }
        var fs = new FindSymbol (sourcefile.file, p.position.to_libvala ());

        if (fs.result.size == 0) {
            debug ("no results :(");
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/definition] failed to reply to client: %s", e.message);
            }
            return;
        }

        Vala.CodeNode? best = get_best (fs, file);

        if (best is Vala.Expression && !(best is Vala.Literal)) { // expressions
            var b = (Vala.Expression)best;
            debug ("best (%s / %s @ %s) is a Expression", best.to_string (), best.type_name, best.source_reference.to_string ());
            if (b.symbol_reference != null && b.symbol_reference.source_reference != null) {
                best = b.symbol_reference;
                debug ("best is now the symbol_reference => %p (%s / %s @ %s)", best, best.type_name, best.to_string (), best.source_reference.to_string ());
            }
        } else if (best is Vala.DelegateType) {
            best = ((Vala.DelegateType)best).delegate_symbol;
        } else if (best is Vala.DataType) { // field types
            var dt = (Vala.DataType)best;
            debug ("[%s] is a DataType, using data_type: [%s] @ %s", best.to_string (), dt.data_type.type_name, dt.data_type.source_reference.to_string ());
            best = dt.data_type;
        } else { // return null
            debug ("best is a %s, returning null", best.type_name);
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/definition] failed to reply to client: %s", e.message);
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
            client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            return;
        }
        */

        if (best == null) {
            warning ("best == null");
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/definition] failed to reply to client: %s", e.message);
            }
            return;
        }

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
            debug ("[textDocument/definition] failed to reply to client: %s", e.message);
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
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/documentSymbol] failed to reply to client: %s", e.message);
            }
            return;
        }

        var array = new Json.Array ();
        var syms = new ListSymbols (sourcefile.file);
        if (init_params.capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport)
            foreach (var dsym in syms) {
                debug (@"found $(dsym.name)");
                array.add_element (Json.gobject_serialize (dsym));
            }
        else {
            foreach (var dsym in syms.flattened ()) {
                debug (@"found $(dsym.name)");
                array.add_element (Json.gobject_serialize (new SymbolInformation.from_document_symbol (dsym, p.textDocument.uri)));
            }
        }

        try {
            Variant result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
            client.reply (id, result);
        } catch (Error e) {
            debug (@"[textDocument/documentSymbol] failed to reply to client: $(e.message)");
        }
    }

    /**
     * Return the string representation of a symbol's type. This is used as the detailed
     * information for a completion item.
     */
    public static string? get_symbol_data_type (Vala.Symbol? sym, bool only_type_names = false, Vala.Symbol? parent = null) {
        if (sym == null) {
            return null;
        } else if (sym is Vala.Property) {
            var prop_sym = sym as Vala.Property;
            if (prop_sym.property_type == null)
                return null; 
            if (only_type_names)
                return prop_sym.property_type.to_string ();
            else {
                string? parent_str = get_symbol_data_type (parent, only_type_names);
                if (parent_str != null)
                    parent_str = @"$(parent_str)::";
                else
                    parent_str = "";
                return @"$(prop_sym.property_type) $parent_str$(prop_sym.name)";
            }
        } else if (sym is Vala.Callable) {
            var method_sym = sym as Vala.Callable;
            if (method_sym.return_type == null)
                return null;
            var creation_method = sym as Vala.CreationMethod;
            string? ret_type = method_sym.return_type.to_string ();
            string param_string = "";
            bool at_least_one = false;
            foreach (var p in method_sym.get_parameters ()) {
                if (at_least_one)
                    param_string += ", ";
                param_string += get_symbol_data_type (p, only_type_names);
                at_least_one = true;
            }
            if (only_type_names) {
                return @"($param_string) -> " + (ret_type ?? (creation_method != null ? creation_method.class_name : "void"));
            } else {
                string? parent_str = get_symbol_data_type (parent, only_type_names);
                if (creation_method == null) {
                    if (parent_str != null)
                        parent_str = @"$parent_str::";
                    else
                        parent_str = "";
                    return (ret_type ?? "void") + @" $parent_str$(sym.name) ($param_string)";
                } else {
                    string sym_name = sym.name == ".new" ? (parent_str ?? creation_method.class_name) : sym.name;
                    string prefix_str = "";
                    if (parent_str != null)
                        prefix_str = @"$parent_str::";
                    else
                        prefix_str = @"$(creation_method.class_name)::";
                    return @"$prefix_str$sym_name ($param_string)";
                }
            }
        } else if (sym is Vala.Parameter) {
            var p = sym as Vala.Parameter;
            string param_string = "";
            if (p.ellipsis)
                param_string = "...";
            else {
                if (p.direction == Vala.ParameterDirection.OUT)
                    param_string = "out ";
                else if (p.direction == Vala.ParameterDirection.REF)
                    param_string = "ref ";
                if (only_type_names)
                    param_string += p.variable_type.data_type.to_string ();
                else {
                    param_string += p.variable_type.to_string ();
                    param_string += " " + p.name;
                    if (p.initializer != null)
                        param_string += @" = $(p.initializer)";
                }
            }
            return param_string;
        } else if (sym is Vala.Variable) {
            // Vala.Parameter is also a variable, so we've already
            // handled it as a special case
            var var_sym = sym as Vala.Variable;
            if (var_sym.variable_type == null)
                return null;
            if (only_type_names)
                return var_sym.variable_type.to_string ();
            else {
                string? parent_str = get_symbol_data_type (parent, only_type_names);
                if (parent_str != null)
                    parent_str = @"$(parent_str)::";
                else
                    parent_str = "";
                return @"$(var_sym.variable_type) $parent_str$(var_sym.name)";
            }
        } else if (sym is Vala.Constant) {
            var const_sym = sym as Vala.Constant;
            string type_string = "";
            if (const_sym.value != null)
                type_string += const_sym.value.to_string ();
            if (const_sym.type_reference == null)
                return type_string;
            type_string = @"($(const_sym.type_reference)) $type_string";
            return type_string;
        } else if (sym is Vala.ObjectTypeSymbol) {
            var object_sym = sym as Vala.ObjectTypeSymbol;
            string type_string = object_sym.to_string ();
            bool at_least_one = false;

            foreach (var type_param in object_sym.get_type_parameters ()) {
                if (!at_least_one)
                    type_string += "<";
                else
                    type_string += ",";
                type_string += type_param.name;
                at_least_one = true;
            }

            if (at_least_one)
                type_string += ">";

            at_least_one = false;
            if (sym is Vala.Class) {
                var class_sym = sym as Vala.Class;
                at_least_one = false;
                foreach (var base_type in class_sym.get_base_types ()) {
                    if (!at_least_one)
                        type_string += ": ";
                    else
                        type_string += ", ";
                    type_string += base_type.to_string ();
                    at_least_one = true;
                }
            } else if (sym is Vala.Interface) {
                var iface_sym = sym as Vala.Interface;
                foreach (var prereq_type in iface_sym.get_prerequisites ()) {
                    if (!at_least_one)
                        type_string += ": ";
                    else
                        type_string += ", ";
                    type_string += prereq_type.to_string ();
                    at_least_one = true;
                }
            }
            if (object_sym is Vala.Class)
                return (only_type_names ? "" : "class ") + @"$type_string";
            else
                return (only_type_names ? "" : "interface ") + @"$type_string";
        } else if (sym is Vala.ErrorCode) {
            var err_val = (sym as Vala.ErrorCode).value;
            return err_val != null ? err_val.to_string () : null;
        } else if (sym is Vala.Struct) {
            var struct_sym = sym as Vala.Struct;
            string type_string = struct_sym.to_string ();
            bool at_least_one = false;

            foreach (var type_param in struct_sym.get_type_parameters ()) {
                if (!at_least_one)
                    type_string += "<";
                else
                    type_string += ",";
                type_string += type_param.name;
                at_least_one = true;
            }

            if (at_least_one)
                type_string += ">";

            if (struct_sym.base_type != null)
                type_string += ": " + struct_sym.base_type.to_string ();

            return (only_type_names ? "" : "struct ") + @"$type_string";
        } else if (sym is Vala.ErrorDomain) {
            // don't do this if LSP ever gets CompletionItemKind.Error
            var err_sym = sym as Vala.ErrorDomain;
            return @"errordomain $err_sym";
        } else if (sym is Vala.Namespace) {
            var ns_sym = sym as Vala.Namespace;
            return @"$ns_sym";
        } else {
            debug (@"get_symbol_data_type: unsupported symbol $(sym.type_name)");
        }
        return null;
    }

    public static LanguageServer.MarkupContent? get_symbol_comment (Vala.Symbol sym) {
        if (sym.comment == null)
            return null;
        string comment = sym.comment.content;
        try {
            comment = /^\s*\*(.*)/m.replace (comment, comment.length, 0, "\\1");
        } catch (RegexError e) {
            warning (@"failed to parse comment...\n$comment\n...");
            comment = "(failed to parse comment)";
        }

        return new MarkupContent () {
            kind = "markdown",
            value = comment
        };
    }

    /**
     * see `vala/valamemberaccess.vala`
     * This determines whether we can access a symbol in the current scope.
     */
    public static bool is_symbol_accessible (Vala.Symbol member, Vala.Scope current_scope) {
        if (member.access == Vala.SymbolAccessibility.PROTECTED && member.parent_symbol is Vala.TypeSymbol) {
            var target_type = (Vala.TypeSymbol) member.parent_symbol;
            bool in_subtype = false;

            for (Vala.Symbol? this_symbol = current_scope.owner; 
                 this_symbol != null;
                 this_symbol = this_symbol.parent_symbol) {
                if (this_symbol == target_type) {
                    in_subtype = true;
                    break;
                }

                var cl = this_symbol as Vala.Class;
                if (cl != null && cl.is_subtype_of (target_type)) {
                    in_subtype = true;
                    break;
                }
            }

            return in_subtype;
        } else if (member.access == Vala.SymbolAccessibility.PRIVATE) {
            var target_type = member.parent_symbol;
            bool in_target_type = false;

            for (Vala.Symbol? this_symbol = current_scope.owner;
                 this_symbol != null;
                 this_symbol = this_symbol.parent_symbol) {
                if (this_symbol == target_type) {
                    in_target_type = true;
                    break;
                }
            }

            return in_target_type;
        }
        return true;
    }

    /**
     * List all relevant members of a type. This is where completion options are generated.
     */
    void add_completions_for_type (Vala.TypeSymbol type, 
                                   Gee.Set<CompletionItem> completions, 
                                   Vala.Scope current_scope,
                                   bool is_instance,
                                   Gee.Set<string> seen_props = new Gee.HashSet<string> ()) {
        if (type is Vala.ObjectTypeSymbol) {
            /**
             * Complete the members of this object, such as the fields,
             * properties, and methods.
             */
            var object_type = type as Vala.ObjectTypeSymbol;

            debug (@"completion: type is object $(object_type.name)\n");

            foreach (var method_sym in object_type.get_methods ()) {
                if (method_sym.name == ".new" || method_sym.is_instance_member () != is_instance
                    || (method_sym is Vala.CreationMethod && is_instance)
                    || !is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method));
            }

            foreach (var signal_sym in object_type.get_signals ()) {
                if (signal_sym.is_instance_member () != is_instance 
                    || !is_symbol_accessible (signal_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (signal_sym, CompletionItemKind.Event));
            }

            foreach (var prop_sym in object_type.get_properties ()) {
                if (prop_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (prop_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (prop_sym, CompletionItemKind.Property));
                seen_props.add (prop_sym.name);
            }

            foreach (var field_sym in object_type.get_fields ()) {
                if (field_sym.name[0] == '_' && seen_props.contains (field_sym.name[1:field_sym.name.length])
                    || field_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (field_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (field_sym, CompletionItemKind.Field));
            }

            // get inner types and constants
            if (!is_instance) {
                foreach (var constant_sym in object_type.get_constants ()) {
                    if (!is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (constant_sym, CompletionItemKind.Constant));
                }

                foreach (var class_sym in object_type.get_classes ())
                    completions.add (new CompletionItem.from_symbol (class_sym, CompletionItemKind.Class));

                foreach (var struct_sym in object_type.get_structs ())
                    completions.add (new CompletionItem.from_symbol (struct_sym, CompletionItemKind.Struct));

                foreach (var enum_sym in object_type.get_enums ())
                    completions.add (new CompletionItem.from_symbol (enum_sym, CompletionItemKind.Enum));

                foreach (var delegate_sym in object_type.get_delegates ())
                    completions.add (new CompletionItem.from_symbol (delegate_sym, CompletionItemKind.Event));
            }

            // get members of supertypes
            if (is_instance) {
                if (object_type is Vala.Class)
                    foreach (var base_type in (object_type as Vala.Class).get_base_types ())
                        add_completions_for_type (base_type.data_type,
                                                  completions, current_scope, is_instance, seen_props);
                if (object_type is Vala.Interface)
                    foreach (var base_type in (object_type as Vala.Interface).get_prerequisites ())
                        add_completions_for_type (base_type.data_type,
                                                  completions, current_scope, is_instance, seen_props);
            }
        } else if (type is Vala.Enum) {
            /**
             * Complete members of this enum, such as the values, methods,
             * and constants.
             */
            var enum_type = type as Vala.Enum;

            foreach (var method_sym in enum_type.get_methods ()) {
                if (method_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method));
            }

            if (!is_instance) {
                foreach (var constant_sym in enum_type.get_constants ()) {
                    if (!is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (constant_sym, CompletionItemKind.Constant));
                }
                foreach (var value_sym in enum_type.get_values ())
                    completions.add (new CompletionItem.from_symbol (value_sym, CompletionItemKind.EnumMember));
            }
        } else if (type is Vala.ErrorDomain) {
            /**
             * Get all the members of the error domain, such as the error
             * codes and the methods.
             */
            var errdomain_type = type as Vala.ErrorDomain;

            foreach (var code_sym in errdomain_type.get_codes ()) {
                if (code_sym.is_instance_member () != is_instance)
                    continue;
                completions.add (new CompletionItem.from_symbol (code_sym, CompletionItemKind.Value));
            }

            foreach (var method_sym in errdomain_type.get_methods ()) {
                if (method_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method));
            }
        } else if (type is Vala.Struct) {
            /**
             * Gets all of the members of the struct.
             */
            var struct_type = type as Vala.Struct;

            foreach (var field_sym in struct_type.get_fields ()) {
                // struct fields are always public
                if (field_sym.is_instance_member () != is_instance)
                    continue;
                completions.add (new CompletionItem.from_symbol (field_sym, CompletionItemKind.Field));
            }

            foreach (var method_sym in struct_type.get_methods ()) {
                if (method_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method));
            }

            foreach (var prop_sym in struct_type.get_properties ()) {
                if (prop_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (prop_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (prop_sym, CompletionItemKind.Property));
            }

            if (!is_instance) {
                foreach (var constant_sym in struct_type.get_constants ()) {
                    if (!is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (constant_sym, CompletionItemKind.Constant));
                }
            }
        } else {
            debug (@"other type node $(type).\n");
        }
    }

    /**
     * Use this when we're completing members of a namespace.
     */
    void add_completions_for_ns (Vala.Namespace ns, Gee.Set<CompletionItem> completions) {
        foreach (var class_sym in ns.get_classes ())
            completions.add (new CompletionItem.from_symbol (class_sym, CompletionItemKind.Class));
        foreach (var const_sym in ns.get_constants ())
            completions.add (new CompletionItem.from_symbol (const_sym, CompletionItemKind.Constant));
        foreach (var iface_sym in ns.get_interfaces ())
            completions.add (new CompletionItem.from_symbol (iface_sym, CompletionItemKind.Interface));
        foreach (var struct_sym in ns.get_structs ())
            completions.add (new CompletionItem.from_symbol (struct_sym, CompletionItemKind.Struct));
        foreach (var method_sym in ns.get_methods ())
            completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method));
        foreach (var enum_sym in ns.get_enums ())
            completions.add (new CompletionItem.from_symbol (enum_sym, CompletionItemKind.Enum));
        foreach (var err_sym in ns.get_error_domains ())
            completions.add (new CompletionItem.from_symbol (err_sym, CompletionItemKind.Enum));
        foreach (var ns_sym in ns.get_namespaces ())
            completions.add (new CompletionItem.from_symbol (ns_sym, CompletionItemKind.Module));
    }

    /**
     * Use this to complete members of a signal.
     */
    void add_completions_for_signal (Vala.Signal sig, Gee.Set<CompletionItem> completions) {
        string arg_list = "";
        foreach (var p in sig.get_parameters ()) {
            if (arg_list != "")
                arg_list += ", ";
            arg_list += get_symbol_data_type (p);
        }
        completions.add_all_array (new CompletionItem []{
            new CompletionItem.for_signal ("connect", @"uint connect ($arg_list)", "Connect signal"),
            new CompletionItem.for_signal ("connect_after", @"uint connect_after ($arg_list)", "Connect signal after default handler"),
            new CompletionItem.for_signal ("disconnect", "void disconnect (uint id)", "Disconnect signal")
        });
    }

    /**
     * Find the type of a symbol in the code.
     */
    Vala.TypeSymbol? get_type_symbol (Vala.CodeNode symbol, bool is_pointer, ref bool is_instance) {
        Vala.DataType? data_type = null;
        Vala.TypeSymbol? type_symbol = null;
        if (symbol is Vala.Variable) {
            data_type = (symbol as Vala.Variable).variable_type;
        } else if (symbol is Vala.Expression) {
            data_type = (symbol as Vala.Expression).value_type;
        }

        if (data_type != null) {
            do {
                if (data_type.data_type == null) {
                    if (data_type is Vala.ErrorType) {
                        var err_type = data_type as Vala.ErrorType;
                        if (err_type.error_code != null)
                            type_symbol = err_type.error_code;
                        else if (err_type.error_domain != null)
                            type_symbol = err_type.error_domain;
                        else {
                            // this is a generic error
                            Vala.Symbol? sym = ctx.code_context.root.scope.lookup ("GLib");
                            if (sym != null)
                                sym = sym.scope.lookup ("Error");
                            else
                                debug ("get_type_symbol(): GLib not found");
                            if (sym != null)
                                type_symbol = sym as Vala.TypeSymbol;
                            else
                                debug (@"could not get type symbol for $(data_type.type_name)");
                        }
                    } else if (data_type is Vala.PointerType && is_pointer) {
                        data_type = (data_type as Vala.PointerType).base_type;
                        debug (@"peeled base_type $(data_type.type_name) from pointer type");
                        continue;       // try again
                    } else {
                        debug (@"could not get type symbol from $(data_type.type_name)");
                    }
                } else
                    type_symbol = data_type.data_type;
                break;
            } while (true);
        } else if (symbol is Vala.TypeSymbol) {
            type_symbol = symbol as Vala.TypeSymbol;
            is_instance = false;
        }

        return type_symbol;
    }

    void textDocumentCompletion (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        TextDocument? doc = ctx.get_source_file (p.textDocument.uri);
        if (doc == null) {
            debug ("unknown file %s", p.textDocument.uri);
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/completion] failed to reply to client: %s", e.message);
            }
            return;
        }
        // force context update if necessary
        require_updated_context ();
        bool is_pointer_access = false;
        long idx = (long) get_string_pos (doc.file.content, p.position.line, p.position.character);
        Position pos = p.position;

        if (idx >= 2 && doc.file.content[idx-2:idx] == "->") {
            is_pointer_access = true;
            debug ("[textDocument/completion] found pointer access");
            pos = p.position.translate (0, -2);
        } else if (idx >= 1 && doc.file.content[idx-1:idx] == ".")
            pos = p.position.translate (0, -1);

        var fs = new FindSymbol (doc.file, pos.to_libvala (), true);

        if (fs.result.size == 0) {
            debug ("[textDocument/completion] no results found");
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/completion] failed to reply to client: %s", e.message);
            }
            return;
        }

        foreach (var res in fs.result)
            debug (@"[textDocument/completion] found $(res.type_name) (semanalyzed = $(res.checked))");

        Vala.CodeNode result = get_best (fs, doc.file);
        Vala.CodeNode? peeled = null;
        Vala.Scope current_scope = get_current_scope (result);
        var json_array = new Json.Array ();
        var completions = new Gee.HashSet<CompletionItem> ();

        debug (@"[textDocument/completion] got $(result.type_name) `$result' (semanalyzed = $(result.checked)))");
        if (result is Vala.MemberAccess) {
            var ma = result as Vala.MemberAccess;
            if (ma.symbol_reference != null) {
                debug (@"peeling away symbol_reference from MemberAccess: $(ma.symbol_reference.type_name)");
                peeled = ma.symbol_reference;
            } else {
                debug ("MemberAccess does not have symbol_reference");
                if (!ma.checked) {
                    for (Vala.CodeNode? parent = ma.parent_node; 
                         parent != null;
                         parent = parent.parent_node)
                    {
                        debug (@"parent ($parent) semanalyzed = $(parent.checked)");
                    }
                }
            }
        }

        do {
            bool is_instance = true;
            Vala.TypeSymbol? type_sym = get_type_symbol (result, is_pointer_access, ref is_instance);

            // try again
            if (type_sym == null && peeled != null)
                type_sym = get_type_symbol (peeled, is_pointer_access, ref is_instance);

            if (type_sym != null)
                add_completions_for_type (type_sym, completions, current_scope, is_instance);
            // and try some more
            else if (peeled is Vala.Signal)
                add_completions_for_signal (peeled as Vala.Signal, completions);
            else if (peeled is Vala.Namespace)
                add_completions_for_ns (peeled as Vala.Namespace, completions);
            else {
                if (result is Vala.MemberAccess &&
                    ((Vala.MemberAccess)result).inner != null) {
                    result = ((Vala.MemberAccess)result).inner;
                    // maybe our expression was wrapped in extra parentheses:
                    // (x as T). for example
                    continue; 
                }
                debug ("[textDocument/completion] could not get datatype");
            }
            break;      // break by default
        } while (true);

        foreach (CompletionItem comp in completions)
            json_array.add_element (Json.gobject_serialize (comp));

        try {
            Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
            client.reply (id, variant_array);
        } catch (Error e) {
            debug (@"[textDocument/completion] failed to reply to client: $(e.message)");
        }
    }

    void textDocumentSignatureHelp (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        TextDocument? doc = ctx.get_source_file (p.textDocument.uri);
        if (doc == null) {
            debug ("unknown file %s", p.textDocument.uri);
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/signatureHelp] failed to reply to client: %s", e.message);
            }
            return;
        }
        // force context update if necessary
        require_updated_context ();

        var signatures = new Gee.ArrayList <SignatureInformation> ();
        var json_array = new Json.Array ();
        int active_param = 0;

        long idx = (long) get_string_pos (doc.file.content, p.position.line, p.position.character);
        Position pos = p.position;

        if (idx >= 2 && doc.file.content[idx-1:idx] == "(") {
            debug ("[textDocument/signatureHelp] possible argument list");
            pos = p.position.translate (0, -2);
        } else if (idx >= 1 && doc.file.content[idx-1:idx] == ",") {
            debug ("[textDocument/signatureHelp] possible ith argument in list");
            pos = p.position.translate (0, -1);
        }

        var fs = new FindSymbol (doc.file, pos.to_libvala ());

        // filter the results for MethodCall's and ExpressionStatements
        var fs_results = fs.result;
        fs.result = new Gee.ArrayList<Vala.CodeNode> ();

        foreach (var res in fs_results) {
            debug (@"[textDocument/signatureHelp] found $(res.type_name) (semanalyzed = $(res.checked))");
            if (res is Vala.ExpressionStatement || res is Vala.MethodCall
             || res is Vala.ObjectCreationExpression)
                fs.result.add (res);
        }

        if (fs.result.size == 0 && fs_results.size > 0) {
            // In cases where our cursor is to the right of a method call and
            // not inside it (most likely because the right parenthesis is omitted),
            // we might not find any MethodCall or ExpressionStatements, so instead
            // look at whatever we found and see if it is a child of what we want.
            foreach (var res in fs_results) {
                // walk up tree
                for (Vala.CodeNode? x = res; x != null; x = x.parent_node)
                    if (x is Vala.ExpressionStatement || x is Vala.MethodCall)
                        fs.result.add (x);
            }
        }

        if (fs.result.size == 0) {
            debug ("[textDocument/signatureHelp] no results found");
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/signatureHelp] failed to reply to client: %s", e.message);
            }
            return;
        }

        Vala.CodeNode result = get_best (fs, doc.file);

        if (result is Vala.ExpressionStatement) {
            result = (result as Vala.ExpressionStatement).expression;
            debug (@"[textDocument/signatureHelp] peeling away expression statement: $(result)");
        }

        var si = new SignatureInformation ();
        Vala.List<Vala.Parameter>? param_list = null;
        // The explicit symbol referenced, like a local variable
        // or a method. Could be null if we invoke an array element, 
        // for example.
        Vala.Symbol? explicit_sym = null;
        // The symbol referenced indirectly
        Vala.Symbol? type_sym = null;
        // The parent symbol (useful for creation methods)
        Vala.Symbol? parent_sym = null;

        if (result is Vala.MethodCall) {
            var mc = result as Vala.MethodCall;
            // TODO: NamedArgument's, whenever they become supported in upstream
            active_param = mc.initial_argument_count - 1;
            if (active_param < 0)
                active_param = 0;
            else if (mc.extra_comma)
                active_param++;
            foreach (var arg in mc.get_argument_list ()) {
                debug (@"$mc: found argument ($arg)");
            }

            // get the method type from the expression
            Vala.DataType data_type = mc.call.value_type;
            explicit_sym = mc.call.symbol_reference;

            if (data_type is Vala.CallableType) {
                var ct = data_type as Vala.CallableType;
                param_list = ct.get_parameters ();
 
                if (ct is Vala.DelegateType)
                    type_sym = (ct as Vala.DelegateType).delegate_symbol;
                else if (ct is Vala.MethodType)
                    type_sym = (ct as Vala.MethodType).method_symbol;
                else if (ct is Vala.SignalType)
                    type_sym = (ct as Vala.SignalType).signal_symbol;
            }
        } else if (result is Vala.ObjectCreationExpression) {
            var oce = result as Vala.ObjectCreationExpression;
            // TODO: NamedArgument's, whenever they become supported in upstream
            active_param = oce.initial_argument_count - 1;
            if (active_param < 0)
                active_param = 0;
            else if (oce.extra_comma)
                active_param++;
            foreach (var arg in oce.get_argument_list ()) {
                debug (@"$oce: found argument ($arg)");
            }

            explicit_sym = oce.symbol_reference;

            if (explicit_sym == null && oce.member_name != null) {
                explicit_sym = oce.member_name.symbol_reference;
                debug (@"[textDocument/signatureHelp] explicit_sym = $explicit_sym $(explicit_sym.type_name)");
            }

            if (explicit_sym != null && explicit_sym is Vala.Callable)
                param_list = (explicit_sym as Vala.Callable).get_parameters ();

            parent_sym = explicit_sym.parent_symbol;
        } else {
            debug ("[textDocument/signatureHelp] neither a method call nor object creation expr");
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/signatureHelp] failed to reply to client: %s", e.message);
            }
            return;     // early exit
        } 

        assert (explicit_sym != null || type_sym != null);
                
        if (explicit_sym == null) {
            si.label = get_symbol_data_type (type_sym);
            si.documentation = get_symbol_comment (type_sym);
        } else {
            // TODO: need a function to display symbol names correctly given context
            if (type_sym != null) {
                si.label = get_symbol_data_type (type_sym);
                si.documentation = get_symbol_comment (type_sym);
            } else {
                si.label = get_symbol_data_type (explicit_sym, false, parent_sym);
            }
            // try getting the documentation for the explicit symbol
            // if the type does not have any documentation
            if (si.documentation == null)
                si.documentation = get_symbol_comment (explicit_sym);
        }

        if (param_list != null) {
            foreach (var parameter in param_list) {
                si.parameters.add (new ParameterInformation () {
                    label = get_symbol_data_type (parameter),
                    documentation = get_symbol_comment (parameter)
                });
                debug (@"found parameter $parameter (name = $(parameter.name))");
            }
            signatures.add (si);
        }


        foreach (var sinfo in signatures)
            json_array.add_element (Json.gobject_serialize (sinfo));

        try {
            Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
            client.reply (id, buildDict (
                signatures: variant_array,
                activeParameter: new Variant.int32 (active_param)
            ));
        } catch (Error e) {
            debug (@"[textDocument/signatureHelp] failed to reply to client: $(e.message)");
        }
    }

    void textDocumentHover (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        TextDocument? doc = ctx.get_source_file (p.textDocument.uri);
        if (doc == null) {
            debug ("unknown file %s", p.textDocument.uri);
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/hover] failed to reply to client: %s", e.message);
            }
            return;
        }

        Position pos = p.position;
        var fs = new FindSymbol (doc.file, pos.to_libvala ());

        if (fs.result.size == 0) {
            debug ("[textDocument/hover] no results found");
            try {
                client.reply (id, new Variant.maybe (VariantType.VARIANT, null));
            } catch (Error e) {
                debug ("[textDocument/hover] failed to reply to client: %s", e.message);
            }
            return;
        }

        Vala.CodeNode result = get_best (fs, doc.file);
        var hoverInfo = new Hover () {
            range = new Range.from_sourceref (result.source_reference)
        };

        if (result is Vala.Symbol) {
            hoverInfo.contents.add (new MarkedString () {
                language = "vala",
                value = get_symbol_data_type (result as Vala.Symbol)
            });
            var comment = get_symbol_comment (result as Vala.Symbol);
            if (comment != null) {
                hoverInfo.contents.add (new MarkedString () {
                    value = comment.value
                });
            }
        } else if (result is Vala.Expression && ((Vala.Expression)result).symbol_reference != null) {
            var sym = (result as Vala.Expression).symbol_reference;
            hoverInfo.contents.add (new MarkedString () {
                language = "vala",
                value = get_symbol_data_type (sym, result is Vala.Literal)
            });
        } else if (result is Vala.CastExpression) {
            hoverInfo.contents.add (new MarkedString () {
                language = "vala",
                value = @"$result"
            });
        } else {
            bool is_instance = true;
            Vala.TypeSymbol? type_sym = get_type_symbol (result, false, ref is_instance);
            hoverInfo.contents.add (new MarkedString () {
                language = "vala",
                value = type_sym != null ? get_symbol_data_type (type_sym, true) : result.to_string ()
            });
        }

        debug (@"[textDocument/hover] got $result $(result.type_name)");

        try {
            client.reply (id, object_to_variant (hoverInfo));
        } catch (Error e) {
            debug ("[textDocument/hover] failed to reply to client: %s", e.message);
        }
    }

    void shutdown (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        ctx.clear ();
        try {
            client.reply (id, buildDict (null));
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
