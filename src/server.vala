using LanguageServer;
using Gee;

class Vls.Server : Object {
    private static bool received_signal = false;
    Jsonrpc.Server server;
    MainLoop loop;

    HashTable<string, NotificationHandler> notif_handlers;
    HashTable<string, CallHandler> call_handlers;
    InitializeParams init_params;

    const uint check_update_context_period_ms = 100;
    const int64 update_context_delay_inc_us = 500 * 1000;
    const int64 update_context_delay_max_us = 1000 * 1000;
    const uint wait_for_context_update_delay_ms = 200;

#if PARSE_SYSTEM_GIRS
    /**
     * Contains documentation from found GIR files.
     */
    GirDocumentation documentation;
#endif
    HashSet<Request> pending_requests;

    bool shutting_down = false;

    bool is_initialized = false;

    /**
     * The global cancellable object
     */
    public static Cancellable cancellable = new Cancellable ();

    [CCode (has_target = false)]
    delegate void NotificationHandler (Vls.Server self, Jsonrpc.Client client, Variant @params);

    [CCode (has_target = false)]
    delegate void CallHandler (Vls.Server self, Jsonrpc.Server server, Jsonrpc.Client client, string method, Variant id, Variant @params);

    uint[] g_sources = {};
    ulong client_closed_event_id;
    HashTable<Project, ulong> projects;
    DefaultProject default_project;

    static construct {
        Process.@signal (ProcessSignal.INT, () => {
            if (!Server.received_signal)
                cancellable.cancel ();
            Server.received_signal = true;
        });
        Process.@signal (ProcessSignal.TERM, () => {
            if (!Server.received_signal)
                cancellable.cancel ();
            Server.received_signal = true;
        });
    }

    public Server (MainLoop loop) {
        this.loop = loop;
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

        // shutdown if/when we get a signal
        g_sources += Timeout.add (1 * 1000, () => {
            if (Server.received_signal) {
                shutdown_real ();
                return Source.REMOVE;
            }
            return !this.shutting_down;
        });

        server.accept_io_stream (new SimpleIOStream (input_stream, output_stream));

#if WITH_JSONRPC_GLIB_3_30
        client_closed_event_id = server.client_closed.connect (client => {
            shutdown_real ();
        });
#endif

        notif_handlers = new HashTable<string, NotificationHandler> (str_hash, str_equal);
        call_handlers = new HashTable<string, CallHandler> (str_hash, str_equal);

        pending_requests = new HashSet<Request> (Request.hash, Request.equal);

        server.notification.connect ((client, method, @params) => {
            // debug (@"Got notification! $method");
            if (!is_initialized) {
                debug (@"Server is not initialized, ignoring $method");
            } else if (notif_handlers.contains (method))
                ((NotificationHandler) notif_handlers[method]) (this, client, @params);
            else
                warning (@"no notification handler for $method");
        });

        server.handle_call.connect ((client, method, id, @params) => {
            // debug (@"Got call! $method");
            if (!is_initialized && !(method == "initialize" ||
                                     method == "shutdown" ||
                                     method == "exit")) {
                debug (@"Server is not initialized, ignoring $method");
                return false;
            } else if (call_handlers.contains (method)) {
                ((CallHandler) call_handlers[method]) (this, server, client, method, id, @params);
                return true;
            } else {
                warning (@"no call handler for $method");
                return false;
            }
        });

        this.projects = new HashTable<Project, ulong> (GLib.direct_hash, GLib.direct_equal);

        call_handlers["initialize"] = this.initialize;
        call_handlers["shutdown"] = this.shutdown;
        notif_handlers["exit"] = this.exit;

        call_handlers["textDocument/definition"] = this.textDocumentDefinition;
        notif_handlers["textDocument/didOpen"] = this.textDocumentDidOpen;
        notif_handlers["textDocument/didClose"] = this.textDocumentDidClose;
        notif_handlers["textDocument/didChange"] = this.textDocumentDidChange;
        call_handlers["textDocument/documentSymbol"] = this.textDocumentDocumentSymbol;
        call_handlers["textDocument/completion"] = this.textDocumentCompletion;
        call_handlers["textDocument/signatureHelp"] = this.textDocumentSignatureHelp;
        call_handlers["textDocument/hover"] = this.textDocumentHover;
        call_handlers["textDocument/references"] = this.textDocumentReferences;
        call_handlers["textDocument/documentHighlight"] = this.textDocumentReferences;
        call_handlers["textDocument/implementation"] = this.textDocumentImplementation;
        call_handlers["workspace/symbol"] = this.workspaceSymbol;
        notif_handlers["$/cancelRequest"] = this.cancelRequest;

        debug ("Finished constructing");
    }

    // a{sv} only
    public Variant buildDict (...) {
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
        if (type == MessageType.Error)
            warning (message);
        try {
            client.send_notification ("window/showMessage", buildDict (
                type: new Variant.int16 (type),
                message: new Variant.string (message)
            ), cancellable);
        } catch (Error e) {
            debug (@"showMessage: failed to notify client: $(e.message)");
        }
    }

