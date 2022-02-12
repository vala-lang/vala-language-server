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

/**
 * Errors occuring while servicing requests.
 */
public errordomain Vls.RequestError {
    /**
     * The request was cancelled before or while the context was being updated.
     */
    CANCELLED
}

class Vls.Server : Jsonrpc.Server {
    private static bool received_signal = false;
    MainLoop loop;

    InitializeParams init_params;

    const uint check_update_context_period_ms = 100;
    const int64 update_context_delay_inc_us = 500 * 1000;
    const int64 update_context_delay_max_us = 1000 * 1000;
    const uint wait_for_context_update_delay_ms = 200;

    /**
     * Contains documentation from found GIR files.
     */
    GirDocumentation documentation;

    HashSet<Request> pending_requests;

    bool shutting_down = false;

    bool initialized = false;

    /**
     * The global cancellable object
     */
    public static Cancellable cancellable = new Cancellable ();

    [CCode (has_target = false)]
    delegate void NotificationHandler (Vls.Server self, Jsonrpc.Client client, Variant @params);

    [CCode (has_target = false)]
    delegate void CallHandler (Vls.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params);

    ulong client_closed_event_id;
    HashTable<Project, ulong> projects;
    DefaultProject default_project;

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

    static construct {
        Process.@signal (ProcessSignal.INT, () => {
            Server.received_signal = true;
        });
        Process.@signal (ProcessSignal.TERM, () => {
            Server.received_signal = true;
        });
    }

    public Server (MainLoop loop) {
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
            debug ("failed to set FDs to nonblocking");
            loop.quit ();
            return;
        }
#endif

        // shutdown if/when we get a signal
        Timeout.add (1 * 1000, () => {
            if (Server.received_signal) {
                shutdown ();
                return Source.REMOVE;
            }
            return !this.shutting_down;
        });

        accept_io_stream (new SimpleIOStream (input_stream, output_stream));

        pending_requests = new HashSet<Request> (Request.hash, Request.equal);

        this.projects = new HashTable<Project, ulong> (GLib.direct_hash, GLib.direct_equal);

        debug ("Finished constructing");
    }

    public override bool handle_call (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        switch (method) {
            case "initialize":
                initialize_async.begin (client, method, id, @params);
                return true;

            case "shutdown":
                shutdown_reply_async.begin (client, method, id, @params);
                return true;

            case "textDocument/definition":
                text_document_definition_async.begin (client, method, id, @params);
                return true;

            case "textDocument/documentSymbol":
                text_document_document_symbol_async.begin (client, method, id, @params);
                return true;

            case "textDocument/completion":
                text_document_completion_async.begin (client, method, id, @params);
                return true;

            case "textDocument/hover":
                text_document_hover_async.begin (client, method, id, @params);
                return true;

            case "textDocument/references":
            case "textDocument/documentHighlight":
                text_document_references_async.begin (client, method, id, @params);
                return true;

            case "textDocument/signatureHelp":
                text_document_signature_help_async.begin (client, method, id, @params);
                return true;

            case "textDocument/implementation":
                text_document_implementation_async.begin (client, method, id, @params);
                return true;

            case "textDocument/rename":
                text_document_rename_async.begin (client, method, id, @params);
                return true;

            case "textDocument/prepareRename":
                text_document_prepare_rename_async.begin (client, method, id, @params);
                return true;

            case "textDocument/codeLens":
                text_document_code_lens_async.begin (client, method, id, @params);
                return true;

            case "textDocument/formatting":
                text_document_formatting.begin (client, method, id, @params);
                return true;

            case "workspace/symbol":
                workspace_symbol_async.begin (client, method, id, @params);
                return true;
        }
        warning ("no call handler for %s", method);
        return false;
    }

    public override void notification (Jsonrpc.Client client, string method, Variant @params) {
        switch (method) {
            case "exit":
                this.exit (client, @params);
                return;

            case "textDocument/didOpen":
                text_document_did_open_async.begin (client, @params);
                return;

            case "textDocument/didSave":
                text_document_did_save (client, @params);
                return;

            case "textDocument/didClose":
                text_document_did_close (client, @params);
                return;

            case "textDocument/didChange":
                text_document_did_change (client, @params);
                return;

            case "$/cancelRequest":
                cancel_request (client, @params);
                return;
        }

        warning ("unhandled notification %s", method);
    }

#if WITH_JSONRPC_GLIB_3_30
    public override void client_closed (Jsonrpc.Client client) {
        shutdown ();
    }
