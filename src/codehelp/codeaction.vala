/* codeaction.vala
 *
 * Copyright 2022 JCWasmx86 <JCWasmx86@t-online.de>
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
using Vala;

namespace Vls.CodeActions {
    /**
     * Extracts a list of code actions for the given document and range.
     *
     * @param file      the current document
     * @param range     the range to show code actions for
     * @param uri       the document URI
     * @param diags     the diagnostics to use
     */
    Collection<CodeAction> extract (Compilation compilation, TextDocument file, Range range, string uri, Gee.List<Diagnostic> diags) {
        // search for nodes containing the query range
        var finder = new NodeSearch (file, range.start, true, range.end);
        var code_actions = new ArrayList<CodeAction> ();
        var class_ranges = new HashMap<TypeSymbol, Range> ();
        var document = new VersionedTextDocumentIdentifier () {
            version = file.version,
            uri = uri
        };

        // add code actions
        foreach (CodeNode code_node in finder.result) {
            if (code_node is IntegerLiteral) {
                var lit = (IntegerLiteral)code_node;
                var lit_range = new Range.from_sourceref (lit.source_reference);
                if (lit_range.contains (range.start) && lit_range.contains (range.end))
                    code_actions.add (new BaseConverterAction (lit, document));
            } else if (code_node is Class) {
                var csym = (Class)code_node;
                var clsdef_range = compute_class_def_range (csym, class_ranges);
                var cls_range = new Range.from_sourceref (csym.source_reference);
                if (cls_range.contains (range.start) && cls_range.contains (range.end)) {
                    var missing = CodeHelp.gather_missing_prereqs_and_unimplemented_symbols (csym);
                    if (!missing.first.is_empty || !missing.second.is_empty) {
                        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (file);
                        code_actions.add (new ImplementMissingPrereqsAction (csym, missing.first, missing.second, clsdef_range.end, code_style, document));
                    }
                }
            }
        }

        finder = new NodeSearch.with_filter (file, null, (a, b) => true, true);
        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (file);
        foreach (var d in diags) {
            if (d.message.has_prefix ("unhandled error ")) {
                foreach (var node in finder.result) {
                    var tmp_range = new Range.from_sourceref (node.source_reference);
                    if ((tmp_range.contains (d.range.start) && tmp_range.contains (d.range.end))
                        && !(node is Vala.Block)) {
                        var error_name = d.message.replace ("unhandled error `", "").replace ("'", "").strip ();
                        if (node is DeclarationStatement) {
                            var variables = new Vala.ArrayList<Variable> ();
                            ((DeclarationStatement)node).get_defined_variables (variables);
                            if (variables.size == 1)
                                code_actions.add (new AddTryCatchAssignmentAction (document, variables, error_name, code_style.indentation, node));
                            var parent = node.parent_node;
                            while (parent != null) {
                                if (parent is Vala.ForeachStatement || parent is Vala.LambdaExpression) {
                                    parent = null;
                                    break;
                                }
                                if (parent is Vala.Method || parent is Vala.Constructor)
                                    break;
                                parent = parent.parent_node;
                            }
                            if (parent != null) {
                                code_actions.add (new AddThrowsDeclaration (document, error_name, parent));
                            }
                        } else if (node is ExpressionStatement && !(node.parent_node is Vala.ForeachStatement)) {
                            var es = (ExpressionStatement) node;
                            code_actions.add (new AddTryCatchStatementAction (document, error_name, code_style.indentation, es.expression));
                        } else {
                            var parent = node.parent_node;
                            while (parent != null) {
                                if (parent is Vala.ForeachStatement || parent is Vala.LambdaExpression) {
                                    parent = null;
                                    break;
                                }
                                if (parent is Vala.Method || parent is Vala.Constructor)
                                    break;
                                parent = parent.parent_node;
                            }
                            if (parent != null) {
                                code_actions.add (new AddThrowsDeclaration (document, error_name, parent));
                            }
                        }
                    }
                }
            }
        }

        return code_actions;
    }

    /**
     * Compute the full range of a class definition.
     */
    Range compute_class_def_range (Class csym, Map<TypeSymbol, Range> class_ranges) {
        if (csym in class_ranges)
            return class_ranges[csym];
        // otherwise compute the result and cache it
        // csym.source_reference must be non-null otherwise NodeSearch wouldn't have found csym
        var pos = new Position.from_libvala (csym.source_reference.end);
        var offset = csym.source_reference.end.pos - (char *)csym.source_reference.file.content;
        var dl = 0;
        var dc = 0;
        while (offset < csym.source_reference.file.content.length && csym.source_reference.file.content[(long)offset] != '{') {
            if (Util.is_newline (csym.source_reference.file.content[(long)offset])) {
                dl++;
                dc = 0;
            } else {
                dc++;
            }
            offset++;
        }
        pos = pos.translate (dl, dc + 1);
        var range = new Range () {
            start = pos,
            end = pos
        };
        foreach (Symbol member in csym.get_members ()) {
            if (member.source_reference == null)
                continue;
            range = range.union (new Range.from_sourceref (member.source_reference));
            if (member is Method && ((Method)member).body != null && ((Method)member).body.source_reference != null)
                range = range.union (new Range.from_sourceref (((Method)member).body.source_reference));
        }
        class_ranges[csym] = range;
        return range;
    }
}
