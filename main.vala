using LanguageServer;

class ValaLanguageServer {
  Jsonrpc.Server server;
  MainLoop loop;

  public ValaLanguageServer (MainLoop loop) {
    this.loop = loop;
    server = new Jsonrpc.Server ();
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

    //log (@"pid = $pid, root_path = $root_path\n");

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
  }

  void exit (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
    loop.quit ();
  }
}

void main () {
  var loop = new MainLoop ();
  new ValaLanguageServer (loop);
  loop.run ();
}
