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
class Vls.SymbolVisitor : CodeVisitor {
    public delegate void Func (CodeNode code_node);

    private SourceFile file;
    private Gee.HashSet<CodeNode> seen;
    private bool include_declaration;
    private Func func;

    public SymbolVisitor (SourceFile file, Symbol symbol, bool include_declaration, owned Func func) {
        this.file = file;
        this.seen = new Gee.HashSet<CodeNode> ();
        this.include_declaration = include_declaration;
        this.func = (owned) func;
        visit_source_file (file);

        // XXX: sometimes the CodeVisitor does not see a local variable,
        // especially if it is declared as part of a foreach statement
        if (symbol is LocalVariable && filter (symbol))
            func (symbol);
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
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_array_creation_expression (ArrayCreationExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_assignment (Assignment a) {
        if (seen.contains (a))
            return;
        seen.add (a);
        if (filter (a))
            func (a);
        a.accept_children (this);
    }

    public override void visit_base_access (BaseAccess expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_binary_expression (BinaryExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_block (Block b) {
        if (seen.contains (b))
            return;
        seen.add (b);
        if (filter (b))
            func (b);
        b.accept_children (this);
    }

    public override void visit_boolean_literal (BooleanLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit);
        lit.accept_children (this);
    }

    public override void visit_break_statement (BreakStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_cast_expression (CastExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_catch_clause (CatchClause clause) {
        if (seen.contains (clause))
            return;
        seen.add (clause);
        if (filter (clause))
            func (clause);
        clause.accept_children (this);
    }

    public override void visit_character_literal (CharacterLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit);
        lit.accept_children (this);
    }

    public override void visit_class (Class cl) {
        if (seen.contains (cl))
            return;
        seen.add (cl);
        if (filter (cl) && include_declaration)
            func (cl);
        cl.accept_children (this);
    }

    public override void visit_conditional_expression (ConditionalExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_constant (Constant c) {
        if (seen.contains (c))
            return;
        seen.add (c);
        if (filter (c) && include_declaration)
            func (c);
        c.accept_children (this);
    }

    public override void visit_constructor (Constructor c) {
        if (seen.contains (c))
            return;
        seen.add (c);
        if (filter (c) && include_declaration)
            func (c);
        c.accept_children (this);
    }

    public override void visit_continue_statement (ContinueStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_creation_method (CreationMethod m) {
        if (seen.contains (m))
            return;
        seen.add (m);
        if (filter (m) && include_declaration)
            func (m);
        m.accept_children (this);
    }

    public override void visit_data_type (DataType type) {
        if (seen.contains (type))
            return;
        seen.add (type);
        if (filter (type))
            func (type);
        type.accept_children (this);
    }

    public override void visit_declaration_statement (DeclarationStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_delegate (Delegate cb) {
        if (seen.contains (cb))
            return;
        seen.add (cb);
        if (filter (cb) && include_declaration)
            func (cb);
        cb.accept_children (this);
    }

    public override void visit_delete_statement (DeleteStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }
    
    public override void visit_destructor (Destructor dtor) {
        if (seen.contains (dtor))
            return;
        seen.add (dtor);
        if (filter (dtor) && include_declaration)
            func (dtor);
        dtor.accept_children (this);
    }

    public override void visit_do_statement (DoStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_element_access (ElementAccess expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_empty_statement (EmptyStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_enum (Enum en) {
        if (seen.contains (en))
            return;
        seen.add (en);
        if (filter (en) && include_declaration)
            func (en);
        en.accept_children (this);
    }

    public override void visit_enum_value (Vala.EnumValue ev) {
        if (seen.contains (ev))
            return;
        seen.add (ev);
        if (filter (ev) && include_declaration)
            func (ev);
        ev.accept_children (this);
    }

    public override void visit_error_code (ErrorCode ecode) {
        if (seen.contains (ecode))
            return;
        seen.add (ecode);
        if (filter (ecode) && include_declaration)
            func (ecode);
        ecode.accept_children (this);
    }

    public override void visit_error_domain (ErrorDomain edomain) {
        if (seen.contains (edomain))
            return;
        seen.add (edomain);
        if (filter (edomain) && include_declaration)
            func (edomain);
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
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_expression_statement (ExpressionStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_field (Field f) {
        if (seen.contains (f))
            return;
        seen.add (f);
        if (filter (f) && include_declaration)
            func (f);
        f.accept_children (this);
    }

    public override void visit_for_statement (ForStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_foreach_statement (ForeachStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_formal_parameter (Vala.Parameter p) {
        if (seen.contains (p))
            return;
        seen.add (p);
        if (filter (p) && include_declaration)
            func (p);
        p.accept_children (this);
    }

    public override void visit_if_statement (IfStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_initializer_list (InitializerList list) {
        if (seen.contains (list))
            return;
        seen.add (list);
        if (filter (list))
            func (list);
        list.accept_children (this);
    }

    public override void visit_integer_literal (IntegerLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit);
        lit.accept_children (this);
    }

    public override void visit_interface (Interface iface) {
        if (seen.contains (iface))
            return;
        seen.add (iface);
        if (filter (iface) && include_declaration)
            func (iface);
        iface.accept_children (this);
    }

    public override void visit_lambda_expression (LambdaExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_local_variable (LocalVariable local) {
        if (seen.contains (local))
            return;
        seen.add (local);
        if (filter (local) && (include_declaration || !(local.parent_node is DeclarationStatement)))
            func (local);
        local.accept_children (this);
    }

    public override void visit_lock_statement (LockStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
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
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_member_access (MemberAccess expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_method (Method m) {
        if (seen.contains (m))
            return;
        seen.add (m);
        if (filter (m) && include_declaration)
            func (m);
        m.accept_children (this);
    }

    public override void visit_method_call (MethodCall expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_namespace (Namespace ns) {
        if (seen.contains (ns))
            return;
        seen.add (ns);
        if (filter (ns))
            func (ns);
        ns.accept_children (this);
    }

    public override void visit_null_literal (NullLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit);
        lit.accept_children (this);
    }

    public override void visit_object_creation_expression (ObjectCreationExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_pointer_indirection (PointerIndirection expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_postfix_expression (PostfixExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_property (Property prop) {
        if (seen.contains (prop))
            return;
        seen.add (prop);
        if (filter (prop) && include_declaration)
            func (prop);
        prop.accept_children (this);
    }

    public override void visit_property_accessor (PropertyAccessor acc) {
        if (seen.contains (acc))
            return;
        seen.add (acc);
        if (filter (acc) && include_declaration)
            func (acc);
        acc.accept_children (this);
    }

    public override void visit_real_literal (RealLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit);
        lit.accept_children (this);
    }

    public override void visit_reference_transfer_expression (ReferenceTransferExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_regex_literal (RegexLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit);
        lit.accept_children (this);
    }

    public override void visit_return_statement (ReturnStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_signal (Vala.Signal sig) {
        if (seen.contains (sig))
            return;
        seen.add (sig);
        if (filter (sig) && include_declaration)
            func (sig);
        sig.accept_children (this);
    }

    public override void visit_sizeof_expression (SizeofExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_slice_expression (SliceExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_string_literal (StringLiteral lit) {
        if (seen.contains (lit))
            return;
        seen.add (lit);
        if (filter (lit))
            func (lit);
        lit.accept_children (this);
    }

    public override void visit_struct (Struct st) {
        if (seen.contains (st))
            return;
        seen.add (st);
        if (filter (st) && include_declaration)
            func (st);
        st.accept_children (this);
    }

    public override void visit_switch_label (SwitchLabel label) {
        if (seen.contains (label))
            return;
        seen.add (label);
        if (filter (label))
            func (label);
        label.accept_children (this);
    }

    public override void visit_switch_section (SwitchSection section) {
        if (seen.contains (section))
            return;
        seen.add (section);
        if (filter (section))
            func (section);
        section.accept_children (this);
    }

    public override void visit_switch_statement (SwitchStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_template (Template tmpl) {
        if (seen.contains (tmpl))
            return;
        seen.add (tmpl);
        if (filter (tmpl))
            func (tmpl);
        tmpl.accept_children (this);
    }

    public override void visit_throw_statement (ThrowStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_try_statement (TryStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_type_check (TypeCheck expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_type_parameter (TypeParameter p) {
        if (seen.contains (p))
            return;
        seen.add (p);
        if (filter (p))
            func (p);
        p.accept_children (this);
    }

    public override void visit_typeof_expression (TypeofExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_unary_expression (UnaryExpression expr) {
        if (seen.contains (expr))
            return;
        seen.add (expr);
        if (filter (expr))
            func (expr);
        expr.accept_children (this);
    }

    public override void visit_unlock_statement (UnlockStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

    public override void visit_using_directive (UsingDirective ud) {
        if (seen.contains (ud))
            return;
        seen.add (ud);
        if (filter (ud))
            func (ud);
        ud.accept_children (this);
    }

    public override void visit_yield_statement (YieldStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }

#if VALA_0_50
    public override void visit_with_statement (Vala.WithStatement stmt) {
        if (seen.contains (stmt))
            return;
        seen.add (stmt);
        if (filter (stmt))
            func (stmt);
        stmt.accept_children (this);
    }
#endif
}
