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
    private VersionedTextDocumentIdentifier document;

    public BaseConverterAction (Vala.IntegerLiteral lit, VersionedTextDocumentIdentifier document) {
        var val = lit.value;
        this.document = document;
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
        if (lit.type_suffix.down ().has_prefix ("u")) {
            var int_value = uint64.parse (raw_value_without_base, ibase);
            for (var i = 0; i < supported_bases.length; i++) {
                if (ibase != supported_bases[i]) {
                    this.init_as_unsigned (supported_bases[i], int_value, lit);
                }
            }
        } else {
            var int_value = int64.parse (raw_value_without_base, ibase);
            for (var i = 0; i < supported_bases.length; i++) {
                if (ibase != supported_bases[i]) {
                    this.init_as_signed (supported_bases[i], int_value, lit, negative);
                }
            }
        }
    }

    private void init_as_unsigned (int target, uint64 int_value, Vala.IntegerLiteral lit) {
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
        this.init_with_data ("Convert %s%s to base %d".printf (lit.value, lit.type_suffix, target), new_text + lit.type_suffix, lit);
    }

    private void init_with_data (string title, string new_text, Vala.IntegerLiteral lit) {
        var workspace_edit = new WorkspaceEdit ();
        var document_edit = new TextDocumentEdit () {
            textDocument = this.document,
        };
        document_edit.edits.add (new TextEdit () {
            range = new Range.from_sourceref (lit.source_reference),
            newText = new_text
        });
        workspace_edit.documentChanges.add (document_edit);
        this.title = title;
        this.kind = "";
        this.edit = workspace_edit;
    }

    private void init_as_signed (int target, int64 int_value, Vala.IntegerLiteral lit, bool negative) {
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
        this.init_with_data ("Convert %s%s to base %d".printf (lit.value, lit.type_suffix, target), new_text + lit.type_suffix, lit);
    }
}
