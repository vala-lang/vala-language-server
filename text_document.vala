class Vls.TextDocument : Object {
    private Context ctx;
    private string filename;

    public Vala.SourceFile file;
    public string uri;
    public int version;

    public TextDocument (Context ctx,
                         string filename,
                         string? content = null,
                         int version = 0) throws ConvertError, FileError {

        if (!FileUtils.test (filename, FileTest.EXISTS)) {
            throw new FileError.NOENT ("file %s does not exist".printf (filename));
        }

        this.uri = Filename.to_uri (filename);
        this.filename = filename;
        this.version = version;
        this.ctx = ctx;

        var type = Vala.SourceFileType.NONE;
        if (uri.has_suffix (".vala") || uri.has_suffix (".gs"))
            type = Vala.SourceFileType.SOURCE;
        else if (uri.has_suffix (".vapi"))
            type = Vala.SourceFileType.PACKAGE;

        string text;

        if (content == null) {
            print (@"reading $filename\n");
            FileUtils.get_contents (filename, out text);
        } else {
            text = content;
        }

        file = new Vala.SourceFile (ctx.code_context, type, filename, text);
        if (type == Vala.SourceFileType.SOURCE) {
            var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, "GLib", null));
            file.add_using_directive (ns_ref);
            ctx.add_using ("GLib");
        }
    }
}
