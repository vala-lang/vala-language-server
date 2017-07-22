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

  // a{sv}
  void parseDict (Variant dict, ...) {
    var l = va_list ();
    var iter = dict.iterator ();
    while (true) {
      string type = l.arg ();
      void *ptr = l.arg ();
      Variant? val = null;

      var next = iter.next ("{sv}", null, out val);
      if (!next)
        break;
      val.get (type, ptr);
    }
  }

  void initialize (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
    var iter = @params.iterator ();

    // Variant? pid = null;
    // iter.next ("{sv}", null, out pid);

    // Variant? root_path = null;
    // iter.next ("{sv}", null, out root_path);

    int64? pid = null;
    string root_path = null;
    parseDict (@params,
      "x", out pid,
      "s", out root_path,
      null);

    // print ("pid = %s, root_path = %s\n", pid.get_int64 ().to_string (), root_path.get_string ());
    print ("pid = %s, root_path = %s\n", pid.to_string (), root_path);

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
