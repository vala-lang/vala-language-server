/* testclient.vala
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

using Gee;
using Lsp;

class Vls.TestClient : Lsp.Editor {
    private static HashSet<weak TestClient> instances = new HashSet<weak TestClient> ();
    private Subprocess vls_subprocess;
    private SubprocessLauncher launcher;
    private IOStream subprocess_stream;
    private MainLoop loop = new MainLoop ();
    private bool shutdown_started;

    public string root_path { get; private set; }

    static construct {
        Posix.@signal (Posix.Signal.INT, () => {
            foreach (var client in instances)
                client.shutdown ();
        });
    }

    ~TestClient () {
        TestClient.instances.remove (this);
    }

    public TestClient (string server_location, string root_path, string[] env_vars, bool unset_env) throws Error {
        TestClient.instances.add (this);

        Log.set_handler (null, LogLevelFlags.LEVEL_MASK, log_handler);
        Log.set_handler ("jsonrpc-server", LogLevelFlags.LEVEL_MASK, log_handler);

        this.root_path = root_path;
        this.launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);

        if (unset_env)
            launcher.set_environ (new string[]{});
        foreach (string env in env_vars) {
            int p = env.index_of_char ('=');
            if (p == -1)
                throw new IOError.INVALID_ARGUMENT ("`%s' not of the form VAR=STRING", env);
            launcher.setenv (env[0:p], env.substring (p+1), true);
        }

        vls_subprocess = launcher.spawnv ({server_location});

        if (pause_for_debugger) {
            print ("Attach debugger to PID %s and press enter.\n", vls_subprocess.get_identifier ());
            stdin.read_line ();
        }

        var input_stream = vls_subprocess.get_stdout_pipe ();
        var output_stream = vls_subprocess.get_stdin_pipe ();

#if !WINDOWS
        if (input_stream is UnixInputStream && output_stream is UnixOutputStream) {
            // set nonblocking
            if (!Unix.set_fd_nonblocking (((UnixInputStream)input_stream).fd, true)
             || !Unix.set_fd_nonblocking (((UnixOutputStream)output_stream).fd, true))
                error ("could not set pipes to nonblocking.\n");
        }
#endif

        this.subprocess_stream = new SimpleIOStream (input_stream, output_stream);
        accept_io_stream (subprocess_stream);
    }

    private void log_handler (string? log_domain, LogLevelFlags log_levels, string message) {
        stderr.printf ("%s: %s\n", log_domain == null ? "vls-testclient" : log_domain, message);
    }

    private async void initialize_server () throws Error {
        var uri = Uri.parse (
            File.new_for_path (root_path).get_uri (), UriFlags.NONE);
        var workspace = new WorkspaceFolder (uri, Path.get_basename (root_path));
        var parameters = new InitializeParams.with_workspace_folders (workspace);
        parameters.process_id = Posix.getpid ();
        parameters.client_info = new ClientInfo ("VLS Test Client");
        parameters.capabilities.text_document = new TextDocumentClientCaps ();
        parameters.capabilities.text_document.document_symbol = DocumentSymbolClientCaps (
            DocumentSymbolClientFlags.HIERARCHICAL_DOCUMENT_SYMBOLS);
        if (check_completions) {
            var completion = new CompletionClientCaps ();
            if (snippet_support)
                completion.flags = CompletionClientFlags.SNIPPETS;
            parameters.capabilities.text_document.completion = completion;
        }

        yield initialize_with_params_async (parameters);
        yield initialized_async ();

        debug ("VLS initialized with %s", init_result.to_variant ().print (true));
    }

    public void wait_for_server () throws Error {
        Error? run_error = null;
        run.begin ((obj, result) => {
            try {
                run.end (result);
            } catch (Error e) {
                run_error = e;
                vls_subprocess.force_exit ();
            }
            loop.quit ();
        });
        loop.run ();

        if (run_error != null)
            throw (!) run_error;
    }

    private async void run () throws Error {
        yield initialize_server ();
        if (document_symbol_file != null) {
            yield check_document_symbols ((!) document_symbol_file);
            yield stop_server ();
        } else if (check_completions) {
            yield check_string_completions ();
            yield stop_server ();
        }
        yield vls_subprocess.wait_async ();
    }

    private static int position_compare (Position left, Position right) {
        if (left.line != right.line)
            return left.line > right.line ? 1 : -1;
        if (left.character != right.character)
            return left.character > right.character ? 1 : -1;
        return 0;
    }

    private static bool range_contains (Range outer, Range inner) {
        return position_compare (outer.start, inner.start) <= 0 &&
            position_compare (inner.end, outer.end) <= 0;
    }

    private static DocumentSymbol? find_symbol (DocumentSymbol[] symbols,
                                                string name) {
        foreach (var symbol in symbols) {
            if (symbol.name == name)
                return symbol;
            var result = find_symbol (symbol.children, name);
            if (result != null)
                return result;
        }
        return null;
    }

    private static void assert_symbol_ranges (DocumentSymbol symbol) {
        foreach (var child in symbol.children) {
            assert (range_contains (symbol.range, child.range));
            assert_symbol_ranges (child);
        }
    }

    private async void check_document_symbols (string filename) throws Error {
        var uri = Uri.parse (File.new_for_path (filename).get_uri (), UriFlags.NONE);
        var result = yield document_symbol_async (uri);
        assert (result != null);
        assert (result.document_symbols != null);

        var symbols = result.document_symbols;
        var server_symbol = find_symbol (symbols, "Server");
        var construct_symbol = find_symbol (symbols, "Server (static construct block)");
        assert (server_symbol != null);
        assert (construct_symbol != null);
        assert (range_contains (server_symbol.range, construct_symbol.range));
        foreach (var symbol in symbols)
            assert_symbol_ranges (symbol);
    }

    private async void check_snippet_completion (string basename,
                                                 string contents,
                                                 Position position,
                                                 string label,
                                                 CompletionItemKind kind) throws Error {
        var filename = Path.build_filename (root_path, "test", basename);
        var uri = Uri.parse (
            File.new_for_path (filename).get_uri (), UriFlags.NONE);
        yield open_text_document_async (uri, LanguageId.VALA, contents);

        var items = yield completion_async (uri, position);
        assert (items != null);
        CompletionItem? completion = null;
        foreach (var item in items) {
            if (item.label == label && item.kind == kind)
                completion = item;
            if (!snippet_support) {
                assert (item.insert_text_format != InsertTextFormat.SNIPPET);
                assert (item.insert_text == null || !item.insert_text.contains ("$"));
            }
        }
        assert (completion != null);
        if (snippet_support) {
            assert (completion.insert_text != null);
            assert (completion.insert_text_format == InsertTextFormat.SNIPPET);
            assert (completion.insert_text.contains ("$"));
        } else {
            assert (completion.insert_text == null);
            assert (completion.insert_text_format == InsertTextFormat.UNSET);
        }
    }

    private async void check_string_completions () throws Error {
        const string contents = "void main () {\n" +
            "    \n" +
            "    string path = \"\";\n" +
            "    path.spli\n" +
            "}\n";
        var filename = Path.build_filename (
            root_path, "test", "completion-client.vala");
        var uri = Uri.parse (
            File.new_for_path (filename).get_uri (), UriFlags.NONE);
        yield open_text_document_async (uri, LanguageId.VALA, contents);

        var keyword_items = yield completion_async (uri, Position (1, 4));
        assert (keyword_items != null);
        CompletionItem? if_keyword = null;
        foreach (var item in keyword_items) {
            if (item.label == "if")
                if_keyword = item;
            if (!snippet_support) {
                assert (item.insert_text_format != InsertTextFormat.SNIPPET);
                assert (item.insert_text == null || !item.insert_text.contains ("$"));
            }
        }
        assert (if_keyword != null);

        var items = yield completion_async (uri, Position (3, 13));
        assert (items != null);
        CompletionItem? split = null;
        foreach (var item in items) {
            if (item.label == "split") {
                split = item;
            }
            if (!snippet_support) {
                assert (item.insert_text_format != InsertTextFormat.SNIPPET);
                assert (item.insert_text == null || !item.insert_text.contains ("$"));
            }
        }
        assert (split != null);
        if (snippet_support) {
            assert (if_keyword.insert_text != null);
            assert (if_keyword.insert_text_format == InsertTextFormat.SNIPPET);
            assert (if_keyword.insert_text.contains ("$"));
            assert (split.insert_text != null);
            assert (split.insert_text_format == InsertTextFormat.SNIPPET);
            assert (split.insert_text.contains ("$"));
        } else {
            assert (if_keyword.insert_text == null);
            assert (if_keyword.insert_text_format == InsertTextFormat.UNSET);
            assert (split.insert_text == null);
            assert (split.insert_text_format == InsertTextFormat.UNSET);
        }

        const string implementation_contents = "abstract class Base {\n" +
            "    public abstract void foo ();\n" +
            "}\n" +
            "class Derived : Base {\n" +
            "    \n" +
            "}\n";
        filename = Path.build_filename (
            root_path, "test", "completion-implementation-client.vala");
        uri = Uri.parse (
            File.new_for_path (filename).get_uri (), UriFlags.NONE);
        yield open_text_document_async (uri, LanguageId.VALA, implementation_contents);

        var implementation_items = yield completion_async (uri, Position (4, 4));
        assert (implementation_items != null);
        CompletionItem? implementation = null;
        foreach (var item in implementation_items) {
            if (item.label.has_prefix ("public override void foo"))
                implementation = item;
        }
        if (snippet_support) {
            assert (implementation != null);
            assert (implementation.insert_text_format == InsertTextFormat.SNIPPET);
        } else {
            assert (implementation == null);
        }

        const string signal_contents = "class Fixture : Object {\n" +
            "    public signal void changed (int value);\n" +
            "    void test () {\n" +
            "        changed.con\n" +
            "    }\n" +
            "}\n";
        yield check_snippet_completion (
            "completion-signal-client.vala", signal_contents, Position (3, 19),
            "connect", CompletionItemKind.METHOD);

        const string array_contents = "void main () {\n" +
            "    int[] values = {};\n" +
            "    values.co\n" +
            "}\n";
        yield check_snippet_completion (
            "completion-array-client.vala", array_contents, Position (2, 13),
            "copy", CompletionItemKind.METHOD);

        const string async_contents = "#!/usr/bin/env -S vala --pkg gio-2.0\n" +
            "\n" +
            "void main () {\n" +
            "    File file = File.new_for_path (\"\");\n" +
            "    file.read_async.begin ();\n" +
            "}\n";
        yield check_snippet_completion (
            "completion-async-client.vala", async_contents, Position (4, 20),
            "begin", CompletionItemKind.METHOD);

        const string generic_contents = "class Box<T> {\n" +
            "}\n" +
            "void main () {\n" +
            "    Bo\n" +
            "}\n";
        yield check_snippet_completion (
            "completion-generic-client.vala", generic_contents, Position (3, 6),
            "Box", CompletionItemKind.CLASS);

        const string constructor_contents = "class Widget {\n" +
            "    public Widget (int value) {\n" +
            "    }\n" +
            "}\n" +
            "void main () {\n" +
            "    var widget = new Wid\n" +
            "}\n";
        yield check_snippet_completion (
            "completion-constructor-client.vala", constructor_contents, Position (5, 24),
            "Widget", CompletionItemKind.CONSTRUCTOR);
    }

    public void shutdown () {
        if (shutdown_started)
            return;
        shutdown_started = true;

        stop_server.begin ((obj, result) => {
            try {
                stop_server.end (result);
            } catch (Error e) {
                warning ("failed to shut down VLS: %s", e.message);
                vls_subprocess.force_exit ();
            }
        });
    }

    private async void stop_server () throws Error {
        if (init_result != null && !is_shutting_down)
            yield shutdown_async ();
        if (!exited)
            yield exit_async ();
    }
}

string? server_location;
[CCode (array_length = false, array_null_terminated = true)]
string[]? env_vars;
string? root_path;
string? document_symbol_file;
bool check_completions;
bool snippet_support;
bool unset_env;
bool pause_for_debugger = false;
const OptionEntry[] options = {
    { "server", 's', 0, OptionArg.FILENAME, ref server_location, "Location of server binary", "FILE" },
    { "root-path", 'r', 0, OptionArg.FILENAME, ref root_path, "Root path to initialize VLS in", "DIRECTORY" },
    { "environ", 'e', 0, OptionArg.STRING_ARRAY, ref env_vars, "List of environment variables", null },
    { "unset-environment", 'u', 0, OptionArg.NONE, ref unset_env, "Don't inherit parent environment", null },
    { "pause", 'p', 0, OptionArg.NONE, ref pause_for_debugger, "Pause before calling VLS to get a chance to attach a debugger", null },
    { "document-symbols", 0, 0, OptionArg.FILENAME, ref document_symbol_file, "Check document symbols for FILE", "FILE" },
    { "completions", 0, 0, OptionArg.NONE, ref check_completions, "Check string completions", null },
    { "snippet-support", 0, 0, OptionArg.NONE, ref snippet_support, "Advertise completion snippet support", null },
    { null }
};

int main (string[] args) {
    try {
        var opt_context = new OptionContext ("- VLS Test Client");
        opt_context.set_help_enabled (true);
        opt_context.add_main_entries (options, null);
        opt_context.parse (ref args);
    } catch (OptionError e) {
        printerr ("error: %s\n", e.message);
        printerr ("Run '%s --help'\n", args[0]);
        return 1;
    }

    if (server_location == null) {
        printerr ("server location required\n");
        return 1;
    }

    if (root_path == null) {
        printerr ("root path required\n");
        return 1;
    }

    try {
        var client = new Vls.TestClient (server_location, root_path, env_vars, unset_env);
        client.wait_for_server ();
    } catch (Error e) {
        printerr ("error running test client: %s\n", e.message);
        return 1;
    }

    return 0;
}
