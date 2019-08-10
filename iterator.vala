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
    private Gee.Deque<Result> containers;
    public Gee.TreeMap<Range, Result> results;

    public class Result {
        public SymbolKind symbol_kind { get; private set; }
        public Vala.Symbol symbol { get; private set; }
        public Result? container { get; private set; }

        public Result(SymbolKind symbol_kind, Vala.Symbol symbol, Result? container) {
            this.symbol_kind = symbol_kind;
            this.symbol = symbol;
            this.container = container;
        }
    }

    public ListSymbols (Vala.SourceFile file) {
        this.file = file;
        this.results = new Gee.TreeMap<Range, Result> ((r1, r2) => r1.start.compare(r2.start));
        this.containers = new Gee.LinkedList<Result> ();
        this.visit_source_file (file);
    }

    public Gee.Iterator<Gee.Map.Entry<Range, Result>> iterator() {
        return results.entries.iterator();
    }

    public override void visit_source_file (Vala.SourceFile file) {
        file.accept_children (this);
    }

    public override void visit_addressof_expression (Vala.AddressofExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_array_creation_expression (Vala.ArrayCreationExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_assignment (Vala.Assignment a) {
        a.accept_children (this);
    }

    public override void visit_base_access (Vala.BaseAccess expr) {
        expr.accept_children (this);
    }

    public override void visit_binary_expression (Vala.BinaryExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_block (Vala.Block b) {
        b.accept_children (this);
    }

    public override void visit_boolean_literal (Vala.BooleanLiteral lit) {
        lit.accept_children (this);
    }

    public override void visit_break_statement (Vala.BreakStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_cast_expression (Vala.CastExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_catch_clause (Vala.CatchClause clause) {
        clause.accept_children (this);
    }

    public override void visit_character_literal (Vala.CharacterLiteral lit) {
        lit.accept_children (this);
    }

    public override void visit_class (Vala.Class cl) {
        var result = new Result(Class, cl, containers.is_empty ? null : containers.peek_head ());
        containers.offer_head (result);
        if (cl.source_reference.file == file)
            results[new Range.from_sourceref (cl.source_reference)] = result;
        cl.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_conditional_expression (Vala.ConditionalExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_constant (Vala.Constant c) {
        if (c.source_reference.file == file)
            results[new Range.from_sourceref (c.source_reference)] 
                = new Result(Constant, c, containers.is_empty ? null : containers.peek_head ());
        c.accept_children (this);
    }

    public override void visit_constructor (Vala.Constructor c) {
        if (c.source_reference.file == file)
            results[new Range.from_sourceref (c.source_reference)] 
                = new Result(Constructor, c, containers.is_empty ? null : containers.peek_head ());
        c.accept_children (this);
    }

    public override void visit_continue_statement (Vala.ContinueStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_creation_method (Vala.CreationMethod m) {
        if (m.source_reference.file == file) {
            var range = new Range.from_sourceref (m.source_reference);
            // When there is no explicit constructor, the constructor will be defined in the same
            // place as the class was defined. When that happens, we prefer the class definition.
            if (!results.has_key (range))
                results[range] = new Result(Constructor, m, containers.is_empty ? null : containers.peek_head ());
        }
        m.accept_children (this);
    }

    public override void visit_declaration_statement (Vala.DeclarationStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_delegate (Vala.Delegate cb) {
        results[new Range.from_sourceref (cb.source_reference)] 
            = new Result(Interface, cb, containers.is_empty ? null : containers.peek_head ());
        cb.accept_children (this);
    }

    public override void visit_delete_statement (Vala.DeleteStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_do_statement (Vala.DoStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_element_access (Vala.ElementAccess expr) {
        expr.accept_children (this);
    }

    public override void visit_empty_statement (Vala.EmptyStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_enum (Vala.Enum en) {
        if (en.source_reference.file == file)
            results[new Range.from_sourceref (en.source_reference)] 
                = new Result(Enum, en, containers.is_empty ? null : containers.peek_head ());
        en.accept_children (this);
    }

    public override void visit_error_domain (Vala.ErrorDomain edomain) {
        if (edomain.source_reference.file == file)
            results[new Range.from_sourceref (edomain.source_reference)] 
                = new Result(Enum, edomain, containers.is_empty ? null : containers.peek_head ());
        edomain.accept_children (this);
    }

    public override void visit_expression_statement (Vala.ExpressionStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_field (Vala.Field f) {
        if (f.source_reference.file == file)
            results[new Range.from_sourceref (f.source_reference)] 
                = new Result(Field, f, containers.is_empty ? null : containers.peek_head ());
        f.accept_children (this);
    }

    public override void visit_for_statement (Vala.ForStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_foreach_statement (Vala.ForeachStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_if_statement (Vala.IfStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_initializer_list (Vala.InitializerList list) {
        list.accept_children (this);
    }

    public override void visit_integer_literal (Vala.IntegerLiteral lit) {
        lit.accept_children (this);
    }

    public override void visit_interface (Vala.Interface iface) {
        if (iface.source_reference.file == file)
            results[new Range.from_sourceref (iface.source_reference)] 
                = new Result(Interface, iface, containers.is_empty ? null : containers.peek_head ());
        iface.accept_children (this);
    }

    public override void visit_lambda_expression (Vala.LambdaExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_local_variable (Vala.LocalVariable local) {
        local.accept_children (this);
    }

    public override void visit_lock_statement (Vala.LockStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_loop (Vala.Loop stmt) {
        stmt.accept_children (this);
    }

    public override void visit_member_access (Vala.MemberAccess expr) {
        expr.accept_children (this);
    }

    public override void visit_method (Vala.Method m) {
        if (m.source_reference.file == file)
            results[new Range.from_sourceref (m.source_reference)] 
                = new Result(Method, m, containers.is_empty ? null : containers.peek_head ());
        m.accept_children (this);
    }

    public override void visit_method_call (Vala.MethodCall expr) {
        expr.accept_children (this);
    }

    public override void visit_namespace (Vala.Namespace ns) {
        var result = new Result(Namespace, ns, containers.is_empty ? null : containers.peek_head ());
        containers.offer_head (result);
        if (ns.source_reference.file == file)
            results[new Range.from_sourceref (ns.source_reference)] = result;
        ns.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_null_literal (Vala.NullLiteral lit) {
        lit.accept_children (this);
    }

    public override void visit_object_creation_expression (Vala.ObjectCreationExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_pointer_indirection (Vala.PointerIndirection expr) {
        expr.accept_children (this);
    }

    public override void visit_postfix_expression (Vala.PostfixExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_property (Vala.Property prop) {
        if (prop.source_reference.file == file)
            results[new Range.from_sourceref (prop.source_reference)] 
                = new Result(Property, prop, containers.is_empty ? null : containers.peek_head ());
        prop.accept_children (this);
    }

    public override void visit_real_literal (Vala.RealLiteral lit) {
        lit.accept_children (this);
    }

    public override void visit_reference_transfer_expression (Vala.ReferenceTransferExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_return_statement (Vala.ReturnStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_signal (Vala.Signal sig) {
        if (sig.source_reference.file == file)
            results[new Range.from_sourceref (sig.source_reference)] 
                = new Result(Event, sig, containers.is_empty ? null : containers.peek_head ());
        sig.accept_children (this);
    }

    public override void visit_sizeof_expression (Vala.SizeofExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_slice_expression (Vala.SliceExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_string_literal (Vala.StringLiteral lit) {
        lit.accept_children (this);
    }

    public override void visit_struct (Vala.Struct st) {
        var result = new Result(Struct, st, containers.is_empty ? null : containers.peek_head ());
        containers.offer_head (result);
        if (st.source_reference.file == file)
            results[new Range.from_sourceref (st.source_reference)] = result;
        st.accept_children (this);
        containers.poll_head ();
    }

    public override void visit_switch_label (Vala.SwitchLabel label) {
        label.accept_children (this);
    }

    public override void visit_switch_section (Vala.SwitchSection section) {
        section.accept_children (this);
    }

    public override void visit_switch_statement (Vala.SwitchStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_throw_statement (Vala.ThrowStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_try_statement (Vala.TryStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_type_check (Vala.TypeCheck expr) {
        expr.accept_children (this);
    }
}
