using Gee;

namespace Vls {
    class CompileCommand : Object, Json.Serializable {
        public string directory { get; set; }
        public string[] command { get; set; }
        public string file { get; set; }
        public string output { get; set; }

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
            if (property_name == "directory" ||
                property_name == "file" ||
                property_name == "output") {
                val = Value (typeof (string));
                val.set_string (property_node.get_string ());
                return true;
            } else if (property_name == "command") {
                val = Value (typeof (string[]));
                string[] command_array = {};
                try {
                    command_array = get_arguments_from_command_str (property_node.get_string ());
                } catch (RegexError e) {
                    warning ("failed to parse `%s': %s", property_node.get_string (), e.message);
                }
                val.set_boxed (command_array);
                return true;
            }
            val = Value (pspec.value_type);
            return false;
        }
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
