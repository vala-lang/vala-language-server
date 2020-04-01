using Gee;

/**
 * An abstract representation of a project with any possible backend.
 */
abstract class Vls.Project : Object {
    /**
     * This collection must be topologically sorted.
     */
    protected ArrayList<BuildTarget> build_targets = new ArrayList<BuildTarget> (); 

    /** 
     * Determine dependencies and remove build targets that are not needed.
     * This is the final operation needed before the project is ready to be
     * built.
     */
    protected void analyze_build_targets () throws Error {
        // there may be multiple consumers of a file
        var consumers_of = new HashMap<File, HashSet<BuildTarget>> (Util.file_hash, Util.file_equal);
        // there can only be one producer for a file
        var producer_for = new HashMap<File, BuildTarget> (Util.file_hash, Util.file_equal); 
        var neither = new ArrayList<BuildTask> ();

        // 1. Find producers + consumers
        debug ("Project: analyzing build targets - producers and consumers ...");
        foreach (var btarget in build_targets) {
            bool is_consumer_or_producer = false;
            foreach (var file_consumed in btarget.input) {
                if (!consumers_of.has_key (file_consumed))
                    consumers_of[file_consumed] = new HashSet<BuildTarget> ();
                consumers_of[file_consumed].add (btarget);
                is_consumer_or_producer = true;
                debug ("\t- %s consumes %s", btarget.id, file_consumed.get_path ());
            }
            foreach (var file_produced in btarget.output) {
                if (producer_for.has_key (file_produced)) {
                    BuildTarget conflict = producer_for[file_produced];
                    throw new ProjectError.CONFIGURATION (@"There are two build targets that produce the same file! Both $(btarget.id) and $(conflict.id) produce $(file_produced.get_path ())");
                }
                producer_for[file_produced] = btarget;
                is_consumer_or_producer = true;
                debug ("\t- %s produces %s", btarget.id, file_produced.get_path ());
            }
            if (!is_consumer_or_producer) {
                if (!(btarget is BuildTask))
                    throw new ProjectError.CONFIGURATION (@"Only build tasks can be initially neither producers nor consumers, yet $(btarget.get_class ().get_name ()) is neither!");
                neither.add ((BuildTask) btarget);
                debug ("\t- %s neither produces nor consumes any files (for now)", btarget.id);
            }
        }

        // 2. For those in the 'neither' category, attempt to guess whether
        //    they are producers or consumers. For each file of each target,
        //    if the file already has a producer, then the target probably 
        //    consumes that file. If the file has only consumers, then the target
        //    probably produces that file.
        //    Note: this strategy assumes topological ordering of the targets.
        foreach (var btask in neither) {
            var files_categorized = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var file in btask.used_files) {
                if (producer_for.has_key (file)) {
                    if (!consumers_of.has_key (file))
                        consumers_of[file] = new HashSet<BuildTarget> ();
                    consumers_of[file].add (btask);
                    btask.input.add (file);
                    files_categorized.add (file);
                } else if (consumers_of.has_key (file)) {
                    producer_for[file] = btask;
                    btask.output.add (file);
                    files_categorized.add (file);
                }
            }
            btask.used_files.remove_all (files_categorized);
            // assume all files not categorized are outputs to the next target(s)
            foreach (var uncategorized_file in btask.used_files) {
                if (producer_for.has_key (uncategorized_file)) {
                    BuildTarget conflict = producer_for[uncategorized_file];
                    warning ("Project: build target %s already produces file (%s) produced by %s.", 
                             conflict.id, uncategorized_file.get_path (), btask.id);
                    continue;
                }
                producer_for[uncategorized_file] = btask;
                btask.output.add (uncategorized_file);
            }
            btask.used_files.clear ();
        }

