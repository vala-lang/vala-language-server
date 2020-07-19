using LanguageServer;

class Vls.FindSymbol : Vala.CodeVisitor {
    public Position? pos { get; private set; }
    private Position? end_pos;
    private Vala.SourceFile file;
    public bool search_multiline { get; private set; }
    public Gee.List<Vala.CodeNode> result = new Gee.ArrayList<Vala.CodeNode> ();
    private Gee.HashSet<Vala.CodeNode> seen = new Gee.HashSet<Vala.CodeNode> ();

    [CCode (has_target = false)]
    public delegate bool Filter (Vala.CodeNode needle, Vala.CodeNode hay_node);

    private Vala.CodeNode? needle;
    private Filter? filter;
    private bool include_declaration = true;

    private bool match (Vala.CodeNode node) {
        var sr = node.source_reference;
        if (sr == null) {
            // debug ("node %s has no source reference", node.type_name);
            return false;
        }

        if (sr.file != file) {
            return false;
        }

        if (sr.begin.line > sr.end.line) {
            warning (@"wtf vala: $(node.type_name): $sr");
            return false;
        }

        if (filter != null) {
            if (!include_declaration &&
                (needle == node && !(needle is Vala.LocalVariable) || node.parent_node is Vala.DeclarationStatement))
                return false;
            return filter (needle, node);
        }

        var range = new Range.from_sourceref (sr);

        if (!search_multiline) {
            if (range.start.line != range.end.line) {
                //  var from = (long)Server.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
                //  var to = (long)Server.get_string_pos (file.content, sr.end.line-1, sr.end.column);
                //  string contents = file.content [from:to];
                //  stderr.printf ("Multiline node: %s: %s", node.type_name, sr.to_string ());
                //  stderr.printf ("\n\t%s", contents.replace ("\n", " "));
                //  stderr.printf ("\n");

                return false;
            }

            if (range.start.line != pos.line) {
                return false;
            }
        } else if (node is Vala.Statement || node is Vala.LambdaExpression || node is Vala.CatchClause) {
            return false;       // we only want to find symbols, right?
        }

        if (range.contains (pos) && (end_pos == null || range.contains (end_pos))) {
            // debug ("Got node: %s (%s) @ %s", node.type_name, node.to_string (), sr.to_string ());
            return true;
        } else {
            return false;
        }
    }

    /*
     * TODO: are children of a CodeNode guaranteed to have a source_reference within the parent?
     * if so, this can be much faster
     */
    public FindSymbol (Vala.SourceFile file, Position pos,
                       bool search_multiline = false,
                       Position? end_pos = null) {
        this.pos = pos;
        this.end_pos = end_pos;
        this.file = file;
        this.search_multiline = search_multiline;
        this.visit_source_file (file);
    }

    public FindSymbol.with_filter (Vala.SourceFile file, Vala.CodeNode needle, Filter filter_func,
                                   bool include_declaration = true) {
        this.file = file;
        this.needle = needle;
        this.filter = filter_func;
        this.include_declaration = include_declaration;
        this.visit_source_file (file);
    }

    public override void visit_source_file (Vala.SourceFile file) {
        file.accept_children (this);
    }

