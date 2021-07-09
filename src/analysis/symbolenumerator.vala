/* symbolenumerator.vala
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

using Lsp;

/**
 * Used to list all symbols defined in a document, usually for outlining.
 */
class Vls.SymbolEnumerator : Vala.CodeVisitor, CodeAnalyzer {
    private Vala.SourceFile file;
    private Gee.Deque<DocumentSymbol> containers;
    private Gee.List<DocumentSymbol> top_level_syms;
    private Gee.TreeMap<Range, DocumentSymbol> syms_flat;
    private Gee.List<DocumentSymbol> all_syms;
    private Gee.List<SymbolInformation>? all_sym_infos;
    private Gee.HashMap<string, DocumentSymbol> ns_name_to_dsym;
    Vala.TypeSymbol? str_sym; 
    string uri;

    public DateTime last_updated { get; set; }

    public SymbolEnumerator (Vala.SourceFile file) {
        this.file = file;
        this.top_level_syms = new Gee.LinkedList<DocumentSymbol> ();
        this.containers = new Gee.LinkedList<DocumentSymbol> ();
        this.syms_flat = new Gee.TreeMap<Range, DocumentSymbol> ();
        this.all_syms = new Gee.LinkedList<DocumentSymbol> ();
        this.ns_name_to_dsym = new Gee.HashMap<string, DocumentSymbol> ();

        try {
            uri = Filename.to_uri (file.filename);
        } catch (Error e) {
            warning ("%s is not a URI!", file.filename);
            return;
        }

        str_sym = file.context.root.scope.lookup ("string") as Vala.TypeSymbol;
        this.visit_source_file (file);
        str_sym = null;
    }

    public Gee.Iterator<DocumentSymbol> iterator () {
        return top_level_syms.iterator ();
    }

    public Gee.Iterable<SymbolInformation> flattened () {
        if (all_sym_infos == null) {
            all_sym_infos = new Gee.LinkedList<SymbolInformation> ();
            all_sym_infos.add_all_iterator (
                all_syms
                .map<SymbolInformation> (s => new SymbolInformation.from_document_symbol (s, uri)));
        }
        return all_sym_infos;
    }

    public DocumentSymbol? add_symbol (Vala.Symbol sym, SymbolKind kind, bool adding_parent = false) {
        var current_sym = (containers.is_empty || adding_parent) ? null : containers.peek_head ();
        DocumentSymbol? dsym;
        string sym_full_name = sym.get_full_name ();
        bool unique = true;

        if (sym is Vala.Namespace && ns_name_to_dsym.has_key (sym_full_name)) {
            dsym = ns_name_to_dsym [sym_full_name];
            unique = false;
        } else {
            dsym = new DocumentSymbol.from_vala_symbol (null, sym, kind);
        }

        // handle conflicts
        if (syms_flat.has_key (dsym.selectionRange)) {
            var existing_sym = syms_flat [dsym.selectionRange];
            // var dsym_name = dsym.kind == Constructor && dsym.name == null ? "(contruct block)" : (dsym.name ?? "(unknown)");
            // debug (@"found dup! $(existing_sym.name) ($(existing_sym.kind)) and $(dsym_name) ($(dsym.kind))");
            if (existing_sym.kind == dsym.kind)
                return existing_sym;
            else if (existing_sym.kind == Class && dsym.kind == Constructor)
                return existing_sym;
            else if (existing_sym.kind == Field && dsym.kind == Property) {
                existing_sym.name = dsym.name;
                existing_sym.detail = dsym.detail;
                existing_sym.kind = dsym.kind;
                return existing_sym;
            } else if (existing_sym.kind == Property && dsym.kind == Field)
                return existing_sym;
            else if (existing_sym.kind == Function && dsym.kind == Method)
                return existing_sym;
        }

        if (dsym.kind == Constructor) {
            if (current_sym != null && (current_sym.kind == Class || current_sym.kind == Struct)) {
                if (dsym.name == ".new")
                    dsym.name = current_sym.name;
                else {
                    if (dsym.name == null) {
                        var name_builder = new StringBuilder (current_sym.name);
                        name_builder.append (" (");
                        if (sym is Vala.Constructor) {
                            var ctor = (Vala.Constructor)sym;
                            if (ctor.binding == Vala.MemberBinding.CLASS)
                                name_builder.append ("class ");
                            else if (ctor.binding == Vala.MemberBinding.STATIC)
                                name_builder.append ("static ");
                        }
                        name_builder.append ("construct block)");
                        dsym.name = name_builder.str;
                    } else
                        dsym.name = @"$(current_sym.name).$(dsym.name)";
                }
            }
        }

        if (dsym.kind == Method || dsym.kind == Function) {
            if (dsym.name != null && /_lambda\d+_/.match (dsym.name))
                return null;
        }

        if (unique) {
            if (current_sym != null) {
                // debug (@"adding $(dsym.name) to current_sym $(current_sym.name)");
                current_sym.children.add (dsym);
            } else {
                if (sym.parent_symbol is Vala.Namespace 
                    && sym.parent_symbol.to_string () != "(root namespace)") {
                    DocumentSymbol parent_dsym;
                    if (!ns_name_to_dsym.has_key (sym.parent_symbol.get_full_name ())) {
                        parent_dsym = (!) add_symbol (sym.parent_symbol, SymbolKind.Namespace, true);
                    } else
                        parent_dsym = ns_name_to_dsym [sym.parent_symbol.get_full_name ()];
                    // debug (@"adding $(dsym.name) to $(parent_dsym.name)");
                    parent_dsym.children.add (dsym);
                } else {
                    // debug (@"adding $(dsym.name) to top_level_syms");
                    top_level_syms.add (dsym);
                }
            }


            if (sym is Vala.Namespace) {
                // debug (@"\tadding $(dsym.name) to ns_name_to_dsym");
                ns_name_to_dsym [sym_full_name] = dsym;
            }
            syms_flat [dsym.selectionRange] = dsym;
            all_syms.add (dsym);
        }

        return dsym;
    }

