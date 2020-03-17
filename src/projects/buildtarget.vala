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

    public string type_name { get; construct; }

    /**
     * The compilation for this build target
     */
    public Compilation compilation { get; protected set; }

    /**
     * A list of all BuildTargets that produce files needed by some
     * of our compilations.
     */
    public HashTable<File, BuildTarget> dependencies { get; protected set; }

    construct {
        dependencies = new HashTable<File, BuildTarget> (Compilation.file_hash, Compilation.files_equal);
    }

    public static uint hash (BuildTarget target) {
        return str_hash (target.id);
    }

    public static bool equal (BuildTarget bt1, BuildTarget bt2) {
        return bt1.id == bt2.id;
    }

    protected BuildTarget (string script_uri, string id, string type_name) {
        Object (script_uri: script_uri, id: id, type_name: type_name);
    }

    public string to_string () {
        return @"$type_name($id)";
    }

    /**
     * Run the compiler for all compilations.
     */
    public bool compile () {
        bool updated = false;
        // compile our dependencies first
        foreach (var target in dependencies.get_values ()) {
            updated |= target.compile ();
            if (compilation.last_compiled != null && 
                target.compilation.last_compiled.compare (compilation.last_compiled) > 0)
                compilation.invalidate ();
        }
        // if our dependencies updated, their output updated too
        updated |= compilation.compile ();
        return updated;
    }

    public TextDocument? lookup_source_file (string uri) {
        return compilation.lookup_source_file (uri);
    }
}
