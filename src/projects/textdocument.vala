using Vala;

class Vls.TextDocument : SourceFile {
    /**
     * This must be manually updated by anything that changes the content
     * of this document.
     */
    public DateTime last_updated { get; set; default = new DateTime.now (); }
    public int version { get; set; }

    public TextDocument (CodeContext context, File file, string? content = null, bool cmdline = false) throws FileError {
        string? cont = content;
        string uri = file.get_uri ();
        string? path = file.get_path ();
        path = path != null ? Util.realpath (path) : null;
        if (path != null && cont == null)
            FileUtils.get_contents (path, out cont);
        SourceFileType ftype;
        if (uri.has_suffix (".vapi") || uri.has_suffix (".gir"))
            ftype = SourceFileType.PACKAGE;
        else if (uri.has_suffix (".vala") || uri.has_suffix (".gs"))
            ftype = SourceFileType.SOURCE;
        else {
            ftype = SourceFileType.NONE;
            warning ("TextDocument: file %s is neither a package nor a source file", uri);
        }
        base (context, ftype, uri, cont, cmdline);
    }
}
