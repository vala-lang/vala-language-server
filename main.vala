void main () {
  var server = new Jsonrpc.Server ();
  var stdin = new UnixInputStream (Posix.STDIN_FILENO, false);
  var stdout = new UnixOutputStream (Posix.STDOUT_FILENO, false);
  var loop = new MainLoop ();

  server.add_handler ("test", (server, client, method, id, @params) => {
    client.reply (id, "ok");
  });

  server.handle_call.connect((client, method, id, @params) => {
    print ("handle_call\n");
    return false;
  });

  server.notification.connect ((client, method, @params) => {
    print ("notification\n");
  });

  server.accept_io_stream (new SimpleIOStream (stdin, stdout));

  loop.run ();
}
