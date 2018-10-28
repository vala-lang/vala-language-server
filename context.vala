using Gee;

/**
 * The point of this class is to refresh the Vala.CodeContext every time
 * we change something.
 */
class Vls.Context {
    private HashSet<string> _defines;
    private HashSet<string> _packages;
    private HashSet<string> _usings;
    private HashMap<string, TextDocument> _sources;
    private HashSet<string> _csources;
    private HashSet<string> _vapidirs;

    public bool dirty { get; private set; default = true; }

    private Vala.CodeContext? _ctx;

    public Vala.CodeContext code_context {
        get {
            if (dirty) {
                message ("dirty context, rebuilding");

                if (_ctx != null) {
                    // stupid workaround for memory leaks in Vala 0.38
                    workaround_038 (_ctx, get_source_files ());
                }
                // generate a new code context 
                _ctx = new Vala.CodeContext ();
                Vala.CodeContext.push (_ctx);
                dirty = false;

                string version = Config.libvala_version;
                string[] parts = version.split(".");
                assert (parts.length == 3);
                assert (parts[0] == "0");
                var minor = int.parse (parts[1]);

                _ctx.report = new Reporter ();
                _ctx.profile = Vala.Profile.GOBJECT;
                _ctx.add_define ("GOBJECT");
                for (int i = 2; i <= minor; i += 2) {
                    _ctx.add_define ("VALA_0_%d".printf (i));
                }
                _ctx.target_glib_major = 2;
                _ctx.target_glib_minor = 56;
                for (int i = 16; i <= _ctx.target_glib_minor; i += 2) {
                    _ctx.add_define ("GLIB_2_%d".printf (i));
                }
                foreach (var define in _defines)
                    _ctx.add_define (define);
                _ctx.add_external_package ("glib-2.0");
                _ctx.add_external_package ("gobject-2.0");

                _ctx.vapi_directories = _vapidirs.to_array ();

                foreach (var package in _packages)
                    _ctx.add_external_package (package);

                foreach (TextDocument doc in _sources.values) {
                    doc.file.context = _ctx;
                    _ctx.add_source_file (doc.file);
                    // clear all using directives (to avoid "T ambiguous with T" errors)
                    doc.file.current_using_directives = new Vala.ArrayList<Vala.UsingDirective> ();
                    // The parser will only add using directives found in each source file.
                    // Therefore, we have to add these directives manually:
                    foreach (string using_directive in _usings) {
                        var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, using_directive, null));
                        doc.file.add_using_directive (ns_ref);
                        _ctx.root.add_using_directive (ns_ref);
                    }

                    // clear all comments from file
                    doc.file.get_comments ().clear ();
                    assert (doc.file.get_comments ().size == 0);

                    // clear all code nodes from file
                    doc.file.get_nodes ().clear ();
                    assert (doc.file.get_nodes ().size == 0);
                }

                Vala.CodeContext.pop ();
            }
            return _ctx;
        }
    }

    public Context() {
        _defines = new HashSet<string> ();
        _packages = new HashSet<string> ();
        _usings = new HashSet<string> (); 
        _sources = new HashMap<string, TextDocument> ();
        _csources = new HashSet<string> ();
        _vapidirs = new HashSet<string> ();
    }

    public void add_define (string define) {
        if (_defines.add (define))
            dirty = true;
    }

    public void add_package (string pkgname) {
        if (_packages.add (pkgname))
            dirty = true;
    }

    public void remove_package (string pkgname) {
        if (_packages.remove (pkgname))
            dirty = true;
    }

    public void add_using (string using_directive) {
        if (_usings.add (using_directive))
            dirty = true;
    }

    /**
     * Returns whether the document was added.
     */
    public bool add_source_file (TextDocument document) {
        if (_sources.has_key (document.uri))
            return false;
        _sources[document.uri] = document;
        dirty = true;
        return true;
    }

    public TextDocument? get_source_file (string uri) {
        if (!_sources.has_key (uri))
            return null;
        return _sources[uri];
    }

    public Collection<TextDocument> get_source_files () {
        return _sources.values;
    }

    public void remove_source_file (string uri) {
        if (_sources.unset (uri))
            dirty = true;
    }

    public bool add_c_source_file (string uri) {
        return _csources.add (uri);
    }

    public bool remove_c_source_file (string uri) {
        return _csources.remove (uri);
    }

    public void clear_c_sources () {
        _csources.clear ();
    }

    public Collection<string> get_filenames () {
        var col = new HashSet<string> ();
        try {
            foreach (string uri in _sources.keys)
                col.add (Filename.from_uri (uri));
            foreach (string uri in _csources)
                col.add (Filename.from_uri (uri));
        } catch { /* ignore */ }
        return col;
    }

    public void add_vapidir (string dir) {
        if (_vapidirs.add (dir))
            dirty = true;
    }

    public void clear_defines () {
        _defines.clear ();
        dirty = true;
    }

    public void clear_packages () {
        _packages.clear ();
        dirty = true;
    }

    public void clear_sources () {
        _csources.clear ();
        _sources.clear ();
        dirty = true;
    }

    /**
     * Clear everything.
     */
    public void clear () {
        clear_defines ();
        clear_packages ();
        clear_sources ();
    }

    /**
     * call this before each semantic update
     */
    public void invalidate() {
        dirty = true;
    }

    public delegate void RunFunc ();

    public void run (RunFunc f) {
        Vala.CodeContext.push (this.code_context);
        f ();
        Vala.CodeContext.pop ();
    }

    public Reporter report {
        get {
            return (Reporter) this.code_context.report;
        }
    }

    public void check () {
        this.run (() => {
            if (report.get_errors () > 0) {
                return;
            }

            var parser = new Vala.Parser ();
            parser.parse (code_context);

            var genie_parser = new Vala.Genie.Parser ();
            genie_parser.parse (code_context);

            if (report.get_errors () > 0) {
                return;
            }

            code_context.check ();
        });
    }
}
