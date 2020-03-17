using Vala;

class Vls.TextDocument : SourceFile {
    /**
     * This must be manually updated by anything that changes the content
     * of this document.
     */
    public DateTime last_updated { get; set; default = new DateTime.now (); }
    public int version { get; set; }

    public TextDocument (CodeContext context, File file, bool cmdline = false) throws FileError {
        string cont;
        string path = Util.realpath ((!) file.get_path ());
        FileUtils.get_contents (path, out cont);
        SourceFileType ftype;
        if (path.has_suffix (".vapi") || path.has_suffix (".gir"))
            ftype = SourceFileType.PACKAGE;
        else if (path.has_suffix (".vala") || path.has_suffix (".gs"))
            ftype = SourceFileType.SOURCE;
        else {
            ftype = SourceFileType.NONE;
            warning ("TextDocument: file %s is neither a package nor a source file", path);
        }
        base (context, ftype, path, cont, cmdline);
    }
}
