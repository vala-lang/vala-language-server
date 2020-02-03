using Gee;

/**
 * Wraps a Vala.CodeContext and refreshes it as necessary.
 */
class Vls.Compilation : Object {
    private weak BuildTarget? _parent_target;
    public weak BuildTarget parent_target {
        get {
            return (!) _parent_target;
        }
    }

    private HashSet<string> _packages = new HashSet<string> ();
    // maps URI -> TextDocument
    private HashMap<string, TextDocument> _sources = new HashMap<string, TextDocument> ();
    private HashMap<string, TextDocument> _autosources = new HashMap<string, TextDocument> ();
    private HashSet<string> _vapi_dirs = new HashSet<string> ();
    private HashSet<string> _gir_dirs = new HashSet<string> ();
    private HashSet<string> _metadata_dirs = new HashSet<string> ();
    private HashSet<string> _gresources_dirs = new HashSet<string> ();
    private HashSet<string> _defines = new HashSet<string> ();

    // compiler flags

    public bool experimental { get; private set; }
    public bool experimental_non_null { get; private set; }
    public Vala.Profile profile { get; private set; }
    public bool abi_stability { get; private set; }

    // code context
    /**
     * Whether the code context needs to be (re-)compiled.
     */
    public bool needs_compile { get; private set; default = true; }

    /**
     * Whether the code context has been updated. This could happen
     * because we added a new source file, or we changed a source file,
     * for example.
     */
    public bool dirty { get; private set; default = true; }

    private Vala.CodeContext? _ctx;

    public Vala.CodeContext code_context {
        get {
            if (dirty) {
                debug ("dirty context, rebuilding");

                if (_ctx != null) {
                    // stupid workaround for memory leaks in Vala 0.38
                    workaround_038 (_ctx, _sources.values);
                    workaround_038 (_ctx, _autosources.values);
                }
                // generate a new code context
                _ctx = new Vala.CodeContext () { keep_going = true };
                _autosources.clear ();
                Vala.CodeContext.push (_ctx);
                dirty = false;

                // string version = Config.libvala_version;
                _ctx.report = new Reporter ();

                // compiler flags and defines
                _ctx.profile = profile;
                switch (profile) {
                    case Vala.Profile.POSIX:
                        _ctx.add_define ("POSIX");
                        break;
                    case Vala.Profile.GOBJECT:
                        _ctx.add_define ("GOBJECT");
                        break;
                    default:
                        error ("unsupported Vala profile %s", profile.to_string ());
                }

                _ctx.experimental = experimental;
                _ctx.experimental_non_null = experimental_non_null;
                _ctx.abi_stability = abi_stability;

                _ctx.vapi_directories = _vapi_dirs.to_array ();
                _ctx.gir_directories = _gir_dirs.to_array ();
                _ctx.metadata_directories = _metadata_dirs.to_array ();
                _ctx.gresources_directories = _gresources_dirs.to_array ();

                foreach (TextDocument doc in _sources.values) {
                    doc.file.context = _ctx;
                    _ctx.add_source_file (doc.file);
                    // clear all using directives (to avoid "T ambiguous with T" errors)
                    doc.file.current_using_directives = new Vala.ArrayList<Vala.UsingDirective> ();
                    // add default using directives for the profile
                    if (profile == Vala.Profile.POSIX) {
                        // import the Posix namespace by default (namespace of backend-specific standard library)
                        var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, "Posix", null));
                        doc.file.add_using_directive (ns_ref);
                        _ctx.root.add_using_directive (ns_ref);
                    } else if (profile == Vala.Profile.GOBJECT) {
                        // import the GLib namespace by default (namespace of backend-specific standard library)
                        var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, "GLib", null));
                        doc.file.add_using_directive (ns_ref);
                        _ctx.root.add_using_directive (ns_ref);
                    }

                    // clear all comments from file
                    doc.file.get_comments ().clear ();