    void initialize (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        init_params = Util.parse_variant<InitializeParams> (@params);

        File root_dir;
        if (init_params.rootUri != null)
            root_dir = File.new_for_uri (init_params.rootUri);
        else if (init_params.rootPath != null)
            root_dir = File.new_for_path (init_params.rootPath);
        else
            root_dir = File.new_for_path (Environment.get_current_dir ());
        if (!root_dir.is_native ()) {
            showMessage (client, "Non-native files not supported", MessageType.Error);
            error ("Non-native files not supported");
        }
        string root_path = Util.realpath ((!) root_dir.get_path ());
        debug (@"[initialize] root path is $root_path");

        // respond
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
                        triggerCharacters: new Variant.strv (new string[] {"(", "[", ","})
                    ),
                    hoverProvider: new Variant.boolean (true),
                    referencesProvider: new Variant.boolean (true),
                    documentHighlightProvider: new Variant.boolean (true),
                    implementationProvider: new Variant.boolean (true),
                    workspaceSymbolProvider: new Variant.boolean (true)
                ),
                serverInfo: buildDict (
                    name: new Variant.string ("Vala Language Server"),
                    version: new Variant.string (Config.version)
                )
            ), cancellable);
        } catch (Error e) {
            error (@"[initialize] failed to reply to client: $(e.message)");
        }

        var meson_file = root_dir.get_child ("meson.build");
        ArrayList<File> cc_files = new ArrayList<File> ();
        try {
            cc_files = Util.find_files (root_dir, /compile_commands\.json/, 2);
        } catch (Error e) {
            warning ("could not enumerate root dir - %s", e.message);
        }

        var new_projects = new ArrayList<Project> ();
        Project? backend_project = null;
        // TODO: autotools, make(?), cmake(?)
        if (meson_file.query_exists (cancellable)) {
            try {
                backend_project = new MesonProject (root_path, cancellable);
            } catch (Error e) {
                if (!(e is ProjectError.VERSION_UNSUPPORTED)) {
                    showMessage (client, @"Failed to initialize Meson project - $(e.message)", MessageType.Error);
                }
            }
        }
        
        // try compile_commands.json if Meson failed
        if (backend_project == null && !cc_files.is_empty) {
            foreach (var cc_file in cc_files) {
                string cc_file_path = Util.realpath (cc_file.get_path ());
                try {
                    backend_project = new CcProject (root_path, cc_file_path, cancellable);
                    debug ("[initialize] initialized CcProject with %s", cc_file_path);
                    break;
                } catch (Error e) {
                    debug ("[initialize] CcProject failed with %s - %s", cc_file_path, e.message);
                    continue;
                }
            }
        }

        // show messages if we could not get a backend-specific project
        if (backend_project == null) {
            var cmake_file = root_dir.get_child ("CMakeLists.txt");
            var autogen_sh = root_dir.get_child ("autogen.sh");

            if (cmake_file.query_exists (cancellable))
                showMessage (client, @"CMake build system is not currently supported. Only Meson is. See https://github.com/benwaffle/vala-language-server/issues/73", MessageType.Warning);
            if (autogen_sh.query_exists (cancellable))
                showMessage (client, @"Autotools build system is not currently supported. Consider switching to Meson.", MessageType.Warning);
        } else {
            new_projects.add (backend_project);
        }

        // always have default project
        default_project = new DefaultProject (root_path);

        foreach (var project in new_projects) {
            try {
                project.build_if_stale (cancellable);
            } catch (Error e) {
                showMessage (client, @"failed to build project - $(e.message)", MessageType.Error);
                warning ("[initialize] failed to build project - %s", e.message);
                return;
            }
        }

#if PARSE_SYSTEM_GIRS
        // create documentation (compiles GIR files too)
        var packages = new HashSet<Vala.SourceFile> ();
        foreach (var project in new_projects)
            packages.add_all (project.get_packages ());
        documentation = new GirDocumentation (packages);
