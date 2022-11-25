/* adddefaulttoswitchaction.vala
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

using Lsp;
using Gee;

class Vls.AddDefaultToSwitchAction : CodeAction {
    public AddDefaultToSwitchAction (CodeActionContext context,
                                     Vala.SwitchStatement sws,
                                     VersionedTextDocumentIdentifier document,
                                     CodeStyleAnalyzer code_style) {
        this.title = "Add default case to switch-statement";
        this.edit = new WorkspaceEdit ();

        var sections = sws.get_sections ();
        uint end_line, end_column;
        string label_indent, inner_indent;
        if (sections.is_empty) {
            end_line = sws.source_reference.end.line;
            end_column = sws.source_reference.end.column;
            Util.advance_past ((string)sws.source_reference.end.pos, /{/, ref end_line, ref end_column);
            label_indent = code_style.get_indentation (sws, 0);
            inner_indent = code_style.get_indentation (sws, 1);
        } else {
            var last_section = sections.last ();
            label_indent = code_style.get_indentation (last_section);
            Vala.SourceReference source_ref;
            if (last_section.get_statements ().is_empty) {
                source_ref = last_section.source_reference;
                inner_indent = code_style.get_indentation (last_section, 1);
            } else {
                var last_stmt = last_section.get_statements ().last ();
                source_ref = last_stmt.source_reference;
                inner_indent = code_style.get_indentation (last_stmt);
            }
            end_line = source_ref.end.line;
            end_column = source_ref.end.column;
            Util.advance_past ((string)source_ref.end.pos, /[;:]/, ref end_line, ref end_column);
        };
        var insert_text = "%sdefault:\n%sassert_not_reached%*s();\n"
            .printf (label_indent, inner_indent, code_style.average_spacing_before_parens, "");
        var document_edit = new TextDocumentEdit (document);
        var end_pos = new Position () {
            line = end_line - 1,
            character = end_column
        };
        var text_edit = new TextEdit (new Range () {
            start = end_pos,
            end = end_pos
        }, insert_text);
        document_edit.edits.add (text_edit);
        this.edit.documentChanges = new ArrayList<TextDocumentEdit>.wrap ({document_edit});

        // now, include all relevant diagnostics
        foreach (var diag in context.diagnostics)
            if (diag.message.contains ("Switch does not handle"))
                add_diagnostic (diag);
        if (diagnostics != null && !diagnostics.is_empty)
            this.kind = "quickfix";
        else
            this.kind = "refactor.rewrite";
    }
}
