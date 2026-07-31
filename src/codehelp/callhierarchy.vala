/* callhierarchy.vala
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

namespace Vls.CallHierarchy {
    CallHierarchyItem item_from_symbol (Symbol symbol) {
        SymbolKind kind;
        if (symbol is Method)
            kind = (symbol.parent_symbol is Namespace) ?
                SymbolKind.FUNCTION : SymbolKind.METHOD;
        else if (symbol is Vala.Signal)
            kind = SymbolKind.EVENT;
        else if (symbol is Constructor)
            kind = SymbolKind.CONSTRUCTOR;
        else
            kind = SymbolKind.METHOD;

        var tags = SymbolTag.UNSET;
        var version = symbol.get_attribute ("Version");
        if (version != null &&
            (version.get_bool ("deprecated") ||
             version.get_string ("deprecated_since") != null)) {
            tags |= SymbolTag.DEPRECATED;
        }

        var range = Util.range_from_sourceref (symbol.source_reference);
        if (symbol.comment != null) {
            range = Util.range_union (
                Util.range_from_sourceref (symbol.comment.source_reference), range);
        }
        if (symbol is Subroutine && ((Subroutine) symbol).body != null) {
            range = Util.range_union (
                Util.range_from_sourceref (((Subroutine) symbol).body.source_reference), range);
        }

        return new CallHierarchyItem (
            symbol.get_full_name (),
            kind,
            Util.uri_from_filename (symbol.source_reference.file.filename),
            range,
            Util.range_from_sourceref (symbol.source_reference),
            CodeHelp.get_symbol_representation (null, symbol, null, true),
            tags);
    }

    Symbol? get_containing_sub_or_callable (CodeNode code_node) {
        for (var current_node = code_node.parent_node; current_node != null; current_node = current_node.parent_node) {
            if (current_node is Subroutine || current_node is Callable)
                return (Symbol)current_node;
        }
        return null;
    }

    CallHierarchyIncomingCall[] get_incoming_calls (Project project, Symbol callable) {
        var incoming_calls = new Gee.HashMap<Symbol, Gee.ArrayList<Range?>> ();
        Symbol[] symbols = {callable};
        if (callable is Method) {
            var method = (Method)callable;
            if (method.base_interface_method != method && method.base_interface_method != null)
                symbols += method.base_interface_method;
            else if (method.base_method != method && method.base_method != null)
                symbols += method.base_method;
        }
        // find all references to this callable
        var references = new Gee.HashMap<SourceRange, CodeNode> ();
        foreach (var symbol in symbols)
            foreach (var pair in SymbolReferences.get_compilations_using_symbol (project, symbol))
                foreach (SourceFile file in pair.first.code_context.get_source_files ())
                    SymbolReferences.list_in_file (file, pair.second, false, true, references);
        debug ("got %d references as incoming calls to %s (%s)", references.size, callable.to_string (), callable.type_name);
        foreach (var reference in references) {
            if (!(reference.value.parent_node is MethodCall || reference.value.parent_node is ObjectCreationExpression))
                continue;
            var container = get_containing_sub_or_callable (reference.value);
            if (container != null) {
                Gee.ArrayList<Range?> ranges;
                if (!incoming_calls.has_key (container)) {
                    ranges = new Gee.ArrayList<Range?> ();
                    incoming_calls[container] = ranges;
                } else {
                    ranges = incoming_calls[container];
                }
                ranges.add (reference.key.range);
            }
        }
        if (callable is Constructor) {
            var ctor = (Constructor)callable;
            if (ctor.this_parameter != null && ctor.this_parameter.variable_type is ObjectType) {
                var type_symbol = ((ObjectType)ctor.this_parameter.variable_type).object_type_symbol;
                foreach (var member in type_symbol.get_members ()) {
                    if (member is CreationMethod) {
                        var cm = (CreationMethod)member;
                        var ranges = new Gee.ArrayList<Range?> ();
                        ranges.add (Util.range_from_sourceref (
                            member.source_reference ?? type_symbol.source_reference));
                        incoming_calls[cm] = ranges;
                    }
                }
            }
        }
        CallHierarchyIncomingCall[] incoming = {};
        foreach (var item in incoming_calls) {
            Range[] ranges = {};
            foreach (var range in item.value)
                ranges += (!) range;
            incoming += new CallHierarchyIncomingCall (
                item_from_symbol (item.key), ranges);
        }
        return incoming;
    }

    CallHierarchyOutgoingCall[] get_outgoing_calls (Project project, Subroutine subroutine) {
        var outgoing_calls = new Gee.HashMap<Symbol, Gee.ArrayList<Range?>> ();
        Subroutine[] subroutines = {subroutine};
        // add all implementing symbols
        foreach (var pair in SymbolReferences.get_compilations_using_symbol (project, subroutine)) {
            var references = new Gee.HashMap<SourceRange, Vala.CodeNode> ();
            foreach (SourceFile file in pair.first.code_context.get_source_files ())
                SymbolReferences.list_implementations_of_virtual_symbol (file, pair.second, references);
            foreach (var node in references.values)
                if (node is Vala.Method)
                    subroutines += (Vala.Method)node;
        }
        // find all methods that are called in this method
        foreach (var current_sub in subroutines) {
            if (current_sub.source_reference != null && current_sub.body != null) {
                var finder = new NodeSearch.with_filter (current_sub.source_reference.file, current_sub,
                                                         (needle, node) => (node is MethodCall || node is ObjectCreationExpression)
                                                                        && get_containing_sub_or_callable (node) == needle);
                var result = new Gee.ArrayList<Vala.CodeNode> ();
                result.add_all (finder.result);
                foreach (var node in result) {
                    var call = (node is MethodCall) ? ((MethodCall)node).call : ((ObjectCreationExpression)node).member_name;
                    if (node.source_reference == null || call.symbol_reference.source_reference == null)
                        continue;
                    var called_item = SymbolReferences.find_real_symbol (project, call.symbol_reference);
                    Gee.ArrayList<Range?> ranges;
                    if (!outgoing_calls.has_key (called_item)) {
                        ranges = new Gee.ArrayList<Range?> ();
                        outgoing_calls[called_item] = ranges;
                    } else {
                        ranges = outgoing_calls[called_item];
                    }
                    ranges.add (Util.range_from_sourceref (node.source_reference));
                }
            }
        }
        CallHierarchyOutgoingCall[] outgoing = {};
        foreach (var item in outgoing_calls) {
            Range[] ranges = {};
            foreach (var range in item.value)
                ranges += (!) range;
            outgoing += new CallHierarchyOutgoingCall (
                item_from_symbol (item.key), ranges);
        }
        return outgoing;
    }
}
