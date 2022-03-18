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

namespace Lsp.CodeActionExtractor {
    CodeAction[] extract (Vala.SourceFile file, CodeActionParams request) {
        var visitor = new CodeActionVisitor (request.range, request.textDocument);
        Vala.CodeContext.push (new Vala.CodeContext ());
        file.accept (visitor);
        Vala.CodeContext.pop ();
        return visitor.code_actions.to_array ();
    }

    // Implement all abstract methods?
    // Extract "Generate hash_code"
    // Extract "Generate to_string"
    // Numbers to alternate formats
    // In case this has to be redone:
    // export IFS=$'\n'
    // for i in $(cat libvala-0.56.vapi |grep class.CodeVisitor -A83|tail -n 82|head -n 81|sed s/.*public/public/g|sed s/virtual/override/g|sed "s/;/{/g"); do
    // echo $i;
    // param_name=$(echo $i|sed s/.*\(//g|sed s/\)\{//g|cut -d ' ' -f2);
    // echo $param_name".accept_children(this);";
    // echo "}";
    // done
    class CodeActionVisitor : Vala.CodeVisitor {
        private string uri;
        private Range range;
        private Set<Vala.CodeNode> visited_nodes;

        internal CodeActionVisitor (Range range, TextDocumentIdentifier identifier) {
            this.range = range;
            this.uri = identifier.uri;
            this.visited_nodes = new Gee.HashSet<Vala.CodeNode>();
        }

        internal Gee.List<CodeAction> code_actions { get; set; default = new Gee.ArrayList<CodeAction> (); }
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
            cl.accept_children (this);
        }

        public override void visit_conditional_expression (Vala.ConditionalExpression expr) {
            expr.accept_children (this);
        }

        public override void visit_constant (Vala.Constant c) {
            c.accept_children (this);
        }

        public override void visit_constructor (Vala.Constructor c) {
            c.accept_children (this);
        }

