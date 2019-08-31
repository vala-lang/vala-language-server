void main (string[] args) {
    Gtk.init (ref args);
    Gtk.Sourceinit ();

    var context = new Vls.Context ();

    if (args.length < 2) {
        print ("Usage: %s [--pkg gtk+-3.0] [file.vala]\n", args[0]);
        return;
    }

    for (int i = 1; i < args.length; ++i) {
        if (args[i] == "--pkg") {
            context.add_package (args[i+1]);
            ++i;
        } else {
            var doc = new Vls.TextDocument (context, Environment.get_current_dir () + "/" + args[i]);
            context.add_source_file (doc);
        }
    }

    context.check ();

    foreach (var sf in context.code_context.get_source_files ()) {
        if (sf.file_type == Vala.SourceFileType.SOURCE) 
            new Vls.CodeNodeUI (sf, null);
    }
    Gtk.main ();
}