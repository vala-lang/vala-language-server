using LanguageServer;

class Vls.Server {
    Jsonrpc.Server server;
    MainLoop loop;

    Vala.CodeContext ctx;

    public Server (MainLoop loop) {
        this.loop = loop;

        // libvala setup
        this.ctx = new Vala.CodeContext ();
        Vala.CodeContext.push (ctx);

        string version = "0.38.3"; //Config.libvala_version;
        string[] parts = version.split(".");
        assert (parts.length == 3);
        assert (parts[0] == "0");
        var minor = int.parse (parts[1]);

        ctx.profile = Vala.Profile.GOBJECT;
        for (int i = 2; i <= minor; i += 2) {
            ctx.add_define ("VALA_0_%d".printf (i));
        }
        ctx.target_glib_major = 2;
        ctx.target_glib_minor = 38;
        for (int i = 16; i <= ctx.target_glib_minor; i += 2) {
            ctx.add_define ("GLIB_2_%d".printf (i));
        }
        ctx.report = new Reporter ();
        ctx.add_external_package ("glib-2.0");
        ctx.add_external_package ("gobject-2.0");

        Vala.CodeContext.pop ();

        this.server = new Jsonrpc.Server ();
        var stdin = new UnixInputStream (Posix.STDIN_FILENO, false);
        var stdout = new UnixOutputStream (Posix.STDOUT_FILENO, false);
        server.accept_io_stream (new SimpleIOStream (stdin, stdout));

        server.notification.connect ((client, method, @params) => {
            stderr.printf (@"Got notification! $method\n");
            if (method == "textDocument/didOpen")
                this.textDocumentDidOpen(client, @params);
        });

        server.add_handler ("initialize", this.initialize);
        server.add_handler ("exit", this.exit);
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
        var source = new Vala.SourceFile (ctx, type, filename, fileContents);

        ctx.add_source_file (source);

        if (ctx.report.get_errors () > 0) {
            stderr.printf ("got errors !!!! :/\n");
        }
    }

    void exit (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        loop.quit ();
    }
}

void main () {
    var loop = new MainLoop ();
    new Vls.Server (loop);
    loop.run ();
}
