using Gee;
using GLib;

/**
 * The point of this class is to refresh the Vala.CodeContext every time
 * we change something.
 */
class Vls.Context {
    private HashSet<string> _defines;
    private HashSet<string> _packages;
    private HashMap<string, TextDocument> _sources;

    public bool dirty { get; private set; default = true; }

    private Vala.CodeContext? _ctx;

    public Vala.CodeContext code_context {
        get {
            if (dirty) {
                // generate a new code context 
                _ctx = new Vala.CodeContext ();
                dirty = false;

                string version = "0.38.3"; //Config.libvala_version;
                string[] parts = version.split(".");
                assert (parts.length == 3);
                assert (parts[0] == "0");
                var minor = int.parse (parts[1]);

                _ctx.profile = Vala.Profile.GOBJECT;
                for (int i = 2; i <= minor; i += 2) {
                    _ctx.add_define ("VALA_0_%d".printf (i));
                }
                _ctx.target_glib_major = 2;
                _ctx.target_glib_minor = 38;
                for (int i = 16; i <= _ctx.target_glib_minor; i += 2) {
                    _ctx.add_define ("GLIB_2_%d".printf (i));
                }
                foreach (var define in _defines)
                    _ctx.add_define (define);
                _ctx.report = new Reporter ();
                _ctx.add_external_package ("glib-2.0");
                _ctx.add_external_package ("gobject-2.0");

                foreach (var package in _packages)
                    _ctx.add_external_package (package);

                _sources.@foreach (entry => {
                    _ctx.add_source_file (entry.value.file);
                    return true;
                });
            }
            return _ctx;
        }
    }

    public Context() {
        _defines = new HashSet<string> (d => str_hash(d), (a,b) => str_equal (a,b));
        _packages = new HashSet<string> (d => str_hash(d), (a,b) => str_equal (a,b));
        _sources = new HashMap<string, TextDocument> (d => str_hash (d), (a,b) => str_equal (a,b));
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

    public void clear_defines () {
        _defines.clear ();
        dirty = true;
    }

    public void clear_packages () {
        _packages.clear ();
        dirty = true;
    }

    public void clear_sources () {
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
}
