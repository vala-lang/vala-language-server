/* typehierarchy.vala
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

using Vala;
using Lsp;

namespace Vls.TypeHierarchy {
    TypeHierarchyItem[] get_subtypes (Project project, TypeSymbol symbol) {
        TypeHierarchyItem[] subtypes = {};

        var generated_vapis = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
        foreach (var btarget in project.get_compilations ())
            generated_vapis.add_all (btarget.output);
        var shown_files = new Gee.HashSet<File> (Util.file_hash, Util.file_equal);
        foreach (var pair in SymbolReferences.get_compilations_using_symbol (project, symbol)) {
            foreach (var source_file in pair.first.code_context.get_source_files ()) {
                var gfile = File.new_for_commandline_arg (source_file.filename);
                // don't show symbol from generated VAPI
                if (gfile in generated_vapis || gfile in shown_files)
                    continue;

                var compilation_type_symbol = SymbolReferences.find_matching_symbol (pair.first.code_context, symbol);
                Vala.CodeContext.push (pair.first.code_context);
                var result = new NodeSearch.with_filter (
                    source_file, 
                    compilation_type_symbol, 
                    (needle, node) => {
                        if (needle is ObjectTypeSymbol && node is ObjectTypeSymbol)
                            return node != needle && ((ObjectTypeSymbol)node).is_subtype_of ((ObjectTypeSymbol)needle);
                        if (needle is Struct && node is Struct)
                            return ((Struct)node).base_struct == (Struct)needle;
                        return false;
                    }, 
                    true
                ).result;
                foreach (var node in result)
                    subtypes += new TypeHierarchyItem.from_symbol ((Vala.TypeSymbol)node);
                Vala.CodeContext.pop ();

                shown_files.add (gfile);
            }
        }

        return subtypes;
    }

    TypeHierarchyItem[] get_supertypes (Project project, TypeSymbol symbol) {
        TypeHierarchyItem[] supertypes = {};

        if (symbol is ObjectTypeSymbol) {
            var ots = (ObjectTypeSymbol)symbol;
            foreach (var iface in ots.get_interfaces ()) {
                var real_iface = SymbolReferences.find_real_symbol (project, iface) as TypeSymbol;
                if (real_iface != null)
                    supertypes += new TypeHierarchyItem.from_symbol (real_iface);
            }
        }
        if (symbol is Class) {
            var cls = (Class)symbol;
            foreach (var base_type in cls.get_base_types ()) {
                if (base_type.type_symbol != null) {
                    var real_type_symbol = SymbolReferences.find_real_symbol (project, base_type.type_symbol) as TypeSymbol;
                    if (real_type_symbol != null)
                        supertypes += new TypeHierarchyItem.from_symbol (real_type_symbol);
                }
            }
        } else if (symbol is Struct) {
            var st = (Struct)symbol;
            if (st.base_type != null && st.base_type.type_symbol != null) {
                var real_type_symbol = SymbolReferences.find_real_symbol (project, st.base_type.type_symbol) as TypeSymbol;
                if (real_type_symbol != null)
                    supertypes += new TypeHierarchyItem.from_symbol (real_type_symbol);
            }
        }

        return supertypes;
    }
}