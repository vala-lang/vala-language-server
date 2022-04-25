/* implementnamedconstructoraction.vala
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
using Gee;

class Vls.ImplementNamedConstructorAction : CodeAction {
    public ImplementNamedConstructorAction (Vala.ObjectCreationExpression oce, Vala.Symbol to_be_created) {
        var target_file = to_be_created.source_reference.file;
        var insertion_line = to_be_created.source_reference.end.line + 1;
        var sb = new StringBuilder ();
        var indent = to_be_created.source_reference.begin.column == 1 ? "" : "\t";
        sb.append (indent).append (indent).append ("public ").append (oce.member_name.to_string ()).append ("(");
        var args = oce.get_argument_list ();
        var idx = 0;
        for (var i = 0; i < args.size - 1; i++) {
            var arg = args[i];
            arg.check (Vala.CodeContext.get ());
            var s = arg.value_type.to_string ();
            sb.append (s == null ? "GLib.Object" : s).append (" arg%d".printf (idx++)).append (", ");
        }
        if (args.size != 0) {
            var last_arg = args[args.size - 1];
            last_arg.check (Vala.CodeContext.get ());
            var s = last_arg.value_type.to_string ();
            sb.append (s == null ? "GLib.Object" : s).append (" arg%d".printf (idx));
        }
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
            this.edit = workspace_edit;
            this.title = "Add constructor";
            text_edit.newText = sb.str;
        } catch (ConvertError ce) {
            error ("Should not happen: %s", ce.message);
        }
    }
}
