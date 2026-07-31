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

class Vls.DiagnosticBatch {
    public Uri uri;
    public Diagnostic[] diagnostics;
    public string? discarded_uri;

    public DiagnosticBatch (Uri uri, Diagnostic[] diagnostics,
                            string? discarded_uri = null) {
        this.uri = uri;
        this.diagnostics = diagnostics;
        this.discarded_uri = discarded_uri;
    }
}

class Vls.Server : Lsp.Server {
    private static bool received_signal = false;
    MainLoop loop;

    InitializeParams init_params;

    const uint check_update_context_period_ms = 100;
    const int64 update_context_delay_inc_us = 500 * 1000;
    const int64 update_context_delay_max_us = 1000 * 1000;

    /**
     * Contains documentation from found GIR files.
     */
    GirDocumentation documentation;

    bool shutting_down = false;
    bool updating_context = false;

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

    /**
     * Use this in projects to keep track of target outputs and avoid
     * rebuilding dependent targets.
     */
    FileCache file_cache = new FileCache ();

    static construct {
        Process.@signal (ProcessSignal.INT, () => {
            Server.received_signal = true;
        });
        Process.@signal (ProcessSignal.TERM, () => {
            Server.received_signal = true;
        });
    }

    public Server (MainLoop loop) {
        base (loop);

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

        // shutdown if/when we get a signal
        Timeout.add (1000, check_signal);

        client_closed.connect ((_client) => {
            shutdown ();
            exit ();
        });
        accept_io_stream (new SimpleIOStream (input_stream, output_stream));

        this.projects = new HashTable<Project, ulong> (GLib.direct_hash, GLib.direct_equal);

        debug ("Finished constructing");
    }

    bool check_signal () {
        if (Server.received_signal) {
            shutdown ();
            exit ();
            return Source.REMOVE;
        }
        return !this.shutting_down;
    }

