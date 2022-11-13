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
     */
    Collection<CodeAction> extract (Compilation compilation, TextDocument file, Range range, string uri) {
        var code_actions = new ArrayList<CodeAction> ();

        if (file.last_updated.compare (compilation.last_updated) > 0)
            // don't show code actions for a stale document
            return code_actions;

        var class_ranges = new HashMap<TypeSymbol, Range> ();
        var document = new VersionedTextDocumentIdentifier () {
            version = file.version,
            uri = uri
        };

        // search for nodes containing the query range
        var finder = new NodeSearch (file, range.start, true, range.end, false);

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
            } else if (code_node is SwitchStatement) {
                var sws = (SwitchStatement)code_node;
                var expr = sws.expression.target_type;
                var labels = sws.get_sections ();
                if (expr is EnumValueType) {
                    var consts_by_name = new Gee.HashSet<string> ();
                    var evt = (EnumValueType)expr;
                    var e = evt.type_symbol;
                    if (!(e is Enum)) {
                        warning ("enum value type doesn't have enum - %s", evt.to_string ());
                        continue;
                    }
                    foreach (var ec in ((Enum)e).get_values ()) {
                        consts_by_name.add (ec.name);
                    }
                    var found_default = false;
                    foreach (var l in labels) {
                        if (l.has_default_label ()) {
                            found_default = true;
                        }
                        foreach (var a in l.get_labels ()) {
                            var case_expression = a.expression;
                            // Default label
                            if (case_expression == null)
                                continue;
                            if (case_expression.symbol_reference is Constant)
                                consts_by_name.remove (((Constant)case_expression.symbol_reference).name);
                        }
                    }
                    if (found_default && consts_by_name.is_empty)
                        continue;
                    var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (file);
                    if (!found_default && sws.source_reference != null)
                        code_actions.add (new AddDefaultToSwitchAction (sws, document, code_style));
                    if (!consts_by_name.is_empty && sws.source_reference != null)
                        code_actions.add (new AddOtherConstantsToSwitchAction (sws, document, (Enum)e, consts_by_name, code_style));
                } else {
                    var found_default = false;
                    foreach (var l in labels) {
                        if (l.has_default_label ()) {
                            found_default = true;
                            break;
                        }
                    }
                    if (!found_default && sws.source_reference != null) {
                        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (file);
                        code_actions.add (new AddDefaultToSwitchAction (sws, document, code_style));
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