        // 3. Analyze dependencies. Only keep build targets that are Compilations 
        //    or are in a dependency chain for a Compilation
        var targets_to_keep = new LinkedList<BuildTarget> ();
        int last_idx = build_targets.size - 1;
        for (; last_idx >= 0; last_idx--) {
            // find the last build target that is a compilation
            if (build_targets[last_idx] is Compilation) {
                targets_to_keep.offer_head (build_targets[last_idx]);
                break;
            }
        }
        for (int i = last_idx - 1; i >= 0; i--) {
            bool produces_file_for_target = false;
            for (int j = last_idx - 1; j > i; j--) {
                foreach (var file in build_targets[j].input) {
                    if (producer_for.has_key (file) && producer_for[file].equal_to (build_targets[i])) {
                        produces_file_for_target = true;
                        build_targets[j].dependencies[file] = build_targets[i];
                        debug ("Project: found dependency: %s --(%s)--> %s", 
                               build_targets[i].id, file.get_path (), build_targets[j].id);
                    }
                }
            }
            if (produces_file_for_target || build_targets[i] is Compilation)
                targets_to_keep.offer_head (build_targets[i]);
            else
                debug ("Project: target #%d (%s) will be removed", i, build_targets[i].id);
        }
        build_targets.clear ();
        build_targets.add_all (targets_to_keep);

        // 4. sanity check: the targets should all be in the order they are defined
        //    (this is probably unnecessary)
        for (int i = 1; i < build_targets.size; i++) {
            if (build_targets[i].no < build_targets[i-1].no)
                throw new ProjectError.CONFIGURATION (@"Project: build target #$(build_targets[i].no) ($(build_targets[i].id)) comes after build target #$(build_targets[i-1].no) ($(build_targets[i-1].id))");
        }
    }

    /**
     * Reconfigure the project if there were changes to the build files that warrant doing so.
     * Returns true if the project was actually reconfigured, false otherwise.
     */
    public abstract bool reconfigure_if_stale (Cancellable? cancellable = null) throws Error;

    /**
     * Build those elements of the project that need to be rebuilt.
     */
    public void build_if_stale (Cancellable? cancellable = null) throws Error {
        // this iteration should be in topological order
        foreach (var btarget in build_targets)
            btarget.build_if_stale (cancellable);
    }

    /**
     * Find all source files matching `escaped_uri`
     */
    public ArrayList<Pair<Vala.SourceFile, Compilation>> lookup_compile_input_source_file (string escaped_uri) {
        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        var file = File.new_for_uri (Uri.unescape_string (escaped_uri));
        foreach (var btarget in build_targets) {
            if (!(btarget is Compilation))
                continue;
            Vala.SourceFile input_source;
            if (((Compilation)btarget).lookup_input_source_file (file, out input_source))
                results.add (new Pair<Vala.SourceFile, Compilation> (input_source, (Compilation)btarget));
        }
        return results;
    }

    /**
     * Open the file
     */
    public virtual void open (string escaped_uri, Cancellable? cancellable = null) throws Error { /* do nothing */ }

    /**
     * Close the file
     */
    public virtual void close (string escaped_uri) throws Error { /* do nothing */ }

#if PARSE_SYSTEM_GIRS
    /**
     * Get all unique packages used in this project
     */
    public Collection<Vala.SourceFile> get_packages () {
        var results = new HashSet<Vala.SourceFile> (Util.source_file_hash, Util.source_file_equal);
        foreach (var btarget in build_targets) {
            if (!(btarget is Compilation))
                continue;
            var compilation = (Compilation) btarget;
            foreach (var source_file in compilation.code_context.get_source_files ())
                if (source_file.file_type == Vala.SourceFileType.PACKAGE)
                    results.add (source_file);
        }
        return results;
    }
#endif

    /**
     * Get all source files used in this project.
     */
    public Collection<Vala.SourceFile> get_project_source_files () {
        var results = new ArrayList<Vala.SourceFile> ();
        foreach (var btarget in build_targets) {
            if (!(btarget is Compilation))
                continue;
            results.add_all (((Compilation)btarget).get_project_files ());
        }
        return results;
    }

    public ArrayList<Compilation> get_compilations () {
        var results = new ArrayList<Compilation> ();
        foreach (var btarget in build_targets)
            if (btarget is Compilation)
                results.add ((Compilation) btarget);
        return results;
    }
}

errordomain Vls.ProjectError {
    /**
     * Generic error during project introspection.
     */
    INTROSPECTION,

    /**
     * Failure during project configuration
     */
    CONFIGURATION,

    /**
     * If a build task failed. 
     */
    TASK_FAILED
}