    /**
     * Find a file with a URI. Will pick the first match.
     *
     * @param uri the URI of the file. may contain escape characters
     */
    Vala.SourceFile? find_file (string uri, out Compilation? compilation = null, out Project? project = null) {
        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
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

    protected override async InitializeResult initialize_async (Lsp.Client client,
                                                                InitializeParams init_params)
                                                                throws Error {
        this.init_params = init_params;

        File root_dir;
        if (init_params.root_uri != null)
            root_dir = File.new_for_uri (init_params.root_uri.to_string ());
        else if (init_params.root_path != null)
            root_dir = File.new_for_path (init_params.root_path);
        else
            root_dir = File.new_for_path (Environment.get_current_dir ());
        if (!root_dir.is_native ()) {
            yield client.show_message_async (
                MessageType.ERROR, "Non-native files not supported");
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
                    var message = @"Failed to initialize Meson project - $(e.message)";
                    warning ("%s", message);
                    yield client.show_message_async (MessageType.ERROR, message);
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
                yield client.show_message_async (
                    MessageType.WARNING,
                    @"CMake build system is not currently supported. Only Meson is. See https://github.com/vala-lang/vala-language-server/issues/73");
            if (autogen_sh.query_exists (cancellable))
                yield client.show_message_async (
                    MessageType.WARNING,
                    @"Autotools build system is not currently supported. Consider switching to Meson.");
        } else {
            new_projects.add (backend_project);
        }

        // always have default project
        default_project = new DefaultProject (root_path, file_cache);

        // build and publish diagnostics
        foreach (var project in new_projects) {
            try {
                debug ("Building project ...");
                project.build_if_stale ();
            } catch (Error e) {
                var message = @"Failed to build project - $(e.message)";
                warning ("%s", message);
                yield client.show_message_async (MessageType.ERROR, message);
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

        // listen for context update requests
        Timeout.add (check_update_context_period_ms, check_update_context);

        // listen for project changed events
        foreach (Project project in new_projects)
            projects[project] = project.changed.connect (project_changed_event);

        var capabilities = new ServerCaps () {
            text_document_sync = TextDocumentSyncKind.INCREMENTAL,
            definition = true,
            document_symbol = true,
            completion = new CompletionOptions (false, {".", ">"}),
            signature_help = new SignatureHelpOptions ({"(", "[", ","}),
            code_action = true,
            hover = true,
            references = true,
            document_highlight = true,
            document_formatting = true,
            document_range_formatting = true,
            implementation = true,
            workspace_symbol = true,
            rename = RenameOptions (true),
            code_lens = CodeLensOptions (false),
            call_hierarchy = CallHierarchyOptions (),
            inlay_hint = InlayHintOptions (),
            type_hierarchy = TypeHierarchyOptions ()
        };
        var result = new InitializeResult (capabilities);
        result.server_info = new ServerInfo (
            "Vala Language Server", Config.PROJECT_VERSION);
        return result;
    }

    protected override async void initialized_async (Lsp.Client client) throws Error {
        update_context_client = client;
        request_context_update (client);
    }

    void project_changed_event () {
        if (update_context_client != null)
            request_context_update ((!) update_context_client);
        debug ("requested context update for project change event");
    }

    protected override async void text_document_did_open_async (Lsp.Client client,
                                                                TextDocumentItem text_document)
                                                                throws Error {
        var uri = text_document.uri.to_string ();
        if (text_document.language_id != LanguageId.VALA &&
            text_document.language_id != LanguageId.GENIE) {
            warning (@"[textDocument/didOpen] $(text_document.language_id.to_string ()) file sent to vala language server");
            return;
        }

        Pair<Vala.SourceFile, Compilation>? doc_w_bt = null;

        foreach (var project in projects.get_keys_as_array ()) {
            try {
                doc_w_bt = project.open (uri, text_document.text, cancellable).first ();
                break;
            } catch (Error e) {
                if (!(e is ProjectError.NOT_FOUND))
                    warning ("[textDocument/didOpen] failed to open %s - %s", Uri.unescape_string (uri), e.message);
            }
        }

        // fallback to default project
        if (doc_w_bt == null) {
            try {
                doc_w_bt = default_project.open (uri, text_document.text, cancellable).first ();
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
            tdoc.last_saved_content = text_document.text;
            tdoc.version = (int) text_document.version;
            if (tdoc.content != text_document.text) {
                tdoc.content = text_document.text;
                request_context_update (client);
                debug (@"[textDocument/didOpen] requested context update");
            }
        } else {
            debug (@"[textDocument/didOpen] opened read-only $(Uri.unescape_string (uri))");
        }

        // add document to open list
        open_files.add (uri);
    }

    protected override async void text_document_did_save_async (Lsp.Client client,
                                                                TextDocumentIdentifier text_document,
                                                                string? text) throws Error {
        var uri = text_document.uri.to_string ();

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;

        foreach (var project in all_projects) {
            foreach (var pair in project.lookup_compile_input_source_file (uri)) {
                var saved_document = pair.first as TextDocument;

                if (saved_document == null) {
                    warning ("[textDocument/didSave] ignoring save to system file");
                    continue;
                }

                // make checkpoint
                saved_document.last_saved_content = saved_document.content;
                debug ("[textDocument/didSave] last save of %s is now at version %d", uri, saved_document.last_saved_version);
            }
        }
    }

    protected override async void text_document_did_close_async (Lsp.Client client,
                                                                 TextDocumentIdentifier text_document)
                                                                 throws Error {
        var uri = text_document.uri.to_string ();

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

    Lsp.Client? update_context_client = null;
    int64 update_context_requests = 0;
    int64 update_context_time_us = 0;

    protected override async void text_document_did_change_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        (unowned TextDocumentContentChangeEvent)[] content_changes) throws Error {
        var uri = text_document.uri.to_string ();
        if (text_document.version == null) {
            warning ("[textDocument/didChange] missing document version for %s", uri);
            return;
        }
        int64 version = (!) text_document.version;

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
                var sb = new StringBuilder (source.content);
                foreach (var change in content_changes) {
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
    void request_context_update (Lsp.Client client) {
        update_context_client = client;
        update_context_requests += 1;
        int64 delay_us = int64.min (update_context_delay_inc_us * update_context_requests, update_context_delay_max_us);
        update_context_time_us = get_monotonic_time () + delay_us;
        // debug (@"Context(s) update (re-)scheduled in $((int) (delay_us / 1000)) ms");
    }

    /** 
     * Reconfigure the project if needed, and check whether we need to rebuild
     * the project and documentation engine if we have context update requests.
     */
    bool check_update_context () {
        if (!updating_context && update_context_client != null &&
            update_context_requests > 0 && get_monotonic_time () >= update_context_time_us) {
            update_context_async.begin ((!) update_context_client, (obj, result) => {
                try {
                    update_context_async.end (result);
                } catch (Error e) {
                    warning ("Failed to update context: %s", e.message);
                }
            });
        }
        return !this.shutting_down;
    }

    public async void wait_for_context_update_async (
        Cancellable request_cancellable) throws Error {
        while (updating_context || update_context_requests > 0) {
            request_cancellable.set_error_if_cancelled ();
            if (!updating_context && update_context_client != null &&
                get_monotonic_time () >= update_context_time_us) {
                yield update_context_async ((!) update_context_client);
                continue;
            }

            Timeout.add (check_update_context_period_ms,
                wait_for_context_update_async.callback);
            yield;
        }
        request_cancellable.set_error_if_cancelled ();
    }

    async void update_context_async (Lsp.Client client) throws Error {
        if (updating_context || update_context_requests == 0)
            return;

        updating_context = true;
        try {
            DiagnosticBatch[] batches;
            string[] error_messages;
            rebuild_contexts (out batches, out error_messages);

            foreach (var message in error_messages) {
                try {
                    yield client.show_message_async (MessageType.ERROR, message);
                } catch (Error e) {
                    debug (@"showMessage: failed to notify client: $(e.message)");
                }
            }

            foreach (var batch in batches) {
                try {
                    yield client.publish_diagnostics_async (batch.uri, batch.diagnostics);
                    if (batch.discarded_uri != null)
                        discarded_files.remove ((!) batch.discarded_uri);
                } catch (Error e) {
                    warning ("[publishDiagnostics] failed to publish diagnostics for %s: %s",
                        batch.uri.to_string (), e.message);
                }
            }
        } finally {
            updating_context = false;
        }
    }

    void rebuild_contexts (out DiagnosticBatch[] batches, out string[] error_messages) {
        debug ("updating contexts and collecting diagnostics...");
        update_context_requests = 0;
        update_context_time_us = 0;
        DiagnosticBatch[] collected_batches = {};
        string[] collected_error_messages = {};

        foreach (string discarded_uri in discarded_files) {
            try {
                collected_batches += new DiagnosticBatch (
                    Uri.parse (discarded_uri, UriFlags.NONE), {}, discarded_uri);
            } catch (UriError e) {
                warning ("Invalid discarded file URI %s: %s", discarded_uri, e.message);
            }
        }

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;
        bool reconfigured_projects = false;
        foreach (var project in all_projects) {
            try {
                bool reconfigured = project.reconfigure_if_stale (cancellable);
                reconfigured_projects |= reconfigured;
                project.build_if_stale (cancellable);

                if (reconfigured && project != default_project) {
                    var newly_added = new HashSet<string> ();
                    foreach (var compilation in project.get_compilations ()) {
                        newly_added.add_all_iterator (
                            compilation.get_project_files ().map<string> (f => f.filename));
                    }
                    foreach (var compilation in default_project.get_compilations ()) {
                        foreach (var source_file in compilation.get_project_files ()) {
                            if (newly_added.contains (source_file.filename)) {
                                var uri = File.new_for_path (source_file.filename).get_uri ();
                                try {
                                    default_project.close (uri);
                                    discarded_files.add (uri);
                                    collected_batches += new DiagnosticBatch (
                                        Uri.parse (uri, UriFlags.NONE), {}, uri);
                                    debug ("discarding %s from DefaultProject", uri);
                                } catch (Error e) {
                                    // The file may already have moved out of the default project.
                                }
                            }
                        }
                    }
                }

                foreach (var compilation in project.get_compilations ()) {
                    foreach (var batch in collect_diagnostics (project, compilation))
                        collected_batches += batch;
                }
            } catch (Error e) {
                warning ("Failed to rebuild and/or reconfigure project: %s", e.message);
                collected_error_messages +=
                    @"Failed to rebuild/reconfigure project: $(e.message)";
            }
        }

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
                    var opened = default_project.open (uri, null, cancellable).first ();
                    var document = opened.first;
                    if (document.content == null)
                        document.get_mapped_contents ();
                    if (document is TextDocument)
                        ((TextDocument) document).last_saved_content = document.content;
                    foreach (var batch in collect_diagnostics (default_project, opened.second))
                        collected_batches += batch;
                } catch (Error e) {
                    warning ("Failed to reopen in default project %s - %s", uri, e.message);
                    try {
                        collected_batches += new DiagnosticBatch (
                            Uri.parse (uri, UriFlags.NONE), {}, uri);
                    } catch (UriError uri_error) {
                        warning ("Invalid orphaned file URI %s: %s", uri, uri_error.message);
                    }
                }
            }
        }

        documentation.rebuild_if_stale ();
        batches = collected_batches;
        error_messages = collected_error_messages;
    }

    DiagnosticBatch[] collect_diagnostics (Project project, Compilation target) {
        Diagnostic[] diagnostics_without_source = {};
        var document_diagnostics = new HashMap<Vala.SourceFile, ArrayList<Diagnostic>?> ();

        debug ("collecting diagnostics for Compilation target %s", target.id);
        foreach (var file in target.code_context.get_source_files ())
            document_diagnostics[file] = null;

        target.reporter.messages.foreach (message => {
            if (message.loc == null) {
                var diagnostic = new Diagnostic (
                    message.message,
                    Range (Position (1, 1), Position (1, 1)));
                diagnostic.severity = message.severity;
                diagnostics_without_source += diagnostic;
                return;
            }

            assert (message.loc.file != null);
            if (!(message.loc.file in target.code_context.get_source_files ())) {
                warning (@"diagnostic has source not in compilation! - $(message.message)");
                return;
            }

            var range = Range (
                Position (message.loc.begin.line - 1, message.loc.begin.column - 1),
                Position (message.loc.end.line - 1, message.loc.end.column));
            var diagnostic = new Diagnostic (message.message, range);
            diagnostic.severity = message.severity;
            if (document_diagnostics[message.loc.file] == null)
                document_diagnostics[message.loc.file] = new ArrayList<Diagnostic> ();
            document_diagnostics[message.loc.file].add (diagnostic);
        });

        DiagnosticBatch[] batches = {};
        foreach (var entry in document_diagnostics.entries) {
            Diagnostic[] diagnostics = {};
            if (entry.value != null)
                diagnostics = ((!) entry.value).to_array ();
            var file = File.new_for_commandline_arg_and_cwd (
                entry.key.filename, target.code_context.directory);
            batches += new DiagnosticBatch (Util.uri_from_file (file), diagnostics);
        }
        batches += new DiagnosticBatch (
            Util.uri_from_filename (project.root_path), diagnostics_without_source);
        return batches;
    }

    public static Vala.CodeNode get_best (NodeSearch fs, Vala.SourceFile file) {
        Vala.CodeNode? best = null;

        foreach (var node in fs.result) {
            if (best == null) {
                best = node;
            } else {
                var best_begin = Util.position_from_libvala (best.source_reference.begin);
                var best_end = Util.position_from_libvala (best.source_reference.end);
                var node_begin = Util.position_from_libvala (node.source_reference.begin);
                var node_end = Util.position_from_libvala (node.source_reference.end);

                // it turns out that if multiple CodeNodes share the same range, the first one we
                // encounter will usually be the "right" one
                if (Util.position_compare (best_begin, node_begin) <= 0 &&
                    Util.position_compare (node_end, best_end) <= 0 &&
                    (!(Util.position_compare (best_begin, node_begin) == 0 &&
                       Util.position_compare (node_end, best_end) == 0) ||
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

    protected override async Location[]? definition_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position) throws Error {
        yield wait_for_context_update_async (client.cancellable);

        const string method = "textDocument/definition";
        Compilation compilation;
        Project project;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? file = find_file (uri, out compilation, out project);
        if (file == null) {
            string message = "[%s] file `%s' not found".printf (method, uri);
            debug ("%s", message);
            yield client.log_trace_async (message);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var search = new NodeSearch (file, position, true);
            if (search.result.size == 0) {
                debug ("[%s] find symbol is empty", method);
                return null;
            }

            Vala.CodeNode best = get_best (search, file);
            if (best is Vala.Expression && !(best is Vala.Literal)) {
                var expression = (Vala.Expression) best;
                if (expression.symbol_reference != null &&
                    expression.symbol_reference.source_reference != null)
                    best = expression.symbol_reference;
            } else if (best is Vala.DataType) {
                best = SymbolReferences.get_symbol_data_type_refers_to ((Vala.DataType) best);
            } else if (best is Vala.UsingDirective) {
                best = ((Vala.UsingDirective) best).namespace_symbol;
            } else if (best is Vala.Method) {
                var method_symbol = (Vala.Method) best;
                if (method_symbol.base_interface_method != method_symbol &&
                    method_symbol.base_interface_method != null)
                    best = method_symbol.base_interface_method;
                else if (method_symbol.base_method != method_symbol &&
                         method_symbol.base_method != null)
                    best = method_symbol.base_method;
            } else if (best is Vala.Property) {
                var property = (Vala.Property) best;
                if (property.base_interface_property != property &&
                    property.base_interface_property != null)
                    best = property.base_interface_property;
                else if (property.base_property != property &&
                         property.base_property != null)
                    best = property.base_property;
            } else {
                debug ("[%s] best is %s, which we can't handle", method, best.type_name);
                return null;
            }

            if (best is Vala.Symbol)
                best = SymbolReferences.find_real_symbol (project, (Vala.Symbol) best);
            if (best.source_reference == null)
                return null;

            var location = Util.location_from_sourceref (best.source_reference);
            debug ("[%s] found location %s", method, location.uri.to_string ());
            Location[] locations = {location};
            return locations;
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    protected override async DocumentSymbolResult? document_symbol_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document) throws Error {
        yield wait_for_context_update_async (client.cancellable);

        const string method = "textDocument/documentSymbol";
        Compilation compilation;
        Project project;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? file = find_file (uri, out compilation, out project);
        if (file == null) {
            string message = "[%s] file `%s' not found".printf (method, uri);
            debug ("%s", message);
            yield client.log_trace_async (message);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var symbols = compilation.get_analysis_for_file<SymbolEnumerator> (file);
            var text_caps = init_params.capabilities.text_document;
            bool hierarchical = text_caps != null &&
                DocumentSymbolClientFlags.HIERARCHICAL_DOCUMENT_SYMBOLS in
                    text_caps.document_symbol.flags;
            if (hierarchical) {
                DocumentSymbol[] document_symbols = {};
                foreach (var symbol in symbols)
                    document_symbols += symbol;
                return new DocumentSymbolResult.for_document_symbols (document_symbols);
            }

            SymbolInformation[] symbol_information = {};
            foreach (var symbol in symbols.flattened ())
                symbol_information += symbol;
            return new DocumentSymbolResult.for_symbol_information (symbol_information);
        } finally {
            Vala.CodeContext.pop ();
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

    protected override async CompletionItem[]? completion_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position,
        CompletionContext? context) throws Error {
        Compilation compilation;
        Project project;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? file = find_file (uri, out compilation, out project);
        if (file == null) {
            string message = "[textDocument/completion] file `%s' not found".printf (uri);
            debug ("%s", message);
            yield client.log_trace_async (message);
            return null;
        }

        return yield CompletionEngine.complete_async (
            this, project, file, compilation, position, context, client.cancellable);
    }

    protected override async SignatureHelp? signature_help_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position) throws Error {
        Compilation compilation;
        Project project;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? file = find_file (uri, out compilation, out project);
        if (file == null) {
            string message = "[textDocument/signatureHelp] file `%s' not found".printf (uri);
            debug ("%s", message);
            yield client.log_trace_async (message);
            return null;
        }

        return yield SignatureHelpEngine.get_async (
            this, project, file, compilation, position, client.cancellable);
    }

    protected override async Hover? hover_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position) throws Error {
        yield wait_for_context_update_async (client.cancellable);

        const string method = "textDocument/hover";
        Compilation compilation;
        Project project;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? doc = find_file (uri, out compilation, out project);
        if (doc == null) {
            string message = "[%s] file `%s' not found".printf (method, uri);
            debug ("%s", message);
            yield client.log_trace_async (message);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var search = new NodeSearch (doc, position, true);
            if (search.result.size == 0)
                return null;

            Vala.Scope scope = (new FindScope (doc, position)).best_block.scope;
            Vala.CodeNode result = get_best (search, doc);
            // don't show lambda expressions on hover
            // don't show property accessors
            if (result is Vala.Method && ((Vala.Method)result).closure ||
                result is Vala.PropertyAccessor)
                return null;

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

            Range? hover_range = null;
            Range? symbol_range = null;
            if (symbol != null) {
                symbol_range = SymbolReferences.get_replacement_range (result, symbol);
                if (symbol_range != null) {
                    Range range = (!) symbol_range;
                    // if the symbol range does not include the cursor, then try
                    // to get the hidden symbol at the cursor first
                    bool found_component = false;
                    if (!Util.range_contains (range, position)) {
                        foreach (var component in SymbolReferences.get_visible_components_of_code_node (result)) {
                            if (component.second != null &&
                                Util.range_contains ((!) component.second, position)) {
                                hover_range = (!) component.second;
                                symbol = component.first;
                                data_type = null;
                                method_type_arguments = null;
                                found_component = true;
                                break;
                            }
                        }
                    }
                    if (!found_component)
                        hover_range = range;
                }
            }

            if (symbol_range == null)
                hover_range = Util.range_from_sourceref (result.source_reference);

            string? representation = CodeHelp.get_symbol_representation (data_type, symbol, scope, true, method_type_arguments);
            if (representation == null)
                return null;

            var contents = new StringBuilder ("```vala\n");
            contents.append (representation);
            contents.append ("\n```");
            if (symbol != null) {
                var comment = get_symbol_documentation (project, symbol);
                if (comment != null) {
                    contents.append ("\n\n");
                    contents.append (comment.body);
                }
            }

            return new Hover (
                new MarkupContent (MarkupKind.MARKDOWN, contents.str), hover_range);
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    DocumentHighlightKind determine_node_highlight_kind (Vala.CodeNode node) {
        Vala.CodeNode? previous_node = node;

        for (Vala.CodeNode? current_node = node.parent_node;
             current_node != null;
             current_node = current_node.parent_node,
            previous_node = current_node) {
            if (current_node is Vala.MethodCall)
                return DocumentHighlightKind.READ;
            else if (current_node is Vala.Assignment) {
                if (previous_node == ((Vala.Assignment)current_node).left)
                    return DocumentHighlightKind.WRITE;
                else if (previous_node == ((Vala.Assignment)current_node).right)
                    return DocumentHighlightKind.READ;
            } else if (current_node is Vala.DeclarationStatement &&
                node == ((Vala.DeclarationStatement)current_node).declaration)
                return DocumentHighlightKind.WRITE;
            else if (current_node is Vala.ForeachStatement &&
                node == ((Vala.ForeachStatement)current_node).element_variable)
                return DocumentHighlightKind.WRITE;
            else if (current_node is Vala.Statement)
                return DocumentHighlightKind.READ;
        }

        return DocumentHighlightKind.TEXT;
    }

    protected override async Location[]? references_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position,
        ReferenceContext context) throws Error {
        yield wait_for_context_update_async (client.cancellable);

        Location[] locations;
        DocumentHighlight[] highlights;
        if (!find_references (text_document, position, context.include_declaration,
                              false, out locations, out highlights))
            return null;
        return locations;
    }

    protected override async DocumentHighlight[]? document_highlight_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position) throws Error {
        yield wait_for_context_update_async (client.cancellable);

        Location[] locations;
        DocumentHighlight[] highlights;
        if (!find_references (text_document, position, true, true,
                              out locations, out highlights))
            return null;
        return highlights;
    }

    bool find_references (TextDocumentIdentifier text_document, Position position,
                          bool include_declaration, bool is_highlight,
                          out Location[] locations,
                          out DocumentHighlight[] highlights) {
        const string method = "textDocument/references";
        locations = {};
        highlights = {};
        Location[] found_locations = {};
        DocumentHighlight[] found_highlights = {};

        Compilation compilation;
        Project project;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? doc = find_file (uri, out compilation, out project);
        if (doc == null) {
            debug ("[%s] file `%s' not found", method, uri);
            return false;
        }

        Vala.CodeContext.push (compilation.code_context);

        var fs = new NodeSearch (doc, position, true);

        if (fs.result.size == 0) {
            debug (@"[$method] no results found");
            Vala.CodeContext.pop ();
            return false;
        }

        Vala.CodeNode result = get_best (fs, doc);
        Vala.Symbol symbol;
        var references = new Gee.HashMap<SourceRange, Vala.CodeNode> ();

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
            return false;
        }

        symbol = (Vala.Symbol) result;

        debug (@"[$method] got best: $result ($(result.type_name))");
        if (is_highlight || symbol is Vala.LocalVariable) {
            // if highlight, show references in current file
            // otherwise, we may also do this if it's a local variable, since
            // Server.get_compilations_using_symbol() only works for global symbols
            SymbolReferences.list_in_file (doc, symbol, include_declaration, true, references);
        } else {
            // show references in all files
            var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in project.get_compilations ())
                generated_vapis.add_all (btarget.output);
            var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol))
                foreach (Vala.SourceFile project_file in btarget_w_sym.first.code_context.get_source_files ()) {
                    // don't show symbol from generated VAPI
                    var file = File.new_for_commandline_arg (project_file.filename);
                    if (file in generated_vapis || file in shown_files)
                        continue;
                    SymbolReferences.list_in_file (project_file, btarget_w_sym.second, include_declaration, true, references);
                    shown_files.add (file);
                }
        }

        debug (@"[$method] found $(references.size) reference(s)");
        foreach (var entry in references) {
            if (is_highlight) {
                found_highlights += DocumentHighlight (
                    entry.key.range, determine_node_highlight_kind (entry.value));
            } else {
                found_locations += Util.location_from_filename (
                    entry.key.filename, entry.key.range);
            }
        }

        Vala.CodeContext.pop ();
        locations = found_locations;
        highlights = found_highlights;
        return true;
    }

    protected override async Location[]? implementation_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position) throws Error {
        yield wait_for_context_update_async (client.cancellable);

        const string method = "textDocument/implementation";
        Compilation compilation;
        Project project;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? doc = find_file (uri, out compilation, out project);
        if (doc == null) {
            string message = "[%s] file `%s' not found".printf (method, uri);
            debug ("%s", message);
            yield client.log_trace_async (message);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var search = new NodeSearch (doc, position, true);
            if (search.result.size == 0) {
                debug (@"[$method] no results found");
                return null;
            }

            Vala.CodeNode result = get_best (search, doc);
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
                return null;
            } else {
                symbol = (Vala.Symbol) result;
            }

            // show references in all files
            var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in project.get_compilations ())
                generated_vapis.add_all (btarget.output);
            var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol)) {
                foreach (var file in btarget_w_sym.first.code_context.get_source_files ()) {
                    var gfile = File.new_for_commandline_arg (file.filename);
                    // don't show symbol from generated VAPI
                    if (gfile in generated_vapis || gfile in shown_files)
                        continue;

                    NodeSearch fs2;
                    if (is_abstract_type) {
                        fs2 = new NodeSearch.with_filter (file, btarget_w_sym.second,
                        (needle, node) => node is Vala.ObjectTypeSymbol && 
                            ((Vala.ObjectTypeSymbol)node).is_subtype_of ((Vala.ObjectTypeSymbol) needle), false);
                    } else if (is_abstract_or_virtual_method) {
                        fs2 = new NodeSearch.with_filter (file, btarget_w_sym.second,
                        (needle, node) => needle != node && (node is Vala.Method) && 
                            (((Vala.Method)node).base_method == needle ||
                            ((Vala.Method)node).base_interface_method == needle), false);
                    } else {
                        fs2 = new NodeSearch.with_filter (file, symbol,
                        (needle, node) => needle != node && (node is Vala.Property) &&
                            (((Vala.Property)node).base_property == needle ||
                            ((Vala.Property)node).base_interface_property == needle), false);
                    }
                    references.add_all (fs2.result);
                    shown_files.add (gfile);
                }
            }

