/* server.vala
 *
 * Copyright 2017-2019 Ben Iofel <ben@iofel.me>
 * Copyright 2017-2020 Princeton Ferro <princetonferro@gmail.com>
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

using Lsp;
using Gee;

class Vls.Server : Jsonrpc.Server {
    private static bool received_signal = false;
    MainLoop loop;

    InitializeParams init_params;

    const uint CHECK_UPDATE_CONTEXT_PERIOD_MS = 100;
    const int UPDATE_CONTEXT_DELAY_INC_MS = 500;
    const int UPDATE_CONTEXT_DELAY_MAX_MS = 1000;

    /**
     * Contains documentation from found GIR files.
     */
    GirDocumentation documentation;

    /**
     * Maps a variant ID to a request that was made.
     */
    HashMap<Variant, Request> pending_requests;

    bool shutting_down = false;

    /**
     * The global cancellable object
     */
    public static Cancellable cancellable = new Cancellable ();

    uint[] g_sources = {};
    ulong client_closed_event_id;
    HashTable<Project, ulong> projects;
    DefaultProject? default_project;

    /**
     * Contains files that have been closed and should no longer be managed
     * by VLS. This is used to clear the errors/warnings for the files on
     * the next context update.
     */
    HashSet<string> discarded_files = new HashSet<string> ();

    /**
     * Files that are currently open in the editor
     */
    HashSet<string> open_files = new HashSet<string> ();

    /**
     * Use this in projects to keep track of target outputs and avoid
     * rebuilding dependent targets.
     */
    FileCache file_cache = new FileCache ();

    /**
     * A scheduler for all operations to shared resources.
     */
    Scheduler scheduler;

    static construct {
        Process.@signal (ProcessSignal.INT, () => {
            Server.received_signal = true;
        });
        Process.@signal (ProcessSignal.TERM, () => {
            Server.received_signal = true;
        });
    }

    public Server (MainLoop loop) throws ThreadError {
        this.loop = loop;

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
            warning ("failed to set FDs to nonblocking");
            loop.quit ();
            return;
        }
#endif

        // create the work scheduler
        scheduler = new Scheduler ();
        pending_requests = new HashMap<Variant, Request> (Request.variant_id_hash, Request.variant_id_equal);
        this.projects = new HashTable<Project, ulong> (GLib.direct_hash, GLib.direct_equal);

        // check for tasks in all workers and schedule them
        g_sources += Timeout.add (50, process_work);

        // set up LSP handlers
        notification.connect (notification_async);
        handle_call.connect ((client, method, id, parameters) => {
            handle_call_async.begin (client, method, id, parameters);
            return true;
        });

        accept_io_stream (new SimpleIOStream (input_stream, output_stream));

        debug ("Finished constructing");
    }

    async void notification_async (Jsonrpc.Client client, string method, Variant parameters) {
        try {
            switch (method) {
                case "exit":
                    exit ();
                    break;

                case "$/cancelRequest":
                    cancel_request (client, parameters);
                    break;

                case "textDocument/didOpen":
                    yield text_document_did_open (client, parameters);
                    break;

                case "textDocument/didSave":
                    text_document_did_save (client, parameters);
                    break;

                case "textDocument/didClose":
                    yield text_document_did_close (client, parameters);
                    break;

                case "textDocument/didChange":
                    text_document_did_change (client, parameters);
                    break;

                default:
                    warning ("unhandled notification `%s'", method);
                    break;
            }
        } catch (Error e) {
            warning ("[%s] error handling notification: %s", method, e.message);
        }
    }

    async void handle_call_async (Jsonrpc.Client client, string method, Variant id, Variant parameters) {
        try {
            switch (method) {
                case "initialize":
                    yield initialize (client, method, id, parameters);
                    break;

                case "shutdown":
                    shutdown ();
                    yield reply_null_async (id, client, cancellable);
                    break;

                case "textDocument/definition":
                    yield goto_definition (client, method, id, parameters);
                    break;

                case "textDocument/documentSymbol":
                    yield document_symbol_outline (client, method, id, parameters);
                    break;

                case "textDocument/completion":
                    yield show_completion (client, method, id, parameters);
                    break;

                case "textDocument/signatureHelp":
                    yield show_signature_help (client, method, id, parameters);
                    break;

                case "textDocument/hover":
                    yield hover (client, method, id, parameters);
                    break;

                case "textDocument/formatting":
                case "textDocument/rangeFormatting":
                    yield format (client, method, id, parameters);
                    break;

                case "textDocument/codeAction":
                    yield code_action (client, method, id, parameters);
                    break;

                case "textDocument/references":
                case "textDocument/documentHighlight":
                    yield show_references (client, method, id, parameters);
                    break;
                    
                case "textDocument/implementation":
                    yield show_implementations (client, method, id, parameters);
                    break;

                case "workspace/symbol":
                    yield search_workspace_symbols (client, method, id, parameters);
                    break;

                case "textDocument/rename":
                    yield rename_symbol (client, method, id, parameters);
                    break;

                case "textDocument/prepareRename":
                    yield prepare_rename_symbol (client, method, id, parameters);
                    break;

                case "textDocument/codeLens":
                    yield code_lens (client, method, id, parameters);
                    break;

                case "textDocument/prepareCallHierarchy":
                    yield prepare_call_hierarchy (client, method, id, parameters);
                    break;

                case "callHierarchy/incomingCalls":
                    yield call_hierarchy_incoming_calls (client, method, id, parameters);
                    break;

                case "callHierarchy/outgoingCalls":
                    yield call_hierarchy_outgoing_calls (client, method, id, parameters);
                    break;

                default:
                    warning ("unhandled call `%s'", method);
                    break;
            }
        } catch (IOError.CANCELLED e) {
            Request? request = pending_requests[id];
            debug ("replying null for cancelled request %s", request != null ? request.to_string () : "");
            try {
                yield reply_null_async (id, client, cancellable);
            } catch (Error e) {
                warning ("[%s] failed to reply to client", method);
            }
        } catch (Error e) {
            try {
                yield client.reply_error_async (id, Jsonrpc.ClientError.INTERNAL_ERROR, e.message, cancellable);
            } catch (Error e) {
                warning ("[%s] failed to reply to client", method);
            }
        }

        pending_requests.unset (id);
    }

    protected override void client_accepted (Jsonrpc.Client client) {
        update_context_client = client;
    }

#if WITH_JSONRPC_GLIB_3_30
    protected override void client_closed (Jsonrpc.Client client) {
        shutdown ();
        exit ();
    }
