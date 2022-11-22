/* addtrycatchstatementaction.vala
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

class Vls.AddTryCatchStatementAction : CodeAction {
    public AddTryCatchStatementAction (VersionedTextDocumentIdentifier document, string error_name, string indent, Vala.CodeNode node) {
        var sref = node.source_reference;
        var sb = new StringBuilder ();
        var line = sref.file.get_source_line (sref.begin.line);
        var copied_indent = line.substring (0, line.length - line.chug ().length);
        sb.append (copied_indent).append ("try {\n");
        for (var i = sref.begin.line; i <= sref.end.line; i++) {
            var len = -1;
            var offset = 0;
            if (i == sref.begin.line && i != sref.end.line) {
                offset = sref.begin.column - 1;
            } else if (i == sref.end.line && i != sref.begin.line) {
                len = sref.end.column;
            } else if (i == sref.begin.line && i == sref.end.line) {
                offset = sref.begin.column - 1;
                len = sref.end.column - sref.begin.column + 1;
            }
            sb.append (copied_indent).append (indent);
            sb.append (sref.file.get_source_line (i).substring (offset, len).strip ());
            sb.append (i == sref.end.line ? ";" : "").append ("\n");
        }
        sb.append (copied_indent).append ("} catch (").append (error_name).append (" e) {\n");
        sb.append (copied_indent).append (indent).append ("error (\"Caught error ").append (error_name).append (": %s\", e.message);\n");
        sb.append (copied_indent).append ("}\n");
        var workspace_edit = new WorkspaceEdit ();
        var document_edit = new TextDocumentEdit (document);
        var text_edit = new TextEdit (new Range.from_sourceref (sref));
        text_edit.range.start.character = 0;
        text_edit.range.end.character++;
        text_edit.newText = sb.str;
        document_edit.edits.add (text_edit);
        workspace_edit.documentChanges = new ArrayList<TextDocumentEdit> ();
        workspace_edit.documentChanges.add (document_edit);
        this.edit = workspace_edit;
        this.title = "Wrap with try-catch";
    }
}
