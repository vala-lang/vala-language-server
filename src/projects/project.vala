/* project.vala
 *
 * Copyright 2020 Princeton Ferro <princetonferro@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Gee;

/**
 * An abstract representation of a project with any possible backend.
 */
abstract class Vls.Project : Object {
    /**
     * The root path for this project.
     */
    public string root_path { get; private set; }

    /**
     * This collection must be topologically sorted.
     */
    protected ArrayList<BuildTarget> build_targets = new ArrayList<BuildTarget> (); 

    /** 
     * Directories of additional files (mainly C sources) that have to be
     * monitored because they have an indirect influence on Vala code.
     */
    private HashMap<File, FileMonitor> monitored_files = new HashMap<File, FileMonitor> (Util.file_hash, Util.file_equal);

    protected Project (string root_path) {
        this.root_path = root_path;
    }

    /** 
     * Determine dependencies and remove build targets that are not needed.
     * This is the final operation needed before the project is ready to be
     * built.
     */
    protected void analyze_build_targets (Cancellable? cancellable = null) throws Error {
        // first, check that at least one target is a Compilation
        if (!build_targets.any_match (t => t is Compilation))
            throw new ProjectError.CONFIGURATION (@"project has no Vala targets");

        // there may be multiple consumers of a file
        var consumers_of = new HashMap<File, HashSet<BuildTarget>> (Util.file_hash, Util.file_equal);
        // there can only be one primary producer of a file, while there can be
        // many secondary producers that modify the file
        var producers_for = new HashMap<File, HashSet<BuildTarget>> (Util.file_hash, Util.file_equal); 
        var unknown = new ArrayList<BuildTask> ();

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
                if (!producers_for.has_key (file_produced))
                    producers_for[file_produced] = new HashSet<BuildTarget> ();
                producers_for[file_produced].add (btarget);
                is_consumer_or_producer = true;
                debug ("\t- %s produces %s", btarget.id, file_produced.get_path ());
            }
            if (!is_consumer_or_producer) {
                if (!(btarget is BuildTask))
                    throw new ProjectError.CONFIGURATION (@"Only build tasks can be initially neither producers nor consumers, not $(btarget.get_class ().get_name ())!");
                debug ("\t- %s neither produces nor consumes any files (for now)", btarget.id);
            }
            // add btarget to neither anyway, if it is a build task
            if (btarget is BuildTask)
                unknown.add ((BuildTask) btarget);
        }

        // 2. For those in the 'unknown' category, attempt to guess whether
        //    they are producers or consumers. For each file of each target,
        //    if the file already has a producer, then the target probably 
        //    consumes that file. If the file has only consumers, then the target
        //    probably produces that file.
        //    Note: this strategy assumes topological ordering of the targets.
        foreach (var btask in unknown) {
            var files_categorized = new HashSet<File> (Util.file_hash, Util.file_equal);
            foreach (var file in btask.used_files) {
                if (file in btask.input) {
                    // if it's an input file, whether it's an output file will
                    // most likely already have been determined by looking at
                    // the meson target info
                    files_categorized.add (file);
                    continue;
                }
                if (producers_for.has_key (file)) {
                    if (!consumers_of.has_key (file))
                        consumers_of[file] = new HashSet<BuildTarget> ();
                    consumers_of[file].add (btask);
                    btask.input.add (file);
                    files_categorized.add (file);
                    debug ("\t- %s consumes %s", btask.id, file.get_path ());
                } else if (consumers_of.has_key (file)) {
                    if (!producers_for.has_key (file))
                        producers_for[file] = new HashSet<BuildTarget> ();
                    producers_for[file].add (btask);
                    btask.output.add (file);
                    files_categorized.add (file);
                    debug ("\t- %s produces %s", btask.id, file.get_path ());
                }
            }
            btask.used_files.remove_all (files_categorized);
            foreach (var uncategorized_file in btask.used_files) {
                // candidate inputs are files that would only be inputs to this
                // target if they exist at least at the time this target is
                // built
                if (uncategorized_file in btask.candidate_inputs)
                    continue;
                // assume all files not categorized and not input candidates
                // are outputs to the next target(s)
                if (producers_for.has_key (uncategorized_file)) {
                    producers_for[uncategorized_file].foreach (conflict => {
                        warning ("Project: build target %s already produces file (%s) produced by %s.", 
                                 conflict.id, uncategorized_file.get_path (), btask.id);
                        return true;
                    });
                    continue;
                } else {
                    producers_for[uncategorized_file] = new HashSet<BuildTarget> ();
                }
                producers_for[uncategorized_file].add (btask);
                btask.output.add (uncategorized_file);
                debug ("\t- %s produces %s", btask.id, uncategorized_file.get_path ());
            }
            btask.used_files.clear ();
        }

        // 3. Now check for two or more primary producers of the same file, which is not allowed.
        foreach (var entry in producers_for) {
            var file_produced = entry.key;
            var producers = entry.value;
            foreach (var btarget in producers) {
                if (!(file_produced in btarget.input) &&
                    producers.any_match (other => !other.equal_to (btarget) && !(file_produced in other.input))) {
                    var conflict = producers.first_match (other => !other.equal_to (btarget) && !(file_produced in other.input));
                    throw new ProjectError.CONFIGURATION (@"There are two build targets that only produce the same file! Both $(btarget.id) and $(conflict.id) produce $(file_produced.get_path ())");
                }
            }
        }

        // 4. Analyze dependencies. Only keep build targets that are Compilations 
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
            bool needed_by_vala_compilation = false;
            // build_targets[i] is the producer 
            // build_targets[j] is the consumer
            for (int j = last_idx; j > i; j--) {
                foreach (var file in build_targets[j].input) {
                    if (producers_for.has_key (file) &&
                        producers_for[file].any_match (t => t.equal_to (build_targets [i]))) {
                        needed_by_vala_compilation = true;
                        build_targets[j].dependencies[file] = build_targets[i];
                        debug ("Project: found dependency: %s --(%s)--> %s", 
                               build_targets[i].id, file.get_path (), build_targets[j].id);
                    }
                }
            }
            if (needed_by_vala_compilation || build_targets[i] is Compilation)
                targets_to_keep.offer_head (build_targets[i]);
        }
        foreach (var target in build_targets)
            if (!(target in targets_to_keep))
                debug ("target %s will be removed", target.id);
        build_targets.clear ();
        build_targets.add_all (targets_to_keep);

        // 5. sanity check: the targets should all be in the order they are defined
        //    (this is probably unnecessary)
        for (int i = 1; i < build_targets.size; i++) {
            if (build_targets[i].no < build_targets[i-1].no)
                throw new ProjectError.CONFIGURATION (@"Project: build target #$(build_targets[i].no) ($(build_targets[i].id)) comes after build target #$(build_targets[i-1].no) ($(build_targets[i-1].id))");
        }

        // 6. monitor source directories of non-Vala build targets
        foreach (BuildTarget btarget in build_targets) {
            if (btarget is Compilation)
                continue;
            foreach (File file in btarget.input) {
                File? parent = file.get_parent ();
                if (parent != null && parent.query_file_type (FileQueryInfoFlags.NONE) == FileType.DIRECTORY) {
                    if (!monitored_files.has_key (parent)) {
                        debug ("Project: obtaining a new file monitor for %s ...", parent.get_path ());
                        FileMonitor file_monitor = parent.monitor_directory (FileMonitorFlags.NONE, cancellable);
                        file_monitor.changed.connect (file_changed_event);
                        monitored_files[parent] = file_monitor;
                    }
                }
            }
        }
    }

    private void file_changed_event (File src, File? dest, FileMonitorEvent event_type) {
        // ignore file changed events for Vala source files
        if (Util.arg_is_vala_file (src.get_path ()) ||
            (dest != null && Util.arg_is_vala_file (dest.get_path ())))
            return;

        if (FileMonitorEvent.ATTRIBUTE_CHANGED in event_type) {
            debug ("Project: watched file %s had an attribute changed", src.get_path ());
            changed ();
        }
        if (FileMonitorEvent.CHANGED in event_type) {
            debug ("Project: watched file %s was changed", src.get_path ());
            changed ();
        }
        if (FileMonitorEvent.DELETED in event_type) {
            debug ("Project: watched file %s was deleted", src.get_path ());
            // remove this file monitor since the file was deleted
            FileMonitor file_monitor;
            if (monitored_files.unset (src, out file_monitor)) {
                file_monitor.cancel ();
                file_monitor.changed.disconnect (file_changed_event);
            }
            changed ();
        }
    }

    /**
     * Emitted when build files change. This is mainly useful for tracking files that indirectly
     * affect Vala messages, such as C sources or build scripts.
     */
    public signal void changed ();

    /**
     * Reconfigure the project if there were changes to the build files that warrant doing so.
     * Returns true if the project was actually reconfigured, false otherwise.
     */
    public abstract async bool reconfigure_async (Cancellable? cancellable = null) throws Error;

    /**
     * Build those elements of the project that need to be rebuilt.
     */
    public virtual async void rebuild_async (Cancellable? cancellable = null) throws Error {
        // this iteration should be in topological order
        foreach (var btarget in build_targets)
            yield btarget.rebuild_async (cancellable);
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
     * Determine the Compilation that outputs `filename`
     * Return true if found, false otherwise.
     */
    public bool lookup_compilation_for_output_file (string filename, out Compilation compilation) {
        var file = File.new_for_commandline_arg_and_cwd (filename, root_path);
        foreach (var btarget in build_targets) {
            if (!(btarget is Compilation))
                continue;
            if (btarget.output.contains (file)) {
                compilation = (Compilation)btarget;
                return true;
            }
        }
        compilation = null;
        return false;
    }

    /**
     * Open the file. Is guaranteed to return a non-empty result, or will
     * throw an error.
     */
    public virtual async ArrayList<Pair<Vala.SourceFile, Compilation>> open (
        string escaped_uri,
        string? content = null,
        Cancellable? cancellable = null
    ) throws Error {
        var results = lookup_compile_input_source_file (escaped_uri);
        if (results.is_empty)
            throw new ProjectError.NOT_FOUND ("cannot open %s - file cannot be created for this type of project", escaped_uri);
        return results;
    }

    /**
     * Close the file. Returns whether a context update is required.
     * The default implementation of this method is to restore the text document to 
     * its last save point.
     */
    public virtual bool close (string escaped_uri) throws Error {
        var results = lookup_compile_input_source_file (escaped_uri);
        if (results.is_empty)
            return false;
        bool modified = false;
        foreach (var pair in results) {
            var text_document = pair.first as TextDocument;
            if (text_document == null)
                continue;
            // If we're closing this document, but the last saved version 
            // is not the same as the current version, then we need to 
            // restore our last checkpoint.
            if (text_document.last_saved_version != text_document.version) {
                text_document.content = text_document.last_saved_content;
                text_document.version = text_document.last_saved_version;
                text_document.last_updated = new DateTime.now ();
                modified = true;
            }
        }
        return modified;
    }

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
    
    /**
     * Gets a list of all directories containing GIRs that are generated by a
     * target.
     */
    public Collection<File> get_custom_gir_dirs () {
        var results = new HashSet<File> (Util.file_hash, Util.file_equal);
        foreach (var btarget in build_targets) {
            foreach (var output_file in btarget.output) {
                if (output_file.get_path ().has_suffix (".gir")) {
                    var parent = output_file.get_parent ();
                    if (parent != null)
                        results.add (parent);
                }
            }
        }
        return results;
    }

    /**
     * Get all source files used in this project.
     */
    public Iterable<Map.Entry<Vala.SourceFile, Compilation>> get_project_source_files () {
        var results = new HashMap<Vala.SourceFile, Compilation> ();
        foreach (var btarget in build_targets) {
            if (!(btarget is Compilation))
                continue;
            foreach (var file in ((Compilation)btarget).get_project_files ())
                results[file] = (Compilation)btarget;
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
     * Project backend has unsupported version.
     */
    VERSION_UNSUPPORTED,

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
    TASK_FAILED,

    /**
     * Opening a file failed because it was not found
     */
    NOT_FOUND
}