#endif

    /**
     * Schedule tasks and check for a termination signal.
     */
    bool process_work () {
        // shutdown if we get a signal
        if (Server.received_signal) {
            shutdown ();
            exit ();
            return Source.REMOVE;
        }

        // schedule tasks for all project workers
        Project[] all_projects = projects.get_keys_as_array ();
        if (default_project != null)
            all_projects += default_project;
        foreach (var project in all_projects) {
            try {
                project.worker.enqueue_tasks (scheduler);
            } catch (ThreadError e) {
                warning ("could not schedule tasks for project %s: %s", project.to_string (), e.message);
            }
            // schedule tasks for all source file workers
            foreach (var compilation in project) {
                foreach (SourceFileWorker worker in compilation) {
                    try {
                        worker.enqueue_tasks (scheduler);
                    } catch (ThreadError e) {
                        // don't reference the source file here as it may be disposed
                        warning ("could not schedule tasks for source file: %s", e.message);
                    }
                }
            }
        }

        // process scheduler wait list
        try {
            scheduler.process_waitlist ();
        } catch (ThreadError e) {
            warning ("could not process scheduler wait list due to threading error: %s", e.message);
        }
        return !this.shutting_down;
    }

    // a{sv} only
    public Variant build_dict (...) {
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

    /**
     * Find a file with a URI. Will pick the first match.
     *
     * @param uri       the URI of the file. may contain escape characters
     */
    SourceFileWorker? find_file (string uri, out Compilation? compilation = null, out Project? project = null) throws Error {
        var results = new ArrayList<Pair<SourceFileWorker, Compilation>> ();
        Project? selected_project = null;
        foreach (var p in projects.get_keys_as_array ()) {
            results = p.lookup_compile_input_source_file (uri);
            if (!results.is_empty) {
                selected_project = p;
                break;
            }
        }
        // fallback to default project
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (uri);
            if (!results.is_empty)
                selected_project = default_project;
        }

        if (selected_project != null) {
            project = selected_project;
            compilation = results[0].second;
            return results[0].first;
        }

        project = null;
        compilation = null;
        return null;
    }

    async void show_message_async (Jsonrpc.Client client, string message, MessageType type) {
        if (type == MessageType.Error)
            warning (message);
        try {
            yield client.send_notification_async ("window/showMessage", build_dict (
                type: new Variant.int16 (type),
                message: new Variant.string (message)
            ), cancellable);
        } catch (Error e) {
            debug (@"showMessage: failed to notify client: $(e.message)");
        }
    }

    async void initialize (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        init_params = Util.parse_variant<InitializeParams> (@params);

        File root_dir;
        if (init_params.rootUri != null)
            root_dir = File.new_for_uri (init_params.rootUri);
        else if (init_params.rootPath != null)
            root_dir = File.new_for_path (init_params.rootPath);
        else
            root_dir = File.new_for_path (Environment.get_current_dir ());
        if (!root_dir.is_native ()) {
            yield show_message_async (client, "Non-native files not supported", MessageType.Error);
            error ("Non-native files not supported");
        }
        string root_path = Util.realpath ((!) root_dir.get_path ());
        debug (@"[initialize] root path is $root_path");

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
                backend_project = new MesonProject (root_path, file_cache, cancellable);
            } catch (Error e) {
                if (!(e is ProjectError.VERSION_UNSUPPORTED)) {
                    yield show_message_async (client, @"Failed to initialize Meson project - $(e.message)", MessageType.Error);
                }
            }
        }
        
        // try compile_commands.json if Meson failed
        if (backend_project == null && !cc_files.is_empty) {
            foreach (var cc_file in cc_files) {
                string cc_file_path = Util.realpath (cc_file.get_path ());
                try {
                    backend_project = new CcProject (root_path, cc_file_path, file_cache, cancellable);
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
                yield show_message_async (client, @"CMake build system is not currently supported. Only Meson is. See https://github.com/vala-lang/vala-language-server/issues/73", MessageType.Warning);
            if (autogen_sh.query_exists (cancellable))
                yield show_message_async (client, @"Autotools build system is not currently supported. Consider switching to Meson.", MessageType.Warning);
        } else {
            new_projects.add (backend_project);
        }

        // always have default project
        default_project = new DefaultProject (root_path, file_cache);
        default_project.worker.update (ProjectWorker.Status.COMPLETE);

        // create initial empty documentation
        var packages = new HashSet<Vala.SourceFile> ();
        var custom_gir_dirs = new HashSet<File> (Util.file_hash, Util.file_equal);
        documentation = new GirDocumentation (packages, custom_gir_dirs);

        // respond early
        try {
            yield client.reply_async (id, build_dict (
                capabilities: build_dict (
                    textDocumentSync: new Variant.int16 (TextDocumentSyncKind.Incremental),
                    definitionProvider: new Variant.boolean (true),
                    documentSymbolProvider: new Variant.boolean (true),
                    completionProvider: build_dict(
                        triggerCharacters: new Variant.strv (new string[] {".", ">"})
                    ),
                    signatureHelpProvider: build_dict(
                        triggerCharacters: new Variant.strv (new string[] {"(", "[", ","})
                    ),
                    codeActionProvider: new Variant.boolean (true),
                    hoverProvider: new Variant.boolean (true),
                    referencesProvider: new Variant.boolean (true),
                    documentHighlightProvider: new Variant.boolean (true),
                    documentFormattingProvider: new Variant.boolean (true),
                    documentRangeFormattingProvider: new Variant.boolean (true),
                    implementationProvider: new Variant.boolean (true),
                    workspaceSymbolProvider: new Variant.boolean (true),
                    renameProvider: build_dict (prepareProvider: new Variant.boolean (true)),
                    codeLensProvider: build_dict (resolveProvider: new Variant.boolean (false)),
                    callHierarchyProvider: new Variant.boolean (true)
                ),
                serverInfo: build_dict (
                    name: new Variant.string ("Vala Language Server"),
                    version: new Variant.string (Config.PROJECT_VERSION)
                )
            ), cancellable);
        } catch (Error e) {
            error (@"[initialize] failed to reply to client: $(e.message)");
        }

        // build and publish diagnostics
        // no need to use the scheduler as these projects have not been
        // committed yet
        foreach (var project in new_projects) {
            try {
                projects[project] = 0;
                debug ("Building project ...");
                yield project.worker.run_not_configured<void> (() => project.build_if_stale (cancellable), true);
                project.worker.update (ProjectWorker.Status.COMPLETE);
                // update the project worker status
                debug ("Publishing diagnostics ...");
                foreach (var compilation in project)
                    yield publish_diagnostics_async (project, compilation, client);
            } catch (Error e) {
                yield show_message_async (client, @"Failed to build project - $(e.message)", MessageType.Error);
            }
        }

        // create documentation (compiles GIR files too)
        foreach (var project in new_projects) {
            packages.add_all (project.get_packages ());
            custom_gir_dirs.add_all (project.get_custom_gir_dirs ());
        }
        documentation = new GirDocumentation (packages, custom_gir_dirs);

        // listen for context update requests
        update_context_client = client;
        check_update_context.begin ();  // begin long-running async task

        // commit the projects and listen for changed events
        foreach (Project project in new_projects)
            projects[project] = project.changed.connect (project_changed_event);
    }

    void project_changed_event () {
        request_context_update ();
        // debug ("requested context update for project change event");
    }

    void cancel_request (Jsonrpc.Client client, Variant @params) {
        Variant? id = @params.lookup_value ("id", null);
        if (id == null)
            return;

        if (!(id.is_of_type (VariantType.INT64) || id.is_of_type (VariantType.STRING))) {
            warning ("[$/cancelRequest] got ID that wasn't an int64 or string");
            return;
        }

        Request request;
        if (pending_requests.unset (id, out request)) {
            request.cancel ();
            debug ("cancelled request %s", request.to_string ());
        }
    }

    static async void reply_null_async (Variant id, Jsonrpc.Client client, Cancellable? cancellable) throws Error {
        yield client.reply_async (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
    }

    static async void reply_object_async (Variant id, Jsonrpc.Client client, Object object, Cancellable? cancellable) throws Error {
        yield client.reply_async (id, Util.object_to_variant (object), cancellable);
    }

    async void text_document_did_open (Jsonrpc.Client client, Variant @params) throws Error {
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

        Pair<SourceFileWorker, Compilation>? doc_w_bt = null;

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
                doc_w_bt = yield default_project.worker.run<Pair<SourceFileWorker, Compilation>> (
                    () => default_project.open (uri, fileContents, cancellable).first (),
                    true
                );
                default_project.worker.update (ProjectWorker.Status.COMPLETE);
                // it's possible that we opened a Vala script and have to
                // include additional packages for documentation
                foreach (var pkg in default_project.get_packages ())
                    documentation.add_package_from_source_file (pkg);
                // show diagnostics for the newly-opened file
                request_context_update ();
            } catch (Error e) {
                warning ("[textDocumnt/didOpen] failed to open %s - %s", Uri.unescape_string (uri), e.message);
            }
        }

        if (doc_w_bt == null) {
            warning ("[textDocument/didOpen] could not open %s", uri);
            return;
        }

        var worker = doc_w_bt.first;
        // We want to load the document unconditionally, to avoid
        // errors later on in textDocument/didChange. However, we
        // only want to edit it if it is an actual TextDocument.
        if (worker.source_file is TextDocument) {
            var tdoc = (TextDocument) worker.source_file;
            debug (@"[textDocument/didOpen] opened $(Uri.unescape_string (uri))"); 
            worker.acquire (cancellable);
            tdoc.last_saved_content = fileContents;
            if (tdoc.content != fileContents) {
                tdoc.content = fileContents;
                debug ("restore file contents");
            }
            worker.release (cancellable);
        } else {
            debug (@"[textDocument/didOpen] opened read-only $(Uri.unescape_string (uri))");
        }

        // add document to open list
        open_files.add (uri);
    }

    void text_document_did_save (Jsonrpc.Client client, Variant @params) throws Error {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);

        string? uri = (string) document.lookup_value ("uri", VariantType.STRING);
        if (uri == null) {
            warning (@"[textDocument/didSave] null URI sent to vala language server");
            return;
        }

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;

        foreach (var project in all_projects) {
            var results = project.lookup_compile_input_source_file (uri);
            foreach (var pair in results) {
                var worker = pair.first;
                var text_document = worker.source_file as TextDocument;

                if (text_document == null) {
                    warning ("[textDocument/didSave] ignoring save to system file");
                    continue;
                }

                // attempt to make checkpoint
                worker.acquire (cancellable);
                text_document.last_saved_content = text_document.content;
                worker.release (cancellable);
            }
        }
        debug ("saved text document %s", Uri.unescape_string (uri));
    }

    async void text_document_did_close (Jsonrpc.Client client, Variant @params) throws Error {
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
                if (project.close (uri, cancellable)) {
                    discarded_files.add (uri);
                    request_context_update ();
                    debug (@"[textDocument/didClose] requested context update");
                }
                debug ("[textDocument/didClose] closed %s", uri);
            } catch (Error e) {
                if (!(e is ProjectError.NOT_FOUND))
                    warning ("[textDocument/didClose] failed to close %s - %s", Uri.unescape_string (uri), e.message);
            }
        }

        debug ("closed text document %s", Uri.unescape_string (uri));
    }

    Jsonrpc.Client? update_context_client = null;
    int update_context_requests = 0;
    int update_context_time_ms = 0;

    void text_document_did_change (Jsonrpc.Client client, Variant @params) throws Error {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        var changes = @params.lookup_value ("contentChanges", VariantType.ARRAY);

        var uri = (string) document.lookup_value ("uri", VariantType.STRING);
        var version = (int64) document.lookup_value ("version", VariantType.INT64);

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;

        foreach (var project in all_projects) {
            var results = project.lookup_compile_input_source_file (uri);
            foreach (var pair in results) {
                var worker = pair.first;
                var source_file = worker.source_file;

                if (!(source_file is TextDocument)) {
                    warning (@"[textDocument/didChange] Ignoring change to system file");
                    return;
                }

                var source = (TextDocument) source_file;
                if (source.version >= version) {
                    warning (@"[textDocument/didChange] rejecting outdated version of $(Uri.unescape_string (uri))");
                    return;
                }

                worker.acquire (cancellable);
                var sb = new StringBuilder (source.content);
                var iter = changes.iterator ();
                Variant? elem = null;
                while ((elem = iter.next_value ()) != null) {
                    var change = Util.parse_variant<TextDocumentContentChangeEvent> (elem);
                    if (change.range == null) {
                        sb.assign (change.text);
                    } else {
                        var start = change.range.start;
                        var end = change.range.end;
                        size_t pos_begin = Util.get_string_pos (sb.str, start.line, start.character);
                        size_t pos_end = Util.get_string_pos (sb.str, end.line, end.character);
                        sb.erase ((ssize_t) pos_begin, (ssize_t) (pos_end - pos_begin));
                        sb.insert ((ssize_t) pos_begin, change.text);
                    }

                }
                source.content = sb.str;
                source.version = (int)version;
                source.last_updated = new DateTime.now ();
                worker.release (cancellable);

                debug ("source for %s => \n---\n%s\n---\n", source.filename, source.content);

                request_context_update ();
            }
        }
    }

    /** 
     * Indicate to the server that the code context(s) it is tracking may
     * need to be refreshed.
     */
    void request_context_update () {
        // debouncing
        int requests = AtomicInt.get (ref update_context_requests);
        int delay_ms = int.min (UPDATE_CONTEXT_DELAY_INC_MS * requests, UPDATE_CONTEXT_DELAY_MAX_MS);
        AtomicInt.set (ref update_context_time_ms, (int)(get_monotonic_time ()/1000) + delay_ms);
        AtomicInt.inc (ref update_context_requests);
    }

    /**
     * Wait a certain length of time.
     */
    static async void wait_async (uint time_ms) {
        Timeout.add (time_ms, wait_async.callback);
        yield;
    }

    /** 
     * Checks whether we need to rebuild the project and documentation engine
     * if we have context update requests. Will run until the server receives a
     * shutdown request.
     */
    async void check_update_context () {
        while (!this.shutting_down) {
            int requests = AtomicInt.get (ref update_context_requests);
            int update_time = AtomicInt.get (ref update_context_time_ms);
            if (requests > 0 && (int)(get_monotonic_time ()/1000) >= update_time) {
                debug ("updating contexts and publishing diagnostics...");
                AtomicInt.add (ref update_context_requests, -requests);

                // update all projects first
                Project[] all_projects = projects.get_keys_as_array ();
                all_projects += default_project;
                bool reconfigured_projects = false;
                foreach (var project in all_projects) {
                    try {
                        // schedule the expensive rebuilding of the whole project off the main thread,
                        // and suspend ourselves until it completes or is cancelled
                        debug ("1. reconfiguring project ...");
                        project.worker.update (ProjectWorker.Status.NOT_CONFIGURED);
                        bool reconfigured = yield project.worker.run_not_configured<bool> (
                            () => project.reconfigure_if_stale (cancellable),
                            true,
                            ProjectWorker.Status.CONFIGURED
                        );
                        debug ("2. recompiling project ...");
                        yield project.worker.run_configured<void> (
                            () => project.build_if_stale (),
                            true,
                            ProjectWorker.Status.COMPLETE
                        );
                        reconfigured_projects |= reconfigured;

                        // remove all newly-added files from the default project
                        if (reconfigured && project != default_project) {
                            var newly_added = new HashSet<string> ();
                            foreach (var compilation in project)
                                newly_added.add_all_iterator (compilation.iterator ().map<string> (w => w.source_file.filename));
                            foreach (var compilation in default_project) {
                                foreach (var w in compilation) {
                                    if (newly_added.contains (w.source_file.filename)) {
                                        var uri = File.new_for_path (w.source_file.filename).get_uri ();
                                        try {
                                            debug ("3. closing default project ...");
                                            default_project.close (uri, cancellable);
                                            discarded_files.add (uri);
                                            debug ("discarding %s from DefaultProject", uri);
                                        } catch (Error e) {
                                            // just ignore
                                        }
                                    }
                                }
                            }
                        }

                        debug ("4. publishing diagnostics ...");
                        foreach (var compilation in project)
                            yield publish_diagnostics_async (project, compilation, update_context_client);
                    } catch (Error e) {
                        warning ("Failed to rebuild and/or reconfigure project: %s", e.message);
                        yield show_message_async (update_context_client, @"Failed to rebuild/reconfigure project: $(e.message)", MessageType.Error);
                    }
                }

                // add open files that do not belong to any project to the default project
                if (reconfigured_projects) {
                    var orphaned_files = new HashSet<string> ();
                    orphaned_files.add_all (open_files);
                    foreach (var project in projects.get_keys ()) {
                        foreach (var compilation in project) {
                            foreach (var w in compilation) {
                                var uri = File.new_for_path (w.source_file.filename).get_uri ();
                                orphaned_files.remove (uri);
                            }
                        }
                    }
                    foreach (var uri in orphaned_files) {
                        try {
                            var opened = default_project.open (uri, null, cancellable).first ();
                            var worker = opened.first;
                            var doc = worker.source_file as TextDocument;
                            if (doc != null) {
                                // ensure the file's contents are available
                                debug ("5. updating text document content ...");
                                worker.acquire (cancellable);
                                doc.last_saved_content = doc.content;
                                worker.release (cancellable);
                            }
                            yield publish_diagnostics_async (default_project, opened.second, update_context_client);
                        } catch (Error e) {
                            warning ("Failed to reopen in default project %s - %s", uri, e.message);
                            // clear the diagnostics for the file
                            try {
                                debug ("6. publishing diagnostics for text document...");
                                yield update_context_client.send_notification_async (
                                    "textDocument/publishDiagnostics",
                                    build_dict (
                                        uri: new Variant.string (uri),
                                        diagnostics: new Variant.array (VariantType.VARIANT, {})
                                    ),
                                    cancellable
                                );
                            } catch (Error e) {
                                warning ("Failed to clear diagnostics for %s - %s", uri, e.message);
                            }
                        }
                    }
                }

                debug ("7. rebuilding documentation ...");
                // rebuild the documentation
                documentation.rebuild_if_stale ();

                debug ("8. done");
            }

            yield wait_async (CHECK_UPDATE_CONTEXT_PERIOD_MS);
        }
    }

    public delegate void OnContextUpdatedFunc (bool request_cancelled);

    async void publish_diagnostics_async (Project project, Compilation target, Jsonrpc.Client client) {
        var diags_without_source = new Json.Array ();

        // debug ("publishing diagnostics for Compilation target %s", target.id);

        var doc_diags = new HashMap<Vala.SourceFile, Json.Array?> ();
        foreach (var w in target)
            doc_diags[w.source_file] = null;

        target.reporter.messages.foreach (err => {
            if (err.loc == null) {
                diags_without_source.add_element (Json.gobject_serialize (new Diagnostic () {
                    range = new Range () {
                        start = new Position () {
                            line = 1,
                            character = 1
                        },
                        end = new Position () {
                            line = 1,
                            character = 1
                        }
                    },
                    severity = err.severity,
                    message = err.message
                }));
                return true;
            }
            assert (err.loc.file != null);
            if (!target.iterator ().any_match (w => err.loc.file == w.source_file)) {
                warning (@"diagnostic has source not in compilation! - $(err.message)");
                return true;
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
            if (!doc_diags.has_key (err.loc.file) || doc_diags[err.loc.file] == null)
                doc_diags[err.loc.file] = new Json.Array ();
            doc_diags[err.loc.file].add_element (node);
            return true;
        });

        // first, publish empty diagnostics for discarded files
        var discarded_files_published = new ArrayList<string> ();
        foreach (string discarded_uri in discarded_files) {
            try {
                yield client.send_notification_async (
                    "textDocument/publishDiagnostics",
                    build_dict (
                        uri: new Variant.string (discarded_uri),
                        diagnostics: new Variant.array (VariantType.VARIANT, {})
                    ),
                    cancellable
                );
                discarded_files_published.add (discarded_uri);
            } catch (Error e) {
                warning ("[publishDiagnostics] failed to publish empty diags for %s: %s", discarded_uri, e.message);
            }
        }
        discarded_files.remove_all (discarded_files_published);

        // report diagnostics for each source file that has diagnostics
        foreach (var entry in doc_diags.entries) {
            Variant diags_variant_array;
            var gfile = File.new_for_commandline_arg_and_cwd (entry.key.filename, target.directory);

            if (entry.value != null) {
                try {
                    diags_variant_array = Json.gvariant_deserialize (
                        new Json.Node.alloc ().init_array (entry.value),
                        null);
                } catch (Error e) {
                    warning (@"[publishDiagnostics] failed to deserialize diags for `$(gfile.get_uri ())': $(e.message)");
                    continue;
                }
            } else {
                diags_variant_array = new Variant.array (VariantType.VARIANT, new Variant[]{});
            }

            try {
                yield client.send_notification_async (
                    "textDocument/publishDiagnostics",
                    build_dict (
                        uri: new Variant.string (gfile.get_uri ()),
                        diagnostics: diags_variant_array
                    ),
                    cancellable
                );
            } catch (Error e) {
                warning (@"[publishDiagnostics] failed to notify client: $(e.message)");
            }
        }

        try {
            Variant diags_wo_src_variant_array = Json.gvariant_deserialize (
                new Json.Node.alloc ().init_array (diags_without_source),
                null);
            yield client.send_notification_async (
                "textDocument/publishDiagnostics",
                build_dict (
                    // use the project root as the URI if the diagnostic is not associated with a file
                    uri: new Variant.string (File.new_for_path(project.root_path).get_uri ()),
                    diagnostics: diags_wo_src_variant_array
                ),
                cancellable
            );
        } catch (Error e) {
            warning (@"[publishDiagnostics] failed to publish diags without source: $(e.message)");
        }
    }

    public static Vala.CodeNode get_best (NodeSearch fs, Vala.SourceFile file) {
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
                    (best is Vala.Field && node is Vala.Property) ||
                    // allow exception for null literals which for some reason are created over async methods that are accessed
                    (best is Vala.NullLiteral && node is Vala.Method)
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

    async void goto_definition (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams> (@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Compilation compilation;
        Project project;
        SourceFileWorker? w = find_file (p.textDocument.uri, out compilation, out project);

        if (w == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var location = yield project.worker.run<Location?> (() => {
            request.set_error_if_cancelled ();

            Vala.CodeContext.push (compilation.context);
            var fs = new NodeSearch (w.source_file, p.position, true);

            if (fs.result.size == 0) {
                debug ("[%s] find symbol is empty", method);
                Vala.CodeContext.pop ();
                return null;
            }

            Vala.CodeNode? best = get_best (fs, w.source_file);

            if (best is Vala.Expression && !(best is Vala.Literal)) {
                var b = (Vala.Expression)best;
                debug ("best (%p) is a Expression (symbol_reference = %p)", best, b.symbol_reference);
                if (b.symbol_reference != null && b.symbol_reference.source_reference != null) {
                    best = b.symbol_reference;
                    debug ("best is now the symbol_referenece => %p (%s)", best, best.to_string ());
                }
            } else if (best is Vala.DataType) {
                best = SymbolReferences.get_symbol_data_type_refers_to ((Vala.DataType) best);
            } else if (best is Vala.UsingDirective) {
                best = ((Vala.UsingDirective)best).namespace_symbol;
            } else if (best is Vala.Method) {
                var m = (Vala.Method)best;

                if (m.base_interface_method != m && m.base_interface_method != null)
                    best = m.base_interface_method;
                else if (m.base_method != m && m.base_method != null)
                    best = m.base_method;
            } else if (best is Vala.Property) {
                var prop = (Vala.Property)best;

                if (prop.base_interface_property != prop && prop.base_interface_property != null)
                    best = prop.base_interface_property;
                else if (prop.base_property != prop && prop.base_property != null)
                    best = prop.base_property;
            } else {
                debug ("[%s] best is %s, which we can't handle", method, best != null ? best.type_name : null);
                Vala.CodeContext.pop ();
                return null;
            }

            if (best is Vala.Symbol)
                best = SymbolReferences.find_real_symbol (project, (Vala.Symbol) best);

            Vala.CodeContext.pop ();
            return new Location.from_sourceref (best.source_reference);
        }, false);

        if (location != null) {
            debug ("[textDocument/definition] found location ... %s", location.uri);
            yield reply_object_async (id, client, location, cancellable);
        } else {
            yield reply_null_async (id, client, cancellable);
        }
    }

    async void document_symbol_outline (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        // debug ("[%s] beginning request ...", request.to_string ());

        Compilation compilation;
        Project project;
        SourceFileWorker? file_worker = find_file (p.textDocument.uri, out compilation, out project);

        if (file_worker == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        // debug ("[%s] queueing on source file worker ...", request.to_string ());
        var result = yield file_worker.run_symbols_resolved<Variant> (() => {
            // debug ("... [%s] running on source file worker ...", request.to_string ());
            request.set_error_if_cancelled ();

            Variant[] symbols = {};
            var syms = compilation.get_analysis_for_file<SymbolEnumerator> (file_worker.source_file);
            if (init_params.capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport)
                foreach (var dsym in syms) {
                    // debug(@"found $(dsym.name)");
                    symbols += Util.object_to_variant (dsym);
                }
            else {
                var dsym_it = syms.flattened ();
                while (dsym_it.next ())
                    symbols += Util.object_to_variant (dsym_it.get ());
            }

            return new Variant.array (VariantType.VARDICT, symbols);
        }, false);
        // debug ("[%s] ... done!", request.to_string ());

        yield client.reply_async (id, result, cancellable);
    }

    public DocComment? get_symbol_documentation (Project project, Vala.Symbol sym) {
        Compilation compilation = null;
        Vala.Symbol real_sym = SymbolReferences.find_real_symbol (project, sym);
        sym = real_sym;
        Vala.Symbol root = null;
        for (var node = sym; node != null; node = node.parent_symbol)
            root = node;
        assert (root != null);
        foreach (var project_compilation in project) {
            if (project_compilation.context.root == root) {
                compilation = project_compilation;
                break;
            }
        }

        if (compilation == null)
            return null;

        Vala.Comment? comment = null;
        DocComment? doc_comment = null;
        var gir_sym = documentation.find_gir_symbol (sym);
        if (gir_sym != null && gir_sym.comment != null)
            comment = gir_sym.comment;
        else
            comment = sym.comment;

        if (comment != null) {
            try {
                if (comment is Vala.GirComment || gir_sym != null && gir_sym.comment == comment)
                    doc_comment = new DocComment.from_gir_comment (comment, documentation, compilation);
                else
                    doc_comment = new DocComment.from_valadoc_comment (comment, sym, compilation);
            } catch (RegexError e) {
                warning ("failed to render comment - %s", e.message);
            }
        }

        if (doc_comment == null && sym is Vala.Parameter) {
            var parent_doc = get_symbol_documentation (project, sym.parent_symbol);
            if (parent_doc != null) {
                string? doc = parent_doc.parameters[sym.name];
                if (doc != null)
                    doc_comment = new DocComment (doc);
            }
        }

        return doc_comment;
    }

    async void show_completion (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<Lsp.CompletionParams>(@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Compilation compilation;
        Project project;
        SourceFileWorker? worker = find_file (p.textDocument.uri, out compilation, out project);
        if (worker == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        // we need to be after semantic analysis because after then our member
        // accesses will be resolved
        var result = yield worker.run_semantics_analyzed<Variant> (() => {
            var completions = CompletionEngine.complete (this, project,
                                                         client, id, method,
                                                         worker.source_file, compilation,
                                                         p, request);
            Variant[] completions_va = {};
            foreach (var item in completions)
                completions_va += Util.object_to_variant (item);
            return new Variant.array (VariantType.VARDICT, completions_va);
        }, false);

        yield client.reply_async (id, result, cancellable);
    }

    async void show_signature_help (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Compilation compilation;
        Project project;
        SourceFileWorker? worker = find_file (p.textDocument.uri, out compilation, out project);
        if (worker == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var result = yield worker.run_semantics_analyzed<Variant> (() => {
            int active_param;
            var signatures = SignatureHelpEngine.extract (this, project,
                                                          client, id, method,
                                                          worker.source_file, compilation,
                                                          p.position, out active_param,
                                                          request);
            return Util.object_to_variant (new SignatureHelp () {
                signatures = signatures,
                activeParameter = active_param
            });
        }, false);

        yield client.reply_async (id, result, cancellable);
    }

    async void hover (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        // debug ("[%s] beginning request ...", request.to_string ());

        Position pos = p.position;
        Compilation compilation;
        Project project;
        SourceFileWorker? worker = find_file (p.textDocument.uri, out compilation, out project);
        if (worker == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        // debug ("[%s] queueing on source file worker ...", request.to_string ());
        var hover_info = yield worker.run_symbols_resolved<Hover?> (() => {
            // debug ("... [%s] running on source file worker ...", request.to_string ());
            request.set_error_if_cancelled ();
            Vala.CodeContext.push (compilation.context);

            var fs = new NodeSearch (worker.source_file, pos, true);

            if (fs.result.size == 0) {
                Vala.CodeContext.pop ();
                return null;
            }

            Vala.Scope scope = (new FindScope (worker.source_file, pos)).best_block.scope;
            Vala.CodeNode result = get_best (fs, worker.source_file);
            // don't show lambda expressions on hover
            // don't show property accessors
            if (result is Vala.Method && ((Vala.Method)result).closure ||
                result is Vala.PropertyAccessor) {
                Vala.CodeContext.pop ();
                return null;
            }

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

                if (expr.parent_node is Vala.ObjectCreationExpression)
                    data_type = ((Vala.ObjectCreationExpression)expr.parent_node).value_type;

                // if data_type is the same as this variable's type, then this variable is not a member
                // of the type 
                // (note: this avoids variable's generic type arguments being resolved to InvalidType)
                if (symbol is Vala.Variable && data_type != null && data_type.equals (((Vala.Variable)symbol).variable_type))
                    data_type = null;
            } else if (result is Vala.Symbol) {
                symbol = (Vala.Symbol) result;
            } else if (result is Vala.DataType) {
                data_type = (Vala.DataType) result;
                symbol = SymbolReferences.get_symbol_data_type_refers_to (data_type);
            } else if (result is Vala.UsingDirective) {
                symbol = ((Vala.UsingDirective)result).namespace_symbol;
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
            //         CodeHelp.get_symbol_representation (data_type, null, scope, false),
            //         CodeHelp.get_symbol_representation (null, symbol, scope, false));

            var hoverInfo = new Hover ();

            Range? symbol_range = null;
            if (symbol != null) {
                symbol_range = SymbolReferences.get_replacement_range (result, symbol);
                if (symbol_range != null) {
                    // if the symbol range does not include the cursor, then try
                    // to get the hidden symbol at the cursor first
                    bool found_component = false;
                    if (!symbol_range.contains (pos)) {
                        foreach (var component in SymbolReferences.get_visible_components_of_code_node (result)) {
                            if (component.second.contains (pos)) {
                                hoverInfo.range = component.second;
                                symbol = component.first;
                                data_type = null;
                                method_type_arguments = null;
                                found_component = true;
                                break;
                            }
                        }
                    }
                    if (!found_component)
                        hoverInfo.range = symbol_range;
                }
            }

            if (symbol_range == null)
                hoverInfo.range = new Range.from_sourceref (result.source_reference);

            string? representation = CodeHelp.get_symbol_representation (data_type, symbol, scope, true, method_type_arguments);
            if (representation != null) {
                hoverInfo.contents.add (new MarkedString () {
                    language = "vala",
                    value = representation
                });
                
                if (symbol != null) {
                    var comment = get_symbol_documentation (project, symbol);
                    if (comment != null) {
                        hoverInfo.contents.add (new MarkedString () {
                            value = comment.body
                        });
                        // if (symbol is Vala.Callable && ((Vala.Callable)symbol).get_parameters () != null) {
                        //     var param_list = ((Vala.Callable) symbol).get_parameters ();
                        //     foreach (var parameter in param_list) {
                        //         if (parameter.name == null)
                        //             break;
                        //         string? param_doc = comment.parameters[parameter.name];
                        //         if (param_doc == null)
                        //             continue;
                        //         hoverInfo.contents.add (new MarkedString () {
                        //             value = @"`$(parameter.name)` \u2014 $param_doc"
                        //         });
                        //     }
                        // }
                        // if (comment.return_body != null)
                        //     hoverInfo.contents.add (new MarkedString () {
                        //         value = @"**returns** $(comment.return_body)"
                        //     });
                    }
                }
            }

            Vala.CodeContext.pop ();
            return hoverInfo;
        }, false);
        // debug ("[%s] ... done! result is @ %p", request.to_string (), hover_info);

        if (hover_info != null)
            yield reply_object_async (id, client, hover_info, cancellable);
        else
            yield reply_null_async (id, client, cancellable);
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

    async void show_references (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<ReferenceParams>(@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        bool is_highlight = method == "textDocument/documentHighlight";
        bool include_declaration = p.context != null ? p.context.includeDeclaration : true;
        Position pos = p.position;

        Compilation compilation;
        Project project;
        SourceFileWorker? worker = find_file (p.textDocument.uri, out compilation, out project);
        if (worker == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var references = new HashMap<Range, Vala.CodeNode> ();

        var symbol = yield worker.run_semantics_analyzed<Vala.Symbol?> (() => {
            request.set_error_if_cancelled ();
            Vala.CodeContext.push (compilation.context);

            var fs = new NodeSearch (worker.source_file, pos, true);

            if (fs.result.size == 0) {
                debug (@"[$method] no results found");
                Vala.CodeContext.pop ();
                return null;
            }

            Vala.CodeNode result = get_best (fs, worker.source_file);

            if (result is Vala.Expression && ((Vala.Expression)result).symbol_reference != null)
                result = ((Vala.Expression) result).symbol_reference;
            else if (result is Vala.DataType) {
                result = SymbolReferences.get_symbol_data_type_refers_to ((Vala.DataType) result);
            } else if (result is Vala.UsingDirective && ((Vala.UsingDirective)result).namespace_symbol != null)
                result = ((Vala.UsingDirective) result).namespace_symbol;

            // ignore lambda expressions and non-symbols
            if (!(result is Vala.Symbol) ||
                result is Vala.Method && ((Vala.Method)result).closure) {
                Vala.CodeContext.pop ();
                return null;
            }

            var symbol = (Vala.Symbol) result;

            if (is_highlight || symbol is Vala.LocalVariable) {
                // if highlight, show references in current file
                // otherwise, we may also do this if it's a local variable, since
                // Server.get_compilations_using_symbol() only works for global symbols
                SymbolReferences.list_in_file (worker.source_file, symbol, include_declaration, true, references);
            }

            Vala.CodeContext.pop ();
            return symbol;
        }, false);

        if (symbol == null) {
            yield reply_null_async (id, client, cancellable);
            return;
        }

        debug (@"[$method] got best: $symbol ($(symbol.type_name))");

        if (!(is_highlight || symbol is Vala.LocalVariable)) {
            // more work to do
            yield project.worker.run<void> (() => {
                request.set_error_if_cancelled ();

                // show references in all files
                Vala.CodeContext.push (compilation.context);
                var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
                foreach (var btarget in project)
                    generated_vapis.add_all (btarget.output);
                var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
                foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol))
                    foreach (var w in btarget_w_sym.first) {
                        // don't show symbol from generated VAPI
                        Vala.CodeContext.push (btarget_w_sym.first.context);
                        var file = File.new_for_commandline_arg (w.source_file.filename);
                        if (file in generated_vapis || file in shown_files) {
                            Vala.CodeContext.pop ();
                            continue;
                        }
                        SymbolReferences.list_in_file (w.source_file, btarget_w_sym.second, include_declaration, true, references);
                        shown_files.add (file);
                        Vala.CodeContext.pop ();
                    }
                Vala.CodeContext.pop ();
            }, false);
        }

        Variant[] references_va = {};

        foreach (var entry in references) {
            if (is_highlight) {
                references_va += Util.object_to_variant (new DocumentHighlight () {
                    range = entry.key,
                    kind = determine_node_highlight_kind (entry.value)
                });
            } else {
                references_va += Util.object_to_variant (new Location (entry.value.source_reference.file.filename, entry.key));
            }
        }

        yield client.reply_async (id, new Variant.array (VariantType.VARDICT, references_va), cancellable);
    }

    async void show_implementations (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Position pos = p.position;

        Compilation compilation;
        Project project;
        SourceFileWorker? w = find_file (p.textDocument.uri, out compilation, out project);
        if (w == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var result = yield project.worker.run <Variant?> (() => {
            request.set_error_if_cancelled ();

            Vala.CodeContext.push (compilation.context);

            var fs = new NodeSearch (w.source_file, pos, true);

            if (fs.result.size == 0) {
                debug (@"[$method] no results found");
                Vala.CodeContext.pop ();
                return null;
            }

            Vala.CodeNode result = get_best (fs, w.source_file);
            Vala.Symbol symbol;

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
                Vala.CodeContext.pop ();
                return null;
            } else {
                symbol = (Vala.Symbol) result;
            }

            // show references in all files
            var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in project)
                generated_vapis.add_all (btarget.output);
            var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol)) {
                foreach (var worker in btarget_w_sym.first) {
                    var gfile = File.new_for_commandline_arg (worker.source_file.filename);
                    // don't show symbol from generated VAPI
                    if (gfile in generated_vapis || gfile in shown_files)
                        continue;

                    NodeSearch fs2;
                    if (is_abstract_type) {
                        fs2 = new NodeSearch.with_filter (worker.source_file, btarget_w_sym.second,
                        (needle, node) => node is Vala.ObjectTypeSymbol && 
                            ((Vala.ObjectTypeSymbol)node).is_subtype_of ((Vala.ObjectTypeSymbol) needle), false);
                    } else if (is_abstract_or_virtual_method) {
                        fs2 = new NodeSearch.with_filter (worker.source_file, btarget_w_sym.second,
                        (needle, node) => needle != node && (node is Vala.Method) && 
                            (((Vala.Method)node).base_method == needle ||
                            ((Vala.Method)node).base_interface_method == needle), false);
                    } else {
                        fs2 = new NodeSearch.with_filter (worker.source_file, symbol,
                        (needle, node) => needle != node && (node is Vala.Property) &&
                            (((Vala.Property)node).base_property == needle ||
                            ((Vala.Property)node).base_interface_property == needle), false);
                    }
                    references.add_all (fs2.result);
                    shown_files.add (gfile);
                }
            }

            debug (@"[$method] found $(references.size) reference(s)");
            Variant[] locations_va = {};
            foreach (var node in references) {
                Vala.CodeNode real_node = node;
                if (node is Vala.Symbol)
                    real_node = SymbolReferences.find_real_symbol (project, (Vala.Symbol) node);
                locations_va += Util.object_to_variant (new Location.from_sourceref (real_node.source_reference));
            }

            Vala.CodeContext.pop ();
            return new Variant.array (VariantType.VARDICT, locations_va);
        }, false);

        if (result != null)
            yield client.reply_async (id, result, cancellable);
        else
            yield reply_null_async (id, client, cancellable);
    }
    
    async void format (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<DocumentRangeFormattingParams>(@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Compilation compilation;
        SourceFileWorker? file_worker = find_file (p.textDocument.uri, out compilation);
        if (file_worker == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        try {
            var edited = yield file_worker.run<TextEdit> (() => {
                var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (file_worker.source_file);
                return Formatter.format (p.options, code_style, file_worker.source_file, p.range, request);
            }, false);
            yield reply_object_async (id, client, edited, cancellable);
        } catch (FormattingError e) {
            warning ("Formatting failed: %s", e.message);
            yield client.reply_error_async (id, Jsonrpc.ClientError.INTERNAL_ERROR, e.message, cancellable);
        }
    }

    async void code_action (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<CodeActionParams> (@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Compilation compilation;
        SourceFileWorker? worker = find_file (p.textDocument.uri, out compilation);
        if (worker == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var source_file = worker.source_file as TextDocument;
        if (source_file == null) {
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var result = yield worker.run <Variant> (() => {
            Vala.CodeContext.push (compilation.context);
            var actions = CodeActions.extract (compilation, source_file, p.range, Uri.unescape_string (p.textDocument.uri));
            Vala.CodeContext.pop ();
            Variant[] actions_va = {};
            foreach (var code_action in actions)
                actions_va += Util.object_to_variant (code_action);
            return new Variant.array (VariantType.VARDICT, actions_va);
        }, false);

        yield client.reply_async (id, result, cancellable);
    }

    async void search_workspace_symbols (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var query = (string) @params.lookup_value ("query", VariantType.STRING);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;
        var document_symbols = new ArrayList<SymbolInformation> ();
        foreach (var project in all_projects) {
            yield project.worker.run_configured<void> (() => {
                foreach (var compilation in project) {
                    foreach (var w in compilation) {
                        request.set_error_if_cancelled ();

                        Vala.CodeContext.push (compilation.context);
                        var symbol_enumerator = compilation.get_analysis_for_file<SymbolEnumerator> (w.source_file);
                        if (symbol_enumerator != null) {
                            document_symbols.add_all_iterator (
                                symbol_enumerator
                                .flattened ()
                                // NOTE: if introspection for g_str_match_string () / string.match_string ()
                                // is fixed, this will have to be changed to `dsym.name.match_sting (query, true)`
                                .filter (dsym => query.match_string (dsym.name, true)));
                        }
                        Vala.CodeContext.pop ();
                    }
                }
            }, false);
        }

        debug (@"[$method] found $(document_symbols.size) element(s) matching `$query'");
        Variant[] symbols_va = {};
        foreach (var symbol_info in document_symbols)
            symbols_va += Util.object_to_variant (symbol_info);
        yield client.reply_async (id, new Variant.array (VariantType.VARDICT, symbols_va), cancellable);
    }

    async void rename_symbol (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        string new_name = (string) @params.lookup_value ("newName", VariantType.STRING);

        // before anything, sanity-check the new symbol name
        if (!/^(?=[^\d])[^\s~`!#%^&*()\-\+={}\[\]|\\\/?.>,<'";:]+$/.match (new_name)) {
            yield client.reply_error_async (
                id, 
                Jsonrpc.ClientError.INVALID_REQUEST, 
                "Invalid symbol name. Symbol names cannot start with a number and must not contain any operators.", 
                cancellable);
            return;
        }

        var p = Util.parse_variant<TextDocumentPositionParams> (@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Position pos = p.position;
        Project project;
        Compilation compilation;
        SourceFileWorker? w = find_file (p.textDocument.uri, out compilation, out project);
        if (w == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var result = yield project.worker.run<Variant?> (() => {
            request.set_error_if_cancelled ();

            Vala.CodeContext.push (compilation.context);

            var fs = new NodeSearch (w.source_file, pos, true);

            if (fs.result.size == 0) {
                debug (@"[$method] no results found");
                Vala.CodeContext.pop ();
                return null;
            }

            Vala.CodeNode result = get_best (fs, w.source_file);
            Vala.Symbol symbol;
            var references = new Gee.HashMap<Range, Vala.CodeNode> ();

            if (result is Vala.Expression && ((Vala.Expression)result).symbol_reference != null)
                result = ((Vala.Expression) result).symbol_reference;
            else if (result is Vala.DataType) {
                result = SymbolReferences.get_symbol_data_type_refers_to ((Vala.DataType) result);
            } else if (result is Vala.UsingDirective && ((Vala.UsingDirective)result).namespace_symbol != null)
                result = ((Vala.UsingDirective) result).namespace_symbol;

            // ignore lambda expressions and non-symbols
            if (!(result is Vala.Symbol) ||
                result is Vala.Method && ((Vala.Method)result).closure) {
                debug ("[%s] result is not a symbol", method);
                Vala.CodeContext.pop ();
                return null;
            }

            symbol = (Vala.Symbol) result;

            debug ("[%s] got symbol %s @ %s", method, symbol.get_full_name (), symbol.source_reference.to_string ());

            // get references in all files
            var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in project)
                generated_vapis.add_all (btarget.output);
            var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
            bool is_abstract_or_virtual = 
                symbol is Vala.Property && (((Vala.Property)symbol).is_virtual || ((Vala.Property)symbol).is_abstract) ||
                symbol is Vala.Method && (((Vala.Method)symbol).is_virtual || ((Vala.Method)symbol).is_abstract) ||
                symbol is Vala.Signal && ((Vala.Signal)symbol).is_virtual;
            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol))
                foreach (var worker in btarget_w_sym.first) {
                    // don't show symbol from generated VAPI
                    var file = File.new_for_commandline_arg (worker.source_file.filename);
                    if (file in generated_vapis || file in shown_files)
                        continue;
                    var file_references = new HashMap<Range, Vala.CodeNode> ();
                    debug ("[%s] looking for references in %s ...", method, file.get_uri ());
                    SymbolReferences.list_in_file (worker.source_file, btarget_w_sym.second, true, false, file_references);
                    if (is_abstract_or_virtual) {
                        debug ("[%s] looking for implementations of abstract/virtual symbol in %s ...", method, file.get_uri ());
                        SymbolReferences.list_implementations_of_virtual_symbol (worker.source_file, btarget_w_sym.second, file_references);
                    }
                    if (!(worker.source_file is TextDocument) && file_references.size > 0) {
                        // This means we have found references in a file that was added automatically,
                        // which should not be modified.
                        debug ("[%s] disallowing requested modification of %s", method, worker.source_file.filename);
                        Vala.CodeContext.pop ();
                        return null;
                    }
                    foreach (var entry in file_references)
                        references[entry.key] = entry.value;
                    shown_files.add (file);
                }
            
            debug ("[%s] found %d references", method, references.size);
            
            // construct the edits for the text documents
            // map: file URI -> TextEdit[]
            var edits = new HashMap<string, ArrayList<TextEdit>> ();
            var source_files = new HashMap<string, Vala.SourceFile> ();

            foreach (var entry in references) {
                var code_node = entry.value;
                var source_range = entry.key;
                debug ("[%s] editing reference %s @ %s ...", 
                    method, 
                    CodeHelp.get_code_node_source (code_node), 
                    code_node.source_reference.to_string ());
                var file = File.new_for_commandline_arg (code_node.source_reference.file.filename);
                if (!edits.has_key (file.get_uri ()))
                    edits[file.get_uri ()] = new ArrayList<TextEdit> ();
                var file_edits = edits[file.get_uri ()];
                // if this is a using directive, we want to only replace the part after the 'using' keyword
                file_edits.add (new TextEdit (source_range, new_name));
                source_files[file.get_uri ()] = code_node.source_reference.file;
            }
            Vala.CodeContext.pop ();

            // TODO: determine support for TextDocumentEdit
            var text_document_edits = new ArrayList<TextDocumentEdit> ();
            foreach (var uri in edits.keys) {
                var document_id = new VersionedTextDocumentIdentifier () {
                    version = ((TextDocument) source_files[uri]).version,
                    uri = uri
                };
                text_document_edits.add (new TextDocumentEdit (document_id) {
                    edits = edits[uri]
                });
            }

            return Util.object_to_variant (new WorkspaceEdit () {
                documentChanges = text_document_edits
            });
        }, false);

        if (result != null)
            yield client.reply_async (id, result, cancellable);
        else
            yield reply_null_async (id, client, cancellable);
    }
    
    async void prepare_rename_symbol (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<TextDocumentPositionParams> (@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Position pos = p.position;
        Project project;
        Compilation compilation;
        SourceFileWorker? file_worker = find_file (p.textDocument.uri, out compilation, out project);
        if (file_worker == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        try {
            var replacement_range = yield project.worker.run<Range> (() => {
                request.set_error_if_cancelled ();
                Vala.CodeContext.push (compilation.context);

                var fs = new NodeSearch (file_worker.source_file, pos, true);

                if (fs.result.size == 0) {
                    Vala.CodeContext.pop ();
                    throw new PrepareRenameError.NO_SYMBOL ("No symbol at cursor");
                }

                Vala.CodeNode initial_result = get_best (fs, file_worker.source_file);
                Vala.CodeNode result = initial_result;
                Vala.Symbol symbol;

                if (result is Vala.Expression && ((Vala.Expression)result).symbol_reference != null)
                    result = ((Vala.Expression) result).symbol_reference;
                else if (result is Vala.DataType) {
                    result = SymbolReferences.get_symbol_data_type_refers_to ((Vala.DataType) result);
                } else if (result is Vala.UsingDirective && ((Vala.UsingDirective)result).namespace_symbol != null)
                    result = ((Vala.UsingDirective) result).namespace_symbol;

                // ignore lambda expressions and non-symbols
                if (!(result is Vala.Symbol) ||
                    result is Vala.Method && ((Vala.Method)result).closure) {
                    Vala.CodeContext.pop ();
                    throw new PrepareRenameError.NO_SYMBOL ("No symbol at cursor");
                }

                symbol = (Vala.Symbol) result;

                var replacement_range = SymbolReferences.get_replacement_range (initial_result, symbol);
                // If the source_reference is null, then this could be something like a
                // `this' parameter.
                if (replacement_range == null || symbol.source_reference == null) {
                    Vala.CodeContext.pop ();
                    throw new PrepareRenameError.FORBIDDEN_SYMBOL ("Cannot rename this symbol");
                }

                foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol)) {
                    if (!(btarget_w_sym.second.source_reference.file is TextDocument)) {
                        // This means we have found references in a file that was added automatically,
                        // which should not be modified.
                        string? pkg = btarget_w_sym.second.source_reference.file.package_name;
                        Vala.CodeContext.pop ();
                        throw new PrepareRenameError.FORBIDDEN_SYMBOL ("Cannot rename a symbol defined in a system library%s", pkg != null ? @" ($pkg)" : ".");
                    }
                }

                Vala.CodeContext.pop ();
                return replacement_range;
            }, false);

            yield reply_object_async (id, client, replacement_range, cancellable);
        } catch (PrepareRenameError e) {
            yield client.reply_error_async (id, Jsonrpc.ClientError.INVALID_REQUEST, e.message, cancellable);
        }
    }

    /**
     * handle an incoming `textDocument/codeLens` request
     */
    async void code_lens (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        string? uri = document != null ? (string?) document.lookup_value ("uri", VariantType.STRING) : null;

        if (document == null || uri == null) {
            warning ("[%s] `textDocument` or `uri` not provided as expected", method);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        // debug ("[%s] beginning request ...", request.to_string ());

        Project project;
        Compilation compilation;
        SourceFileWorker? worker = find_file (uri, out compilation, out project);
        if (worker == null) {
            debug ("[%s] file `%s' not found", method, uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        // debug ("[%s] queueing on source file worker ...", request.to_string ());
        var result = yield worker.run<Variant> (() => {
            // debug ("... [%s] running on source file worker ...", request.to_string ());
            Variant[] lenses_va = {};
            foreach (var lens in compilation.get_analysis_for_file<CodeLensAnalyzer> (worker.source_file))
                lenses_va += Util.object_to_variant (lens);
            return new Variant.array (VariantType.VARDICT, lenses_va);
        }, false);
        // debug ("[%s] ... done!", request.to_string ());

        yield client.reply_async (id, result, cancellable);
    }

    async void prepare_call_hierarchy (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var p = Util.parse_variant<TextDocumentPositionParams> (@params);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Project project;
        Compilation compilation;
        SourceFileWorker? worker = find_file (p.textDocument.uri, out compilation, out project);
        if (worker == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var result = yield worker.run_symbols_resolved<Variant?> (() => {
            request.set_error_if_cancelled ();
            Vala.CodeContext.push (compilation.context);

            var fs = new NodeSearch (worker.source_file, p.position);

            if (fs.result.size == 0) {
                debug (@"[$method] no results found");
                Vala.CodeContext.pop ();
                return null;
            }

            Vala.CodeNode result = get_best (fs, worker.source_file);

            Vala.Method method_sym;

            if (result is Vala.Method) {
                method_sym = (Vala.Method)result;
            } else if (result is Vala.MethodCall) {
                var call_method = ((Vala.MethodCall)result).call.symbol_reference as Vala.Method;
                if (call_method == null) {
                    Vala.CodeContext.pop ();
                    return null;
                }
                method_sym = call_method;
            } else if (result is Vala.Expression && ((Vala.Expression)result).symbol_reference is Vala.Method) {
                method_sym = (Vala.Method) ((Vala.Expression)result).symbol_reference;
            } else {
                Vala.CodeContext.pop ();
                return null;
            }

            Vala.CodeContext.pop ();
            return new Variant.array (VariantType.VARDICT, {
                Util.object_to_variant (new CallHierarchyItem.from_symbol (method_sym))
            });
        }, false);

        if (result != null)
            yield client.reply_async (id, result, cancellable);
        else
            yield reply_null_async (id, client, cancellable);
    }

    async void call_hierarchy_incoming_calls (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var itemv = @params.lookup_value ("item", VariantType.VARDICT);
        var item = Util.parse_variant<CallHierarchyItem> (itemv);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Project project;
        Compilation compilation;
        SourceFileWorker? file_worker = find_file (item.uri, out compilation, out project);
        if (file_worker == null) {
            debug ("[%s] file `%s' not found", method, item.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var result = yield project.worker.run <Variant?> (() => {
            request.set_error_if_cancelled ();

            Vala.CodeContext.push (compilation.context);
            var symbol = CodeHelp.lookup_symbol_full_name (item.name, compilation.context.root.scope);
            if (!(symbol is Vala.Callable || symbol is Vala.Subroutine)) {
                Vala.CodeContext.pop ();
                return null;
            }

            var incoming = CallHierarchy.get_incoming_calls (project, symbol);
            Vala.CodeContext.pop ();

            // get all methods that call this method
            Variant[] incoming_va = {};
            foreach (var incoming_call in incoming)
                incoming_va += Util.object_to_variant (incoming_call);
            return new Variant.array (VariantType.VARDICT, incoming_va);
        }, false);

        if (result != null)
            yield client.reply_async (id, result, cancellable);
        else
            yield reply_null_async (id, client, cancellable);
    }

    async void call_hierarchy_outgoing_calls (Jsonrpc.Client client, string method, Variant id, Variant @params) throws Error {
        var itemv = @params.lookup_value ("item", VariantType.VARDICT);
        var item = Util.parse_variant<CallHierarchyItem> (itemv);
        var request = new Request (id, cancellable, method);
        pending_requests[id] = request;

        Project project;
        Compilation compilation;
        SourceFileWorker? file_worker = find_file (item.uri, out compilation, out project);
        if (file_worker == null) {
            debug ("[%s] file `%s' not found", method, item.uri);
            yield reply_null_async (id, client, cancellable);
            return;
        }

        var result = yield project.worker.run<Variant?> (() => {
            request.set_error_if_cancelled ();

            Vala.CodeContext.push (compilation.context);
            var subroutine = CodeHelp.lookup_symbol_full_name (item.name, Vala.CodeContext.get ().root.scope) as Vala.Subroutine;
            if (subroutine == null) {
                Vala.CodeContext.pop ();
                return null;
            }

            var outgoing = CallHierarchy.get_outgoing_calls (project, subroutine);
            Vala.CodeContext.pop ();

            // get all methods called by this method
            Variant[] outgoing_va = {};
            foreach (var outgoing_call in outgoing)
                outgoing_va += Util.object_to_variant (outgoing_call);
            return new Variant.array (VariantType.VARDICT, outgoing_va);
        }, false);

        if (result != null)
            yield client.reply_async (id, result, cancellable);
        else
            yield reply_null_async (id, client, cancellable);
    }

    void shutdown () {
        debug ("shutting down...");
        this.shutting_down = true;
        cancellable.cancel ();
        if (client_closed_event_id != 0)
            this.disconnect (client_closed_event_id);
        foreach (var project in projects.get_keys_as_array ()) {
            var handler_id = projects[project];
            if (handler_id != 0)
                project.disconnect (handler_id);
        }
        foreach (uint source_id in g_sources)
            Source.remove (source_id);
    }

    void exit () {
        loop.quit ();
    }
}

/**
 * `--version`
 */
bool opt_version;

const OptionEntry[] entries = {
    { "version", 'v', OptionFlags.NONE, OptionArg.NONE, ref opt_version, "Print the version and commit info", null },
    {}
};

int main (string[] args) {
    Environment.set_prgname ("vala-language-server");
    var ocontext = new OptionContext ("- vala-language-server");
    ocontext.add_main_entries (entries, null);
    ocontext.set_summary ("A language server for Vala");
    ocontext.set_description (@"Report bugs to $(Config.PROJECT_BUGSITE)");
    try {
        ocontext.parse (ref args);
    } catch (Error e) {
        stderr.printf ("%s\n", e.message);
        stderr.printf ("Run '%s --version' to print version, or no arguments to run the language server.\n", args[0]);
        return 1;
    }

    if (opt_version) {
        stdout.printf ("%s %s\n", Config.PROJECT_NAME, Config.PROJECT_VERSION);
        return 1;
    }

    // otherwise
    try {
        var loop = new MainLoop ();
        new Vls.Server (loop);
        loop.run ();
    } catch (ThreadError e) {
        stderr.printf ("could not start server due to threading issue: %s\n", e.message);
        return 1;
    }
    return 0;
}
