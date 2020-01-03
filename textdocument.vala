class Vls.TextDocument : Object {
    public weak Compilation compilation { get; private set; }
    private string filename;

    public Vala.SourceFile file { get; private set; }
    public string uri { get; private set; }
    public int version;

    public string? content {
        get {
            return (string) file.get_mapped_contents ();
        }
        set {
            file.content = value;
        }
    }

    public TextDocument (Compilation compilation,
                         string filename,
                         string? content = null,
                         int version = 0) throws ConvertError, FileError {

        if (!FileUtils.test (filename, FileTest.EXISTS)) {
            throw new FileError.NOENT ("file %s does not exist".printf (filename));
        }

        this.compilation = compilation;
        this.filename = filename;
        this.uri = Filename.to_uri (filename);
        this.version = version;

        var type = Vala.SourceFileType.NONE;
        if (uri.has_suffix (".vala") || uri.has_suffix (".gs"))
            type = Vala.SourceFileType.SOURCE;
        else if (uri.has_suffix (".vapi") || uri.has_suffix (".gir"))
            type = Vala.SourceFileType.PACKAGE;

        this.file = new Vala.SourceFile (compilation.code_context, type, filename, content);
    }
}
