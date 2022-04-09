/* baseconverteraction.vala
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

/**
 * The base converter code action allows to convert a constant to a different base.
 * For example:
 * ```vala
 * int x = 10;   // actions: convert to 0xA or 012
 * ```
 */
class Vls.BaseConverterAction : CodeAction {
    public BaseConverterAction (Vala.IntegerLiteral lit, VersionedTextDocumentIdentifier document) {
        string val = lit.value;
        // bool signed = lit.type_suffix[0] == 'u' || lit.type_suffix[0] == 'U';
        bool negative = false;
        if (val[0] == '-') {
            negative = true;
            val = val[1:];
        }
        var workspace_edit = new WorkspaceEdit ();
        var document_edit = new TextDocumentEdit () {
            textDocument = document
        };
        var text_edit = new TextEdit () {
            range = new Range.from_sourceref (lit.source_reference)
        };
        if (val.has_prefix ("0x")) {
            // base 16  -> base 8
            val = val[2:];
            text_edit.newText = "%s%#llo".printf (negative ? "-" : "", ulong.parse (val, 16));
            this.title = "Convert hexadecimal value to octal";
        } else if (val[0] == '0') {
            // base 8   -> base 10
            val = val[1:];
            text_edit.newText = "%s%#lld".printf (negative ? "-" : "", ulong.parse (val, 8));
            this.title = "Convert octal value to decimal";
        } else {
            // base 10  -> base 16
            text_edit.newText = "%s%#llx".printf (negative ? "-" : "", ulong.parse (val));
            this.title = "Convert decimal value to hexadecimal";
        }
        document_edit.edits.add (text_edit);
        workspace_edit.documentChanges.add (document_edit);
        this.kind = "";
        this.edit = workspace_edit;
    }
}
