/* codeaction.vala
 *
 * Copyright 2022 JCWasmx86 <JCWasmx86@t-online.de>
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 3 of the
 * License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

using Gee;
using Lsp;

namespace Vls.CodeActions {
    /**
     * Extracts a list of code actions for the given document and range.
     */
    CodeAction[] extract (TextDocument file, Range range, string uri) {
        var visitor = new Visitor (file, range, uri);
        file.accept (visitor);
        return visitor.code_actions.to_array ();
    }

    class Visitor : Vala.CodeVisitor {
        private TextDocument doc;
        private string uri;
        private Range range;
        private Set<Vala.CodeNode> seen;
        private VersionedTextDocumentIdentifier document;
        internal Gee.List<CodeAction> code_actions { get; set; default = new Gee.ArrayList<CodeAction> (); }

        internal Visitor (TextDocument doc, Range range, string uri) {
            this.doc = doc;
            this.uri = uri;
            this.range = range;
            this.seen = new HashSet<Vala.CodeNode>();
            this.document = new VersionedTextDocumentIdentifier () {
                version = doc.version,
                uri = this.uri
            };
        }

        public override void visit_addressof_expression (Vala.AddressofExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_array_creation_expression (Vala.ArrayCreationExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_assignment (Vala.Assignment a) {
            if (!seen.add (a))
                return;
            a.accept_children (this);
        }

        public override void visit_base_access (Vala.BaseAccess expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_binary_expression (Vala.BinaryExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_block (Vala.Block b) {
            if (!seen.add (b))
                return;
            b.accept_children (this);
        }

        public override void visit_boolean_literal (Vala.BooleanLiteral lit) {
            if (!seen.add (lit))
                return;
            lit.accept_children (this);
        }

        public override void visit_break_statement (Vala.BreakStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_cast_expression (Vala.CastExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_catch_clause (Vala.CatchClause clause) {
            if (!seen.add (clause))
                return;
            clause.accept_children (this);
        }

        public override void visit_character_literal (Vala.CharacterLiteral lit) {
            if (!seen.add (lit))
                return;
            lit.accept_children (this);
        }

        public override void visit_class (Vala.Class cl) {
            if (!seen.add (cl))
                return;
            cl.accept_children (this);
        }

        public override void visit_conditional_expression (Vala.ConditionalExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_constant (Vala.Constant c) {
            if (!seen.add (c))
                return;
            c.accept_children (this);
        }

        public override void visit_constructor (Vala.Constructor c) {
            if (!seen.add (c))
                return;
            c.accept_children (this);
        }

        public override void visit_continue_statement (Vala.ContinueStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_creation_method (Vala.CreationMethod m) {
            if (!seen.add (m))
                return;
            m.accept_children (this);
        }

        public override void visit_data_type (Vala.DataType type) {
            if (!seen.add (type))
                return;
            type.accept_children (this);
        }

        public override void visit_declaration_statement (Vala.DeclarationStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_delegate (Vala.Delegate d) {
            if (!seen.add (d))
                return;
            d.accept_children (this);
        }

        public override void visit_delete_statement (Vala.DeleteStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_destructor (Vala.Destructor d) {
            if (!seen.add (d))
                return;
            d.accept_children (this);
        }

        public override void visit_do_statement (Vala.DoStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_element_access (Vala.ElementAccess expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_empty_statement (Vala.EmptyStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_end_full_expression (Vala.Expression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_enum (Vala.Enum en) {
            if (!seen.add (en))
                return;
            en.accept_children (this);
        }

        public override void visit_enum_value (Vala.EnumValue ev) {
            if (!seen.add (ev))
                return;
            ev.accept_children (this);
        }

        public override void visit_error_code (Vala.ErrorCode ecode) {
            if (!seen.add (ecode))
                return;
            ecode.accept_children (this);
        }

        public override void visit_error_domain (Vala.ErrorDomain edomain) {
            if (!seen.add (edomain))
                return;
            edomain.accept_children (this);
        }

        public override void visit_expression (Vala.Expression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_expression_statement (Vala.ExpressionStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_field (Vala.Field f) {
            if (!seen.add (f))
                return;
            f.accept_children (this);
        }

        public override void visit_for_statement (Vala.ForStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_foreach_statement (Vala.ForeachStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_formal_parameter (Vala.Parameter p) {
            if (!seen.add (p))
                return;
            p.accept_children (this);
        }

        public override void visit_if_statement (Vala.IfStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_initializer_list (Vala.InitializerList list) {
            if (!seen.add (list))
                return;
            list.accept_children (this);
        }

        public override void visit_integer_literal (Vala.IntegerLiteral lit) {
            if (!seen.add (lit))
                return;
            if (lit.source_reference != null) {
                var lit_range = new Range.from_sourceref (lit.source_reference);
                if (lit_range.contains (this.range.start) && lit_range.contains (this.range.end))
                    code_actions.add (new BaseConverterAction (lit, document));
            }
            lit.accept_children (this);
        }

        public override void visit_interface (Vala.Interface iface) {
            if (!seen.add (iface))
                return;
            iface.accept_children (this);
        }

        public override void visit_lambda_expression (Vala.LambdaExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_local_variable (Vala.LocalVariable local) {
            if (!seen.add (local))
                return;
            local.accept_children (this);
        }

        public override void visit_lock_statement (Vala.LockStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

#if VALA_0_52
        public override void visit_loop_statement (Vala.LoopStatement stmt) {
#else
        public override void visit_loop (Vala.Loop stmt) {
#endif
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_member_access (Vala.MemberAccess expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_method (Vala.Method m) {
            if (!seen.add (m))
                return;
            m.accept_children (this);
        }

        public override void visit_method_call (Vala.MethodCall expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_named_argument (Vala.NamedArgument expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_namespace (Vala.Namespace ns) {
            if (!seen.add (ns))
                return;
            ns.accept_children (this);
        }

        public override void visit_null_literal (Vala.NullLiteral lit) {
            if (!seen.add (lit))
                return;
            lit.accept_children (this);
        }

        public override void visit_object_creation_expression (Vala.ObjectCreationExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_pointer_indirection (Vala.PointerIndirection expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_postfix_expression (Vala.PostfixExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_property (Vala.Property prop) {
            if (!seen.add (prop))
                return;
            prop.accept_children (this);
        }

        public override void visit_property_accessor (Vala.PropertyAccessor acc) {
            if (!seen.add (acc))
                return;
            acc.accept_children (this);
        }

        public override void visit_real_literal (Vala.RealLiteral lit) {
            if (!seen.add (lit))
                return;
            lit.accept_children (this);
        }

        public override void visit_reference_transfer_expression (Vala.ReferenceTransferExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_regex_literal (Vala.RegexLiteral lit) {
            if (!seen.add (lit))
                return;
            lit.accept_children (this);
        }

        public override void visit_return_statement (Vala.ReturnStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_signal (Vala.Signal sig) {
            if (!seen.add (sig))
                return;
            sig.accept_children (this);
        }

        public override void visit_sizeof_expression (Vala.SizeofExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_slice_expression (Vala.SliceExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_source_file (Vala.SourceFile source_file) {
            source_file.accept_children (this);
        }

        public override void visit_string_literal (Vala.StringLiteral lit) {
            if (!seen.add (lit))
                return;
            lit.accept_children (this);
        }

        public override void visit_struct (Vala.Struct st) {
            if (!seen.add (st))
                return;
            st.accept_children (this);
        }

        public override void visit_switch_label (Vala.SwitchLabel label) {
            if (!seen.add (label))
                return;
            label.accept_children (this);
        }

        public override void visit_switch_section (Vala.SwitchSection section) {
            if (!seen.add (section))
                return;
            section.accept_children (this);
        }

        public override void visit_switch_statement (Vala.SwitchStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_template (Vala.Template tmpl) {
            if (!seen.add (tmpl))
                return;
            tmpl.accept_children (this);
        }

        public override void visit_throw_statement (Vala.ThrowStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_try_statement (Vala.TryStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_tuple (Vala.Tuple tuple) {
            if (!seen.add (tuple))
                return;
            tuple.accept_children (this);
        }

        public override void visit_type_check (Vala.TypeCheck expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_type_parameter (Vala.TypeParameter p) {
            if (!seen.add (p))
                return;
            p.accept_children (this);
        }

        public override void visit_typeof_expression (Vala.TypeofExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_unary_expression (Vala.UnaryExpression expr) {
            if (!seen.add (expr))
                return;
            expr.accept_children (this);
        }

        public override void visit_unlock_statement (Vala.UnlockStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

        public override void visit_using_directive (Vala.UsingDirective ns) {
            if (!seen.add (ns))
                return;
            ns.accept_children (this);
        }

        public override void visit_while_statement (Vala.WhileStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }

#if VALA_0_50
        public override void visit_with_statement (Vala.WithStatement stmt) {
            if (!seen.add (stmt))
                return;
            stmt.accept_children (this);
        }
#endif

        public override void visit_yield_statement (Vala.YieldStatement y) {
            if (!seen.add (y))
                return;
            y.accept_children (this);
        }
    }
}
