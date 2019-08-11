using LanguageServer;

class Vls.FindSymbol : Vala.CodeVisitor {
    private LanguageServer.Position pos;
    private Vala.SourceFile file;
    public Gee.List<Vala.CodeNode> result;

    bool match (Vala.CodeNode node) {
        var sr = node.source_reference;
        if (sr == null) {
            debug ("node %s has no source reference", node.type_name);
            return false;
        }

        if (sr.begin.line > sr.end.line) {
            warning (@"wtf vala: $(node.type_name): $sr");
            return false;
        }

        if (sr.begin.line != sr.end.line) {
            //  var from = (long)Server.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
            //  var to = (long)Server.get_string_pos (file.content, sr.end.line-1, sr.end.column);
            //  string contents = file.content [from:to];
            //  stderr.printf ("Multiline node: %s: %s", node.type_name, sr.to_string ());
            //  stderr.printf ("\n\t%s", contents.replace ("\n", " "));
            //  stderr.printf ("\n");

            return false;
        }

        if (sr.begin.line != pos.line) {
            return false;
        }
        if (sr.begin.column - 1 <= pos.character && pos.character <= sr.end.column) {
            debug ("Got node: %s (%s) @ %s", node.type_name, node.to_string (), sr.to_string ());
            return true;
        } else {
            return false;
        }
    }

    /*
     * TODO: are children of a CodeNode guaranteed to have a source_reference within the parent?
     * if so, this can be much faster
     */
    public FindSymbol (Vala.SourceFile file, LanguageServer.Position pos) {
        this.pos = pos;
        this.file = file;
        result = new Gee.ArrayList<Vala.CodeNode> ();
        this.visit_source_file (file);
    }

    public override void visit_source_file (Vala.SourceFile file) {
        file.accept_children (this);
    }

