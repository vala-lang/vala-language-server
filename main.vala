class ValaLanugageServer {
  Jsonrpc.Server server;

  public ValaLanugageServer (MainLoop loop) {
    server = new Jsonrpc.Server ();
    var stdin = new UnixInputStream (Posix.STDIN_FILENO, false);
    var stdout = new UnixOutputStream (Posix.STDOUT_FILENO, false);
    server.accept_io_stream (new SimpleIOStream (stdin, stdout));

    server.add_handler ("initialize", this.initialize);
  }

  void initialize (Jsonrpc.Server self, Jsonrpc.Client client, string method, Variant id, Variant @params) {
    int64 pid = @params.get_child_value (0).get_child_value (0).get_int64 ();
    string root_path = @params.get_child_value (1).get_child_value (0).get_string ();

    print (@"pid = $pid, root_path = $root_path\n");
  }
}

void main () {
  var loop = new MainLoop ();
  var langserv = new ValaLanugageServer (loop);
  loop.run ();
}