            debug (@"[$method] found $(references.size) reference(s)");
            Location[] locations = {};
            foreach (var node in references) {
                Vala.CodeNode real_node = node;
                if (node is Vala.Symbol)
                    real_node = SymbolReferences.find_real_symbol (project, (Vala.Symbol) node);
                if (real_node.source_reference != null)
                    locations += Util.location_from_sourceref (real_node.source_reference);
            }
            return locations;
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    protected override async TextEdit[]? formatting_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        FormattingOptions options) throws Error {
        return format (text_document, options, null);
    }

    protected override async TextEdit[]? range_formatting_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Range range,
        FormattingOptions options) throws Error {
        return format (text_document, options, range);
    }

    TextEdit[]? format (TextDocumentIdentifier text_document,
                        FormattingOptions options, Range? range) throws Error {
        Compilation compilation;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? source_file = find_file (uri, out compilation);
        if (source_file == null) {
            debug ("[textDocument/formatting] file `%s' not found", uri);
            return null;
        }

        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (source_file);
        var edit = Formatter.format (
            options, code_style, source_file, range, cancellable);
        TextEdit[] edits = {edit};
        return edits;
    }

    protected override async Lsp.Action[]? code_action_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Range range,
        CodeActionContext context) throws Error {
        Compilation compilation;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? source_file = find_file (uri, out compilation);
        if (source_file == null) {
            debug ("[textDocument/codeAction] file `%s' not found", uri);
            return null;
        }

        if (!(source_file is TextDocument))
            return null;

        Vala.CodeContext.push (compilation.code_context);
        var code_actions = CodeActions.extract (
            context, compilation, (TextDocument) source_file, range, text_document.uri);
        Vala.CodeContext.pop ();

        Lsp.Action[] actions = {};
        foreach (var action in code_actions)
            actions += action;
        return actions;
    }

    protected override async SymbolInformation[]? workspace_symbol_async (
        Lsp.Client client,
        string query) throws Error {
        yield wait_for_context_update_async (client.cancellable);

        SymbolInformation[] symbols = {};
        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;
        foreach (var project in all_projects) {
            foreach (var source_pair in project.get_project_source_files ()) {
                var text_document = source_pair.key;
                var compilation = source_pair.value;
                Vala.CodeContext.push (compilation.code_context);
                try {
                    var symbol_enumerator = compilation.get_analysis_for_file<SymbolEnumerator> (text_document);
                    if (symbol_enumerator != null) {
                        foreach (var symbol in symbol_enumerator.flattened ()) {
                            // Keep query as the receiver until string.match_string()
                            // introspection is corrected.
                            if (query.match_string (symbol.name, true))
                                symbols += symbol;
                        }
                    }
                } finally {
                    Vala.CodeContext.pop ();
                }
            }
        }

        debug ("[workspace/symbol] found %d element(s) matching `%s'",
            symbols.length, query);
        return symbols;
    }

    protected override async WorkspaceEdit? rename_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position,
        string new_name) throws Error {
        const string method = "textDocument/rename";
        // before anything, sanity-check the new symbol name
        if (!/^(?=[^\d])[^\s~`!#%^&*()\-\+={}\[\]|\\\/?.>,<'";:]+$/.match (new_name)) {
            throw new ProtocolError.INVALID_PARAMS (
                "Invalid symbol name. Symbol names cannot start with a number " +
                "and must not contain any operators.");
        }

        yield wait_for_context_update_async (client.cancellable);

        Project project;
        Compilation compilation;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? doc = find_file (uri, out compilation, out project);
        if (doc == null) {
            debug ("[%s] file `%s' not found", method, uri);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var search = new NodeSearch (doc, position, true);
            if (search.result.size == 0) {
                debug (@"[$method] no results found");
                return null;
            }

            Vala.CodeNode result = get_best (search, doc);
            Vala.Symbol symbol;
            var references = new Gee.HashMap<SourceRange, Vala.CodeNode> ();

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
                return null;
            }

            symbol = (Vala.Symbol) result;
            if (symbol.source_reference == null)
                return null;
            debug ("[%s] got symbol %s @ %s", method, symbol.get_full_name (),
                symbol.source_reference.to_string ());

            // get references in all files
            var generated_vapis = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var btarget in project.get_compilations ())
                generated_vapis.add_all (btarget.output);
            var shown_files = new HashSet<File> (Util.file_hash, Util.file_equal);
            bool is_abstract_or_virtual = 
                symbol is Vala.Property && (((Vala.Property)symbol).is_virtual || ((Vala.Property)symbol).is_abstract) ||
                symbol is Vala.Method && (((Vala.Method)symbol).is_virtual || ((Vala.Method)symbol).is_abstract) ||
                symbol is Vala.Signal && ((Vala.Signal)symbol).is_virtual;
            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol))
                foreach (Vala.SourceFile project_file in btarget_w_sym.first.code_context.get_source_files ()) {
                    // don't show symbol from generated VAPI
                    var file = File.new_for_commandline_arg (project_file.filename);
                    if (file in generated_vapis || file in shown_files)
                        continue;
                    var file_references = new HashMap<SourceRange, Vala.CodeNode> ();
                    debug ("[%s] looking for references in %s ...", method, file.get_uri ());
                    SymbolReferences.list_in_file (project_file, btarget_w_sym.second, true, false, file_references);
                    if (is_abstract_or_virtual) {
                        debug ("[%s] looking for implementations of abstract/virtual symbol in %s ...", method, file.get_uri ());
                        SymbolReferences.list_implementations_of_virtual_symbol (project_file, btarget_w_sym.second, file_references);
                    }
                    if (!(project_file is TextDocument) && file_references.size > 0) {
                        // This means we have found references in a file that was added automatically,
                        // which should not be modified.
                        debug ("[%s] disallowing requested modification of %s", method, project_file.filename);
                        throw new ProtocolError.REQUEST_FAILED (
                            "Cannot rename a symbol defined in a system library.");
                    }
                    foreach (var entry in file_references)
                        references[entry.key] = entry.value;
                    shown_files.add (file);
                }
            
            debug ("[%s] found %d references", method, references.size);
            
            // construct the edits for the text documents
            // map: file URI -> TextEdit[]
            var edits = new HashMap<string, ArrayList<TextEdit?>> ();
            var source_files = new HashMap<string, Vala.SourceFile> ();

            foreach (var entry in references) {
                var code_node = entry.value;
                Range source_range = entry.key.range;
                debug ("[%s] editing reference %s @ %s ...", 
                    method, 
                    CodeHelp.get_code_node_source (code_node), 
                    code_node.source_reference.to_string ());
                var file = File.new_for_commandline_arg (entry.key.filename);
                if (!edits.has_key (file.get_uri ()))
                    edits[file.get_uri ()] = new ArrayList<TextEdit?> ();
                var file_edits = edits[file.get_uri ()];
                // if this is a using directive, we want to only replace the part after the 'using' keyword
                file_edits.add (TextEdit (source_range, new_name));
                source_files[file.get_uri ()] = code_node.source_reference.file;
            }

            var workspace_edit = new WorkspaceEdit ();
            foreach (var edit_uri in edits.keys) {
                TextEdit[] document_edits = {};
                foreach (var edit in edits[edit_uri])
                    document_edits += (!) edit;
                var document_id = TextDocumentIdentifier (
                    Uri.parse (edit_uri, UriFlags.NONE),
                    ((TextDocument) source_files[edit_uri]).version);
                workspace_edit.add_document_change (new TextDocumentEdit (
                    document_id, document_edits));
            }
            return workspace_edit;
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    protected override async PrepareRenameResult? prepare_rename_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position) throws Error {
        yield wait_for_context_update_async (client.cancellable);

        const string method = "textDocument/prepareRename";
        Project project;
        Compilation compilation;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? doc = find_file (uri, out compilation, out project);
        if (doc == null) {
            debug ("[%s] file `%s' not found", method, uri);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var search = new NodeSearch (doc, position, true);
            if (search.result.size == 0)
                throw new ProtocolError.REQUEST_FAILED (
                    "There is no symbol at the cursor.");

            Vala.CodeNode initial_result = get_best (search, doc);
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
                throw new ProtocolError.REQUEST_FAILED (
                    "There is no symbol at the cursor.");
            }

            symbol = (Vala.Symbol) result;

            var replacement_range = SymbolReferences.get_replacement_range (initial_result, symbol);
            // If the source_reference is null, then this could be something like a
            // `this' parameter.
            if (replacement_range == null || symbol.source_reference == null)
                throw new ProtocolError.REQUEST_FAILED (
                    "There is no symbol at the cursor.");

            foreach (var btarget_w_sym in SymbolReferences.get_compilations_using_symbol (project, symbol)) {
                if (!(btarget_w_sym.second.source_reference.file is TextDocument)) {
                    // This means we have found references in a file that was added automatically,
                    // which should not be modified.
                    string? pkg = btarget_w_sym.second.source_reference.file.package_name;
                    throw new ProtocolError.REQUEST_FAILED (
                        "Cannot rename a symbol defined in a system library" +
                        (pkg != null ? @" ($pkg)." : "."));
                }
            }

            return PrepareRenameResult.for_range ((!) replacement_range, symbol.name);
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    protected override async CodeLens[]? code_lens_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document) throws Error {
        yield wait_for_context_update_async (client.cancellable);

        Compilation compilation;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? file = find_file (uri, out compilation);
        if (file == null) {
            debug ("[textDocument/codeLens] file `%s' not found", uri);
            return null;
        }

        return CodeLensEngine.get (file, compilation);
    }

    protected override async CallHierarchyItem[]? prepare_call_hierarchy_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position) throws Error {
        const string method = "textDocument/prepareCallHierarchy";
        Project project;
        Compilation compilation;
        var uri = text_document.uri.to_string ();
        Vala.SourceFile? doc = find_file (uri, out compilation, out project);
        if (doc == null) {
            debug ("[%s] file `%s' not found", method, uri);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var search = new NodeSearch (doc, position);
            if (search.result.size == 0) {
                debug (@"[$method] no results found");
                return null;
            }

            Vala.CodeNode result = get_best (search, doc);
            Vala.Method? method_symbol = null;
            if (result is Vala.Method)
                method_symbol = (Vala.Method) result;
            else if (result is Vala.MethodCall)
                method_symbol = ((Vala.MethodCall) result).call.symbol_reference as Vala.Method;
            else if (result is Vala.Expression &&
                     ((Vala.Expression) result).symbol_reference is Vala.Method)
                method_symbol = (Vala.Method) ((Vala.Expression) result).symbol_reference;

            if (method_symbol == null)
                return null;
            CallHierarchyItem[] items = {
                CallHierarchy.item_from_symbol (method_symbol)
            };
            return items;
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    protected override async CallHierarchyIncomingCall[]? incoming_calls_async (
        Lsp.Client client,
        CallHierarchyItem item) throws Error {
        const string method = "callHierarchy/incomingCalls";
        Project project;
        Compilation compilation;
        var uri = item.uri.to_string ();
        Vala.SourceFile? doc = find_file (uri, out compilation, out project);
        if (doc == null) {
            debug ("[%s] file `%s' not found", method, uri);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var symbol = CodeHelp.lookup_symbol_full_name (
                item.name, compilation.code_context.root.scope);
            if (!(symbol is Vala.Callable || symbol is Vala.Subroutine))
                return null;

            return CallHierarchy.get_incoming_calls (project, symbol);
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    protected override async CallHierarchyOutgoingCall[]? outgoing_calls_async (
        Lsp.Client client,
        CallHierarchyItem item) throws Error {
        const string method = "callHierarchy/outgoingCalls";
        Project project;
        Compilation compilation;
        var uri = item.uri.to_string ();
        Vala.SourceFile? doc = find_file (uri, out compilation, out project);
        if (doc == null) {
            debug ("[%s] file `%s' not found", method, uri);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var subroutine = CodeHelp.lookup_symbol_full_name (
                item.name, compilation.code_context.root.scope) as Vala.Subroutine;
            if (subroutine == null)
                return null;

            return CallHierarchy.get_outgoing_calls (project, subroutine);
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    protected override async InlayHint[]? inlay_hint_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Range range) throws Error {
        const string method = "textDocument/inlayHint";
        Compilation compilation;
        var uri = text_document.uri.to_string ();
        var file = find_file (uri, out compilation);
        if (file == null) {
            debug ("[%s] file `%s' not found", method, uri);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var query = new NodeSearch.within (file, range, false);
            if (query.result.is_empty) {
                debug ("[%s] nothing found", method);
                return null;
            }

            InlayHint[] hints = {};
            foreach (var item in query.result) {
                Vala.LocalVariable? local = null;
                var representation = CodeHelp.get_code_node_source (item);
                MatchInfo foreach_match;
                if (item is Vala.DeclarationStatement)
                    local = ((Vala.DeclarationStatement)item).declaration as Vala.LocalVariable;
                if (local != null && local.source_reference != null && !(local.initializer is Vala.ObjectCreationExpression) &&
                    local in compilation.var_decls) {
                    // show inlay hints for local variables with non-obvious inferred types
                    var hint = new InlayHint (
                        Util.position_from_libvala (local.source_reference.end),
                        ":%s".printf (CodeHelp.get_data_type_representation (
                            local.variable_type, null)),
                        InlayHintKind.TYPE);
                    hint.padding = InlayHintPadding.LEFT;
                    hints += hint;
                } else if (/foreach\s*\(\s*var\s+(\w+)/m.match (representation, 0, out foreach_match)) {
                    // HACK for foreach statements (includes generated decls of foreach element vars)
                    int start, end;
                    if (foreach_match.fetch_pos (1, out start, out end)) {
                        // extract element variable type
                        Vala.DataType? element_type = null;
                        if (item is Vala.ForeachStatement && !(((Vala.ForeachStatement)item).type_reference is Vala.VarType) &&
                            ((Vala.ForeachStatement)item).element_variable != null) {
                            // the element variable type will be the same as [type_reference]
                            // we only have an element variable with foreach statements on arrays
                            element_type = ((Vala.ForeachStatement)item).type_reference;
                        } else if (local != null) {
                            // there is an auto-generated declaration for a foreach statement iterator variable
                            element_type = local.variable_type;
                            // make sure this declaration is actually the element variable
                            bool is_element_var = false;
                            for (Vala.CodeNode? current_node = local; current_node != null; current_node = current_node.parent_node) {
                                if (current_node is Vala.ForeachStatement) {
                                    var stmt = (Vala.ForeachStatement)current_node;
                                    is_element_var = stmt.variable_name == local.name;
                                    break;
                                }
                            }
                            if (!is_element_var)
                                continue;
                        } else {
                            // otherwise, continue
                            continue;
                        }

                        var hint_range = SymbolReferences.get_narrowed_source_reference (
                            item.source_reference, representation, start, end);
                        var hint = new InlayHint (
                            hint_range.end,
                            ":%s".printf (CodeHelp.get_data_type_representation (
                                element_type, null)),
                            InlayHintKind.TYPE);
                        hint.padding = InlayHintPadding.LEFT;
                        hints += hint;
                    }
                } else if (item is Vala.LambdaExpression) {
                    var lambda = (Vala.LambdaExpression)item;
                    foreach (var param in lambda.get_parameters ()) {
                        if (param.variable_type != null) {
                            var hint_range = Util.range_from_sourceref (
                                param.source_reference);
                            var hint = new InlayHint (
                                hint_range.start,
                                CodeHelp.get_data_type_representation (
                                    param.variable_type, null),
                                InlayHintKind.PARAMETER);
                            hint.padding = InlayHintPadding.RIGHT;
                            hints += hint;
                        }
                    }
                } else if ((item is Vala.MethodCall || item is Vala.ObjectCreationExpression) && compilation.method_calls.has_key (item)) {
                    Vala.List<Vala.Parameter>? parameters = null;
                    if (item is Vala.MethodCall) {
                        var mc = (Vala.MethodCall)item;
                        if (mc.call.value_type != null)
                            parameters = mc.call.value_type.get_parameters ();
                    } else {
                        var oce = (Vala.ObjectCreationExpression)item;
                        if (oce.member_name != null && oce.member_name.symbol_reference is Vala.Callable)
                            parameters = ((Vala.Callable)oce.member_name.symbol_reference).get_parameters ();
                        else if (oce.type_reference != null)
                            parameters = oce.type_reference.get_parameters ();
                    }
                    if (parameters != null) {
                        int orig_param_count = compilation.method_calls[item];
                        var iter = parameters.iterator ();
                        var args_i = 0;
                        Vala.Parameter? last_ellipsis = null;
                        Vala.List<Vala.Expression> argument_list;
                        if (item is Vala.MethodCall)
                            argument_list = ((Vala.MethodCall)item).get_argument_list ();
                        else
                            argument_list = ((Vala.ObjectCreationExpression)item).get_argument_list ();
                        foreach (var arg in argument_list) {
                            if (arg.source_reference == null) {
                                // ignore implicit parameters
                                args_i++;
                                continue;
                            }
                            if (args_i >= orig_param_count)
                                break;
                            if (arg is Vala.NamedArgument) {
                                args_i++;
                                continue;
                            }
                            if (!iter.next () && last_ellipsis == null)
                                break;
                            var formal_parameter = last_ellipsis ?? iter.get ();
                            if (formal_parameter.ellipsis)
                                last_ellipsis = formal_parameter;
                            var parameter_name = formal_parameter.name ?? @"arg$args_i";
                            var argument = arg;
                            if (argument is Vala.UnaryExpression &&
                                (((Vala.UnaryExpression)argument).operator == Vala.UnaryOperator.REF || ((Vala.UnaryExpression)argument).operator == Vala.UnaryOperator.OUT))
                                argument = ((Vala.UnaryExpression)argument).inner;
                            if (CodeHelp.get_code_node_source (argument).casefold () == parameter_name.casefold ()) {
                                // no need to show formal parameter when the argument has the same name
                                args_i++;
                                continue;
                            }
                            var hint_range = Util.range_from_sourceref (arg.source_reference);
                            var hint = new InlayHint (
                                hint_range.start,
                                "%s:".printf (parameter_name),
                                InlayHintKind.PARAMETER);
                            hint.padding = InlayHintPadding.RIGHT;
                            hints += hint;
                            args_i++;
                        }
                    }
                }
            }
            return hints;
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    protected override async TypeHierarchyItem[]? prepare_type_hierarchy_async (
        Lsp.Client client,
        TextDocumentIdentifier text_document,
        Position position) throws Error {
        const string method = "textDocument/prepareTypeHierarchy";
        Project project;
        Compilation compilation;
        var uri = text_document.uri.to_string ();
        var doc = find_file (uri, out compilation, out project);
        if (doc == null) {
            debug ("[%s] file `%s' not found", method, uri);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var search = new NodeSearch (doc, position);
            if (search.result.size == 0) {
                debug (@"[$method] no results found");
                return null;
            }

            var result = get_best (search, doc);
            Vala.TypeSymbol? type_symbol = null;
            if (result is Vala.TypeSymbol) {
                type_symbol = (Vala.TypeSymbol) result;
            } else if (result is Vala.DataType &&
                       ((Vala.DataType) result).type_symbol != null) {
                type_symbol = ((Vala.DataType) result).type_symbol;
            } else if (result is Vala.Expression &&
                       ((Vala.Expression) result).symbol_reference is Vala.TypeSymbol) {
                type_symbol = (Vala.TypeSymbol) ((Vala.Expression) result).symbol_reference;
                // A qualified expression can expose more than one type symbol.
                foreach (var component in
                         SymbolReferences.get_visible_components_of_code_node (result)) {
                    if (component.first is Vala.TypeSymbol && component.second != null &&
                        Util.range_contains ((!) component.second, position)) {
                        type_symbol = (Vala.TypeSymbol) component.first;
                        break;
                    }
                }
            }

            if (type_symbol == null)
                return null;
            TypeHierarchyItem[] items = {
                TypeHierarchy.item_from_symbol (type_symbol)
            };
            return items;
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    protected override async TypeHierarchyItem[]? type_hierarchy_supertypes_async (
        Lsp.Client client,
        TypeHierarchyItem item) throws Error {
        return get_type_hierarchy (item, true);
    }

    protected override async TypeHierarchyItem[]? type_hierarchy_subtypes_async (
        Lsp.Client client,
        TypeHierarchyItem item) throws Error {
        return get_type_hierarchy (item, false);
    }

    TypeHierarchyItem[]? get_type_hierarchy (TypeHierarchyItem item, bool supertypes) {
        string method = supertypes ? "typeHierarchy/supertypes" : "typeHierarchy/subtypes";
        Project project;
        Compilation compilation;
        var uri = item.uri.to_string ();
        Vala.SourceFile? doc = find_file (uri, out compilation, out project);
        if (doc == null) {
            debug ("[%s] file `%s' not found", method, uri);
            return null;
        }

        Vala.CodeContext.push (compilation.code_context);
        try {
            var symbol = CodeHelp.lookup_symbol_full_name (
                item.name, compilation.code_context.root.scope) as Vala.TypeSymbol;
            if (symbol == null)
                return null;

            if (supertypes)
                return TypeHierarchy.get_supertypes (project, symbol);
            return TypeHierarchy.get_subtypes (project, symbol);
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    protected override async void shutdown_async (Lsp.Client client) throws Error {
        shutdown ();
    }

    void shutdown () {
        if (shutting_down)
            return;

        debug ("shutting down...");
        this.shutting_down = true;
        foreach (var project in projects.get_keys_as_array ())
            project.disconnect (projects[project]);
    }

    public override void exit () {
        cancellable.cancel ();
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
        return 0;
    }

    // otherwise
    var loop = new MainLoop ();
    new Vls.Server (loop);
    loop.run ();
    return 0;
}
