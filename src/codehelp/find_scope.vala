/* find_scope.vala
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

using LanguageServer;
using Gee;

class Vls.FindScope : Vala.CodeVisitor {
    Vala.CodeContext context;
    Vala.SourceFile file;
    Position pos;
    ArrayList<Vala.Symbol> candidate_blocks = new ArrayList<Vala.Symbol> ();
    bool before_context_update;

    private Vala.Symbol _best_block;

    public Vala.Symbol best_block {
        get {
            if (_best_block == null)
                compute_best_block ();
            return _best_block;
        }
    }

    public FindScope (Vala.SourceFile file, Position pos, bool before_context_update = true) {
        assert (Vala.CodeContext.get () == file.context);
        // debug ("FindScope @ %s", pos.to_string ());
        this.context = file.context;
        this.file = file;
        this.pos = pos;
        this.before_context_update = before_context_update;
        this.visit_source_file (file);
    }

    void compute_best_block () {
        Vala.Symbol smallest_block = context.root;
        Range? best_range = smallest_block.source_reference != null ?
            new Range.from_sourceref (smallest_block.source_reference) : null;

        foreach (Vala.Symbol block in candidate_blocks) {
            var scope_range = new Range.from_sourceref (block.source_reference);
            if (best_range == null ||
                best_range.start.compare_to (scope_range.start) <= 0 &&
                !(best_range.start.compare_to (scope_range.start) == 0 && scope_range.end.compare_to (best_range.end) == 0)) {
                smallest_block = block;
                best_range = scope_range;
            }
        }

        _best_block = smallest_block;
    }

    void add_if_matches (Vala.Symbol symbol) {
        var sr = symbol.source_reference;
        if (sr == null) {
            // debug ("node %s has no source reference", node.type_name);
            return;
        }

        if (sr.file != file) {
            return;
        }

        if (sr.begin.line > sr.end.line) {
            warning (@"wtf vala: $(symbol.type_name): $sr");
            return;
        }

        var range = new Range.from_sourceref (sr);

        if (symbol is Vala.TypeSymbol || symbol is Vala.Namespace) {
            var symtab = symbol.scope.get_symbol_table ();
            if (symtab != null) {
                foreach (Vala.Symbol member in symtab.get_values ()) {
                    if (member.source_reference != null && member.source_reference.file == sr.file)
                        range = range.union (new Range.from_sourceref (member.source_reference));
                }
            }
        }

        // compare to range.end.line + 1 if before context update, assuming that
        // it's possible the user expanded the current scope
        Position new_end = before_context_update ? range.end.translate (2) : range.end;
        bool pos_within_start = range.start.compare_to (pos) <= 0;
        bool pos_within_end = pos.compare_to (range.end) <= 0 || pos.compare_to (new_end) <= 0;
        if (pos_within_start && pos_within_end) {
            candidate_blocks.add (symbol);
            // debug ("%s (%s, @ %s / %s) added to candidates for %s",
            //     node.to_string (), node.type_name, node.source_reference.to_string (), range.to_string (), pos.to_string ());
        } else {
            // debug ("%s (%s, @ %s / %s) not in candidates for %s",
            //     node.to_string (), node.type_name, node.source_reference.to_string (), range.to_string (), pos.to_string ());
        }
    }

    public override void visit_source_file (Vala.SourceFile file) {
        file.accept_children (this);
    }

    public override void visit_assignment (Vala.Assignment a) {
        a.accept_children (this);
    }

    public override void visit_binary_expression (Vala.BinaryExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_block (Vala.Block b) {
        add_if_matches (b);
        b.accept_children (this);
    }

    public override void visit_catch_clause (Vala.CatchClause clause) {
        clause.accept_children (this);
    }

    public override void visit_class (Vala.Class cl) {
        add_if_matches (cl);
        cl.accept_children (this);
    }

    public override void visit_conditional_expression (Vala.ConditionalExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_constructor (Vala.Constructor c) {
        add_if_matches (c);
        c.accept_children (this);
    }

    public override void visit_creation_method (Vala.CreationMethod m) {
        add_if_matches (m);
        m.accept_children (this);
    }

    public override void visit_declaration_statement (Vala.DeclarationStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_destructor (Vala.Destructor d) {
        add_if_matches (d);
        d.accept_children (this);
    }

    public override void visit_do_statement (Vala.DoStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_enum (Vala.Enum en) {
        en.accept_children (this);
    }

    public override void visit_error_domain (Vala.ErrorDomain edomain) {
        edomain.accept_children (this);
    }

    public override void visit_expression_statement (Vala.ExpressionStatement stmt) {
        stmt.accept_children (this);
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

    public override void visit_interface (Vala.Interface iface) {
        add_if_matches (iface);
        iface.accept_children (this);
    }

    public override void visit_lambda_expression (Vala.LambdaExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_lock_statement (Vala.LockStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_local_variable (Vala.LocalVariable local) {
        local.accept_children (this);
    }

    public override void visit_loop_statement (Vala.LoopStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_member_access (Vala.MemberAccess expr) {
        expr.accept_children (this);
    }

    public override void visit_method (Vala.Method m) {
        add_if_matches (m);
        m.accept_children (this);
    }

    public override void visit_method_call (Vala.MethodCall mc) {
        mc.accept_children (this);
    }

    public override void visit_namespace (Vala.Namespace ns) {
        add_if_matches (ns);
        ns.accept_children (this);
    }

    public override void visit_object_creation_expression (Vala.ObjectCreationExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_postfix_expression (Vala.PostfixExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_property (Vala.Property prop) {
        add_if_matches (prop);
        prop.accept_children (this);
    }

    public override void visit_property_accessor (Vala.PropertyAccessor acc) {
        add_if_matches (acc);
        acc.accept_children (this);
    }

    public override void visit_return_statement (Vala.ReturnStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_signal (Vala.Signal sig) {
        sig.accept_children (this);
    }

    public override void visit_struct (Vala.Struct st) {
        add_if_matches (st);
        st.accept_children (this);
    }

    public override void visit_switch_label (Vala.SwitchLabel label) {
        label.accept_children (this);
    }

    public override void visit_switch_section (Vala.SwitchSection section) {
        add_if_matches (section);
        section.accept_children (this);
    }

    public override void visit_switch_statement (Vala.SwitchStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_try_statement (Vala.TryStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_unary_expression (Vala.UnaryExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_while_statement (Vala.WhileStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_yield_statement (Vala.YieldStatement stmt) {
        stmt.accept_children (this);
    }
}
