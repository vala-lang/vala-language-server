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
