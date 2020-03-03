using Gee;

/**
 * Represents a Meson build target.
 */
class Vls.MesonTarget : BuildTarget {
    public MesonTarget (Meson.TargetInfo meson_target_info, string build_dir) 
                        throws ConvertError, FileError {
        base (meson_target_info.defined_in, meson_target_info.id, build_dir);
        produced_files = new ArrayList<string>.wrap (meson_target_info.filename);

        foreach (var target_source in meson_target_info.target_sources) {
            bool experimental = false;
            bool experimental_non_null = false;
            Vala.Profile profile = Vala.Profile.GOBJECT;
            bool abi_stability = false;
            var args = new HashMap<string, ArrayList<string>> ();
            var files_from_args = new HashSet<string> ();
            bool ignore_next_arg = false;

            // get all flags
            for (int i=0; i<target_source.parameters.length; i++) {
                string param = target_source.parameters[i];
                if (/^--\w*[\w-]*\w+$/.match (param)) {
                    if (param == "--pkg" || param == "--vapidir" ||
                        param == "--girdir" || param == "--metadatadir" ||
                        param == "--gresourcesdir" || param == "--define") {
                        if (i+1 < target_source.parameters.length) {
                            // the next argument is the value
                            if (!args.has_key (param))
                                args[param] = new ArrayList<string> ();
                            args[param].add (target_source.parameters[i+1]);
                            i++;
                        }
                    } else if (param == "--experimental") {
                        experimental = true;
                    } else if (param == "--experimental-non-null") {
                        experimental_non_null = true;
                    } else if (param == "--profile") {
                        if (i+1 < target_source.parameters.length) {
                            // the next argument is the value
                            string profile_str = target_source.parameters[i+1];
                            if (profile_str == "posix")
                                profile = Vala.Profile.POSIX;
                            i++;
                        }
                    } else if (param.has_prefix ("-D")) {
                        if (param == "-D") {
                            if (i+1 < target_source.parameters.length) {
                                // the next argument is the value
                                if (!args.has_key ("--define"))
                                    args["--define"] = new ArrayList<string> ();
                                args["--define"].add (target_source.parameters[i+1]);
                                i++;
                            }
                        } else {
                            if (!args.has_key ("--define"))
                                args["--define"] = new ArrayList<string> ();
                            args["--define"].add (param.substring (2));
                        }
                    } else if (param == "--abi-stability") {
                        abi_stability = true;
                    } else {
                        if (param == "--vapi" || param == "--internal-vapi"
                         || param == "--gir") {
                            ignore_next_arg = true;
                        }
                        debug (@"MesonTarget: ignoring flag `$param'");
                    }
                } else if (!ignore_next_arg) {
                    int idx = param.index_of ("=");
                    if (idx != -1) {
                        // --[param_name]={value}
                        string param_name = param[0:idx];
                        if (!args.has_key (param_name))
                            args[param_name] = new ArrayList<string> ();
                        args[param_name].add (param.substring (idx+1));
                    } else if (param.has_suffix (".vapi") || param.has_suffix (".gir")) {
                        // TODO: recognize basedir
                        files_from_args.add (param);
                    } else {
                        debug (@"MesonTarget: ignoring argument `$param'");
                    }
                } else {
                    ignore_next_arg = false;
                    debug (@"MesonTarget: ignoring argument `$param' because of previous argument");
                }
            }

            var compilation = new Compilation (this, experimental,
                    experimental_non_null,
                    profile, abi_stability,
                    args["--pkg"],
                    args["--vapidir"],
                    args["--girdir"],
                    args["--metadatadir"],
                    args["--gresourcesdir"],
                    args["--define"]);

            // add source files to compilation
            foreach (string source in files_from_args) {
                debug (@"MesonTarget: adding source file `$source' from args");
                compilation.add_source_file (source);
            }

            foreach (string source in target_source.sources) {
                if (!Path.is_absolute (source))
                    source = Path.build_filename (build_dir, source);
                debug (@"MesonTarget: adding source file `$source'");
                compilation.add_source_file (source);
            }

            // if we succeeded, add the compilation to our target
            debug (@"MesonTarget: adding compilation");
            compilations.add (compilation);
        }
    }

    public override string to_string () {
        return @"MesonTarget($id @ $script_uri)";
    }
}

namespace Meson {
    class TargetSourceInfo : Object {
        // we don't care about language since we only support Vala target sources
        public string[] compiler { get; set; }
        public string[] parameters { get; set; }
        public string[] sources { get; set; }
    }

    class TargetInfo : Object, Json.Serializable {
        public string name { get; set; }
        public string id { get; set; }
        public string defined_in { get; set; }
        public string[] filename { get; set; }
        public ArrayList<TargetSourceInfo> target_sources { get; set; }

        public new void Json.Serializable.set_property (ParamSpec pspec, Value value) {
            base.set_property (pspec.get_name (), value);
        }

        public new Value Json.Serializable.get_property (ParamSpec pspec) {
            Value val = Value(pspec.value_type);
            base.get_property (pspec.get_name (), ref val);
            return val;
        }

        public unowned ParamSpec? find_property (string name) {
            return this.get_class ().find_property (name);
        }

        public Json.Node serialize_property (string property_name, Value value, ParamSpec pspec) {
            error ("MesonTarget: serialization not supported");
        }

        public bool deserialize_property (string property_name, out Value val, ParamSpec pspec, Json.Node property_node) {
            if (property_name == "name" ||
                property_name == "id" ||
                property_name == "defined-in") {
                val = Value (typeof (string));
                val.set_string (property_node.get_string ());
                return true;
            } else if (property_name == "filename") {
                val = Value (typeof (string[]));
                var array = new string [property_node.get_array ().get_length ()];
                property_node.get_array ().foreach_element ((json_array, i, node) => {
                    array[i] = node.get_string ();
                });
                val.set_boxed (new string[] {"hello"});
                return true;
            } else if (property_name == "target-sources") {
                target_sources = new ArrayList<TargetSourceInfo> ();
                property_node.get_array ().foreach_element ((_1, _2, node) => {
                    Json.Node? language_property = node.get_object ().get_member ("language");
                    if (language_property == null || 
                        language_property.get_string () != "vala")
                        return;
                    var tsi = Json.gobject_deserialize (typeof (Meson.TargetSourceInfo), node) as Meson.TargetSourceInfo;
                    assert (tsi != null);
                    target_sources.add (tsi);
                });
                val = Value (target_sources.get_type ());
                val.set_object (target_sources);
                return true;
            }
            val = Value (pspec.value_type);
            return false;
        }
    }
}
