/* addthrowsdeclaration.vala
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

class Vls.AddThrowsDeclaration : CodeAction {
    public AddThrowsDeclaration (VersionedTextDocumentIdentifier document, string error_name, Vala.CodeNode where) {

        var error_types = new Vala.HashSet<Vala.DataType> ();
        if (where is Vala.Constructor)
            ((Vala.Constructor)where).body.get_error_types (error_types, null);
        else
            where.get_error_types (error_types, null);

        var sb = new StringBuilder ();
        if (error_types.is_empty) {
            sb.append (" throws ");
        } else {
            sb.append (", ");
        }
        sb.append (error_name);
        sb.append (" ");
        var sref = where.source_reference;
        var range = new Range ();
        for (var i = sref.begin.line; i <= sref.end.line; i++) {
            var line = sref.file.get_source_line (i);
            if (line.contains ("{")) {
                var idx = line.index_of ("{");
                range.start = new Lsp.Position () {
                    line = i - 1,
                    character = idx - 1,
                };
                range.end = new Lsp.Position () {
                    line = i - 1,
                    character = idx - 1,
                };
            }
        }
        var workspace_edit = new WorkspaceEdit ();
        var document_edit = new TextDocumentEdit (document);
        var text_edit = new TextEdit (range);
        text_edit.range.end.character++;
        text_edit.newText = sb.str;
        document_edit.edits.add (text_edit);
        workspace_edit.documentChanges = new ArrayList<TextDocumentEdit> ();
        workspace_edit.documentChanges.add (document_edit);
        this.edit = workspace_edit;
        this.title = "Add to error list";
    }
}
