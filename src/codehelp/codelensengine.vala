/* codelensengine.vala
 *
 * Copyright 2021 Princeton Ferro <princetonferro@gmail.com>
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
using Lsp;

enum Vls.Command {
    /**
     * The editor should display the base symbol of a method or property.
     */
    EDITOR_SHOW_BASE_SYMBOL,

    /**
     * The editor should display the symbol hidden by the current symbol.
     */
    EDITOR_SHOW_HIDDEN_SYMBOL;

    public unowned string to_string () {
        switch (this) {
            case EDITOR_SHOW_BASE_SYMBOL:
                return "vala.showBaseSymbol";
            case EDITOR_SHOW_HIDDEN_SYMBOL:
                return "vala.showHiddenSymbol";
        }
        assert_not_reached ();
    }
}

namespace Vls.CodeLensEngine {
    /**
     * Collects only those symbols of interest to the code lens. Currently these are:
     * 
     * * methods and properties that override or implement a base symbol
     * * abstract and virtual methods and properties that are overridden
     * * methods and properties that hide a base symbol
     */
    class SymbolCollector : Vala.CodeVisitor {
        /**
         * Collection of methods/properties that override a base symbol.
         *
         * Maps a symbol to the base symbol it overrides.
         */
        public HashMap<Vala.Symbol, Vala.Symbol> found_overrides { get; private set; }

        /**
         * Collection of methods/properties that implement a base symbol.
         *
         * Maps a symbol to the abstract symbol it implements.
         */
        public HashMap<Vala.Symbol, Vala.Symbol> found_implementations { get; private set; }

        /**
         * Collection of methods/properties that hide a base symbol.
         *
         * Maps a symbol to the symbol it hides.
         */
        public HashMap<Vala.Symbol, Vala.Symbol> found_hides { get; private set; }

        private Vala.SourceFile file;

        public SymbolCollector (Vala.SourceFile file) {
            this.file = file;
            this.found_overrides = new HashMap<Vala.Symbol, Vala.Symbol> ();
            this.found_implementations = new HashMap<Vala.Symbol, Vala.Symbol> ();
            this.found_hides = new HashMap<Vala.Symbol, Vala.Symbol> ();
            visit_source_file (file);
        }

        public override void visit_source_file (Vala.SourceFile file) {
            file.accept_children (this);
        }

        public override void visit_namespace (Vala.Namespace ns) {
            ns.accept_children (this);
        }

        public override void visit_class (Vala.Class cl) {
            if (cl.source_reference.file != null && cl.source_reference.file != file)
                return;
            cl.accept_children (this);
        }

        public override void visit_interface (Vala.Interface iface) {
            if (iface.source_reference.file != null && iface.source_reference.file != file)
                return;
            iface.accept_children (this);
        }

        public override void visit_struct (Vala.Struct st) {
            if (st.source_reference.file != null && st.source_reference.file != file)
                return;
            st.accept_children (this);
        }

        public override void visit_method (Vala.Method m) {
            if (m.source_reference.file != file)
                return;

            if (m.base_interface_method != null && m.base_interface_method != m) {
                if (CodeHelp.base_method_requires_override (m.base_interface_method))
                    found_overrides[m] = m.base_interface_method;
                else
                    found_implementations[m] = m.base_interface_method;
            } else if (m.base_method != null && m.base_method != m) {
                if (CodeHelp.base_method_requires_override (m.base_method))
                    found_overrides[m] = m.base_method;
                else
                    found_implementations[m] = m.base_method;
            }

            var hidden_member = m.get_hidden_member ();
            if (m.hides && hidden_member != null)
                found_hides[m] = hidden_member;
        }

        public override void visit_property (Vala.Property prop) {
            if (prop.source_reference.file != file)
                return;

            if (prop.base_interface_property != null && prop.base_interface_property != prop) {
                if (CodeHelp.base_property_requires_override (prop.base_interface_property))
                    found_overrides[prop] = prop.base_interface_property;
                else
                    found_implementations[prop] = prop.base_interface_property;
            } else if (prop.base_property != null && prop.base_property != prop) {
                if (CodeHelp.base_property_requires_override (prop.base_property))
                    found_overrides[prop] = prop.base_property;
                else
                    found_implementations[prop] = prop.base_property;
            }

            var hidden_member = prop.get_hidden_member ();
            if (prop.hides && hidden_member != null)
                found_hides[prop] = hidden_member;
        }
    }

