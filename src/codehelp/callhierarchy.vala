/* implementmissingprereqsaction.vala
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
    Symbol? get_containing_sub_or_callable (CodeNode code_node) {
        for (var current_node = code_node.parent_node; current_node != null; current_node = current_node.parent_node) {
            if (current_node is Subroutine || current_node is Callable)
                return (Symbol)current_node;
        }
        return null;
    }

    CallHierarchyIncomingCall[] get_incoming_calls (Project project, Symbol callable) {
        var incoming_calls = new Gee.HashMap<Symbol, Gee.ArrayList<Range>> ();
        Symbol[] symbols = {callable};
        if (callable is Method) {
            var method = (Method)callable;
            if (method.base_interface_method != method && method.base_interface_method != null)
                symbols += method.base_interface_method;
            else if (method.base_method != method && method.base_method != null)
                symbols += method.base_method;
        }
        // find all references to this callable
        var references = new Gee.HashMap<Range, CodeNode> ();
        foreach (var symbol in symbols)
            foreach (var pair in SymbolReferences.get_compilations_using_symbol (project, symbol))
                foreach (var w in pair.first)
                    SymbolReferences.list_in_file (w.source_file, pair.second, false, true, references);
        debug ("got %d references as incoming calls to %s (%s)", references.size, callable.to_string (), callable.type_name);
        foreach (var reference in references) {
            if (!(reference.value.parent_node is MethodCall || reference.value.parent_node is ObjectCreationExpression))
                continue;
            var container = get_containing_sub_or_callable (reference.value);
            if (container != null) {
                Gee.ArrayList<Range> ranges;
                if (!incoming_calls.has_key (container)) {
                    ranges = new Gee.ArrayList<Range> ();
                    incoming_calls[container] = ranges;
                } else {
                    ranges = incoming_calls[container];
                }
                ranges.add (reference.key);
            }
        }
        if (callable is Constructor) {
            var ctor = (Constructor)callable;
            if (ctor.this_parameter != null && ctor.this_parameter.variable_type is ObjectType) {
                var type_symbol = ((ObjectType)ctor.this_parameter.variable_type).object_type_symbol;
                foreach (var member in type_symbol.get_members ()) {
                    if (member is CreationMethod) {
                        var cm = (CreationMethod)member;
                        incoming_calls[cm] = new Gee.ArrayList<Range>.wrap ({new Range.from_sourceref (member.source_reference ?? type_symbol.source_reference)});
                    }
                }
            }
        }
        CallHierarchyIncomingCall[] incoming = {};
        foreach (var item in incoming_calls) {
            incoming += new CallHierarchyIncomingCall () {
                from = new CallHierarchyItem.from_symbol (item.key),
                fromRanges = item.value
            };
        }
        return incoming;
    }

    CallHierarchyOutgoingCall[] get_outgoing_calls (Project project, Subroutine subroutine) {
        var outgoing_calls = new Gee.HashMap<Symbol, Gee.ArrayList<Range>> ();
        Subroutine[] subroutines = {subroutine};
        // add all implementing symbols
        foreach (var pair in SymbolReferences.get_compilations_using_symbol (project, subroutine)) {
            var references = new Gee.HashMap<Range, Vala.CodeNode> ();
            foreach (var w in pair.first)
                SymbolReferences.list_implementations_of_virtual_symbol (w.source_file, pair.second, references);
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
                    Gee.ArrayList<Range> ranges;
                    if (!outgoing_calls.has_key (called_item)) {
                        ranges = new Gee.ArrayList<Range> ();
                        outgoing_calls[called_item] = ranges;
                    } else {
                        ranges = outgoing_calls[called_item];
                    }
                    ranges.add (new Range.from_sourceref (node.source_reference));
                }
            }
        }
        CallHierarchyOutgoingCall[] outgoing = {};
        foreach (var item in outgoing_calls) {
            outgoing += new CallHierarchyOutgoingCall () {
                to = new CallHierarchyItem.from_symbol (item.key),
                fromRanges = item.value
            };
        }
        return outgoing;
    }
}
