/* cnamemapper.vala
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

/**
 * Visits the symbols in a file and maps their C name. This is used by the
 * documentation engine to equalize references to symbols in VAPIs with 
 * references to symbols in corresponding GIRs. It is also used to map
 * references to C names in documentation text to references to symbols
 * in VAPIs.
 *
 * @see Vls.CodeHelp.get_symbol_cname
 */
class Vls.CNameMapper : Vala.CodeVisitor {
    private Gee.HashMap<string, Vala.Symbol> cname_to_sym;

    public CNameMapper (Gee.HashMap<string, Vala.Symbol> cname_to_sym) {
        this.cname_to_sym = cname_to_sym;
    }

    private void map_cname (Vala.Symbol sym) {
        string cname = CodeHelp.get_symbol_cname (sym);
        // debug ("mapping C name %s -> symbol %s (%s)", cname, sym.get_full_name (), sym.type_name);
        if (!cname_to_sym.has_key (cname)) {
            cname_to_sym[cname] = sym;
            if (sym is Vala.ErrorDomain || sym is Vala.Enum) {
                // also map its C prefix (without the trailing underscore)
                string? cprefix = sym.get_attribute_string ("CCode", "cprefix");
                MatchInfo match_info = null;
                if (cprefix != null && /^([A-Z]+(_[A-Z]+)*)_$/.match (cprefix, 0, out match_info)) {
                    cname_to_sym[match_info.fetch (1)] = sym;
                }
            }
        }
    }

    public override void visit_source_file (Vala.SourceFile source_file) {
        source_file.accept_children (this);
    }

    public override void visit_class (Vala.Class cl) {
        map_cname (cl);
        cl.accept_children (this);
    }

    public override void visit_constant (Vala.Constant c) {
        map_cname (c);
    }

    public override void visit_creation_method (Vala.CreationMethod m) {
        map_cname (m);
    }

    public override void visit_delegate (Vala.Delegate d) {
        map_cname (d);
    }

    public override void visit_enum (Vala.Enum en) {
        map_cname (en);
        en.accept_children (this);
    }

    public override void visit_enum_value (Vala.EnumValue ev) {
        map_cname (ev);
    }

    public override void visit_error_domain (Vala.ErrorDomain edomain) {
        map_cname (edomain);
        edomain.accept_children (this);
    }

    public override void visit_error_code (Vala.ErrorCode ecode) {
        map_cname (ecode);
    }

    public override void visit_field (Vala.Field f) {
        map_cname (f);
    }

    public override void visit_interface (Vala.Interface iface) {
        map_cname (iface);
        iface.accept_children (this);
    }

    public override void visit_method (Vala.Method m) {
        map_cname (m);
    }

    public override void visit_namespace (Vala.Namespace ns) {
        map_cname (ns);
        ns.accept_children (this);
    }

    public override void visit_property (Vala.Property prop) {
        map_cname (prop);
    }

    public override void visit_signal (Vala.Signal sig) {
        map_cname (sig);
    }

    public override void visit_struct (Vala.Struct st) {
        map_cname (st);
        st.accept_children (this);
    }
}
