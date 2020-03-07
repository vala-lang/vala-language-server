using Gee;

/**
 * Represents a single build target from a build script.
 * Usage:
 * 1. configure a build directory for a build script
 * 2. generate a BuildTarget for each target in the build directory
 * 3. generate a Compilation for each target source in each BuildTarget
 * 4. resolve dependencies between build targets
 */
abstract class Vls.BuildTarget : Object {
    /**
     * The script this target is defined in, or
     * the directory of the project if there is no
     * build script.
     */
    public string script_uri { get; construct; }

    /**
     * The ID of the build target.
     */
    public string id { get; construct; }

    /**
     * Where build files are located.
     */
    public string build_dir { get; construct; }

    /**
     * The list of files produced by this target.
     */
    public ArrayList<string> produced_files { get; protected set; }

    /**
     * The list of compilations, where each compilation
     * includes a list of sources and compiler flags.
     */
    protected ArrayList<Compilation> compilations { get; protected set; }

    /**
     * A list of all BuildTargets that produce files needed by some
     * of our compilations.
     */
    public ArrayList<BuildTarget> dependencies { get; protected set; }

    construct {
        produced_files = new ArrayList<string> ();
        compilations = new ArrayList<Compilation> ();
        dependencies = new ArrayList<BuildTarget> ();
    }

    public static uint hash (BuildTarget target) {
        return str_hash (target.id);
    }

    public static bool equal (BuildTarget bt1, BuildTarget bt2) {
        return bt1.id == bt2.id;
    }

    protected BuildTarget (string script_uri, string id, string build_dir) {
        Object (script_uri: script_uri, id: id, build_dir: build_dir);
    }

    public Iterator<Compilation> iterator () {
        return compilations.iterator ();
    }

    public virtual string to_string () {
        return @"BuildTarget($id @ $script_uri)";
    }

    /**
     * Run the compiler for all compilations.
     */
    public bool compile () {
        bool updated = false;
        // compile our dependencies first
        foreach (var target in dependencies)
            updated |= target.compile ();

        foreach (var compilation in compilations)
            updated |= compilation.compile ();
        return updated;
    }

    public TextDocument? lookup_source_file (string uri) {
        int nth = 0;
        foreach (var compilation in compilations) {
            debug (@"looking inside compilation #$(nth) for $uri");
            var result = compilation.lookup_source_file (uri);
            if (result != null)
                return result;
            nth++;
        }
        debug (@"nothing found");
        return null;
    }
}
