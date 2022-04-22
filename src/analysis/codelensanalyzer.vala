/* codelensanalyzer.vala
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

/**
 * Collects only those symbols of interest to the code lens. Currently these are:
 * 
 * * methods and properties that override or implement a base symbol
 * * abstract and virtual methods and properties that are overridden
 * * methods and properties that hide a base symbol
 */
class Vls.CodeLensAnalyzer : Vala.CodeVisitor, CodeAnalyzer {
    public DateTime last_updated { get; set; }

    /**
     * Collection of methods/properties that override a base symbol.
     *
     * Maps a symbol to the base symbol it overrides.
     */
    HashMap<Vala.Symbol, Vala.Symbol>? _found_overrides;

    /**
     * Collection of methods/properties that implement a base symbol.
     *
     * Maps a symbol to the abstract symbol it implements.
     */
    HashMap<Vala.Symbol, Vala.Symbol>? _found_implementations;

    /**
     * Collection of methods/properties that hide a base symbol.
     *
     * Maps a symbol to the symbol it hides.
     */
    HashMap<Vala.Symbol, Vala.Symbol>? _found_hides;

    ArrayList<CodeLens> _lenses;

    private Vala.SourceFile? file;

    public Iterator<CodeLens> iterator () {
        return _lenses.iterator ();
    }

    public override void visit_source_file (Vala.SourceFile file) {
        this.file = file;
        _found_overrides = new HashMap<Vala.Symbol, Vala.Symbol> ();
        _found_implementations = new HashMap<Vala.Symbol, Vala.Symbol> ();
        _found_hides = new HashMap<Vala.Symbol, Vala.Symbol> ();
        this.file.accept_children (this);

        _lenses = new ArrayList<CodeLens> ();
        _lenses.add_all_iterator (
            _found_overrides
            .map<CodeLens> (entry =>
                            new CodeLens () {
                                range = new Range.from_sourceref (entry.key.source_reference),
                                command = new Lsp.Command () {
                                    title = "overrides " + CodeLensEngine.represent_symbol (entry.key, entry.value),
                                    command = Command.EDITOR_SHOW_BASE_SYMBOL.to_string (),
                                    arguments = CodeLensEngine.create_arguments (entry.key, entry.value)
                                }
                            }));

        _lenses.add_all_iterator (
            _found_implementations
            .map<CodeLens> (entry =>
                            new CodeLens () {
                                range = new Range.from_sourceref (entry.key.source_reference),
                                command = new Lsp.Command () {
                                    title = "implements " + CodeLensEngine.represent_symbol (entry.key, entry.value),
                                    command = Command.EDITOR_SHOW_BASE_SYMBOL.to_string (),
                                    arguments = CodeLensEngine.create_arguments (entry.key, entry.value)
                                }
                            }));

        _lenses.add_all_iterator (
            _found_hides
            .map<CodeLens> (entry =>
                            new CodeLens () {
                                range = new Range.from_sourceref (entry.key.source_reference),
                                command = new Lsp.Command () {
                                    title = "hides " + CodeLensEngine.represent_symbol (entry.key, entry.value),
                                    command = Command.EDITOR_SHOW_HIDDEN_SYMBOL.to_string (),
                                    arguments = CodeLensEngine.create_arguments (entry.key, entry.value)
                                }
                            }));

        this.file = null;
        _found_overrides = null;
        _found_implementations = null;
        _found_hides = null;
        last_updated = new DateTime.now ();
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
                _found_overrides[m] = m.base_interface_method;
            else
                _found_implementations[m] = m.base_interface_method;
        } else if (m.base_method != null && m.base_method != m) {
            if (CodeHelp.base_method_requires_override (m.base_method))
                _found_overrides[m] = m.base_method;
            else
                _found_implementations[m] = m.base_method;
        }

        var hidden_member = m.get_hidden_member ();
        if (m.hides && hidden_member != null)
            _found_hides[m] = hidden_member;
    }

    public override void visit_property (Vala.Property prop) {
        if (prop.source_reference.file != file)
            return;

        if (prop.base_interface_property != null && prop.base_interface_property != prop) {
            if (CodeHelp.base_property_requires_override (prop.base_interface_property))
                _found_overrides[prop] = prop.base_interface_property;
            else
                _found_implementations[prop] = prop.base_interface_property;
        } else if (prop.base_property != null && prop.base_property != prop) {
            if (CodeHelp.base_property_requires_override (prop.base_property))
                _found_overrides[prop] = prop.base_property;
            else
                _found_implementations[prop] = prop.base_property;
        }

        var hidden_member = prop.get_hidden_member ();
        if (prop.hides && hidden_member != null)
            _found_hides[prop] = hidden_member;
    }
}