    public override void visit_addressof_expression (Vala.AddressofExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_array_creation_expression (Vala.ArrayCreationExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_assignment (Vala.Assignment a) {
        if (seen.contains (a))
            return;
        seen.add (a);
        if (this.match (a))
            result.add (a);
        a.accept_children (this);
    }

    public override void visit_base_access (Vala.BaseAccess expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_binary_expression (Vala.BinaryExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_block (Vala.Block b) {
        if (seen.contains (b))
            return;
        seen.add (b);
        if (this.match (b))
            result.add (b);
        b.accept_children (this);
    }

    public override void visit_boolean_literal (Vala.BooleanLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_break_statement (Vala.BreakStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_cast_expression (Vala.CastExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_catch_clause (Vala.CatchClause clause) {
        if (seen.contains (clause))
            return;
        seen.add (clause);
        if (this.match (clause))
            result.add (clause);
        clause.accept_children (this);
    }

    public override void visit_character_literal (Vala.CharacterLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_class (Vala.Class cl) {
        if (seen.contains (cl))
            return;
        seen.add (cl);
        if (this.match (cl))
            result.add (cl);
        cl.accept_children (this);
    }

    public override void visit_conditional_expression (Vala.ConditionalExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_constant (Vala.Constant c) {
        if (seen.contains (c))
            return;
        seen.add (c);
        if (this.match (c))
            result.add (c);
        c.accept_children (this);
    }

    public override void visit_constructor (Vala.Constructor c) {
        if (seen.contains (c))
            return;
        seen.add (c);
        if (this.match (c))
            result.add (c);
        c.accept_children (this);
    }

    public override void visit_continue_statement (Vala.ContinueStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_creation_method (Vala.CreationMethod m) {
        if (seen.contains (m))
            return;
        seen.add (m);
        if (this.match (m))
            result.add (m);
        m.accept_children (this);
    }

    public override void visit_data_type (Vala.DataType type) {
        if (seen.contains (type))
            return;
        seen.add (type);
        if (this.match (type))
            result.add (type);
        type.accept_children (this);
    }

    public override void visit_declaration_statement (Vala.DeclarationStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_delegate (Vala.Delegate cb) {
        if (seen.contains (cb))
            return;
        seen.add (cb);
        if (this.match (cb))
            result.add (cb);
        cb.accept_children (this);
    }

    public override void visit_delete_statement (Vala.DeleteStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_destructor (Vala.Destructor dtor) {
        if (seen.contains (dtor))
            return;
        seen.add (dtor);
        if (this.match (dtor))
            result.add (dtor);
        dtor.accept_children (this);
    }

    public override void visit_do_statement (Vala.DoStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_element_access (Vala.ElementAccess expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_empty_statement (Vala.EmptyStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_enum (Vala.Enum en) {
        if (seen.contains (en))
            return;
        seen.add (en);
        if (this.match (en))
            result.add (en);
        en.accept_children (this);
    }

    public override void visit_enum_value (Vala.EnumValue ev) {
        if (seen.contains (ev))
            return;
        seen.add (ev);
        if (this.match (ev))
            result.add (ev);
        ev.accept_children (this);
    }

    public override void visit_error_code (Vala.ErrorCode ecode) {
        if (seen.contains (ecode))
            return;
        seen.add (ecode);
        if (this.match (ecode))
            result.add (ecode);
        ecode.accept_children (this);
    }

    public override void visit_error_domain (Vala.ErrorDomain edomain) {
        if (seen.contains (edomain))
            return;
        seen.add (edomain);
        if (this.match (edomain))
            result.add (edomain);
        edomain.accept_children (this);
    }

    /* note: do NOT implement visit_expression () without seen, since
     * this will, in most cases, be redundant and dramatically
     * slow down FindSymbol */
    public override void visit_expression (Vala.Expression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_expression_statement (Vala.ExpressionStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_field (Vala.Field f) {
        if (seen.contains (f))
            return;
        seen.add (f);
        if (this.match (f))
            result.add (f);
        f.accept_children (this);
    }

    public override void visit_for_statement (Vala.ForStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_foreach_statement (Vala.ForeachStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_formal_parameter (Vala.Parameter p) {
        if (seen.contains (p))
            return;
        seen.add (p);
        if (this.match (p))
            result.add (p);
        p.accept_children (this);
    }

    public override void visit_if_statement (Vala.IfStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_initializer_list (Vala.InitializerList list) {
        if (seen.contains (list))
            return;
        seen.add (list);
        if (this.match (list))
            result.add (list);
        list.accept_children (this);
    }

    public override void visit_integer_literal (Vala.IntegerLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_interface (Vala.Interface iface) {
        if (seen.contains (iface))
            return;
        seen.add (iface);
        if (this.match (iface))
            result.add (iface);
        iface.accept_children (this);
    }

    public override void visit_lambda_expression (Vala.LambdaExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_local_variable (Vala.LocalVariable local) {
        if (seen.contains (local))
            return;
        seen.add (local);
        if (this.match (local))
            result.add (local);
        local.accept_children (this);
    }

    public override void visit_lock_statement (Vala.LockStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_loop (Vala.Loop stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_member_access (Vala.MemberAccess expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_method (Vala.Method m) {
        if (seen.contains (m))
            return;
        seen.add (m);
        if (this.match (m))
            result.add (m);
        m.accept_children (this);
    }

    public override void visit_method_call (Vala.MethodCall expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_namespace (Vala.Namespace ns) {
        if (seen.contains (ns))
            return;
        seen.add (ns);
        if (this.match (ns))
            result.add (ns);
        ns.accept_children (this);
    }

    public override void visit_null_literal (Vala.NullLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_object_creation_expression (Vala.ObjectCreationExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_pointer_indirection (Vala.PointerIndirection expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_postfix_expression (Vala.PostfixExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_property (Vala.Property prop) {
        if (seen.contains (prop))
            return;
        seen.add (prop);
        if (this.match (prop))
            result.add (prop);
        prop.accept_children (this);
    }

    public override void visit_property_accessor (Vala.PropertyAccessor acc) {
        if (seen.contains (acc))
            return;
        seen.add (acc);
        if (this.match (acc))
            result.add (acc);
        acc.accept_children (this);
    }

    public override void visit_real_literal (Vala.RealLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_reference_transfer_expression (Vala.ReferenceTransferExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_regex_literal (Vala.RegexLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_return_statement (Vala.ReturnStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_signal (Vala.Signal sig) {
        if (seen.contains (sig))
            return;
        seen.add (sig);
        if (this.match (sig))
            result.add (sig);
        sig.accept_children (this);
    }

    public override void visit_sizeof_expression (Vala.SizeofExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_slice_expression (Vala.SliceExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_string_literal (Vala.StringLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (this.match (lit))
            result.add (lit);
        lit.accept_children (this);
    }

    public override void visit_struct (Vala.Struct st) {
        if (seen.contains (st))
            return;
        seen.add (st);
        if (this.match (st))
            result.add (st);
        st.accept_children (this);
    }

    public override void visit_switch_label (Vala.SwitchLabel label) {
        if (seen.contains (label))
            return;
        seen.add (label);
        if (this.match (label))
            result.add (label);
        label.accept_children (this);
    }

    public override void visit_switch_section (Vala.SwitchSection section) {
        if (seen.contains (section))
            return;
        seen.add (section);
        if (this.match (section))
            result.add (section);
        section.accept_children (this);
    }

    public override void visit_switch_statement (Vala.SwitchStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_template (Vala.Template tmpl) {
        if (seen.contains (tmpl))
            return;
        seen.add (tmpl);
        if (this.match (tmpl))
            result.add (tmpl);
        tmpl.accept_children (this);
    }

    public override void visit_throw_statement (Vala.ThrowStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_try_statement (Vala.TryStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (this.match (stmt))
            result.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_type_check (Vala.TypeCheck expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_type_parameter (Vala.TypeParameter p) {
        if (seen.contains (p))
            return;
        seen.add (p);
        if (this.match (p))
            result.add (p);
        p.accept_children (this);
    }

    public override void visit_typeof_expression (Vala.TypeofExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_unary_expression (Vala.UnaryExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (this.match (expr))
            result.add (expr);
        expr.accept_children (this);
    }

    public override void visit_unlock_statement (Vala.UnlockStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        stmt.accept_children (this);
    }

    public override void visit_using_directive (Vala.UsingDirective ud) {
        if (seen.contains (ud))
            return;
        seen.add (ud);
        if (this.match (ud))
            result.add (ud);
        ud.accept_children (this);
    }

    public override void visit_yield_statement (Vala.YieldStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        stmt.accept_children (this);
    }
}
