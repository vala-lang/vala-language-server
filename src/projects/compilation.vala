/* compilation.vala
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

class Vls.Compilation : BuildTarget {
    private HashSet<string> _packages = new HashSet<string> ();
    private HashSet<string> _defines = new HashSet<string> ();

    private HashSet<string> _vapi_dirs = new HashSet<string> ();
    private HashSet<string> _gir_dirs = new HashSet<string> ();
    private HashSet<string> _metadata_dirs = new HashSet<string> ();
    private HashSet<string> _gresources_dirs = new HashSet<string> ();

    /**
     * This helps us determine which files have remained the same after an
     * update.
     */
    private FileCache _file_cache;

    /**
     * These are files that are part of the project.
     */
    private HashMap<File, SourceFileWorker> _project_sources = new HashMap<File, SourceFileWorker> (Util.file_hash, Util.file_equal);

    /**
     * This is the list of initial content for project source files.
     * Used for files that do not exist ('untitled' files);
     */
    private HashMap<File, string> _sources_initial_content = new HashMap<File, string> (Util.file_hash, Util.file_equal);

    /**
     * These may not exist until right before we compile the code context.
     */
    private HashSet<File> _generated_sources = new HashSet<File> (Util.file_hash, Util.file_equal);

    /**
     * The analyses for each project source.
     */
    private HashMap<Vala.SourceFile, HashMap<Type, CodeAnalyzer>> _source_analyzers = new HashMap<Vala.SourceFile, HashMap<Type, CodeAnalyzer>> ();

    /**
     * List of source file workers for all source files, including
     * automatically-added sources.
     */
    private ConcurrentList<SourceFileWorker> _all_sources = new ConcurrentList<SourceFileWorker> ();

    private Vala.CodeContext _context;
    public Vala.CodeContext context {
        get { return _context; }
    }

    // CodeContext arguments:
    private bool _deprecated;
    private bool _experimental;
    private bool _experimental_non_null;
    private bool _abi_stability;
    private string? _target_glib;

    /**
     * The output directory.
     */
    public string directory { get; private set; }
    private Vala.Profile _profile;
    private string? _entry_point_name;
    private bool _fatal_warnings;

    /**
     * Absolute path to generated VAPI
     */
    private string? _output_vapi;

    /**
     * Absolute path to generated GIR
     */
    private string? _output_gir;

    /**
     * Absolute path to generated internal VAPI
     */
    private string? _output_internal_vapi;

    private bool _completed_first_compile;

    /**
     * The reporter for the code context
     */
    public Reporter reporter {
        get {
            assert (_context.report is Reporter);
            return (Reporter) _context.report;
        }
    }

    /**
     * Maps a symbol's C name to the actual symbol. The documentation engine
     * uses this to replace references to C symbols with appropriate Vala references.
     */
    public HashMap<string, Vala.Symbol> cname_to_sym { get; private set; default = new HashMap<string, Vala.Symbol> (); }

    public Compilation (FileCache file_cache,
                        string output_dir, string name, string id, int no,
                        string[] compiler, string[] args, string[] sources, string[] generated_sources,
                        string?[] target_output_files,
                        string[]? sources_content = null) throws Error {
        base (output_dir, name, id, no);
        _file_cache = file_cache;
        directory = output_dir;

        // parse arguments
        var output_dir_file = File.new_for_path (output_dir);
        bool set_directory = false;
        string? flag_name, arg_value;           // --<flag_name>[=<arg_value>]

        // because we rely on --directory for determining the location of output files
        // because we rely on --basedir (if defined) for determining the location of input files
        for (int arg_i = -1; (arg_i = Util.iterate_valac_args (args, out flag_name, out arg_value, arg_i)) < args.length;) {
            if (flag_name == "directory") {
                if (arg_value == null) {
                    warning ("Compilation(%s) null --directory", id);
                    continue;
                }
                directory = Util.realpath (arg_value, output_dir);
                set_directory = true;
            }
        }

        for (int arg_i = -1; (arg_i = Util.iterate_valac_args (args, out flag_name, out arg_value, arg_i)) < args.length;) {
            if (flag_name == "pkg") {
                _packages.add (arg_value);
            } else if (flag_name == "vapidir") {
                _vapi_dirs.add (arg_value);
            } else if (flag_name == "girdir") {
                _gir_dirs.add (arg_value);
            } else if (flag_name == "metadatadir") {
                _metadata_dirs.add (arg_value);
            } else if (flag_name == "gresourcesdir") {
                _gresources_dirs.add (arg_value);
            } else if (flag_name == "define") {
                _defines.add (arg_value);
            } else if (flag_name == "enable-experimental") {
                _experimental = true;
            } else if (flag_name == "enable-experimental-non-null") {
                _experimental_non_null = true;
            } else if (flag_name == "fatal-warnings") {
                _fatal_warnings = true;
            } else if (flag_name == "profile") {
                if (arg_value == "posix")
                    _profile = Vala.Profile.POSIX;
                else if (arg_value == "gobject")
                    _profile = Vala.Profile.GOBJECT;
                else
                    throw new ProjectError.INTROSPECTION (@"Compilation($id) unsupported Vala profile `$arg_value'");
            } else if (flag_name == "abi-stability") {
                _abi_stability = true;
            } else if (flag_name == "target-glib") {
                _target_glib = arg_value;
            } else if (flag_name == "vapi" || flag_name == "gir" || flag_name == "internal-vapi") {
                if (arg_value == null) {
                    warning ("Compilation(%s) --%s is null", id, flag_name);
                    continue;
                }

                string path = Util.realpath (arg_value, directory);
                if (!set_directory)
                    warning ("Compilation(%s) no --directory given, assuming %s", id, directory);
                if (flag_name == "vapi")
                    _output_vapi = path;
                else if (flag_name == "gir")
                    _output_gir = path;
                else
                    _output_internal_vapi = path;

                output.add (File.new_for_path (path));
            } else if (flag_name == null) {
                if (arg_value == null) {
                    warning ("Compilation(%s) failed to parse argument #%d (%s)", id, arg_i, args[arg_i]);
                } else if (Util.arg_is_vala_file (arg_value)) {
                    var file_from_arg = File.new_for_path (Util.realpath (arg_value, output_dir));
                    if (output_dir_file.get_relative_path (file_from_arg) != null)
                        _generated_sources.add (file_from_arg);
                    input.add (file_from_arg);
                }
            } else if (flag_name != "directory") {
                debug ("Compilation(%s) ignoring argument #%d (%s)", id, arg_i, args[arg_i]);
            }
        }

        for (int i = 0; i < sources.length; i++) {
            unowned string source = sources[i];
            unowned string? content = sources_content != null ? sources_content[i] : null;

            string? uri_scheme = Uri.parse_scheme (source);
            if (uri_scheme != null && uri_scheme.down () != "c") {
                var file = File.new_for_uri (source);
                input.add (file);
                if (content != null)
                    _sources_initial_content[file] = content;
            } else {
                input.add (File.new_for_path (Util.realpath (source, output_dir)));
            }
        }

        foreach (string generated_source in generated_sources) {
            var generated_source_file = File.new_for_path (Util.realpath (generated_source, output_dir));
            _generated_sources.add (generated_source_file);
            input.add (generated_source_file);
        }

        // add the rest of these target output files
        foreach (string? output_file in target_output_files) {
            if (output_file != null) {
                if (output.add (File.new_for_commandline_arg_and_cwd (output_file, output_dir)))
                    debug ("Compilation(%s): also outputs %s", id, output_file);
            }
        }

        // finally, add these very important packages
        if (_profile == Vala.Profile.POSIX) {
            _packages.add ("posix");
        } else {
            _packages.add ("glib-2.0");
            _packages.add ("gobject-2.0");
            if (_profile != Vala.Profile.GOBJECT)
                warning ("Compilation(%s) no --profile argument given, assuming GOBJECT", id);
        }
    }

    private void configure (Cancellable? cancellable = null) throws Error {
        cancellable.set_error_if_cancelled ();

        // 0. remove source file workers from old sources and clear cname mapper
        var old_workers = new ArrayList<SourceFileWorker> ();
        old_workers.add_all (_all_sources);
        cname_to_sym.clear ();
        foreach (var old_worker in old_workers) {
            old_worker.update (SourceFileWorker.Status.NOT_PARSED);
            // we're using this to wait for threads to terminate that depend on
            // the source file being parsed
            old_worker.acquire (cancellable);
            if (!(old_worker.source_file is TextDocument))
                _all_sources.remove (old_worker);
            old_worker.release (cancellable);
        }

        // 1. (re)create code context
        _context = new Vala.CodeContext () {
            deprecated = _deprecated,
            experimental = _experimental,
            experimental_non_null = _experimental_non_null,
            abi_stability = _abi_stability,
            directory = directory,
            vapi_directories = _vapi_dirs.to_array (),
            gir_directories = _gir_dirs.to_array (),
            metadata_directories = _metadata_dirs.to_array (),
            keep_going = true,
            // report = new Reporter (_fatal_warnings),
            entry_point_name = _entry_point_name,
            gresources_directories = _gresources_dirs.to_array ()
        };

#if VALA_0_50
        _context.set_target_profile (_profile, false);
#else
        _context.profile = _profile;
        switch (_profile) {
            case Vala.Profile.POSIX:
                context.add_define ("POSIX");
                break;
            case Vala.Profile.GOBJECT:
                context.add_define ("GOBJECT");
                break;
        }
#endif

        // Vala compiler bug requires us to initialize things this way instead of
        // the alternative above
        _context.report = new Reporter (_fatal_warnings);

        // set target GLib version if specified
        if (_target_glib != null)
            _context.set_target_glib_version (_target_glib);
        Vala.CodeContext.push (_context);

        foreach (string define in _defines)
            _context.add_define (define);

        if (_project_sources.is_empty) {
            // debug ("Compilation(%s): will load input sources for the first time", id);
            if (input.is_empty)
                warning ("Compilation(%s): no input sources to load!", id);
            foreach (File file in input) {
                if (!dependencies.has_key (file)) {
                    try {
                        var text_document = new TextDocument (_context, file, _sources_initial_content[file], true);
                        var worker = new SourceFileWorker (text_document);
                        _project_sources[file] = worker;
                        _all_sources.add (worker);
                    } catch (Error e) {
                        warning ("Compilation(%s): %s", id, e.message);
                        Vala.CodeContext.pop ();
                        throw e;    // rethrow
                    }
                } else
                    _generated_sources.add (file);

                cancellable.set_error_if_cancelled ();
            }
        }

        foreach (SourceFileWorker worker in _project_sources.values) {
            worker.acquire (cancellable);

            var doc = (TextDocument)worker.source_file;
            doc.context = _context;
            _context.add_source_file (doc);
            // clear all using directives (to avoid "T ambiguous with T" errors)
            doc.current_using_directives.clear ();
            // add default using directives for the profile
            if (_profile == Vala.Profile.POSIX) {
                // import the Posix namespace by default (namespace of backend-specific standard library)
                var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, "Posix", null));
                doc.add_using_directive (ns_ref);
                _context.root.add_using_directive (ns_ref);
            } else if (_profile == Vala.Profile.GOBJECT) {
                // import the GLib namespace by default (namespace of backend-specific standard library)
                var ns_ref = new Vala.UsingDirective (new Vala.UnresolvedSymbol (null, "GLib", null));
                doc.add_using_directive (ns_ref);
                _context.root.add_using_directive (ns_ref);
            }

            // clear all comments from file
            doc.get_comments ().clear ();

            // clear all code nodes from file
            doc.get_nodes ().clear ();

            worker.release (cancellable);
        }

        // packages (should come after in case we've wrapped any package files in TextDocuments)
        foreach (string package in _packages)
            _context.add_external_package (package);

        Vala.CodeContext.pop ();
    }

    private void compile (Cancellable? cancellable = null) throws Error {
        cancellable.set_error_if_cancelled ();

        debug ("compiling %s ...", id);
        var vala_parser = new Vala.Parser ();
        var genie_parser = new Vala.Genie.Parser ();
        var gir_parser = new Vala.GirParser ();

        // add all generated files before compiling
        foreach (File generated_file in _generated_sources) {
            // generated files are also part of the project, so we use TextDocument intead of Vala.SourceFile
            if (!generated_file.query_exists ())
                throw new FileError.NOENT (@"file does not exist");
            var generated_source_file = new TextDocument (_context, generated_file);
            _context.add_source_file (generated_source_file);
        }

        // add source file workers for all the other files and map their
        // contents
        foreach (var file in _context.get_source_files ()) {
            if (!(file is TextDocument)) {
                var worker = new SourceFileWorker (file);
                _all_sources.add (worker);
            }
            if (file.content == null)
                file.content = (string)file.get_mapped_contents ();
        }

        // update status of all project workers
        foreach (var worker in _project_sources.values)
            worker.update (SourceFileWorker.Status.NOT_PARSED);

        // acquire all workers for writing
        foreach (var worker in _all_sources)
            worker.acquire (cancellable);

        // parse everything at once
        vala_parser.parse (_context);
        genie_parser.parse (_context);
        gir_parser.parse (_context);

        // TODO: parallelize parser
        foreach (var worker in _all_sources)
            worker.update (SourceFileWorker.Status.PARSED);

        // then run the symbol analyzer
        var resolver = new Vala.SymbolResolver ();
        resolver.resolve (_context);
        foreach (var worker in _all_sources)
            worker.update (SourceFileWorker.Status.SYMBOLS_RESOLVED);


        // then run the semantic analyzer
        debug ("    begin semantic analysis for %s ...", id);
        _context.init_types ();
        var analyzer = new Vala.SemanticAnalyzer (_context);
        analyzer.analyze_root ();

        // release all the workers for writing
        foreach (var worker in _all_sources)
            worker.release (cancellable);
        int num_analyses = 0;
        foreach (var worker in _all_sources) {
            AtomicInt.inc (ref num_analyses);
            worker.run_symbols_resolved.begin<void> (() => {
                Vala.CodeContext.push (_context);
                worker.source_file.accept (new Vala.SemanticAnalyzer (_context));
                Vala.CodeContext.pop ();
                AtomicInt.dec_and_test (ref num_analyses);
            }, true, SourceFileWorker.Status.SEMANTICS_ANALYZED);
        }

        // wait for all the semantic analyses to be finished
        while (AtomicInt.get (ref num_analyses) > 0) {
            // TODO: a better way to handle this?
            cancellable.set_error_if_cancelled ();
            Thread.usleep (50000);              // wake up 20 times / second
        }
        debug ("    ... semantic analysis done");

        // update C name map for package files
        foreach (var worker in _all_sources) {
            if (worker.source_file.file_type == Vala.SourceFileType.PACKAGE) {
                worker.acquire (cancellable);
                worker.source_file.accept (new CNameMapper (cname_to_sym));
                worker.release (cancellable);
            }
        }

        // only run the flow analyzer and used checkers when we have no other
        // errors, otherwise we'll get spurious error messages
        if (reporter.get_errors () == 0) {
            num_analyses = 0;
            foreach (var worker in _all_sources) {
                AtomicInt.inc (ref num_analyses);
                worker.run_semantics_analyzed.begin<void> (() => {
                    Vala.CodeContext.push (_context);
                    worker.source_file.accept (new Vala.FlowAnalyzer (_context));
                    Vala.CodeContext.pop ();
                    AtomicInt.dec_and_test (ref num_analyses);
                }, true);
            }

            // wait for all the flow analyses to be finished
            while (AtomicInt.get (ref num_analyses) > 0) {
                // TODO: a better way to handle this?
                cancellable.set_error_if_cancelled ();
                Thread.usleep (50000);              // wake up 20 times / second
            }

            if (reporter.get_errors () == 0) {
                var used_attr = new Vala.UsedAttr ();
                used_attr.check_unused (_context);
            }
        }

        // generate output files
        // generate VAPI
        if (_output_vapi != null) {
            // create the directories if they don't exist
            DirUtils.create_with_parents (Path.get_dirname (_output_vapi), 0755);
            var interface_writer = new Vala.CodeWriter ();
            interface_writer.write_file (_context, _output_vapi);
        }

        // write output GIR
        if (_output_gir != null) {
            // TODO: output GIR (Vala.GIRWriter is private)
        }

        // write out internal VAPI
        if (_output_internal_vapi != null) {
            // create the directories if they don't exist
            DirUtils.create_with_parents (Path.get_dirname (_output_internal_vapi), 0755);
            var interface_writer = new Vala.CodeWriter (Vala.CodeWriterType.INTERNAL);
            interface_writer.write_file (_context, _output_internal_vapi);
        }

        // remove analyses for sources that are no longer a part of the code context
        var removed_sources = new HashSet<Vala.SourceFile> ();
        removed_sources.add_all (_source_analyzers.keys);
        foreach (var file in _context.get_source_files ()) {
            var text_document = file as TextDocument;
            if (text_document != null)
                text_document.last_fresh_content = text_document.content;
            removed_sources.remove (file);
        }
        foreach (var source in removed_sources)
            _source_analyzers.unset (source, null);

        // update analyses for all source files
        debug ("    begin remaining analyses for %s ...", id);
        num_analyses = 0;
        foreach (var worker in _all_sources) {
            var file = worker.source_file;
            var file_analyses = _source_analyzers[file];
            if (file_analyses == null) {
                file_analyses = new HashMap<Type, CodeAnalyzer> ();
                _source_analyzers[file] = file_analyses;
            }

            // compute code lenses (if we have to)
            CodeLensAnalyzer? code_lens_analyzer = null;
            if (file_analyses != null)
                code_lens_analyzer = file_analyses[typeof (CodeLensAnalyzer)] as CodeLensAnalyzer;
            if (code_lens_analyzer == null || !(file is TextDocument)
                || code_lens_analyzer.last_updated.compare (((TextDocument)file).last_updated) >= 0) {
                code_lens_analyzer = new CodeLensAnalyzer ();
                AtomicInt.inc (ref num_analyses);
                worker.run_semantics_analyzed.begin<void> (() => {
                    Vala.CodeContext.push (_context);
                    code_lens_analyzer.visit_source_file (file);
                    Vala.CodeContext.pop ();
                    AtomicInt.dec_and_test (ref num_analyses);
                }, false);
            }
            file_analyses[typeof (CodeLensAnalyzer)] = code_lens_analyzer;

            // analyze code style (if we have to)
            CodeStyleAnalyzer? code_analyzer = null;
            if (file_analyses != null)
                code_analyzer = file_analyses[typeof (CodeStyleAnalyzer)] as CodeStyleAnalyzer;
            if (code_analyzer == null || !(file is TextDocument)
                || code_analyzer.last_updated.compare (((TextDocument)file).last_updated) >= 0) {
                code_analyzer = new CodeStyleAnalyzer ();
                AtomicInt.inc (ref num_analyses);
                worker.run_semantics_analyzed.begin<void> (() => {
                    Vala.CodeContext.push (_context);
                    code_analyzer.visit_source_file (file);
                    Vala.CodeContext.pop ();
                    AtomicInt.dec_and_test (ref num_analyses);
                }, false);
            }
            file_analyses[typeof (CodeStyleAnalyzer)] = code_analyzer;

            // analyze document symbol outline
            SymbolEnumerator? symbol_enumerator = null;
            if (file_analyses != null)
                symbol_enumerator = file_analyses[typeof (SymbolEnumerator)] as SymbolEnumerator;
            if (symbol_enumerator == null || !(file is TextDocument)
                || symbol_enumerator.last_updated.compare (((TextDocument)file).last_updated) >= 0) {
                symbol_enumerator = new SymbolEnumerator ();
                AtomicInt.inc (ref num_analyses);
                worker.run_semantics_analyzed.begin<void> (() => {
                    Vala.CodeContext.push (_context);
                    symbol_enumerator.visit_source_file (file);
                    Vala.CodeContext.pop ();
                    AtomicInt.dec_and_test (ref num_analyses);
                }, false);
            }
            file_analyses[typeof (SymbolEnumerator)] = symbol_enumerator;
        }

        // wait for all the remaining analyses to be finished
        while (AtomicInt.get (ref num_analyses) > 0) {
            // TODO: a better way to handle this?
            cancellable.set_error_if_cancelled ();
            Thread.usleep (50000);              // wake up 20 times / second
        }

        debug ("    ... remaining analyses done");
        foreach (var worker in _project_sources.values)
            worker.update (SourceFileWorker.Status.COMPLETE);

        last_updated = new DateTime.now ();
        _completed_first_compile = true;
        debug ("finished compiling %s", id);
    }

    public override void build_if_stale (Cancellable? cancellable = null) throws Error {
        if (_project_sources.is_empty)
            // configure for first time
            configure (cancellable);

        bool stale = false;
        bool updated_file = false;

        foreach (Map.Entry<File, BuildTarget> dep in dependencies) {
            if (_file_cache[dep.key].last_updated.compare (last_updated) > 0) {
                stale = true;
                break;
            } else if (dep.value.last_updated.compare (last_updated) > 0) {
                // dep was updated but file is the same
                updated_file = true;
            }
        }
        foreach (SourceFileWorker worker in _project_sources.values) {
            var doc = (TextDocument)worker.source_file;
            if (doc.last_updated.compare (last_updated) > 0) {
                stale = true;
                break;
            }
        }
        if (stale || !_completed_first_compile) {
            configure (cancellable);
            Vala.CodeContext.push (_context);
            try {
                compile (cancellable);
            } catch (Error e) {
                Vala.CodeContext.pop ();
                throw e;        // rethrow
            }
            Vala.CodeContext.pop ();
        } else if (updated_file) {
            // even if the files are unchanged after updates, we need to
            // silently update the last_updated property of this target at the
            // very least, in order to maintain the invariant that a build
            // target is always "last updated" after its dependencies
            last_updated = new DateTime.now ();
        }

        // update all output files
        foreach (var file in output)
            _file_cache.update (file, cancellable);
    }

    /**
     * Get the analysis for the source file
     */
    public T? get_analysis_for_file<T> (Vala.SourceFile source) {
        var analyses = _source_analyzers[source];
        if (analyses == null)
            return null;
        return analyses[typeof (T)];
    }

    public Iterator<SourceFileWorker> iterator () {
        return _all_sources.iterator ();
    }
}
