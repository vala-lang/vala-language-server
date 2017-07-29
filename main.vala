using LanguageServer;

class ValaLanugageServer {
  Jsonrpc.Server server;

  public ValaLanugageServer (MainLoop loop) {
    server = new Jsonrpc.Server ();
    var stdin = new UnixInputStream (Posix.STDIN_FILENO, false);
    var stdout = new UnixOutputStream (Posix.STDOUT_FILENO, false);
    server.accept_io_stream (new SimpleIOStream (stdin, stdout));

    server.add_handler ("initialize", this.initialize);
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
    dict.lookup ("processId", "x", pid);

    string root_path = null;
    dict.lookup ("rootPath", "s", out root_path);

    print ("pid = %" + int64.FORMAT + ", root_path = %s\n", pid, root_path);

    client.reply (id, buildDict (
      textDocumentSync: new Variant.int16 (TextDocumentSyncKind.Full)
    ));
  }
}

void main () {
  var loop = new MainLoop ();
  new ValaLanugageServer (loop);
  loop.run ();
}
