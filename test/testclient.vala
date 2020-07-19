using Gee;

class Vls.TestClient : Jsonrpc.Server {
    private static HashSet<weak TestClient> instances = new HashSet<weak TestClient> ();
    private Jsonrpc.Client? vls_jsonrpc_client;
    private Subprocess vls_subprocess;
    private SubprocessLauncher launcher;
    private IOStream subprocess_stream;

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
            launcher.setenv (env[0:p], env.substring (p + 1), true);
        }

        vls_subprocess = launcher.spawnv ({server_location, server_location});

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

    public override void client_accepted (Jsonrpc.Client client) {
        if (vls_jsonrpc_client == null) {
            vls_jsonrpc_client = client;
            try {
                initialize_server ();
            } catch (Error e) {
                try {
                    printerr ("failed to initialize server: %s", e.message);
                    client.close ();
                } catch (Error e) {}
            }
        }
    }

#if WITH_JSONRPC_GLIB_3_30
    public override void client_closed (Jsonrpc.Client client) {
        if (client == vls_jsonrpc_client) {
            vls_jsonrpc_client = null;
        }
    }
#endif

    private void initialize_server () throws Error {
        Variant? return_value;
        vls_jsonrpc_client.call (
            "initialize",
            buildDict (
                processId: new Variant.int32 ((int32) Posix.getpid ()),
                rootPath: new Variant.string (root_path),
                rootUri: new Variant.string (File.new_for_path (root_path).get_uri ())
            ),
            null,
            out return_value
        );
        debug ("VLS replied with %s", Json.to_string (Json.gvariant_serialize (return_value), true));
    }

    public void wait_for_server () throws Error {
        vls_subprocess.wait ();
    }

    public override void notification (Jsonrpc.Client client, string method, Variant @params) {
        debug ("VLS sent notification `%s': %s", method, Json.to_string (Json.gvariant_serialize (@params), true));
    }

    public void shutdown () {
        try {
            subprocess_stream.close ();
            debug ("closed subprocess stream");
        } catch (Error e) {}
    }
}

string? server_location;
[CCode (array_length = false, array_null_terminated = true)]
string[]? env_vars;
string? root_path;
bool unset_env;
const OptionEntry[] options = {
    { "server", 's', 0, OptionArg.FILENAME, ref server_location, "Location of server binary", "FILE" },
    { "root-path", 'r', 0, OptionArg.FILENAME, ref root_path, "Root path to initialize VLS in", "DIRECTORY" },
    { "environ", 'e', 0, OptionArg.STRING_ARRAY, ref env_vars, "List of environment variables", null },
    { "unset-environment", 'u', 0, OptionArg.NONE, ref unset_env, "Don't inherit parent environment", null },
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
