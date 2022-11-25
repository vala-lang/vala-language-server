/* implementmissingprereqsaction.vala
 *
 * Copyright 2022 Princeton Ferro <princetonferro@gmail.com>
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2.1 of the
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
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Lsp;
using Gee;

/**
 * Implement all missing prerequisites of a class type.
 */
class Vls.ImplementMissingPrereqsAction : CodeAction {
    public ImplementMissingPrereqsAction (CodeActionContext context,
                                          Vala.Class class_sym,
                                          Vala.Collection<Vala.DataType> missing_prereqs,
                                          Vala.Collection<Pair<Vala.DataType, Vala.Symbol>> missing_symbols,
                                          Position classdef_end,
                                          CodeStyleAnalyzer code_style,
                                          VersionedTextDocumentIdentifier document) {
        this.title = "Implement missing prerequisites for class";
        this.kind = "quickfix";
        this.edit = new WorkspaceEdit ();

        var changes = new ArrayList<TextDocumentEdit> ();
        var document_edit = new TextDocumentEdit (document);
        changes.add (document_edit);

        // insert the types after the class declaration
        var cls_endpos = new Position.from_libvala (class_sym.source_reference.end);
        var typelist_text = new StringBuilder ();
        var prereq_i = 0;
        foreach (var prereq_type in missing_prereqs) {
            if (prereq_i > 0) {
                typelist_text.append (", ");
            } else {
                typelist_text.append (CodeHelp.get_code_node_source (class_sym).index_of_char (':') == -1 ? " : " : ", ");
            }
            typelist_text.append (CodeHelp.get_data_type_representation (prereq_type, class_sym.scope, true));
            prereq_i++;
        }
        document_edit.edits.add (new TextEdit (new Range () {
            start = cls_endpos,
            end = cls_endpos
        }, typelist_text.str));

        // insert the methods and properties that need to be implemented
        var symbols_insert_text = new StringBuilder ();
        string symbol_indent, inner_indent;
        var visible_members = CodeHelp.get_visible_members (class_sym);

        if (visible_members.is_empty) {
            symbol_indent = code_style.get_indentation (class_sym, 1);
            inner_indent = code_style.get_indentation (class_sym, 2);
        } else {
            var last_member = visible_members.last ();
            symbol_indent = code_style.get_indentation (last_member);
            inner_indent = code_style.get_indentation (last_member, 1);
        }
        foreach (var prereq_sym_pair in missing_symbols) {
            var instance_type = prereq_sym_pair.first;
            var sym = prereq_sym_pair.second;

            if (!(sym is Vala.Method || sym is Vala.Property)) {
                warning ("unexpected symbol type %s @ %s", sym.type_name, sym.source_reference.to_string ());
                continue;
            }

            symbols_insert_text.append_printf ("\n%s%s ", symbol_indent, sym.access.to_string ());

            if (sym.hides)
                symbols_insert_text.append ("new ");

            if (sym is Vala.Method && ((Vala.Method)sym).coroutine)
                symbols_insert_text.append ("async ");
            if (sym is Vala.Method && CodeHelp.base_method_requires_override ((Vala.Method)sym) ||
                sym is Vala.Property && CodeHelp.base_property_requires_override ((Vala.Property)sym))
                symbols_insert_text.append ("override ");

            Vala.DataType? return_type = null;
            if (sym is Vala.Callable)
                return_type = ((Vala.Callable)sym).return_type.get_actual_type (instance_type, null, null);
            else if (sym is Vala.Property)
                return_type = ((Vala.Property)sym).property_type.get_actual_type (instance_type, null, null);
            
            if (return_type != null) {
                string? return_type_representation = CodeHelp.get_data_type_representation (return_type, class_sym.scope);
                symbols_insert_text.append (return_type_representation);
                symbols_insert_text.append_c (' ');
            } else {
                warning ("no return type for symbol %s", sym.name);
            }

            symbols_insert_text.append (sym.name);

            if (sym is Vala.Callable) {
                // display type arguments
                Vala.List<Vala.TypeParameter>? type_parameters = null;
                if (sym is Vala.Delegate)
                    type_parameters = ((Vala.Delegate)sym).get_type_parameters ();
                else if (sym is Vala.Method)
                    type_parameters = ((Vala.Method)sym).get_type_parameters ();
                
                if (type_parameters != null && !type_parameters.is_empty) {
                    symbols_insert_text.append_c ('<');
                    int i = 1;
                    foreach (var type_parameter in type_parameters) {
                        if (i > 1) {
                            symbols_insert_text.append_c (',');
                        }
                        symbols_insert_text.append (type_parameter.name);
                    }
                    symbols_insert_text.append_c ('>');
                }

                symbols_insert_text.append_printf ("%*s(", code_style.average_spacing_before_parens, "");

                int i = 1;
                foreach (Vala.Parameter param in ((Vala.Callable) sym).get_parameters ()) {
                    if (i > 1) {
                        symbols_insert_text.append (", ");
                    }
                    symbols_insert_text.append (CodeHelp.get_symbol_representation (instance_type, param, class_sym.scope, false));
                    i++;
                }
                symbols_insert_text.append_printf (") {\n%sassert_not_reached%*s();\n%s}",
                                                   inner_indent, code_style.average_spacing_before_parens, "", symbol_indent);
            } else if (sym is Vala.Property) {
                var prop = (Vala.Property)sym;
                symbols_insert_text.append (" {");
                if (prop.get_accessor != null) {
                    if (prop.get_accessor.value_type is Vala.ReferenceType && prop.get_accessor.value_type.value_owned)
                        symbols_insert_text.append (" owned");
                    if (prop.get_accessor.access != prop.access)
                        symbols_insert_text.append_printf (" %s", prop.get_accessor.access.to_string ());
                    symbols_insert_text.append (" get;");
                }
                if (prop.set_accessor != null) {
                    if (prop.set_accessor.value_type is Vala.ReferenceType && prop.set_accessor.value_type.value_owned)
                        symbols_insert_text.append (" owned");
                    if (prop.set_accessor.access != prop.access)
                        symbols_insert_text.append_printf (" %s", prop.set_accessor.access.to_string ());
                    symbols_insert_text.append (" set;");
                }
                symbols_insert_text.append (" }");
            }
        }
        document_edit.edits.add (new TextEdit (new Range () {
            start = classdef_end,
            end = classdef_end 
        }, symbols_insert_text.str));

        this.edit.documentChanges = changes;

        // now, include all relevant diagnostics
        foreach (var diag in context.diagnostics)
            if (/does not implement|some prerequisites .*are not met/.match (diag.message))
                add_diagnostic (diag);
    }
}
