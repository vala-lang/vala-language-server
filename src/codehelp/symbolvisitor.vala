/* symbolvisitor.vala
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

using Vala;

/**
 * Useful for when we need to iterate over the nodes in a document
 * in a generic fashion, in search of a code node that matches a given
 * symbol in some way, or that we can perform an operation on, given
 * knowledge of a symbol to compare, custom user data, and the code
 * node we are presently exploring.
 */
class Vls.SymbolVisitor<G> : CodeVisitor {
    [CCode (has_target = false)]
    public delegate void Func<G> (CodeNode code_node, Symbol symbol, G user_data);

    private SourceFile file;
    private Symbol symbol;
    private G data;
    private Gee.HashSet<CodeNode> seen;
    private bool include_declaration;
    private Func<G> func;

    public SymbolVisitor (SourceFile file, Symbol symbol, G data, bool include_declaration, Func<G> func) {
        this.file = file;
        this.symbol = symbol;
        this.data = data;
        this.seen = new Gee.HashSet<CodeNode> ();
        this.include_declaration = include_declaration;
        this.func = func;
        visit_source_file (file);

        // XXX: sometimes the CodeVisitor does not see a local variable,
        // especially if it is declared as part of a foreach statement
        if (symbol is LocalVariable && filter (symbol))
            func (symbol, symbol, data);
    }

    private bool filter (CodeNode node) {
        var sr = node.source_reference;
        if (sr == null)
            return false;
        if (sr.file != file)
            return false;
        if (sr.begin.line > sr.end.line) {
            warning ("wtf Vala: %s @ %s", node.type_name, sr.to_string ());
            return false;
        }
        return true;
    }

    public override void visit_source_file (SourceFile source_file) {
        source_file.accept_children (this);
        foreach (var using_directive in source_file.current_using_directives)
            visit_using_directive (using_directive);
    }

