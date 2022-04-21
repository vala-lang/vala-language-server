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
     * Extracts a list of code actions for the given document and range using the AST and the diagnostics.
     *
     * @param file      the current document
     * @param range     the range to show code actions for
     * @param uri       the document URI
     */
    Collection<CodeAction> generate_codeactions (Compilation compilation, TextDocument file, Range range, string uri, Reporter reporter) {
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
                var lit = (IntegerLiteral) code_node;
                var lit_range = new Range.from_sourceref (lit.source_reference);
                if (lit_range.contains (range.start) && lit_range.contains (range.end))
                    code_actions.add (new BaseConverterAction (lit, document));
            } else if (code_node is Class) {
                var csym = (Class) code_node;
                var clsdef_range = compute_class_def_range (csym, class_ranges);
                var cls_range = new Range.from_sourceref (csym.source_reference);
                if (cls_range.contains (range.start) && cls_range.contains (range.end)) {
                    var missing = CodeHelp.gather_missing_prereqs_and_unimplemented_symbols (csym);
                    if (!missing.first.is_empty || !missing.second.is_empty) {
                        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (file);
                        code_actions.add (new ImplementMissingPrereqsAction (csym, missing.first, missing.second, clsdef_range.end, code_style, document));
                    }
                }
            } else if (code_node is ObjectCreationExpression) {
                var oce = (ObjectCreationExpression) code_node;
                foreach (var diag in reporter.messages) {
                    if (file.filename != diag.loc.file.filename)
                        continue;
                    if (diag.message.contains (" extra arguments for ")) {
                        var to_be_created = oce.type_reference.symbol;
                        if (!(to_be_created is Vala.Class)) {
                            continue;
                        }
                        var constr = ((Vala.Class) to_be_created).constructor;
                        if (constr != null) {
                            continue;
                        }
                        var target_file = to_be_created.source_reference.file;
                        // We can't just edit, e.g. some external vapi
                        if (!compilation.get_project_files ().contains (target_file))
                            continue;
                        var insertion_line = to_be_created.source_reference.end.line + 1;
                        var sb = new StringBuilder ();
                        var indent = to_be_created.source_reference.begin.column == 1 ? "" : "\t";
                        sb.append (indent).append (indent).append ("public ").append (oce.member_name.to_string ()).append ("(");
                        var args = oce.get_argument_list ();
                        var idx = 0;
                        for (var i = 0; i < args.size - 1; i++) {
                            sb.append (args[i].value_type.to_string ()).append (" arg%d".printf (idx++)).append (", ");
                        }
                        if (args.size != 0)
                            sb.append (args[args.size - 1].value_type.to_string ()).append (" arg%d".printf (idx));
                        sb.append (") {}\n ");
                        try {
                            var target_uri = Filename.to_uri (target_file.filename);
                            var target_document = new VersionedTextDocumentIdentifier () {
                                uri = target_uri,
                                version = 1
                            };
                            var workspace_edit = new WorkspaceEdit ();
                            var document_edit = new TextDocumentEdit (target_document);
                            var r = new Range.from_sourceref (
                                new Vala.SourceReference (target_file,
                                        Vala.SourceLocation (null, insertion_line, 1),
                                        Vala.SourceLocation (null, insertion_line, 1)));
                            var text_edit = new TextEdit (r);
                            document_edit.edits.add (text_edit);
                            workspace_edit.documentChanges = new Gee.ArrayList<TextDocumentEdit> ();
                            workspace_edit.documentChanges.add (document_edit);
                            var ca = new CodeAction ();
                            ca.edit = workspace_edit;
                            ca.title = "Add constructor";
                            text_edit.newText = sb.str;
                            code_actions.add (ca);
                        } catch (ConvertError ce) {
                            error ("Should not happen: %s", ce.message);
                        }
                    }
                }
            }
        }

        find_actionable_diagnostics (code_actions, document, file, range, reporter);

        return code_actions;
    }

    void find_actionable_diagnostics (Vala.ArrayList<Lsp.CodeAction> code_actions, VersionedTextDocumentIdentifier document, TextDocument file, Range range, Reporter reporter) {
        foreach (var diagnostic in reporter.messages) {
            if (file.filename != diagnostic.loc.file.filename)
                continue;
            var location = new Range.from_sourceref (diagnostic.loc);
            // Should this be AND or OR?
            var matches = location.contains (range.start) || location.contains (range.end);
            if (!matches)
                continue;
            var workspace_edit = new WorkspaceEdit ();
            var document_edit = new TextDocumentEdit (document);
            var text_edit = new TextEdit (location);
            document_edit.edits.add (text_edit);
            workspace_edit.documentChanges = new Gee.ArrayList<TextDocumentEdit> ();
            workspace_edit.documentChanges.add (document_edit);
            var ca = new CodeAction ();
            ca.edit = workspace_edit;
            var msg = diagnostic.message;
            if (msg == "[Deprecated] is deprecated. Use [Version (deprecated = true, deprecated_since = \"\", replacement = \"\")]") {
                // No [], as the range excludes those chars
                text_edit.newText = "Version (deprecated = true, deprecated_since = \"\", replacement = \"\")";
                ca.title = "Use [Version (deprecated = true, deprecated_since = \"\", replacement = \"\")]";
            } else if (msg == "[NoArrayLength] is deprecated, use [CCode (array_length = false)] instead.") {
                text_edit.newText = "CCode (array_length = false)";
                ca.title = "Use [CCode (array_length = false)]";
            } else if (msg == "[Experimental] is deprecated. Use [Version (experimental = true, experimental_until = \"\")]") {
                text_edit.newText = "Version (experimental = true, experimental_until = \"\")";
                ca.title = "Use [Version (experimental = true, experimental_until = \"\")]";
            } else if (msg == "Assignment to same variable") {
                text_edit.newText = "";
                var line = file.get_source_line (diagnostic.loc.end.line);
                var before_same_assignment = line.substring (0, diagnostic.loc.begin.column);
                if (before_same_assignment.strip () == "")
                    text_edit.range.start.character = 0;
                var after_same_assignment = line.substring (diagnostic.loc.end.column);
                var idx = 0;
                var found_semicolon = -1;
                while (idx < after_same_assignment.length) {
                    if (after_same_assignment[idx] == ';') {
                        found_semicolon = idx;
                    } else if (after_same_assignment[idx] == '/'
                               && idx + 1 < after_same_assignment.length
                               && after_same_assignment[idx + 1] == '/') {
                        break;
                    }
                    idx++;
                }
                if (found_semicolon != -1)
                    text_edit.range.end.character += idx;
                ca.title = "Remove assignment";
            } else {
                continue;
            }
            code_actions.add (ca);
        }
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
        var offset = csym.source_reference.end.pos - (char*) csym.source_reference.file.content;
        var dl = 0;
        var dc = 0;
        while (offset < csym.source_reference.file.content.length && csym.source_reference.file.content[(long) offset] != '{') {
            if (Util.is_newline (csym.source_reference.file.content[(long) offset])) {
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
            if (member is Method && ((Method) member).body != null && ((Method) member).body.source_reference != null)
                range = range.union (new Range.from_sourceref (((Method) member).body.source_reference));
        }
        class_ranges[csym] = range;
        return range;
    }
}
