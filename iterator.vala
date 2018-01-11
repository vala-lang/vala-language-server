class Vls.FindSymbol : Vala.CodeVisitor {
    private LanguageServer.Position pos;
    private Vala.SourceFile file;
    public Gee.List<Vala.CodeNode> result;

    bool match (Vala.CodeNode node) {
        var sr = node.source_reference;
        if (sr == null) {
            stderr.printf ("node %s has no source reference\n", node.type_name);
            return false;
        }

        if (sr.begin.line > sr.end.line) {
            stderr.printf (@"wtf vala: $(node.type_name): $sr\n");
            return false;
        }

        if (sr.begin.line != sr.end.line) {
            var from = (long)Server.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
            var to = (long)Server.get_string_pos (file.content, sr.end.line-1, sr.end.column);
            string contents = file.content [from:to];
            stderr.printf ("Multiline node: %s: %s", node.type_name, sr.to_string ());
            stderr.printf ("\n\t%s", contents.replace ("\n", " "));
            stderr.printf ("\n");

            return false;
        }

        if (sr.begin.line != pos.line) {
            stderr.printf ("%s @ %s not on line %u\n", node.type_name, sr.to_string (), pos.line);
            return false;
        }
        if (sr.begin.column <= pos.character && pos.character <= sr.end.column) {
            stderr.printf ("Got node: %s @ %s\n", node.type_name, sr.to_string ());
            return true;
        } else {
            stderr.printf ("%s @ %s not around char %u\n", node.type_name, sr.to_string (), pos.character);
            return false;
        }
    }

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