    /**
     * Represent the symbol in a special way for code lenses:
     * `{parent with type parameters}.{symbol_name}`
     * 
     * We don't care to show modifiers, return types, and/or parameters.
     */
    string represent_symbol (Vala.Symbol current_symbol, Vala.Symbol target_symbol) {
        var builder = new StringBuilder ();

        if (current_symbol.parent_symbol is Vala.TypeSymbol) {
            Vala.DataType? target_symbol_parent_type = null;
            var ancestor_types = new GLib.Queue<Vala.DataType> ();
            ancestor_types.push_tail (Vala.SemanticAnalyzer.get_data_type_for_symbol (current_symbol.parent_symbol));

            while (target_symbol_parent_type == null && !ancestor_types.is_empty ()) {
                var parent_type = ancestor_types.pop_head ();
                if (parent_type.type_symbol is Vala.Class) {
                    foreach (var base_type in ((Vala.Class)parent_type.type_symbol).get_base_types ()) {
                        var actual_base_type = base_type.get_actual_type (parent_type, null, null);
                        if (base_type.type_symbol == target_symbol.parent_symbol) {
                            target_symbol_parent_type = actual_base_type;
                            break;
                        }
                        ancestor_types.push_tail (actual_base_type);
                    }
                } else if (parent_type.type_symbol is Vala.Interface) {
                    foreach (var base_type in ((Vala.Interface)parent_type.type_symbol).get_prerequisites ()) {
                        var actual_base_type = base_type.get_actual_type (parent_type, null, null);
                        if (base_type.type_symbol == target_symbol.parent_symbol) {
                            target_symbol_parent_type = actual_base_type;
                            break;
                        }
                        ancestor_types.push_tail (actual_base_type);
                    }
                } else if (parent_type.type_symbol is Vala.Struct) {
                    var base_type = ((Vala.Struct)parent_type.type_symbol).base_type;
                    var actual_base_type = base_type.get_actual_type (parent_type, null, null);
                    if (base_type.type_symbol == target_symbol.parent_symbol) {
                        target_symbol_parent_type = actual_base_type;
                        break;
                    }
                    ancestor_types.push_tail (actual_base_type);
                }
            }

            builder.append (CodeHelp.get_symbol_representation (
                    target_symbol_parent_type,
                    target_symbol.parent_symbol,
                    current_symbol.scope,
                    true,
                    null,
                    null,
                    false,
                    true));

            builder.append_c ('.');
        }

        builder.append (target_symbol.name);
        if (target_symbol is Vala.Callable)
            builder.append ("()");
        return builder.str;
    }

    Array<Variant> create_arguments (Vala.Symbol current_symbol, Vala.Symbol target_symbol) {
        var arguments = new Array<Variant> ();

        try {
            arguments.append_val (Util.object_to_variant (new Location.from_sourceref (current_symbol.source_reference)));
            arguments.append_val (Util.object_to_variant (new Location.from_sourceref (target_symbol.source_reference)));
        } catch (Error e) {
            warning ("failed to create arguments for command: %s", e.message);
        }

        return arguments;
    }

    void begin_response (Server lang_serv, Project project,
                         Jsonrpc.Client client, Variant id, string method,
                         Vala.SourceFile doc, Compilation compilation) {
        lang_serv.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);
            var collected_symbols = new SymbolCollector (doc);
            Vala.CodeContext.pop ();

            var lenses = new ArrayList<CodeLens> ();

            lenses.add_all_iterator (
                collected_symbols.found_overrides
                .map<CodeLens> (entry =>
                                new CodeLens () {
                                    range = new Range.from_sourceref (entry.key.source_reference),
                                    command = new Lsp.Command () {
                                        title = "overrides " + represent_symbol (entry.key, entry.value),
                                        command = Command.EDITOR_SHOW_BASE_SYMBOL.to_string (),
                                        arguments = create_arguments (entry.key, entry.value)
                                    }
                                }));

            lenses.add_all_iterator (
                collected_symbols.found_implementations
                .map<CodeLens> (entry =>
                                new CodeLens () {
                                    range = new Range.from_sourceref (entry.key.source_reference),
                                    command = new Lsp.Command () {
                                        title = "implements " + represent_symbol (entry.key, entry.value),
                                        command = Command.EDITOR_SHOW_BASE_SYMBOL.to_string (),
                                        arguments = create_arguments (entry.key, entry.value)
                                    }
                                }));

            lenses.add_all_iterator (
                collected_symbols.found_hides
                .map<CodeLens> (entry =>
                                new CodeLens () {
                                    range = new Range.from_sourceref (entry.key.source_reference),
                                    command = new Lsp.Command () {
                                        title = "hides " + represent_symbol (entry.key, entry.value),
                                        command = Command.EDITOR_SHOW_HIDDEN_SYMBOL.to_string (),
                                        arguments = create_arguments (entry.key, entry.value)
                                    }
                                }));

            finish (client, id, method, lenses);
        });
    }

    void finish (Jsonrpc.Client client, Variant id, string method, Collection<CodeLens> lenses) {
        try {
            var json_array = new Json.Array ();

            foreach (var lens in lenses)
                json_array.add_element (Json.gobject_serialize (lens));

            Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
            client.reply (id, variant_array, Server.cancellable);
        } catch (Error e) {
            warning ("[%s] failed to reply to client: %s", method, e.message);
        }
    }
}
