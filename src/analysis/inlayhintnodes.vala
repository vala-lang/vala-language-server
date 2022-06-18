/* inlayhintnodes.vala
 *
 * Copyright 2022 Princeton Ferro <princetonferro@gmail.com>
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
 * Collects all special nodes of interest to the inlay hinter. This must be run
 * before the semantic analyzer.
 */
class Vls.InlayHintNodes : Vala.CodeVisitor {
    SourceFile? file;
    Gee.HashSet<LocalVariable> declarations;
    Gee.HashMap<CodeNode, int> method_calls;

    public InlayHintNodes (Gee.HashSet<LocalVariable> declarations, Gee.HashMap<CodeNode, int> method_calls) {
        this.declarations = declarations;
        this.method_calls = method_calls;
    }

    public override void visit_source_file (SourceFile source_file) {
        file = source_file;
        source_file.accept_children (this);
        file = null;
    }

    public override void visit_namespace (Namespace ns) {
        if (ns.source_reference == null || ns.source_reference.file != file)
            return;
        ns.accept_children (this);
    }

    public override void visit_class (Vala.Class cl) {
        if (cl.source_reference == null || cl.source_reference.file != file)
            return;
        cl.accept_children (this);
    }

    public override void visit_interface (Vala.Interface iface) {
        if (iface.source_reference == null || iface.source_reference.file != file)
            return;
        iface.accept_children (this);
    }

    public override void visit_struct (Vala.Struct st) {
        if (st.source_reference == null || st.source_reference.file != file)
            return;
        st.accept_children (this);
    }

    public override void visit_enum (Vala.Enum en) {
        if (en.source_reference == null || en.source_reference.file != file)
            return;
        en.accept_children (this);
    }

    public override void visit_method (Method m) {
        if (m.source_reference == null || m.source_reference.file != file)
            return;
        m.accept_children (this);
    }

    public override void visit_creation_method (Vala.CreationMethod m) {
        if (m.source_reference == null || m.source_reference.file != file)
            return;
        m.accept_children (this);
    }

    public override void visit_destructor (Vala.Destructor d) {
        if (d.source_reference == null || d.source_reference.file != file)
            return;
        d.accept_children (this);
    }

    public override void visit_constructor (Vala.Constructor c) {
        if (c.source_reference == null || c.source_reference.file != file)
            return;
        c.accept_children (this);
    }

    public override void visit_signal (Vala.Signal sig) {
        sig.accept_children (this);
    }

    public override void visit_property (Vala.Property prop) {
        prop.accept_children (this);
    }

    public override void visit_property_accessor (Vala.PropertyAccessor acc) {
        acc.accept_children (this);
    }

    public override void visit_block (Block b) {
        b.accept_children (this);
    }

    public override void visit_declaration_statement (Vala.DeclarationStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_local_variable (LocalVariable local) {
        if (!(local.initializer is CastExpression || local.initializer is ObjectCreationExpression || local.initializer is ArrayCreationExpression) &&
            local.variable_type is VarType)
            declarations.add (local);
        local.accept_children (this);
    }

    public override void visit_expression_statement (Vala.ExpressionStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_expression (Expression expr) {
        expr.accept_children (this);
    }

    public override void visit_method_call (Vala.MethodCall expr) {
        method_calls[expr] = expr.get_argument_list ().size;
    }

    public override void visit_object_creation_expression (Vala.ObjectCreationExpression expr) {
        method_calls[expr] = expr.get_argument_list ().size;
    }

    public override void visit_formal_parameter (Vala.Parameter p) {
        p.accept_children (this);
    }

    public override void visit_if_statement (IfStatement stmt) {
        stmt.accept_children (this);
    }

#if VALA_0_52
    public override void visit_loop_statement (LoopStatement stmt) {
#else
    public override void visit_loop (Loop stmt) {
#endif
        stmt.accept_children (this);
    }

    public override void visit_for_statement (ForStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_foreach_statement (Vala.ForeachStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_do_statement (Vala.DoStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_while_statement (WhileStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_try_statement (TryStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_catch_clause (CatchClause clause) {
        clause.accept_children (this);
    }

    public override void visit_return_statement (ReturnStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_yield_statement (YieldStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_lock_statement (LockStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_unlock_statement (UnlockStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_switch_statement (SwitchStatement stmt) {
        stmt.accept_children (this);
    }
}