#endif

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

    async void show_message_async (Jsonrpc.Client client, string message, MessageType type) {
        if (type == MessageType.Error)
            warning (message);
        try {
            yield client.send_notification_async (
                "window/showMessage",
                    build_dict (
                    type: new Variant.int16 (type),
                    message: new Variant.string (message)
                ),
                cancellable
            );
        } catch (Error e) {
            debug (@"showMessage: failed to notify client: $(e.message)");
        }
    }

    async void initialize_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
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
                backend_project = yield new MesonProject (root_path, cancellable);
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
                    backend_project = yield new CcProject (root_path, cc_file_path, cancellable);
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
                yield show_message_async (client, @"CMake build system is not currently supported. Only Meson is. See https://github.com/benwaffle/vala-language-server/issues/73", MessageType.Warning);
            if (autogen_sh.query_exists (cancellable))
                yield show_message_async (client, @"Autotools build system is not currently supported. Consider switching to Meson.", MessageType.Warning);
        } else {
            new_projects.add (backend_project);
        }

        // always have default project
        default_project = new DefaultProject (root_path);

        // build and publish diagnostics
        foreach (var project in new_projects) {
            try {
                debug ("Building project ...");
                yield project.rebuild_async ();
                debug ("Publishing diagnostics ...");
                foreach (var compilation in project.get_compilations ())
                    yield publish_diagnostics_async (project, compilation, client);
            } catch (Error e) {
                yield show_message_async (client, @"Failed to build project - $(e.message)", MessageType.Error);
            }
        }

        // create documentation (compiles GIR files too)
        var packages = new HashSet<Vala.SourceFile> ();
        var custom_gir_dirs = new HashSet<File> (Util.file_hash, Util.file_equal);
        foreach (var project in new_projects) {
            packages.add_all (project.get_packages ());
            custom_gir_dirs.add_all (project.get_custom_gir_dirs ());
        }
        documentation = new GirDocumentation (packages, custom_gir_dirs);

        // listen for project changed events
        foreach (Project project in new_projects)
            projects[project] = project.changed.connect (project_changed_event);

        // listen for context update requests
        update_context_client = client;

        // Respond. Now we've "returned" from the LSP client's point of view.
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
                    hoverProvider: new Variant.boolean (true),
                    referencesProvider: new Variant.boolean (true),
                    documentHighlightProvider: new Variant.boolean (true),
                    documentFormattingProvider: new Variant.boolean (true),
                    implementationProvider: new Variant.boolean (true),
                    workspaceSymbolProvider: new Variant.boolean (true),
                    renameProvider: build_dict (prepareProvider: new Variant.boolean (true)),
                    codeLensProvider: build_dict (resolveProvider: new Variant.boolean (false))
                ),
                serverInfo: build_dict (
                    name: new Variant.string ("Vala Language Server"),
                    version: new Variant.string (Config.PROJECT_VERSION)
                )
            ), cancellable);
            initialized = true;
        } catch (Error e) {
            error (@"[initialize] failed to reply to client: $(e.message)");
        }

        check_update_context_async.begin ();    // begin long-running task
    }

    void project_changed_event () {
        request_context_update (update_context_client);
        debug ("requested context update for project change event");
    }

    void cancel_request (Jsonrpc.Client client, Variant @params) {
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

    public static async void reply_null_async (Variant id, Jsonrpc.Client client, string method) {
        try {
            yield client.reply_async (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }

    async void text_document_did_open_async (Jsonrpc.Client client, Variant @params) {
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
                doc_w_bt = (yield project.open (uri, fileContents, cancellable)).first ();
                break;
            } catch (Error e) {
                if (!(e is ProjectError.NOT_FOUND))
                    warning ("[textDocument/didOpen] failed to open %s - %s", Uri.unescape_string (uri), e.message);
            }
        }

        // fallback to default project
        if (doc_w_bt == null) {
            try {
                doc_w_bt = (yield default_project.open (uri, fileContents, cancellable)).first ();
                // it's possible that we opened a Vala script and have to
                // include additional packages for documentation
                foreach (var pkg in default_project.get_packages ())
                    documentation.add_package_from_source_file (pkg);
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
            var tdoc = (TextDocument) doc;
            debug (@"[textDocument/didOpen] opened $(Uri.unescape_string (uri))"); 
            tdoc.last_saved_content = fileContents;
            if (tdoc.content != fileContents) {
                tdoc.content = fileContents;
                request_context_update (client);
                debug (@"[textDocument/didOpen] requested context update");
            }
        } else {
            debug (@"[textDocument/didOpen] opened read-only $(Uri.unescape_string (uri))");
        }

        // add document to open list
        open_files.add (uri);
    }

    void text_document_did_save (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);

        string? uri = (string) document.lookup_value ("uri", VariantType.STRING);
        if (uri == null) {
            warning (@"[textDocument/didSave] null URI sent to vala language server");
            return;
        }

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;

        foreach (var project in all_projects) {
            foreach (var pair in project.lookup_compile_input_source_file (uri)) {
                var text_document = pair.first as TextDocument;

                if (text_document == null) {
                    warning ("[textDocument/didSave] ignoring save to system file");
                    continue;
                }

                // make checkpoint
                text_document.last_saved_content = text_document.content;
                debug ("[textDocument/didSave] last save of %s is now at version %d", uri, text_document.last_saved_version);
            }
        }
    }

    void text_document_did_close (Jsonrpc.Client client, Variant @params) {
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
                    discarded_files.add (uri);
                    request_context_update (client);
                    debug (@"[textDocument/didClose] requested context update");
                }
                debug ("[textDocument/didClose] closed %s", uri);
            } catch (Error e) {
                if (!(e is ProjectError.NOT_FOUND))
                    warning ("[textDocument/didClose] failed to close %s - %s", Uri.unescape_string (uri), e.message);
            }
        }
    }

    Jsonrpc.Client? update_context_client = null;
    int64 update_context_requests = 0;
    int64 update_context_time_us = 0;
    bool updating_context = false;

    void text_document_did_change (Jsonrpc.Client client, Variant @params) {
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

    /** 
     * Indicate to the server that the code context(s) it is tracking may
     * need to be refreshed.
     * 
     * @param client        the client to eventually send a `publishDiagnostics` 
     *                      notification to, if the context is refreshed
     */
    void request_context_update (Jsonrpc.Client client) {
        update_context_client = client;
        update_context_requests += 1;
        int64 delay_us = int64.min (update_context_delay_inc_us * update_context_requests, update_context_delay_max_us);
        update_context_time_us = get_monotonic_time () + delay_us;
        // debug (@"Context(s) update (re-)scheduled in $((int) (delay_us / 1000)) ms");
    }

    /** 
     * Runs in the background periodically. Reconfigures the project if needed,
     * and checks whether we need to rebuild the project and documentation
     * engine if we have context update requests.
     */
    async void check_update_context_async () {
        while (!shutting_down && !cancellable.is_cancelled ()) {
            if (update_context_requests > 0 && get_monotonic_time () >= update_context_time_us) {
                update_context_requests = 0;
                update_context_time_us = 0;
                debug ("updating contexts and publishing diagnostics...");
                updating_context = true;

                Project[] all_projects = projects.get_keys_as_array ();
                all_projects += default_project;
                bool reconfigured_projects = false;
                foreach (var project in all_projects) {
                    try {
                        bool reconfigured = yield project.reconfigure_async (cancellable);
                        reconfigured_projects |= reconfigured;
                        yield project.rebuild_async (cancellable);

                        // remove all newly-added files from the default project
                        if (reconfigured && project != default_project) {
                            var newly_added = new HashSet<string> ();
                            foreach (var compilation in project.get_compilations ())
                                newly_added.add_all_iterator (compilation.get_project_files ().map<string> (f => f.filename));
                            foreach (var compilation in default_project.get_compilations ()) {
                                foreach (var source_file in compilation.get_project_files ()) {
                                    if (newly_added.contains (source_file.filename)) {
                                        var uri = File.new_for_path (source_file.filename).get_uri ();
                                        try {
                                            default_project.close (uri);
                                            discarded_files.add (uri);
                                            debug ("discarding %s from DefaultProject", uri);
                                        } catch (Error e) {
                                            // just ignore
                                        }
                                    }
                                }
                            }
                        }

                        foreach (var compilation in project.get_compilations ())
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
                        foreach (var compilation in project.get_compilations ()) {
                            foreach (var source_file in compilation.code_context.get_source_files ()) {
                                var uri = File.new_for_path (source_file.filename).get_uri ();
                                orphaned_files.remove (uri);
                            }
                        }
                    }
                    foreach (var uri in orphaned_files) {
                        try {
                            var opened = (yield default_project.open (uri, null, cancellable)).first ();
                            // ensure the file's contents are available
                            var doc = opened.first;
                            if (doc.content == null)
                                doc.get_mapped_contents ();
                            if (doc is TextDocument)
                                ((TextDocument)doc).last_saved_content = doc.content;
                            yield publish_diagnostics_async (default_project, opened.second, update_context_client);
                        } catch (Error e) {
                            warning ("Failed to reopen in default project %s - %s", uri, e.message);
                            // clear the diagnostics for the file
                            try {
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

                // rebuild the documentation
                documentation.rebuild_if_stale ();
                updating_context = false;
            }

            // schedule ourselves
            SourceFunc callback = check_update_context_async.callback;
            Timeout.add (check_update_context_period_ms, () => {
                callback ();
                return Source.REMOVE;
            });
            yield;
        }
    }

    /**
     * Waits for the code context to be refreshed.
     *
     * @param id        an identifier for the request
     * @param method    the name of the method, for debugging purposes
     *
     * @throws RequestError if the request was cancelled or some failure happened
     */
    public async void wait_for_context_update_async (Variant id, string? method = null) throws RequestError {
        if (initialized && update_context_requests == 0)
            return;     // there's nothing to wait for

        var req = new Request (id, method);

        if (!pending_requests.add (req))
            warning (@"Request($req): request already in pending requests, this should not happen");

        SourceFunc callback = wait_for_context_update_async.callback;
        RequestError? err = null;

        Timeout.add (wait_for_context_update_delay_ms, () => {
            if (initialized && update_context_requests == 0 && !updating_context) {
                // context was updated
                // if [req] is still present, it hasn't been cancelled
                if (!pending_requests.remove (req))
                    err = new RequestError.CANCELLED (@"Request($req) already cancelled by the time context was updated");
                callback ();
                return Source.REMOVE;
            }

            // context hasn't been updated yet

            if (!pending_requests.contains (req)) {
                // request has been cancelled before context was updated
                err = new RequestError.CANCELLED (@"Request($req) cancelled before context before context has been updated");
                callback ();
                return Source.REMOVE;
            }

            // otherwise just continue waiting...
            // debug (@"Request($req): waiting for context update ...");
            return Source.CONTINUE;
        });

        yield;  // wait for invocation of callback

        if (err != null)
            throw err;
    }

    async void publish_diagnostics_async (Project project, Compilation target, Jsonrpc.Client client) {
        var diags_without_source = new Json.Array ();

        debug ("publishing diagnostics for Compilation target %s", target.id);

        var doc_diags = new HashMap<Vala.SourceFile, Json.Array?> ();
        foreach (var file in target.code_context.get_source_files ())
            doc_diags[file] = null;

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
            if (!doc_diags.has_key (err.loc.file) || doc_diags[err.loc.file] == null)
                doc_diags[err.loc.file] = new Json.Array ();
            doc_diags[err.loc.file].add_element (node);
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
            var gfile = File.new_for_commandline_arg_and_cwd (entry.key.filename, target.code_context.directory);

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

    async void text_document_definition_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams> (@params);
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
            yield reply_null_async (id, client, method);
            return;
        }

        try {
            yield wait_for_context_update_async (id, method);
        } catch (Error e) {
            yield reply_null_async (id, client, method);
            return;
        }

        // ignore multiple results
        Vala.SourceFile file = results[0].first;
        Compilation compilation = results[0].second;

        Vala.CodeContext.push (compilation.code_context);
        var fs = new FindSymbol (file, p.position, true);

        if (fs.result.size == 0) {
            debug ("[%s] find symbol is empty", method);
            Vala.CodeContext.pop ();
            try {
                yield client.reply_async (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
            } catch (Error e) {
                debug("[textDocument/definition] failed to reply to client: %s", e.message);
            }
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
            try {
                yield client.reply_async (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
            } catch (Error e) {
                debug("[textDocument/definition] failed to reply to client: %s", e.message);
            }
            return;
        }

        if (best is Vala.Symbol)
            best = SymbolReferences.find_real_symbol (selected_project, (Vala.Symbol) best);

        var location = new Location.from_sourceref (best.source_reference);
        debug ("[textDocument/definition] found location ... %s", location.uri);
        Vala.CodeContext.pop ();
        try {
            yield client.reply_async (id, Util.object_to_variant (location), cancellable);
        } catch (Error e) {
            debug("[textDocument/definition] failed to reply to client: %s", e.message);
        }
    }

    async void text_document_document_symbol_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);
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
            yield reply_null_async (id, client, method);
            return;
        }

        // ignore multiple results
        Vala.SourceFile file = results[0].first;
        Compilation compilation = results[0].second;

        Vala.CodeContext.push (compilation.code_context);

        var array = new Json.Array ();
        var syms = compilation.get_analysis_for_file<SymbolEnumerator> (file) as SymbolEnumerator;
        if (init_params.capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport)
            foreach (var dsym in syms) {
                // debug(@"found $(dsym.name)");
                array.add_element (Json.gobject_serialize (dsym));
            }
        else {
            foreach (var dsym in syms.flattened ()) {
                // debug(@"found $(dsym.name)");
                array.add_element (Json.gobject_serialize (dsym));
            }
        }

        Vala.CodeContext.pop ();

        try {
            Variant result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
            yield client.reply_async (id, result, cancellable);
        } catch (Error e) {
            debug (@"[textDocument/documentSymbol] failed to reply to client: $(e.message)");
        }
    }

    public DocComment? get_symbol_documentation (Project project, Vala.Symbol sym) {
        Compilation compilation = null;
        Vala.Symbol real_sym = SymbolReferences.find_real_symbol (project, sym);
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

    async void text_document_completion_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.CompletionParams>(@params);
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
            yield reply_null_async (id, client, method);
            return;
        }

        yield CompletionEngine.begin_response_async (this, selected_project,
                                                     client, id, method,
                                                     results[0].first, results[0].second,
                                                     p.position, p.context);
    }

    async void text_document_signature_help_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);
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
            yield reply_null_async (id, client, method);
            return;
        }

        yield SignatureHelpEngine.begin_response_async (this, selected_project,
                                                        client, id, method,
                                                        results[0].first, results[0].second,
                                                        p.position);
    }

    async void text_document_hover_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);
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
            yield reply_null_async (id, client, "textDocument/hover");
            return;
        }

        Position pos = p.position;
        Vala.SourceFile doc = results[0].first;
        Compilation compilation = results[0].second;
        Vala.CodeContext.push (compilation.code_context);

        var fs = new FindSymbol (doc, pos, true);

        if (fs.result.size == 0) {
            // debug ("[textDocument/hover] no results found");
            Vala.CodeContext.pop ();
            yield reply_null_async (id, client, method);
            return;
        }

        Vala.Scope scope = (new FindScope (doc, pos)).best_block.scope;
        Vala.CodeNode result = get_best (fs, doc);
        // don't show lambda expressions on hover
        // don't show property accessors
        if (result is Vala.Method && ((Vala.Method)result).closure ||
            result is Vala.PropertyAccessor) {
            Vala.CodeContext.pop ();
            yield reply_null_async (id, client, "textDocument/hover");
            return;
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
                var comment = get_symbol_documentation (selected_project, symbol);
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

        try {
            yield client.reply_async (id, Util.object_to_variant (hoverInfo), cancellable);
        } catch (Error e) {
            warning ("[textDocument/hover] failed to reply to client: %s", e.message);
        }
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

    async void text_document_references_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
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
            yield reply_null_async (id, client, method);
            return;
        }

        Position pos = p.position;
        bool is_highlight = method == "textDocument/documentHighlight";
        bool include_declaration = p.context != null ? p.context.includeDeclaration : true;

        Vala.SourceFile doc = results[0].first;
        Compilation compilation = results[0].second;
        Vala.CodeContext.push (compilation.code_context);

        var fs = new FindSymbol (doc, pos, true);

        if (fs.result.size == 0) {
            debug (@"[$method] no results found");
            Vala.CodeContext.pop ();
            yield reply_null_async (id, client, method);
            return;
        }

        Vala.CodeNode result = get_best (fs, doc);
        Vala.Symbol symbol;
        var json_array = new Json.Array ();
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
            Vala.CodeContext.pop ();
            yield reply_null_async (id, client, method);
            return;
        }

        symbol = (Vala.Symbol) result;

        debug (@"[$method] got best: $result ($(result.type_name))");
        if (is_highlight || symbol is Vala.LocalVariable) {
            // if highlight, show references in current file
            // otherwise, we may also do this if it's a local variable, since
            // Server.get_compilations_using_symbol() only works for global symbols
            SymbolReferences.list_in_file (doc, symbol, include_declaration, references);
        } else {
            // show references in all files
            var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in selected_project.get_compilations ())
                generated_vapis.add_all (btarget.output);
            var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (selected_project, symbol))
                foreach (Vala.SourceFile project_file in btarget_w_sym.first.code_context.get_source_files ()) {
                    // don't show symbol from generated VAPI
                    var file = File.new_for_commandline_arg (project_file.filename);
                    if (file in generated_vapis || file in shown_files)
                        continue;
                    SymbolReferences.list_in_file (project_file, btarget_w_sym.second, include_declaration, references);
                    shown_files.add (file);
                }
        }
        
        debug (@"[$method] found $(references.size) reference(s)");
        foreach (var entry in references) {
            if (is_highlight) {
                json_array.add_element (Json.gobject_serialize (new DocumentHighlight () {
                    range = entry.key,
                    kind = determine_node_highlight_kind (entry.value)
                }));
            } else {
                json_array.add_element (Json.gobject_serialize (new Location (entry.value.source_reference.file.filename, entry.key)));
            }
        }

        Vala.CodeContext.pop ();

        try {
            Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
            yield client.reply_async (id, variant_array, cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }

    async void text_document_implementation_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);
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
            yield reply_null_async (id, client, method);
            return;
        }

        Position pos = p.position;

        Vala.SourceFile doc = results[0].first;
        Compilation compilation = results[0].second;
        Vala.CodeContext.push (compilation.code_context);

        var fs = new FindSymbol (doc, pos, true);

        if (fs.result.size == 0) {
            debug (@"[$method] no results found");
            Vala.CodeContext.pop ();
            yield reply_null_async (id, client, method);
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
            Vala.CodeContext.pop ();
            yield reply_null_async (id, client, method);
            return;
        } else {
            symbol = (Vala.Symbol) result;
        }

        // show references in all files
        var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
        foreach (var btarget in selected_project.get_compilations ())
            generated_vapis.add_all (btarget.output);
        var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
        foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (selected_project, symbol)) {
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
                real_node = SymbolReferences.find_real_symbol (selected_project, (Vala.Symbol) node);
            json_array.add_element (Json.gobject_serialize (new Location.from_sourceref (real_node.source_reference)));
        }

        Vala.CodeContext.pop ();

        try {
            Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
            yield client.reply_async (id, variant_array, cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }
    
    async void text_document_formatting (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.DocumentFormattingParams>(@params);
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
            yield reply_null_async (id, client, method);
            return;
        }
        var json_array = new Json.Array ();
        foreach (var pair in results) {
            TextEdit edited;
            Vala.SourceFile source_file = pair.first;
            Compilation compilation = pair.second;
            var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (source_file) as CodeStyleAnalyzer;
            try {
                edited = yield Formatter.format_async (p.options, code_style, source_file, cancellable);
            } catch (Error e) {
                try {
                    yield client.reply_error_async (id, Jsonrpc.ClientError.INTERNAL_ERROR, e.message, cancellable);
                    warning ("Formatting failed: %s", e.message);
                } catch (Error e) {
                }
                return;
            }
            json_array.add_element (Json.gobject_serialize (edited));
        }
        try {
            Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
            client.reply (id, variant_array, cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }

    async void workspace_symbol_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var query = (string) @params.lookup_value ("query", VariantType.STRING);

        try {
            yield wait_for_context_update_async (id, method);
        } catch (Error e) {
            yield reply_null_async (id, client, method);
            return;
        }

        var json_array = new Json.Array ();
        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;
        foreach (var project in all_projects) {
            foreach (var source_pair in project.get_project_source_files ()) {
                var text_document = source_pair.key;
                var compilation = source_pair.value;
                Vala.CodeContext.push (compilation.code_context);
                var symbol_enumerator = compilation.get_analysis_for_file<SymbolEnumerator> (text_document) as SymbolEnumerator;
                if (symbol_enumerator != null) {
                    symbol_enumerator
                        .flattened ()
                        // NOTE: if introspection for g_str_match_string () / string.match_string ()
                        // is fixed, this will have to be changed to `dsym.name.match_sting (query, true)`
                        .filter (dsym => query.match_string (dsym.name, true))
                        .foreach (dsym => {
                            json_array.add_element (Json.gobject_serialize (dsym));
                            return true;
                        });
                }
                Vala.CodeContext.pop ();
            }
        }

        debug (@"[$method] found $(json_array.get_length ()) element(s) matching `$query'");
        try {
            Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
            yield client.reply_async (id, variant_array, cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }

    async void text_document_rename_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        string new_name = (string) @params.lookup_value ("newName", VariantType.STRING);

        // before anything, sanity-check the new symbol name
        if (!/^(?=[^\d])[^\s~`!#%^&*()\-\+={}\[\]|\\\/?.>,<'";:]+$/.match (new_name)) {
            try {
                yield client.reply_error_async (
                    id, 
                    Jsonrpc.ClientError.INVALID_REQUEST, 
                    "Invalid symbol name. Symbol names cannot start with a number and must not contain any operators.", 
                    cancellable
                );
            } catch (Error e) {
                debug ("[%s] failed to reply to client with error - %s", method, e.message);
            }
            return;
        }

        // we cannot rename until everything is up-to-date
        try {
            yield wait_for_context_update_async (id, method);
        } catch (Error e) {
            yield reply_null_async (id, client, method);
            return;
        }

        var p = Util.parse_variant<TextDocumentPositionParams> (@params);
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
            yield reply_null_async (id, client, method);
            return;
        }

        Position pos = p.position;
        Vala.SourceFile doc = results[0].first;
        Compilation compilation = results[0].second;
        Vala.CodeContext.push (compilation.code_context);

        var fs = new FindSymbol (doc, pos, true);

        if (fs.result.size == 0) {
            debug (@"[$method] no results found");
            Vala.CodeContext.pop ();
            yield reply_null_async (id, client, method);
            return;
        }

        Vala.CodeNode result = get_best (fs, doc);
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
            yield reply_null_async (id, client, method);
            return;
        }

        symbol = (Vala.Symbol) result;

        debug ("[%s] got symbol %s @ %s", method, symbol.get_full_name (), symbol.source_reference.to_string ());

        // get references in all files
        var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
        foreach (var btarget in selected_project.get_compilations ())
            generated_vapis.add_all (btarget.output);
        var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
        bool is_abstract_or_virtual = 
            symbol is Vala.Property && (((Vala.Property)symbol).is_virtual || ((Vala.Property)symbol).is_abstract) ||
            symbol is Vala.Method && (((Vala.Method)symbol).is_virtual || ((Vala.Method)symbol).is_abstract) ||
            symbol is Vala.Signal && ((Vala.Signal)symbol).is_virtual;
        foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (selected_project, symbol))
            foreach (Vala.SourceFile project_file in btarget_w_sym.first.code_context.get_source_files ()) {
                // don't show symbol from generated VAPI
                var file = File.new_for_commandline_arg (project_file.filename);
                if (file in generated_vapis || file in shown_files)
                    continue;
                var file_references = new HashMap<Range, Vala.CodeNode> ();
                debug ("[%s] looking for references in %s ...", method, file.get_uri ());
                SymbolReferences.list_in_file (project_file, btarget_w_sym.second, true, file_references);
                if (is_abstract_or_virtual) {
                    debug ("[%s] looking for implementations of abstract/virtual symbol in %s ...", method, file.get_uri ());
                    SymbolReferences.list_implementations_of_virtual_symbol (project_file, btarget_w_sym.second, file_references);
                }
                if (!(project_file is TextDocument) && file_references.size > 0) {
                    // This means we have found references in a file that was added automatically,
                    // which should not be modified.
                    debug ("[%s] disallowing requested modification of %s", method, project_file.filename);
                    Vala.CodeContext.pop ();
                    yield reply_null_async (id, client, method);
                    return;
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
                CodeHelp.get_expression_representation (code_node), 
                code_node.source_reference.to_string ());
            var file = File.new_for_commandline_arg (code_node.source_reference.file.filename);
            if (!edits.has_key (file.get_uri ()))
                edits[file.get_uri ()] = new ArrayList<TextEdit> ();
            var file_edits = edits[file.get_uri ()];
            // if this is a using directive, we want to only replace the part after the 'using' keyword
            file_edits.add (new TextEdit () {
                range = source_range,
                newText = new_name
            });
            source_files[file.get_uri ()] = code_node.source_reference.file;
        }

        // TODO: determine support for TextDocumentEdit
        var text_document_edits_json = new Json.Array ();
        foreach (var uri in edits.keys) {
            text_document_edits_json.add_element (Json.gobject_serialize (new TextDocumentEdit () {
                textDocument = new VersionedTextDocumentIdentifier () {
                    version = ((TextDocument) source_files[uri]).version,
                    uri = uri
                },
                edits = edits[uri]
            }));
        }

        Vala.CodeContext.pop ();

        try {
            Variant changes = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (text_document_edits_json), null);
            yield client.reply_async (id, 
                build_dict (
                    documentChanges: changes
                ),
                cancellable
            );
        } catch (Error e) {
            warning ("[%s] failed to reply to client - %s", method, e.message);
        }
    }
    
    async void text_document_prepare_rename_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        // we cannot think of renaming things until everything is up-to-date
        try {
            yield wait_for_context_update_async (id, method);
        } catch (Error e) {
            yield reply_null_async (id, client, method);
            return;
        }

        var p = Util.parse_variant<TextDocumentPositionParams> (@params);
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
            yield reply_null_async (id, client, method);
            return;
        }

        Position pos = p.position;
        Vala.SourceFile doc = results[0].first;
        Compilation compilation = results[0].second;
        Vala.CodeContext.push (compilation.code_context);

        var fs = new FindSymbol (doc, pos, true);

        if (fs.result.size == 0) {
            Vala.CodeContext.pop ();
            try {
                yield client.reply_error_async (
                    id,
                    Jsonrpc.ClientError.INVALID_REQUEST,
                    "There is no symbol at the cursor.",
                    cancellable
                );
            } catch (Error e) {
                warning ("[%s] failed to reply with error - %s", method, e.message);
            }
            return;
        }

        Vala.CodeNode initial_result = get_best (fs, doc);
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
            try {
                yield client.reply_error_async (
                    id, 
                    Jsonrpc.ClientError.INVALID_REQUEST, 
                    "There is no symbol at the cursor.", 
                    cancellable
                );
            } catch (Error e) {
                warning ("[%s] failed to reply with error - %s", method, e.message);
            }
            return;
        }

        symbol = (Vala.Symbol) result;

        var replacement_range = SymbolReferences.get_replacement_range (initial_result, symbol);
        // If the source_reference is null, then this could be something like a
        // `this' parameter.
        if (replacement_range == null || symbol.source_reference == null) {
            Vala.CodeContext.pop ();
            try {
                yield client.reply_error_async (
                    id,
                    Jsonrpc.ClientError.INVALID_REQUEST,
                    "There is no symbol at the cursor.",
                    cancellable
                );
            } catch (Error e) {
                warning ("[%s] failed to reply with error - %s", method, e.message);
            }
            return;
        }

        foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (selected_project, symbol)) {
            if (!(btarget_w_sym.second.source_reference.file is TextDocument)) {
                // This means we have found references in a file that was added automatically,
                // which should not be modified.
                string? pkg = btarget_w_sym.second.source_reference.file.package_name;
                Vala.CodeContext.pop ();
                try {
                    yield client.reply_error_async (
                        id, 
                        Jsonrpc.ClientError.INVALID_REQUEST, 
                        "Cannot rename a symbol defined in a system library" + (pkg != null ? @" ($pkg)." : "."),
                        cancellable
                    );
                } catch (Error e) {
                    warning ("[%s] failed to reply with error - %s", method, e.message);
                }
                return;
            }
        }

        try {
            yield client.reply_async (id,
                build_dict (
                    range: Util.object_to_variant (replacement_range),
                    placeholder: new Variant.string (symbol.name)
                ),
                cancellable
            );
        } catch (Error e) {
            warning ("[%s] failed to reply with success - %s", method, e.message);
        }
        Vala.CodeContext.pop ();
    }

    /**
     * handle an incoming `textDocument/codeLens` request
     */
    async void text_document_code_lens_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        string? uri = document != null ? (string?) document.lookup_value ("uri", VariantType.STRING) : null;

        if (document == null || uri == null) {
            warning ("[%s] `textDocument` or `uri` not provided as expected", method);
            yield reply_null_async (id, client, method);
            return;
        }

        try {
            yield wait_for_context_update_async (id, method);
        } catch (Error e) {
            yield reply_null_async (id, client, method);
            return;
        }

        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        Project selected_project = null;
        foreach (var project in projects.get_keys_as_array ()) {
            results = project.lookup_compile_input_source_file (uri);
            if (!results.is_empty) {
                selected_project = project;
                break;
            }
        }
        // fallback to default project
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (uri);
            selected_project = default_project;
        }
        if (results.is_empty) {
            debug (@"file `$(Uri.unescape_string (uri))' not found");
            yield reply_null_async (id, client, method);
            return;
        }

        yield CodeLensEngine.begin_response_async (this, selected_project,
                                                   client, id, method,
                                                   results[0].first, results[0].second);
    }

    async void shutdown_reply_async (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        yield reply_null_async (id, client, method);
        shutdown ();
    }

    void exit (Jsonrpc.Client client, Variant @params) {
        shutdown ();
    }

    void shutdown () {
        debug ("shutting down...");
        this.shutting_down = true;
        cancellable.cancel ();
        if (client_closed_event_id != 0)
            this.disconnect (client_closed_event_id);
        foreach (var project in projects.get_keys_as_array ())
            project.disconnect (projects[project]);
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
    var loop = new MainLoop ();
    new Vls.Server (loop);
    loop.run ();
    return 0;
}