    public override void visit_addressof_expression (Vala.AddressofExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_array_creation_expression (Vala.ArrayCreationExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_assignment (Vala.Assignment a) {
        if (this.match (a))
            result.add (a);
        a.accept_children (this);
    }

    public override void visit_base_access (Vala.BaseAccess expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_binary_expression (Vala.BinaryExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_block (Vala.Block b) {
        b.accept_children (this);
    }

    public override void visit_boolean_literal (Vala.BooleanLiteral lit) {
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_break_statement (Vala.BreakStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_cast_expression (Vala.CastExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_catch_clause (Vala.CatchClause clause) {
        if (this.match (clause))
            result.add (clause);
        clause.accept_children (this);
    }

    public override void visit_character_literal (Vala.CharacterLiteral lit) {
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_class (Vala.Class cl) {
        if (this.match (cl))
            result.add (cl);
        cl.accept_children (this);
    }

    public override void visit_conditional_expression (Vala.ConditionalExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_constant (Vala.Constant c) {
        if (this.match (c))
            result.add (c);
        c.accept_children (this);
    }

    public override void visit_constructor (Vala.Constructor c) {
        if (this.match (c))
            result.add (c);
        c.accept_children (this);
    }

    public override void visit_continue_statement (Vala.ContinueStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_creation_method (Vala.CreationMethod m) {
        if (this.match (m))
            result.add (m);
        m.accept_children (this);
    }

    public override void visit_declaration_statement (Vala.DeclarationStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_delegate (Vala.Delegate cb) {
        if (this.match (cb))
            result.add (cb);
        cb.accept_children (this);
    }

    public override void visit_delete_statement (Vala.DeleteStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_do_statement (Vala.DoStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_element_access (Vala.ElementAccess expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_empty_statement (Vala.EmptyStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_enum (Vala.Enum en) {
        if (this.match (en))
            result.add (en);
        en.accept_children (this);
    }

    public override void visit_error_domain (Vala.ErrorDomain edomain) {
        if (this.match (edomain))
            result.add (edomain);
        edomain.accept_children (this);
    }

    public override void visit_expression_statement (Vala.ExpressionStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_field (Vala.Field f) {
        if (this.match (f))
            result.add (f);
        f.accept_children (this);
    }

    public override void visit_for_statement (Vala.ForStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_foreach_statement (Vala.ForeachStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_if_statement (Vala.IfStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_initializer_list (Vala.InitializerList list) {
        if (this.match (list))
            result.add (list);
        list.accept_children (this);
    }

    public override void visit_integer_literal (Vala.IntegerLiteral lit) {
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_interface (Vala.Interface iface) {
        if (this.match (iface))
            result.add (iface);
        iface.accept_children (this);
    }

    public override void visit_lambda_expression (Vala.LambdaExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_local_variable (Vala.LocalVariable local) {
        if (this.match (local))
            result.add (local);
        local.accept_children (this);
    }

    public override void visit_lock_statement (Vala.LockStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_loop (Vala.Loop stmt) {
        stmt.accept_children (this);
    }

    public override void visit_member_access (Vala.MemberAccess expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_method (Vala.Method m) {
        if (this.match (m))
            result.add (m);
        m.accept_children (this);
    }

    public override void visit_method_call (Vala.MethodCall expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_namespace (Vala.Namespace ns) {
        if (this.match (ns))
            result.add (ns);
        ns.accept_children (this);
    }

    public override void visit_null_literal (Vala.NullLiteral lit) {
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_object_creation_expression (Vala.ObjectCreationExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_pointer_indirection (Vala.PointerIndirection expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_postfix_expression (Vala.PostfixExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_property (Vala.Property prop) {
        if (this.match (prop))
            result.add (prop);
        prop.accept_children (this);
    }

    public override void visit_real_literal (Vala.RealLiteral lit) {
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_reference_transfer_expression (Vala.ReferenceTransferExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_return_statement (Vala.ReturnStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_signal (Vala.Signal sig) {
        if (this.match (sig))
            result.add (sig);
        sig.accept_children (this);
    }

    public override void visit_sizeof_expression (Vala.SizeofExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_slice_expression (Vala.SliceExpression expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_string_literal (Vala.StringLiteral lit) {
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_struct (Vala.Struct st) {
        if (this.match (st))
            result.add (st);
        st.accept_children (this);
    }

    public override void visit_switch_label (Vala.SwitchLabel label) {
        if (this.match (label))
            result.add (label);
        label.accept_children (this);
    }

    public override void visit_switch_section (Vala.SwitchSection section) {
        if (this.match (section))
            result.add (section);
        section.accept_children (this);
    }

    public override void visit_switch_statement (Vala.SwitchStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_throw_statement (Vala.ThrowStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_try_statement (Vala.TryStatement stmt) {
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_type_check (Vala.TypeCheck expr) {
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }
}

class Vls.ListSymbols : Vala.CodeVisitor {
    private Vala.SourceFile file;
    private Gee.Deque<DocumentSymbol> containers;
    private Gee.List<DocumentSymbol> top_level_syms;
    private Gee.TreeMap<Range, DocumentSymbol> syms_flat;
    private Gee.List<DocumentSymbol> all_syms;

    public ListSymbols (Vala.SourceFile file) {
        this.file = file;
        this.top_level_syms = new Gee.LinkedList<DocumentSymbol> ();
        this.containers = new Gee.LinkedList<DocumentSymbol> ();
        this.syms_flat = new Gee.TreeMap<Range, DocumentSymbol> ((r1, r2) => r1.start.compare (r2.start));
        this.all_syms = new Gee.LinkedList<DocumentSymbol> ();
        this.visit_source_file (file);
    }

    public Gee.Iterator<DocumentSymbol> iterator () {
        return top_level_syms.iterator ();
    }

    public Gee.Iterable<DocumentSymbol> flattened () {
        return all_syms;
    }

    public DocumentSymbol? add_symbol (Vala.Symbol sym, SymbolKind kind) {
        var current_sym = containers.is_empty ? null : containers.peek_head ();
        var dsym = new DocumentSymbol.from_vala_symbol (sym, kind);

        // handle conflicts
        if (syms_flat.has_key (dsym.range)) {
            var existing_sym = syms_flat [dsym.range];
            debug (@"found dup! $(existing_sym.name) and $(dsym.name)");
            if (existing_sym.kind == dsym.kind)
                return existing_sym;
            else if (existing_sym.kind == Class && dsym.kind == Constructor)
                return existing_sym;
            else if (existing_sym.kind == Field && dsym.kind == Property) {
                existing_sym.name = dsym.name;
                existing_sym.kind = dsym.kind;
                return existing_sym;
            } else if (existing_sym.kind == Property && dsym.kind == Field)
                return existing_sym;
        }

        if (dsym.kind == Constructor) {
            if (current_sym != null && (current_sym.kind == Class || current_sym.kind == Struct)) {
                if (dsym.name == ".new")
                    dsym.name = current_sym.name;
                else {
                    if (dsym.name == null)
                        dsym.name = @"$(current_sym.name) (construct block)";
                    else
                        dsym.name = @"$(current_sym.name).$(dsym.name)";
                }
            }
        }
        
        if (dsym.kind == Method || dsym.kind == Function) {
            if (/_lambda\d+_/.match (dsym.name))
                return null;
        }

        if (current_sym != null)
            current_sym.children.add (dsym);
        else
            top_level_syms.add (dsym);
        syms_flat [dsym.range] = dsym;
        all_syms.add (dsym);
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
        add_symbol (c, Constant);
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

    public override void visit_error_domain (Vala.ErrorDomain edomain) {
        if (edomain.source_reference != null && edomain.source_reference.file != file) return;
        add_symbol (edomain, Enum);
        edomain.accept_children (this);
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

    public override void visit_loop (Vala.Loop stmt) {
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
        containers.offer_head (dsym);
        m.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_method_call (Vala.MethodCall expr) {
        if (expr.source_reference != null && expr.source_reference.file != file) return;
        expr.accept_children (this);
    }

    public override void visit_namespace (Vala.Namespace ns) {
        if (ns.source_reference != null && ns.source_reference.file != file) return;
        ns.accept_children (this);
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