#endif

        // build and publish diagnostics
        foreach (var project in new_projects) {
            try {
                debug ("Building project ...");
                project.build_if_stale ();
                debug ("Publishing diagnostics ...");
                foreach (var compilation in project.get_compilations ())
                    publishDiagnostics (compilation, client);
            } catch (Error e) {
                showMessage (client, @"Failed to build project - $(e.message)", MessageType.Error);
            }
        }

        // listen for context update requests
        update_context_client = client;
        g_sources += Timeout.add (check_update_context_period_ms, () => {
            check_update_context ();
            return !this.shutting_down;
        });

        // listen for project changed events
        foreach (Project project in new_projects)
            projects[project] = project.changed.connect (project_changed_event);

        is_initialized = true;
    }

    void project_changed_event () {
        request_context_update (update_context_client);
        debug ("requested context update for project change event");
    }

    void cancelRequest (Jsonrpc.Client client, Variant @params) {
        Variant? id = @params.lookup_value ("id", null);
        if (id == null)
            return;

        var req = new Request (id);
        // if (pending_requests.remove (req))
        //     debug (@"[cancelRequest] cancelled request $req");
        // else
        //     debug (@"[cancelRequest] request $req not found");
        pending_requests.remove (req);
    }

    public static void reply_null (Variant id, Jsonrpc.Client client, string method) {
        try {
            client.reply (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }

    void textDocumentDidOpen (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);

        string? uri         = (string) document.lookup_value ("uri",        VariantType.STRING);
        string languageId   = (string) document.lookup_value ("languageId", VariantType.STRING);
        string fileContents = (string) document.lookup_value ("text",       VariantType.STRING);

        if (languageId != "vala" && languageId != "genie") {
            warning (@"[textDocument/didOpen] $languageId file sent to vala language server");
            return;
        }

        if (uri == null) {
            warning (@"[textDocument/didOpen] null URI sent to vala language server");
            return;
        }

        Pair<Vala.SourceFile, Compilation>? doc_w_bt = null;

        foreach (var project in projects.get_keys_as_array ()) {
            try {
                doc_w_bt = project.open (uri, fileContents, cancellable).first ();
                break;
            } catch (Error e) {
                if (!(e is ProjectError.NOT_FOUND))
                    warning ("[textDocument/didOpen] failed to open %s - %s", Uri.unescape_string (uri), e.message);
            }
        }

        // fallback to default project
        if (doc_w_bt == null) {
            try {
                doc_w_bt = default_project.open (uri, fileContents, cancellable).first ();
                // show diagnostics for the newly-opened file
                request_context_update (client);
            } catch (Error e) {
                warning ("[textDocumnt/didOpen] failed to open %s - %s", Uri.unescape_string (uri), e.message);
            }
        }

        if (doc_w_bt == null) {
            warning ("[textDocument/didOpen] could not open %s", uri);
            return;
        }

        var doc = doc_w_bt.first;
        // We want to load the document unconditionally, to avoid
        // errors later on in textDocument/didChange. However, we
        // only want to edit it if it is an actual TextDocument.
        if (doc.content == null)
            doc.get_mapped_contents ();
        if (doc is TextDocument) {
            debug (@"[textDocument/didOpen] opened $(Uri.unescape_string (uri))"); 
            if (doc.content != fileContents) {
                doc.content = fileContents;
                request_context_update (client);
                debug (@"[textDocument/didOpen] requested context update");
            }
        } else {
            debug (@"[textDocument/didOpen] opened read-only $(Uri.unescape_string (uri))");
        }
    }

    void textDocumentDidClose (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        string? uri         = (string) document.lookup_value ("uri",        VariantType.STRING);

        if (uri == null) {
            warning (@"[textDocument/didClose] null URI sent to vala language server");
            return;
        }

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;

        foreach (var project in all_projects) {
            try {
                if (project.close (uri)) {
                    request_context_update (client);
                    debug (@"[textDocument/didClose] requested context update");
                }
            } catch (Error e) {
                if (!(e is ProjectError.NOT_FOUND))
                    warning ("[textDocument/didClose] failed to close %s - %s", Uri.unescape_string (uri), e.message);
            }
        }
    }

    Jsonrpc.Client? update_context_client = null;
    int64 update_context_requests = 0;
    int64 update_context_time_us = 0;

    void textDocumentDidChange (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        var changes = @params.lookup_value ("contentChanges", VariantType.ARRAY);

        var uri = (string) document.lookup_value ("uri", VariantType.STRING);
        var version = (int64) document.lookup_value ("version", VariantType.INT64);

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;

        foreach (var project in all_projects) {
            foreach (Pair<Vala.SourceFile, Compilation> pair in project.lookup_compile_input_source_file (uri)) {
                var source_file = pair.first;

                if (!(source_file is TextDocument)) {
                    warning (@"[textDocument/didChange] Ignoring change to system file");
                    return;
                }

                var source = (TextDocument) source_file;
                if (source.version >= version) {
                    warning (@"[textDocument/didChange] rejecting outdated version of $(Uri.unescape_string (uri))");
                    return;
                }

                if (source_file.content == null) {
                    error (@"[textDocument/didChange] source content is null!");
                }

                // update the document
                var iter = changes.iterator ();
                Variant? elem = null;
                var sb = new StringBuilder (source.content);
                while ((elem = iter.next_value ()) != null) {
                    var changeEvent = Util.parse_variant<TextDocumentContentChangeEvent> (elem);

                    if (changeEvent.range == null) {
                        sb.assign (changeEvent.text);
                    } else {
                        var start = changeEvent.range.start;
                        var end = changeEvent.range.end;
                        size_t pos_begin = Util.get_string_pos (sb.str, start.line, start.character);
                        size_t pos_end = Util.get_string_pos (sb.str, end.line, end.character);
                        sb.erase ((ssize_t) pos_begin, (ssize_t) (pos_end - pos_begin));
                        sb.insert ((ssize_t) pos_begin, changeEvent.text);
                    }
                }
                source.content = sb.str;
                source.last_updated = new DateTime.now ();
                source.version = (int) version;

                request_context_update (client);
            }
        }
    }

    void request_context_update (Jsonrpc.Client client) {
        update_context_client = client;
        update_context_requests += 1;
        int64 delay_us = int64.min (update_context_delay_inc_us * update_context_requests, update_context_delay_max_us);
        update_context_time_us = get_monotonic_time () + delay_us;
        // debug (@"Context(s) update (re-)scheduled in $((int) (delay_us / 1000)) ms");
    }

    /** 
     * Reconfigure the project if needed, and check whether we need to rebuild
     * the project if we have context update requests.
     */
    void check_update_context () {
        if (update_context_requests > 0 && get_monotonic_time () >= update_context_time_us) {
            debug ("updating contexts and publishing diagnostics...");
            update_context_requests = 0;
            update_context_time_us = 0;
            Project[] all_projects = projects.get_keys_as_array ();
            all_projects += default_project;
            foreach (var project in all_projects) {
                try {
                    project.reconfigure_if_stale (cancellable);
                    project.build_if_stale (cancellable);
                    foreach (var compilation in project.get_compilations ())
                        /* This must come after the resetting of the two variables above,
                        * since it's possible for publishDiagnostics to eventually call
                        * one of our JSON-RPC callbacks through g_main_context_iteration (),
                        * if we get a new message while sending the textDocument/publishDiagnostics
                        * notifications. */
                        publishDiagnostics (compilation, update_context_client);
                } catch (Error e) {
                    warning ("Failed to rebuild and/or reconfigure project: %s", e.message);
                }
            }
        }
    }

    public delegate void OnContextUpdatedFunc (bool request_cancelled);

    /**
     * Rather than satisfying all requests in `check_update_context ()`,
     * to avoid race conditions, we have to spawn a timeout to check for 
     * the right conditions to call `on_context_updated_func ()`.
     */
    public void wait_for_context_update (Variant id, owned OnContextUpdatedFunc on_context_updated_func) {
        // we've already updated the context
        if (update_context_requests == 0)
            on_context_updated_func (false);
        else {
            var req = new Request (id);
            if (!pending_requests.add (req))
                warning (@"Request ($req): request already in pending requests, this should not happen");
            /* else
                debug (@"Request ($req): added request to pending requests"); */
            wait_for_context_update_aux (req, (owned) on_context_updated_func);
        }
    }

    /**
     * Execute `on_context_updated_func ()` or wait.
     */
    void wait_for_context_update_aux (Request req, owned OnContextUpdatedFunc on_context_updated_func) {
        // we've already updated the context
        if (update_context_requests == 0) {
            if (!pending_requests.remove (req)) {
                // debug (@"Request ($req): context updated but request cancelled");
                on_context_updated_func (true);
            } else {
                // debug (@"Request ($req): context updated");
                on_context_updated_func (false);
            }
        } else {
            Timeout.add (wait_for_context_update_delay_ms, () => {
                if (pending_requests.contains (req))
                    wait_for_context_update_aux (req, (owned) on_context_updated_func);
                else {
                    // debug (@"Request ($req): cancelled before context update");
                    on_context_updated_func (true);
                }
                return Source.REMOVE;
            });
        }
    }

    void publishDiagnostics (Compilation target, Jsonrpc.Client client) {
        var files_not_published = new HashSet<Vala.SourceFile> (Util.source_file_hash, Util.source_file_equal);
        var diags_without_source = new Json.Array ();

        debug ("publishing diagnostics for Compilation target %s", target.id);

        foreach (var file in target.code_context.get_source_files ())
            files_not_published.add (file);

        var doc_diags = new HashMap<Vala.SourceFile, Json.Array> ();

        target.reporter.messages.foreach (err => {
            if (err.loc == null) {
                diags_without_source.add_element (Json.gobject_serialize (new Diagnostic () {
                    severity = err.severity,
                    message = err.message
                }));
                return;
            }
            assert (err.loc.file != null);
            if (!(err.loc.file in target.code_context.get_source_files ())) {
                warning (@"diagnostic has source not in compilation! - $(err.message)");
                return;
            }

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
                severity = err.severity,
                message = err.message
            };

            var node = Json.gobject_serialize (diag);
            if (!doc_diags.has_key (err.loc.file))
                doc_diags[err.loc.file] = new Json.Array ();
            doc_diags[err.loc.file].add_element (node);
        });

        // at the end, report diags for each source file
        foreach (var entry in doc_diags.entries) {
            Variant diags_variant_array;
            var gfile = File.new_for_commandline_arg_and_cwd (entry.key.filename, target.code_context.directory);

            files_not_published.remove (entry.key);
            try {
                diags_variant_array = Json.gvariant_deserialize (
                    new Json.Node.alloc ().init_array (entry.value),
                    null);
            } catch (Error e) {
                warning (@"[publishDiagnostics] failed to deserialize diags for `$(gfile.get_uri ())': $(e.message)");
                continue;
            }
            try {
                client.send_notification (
                    "textDocument/publishDiagnostics",
                    buildDict (
                        uri: new Variant.string (gfile.get_uri ()),
                        diagnostics: diags_variant_array
                    ),
                    cancellable);
            } catch (Error e) {
                warning (@"[publishDiagnostics] failed to notify client: $(e.message)");
            }
        }

        foreach (var entry in files_not_published) {
            var gfile = File.new_for_commandline_arg_and_cwd (entry.filename, target.code_context.directory);
            try {
                client.send_notification (
                    "textDocument/publishDiagnostics",
                    buildDict (
                        uri: new Variant.string (gfile.get_uri ()),
                        diagnostics: new Variant.array (VariantType.VARIANT, new Variant[]{})
                    ),
                    cancellable);
            } catch (Error e) {
                warning (@"[publishDiagnostics] failed to publish empty diags for $(gfile.get_uri ()): $(e.message)");
            }
        }

        try {
            Variant diags_wo_src_variant_array = Json.gvariant_deserialize (
                new Json.Node.alloc ().init_array (diags_without_source),
                null);
            client.send_notification (
                "textDocument/publishDiagnostics",
                buildDict (
                    diagnostics: diags_wo_src_variant_array
                ),
                cancellable);
        } catch (Error e) {
            warning (@"[publishDiagnostics] failed to publish diags without source: $(e.message)");
        }
    }

    public static Vala.CodeNode get_best (FindSymbol fs, Vala.SourceFile file) {
        Vala.CodeNode? best = null;

        foreach (var node in fs.result) {
            if (best == null) {
                best = node;
            } else {
                var best_begin = new Position.from_libvala (best.source_reference.begin);
                var best_end = new Position.from_libvala (best.source_reference.end);
                var node_begin = new Position.from_libvala (node.source_reference.begin);
                var node_end = new Position.from_libvala (node.source_reference.end);

                // it turns out that if multiple CodeNodes share the same range, the first one we
                // encounter will usually be the "right" one
                if (best_begin.compare_to (node_begin) <= 0 && node_end.compare_to (best_end) <= 0 &&
                    (!(best_begin.compare_to (node_begin) == 0 && node_end.compare_to (best_end) == 0) ||
                    // allow exception for local variables (pick the last one) - this helps foreach
                    (best is Vala.LocalVariable && node is Vala.LocalVariable) ||
                    // allow exception for lone properties - their implicit _* fields are declared in the same location
                    (best is Vala.Field && node is Vala.Property)
                )) {
                    best = node;
                }
            }
        }

        assert (best != null);
        // var sr = best.source_reference;
        // var from = (long)Util.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
        // var to = (long)Util.get_string_pos (file.content, sr.end.line-1, sr.end.column);
        // string contents = file.content [from:to];
        // debug ("Got best node: %s @ %s = %s", best.type_name, sr.to_string(), contents);

        return (!) best;
    }

    /**
     * Gets the symbol you really want, not something from a generated file.
     *
     * If `sym` comes from a generated file (eg. a VAPI), then
     * it would be more useful to show the file specific to the compilation
     * that generated the file.
     */
    Vala.Symbol find_real_sym (Project project, Vala.Symbol sym) {
        if (sym.source_reference == null || sym.source_reference.file == null)
            return sym;

        Compilation alter_comp;
        if (project.lookup_compilation_for_output_file (sym.source_reference.file.filename, out alter_comp)) {
            Vala.Symbol? matching_sym;
            if ((matching_sym = Util.find_matching_symbol (alter_comp.code_context, sym)) != null)
                return matching_sym;
        }
        return sym;
    }

    void textDocumentDefinition (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams> (@params);
        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        Project selected_project = null;
        foreach (var project in projects.get_keys_as_array ()) {
            results = project.lookup_compile_input_source_file (p.textDocument.uri);
            if (!results.is_empty) {
                selected_project = project;
                break;
            }
        }
        // fallback to default project
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (p.textDocument.uri);
            selected_project = default_project;
        }
        if (results.is_empty) {
            debug (@"[$method] file `$(p.textDocument.uri)' not found");
            reply_null (id, client, method);
            return;
        }

        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            // ignore multiple results
            Vala.SourceFile file = results[0].first;
            Compilation compilation = results[0].second;

            Vala.CodeContext.push (compilation.code_context);
            var fs = new FindSymbol (file, p.position);

            if (fs.result.size == 0) {
                try {
                    client.reply (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
                } catch (Error e) {
                    debug("[textDocument/definition] failed to reply to client: %s", e.message);
                }
                Vala.CodeContext.pop ();
                return;
            }

            Vala.CodeNode? best = get_best (fs, file);

            if (best is Vala.Expression && !(best is Vala.Literal)) {
                var b = (Vala.Expression)best;
                debug ("best (%p) is a Expression (symbol_reference = %p)", best, b.symbol_reference);
                if (b.symbol_reference != null && b.symbol_reference.source_reference != null) {
                    best = b.symbol_reference;
                    debug ("best is now the symbol_referenece => %p (%s)", best, best.to_string ());
                }
            } else if (best is Vala.DataType) {
                var dt = best as Vala.DataType;
                if (dt.type_symbol != null)
                    best = dt.type_symbol;
                else if (dt.symbol != null)
                    best = dt.symbol;
            } else {
                try {
                    client.reply (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
                } catch (Error e) {
                    debug("[textDocument/definition] failed to reply to client: %s", e.message);
                }
                Vala.CodeContext.pop ();
                return;
            }

            if (best is Vala.Symbol)
                best = find_real_sym (selected_project, (Vala.Symbol) best);

            var location = new Location.from_sourceref (best.source_reference);
            debug ("[textDocument/definition] found location ... %s", location.uri);
            try {
                client.reply (id, Util.object_to_variant (location), cancellable);
            } catch (Error e) {
                debug("[textDocument/definition] failed to reply to client: %s", e.message);
            }
            Vala.CodeContext.pop ();
        });
    }

    void textDocumentDocumentSymbol (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        Project selected_project = null;
        foreach (var project in projects.get_keys_as_array ()) {
            results = project.lookup_compile_input_source_file (p.textDocument.uri);
            if (!results.is_empty) {
                selected_project = project;
                break;
            }
        }
        // fallback to default project
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (p.textDocument.uri);
            selected_project = default_project;
        }
        if (results.is_empty) {
            debug (@"[$method] file `$(p.textDocument.uri)' not found");
            reply_null (id, client, method);
            return;
        }

        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            // ignore multiple results
            Vala.SourceFile file = results[0].first;
            Compilation compilation = results[0].second;

            if (compilation.code_context != file.context) {
                // This means the file was probably deleted from the current code context,
                // and so it's no longer valid. This is often the case for system files 
                // that are added automatically in Vala.CodeContext
                // This seems to be especially a problem on GNOME Builder, which runs
                // this query on all files right after the user updates a file, but before
                // the code context is updated.
                debug ("[%s] file (%s) context != compilation.code_context; not proceeding further",
                    method, p.textDocument.uri);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);

            var array = new Json.Array ();
            var syms = new ListSymbols (file);
            if (init_params.capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport)
                foreach (var dsym in syms) {
                    // debug(@"found $(dsym.name)");
                    array.add_element (Json.gobject_serialize (dsym));
                }
            else {
                foreach (var dsym in syms.flattened ()) {
                    // debug(@"found $(dsym.name)");
                    array.add_element (Json.gobject_serialize (new SymbolInformation.from_document_symbol (dsym, p.textDocument.uri)));
                }
            }

            try {
                Variant result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
                client.reply (id, result, cancellable);
            } catch (Error e) {
                debug (@"[textDocument/documentSymbol] failed to reply to client: $(e.message)");
            }
            Vala.CodeContext.pop ();
        });
    }

    public LanguageServer.MarkupContent? get_symbol_documentation (Project project, Vala.Symbol sym) {
        Compilation compilation = null;
        Vala.Symbol real_sym = find_real_sym (project, sym);
        sym = real_sym;
        Vala.Symbol root = null;
        for (var node = sym; node != null; node = node.parent_symbol)
            root = node;
        assert (root != null);
        foreach (var project_compilation in project.get_compilations ()) {
            if (project_compilation.code_context.root == root) {
                compilation = project_compilation;
                break;
            }
        }

        if (compilation == null)
            return null;

#if PARSE_SYSTEM_GIRS
        var gir_sym = documentation.find_gir_symbol (sym);
#endif
        string? comment = null;

        if (sym.comment != null) {
            comment = sym.comment.content;
            try {
                comment = /^\s*\*(.*)/m.replace (comment, comment.length, 0, "\\1");
            } catch (RegexError e) {
                warning (@"failed to parse comment...\n$comment\n...");
                comment = "(failed to parse Vala comment - `%s`)".printf (e.message);
            }
#if PARSE_SYSTEM_GIRS
        } else if (gir_sym != null && gir_sym.comment != null) {
            try {
                comment = documentation.render_gtk_doc_comment (gir_sym.comment, compilation);
            } catch (RegexError e) {
                warning ("failed to parse GTK-Doc comment...\n%s\n...", comment);
                comment = "(failed to parse GTK-Doc comment - `%s`)".printf (e.message);
            }
#endif
        } else {
            return null;
        }

        return new MarkupContent () {
            kind = "markdown",
            value = comment
        };
    }

    void textDocumentCompletion (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.CompletionParams>(@params);
        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        Project selected_project = null;
        foreach (var project in projects.get_keys_as_array ()) {
            results = project.lookup_compile_input_source_file (p.textDocument.uri);
            if (!results.is_empty) {
                selected_project = project;
                break;
            }
        }
        // fallback to default project
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (p.textDocument.uri);
            selected_project = default_project;
        }
        if (results.is_empty) {
            debug (@"[$method] failed to find file $(p.textDocument.uri)");
            reply_null (id, client, method);
            return;
        }

        CompletionEngine.begin_response (this, selected_project,
                                         client, id, method,
                                         results[0].first, results[0].second,
                                         p.position, p.context);
    }

    void textDocumentSignatureHelp (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        Project selected_project = null;
        foreach (var project in projects.get_keys_as_array ()) {
            results = project.lookup_compile_input_source_file (p.textDocument.uri);
            if (!results.is_empty) {
                selected_project = project;
                break;
            }
        }
        // fallback to default project
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (p.textDocument.uri);
            selected_project = default_project;
        }
        if (results.is_empty) {
            debug ("unknown file %s", p.textDocument.uri);
            reply_null (id, client, "textDocument/signatureHelp");
            return;
        }

        SignatureHelpEngine.begin_response (this, selected_project,
                                            client, id, method,
                                            results[0].first, results[0].second,
                                            p.position);
    }

    void textDocumentHover (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        Project selected_project = null;
        foreach (var project in projects.get_keys_as_array ()) {
            results = project.lookup_compile_input_source_file (p.textDocument.uri);
            if (!results.is_empty) {
                selected_project = project;
                break;
            }
        }
        // fallback to default project
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (p.textDocument.uri);
            selected_project = default_project;
        }
        if (results.is_empty) {
            debug (@"file `$(Uri.unescape_string (p.textDocument.uri))' not found");
            reply_null (id, client, "textDocument/hover");
            return;
        }

        Position pos = p.position;
        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, "textDocument/hover");
                return;
            }

            Vala.SourceFile doc = results[0].first;
            Compilation compilation = results[0].second;
            Vala.CodeContext.push (compilation.code_context);

            var fs = new FindSymbol (doc, pos, true);

            if (fs.result.size == 0) {
                // debug ("[textDocument/hover] no results found");
                reply_null (id, client, "textDocument/hover");
                Vala.CodeContext.pop ();
                return;
            }

            Vala.Scope scope = (new FindScope (doc, pos)).best_block.scope;
            Vala.CodeNode result = get_best (fs, doc);
            // don't show lambda expressions on hover
            // don't show property accessors
            if (result is Vala.Method && ((Vala.Method)result).closure ||
                result is Vala.PropertyAccessor) {
                reply_null (id, client, "textDocument/hover");
                Vala.CodeContext.pop ();
                return;
            }
            var hoverInfo = new Hover () {
                range = new Range.from_sourceref (result.source_reference)
            };

            // the instance's data type, used to resolve the symbol, which may be a member
            Vala.DataType? data_type = null;
            Vala.List<Vala.DataType>? method_type_arguments = null;
            Vala.Symbol? symbol = null;

            if (result is Vala.Expression) {
                var expr = (Vala.Expression) result;
                symbol = expr.symbol_reference;
                data_type = expr.value_type;
                if (symbol != null && expr is Vala.MemberAccess) {
                    var ma = (Vala.MemberAccess) expr;
                    if (ma.inner != null && ma.inner.value_type != null) {
                        // get inner's data_type, which we can use to resolve expr's generic type
                        data_type = ma.inner.value_type;
                    }
                    method_type_arguments = ma.get_type_arguments ();
                }

                // if data_type is the same as this variable's type, then this variable is not a member
                // of the type 
                // (note: this avoids variable's generic type arguments being resolved to InvalidType)
                if (symbol is Vala.Variable && data_type != null && data_type.equals (((Vala.Variable)symbol).variable_type))
                    data_type = null;
            } else if (result is Vala.Symbol) {
                symbol = (Vala.Symbol) result;
            } else if (result is Vala.DataType) {
                data_type = (Vala.DataType) result;
                symbol = ((Vala.DataType)result).symbol;
            } else {
                warning ("result as %s not matched", result.type_name);
            }

            // don't show temporary variables
            if (symbol != null && symbol.name != null && symbol.name[0] == '.' && symbol.name[1].isdigit ()) {
                if (symbol is Vala.Variable && data_type == null)
                    data_type = ((Vala.Variable)symbol).variable_type;
                symbol = null;
            }

            // debug ("(parent) data_type is %s, symbol is %s",
            //         CodeHelp.get_symbol_representation (data_type, null, scope),
            //         CodeHelp.get_symbol_representation (null, symbol, scope));

            string? representation = CodeHelp.get_symbol_representation (data_type, symbol, scope, method_type_arguments);
            if (representation != null) {
                hoverInfo.contents.add (new MarkedString () {
                    language = "vala",
                    value = representation
                });
                
                if (symbol != null) {
                    var comment = get_symbol_documentation (selected_project, symbol);
                    if (comment != null) {
                        hoverInfo.contents.add (new MarkedString () {
                            value = comment.value
                        });
                    }
                }
            }

            try {
                client.reply (id, Util.object_to_variant (hoverInfo), cancellable);
            } catch (Error e) {
                warning ("[textDocument/hover] failed to reply to client: %s", e.message);
            }

            Vala.CodeContext.pop ();
        });
    }

    DocumentHighlightKind determine_node_highlight_kind (Vala.CodeNode node) {
        Vala.CodeNode? previous_node = node;

        for (Vala.CodeNode? current_node = node.parent_node;
             current_node != null;
             current_node = current_node.parent_node,
             previous_node = current_node) {
            if (current_node is Vala.MethodCall)
                return DocumentHighlightKind.Read;
            else if (current_node is Vala.Assignment) {
                if (previous_node == ((Vala.Assignment)current_node).left)
                    return DocumentHighlightKind.Write;
                else if (previous_node == ((Vala.Assignment)current_node).right)
                    return DocumentHighlightKind.Read;
            } else if (current_node is Vala.DeclarationStatement &&
                node == ((Vala.DeclarationStatement)current_node).declaration)
                return DocumentHighlightKind.Write;
            else if (current_node is Vala.ForeachStatement &&
                node == ((Vala.ForeachStatement)current_node).element_variable)
                return DocumentHighlightKind.Write;
            else if (current_node is Vala.Statement)
                return DocumentHighlightKind.Read;
        }

        return DocumentHighlightKind.Text;
    }

    /**
     * It's possible that a symbol can be used across build targets.
     */
    static Collection<Pair<Compilation, Vala.Symbol>> get_compilations_using_symbol (Project project, Vala.Symbol sym) {
        var compilations = new ArrayList<Pair<Compilation, Vala.Symbol>> ();

        foreach (var compilation in project.get_compilations ()) {
            Vala.Symbol? matching_sym = Util.find_matching_symbol (compilation.code_context, sym);
            if (matching_sym != null)
                compilations.add (new Pair<Compilation, Vala.Symbol> (compilation, matching_sym));
        }

        return compilations;
    }

    static void list_references_in_file (Vala.SourceFile file, Vala.Symbol sym, 
                                         bool include_declaration, ArrayList<Vala.CodeNode> references) {
        var unique_srefs = new HashSet<string> ();
        if (sym is Vala.TypeSymbol) {
            var fs2 = new FindSymbol.with_filter (file, sym,
                (needle, node) => node == needle ||
                    (node is Vala.DataType && ((Vala.DataType) node).type_symbol == needle), include_declaration);
            foreach (var node in fs2.result)
                if (!(node.source_reference.to_string () in unique_srefs)) {
                    references.add (node);
                    unique_srefs.add (node.source_reference.to_string ());
                }
        }
        var fs2 = new FindSymbol.with_filter (file, sym, 
            (needle, node) => node == needle || 
                (node is Vala.Expression && ((Vala.Expression)node).symbol_reference == needle), include_declaration);
        foreach (var node in fs2.result)
            if (!(node.source_reference.to_string () in unique_srefs)) {
                references.add (node);
                unique_srefs.add (node.source_reference.to_string ());
            }
    }

    void textDocumentReferences (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<ReferenceParams>(@params);
        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        Project selected_project = null;
        foreach (var project in projects.get_keys_as_array ()) {
            results = project.lookup_compile_input_source_file (p.textDocument.uri);
            if (!results.is_empty) {
                selected_project = project;
                break;
            }
        }
        // fallback to default project
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (p.textDocument.uri);
            selected_project = default_project;
        }
        if (results.is_empty) {
            debug (@"file `$(Uri.unescape_string (p.textDocument.uri))' not found");
            reply_null (id, client, method);
            return;
        }

        Position pos = p.position;
        bool is_highlight = method == "textDocument/documentHighlight";
        bool include_declaration = p.context != null ? p.context.includeDeclaration : true;
        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            Vala.SourceFile doc = results[0].first;
            Compilation compilation = results[0].second;
            Vala.CodeContext.push (compilation.code_context);

            var fs = new FindSymbol (doc, pos, true);

            if (fs.result.size == 0) {
                debug (@"[$method] no results found");
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            Vala.CodeNode result = get_best (fs, doc);
            Vala.Symbol symbol;
            var json_array = new Json.Array ();
            var references = new Gee.ArrayList<Vala.CodeNode> ();

            if (result is Vala.Expression && ((Vala.Expression)result).symbol_reference != null)
                result = ((Vala.Expression) result).symbol_reference;
            else if (result is Vala.DataType && ((Vala.DataType)result).type_symbol != null)
                result = ((Vala.DataType) result).type_symbol;

            // ignore lambda expressions and non-symbols
            if (!(result is Vala.Symbol) ||
                result is Vala.Method && ((Vala.Method)result).closure) {
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            symbol = (Vala.Symbol) result;

            debug (@"[$method] got best: $result ($(result.type_name))");
            if (is_highlight || symbol is Vala.LocalVariable) {
                // if highlight, show references in current file
                // otherwise, we may also do this if it's a local variable, since
                // Server.get_compilations_using_symbol() only works for global symbols
                list_references_in_file (doc, symbol, include_declaration, references);
            } else {
                // show references in all files
                var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
                foreach (var btarget in selected_project.get_compilations ())
                    generated_vapis.add_all (btarget.output);
                var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
                foreach (var btarget_w_sym in Server.get_compilations_using_symbol (selected_project, symbol))
                    foreach (Vala.SourceFile project_file in btarget_w_sym.first.code_context.get_source_files ()) {
                        // don't show symbol from generated VAPI
                        var file = File.new_for_commandline_arg (project_file.filename);
                        if (file in generated_vapis || file in shown_files)
                            continue;
                        list_references_in_file (project_file, btarget_w_sym.second, include_declaration, references);
                        shown_files.add (file);
                    }
            }
            
            debug (@"[$method] found $(references.size) reference(s)");
            foreach (var node in references) {
                if (is_highlight) {
                    json_array.add_element (Json.gobject_serialize (new DocumentHighlight () {
                        range = new Range.from_sourceref (node.source_reference),
                        kind = determine_node_highlight_kind (node)
                    }));
                } else {
                    json_array.add_element (Json.gobject_serialize (new Location.from_sourceref (node.source_reference)));
                }
            }

            try {
                Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
                client.reply (id, variant_array, cancellable);
            } catch (Error e) {
                debug (@"[$method] failed to reply to client: $(e.message)");
            }

            Vala.CodeContext.pop ();
        });
    }

    void textDocumentImplementation (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<LanguageServer.TextDocumentPositionParams>(@params);
        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        Project selected_project = null;
        foreach (var project in projects.get_keys_as_array ()) {
            results = project.lookup_compile_input_source_file (p.textDocument.uri);
            if (!results.is_empty) {
                selected_project = project;
                break;
            }
        }
        // fallback to default project
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (p.textDocument.uri);
            selected_project = default_project;
        }
        if (results.is_empty) {
            debug (@"file `$(Uri.unescape_string (p.textDocument.uri))' not found");
            reply_null (id, client, method);
            return;
        }

        Position pos = p.position;
        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            Vala.SourceFile doc = results[0].first;
            Compilation compilation = results[0].second;
            Vala.CodeContext.push (compilation.code_context);

            var fs = new FindSymbol (doc, pos, true);

            if (fs.result.size == 0) {
                debug (@"[$method] no results found");
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            }

            Vala.CodeNode result = get_best (fs, doc);
            Vala.Symbol symbol;

            var json_array = new Json.Array ();
            var references = new Gee.ArrayList<Vala.CodeNode> ();

            if (result is Vala.DataType && ((Vala.DataType)result).type_symbol != null)
                result = ((Vala.DataType) result).type_symbol;

            debug (@"[$method] got best: $result ($(result.type_name))");
            bool is_abstract_type = (result is Vala.Interface) || ((result is Vala.Class) && ((Vala.Class)result).is_abstract);
            bool is_abstract_or_virtual_method = (result is Vala.Method) && 
                (((Vala.Method)result).is_abstract || ((Vala.Method)result).is_virtual);
            bool is_abstract_or_virtual_property = (result is Vala.Property) &&
                (((Vala.Property)result).is_abstract || ((Vala.Property)result).is_virtual);

            if (!is_abstract_type && !is_abstract_or_virtual_method && !is_abstract_or_virtual_property) {
                debug (@"[$method] best is neither an abstract type/interface nor abstract/virtual method/property");
                reply_null (id, client, method);
                Vala.CodeContext.pop ();
                return;
            } else {
                symbol = (Vala.Symbol) result;
            }

            // show references in all files
            var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in selected_project.get_compilations ())
                generated_vapis.add_all (btarget.output);
            var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget_w_sym in Server.get_compilations_using_symbol (selected_project, symbol)) {
                foreach (var file in btarget_w_sym.first.code_context.get_source_files ()) {
                    var gfile = File.new_for_commandline_arg (file.filename);
                    // don't show symbol from generated VAPI
                    if (gfile in generated_vapis || gfile in shown_files)
                        continue;

                    FindSymbol fs2;
                    if (is_abstract_type) {
                        fs2 = new FindSymbol.with_filter (file, btarget_w_sym.second,
                        (needle, node) => node is Vala.ObjectTypeSymbol && 
                            ((Vala.ObjectTypeSymbol)node).is_subtype_of ((Vala.ObjectTypeSymbol) needle), false);
                    } else if (is_abstract_or_virtual_method) {
                        fs2 = new FindSymbol.with_filter (file, btarget_w_sym.second,
                        (needle, node) => needle != node && (node is Vala.Method) && 
                            (((Vala.Method)node).base_method == needle ||
                            ((Vala.Method)node).base_interface_method == needle), false);
                    } else {
                        fs2 = new FindSymbol.with_filter (file, symbol,
                        (needle, node) => needle != node && (node is Vala.Property) &&
                            (((Vala.Property)node).base_property == needle ||
                            ((Vala.Property)node).base_interface_property == needle), false);
                    }
                    references.add_all (fs2.result);
                    shown_files.add (gfile);
                }
            }

            debug (@"[$method] found $(references.size) reference(s)");
            foreach (var node in references) {
                Vala.CodeNode real_node = node;
                if (node is Vala.Symbol)
                    real_node = find_real_sym (selected_project, (Vala.Symbol) node);
                json_array.add_element (Json.gobject_serialize (new Location.from_sourceref (real_node.source_reference)));
            }

            try {
                Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
                client.reply (id, variant_array, cancellable);
            } catch (Error e) {
                debug (@"[$method] failed to reply to client: $(e.message)");
            }

            Vala.CodeContext.pop ();
        });
    }

    // TODO: avoid recreating SymbolInformation unless the compilation has changed?
    void workspaceSymbol (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var query = (string) @params.lookup_value ("query", VariantType.STRING);

        wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            var json_array = new Json.Array ();
            Project[] all_projects = projects.get_keys_as_array ();
            all_projects += default_project;
            foreach (var project in all_projects) {
                foreach (var text_document in project.get_project_source_files ()) {
                    Vala.CodeContext.push (text_document.context);
                    new ListSymbols (text_document)
                        .flattened ()
                        // NOTE: if introspection for g_str_match_string () / string.match_string ()
                        // is fixed, this will have to be changed to `dsym.name.match_sting (query, true)`
                        .filter (dsym => query.match_string (dsym.name, true))
                        .foreach (dsym => {
                            var si = new SymbolInformation.from_document_symbol (dsym, 
                                File.new_for_commandline_arg_and_cwd (text_document.filename, project.root_path).get_uri ());
                            json_array.add_element (Json.gobject_serialize (si));
                            return true;
                        });
                    Vala.CodeContext.pop ();
                }
            }

            debug (@"[$method] found $(json_array.get_length ()) element(s) matching `$query'");
            try {
                Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
                client.reply (id, variant_array, cancellable);
            } catch (Error e) {
                debug (@"[$method] failed to reply to client: $(e.message)");
            }
        });
    }

    void shutdown (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        reply_null (id, client, "shutdown");
        shutdown_real ();
    }

    void exit (Jsonrpc.Client client, Variant @params) {
        shutdown_real ();
    }

    void shutdown_real () {
        debug ("shutting down...");
        this.shutting_down = true;
        cancellable.cancel ();
        if (client_closed_event_id != 0)
            server.disconnect (client_closed_event_id);
        foreach (var project in projects.get_keys_as_array ())
            project.disconnect (projects[project]);
        loop.quit ();
        foreach (uint id in g_sources)
            Source.remove (id);
    }
}

void main () {
    var loop = new MainLoop ();
    new Vls.Server (loop);
    loop.run ();
}