                    // clear all code nodes from file
                    doc.file.get_nodes ().clear ();
                }

                // packages (should come after in case we've wrapped any package files in TextDocuments)
                foreach (var package in _packages)
                    _ctx.add_external_package (package);

                Vala.CodeContext.pop ();
                needs_compile = true;
            }

            return (!) _ctx;
        }
    }

    /**
     * The reporter for the code context.
     */
    public Reporter reporter {
        get { return (Reporter) code_context.report; }
    }

    construct {
        _packages.add ("glib-2.0");
        _packages.add ("gobject-2.0");
    }

    public Compilation (BuildTarget parent, 
                        bool experimental,
                        bool experimental_non_null,
                        Vala.Profile profile,
                        bool abi_stability,
                        Collection<string>? packages = null,
                        Collection<string>? vapi_dirs = null,
                        Collection<string>? gir_dirs = null,
                        Collection<string>? metadata_dirs = null,
                        Collection<string>? gresources_dirs = null,
                        Collection<string>? defines = null) {
        this._parent_target = parent;

        if (packages != null)
            _packages.add_all (packages);
        if (vapi_dirs != null)
            _vapi_dirs.add_all (vapi_dirs);
        if (gir_dirs != null)
            _gir_dirs.add_all (gir_dirs);
        if (metadata_dirs != null)
            _metadata_dirs.add_all (metadata_dirs);
        if (gresources_dirs != null)
            _gresources_dirs.add_all (gresources_dirs);
        if (defines != null)
            _defines.add_all (defines);

        this.experimental = experimental;
        this.experimental_non_null = experimental_non_null;
        this.profile = profile;
        this.abi_stability = abi_stability;
    }

    public Compilation.without_parent () {
        this.profile = Vala.Profile.GOBJECT;
    }

    public TextDocument add_source_file (string filename, 
        bool is_writable = true) throws ConvertError, FileError {
        if (_sources.has_key (filename))
            throw new FileError.FAILED (@"file `$filename' is already in the compilation");
        var source = new TextDocument (this, filename, is_writable);
        _sources[filename] = source;
        if (source.file.package_name != null)
            _packages.remove (source.file.package_name);
        dirty = true;
        return source;
    }

    public bool compile () {
        if (!(needs_compile || dirty))
            return false;
        Vala.CodeContext.push (this.code_context);
        var parser = new Vala.Parser ();
        parser.parse (code_context);

        var genie_parser = new Vala.Genie.Parser ();
        genie_parser.parse (code_context);

        var gir_parser = new Vala.GirParser ();
        gir_parser.parse (code_context);

        code_context.check ();
        // wrap autosources
        foreach (var auto_source in get_internal_files ()) {
            try {
                _autosources[auto_source.filename] = new TextDocument.from_sourcefile (this, auto_source, false);
                debug (@"compilation: wrapped autosource `$(auto_source.filename)'");
            } catch (Error e) {
                debug (@"compilation: failed to wrap autosource `$(auto_source.filename)': $(e.message)");
            }
        }
        Vala.CodeContext.pop ();
        needs_compile = false;
        return true;
    }

    /**
     * Should only be used when changing source file content.
     */
    public void invalidate () {
        dirty = true;
    }

    /**
     * Lookup a source file by filename.
     */
    public TextDocument? lookup_source_file (string filename) {
        var result = _sources[filename];
        if (result == null)
            return _autosources[filename];
        return result;
    }

    public Iterator<TextDocument> iterator () {
        return _sources.values.iterator ();
    }

    /**
     * Get source files automatically added during the last compilation.
     */
    public Gee.List<Vala.SourceFile> get_internal_files () {
        var internal_files = new ArrayList<Vala.SourceFile> ();

        if (_ctx != null)
            foreach (var source_file in _ctx.get_source_files ()) {
                if (!_sources.has_key (source_file.filename))
                    internal_files.add (source_file);
            }

        return internal_files;
    }
}