    public override void visit_addressof_expression (AddressofExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_array_creation_expression (ArrayCreationExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_assignment (Assignment a) {
        if (seen.contains (a))
            return;
        seen.add (a);
        if (filter (a))
            func (a, symbol, data);
        a.accept_children (this);
    }

    public override void visit_base_access (BaseAccess expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_binary_expression (BinaryExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_block (Block b) {
        if (seen.contains (b))
            return;
        seen.add (b);
        if (filter (b))
            func (b, symbol, data);
        b.accept_children (this);
    }

    public override void visit_boolean_literal (BooleanLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit, symbol, data);
        lit.accept_children (this);
    }

    public override void visit_break_statement (BreakStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_cast_expression (CastExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_catch_clause (CatchClause clause) {
        if (seen.contains (clause))
            return;
        seen.add (clause);
        if (filter (clause))
            func (clause, symbol, data);
        clause.accept_children (this);
    }

    public override void visit_character_literal (CharacterLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit, symbol, data);
        lit.accept_children (this);
    }

    public override void visit_class (Class cl) {
        if (seen.contains (cl))
            return;
        seen.add (cl);
        if (filter (cl) && include_declaration)
            func (cl, symbol, data);
        cl.accept_children (this);
    }

    public override void visit_conditional_expression (ConditionalExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_constant (Constant c) {
        if (seen.contains (c))
            return;
        seen.add (c);
        if (filter (c) && include_declaration)
            func (c, symbol, data);
        c.accept_children (this);
    }

    public override void visit_constructor (Constructor c) {
        if (seen.contains (c))
            return;
        seen.add (c);
        if (filter (c) && include_declaration)
            func (c, symbol, data);
        c.accept_children (this);
    }

    public override void visit_continue_statement (ContinueStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_creation_method (CreationMethod m) {
        if (seen.contains (m))
            return;
        seen.add (m);
        if (filter (m) && include_declaration)
            func (m, symbol, data);
        m.accept_children (this);
    }

    public override void visit_data_type (DataType type) {
        if (seen.contains (type))
            return;
        seen.add (type);
        if (filter (type))
            func (type, symbol, data);
        type.accept_children (this);
    }

    public override void visit_declaration_statement (DeclarationStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_delegate (Delegate cb) {
        if (seen.contains (cb))
            return;
        seen.add (cb);
        if (filter (cb) && include_declaration)
            func (cb, symbol, data);
        cb.accept_children (this);
    }

    public override void visit_delete_statement (DeleteStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }
    
    public override void visit_destructor (Destructor dtor) {
        if (seen.contains (dtor))
            return;
        seen.add (dtor);
        if (filter (dtor) && include_declaration)
            func (dtor, symbol, data);
        dtor.accept_children (this);
    }

    public override void visit_do_statement (DoStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_element_access (ElementAccess expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_empty_statement (EmptyStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_enum (Enum en) {
        if (seen.contains (en))
            return;
        seen.add (en);
        if (filter (en) && include_declaration)
            func (en, symbol, data);
        en.accept_children (this);
    }

    public override void visit_enum_value (Vala.EnumValue ev) {
        if (seen.contains (ev))
            return;
        seen.add (ev);
        if (filter (ev) && include_declaration)
            func (ev, symbol, data);
        ev.accept_children (this);
    }

    public override void visit_error_code (ErrorCode ecode) {
        if (seen.contains (ecode))
            return;
        seen.add (ecode);
        if (filter (ecode) && include_declaration)
            func (ecode, symbol, data);
        ecode.accept_children (this);
    }

    public override void visit_error_domain (ErrorDomain edomain) {
        if (seen.contains (edomain))
            return;
        seen.add (edomain);
        if (filter (edomain) && include_declaration)
            func (edomain, symbol, data);
        edomain.accept_children (this);
    }

    /* note: do NOT implement visit_expression () without seen, since
     * this will, in most cases, be redundant and dramatically
     * slow down FindSymbol */
    public override void visit_expression (Expression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_expression_statement (ExpressionStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_field (Field f) {
        if (seen.contains (f))
            return;
        seen.add (f);
        if (filter (f) && include_declaration)
            func (f, symbol, data);
        f.accept_children (this);
    }

    public override void visit_for_statement (ForStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_foreach_statement (ForeachStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_formal_parameter (Vala.Parameter p) {
        if (seen.contains (p))
            return;
        seen.add (p);
        if (filter (p) && include_declaration)
            func (p, symbol, data);
        p.accept_children (this);
    }

    public override void visit_if_statement (IfStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_initializer_list (InitializerList list) {
        if (seen.contains (list))
            return;
        seen.add (list);
        if (filter (list))
            func (list, symbol, data);
        list.accept_children (this);
    }

    public override void visit_integer_literal (IntegerLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit, symbol, data);
        lit.accept_children (this);
    }

    public override void visit_interface (Interface iface) {
        if (seen.contains (iface))
            return;
        seen.add (iface);
        if (filter (iface) && include_declaration)
            func (iface, symbol, data);
        iface.accept_children (this);
    }

    public override void visit_lambda_expression (LambdaExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_local_variable (LocalVariable local) {
        if (seen.contains (local))
            return;
        seen.add (local);
        if (filter (local) && (include_declaration || !(local.parent_node is DeclarationStatement)))
            func (local, symbol, data);
        local.accept_children (this);
    }

    public override void visit_lock_statement (LockStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

#if VALA_0_52
    public override void visit_loop_statement (Vala.LoopStatement stmt) {
#else
    public override void visit_loop (Vala.Loop stmt) {
#endif
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_member_access (MemberAccess expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_method (Method m) {
        if (seen.contains (m))
            return;
        seen.add (m);
        if (filter (m) && include_declaration)
            func (m, symbol, data);
        m.accept_children (this);
    }

    public override void visit_method_call (MethodCall expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_namespace (Namespace ns) {
        if (seen.contains (ns))
            return;
        seen.add (ns);
        if (filter (ns))
            func (ns, symbol, data);
        ns.accept_children (this);
    }

    public override void visit_null_literal (NullLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit, symbol, data);
        lit.accept_children (this);
    }

    public override void visit_object_creation_expression (ObjectCreationExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_pointer_indirection (PointerIndirection expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_postfix_expression (PostfixExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_property (Property prop) {
        if (seen.contains (prop))
            return;
        seen.add (prop);
        if (filter (prop) && include_declaration)
            func (prop, symbol, data);
        prop.accept_children (this);
    }

    public override void visit_property_accessor (PropertyAccessor acc) {
        if (seen.contains (acc))
            return;
        seen.add (acc);
        if (filter (acc) && include_declaration)
            func (acc, symbol, data);
        acc.accept_children (this);
    }

    public override void visit_real_literal (RealLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit, symbol, data);
        lit.accept_children (this);
    }

    public override void visit_reference_transfer_expression (ReferenceTransferExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_regex_literal (RegexLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit, symbol, data);
        lit.accept_children (this);
    }

    public override void visit_return_statement (ReturnStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_signal (Vala.Signal sig) {
        if (seen.contains (sig))
            return;
        seen.add (sig);
        if (filter (sig) && include_declaration)
            func (sig, symbol, data);
        sig.accept_children (this);
    }

    public override void visit_sizeof_expression (SizeofExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_slice_expression (SliceExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_string_literal (StringLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit, symbol, data);
        lit.accept_children (this);
    }

    public override void visit_struct (Struct st) {
        if (seen.contains (st))
            return;
        seen.add (st);
        if (filter (st) && include_declaration)
            func (st, symbol, data);
        st.accept_children (this);
    }

    public override void visit_switch_label (SwitchLabel label) {
        if (seen.contains (label))
            return;
        seen.add (label);
        if (filter (label))
            func (label, symbol, data);
        label.accept_children (this);
    }

    public override void visit_switch_section (SwitchSection section) {
        if (seen.contains (section))
            return;
        seen.add (section);
        if (filter (section))
            func (section, symbol, data);
        section.accept_children (this);
    }

    public override void visit_switch_statement (SwitchStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_template (Template tmpl) {
        if (seen.contains (tmpl))
            return;
        seen.add (tmpl);
        if (filter (tmpl))
            func (tmpl, symbol, data);
        tmpl.accept_children (this);
    }

    public override void visit_throw_statement (ThrowStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_try_statement (TryStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_type_check (TypeCheck expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_type_parameter (TypeParameter p) {
        if (seen.contains (p))
            return;
        seen.add (p);
        if (filter (p))
            func (p, symbol, data);
        p.accept_children (this);
    }

    public override void visit_typeof_expression (TypeofExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_unary_expression (UnaryExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr, symbol, data);
        expr.accept_children (this);
    }

    public override void visit_unlock_statement (UnlockStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }

    public override void visit_using_directive (UsingDirective ud) {
        if (seen.contains (ud))
            return;
        seen.add (ud);
        if (filter (ud))
            func (ud, symbol, data);
        ud.accept_children (this);
    }

    public override void visit_yield_statement (YieldStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt, symbol, data);
        stmt.accept_children (this);
    }
}