    public override void visit_source_file (Vala.SourceFile file) {
        file.accept_children (this);
    }

    public override void visit_addressof_expression (Vala.AddressofExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_array_creation_expression (Vala.ArrayCreationExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_assignment (Vala.Assignment a) {
        if (a.source_reference != null && a.source_reference.file != file) return;
        a.accept_children (this);
    }

    public override void visit_base_access (Vala.BaseAccess expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_binary_expression (Vala.BinaryExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_block (Vala.Block b) {
        if (b.source_reference != null && b.source_reference.file != file) return;
        b.accept_children (this);
    }

    public override void visit_boolean_literal (Vala.BooleanLiteral lit) {
        if (lit.source_reference != null && lit.source_reference.file != file) return;
        lit.accept_children (this);
    }

    public override void visit_break_statement (Vala.BreakStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_cast_expression (Vala.CastExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_catch_clause (Vala.CatchClause clause) {
        if (clause.source_reference != null && clause.source_reference.file != file) return;
        clause.accept_children (this);
    }

    public override void visit_character_literal (Vala.CharacterLiteral lit) {
        if (lit.source_reference != null && lit.source_reference.file != file) return;
        lit.accept_children (this);
    }

    public override void visit_class (Vala.Class cl) {
        if (cl.source_reference != null && cl.source_reference.file != file) return;
        var dsym = add_symbol (cl, Class);
        containers.offer_head (dsym);
        cl.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_conditional_expression (Vala.ConditionalExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_constant (Vala.Constant c) {
        if (c.source_reference != null && c.source_reference.file != file) return;
        if (!containers.is_empty) {
            var kind = containers.peek_head ().kind;
            if (kind == Method || kind == Function || kind == Constructor) return;
        }
        var skind = SymbolKind.Constant;

        if (c.type_reference.type_symbol != null) {
            if (str_sym != null && c.type_reference.type_symbol.is_subtype_of (str_sym))
                skind = SymbolKind.String;
            else if (c.type_reference.type_symbol.get_attribute ("IntegerType") != null ||
                    c.type_reference.type_symbol.get_attribute ("FloatingType") != null)
                skind = SymbolKind.Number;
            else if (c.type_reference.type_symbol.get_attribute ("BooleanType") != null)
                skind = SymbolKind.Boolean;
        }
        add_symbol (c, skind);
        c.accept_children (this);
    }

    public override void visit_constructor (Vala.Constructor c) {
        if (c.source_reference != null && c.source_reference.file != file) return;
        var dsym = add_symbol (c, Constructor);
        containers.offer_head (dsym);
        c.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_continue_statement (Vala.ContinueStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_creation_method (Vala.CreationMethod m) {
        if (m.source_reference != null && m.source_reference.file != file) return;
        add_symbol (m, Constructor);
        m.accept_children (this);
    }

    public override void visit_declaration_statement (Vala.DeclarationStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_delegate (Vala.Delegate cb) {
        if (cb.source_reference != null && cb.source_reference.file != file) return;
        add_symbol (cb, Interface);
        cb.accept_children (this);
    }

    public override void visit_delete_statement (Vala.DeleteStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_destructor (Vala.Destructor dtor) {
        if (dtor.source_reference != null && dtor.source_reference.file != file) return;
        var dsym = add_symbol (dtor, Method);
        if (!containers.is_empty) {
            var csym = containers.peek_head ();
            dsym.name = @"~$(csym.name)";
        }
        dtor.accept_children (this);
    }

    public override void visit_do_statement (Vala.DoStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_element_access (Vala.ElementAccess expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_empty_statement (Vala.EmptyStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_enum (Vala.Enum en) {
        if (en.source_reference != null && en.source_reference.file != file) return;
        var dsym = add_symbol (en, Enum);
        containers.offer_head (dsym);
        en.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_enum_value (Vala.EnumValue ev) {
        if (ev.source_reference != null && ev.source_reference.file != file) return;
        add_symbol (ev, EnumMember);
        ev.accept_children (this);
    }

    public override void visit_error_code (Vala.ErrorCode ecode) {
        if (ecode.source_reference != null && ecode.source_reference.file != file) return;
        add_symbol (ecode, EnumMember);
        ecode.accept_children (this);
    }

    public override void visit_error_domain (Vala.ErrorDomain edomain) {
        if (edomain.source_reference != null && edomain.source_reference.file != file) return;
        var dsym = add_symbol (edomain, Enum);
        containers.offer_head (dsym);
        edomain.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_expression_statement (Vala.ExpressionStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_field (Vala.Field f) {
        if (f.source_reference != null && f.source_reference.file != file) return;
        add_symbol (f, Field);
        f.accept_children (this);
    }

    public override void visit_for_statement (Vala.ForStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_foreach_statement (Vala.ForeachStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_if_statement (Vala.IfStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_initializer_list (Vala.InitializerList list) {
        if (list.source_reference != null && list.source_reference.file != file) return;
        list.accept_children (this);
    }

    public override void visit_integer_literal (Vala.IntegerLiteral lit) {
        if (lit.source_reference != null && lit.source_reference.file != file) return;
        lit.accept_children (this);
    }

    public override void visit_interface (Vala.Interface iface) {
        if (iface.source_reference != null && iface.source_reference.file != file) return;
        var dsym = add_symbol (iface, Interface);
        containers.offer_head (dsym);
        iface.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_lambda_expression (Vala.LambdaExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_local_variable (Vala.LocalVariable local) {
        if (local.source_reference != null && local.source_reference.file != file) return;
        local.accept_children (this);
    }

    public override void visit_lock_statement (Vala.LockStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

#if VALA_0_52
    public override void visit_loop_statement (Vala.LoopStatement stmt) {
#else
    public override void visit_loop (Vala.Loop stmt) {
#endif
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_member_access (Vala.MemberAccess expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_method (Vala.Method m) {
        if (m.source_reference != null && m.source_reference.file != file) return;
        if (!containers.is_empty) {
            var kind = containers.peek_head ().kind;
            if (kind == Method || kind == Function || kind == Constructor) return;
        }
        var dsym = add_symbol (m, containers.is_empty ? SymbolKind.Function : SymbolKind.Method);
        if (dsym != null)
            containers.offer_head (dsym);
        m.accept_children (this);
        if (dsym != null)
            containers.poll_head ();
    }

    public override void visit_method_call (Vala.MethodCall expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_namespace (Vala.Namespace ns) {
        if (ns.source_reference != null && ns.source_reference.file != file) return;
        var dsym = add_symbol (ns, Namespace);
        containers.offer_head (dsym);
        ns.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_null_literal (Vala.NullLiteral lit) {
        if (lit.source_reference != null && lit.source_reference.file != file) return;
        lit.accept_children (this);
    }

    public override void visit_object_creation_expression (Vala.ObjectCreationExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_pointer_indirection (Vala.PointerIndirection expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_postfix_expression (Vala.PostfixExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_property (Vala.Property prop) {
        if (prop.source_reference != null && prop.source_reference.file != file) return;
        var dsym = add_symbol (prop, Property);
        containers.offer_head (dsym);
        prop.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_real_literal (Vala.RealLiteral lit) {
        if (lit.source_reference != null && lit.source_reference.file != file) return;
        lit.accept_children (this);
    }

    public override void visit_reference_transfer_expression (Vala.ReferenceTransferExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_return_statement (Vala.ReturnStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_signal (Vala.Signal sig) {
        if (sig.source_reference != null && sig.source_reference.file != file) return;
        add_symbol (sig, Event);
        sig.accept_children (this);
    }

    public override void visit_sizeof_expression (Vala.SizeofExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_slice_expression (Vala.SliceExpression expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_string_literal (Vala.StringLiteral lit) {
        if (lit.source_reference != null && lit.source_reference.file != file) return;
        lit.accept_children (this);
    }

    public override void visit_struct (Vala.Struct st) {
        if (st.source_reference != null && st.source_reference.file != file) return;
        var dsym = add_symbol (st, Struct);
        containers.offer_head (dsym);
        st.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_switch_label (Vala.SwitchLabel label) {
        if (label.source_reference != null && label.source_reference.file != file) return;
        label.accept_children (this);
    }

    public override void visit_switch_section (Vala.SwitchSection section) {
        if (section.source_reference != null && section.source_reference.file != file) return;
        section.accept_children (this);
    }

    public override void visit_switch_statement (Vala.SwitchStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_throw_statement (Vala.ThrowStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_try_statement (Vala.TryStatement stmt) {
        if (stmt.source_reference != null && stmt.source_reference.file != file) return;
        stmt.accept_children (this);
    }

    public override void visit_type_check (Vala.TypeCheck expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }
}