        public override void visit_continue_statement (Vala.ContinueStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_creation_method (Vala.CreationMethod m) {
            m.accept_children (this);
        }

        public override void visit_data_type (Vala.DataType type) {
            type.accept_children (this);
        }

        public override void visit_declaration_statement (Vala.DeclarationStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_delegate (Vala.Delegate d) {
            d.accept_children (this);
        }

        public override void visit_delete_statement (Vala.DeleteStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_destructor (Vala.Destructor d) {
            d.accept_children (this);
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

        public override void visit_end_full_expression (Vala.Expression expr) {
            expr.accept_children (this);
        }

        public override void visit_enum (Vala.Enum en) {
            en.accept_children (this);
        }

        public override void visit_enum_value (Vala.EnumValue ev) {
            ev.accept_children (this);
        }

        public override void visit_error_code (Vala.ErrorCode ecode) {
            ecode.accept_children (this);
        }

        public override void visit_error_domain (Vala.ErrorDomain edomain) {
            edomain.accept_children (this);
        }

        public override void visit_expression (Vala.Expression expr) {
            expr.accept_children (this);
        }

        public override void visit_expression_statement (Vala.ExpressionStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_field (Vala.Field f) {
            f.accept_children (this);
        }

        public override void visit_for_statement (Vala.ForStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_foreach_statement (Vala.ForeachStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_formal_parameter (Vala.Parameter p) {
            p.accept_children (this);
        }

        public override void visit_if_statement (Vala.IfStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_initializer_list (Vala.InitializerList list) {
            list.accept_children (this);
        }

        public override void visit_integer_literal (Vala.IntegerLiteral lit) {
            var location = lit.source_reference;
            if (location != null && !this.visited_nodes.contains (lit)) {
                this.visited_nodes.add (lit);
                var start = location.begin.line - 1;
                var end = location.end.line - 1;
                var contains_start = start >= this.range.start.line && start <= this.range.end.line;
                var contains_end = end <= this.range.end.line && end >= this.range.start.line;
                if (!contains_start && !contains_end) {
                    lit.accept_children (this);
                    return;
                }
                var val = lit.value;
                var negative = val.has_prefix ("-");
                if (negative)
                    val = val.substring (1);
                var ibase = 10;
                if (val.has_prefix ("0x"))
                    ibase = 16;
                else if (val.has_prefix ("0") && val != "0")
                    ibase = 8;
                var offset = ibase == 8 ? 1 : (ibase == 10 ? 0 : 2);
                var raw_value_without_base = val.substring (offset);
                var supported_bases = new int[] { 8, 10, 16 };
                var base_prefixes = new string[] { "0", "", "0x" };
                if (lit.type_suffix.down ().has_prefix ("u")) {
                    var int_value = uint64.parse (raw_value_without_base, ibase);
                    for (var i = 0; i < supported_bases.length; i++) {
                        if (ibase != supported_bases[i]) {
                            this.add_unsigned_base_converter (supported_bases[i], base_prefixes[i], int_value, lit);
                        }
                    }
                } else {
                    var int_value = int64.parse (raw_value_without_base, ibase);
                    for (var i = 0; i < supported_bases.length; i++) {
                        if (ibase != supported_bases[i]) {
                            this.add_base_converter (supported_bases[i], base_prefixes[i], int_value, lit, negative);
                        }
                    }
                }
            }
            lit.accept_children (this);
        }

        private void add_unsigned_base_converter (int target, string prefix, uint64 int_value, Vala.IntegerLiteral lit) {
            var new_text = "";
            switch (target) {
            case 8:
                new_text = "0%llo".printf (int_value);
                break;
            case 10:
                new_text = "%llu".printf (int_value);
                break;
            case 16:
                new_text = "0x%llx".printf (int_value);
                break;
            }
            this.add_base_converter_action ("Convert %s%s to base %d".printf (lit.value, lit.type_suffix, target), new_text + lit.type_suffix, lit);
        }

        private void add_base_converter_action (string title, string new_text, Vala.IntegerLiteral lit) {
            var action = new CodeAction ();
            action.title = title;
            action.kind = "";
            var loc = lit.source_reference;
            action.edit = new WorkspaceEdit ();
            var edit = new TextEdit ();
            edit.range = new Range () {
                start = new Position () {
                    line = loc.begin.line - 1,
                    character = loc.begin.column - 1
                },
                end = new Position () {
                    line = loc.end.line - 1,
                    character = loc.end.column
                },
            };
            edit.newText = new_text;
            var docEdit = new TextDocumentEdit ();
            docEdit.edits.add (edit);
            docEdit.textDocument = new VersionedTextDocumentIdentifier () {
                uri = this.uri
            };
            action.edit.documentChanges.add (docEdit);
            this.code_actions.add (action);
        }

        private void add_base_converter (int target, string prefix, int64 int_value, Vala.IntegerLiteral lit, bool negative) {
            var new_text = "";
            var minus = negative ? "-" : "";
            switch (target) {
            case 8:
                new_text = "%s0%llo".printf (minus, int_value);
                break;
            case 10:
                new_text = "%s%lld".printf (minus, int_value);
                break;
            case 16:
                new_text = "%s0x%llx".printf (minus, int_value);
                break;
            }
            this.add_base_converter_action ("Convert %s%s to base %d".printf (lit.value, lit.type_suffix, target), new_text + lit.type_suffix, lit);
        }

        public override void visit_interface (Vala.Interface iface) {
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

#if VALA_0_52
        public override void visit_loop_statement (Vala.LoopStatement stmt) {
#else
        public override void visit_loop (Vala.Loop stmt) {
#endif
            stmt.accept_children (this);
        }

        public override void visit_member_access (Vala.MemberAccess expr) {
            expr.accept_children (this);
        }

        public override void visit_method (Vala.Method m) {
            m.accept_children (this);
        }

        public override void visit_method_call (Vala.MethodCall expr) {
            expr.accept_children (this);
        }

        public override void visit_named_argument (Vala.NamedArgument expr) {
            expr.accept_children (this);
        }

        public override void visit_namespace (Vala.Namespace ns) {
            ns.accept_children (this);
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
            prop.accept_children (this);
        }

        public override void visit_property_accessor (Vala.PropertyAccessor acc) {
            acc.accept_children (this);
        }

        public override void visit_real_literal (Vala.RealLiteral lit) {
            lit.accept_children (this);
        }

        public override void visit_reference_transfer_expression (Vala.ReferenceTransferExpression expr) {
            expr.accept_children (this);
        }

        public override void visit_regex_literal (Vala.RegexLiteral lit) {
            lit.accept_children (this);
        }

        public override void visit_return_statement (Vala.ReturnStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_signal (Vala.Signal sig) {
            sig.accept_children (this);
        }

        public override void visit_sizeof_expression (Vala.SizeofExpression expr) {
            expr.accept_children (this);
        }

        public override void visit_slice_expression (Vala.SliceExpression expr) {
            expr.accept_children (this);
        }

        public override void visit_source_file (Vala.SourceFile source_file) {
            source_file.accept_children (this);
        }

        public override void visit_string_literal (Vala.StringLiteral lit) {
            lit.accept_children (this);
        }

        public override void visit_struct (Vala.Struct st) {
            st.accept_children (this);
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

        public override void visit_template (Vala.Template tmpl) {
            tmpl.accept_children (this);
        }

        public override void visit_throw_statement (Vala.ThrowStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_try_statement (Vala.TryStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_tuple (Vala.Tuple tuple) {
            tuple.accept_children (this);
        }

        public override void visit_type_check (Vala.TypeCheck expr) {
            expr.accept_children (this);
        }

        public override void visit_type_parameter (Vala.TypeParameter p) {
            p.accept_children (this);
        }

        public override void visit_typeof_expression (Vala.TypeofExpression expr) {
            expr.accept_children (this);
        }

        public override void visit_unary_expression (Vala.UnaryExpression expr) {
            expr.accept_children (this);
        }

        public override void visit_unlock_statement (Vala.UnlockStatement stmt) {
            stmt.accept_children (this);
        }

        public override void visit_using_directive (Vala.UsingDirective ns) {
            ns.accept_children (this);
        }

        public override void visit_while_statement (Vala.WhileStatement stmt) {
            stmt.accept_children (this);
        }

#if VALA_0_50
        public override void visit_with_statement (Vala.WithStatement stmt) {
            stmt.accept_children (this);
        }

#endif

        public override void visit_yield_statement (Vala.YieldStatement y) {
            y.accept_children (this);
        }
    }
}
