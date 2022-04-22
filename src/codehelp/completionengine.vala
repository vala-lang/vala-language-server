/* completionengine.vala
 *
 * Copyright 2020 Princeton Ferro <princetonferro@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Lsp;
using Gee;

namespace Vls.CompletionEngine {
    /**
     * Get all available completions.
     */
    Collection<CompletionItem> complete (Server lang_serv, Project project,
                                         Jsonrpc.Client client, Variant id, string method,
                                         Vala.SourceFile doc, Compilation compilation,
                                         CompletionParams completion,
                                         Cancellable? cancellable) throws Error {
        cancellable.set_error_if_cancelled ();
        var pos = completion.position;

        bool is_pointer_access = false;
        long idx = (long) Util.get_string_pos (doc.content, pos.line, pos.character);

        Position end_pos = pos.dup ();
        bool is_member_access = false;
        bool is_null_safe_access = false;

        // move back to the nearest member access if there is one
        long lb_idx = idx;

        // first, move back to the character we just inserted
        lb_idx--;

        // next, move back to the first non-space
        while (lb_idx > 0 && doc.content[lb_idx].isspace ())
            lb_idx--;
        
        // now attempt to find a member access
        while (lb_idx >= 0 && !doc.content[lb_idx].isspace ()) {
            // if we're at a member access operator, we're done
            if ((lb_idx >= 1 &&
                 ((doc.content[lb_idx-1] == '-' && doc.content[lb_idx] == '>') ||
                  (doc.content[lb_idx-1] == '?' && doc.content[lb_idx] == '.'))) ||
                doc.content[lb_idx] == '.') {
                var new_pos = pos.translate (0, (int) (lb_idx - idx));
                // debug ("[%s] moved cursor back from '%c'@%s -> '%c'@%s",
                //     method, doc.content[idx], pos.to_string (), doc.content[lb_idx], new_pos.to_string ());
                idx = lb_idx;
                pos = new_pos;
                end_pos = pos.dup ();
                break;
            } else if (!doc.content[lb_idx].isalnum() && doc.content[lb_idx] != '_') {
                // if this character does not belong to an identifier, break
                // debug ("[%s] breaking, since we could not find a member access", method);
                // var new_pos = pos.translate (0, (int) (lb_idx - idx));
                // debug ("[%s] moved cursor back from '%c'@%s -> '%c'@%s",
                //     method, doc.content[idx], pos.to_string (), doc.content[lb_idx], new_pos.to_string ());
                break;
            }
            lb_idx--;
        }
        
        var completions = new HashSet<CompletionItem> ();

        if (idx >= 1 && doc.content[idx-1] == '-' && doc.content[idx] == '>') {
            is_pointer_access = true;
            is_member_access = true;
            // debug (@"[$method] found pointer access @ $pos");
            // pos = pos.translate (0, -2);
        } else if (idx >= 1 && doc.content[idx-1] == '?' && doc.content[idx] == '.') {
            is_null_safe_access = true;
            is_member_access = true;
            // debug (@"[$method] found null-safe member access @ $pos");
            // pos = pos.translate (0, -2);
        } else if (doc.content[idx] == '.') {
            // pos = pos.translate (0, -1);
            // debug ("[%s] found member access", method);
            is_member_access = true;
        } else {
            // The editor requested a member access completion from a '>'.
            // This is a hack since the LSP doesn't allow us to specify a trigger string ("->" in this case)
            if (completion.context != null && completion.context.triggerKind == CompletionTriggerKind.TriggerCharacter) {
                // completion conditions are not satisfied
                return completions;
            }
            // TODO: incomplete completions
        }

        Vala.CodeContext.push (compilation.context);
        if (is_member_access) {
            // attempt the very fast and accurate symbol extractor
            var se = new SymbolExtractor (pos, doc);
            if (se.extracted_expression != null)
                show_members (lang_serv, project, doc, compilation,
                              is_null_safe_access, is_pointer_access, se.in_oce,
                              se.extracted_expression, se.block.scope, completions, false);

            if (completions.is_empty) {
                // fall back to using the incomplete AST
                show_members_from_ast (lang_serv, project,
                                       client, id, 
                                       doc, compilation, 
                                       is_null_safe_access, is_pointer_access,
                                       pos, end_pos, completions);
            }
        } else {
            Vala.Scope best_scope;
            Vala.Symbol nearest_symbol;
            /**
             * The expression inside a Vala `with(<expr>) { ... }` statement.
             */
            Vala.Expression? nearest_with_expression;
            bool in_loop;
            bool showing_override_suggestions = false;
            walk_up_current_scope (lang_serv, doc, pos, out best_scope, out nearest_symbol, out nearest_with_expression, out in_loop);
            if (nearest_with_expression != null) {
                show_members (lang_serv, project, doc, compilation, false, false, false, nearest_with_expression, best_scope, completions);
            }
            if (nearest_symbol is Vala.Class) {
                var results = CodeHelp.gather_missing_prereqs_and_unimplemented_symbols ((Vala.Class) nearest_symbol);
                // TODO: use missing prereqs (results.first)
                list_implementable_symbols (lang_serv, project, compilation, doc, (Vala.Class) nearest_symbol, best_scope, results.second, completions);
                showing_override_suggestions = !completions.is_empty;
            }
            if (nearest_symbol is Vala.ObjectTypeSymbol) {
                list_implementable_symbols (lang_serv, project, compilation, doc,
                                            (Vala.ObjectTypeSymbol) nearest_symbol, best_scope,
                                            CodeHelp.gather_base_virtual_symbols_not_overridden ((Vala.ObjectTypeSymbol) nearest_symbol),
                                            completions);
            }
            if (!showing_override_suggestions) {
                list_symbols (lang_serv, project, compilation, doc, pos, best_scope, completions, (new SymbolExtractor (pos, doc)).in_oce);
                list_keywords (lang_serv, doc, nearest_symbol, in_loop, completions);
            }
        }
        Vala.CodeContext.pop ();
        return completions;
    }

    void walk_up_current_scope (Server lang_serv, 
                                Vala.SourceFile doc, Position pos, 
                                out Vala.Scope best_scope, out Vala.Symbol nearest_symbol,
                                out Vala.Expression? nearest_with_expression,
                                out bool in_loop) {
        best_scope = new FindScope (doc, pos).best_block.scope;
        in_loop = false;
        nearest_symbol = null;
        nearest_with_expression = null;
        for (Vala.Scope? scope = best_scope; 
             scope != null; 
             scope = scope.parent_scope) {
            Vala.Symbol owner = scope.owner;
            if (owner.parent_node is Vala.WhileStatement ||
                owner.parent_node is Vala.ForStatement ||
                owner.parent_node is Vala.ForeachStatement ||
                owner.parent_node is Vala.DoStatement ||
                owner.parent_node is Vala.Loop)
                in_loop = true;
#if VALA_0_50
            if (nearest_with_expression == null && owner.parent_node is Vala.WithStatement)
                nearest_with_expression = ((Vala.WithStatement)owner.parent_node).expression;
#endif

            if (owner is Vala.Callable || owner is Vala.Statement || owner is Vala.Block || 
                owner is Vala.Subroutine) {
                if (owner is Vala.Method) {
                    if (nearest_symbol == null)
                        nearest_symbol = owner;
                }
            } else if (owner is Vala.TypeSymbol) {
                if (nearest_symbol == null)
                    nearest_symbol = owner;
            } else if (owner is Vala.Namespace) {
                if (nearest_symbol == null)
                    nearest_symbol = owner;
            }
        }

        if (nearest_symbol == null)
            nearest_symbol = best_scope.owner;
    }

    /**
     * Fill the completion list with all scope-visible symbols
     */
    void list_symbols (Server lang_serv, Project project,
                       Compilation compilation,
                       Vala.SourceFile doc, Position pos, 
                       Vala.Scope best_scope, 
                       Set<CompletionItem> completions,
                       bool in_oce) {
        string method = "textDocument/completion";
        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (doc);
        bool in_instance = false;
        bool inside_static_or_class_construct_block = false;
        var seen_props = new HashSet<string> ();

        // if (best_scope.owner.source_reference != null)
        //     debug (@"[$method] best scope SR is $(best_scope.owner.source_reference)");
        // else
        //     debug (@"[$method] listing symbols from $(best_scope.owner)");
        for (Vala.Scope? current_scope = best_scope;
                current_scope != null;
                current_scope = current_scope.parent_scope) {
            Vala.Symbol owner = current_scope.owner;
            if (owner is Vala.Callable || owner is Vala.Statement || owner is Vala.Block || 
                owner is Vala.Subroutine) {
                Vala.Parameter? this_param = null;
                if (owner is Vala.Method)
                    this_param = ((Vala.Method)owner).this_parameter;
                else if (owner is Vala.PropertyAccessor)
                    this_param = ((Vala.PropertyAccessor)owner).prop.this_parameter;
                else if (owner is Vala.Constructor)
                    this_param = ((Vala.Constructor)owner).this_parameter;
                else if (owner is Vala.Destructor)
                    this_param = ((Vala.Destructor)owner).this_parameter;
                in_instance = this_param != null;
                if (in_instance) {
                    string instance_type_string = "type";
                    Vala.DataType? base_type = null;

                    if (this_param.variable_type != null && this_param.variable_type.type_symbol is Vala.Class) {
                        foreach (var class_base_type in ((Vala.Class)this_param.variable_type.type_symbol).get_base_types ())
                            if (class_base_type.type_symbol is Vala.Class) {
                                base_type = class_base_type;
                                break;
                            }
                        instance_type_string = "class";
                    } else if (this_param.variable_type != null && this_param.variable_type.type_symbol is Vala.Struct) {
                        base_type = ((Vala.Struct)this_param.variable_type.type_symbol).base_type;
                        instance_type_string = "struct";
                    } else {
                        // this_param can't be anything else
                    }

                    // add `this' parameter
                    completions.add (new CompletionItem.from_symbol (
                                        null, 
                                        this_param, 
                                        current_scope,
                                        CompletionItemKind.Keyword, 
                                        new DocComment (@"Access the current instance of this $instance_type_string")));

                    // add `base` parameter if this is a subtype
                    if (base_type != null) {
                        completions.add (new CompletionItem.from_synthetic_symbol (base_type,
                                                                                   "base",
                                                                                   current_scope,
                                                                                   CompletionItemKind.Keyword,
                                                                                   new DocComment (@"Accesses the base $instance_type_string")));
                    }
                }
                var symtab = current_scope.get_symbol_table ();
                if (symtab != null) {
                    foreach (Vala.Symbol sym in symtab.get_values ()) {
                        if (sym.name == null || sym.name[0] == '.')
                            continue;
                        var sr = sym.source_reference;
                        if (sr == null)
                            continue;
                        var sr_begin = new Position.from_libvala (sr.begin);

                        // don't show local variables that are declared ahead of the cursor
                        if (sr_begin.compare_to (pos) > 0)
                            continue;
                        completions.add (new CompletionItem.from_symbol (null, sym, current_scope,
                            (sym is Vala.Constant) ? CompletionItemKind.Constant : CompletionItemKind.Variable,
                            lang_serv.get_symbol_documentation (project, sym)));
                    }
                }

                // Show `class` methods for static/class constructor blocks.
                // These members should only be referenced implicitly from the
                // subclass, or from an explicit class access expression.
                if (owner is Vala.Constructor && ((Vala.Constructor)owner).binding != Vala.MemberBinding.INSTANCE)
                    inside_static_or_class_construct_block = true;
            } else if (owner is Vala.TypeSymbol) {
                if (in_instance)
                    add_completions_for_type (lang_serv, project, code_style, Vala.SemanticAnalyzer.get_data_type_for_symbol (owner), (Vala.TypeSymbol) owner, completions, best_scope, in_oce, false, seen_props);
                // always show static members
                add_completions_for_type (lang_serv, project, code_style, null, (Vala.TypeSymbol) owner, completions, best_scope, in_oce, false, seen_props);
                // suggest class members to implicitly access
                if ((in_instance || inside_static_or_class_construct_block) && owner is Vala.Class)
                    add_completions_for_class_access (lang_serv, project, code_style, (Vala.Class) owner, best_scope, completions);
                // once we leave a type symbol, we're no longer in an instance
                in_instance = false;
            } else if (owner is Vala.Namespace) {
                add_completions_for_ns (lang_serv, project, code_style, (Vala.Namespace) owner, best_scope, completions, in_oce);
            } else {
                debug (@"[$method] ignoring owner ($owner) ($(owner.type_name)) of scope");
            }
        }
        // show members of all imported namespaces
        foreach (var ud in doc.current_using_directives) {
            if (ud.namespace_symbol is Vala.Namespace)
                add_completions_for_ns (lang_serv, project, code_style, (Vala.Namespace) ud.namespace_symbol, best_scope, completions, in_oce);
        }
    }

    /**
     * Fill the completion list with keywords.
     */
    void list_keywords (Server lang_serv,
                        Vala.SourceFile doc, 
                        Vala.Symbol? nearest_symbol, bool in_loop, 
                        Set<CompletionItem> completions) {
        if (nearest_symbol is Vala.TypeSymbol) {
            completions.add_all_array({
                new CompletionItem.keyword ("async"),
                new CompletionItem.keyword ("override"),
                new CompletionItem.keyword ("protected"),
                new CompletionItem.keyword ("weak"),
            });
        }

        if (nearest_symbol is Vala.Namespace) {
            completions.add_all_array ({
                new CompletionItem.keyword ("delegate"),
                new CompletionItem.keyword ("errordomain", "errordomain $0"),
                new CompletionItem.keyword ("internal"),
                new CompletionItem.keyword ("namespace", "namespace $0"),
                new CompletionItem.keyword ("params"),
                new CompletionItem.keyword ("private"),
                new CompletionItem.keyword ("public"),
                new CompletionItem.keyword ("unowned"),
                new CompletionItem.keyword ("void"),
            });
        }

        if (nearest_symbol is Vala.Namespace || nearest_symbol is Vala.ObjectTypeSymbol) {
            completions.add_all_array ({
                new CompletionItem.keyword ("abstract"),
                new CompletionItem.keyword ("class", "class $0"),
                new CompletionItem.keyword ("enum", "enum $0"),
                new CompletionItem.keyword ("interface", "interface $0"),
                new CompletionItem.keyword ("struct", "struct $0"),
                new CompletionItem.keyword ("throws", "throws $0"),
                new CompletionItem.keyword ("virtual")
            });
        }

        if (nearest_symbol is Vala.Callable) {
            completions.add_all_array ({
                new CompletionItem.keyword ("catch", "catch ($1) {$2}$0"),
                new CompletionItem.keyword ("delete", "delete $1;$0"),
                new CompletionItem.keyword ("do", "do {$2} while (${1:<condition>});$0"),
                new CompletionItem.keyword ("else"),
                new CompletionItem.keyword ("else if", "else if (${1:<condition>})$0"),
                new CompletionItem.keyword ("finally", "finally {$1}$0"),
                new CompletionItem.keyword ("false"),
                new CompletionItem.keyword ("for", "for (${3:var} ${1:i} = ${2:<expression>}; ${4:<condition>}; ${5:<expression>})$0"),
                new CompletionItem.keyword ("foreach", "foreach (${3:var} ${1:item} in ${2:<expression>})$0"),
                new CompletionItem.keyword ("if", "if (${1:<condition>})$0"),
                new CompletionItem.keyword ("in", "in ${1:<expression>}$0"),
                new CompletionItem.keyword ("is", "is ${1:<type>}$0"),
                new CompletionItem.keyword ("new"),
                new CompletionItem.keyword ("null"),
                new CompletionItem.keyword ("return", "return ${1:<expression>};$0"),
                new CompletionItem.keyword ("switch", "switch (${1:<expression>}) {$0}"),
                new CompletionItem.keyword ("throw"),
                new CompletionItem.keyword ("true"),
                new CompletionItem.keyword ("try", "try {$1} catch ($2) {$3}$0"),
                new CompletionItem.keyword ("var", "var ${1:<var-name>} = $0"),
                new CompletionItem.keyword ("while", "while (${1:<condition>})$0"),
#if VALA_0_50
                new CompletionItem.keyword ("with", "with (${1:<expression>}) {$0}"),
#endif
                new CompletionItem.keyword ("yield"),
            });
        }

        if (nearest_symbol == Vala.CodeContext.get ().root)
            completions.add (new CompletionItem.keyword ("using", "using ${1:<namespace>};$0"));
        
        if (in_loop) {
            completions.add_all_array ({
                new CompletionItem.keyword ("break"),
                new CompletionItem.keyword ("continue"),
            });
        }

        completions.add_all_array ({
            new CompletionItem.keyword ("global", "global::")
        });
    }

    /**
     * List symbols that to implement from base classes and interfaces.
     */
    void list_implementable_symbols (Server lang_serv, Project project, Compilation compilation,
                                     Vala.SourceFile doc, Vala.TypeSymbol type_symbol, Vala.Scope scope,
                                     Vala.List<Pair<Vala.DataType?, Vala.Symbol>> missing_symbols,
                                     Set<CompletionItem> completions) {
        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (doc);
        string spaces = " ";

        if (code_style != null)
            spaces = string.nfill (code_style.average_spacing_before_parens, ' ');

        foreach (var pair in missing_symbols) {
            var instance_type = pair.first;
            var sym = pair.second;
            var kind = CompletionItemKind.Method;

            if (sym is Vala.Property)
                kind = CompletionItemKind.Property;
            
            var label = new StringBuilder ();
            var insert_text = new StringBuilder ();

            label.append (sym.access.to_string ());
            label.append_c (' ');
            insert_text.append (sym.access.to_string ());
            insert_text.append_c (' ');

            if (sym.hides) {
                label.append ("new ");
                insert_text.append ("new ");
            }

            if (sym is Vala.Method && ((Vala.Method)sym).coroutine) {
                label.append ("async ");
                insert_text.append ("async ");
            }

            if (sym is Vala.Method && CodeHelp.base_method_requires_override ((Vala.Method)sym) ||
                sym is Vala.Property && CodeHelp.base_property_requires_override ((Vala.Property)sym)) {
                label.append ("override ");
                insert_text.append ("override ");
            }

            Vala.DataType? return_type = null;
            if (sym is Vala.Callable)
                return_type = ((Vala.Callable)sym).return_type.get_actual_type (instance_type, null, null);
            else if (sym is Vala.Property)
                return_type = ((Vala.Property)sym).property_type.get_actual_type (instance_type, null, null);
            
            if (return_type != null) {
                string? return_type_representation = CodeHelp.get_data_type_representation (return_type, scope);
                label.append (return_type_representation);
                label.append_c (' ');
                insert_text.append (return_type_representation);
                insert_text.append_c (' ');
            } else {
                warning ("no return type for symbol %s", sym.name);
            }

            label.append (sym.name);
            insert_text.append (sym.name);

            // TODO: use prefix to avoid inserting part of the method signature
            // that has already been typed

            if (sym is Vala.Callable) {
                // display type arguments
                Vala.List<Vala.TypeParameter>? type_parameters = null;
                if (sym is Vala.Delegate)
                    type_parameters = ((Vala.Delegate)sym).get_type_parameters ();
                else if (sym is Vala.Method)
                    type_parameters = ((Vala.Method)sym).get_type_parameters ();
                
                if (type_parameters != null && !type_parameters.is_empty) {
                    label.append_c ('<');
                    insert_text.append_c ('<');
                    int i = 1;
                    foreach (var type_parameter in type_parameters) {
                        if (i > 1) {
                            label.append_c (',');
                            insert_text.append_c (',');
                        }
                        label.append (type_parameter.name);
                        insert_text.append (type_parameter.name);
                    }
                    label.append_c ('>');
                    insert_text.append_c ('>');
                }

                label.append (spaces);
                insert_text.append (spaces);

                label.append_c ('(');
                insert_text.append_c ('(');
                int i = 1;
                foreach (Vala.Parameter param in ((Vala.Callable) sym).get_parameters ()) {
                    if (i > 1) {
                        insert_text.append (", ");
                        label.append (", ");
                    }
                    insert_text.append (CodeHelp.get_symbol_representation (instance_type, param, scope, false, null, "${" + @"$i:$(param.name)}"));
                    label.append (CodeHelp.get_symbol_representation (instance_type, param, scope, false));
                    i++;
                }
                insert_text.append_c(')');
                label.append_c (')');
            } else if (sym is Vala.Property) {
                var prop = (Vala.Property)sym;
                label.append (" {");
                insert_text.append (" {");
                int count = 1;
                if (prop.get_accessor != null) {
                    if (prop.get_accessor.value_type is Vala.ReferenceType && prop.get_accessor.value_type.value_owned) {
                        label.append (" owned");
                        insert_text.append (" owned");
                    }
                    label.append (" get;");
                    insert_text.append_printf (" get${%d:;}", count);
                    count++;
                }
                if (prop.set_accessor != null) {
                    if (prop.set_accessor.value_type is Vala.ReferenceType && prop.set_accessor.value_type.value_owned) {
                        label.append (" owned");
                        insert_text.append (" owned");
                    }
                    label.append (" set;");
                    insert_text.append_printf (" set${%d:;}", count);
                    count++;
                }
                label.append (" }");
                insert_text.append (" }");
            }

            insert_text.append ("$0");
            completions.add (
                new CompletionItem.from_unimplemented_symbol (
                    sym, label.str, kind, insert_text.str, 
                    lang_serv.get_symbol_documentation (project, sym)
                ));
        }
    }

    /**
     * Fill the completion list with members of {@result}
     * If scope is null, the current scope will be calculated.
     */
    void show_members (Server lang_serv, Project project,
                       Vala.SourceFile doc, Compilation compilation,
                       bool is_null_safe_access, bool is_pointer_access, bool in_oce,
                       Vala.CodeNode result, Vala.Scope? scope, Set<CompletionItem> completions,
                       bool retry_inner = true) {
        string method = "textDocument/completion";
        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (doc) as CodeStyleAnalyzer;
        Vala.Scope current_scope = scope ?? CodeHelp.get_scope_containing_node (result);
        Vala.DataType? data_type = null;
        Vala.Symbol? symbol = null;
        // whether we are accessing `this` or `base` within a creation method
        bool is_cm_this_or_base_access = false;

        do {
            if (result is Vala.Expression) {
                data_type = ((Vala.Expression)result).value_type;
                symbol = ((Vala.Expression)result).symbol_reference;
                // walk up scopes, looking for a creation method
                Vala.CreationMethod? cm = null;
                for (var cm_scope = current_scope; cm_scope != null && cm == null; cm_scope = cm_scope.parent_scope)
                    cm = cm_scope.owner as Vala.CreationMethod;
                is_cm_this_or_base_access = cm != null &&
                    (result is Vala.BaseAccess || 
                        result is Vala.MemberAccess && 
                            ((Vala.MemberAccess)result).member_name == "this" && 
                            ((Vala.MemberAccess)result).inner == null);
            } else if (result is Vala.Symbol) {
                symbol = (Vala.Symbol) result;
            }

            if (data_type != null && data_type.type_symbol != null &&
                (data_type is Vala.PointerType == is_pointer_access) &&
                (!in_oce || !(is_null_safe_access || is_pointer_access)))
                add_completions_for_type (lang_serv, project, code_style, data_type, data_type.type_symbol, completions, current_scope, in_oce, is_cm_this_or_base_access);
            else if (symbol is Vala.Signal && !(is_null_safe_access || is_pointer_access))
                add_completions_for_signal (code_style, data_type, (Vala.Signal) symbol, current_scope, completions);
            else if (symbol is Vala.Namespace && !(is_null_safe_access || is_pointer_access))
                add_completions_for_ns (lang_serv, project, code_style, (Vala.Namespace) symbol, current_scope, completions, in_oce);
            else if (symbol is Vala.Method && ((Vala.Method) symbol).coroutine && !(is_null_safe_access || is_pointer_access))
                add_completions_for_async_method (code_style, data_type, (Vala.Method) symbol, current_scope, completions);
            else if (data_type is Vala.ArrayType && !is_pointer_access)
                add_completions_for_array_type (code_style, (Vala.ArrayType) data_type, current_scope, completions);
            else if (symbol is Vala.TypeSymbol && !(is_null_safe_access || is_pointer_access))
                add_completions_for_type (lang_serv, project, code_style, null, (Vala.TypeSymbol)symbol, completions, current_scope, in_oce, is_cm_this_or_base_access);
            else {
                if (result is Vala.MemberAccess &&
                    ((Vala.MemberAccess)result).inner != null &&
                    // don't try inner if the outer expression already has a symbol reference
                    ((Vala.MemberAccess)result).inner.symbol_reference == null &&
                    // don't try inner if the MemberAccess was generted by SymbolExtractor
                    retry_inner) {
                    result = ((Vala.MemberAccess)result).inner;
                    debug (@"[$method] trying MemberAccess.inner");
                    // (new Object ()).
                    in_oce = false;
                    // maybe our expression was wrapped in extra parentheses:
                    // (x as T). for example
                    continue;
                }
                if (result is Vala.ObjectCreationExpression &&
                    ((Vala.ObjectCreationExpression)result).member_name != null) {
                    result = ((Vala.ObjectCreationExpression)result).member_name;
                    debug (@"[$method] trying ObjectCreationExpression.member_name");
                    in_oce = true;
                    // maybe our object creation expression contains a member access
                    // from a namespace or some other type
                    // new Vls. for example
                    continue;
                }
                if (is_pointer_access && data_type is Vala.PointerType) {
                    // unwrap pointer type
                    var base_type = ((Vala.PointerType)data_type).base_type;
                    debug (@"[$method] unwrapping data type $data_type => $base_type");
                    result = base_type;
                    data_type = base_type;
                    is_pointer_access = false;
                    continue;
                }
                debug ("[%s] could not get datatype for %s", method,
                        result == null ? "(null)" : @"($(result.type_name)) $result");
            }
            break;      // break by default
        } while (true);
    }

    /**
     * Use a node from the incomplete AST to generate completions, which may be
     * less accurate than the symbol extractor, but may be more accurate in
     * some edge cases.
     */
    void show_members_from_ast (Server lang_serv, Project project,
                                Jsonrpc.Client client, Variant id,
                                Vala.SourceFile doc, Compilation compilation,
                                bool is_null_safe_access, bool is_pointer_access,
                                Position pos, Position? end_pos, Set<CompletionItem> completions) {
        string method = "textDocument/completion";
        // debug (@"[$method] FindSymbol @ $pos" + (end_pos != null ? @" -> $end_pos" : ""));
        Vala.CodeContext.push (compilation.context);

        var fs = new NodeSearch (doc, pos, true, end_pos);

        if (fs.result.size == 0) {
            debug (@"[$method] no results found for member access");
            Vala.CodeContext.pop ();
            return;
        }
        
        bool in_oce = false;

        foreach (var res in fs.result) {
            // debug (@"[$method] found $(res.type_name) (semanalyzed = $(res.checked))");
            in_oce |= res is Vala.ObjectCreationExpression;
        }

        Vala.CodeNode result = Server.get_best (fs, doc);
        show_members (lang_serv, project, doc, compilation, is_null_safe_access, is_pointer_access, in_oce, result, null, completions);
        Vala.CodeContext.pop ();
    }

    /**
     * Determines whether the completion engine should suggest a particular
     * method when the expression is a {@link Vala.ObjectTypeSymbol} or
     * {@link Vala.Struct}.
     */
    bool should_show_method_for_object_or_struct (Vala.TypeSymbol type_symbol,
                                                  Vala.Method method_sym, Vala.Scope current_scope,
                                                  bool is_instance, bool in_oce,
                                                  bool is_cm_this_or_base_access) {
        if (method_sym.name == ".new") {
            return false;
        } else if (is_instance && !in_oce) {
            // for instance symbols, show only instance members
            // except for creation methods, which are treated as instance members
            if (!method_sym.is_instance_member () || method_sym is Vala.CreationMethod && !is_cm_this_or_base_access)
                return false;
        } else if (in_oce) {
            // only show creation methods for non-instance symbols within an OCE
            if (!(method_sym is Vala.CreationMethod))
                return false;
        } else /* if (!is_instance) */ {
            // for non-instance object symbols, only show static methods
            // for non-instance struct symbols, show static methods and creation methods
            if (!(type_symbol is Vala.Struct && method_sym is Vala.CreationMethod) && method_sym.binding != Vala.MemberBinding.STATIC)
                return false;
        }
        // check whether the symbol is accessible
        if (!CodeHelp.is_symbol_accessible (method_sym, current_scope))
            return false;
        return true;
    }

    /**
     * Generate insert text for a class, struct, or interface
     */
    string? generate_insert_text_for_type_symbol (Vala.TypeSymbol type_symbol,
                                                  Vala.Scope? current_scope, uint method_spaces) {
        Vala.List<Vala.TypeParameter>? type_parameters = null;

        if (type_symbol is Vala.ObjectTypeSymbol)
            type_parameters = ((Vala.ObjectTypeSymbol)type_symbol).get_type_parameters ();
        else if (type_symbol is Vala.Struct)
            type_parameters = ((Vala.Struct)type_symbol).get_type_parameters ();
        else if (type_symbol is Vala.Delegate)
            type_parameters = ((Vala.Delegate)type_symbol).get_type_parameters ();

        if (type_parameters == null || type_parameters.is_empty)
            return null;

        var builder = new StringBuilder (type_symbol.name);
        builder.append_c ('<');
        uint p = 0;
        foreach (var type_parameter in type_parameters) {
            if (p > 0)
                builder.append (", ");
            builder.append_printf ("${%u:%s}", p + 1, type_parameter.name);
            p++;
        }
        builder.append_c ('>');
        builder.append ("$0");
        return builder.str;
    }

    string? generate_insert_text_for_callable (Vala.DataType? type, Vala.Callable callable_sym,
                                               Vala.Scope? current_scope, uint method_spaces,
                                               string? symbol_override = null) {
        var builder = new StringBuilder ();

        if (callable_sym.name == ".new") {
            if (callable_sym.parent_symbol == null) {
                warning ("parent is null for %s()", callable_sym.name);
                return null;
            }
            builder.append (symbol_override ?? callable_sym.parent_symbol.name);

            if (callable_sym.parent_symbol is Vala.ObjectTypeSymbol && ((Vala.ObjectTypeSymbol) callable_sym.parent_symbol).has_type_parameters ()) {
                uint num_parameters = callable_sym.get_parameters ().size;

                builder.append_c ('<');
                uint p = 0;
                foreach (var type_parameter in ((Vala.ObjectTypeSymbol) callable_sym.parent_symbol).get_type_parameters ()) {
                    if (p > 0)
                        builder.append (", ");
                    builder.append_printf ("${%u:%s}", num_parameters + p + 1, type_parameter.name);
                    p++;
                }
                builder.append_c ('>');
            }
        } else {
            builder.append (symbol_override ?? callable_sym.name);

            var method_sym = callable_sym as Vala.Method;
            if (method_sym != null && method_sym.has_type_parameters ()) {
                uint num_parameters = callable_sym.get_parameters ().size;

                builder.append_c ('<');
                uint p = 0;
                foreach (var type_parameter in method_sym.get_type_parameters ()) {
                    if (p > 0)
                        builder.append (", ");
                    builder.append_printf ("${%u:%s}", num_parameters + p + 1, type_parameter.name);
                    p++;
                }
                builder.append_c ('>');
            }
        }

        builder.append (string.nfill (method_spaces, ' '));
        builder.append_c ('(');

        uint p = 0;
        Func<Vala.Parameter> serialize_parameter = (parameter) => {
            if (p > 0)
                builder.append (", ");
            if (parameter.direction == Vala.ParameterDirection.OUT)
                builder.append ("out ");
            else if (parameter.direction == Vala.ParameterDirection.REF)
                builder.append ("ref ");
            builder.append_printf ("${%u:%s}", p + 1, CodeHelp.get_symbol_representation (type, parameter, current_scope, false, null, null, false, false, null, false));
            p++;
        };

        if (symbol_override == "begin" && callable_sym is Vala.Method && ((Vala.Method)callable_sym).coroutine) {
            foreach (var parameter in ((Vala.Method)callable_sym).get_async_begin_parameters ())
                serialize_parameter (parameter);
        } else {
            foreach (var parameter in callable_sym.get_parameters ())
                serialize_parameter (parameter);
        }
        builder.append_c (')');
        builder.append ("$0");

        return builder.str;
    }

    /**
     * List all relevant members of a type. This is where completion options are generated.
     *
     * @param is_cm_this_or_base_access     Whether we are accessing `this` or `base` within a creation method.
     */
    void add_completions_for_type (Server lang_serv, Project project,
                                   CodeStyleAnalyzer? code_style,
                                   Vala.DataType? type, 
                                   Vala.TypeSymbol type_symbol,
                                   Set<CompletionItem> completions, 
                                   Vala.Scope current_scope,
                                   bool in_oce,
                                   bool is_cm_this_or_base_access,
                                   Set<string> seen_props = new HashSet<string> (),
                                   Set<Vala.TypeSymbol> seen_type_symbols = new HashSet<Vala.TypeSymbol> ()) {
        if (type_symbol in seen_type_symbols)
            return;     // bail out for recursive types
        seen_type_symbols.add (type_symbol);
        bool is_instance = type != null;
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;
        if (type_symbol is Vala.ObjectTypeSymbol) {
            /**
             * Complete the members of this object, such as the fields,
             * properties, and methods.
             */
            var object_sym = (Vala.ObjectTypeSymbol) type_symbol;

            // debug (@"type symbol is object $(object_sym.name) (is_instance = $is_instance, in_oce = $in_oce)");

            foreach (var method_sym in object_sym.get_methods ()) {
                if (!should_show_method_for_object_or_struct (type_symbol,
                        method_sym,
                        current_scope,
                        is_instance,
                        in_oce,
                        is_cm_this_or_base_access))
                    continue;
                var completion = new CompletionItem.from_symbol (type, method_sym, current_scope,
                    (method_sym is Vala.CreationMethod) ? CompletionItemKind.Constructor : CompletionItemKind.Method, 
                    lang_serv.get_symbol_documentation (project, method_sym));
                completion.insertText = generate_insert_text_for_callable (type, method_sym, current_scope, method_spaces);
                completion.insertTextFormat = InsertTextFormat.Snippet;
                completions.add (completion);
            }

            if (!in_oce) {
                foreach (var field_sym in object_sym.get_fields ()) {
                    if (field_sym.name[0] == '_' && seen_props.contains (field_sym.name[1:field_sym.name.length])
                        || field_sym.is_instance_member () != is_instance
                        || !CodeHelp.is_symbol_accessible (field_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (type, field_sym, current_scope, CompletionItemKind.Field, lang_serv.get_symbol_documentation (project, field_sym)));
                }
            }

            if (!in_oce && is_instance) {
                foreach (var signal_sym in object_sym.get_signals ()) {
                    if (signal_sym.is_instance_member () != is_instance 
                        || !CodeHelp.is_symbol_accessible (signal_sym, current_scope))
                        continue;
                    // generate one completion for invoking the signal and another without, for member access
                    completions.add (new CompletionItem.from_symbol (type, signal_sym, current_scope, CompletionItemKind.Event, lang_serv.get_symbol_documentation (project, signal_sym)));
                    var emitter_documentation = lang_serv.get_symbol_documentation (project, signal_sym);
                    if (emitter_documentation != null)
                        emitter_documentation.body = "_(Invokes this signal)_\n\n" + emitter_documentation.body;
                    completions.add (new CompletionItem.from_symbol (type, signal_sym, 
                                                                     current_scope, 
                                                                     CompletionItemKind.Method, 
                                                                     emitter_documentation) {
                        insertText = generate_insert_text_for_callable (type, signal_sym, current_scope, method_spaces),
                        insertTextFormat = InsertTextFormat.Snippet
                    });
                }

                foreach (var prop_sym in object_sym.get_properties ()) {
                    if (prop_sym.is_instance_member () != is_instance
                        || !CodeHelp.is_symbol_accessible (prop_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (type, prop_sym, current_scope, CompletionItemKind.Property, lang_serv.get_symbol_documentation (project, prop_sym)));
                    seen_props.add (prop_sym.name);
                }
            }

            // get inner types and constants
            if (!is_instance && !in_oce) {
                foreach (var constant_sym in object_sym.get_constants ()) {
                    if (!CodeHelp.is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (type, constant_sym, current_scope, CompletionItemKind.Constant, lang_serv.get_symbol_documentation (project, constant_sym)));
                }

                foreach (var enum_sym in object_sym.get_enums ())
                    completions.add (new CompletionItem.from_symbol (type, enum_sym, current_scope, CompletionItemKind.Enum, lang_serv.get_symbol_documentation (project, enum_sym)));

                foreach (var delegate_sym in object_sym.get_delegates ())
                    completions.add (new CompletionItem.from_symbol (type, delegate_sym, current_scope, CompletionItemKind.Interface, lang_serv.get_symbol_documentation (project, delegate_sym)));
            }

            // if we're inside an OCE (which are treated as instances), get only inner types
            if (!is_instance || in_oce) {
                foreach (var class_sym in object_sym.get_classes ())
                    add_class_completion (lang_serv, project, code_style, class_sym, current_scope, in_oce, completions);

                foreach (var iface_sym in object_sym.get_interfaces ())
                    completions.add (new CompletionItem.from_symbol (type, iface_sym, current_scope, CompletionItemKind.Interface, lang_serv.get_symbol_documentation (project, iface_sym)));

                foreach (var struct_sym in object_sym.get_structs ())
                    completions.add (new CompletionItem.from_symbol (type, struct_sym, current_scope, CompletionItemKind.Struct, lang_serv.get_symbol_documentation (project, struct_sym)));
            }

            // get instance members of supertypes
            if (is_instance && !in_oce) {
                if (object_sym is Vala.Class) {
                    var class_sym = (Vala.Class) object_sym;
                    foreach (var base_type in class_sym.get_base_types ())
                        add_completions_for_type (lang_serv, project, code_style, type, base_type.type_symbol,
                                                  completions, current_scope, in_oce, false, seen_props, seen_type_symbols);
                }
                if (object_sym is Vala.Interface) {
                    var iface_sym = (Vala.Interface) object_sym;
                    foreach (var base_type in iface_sym.get_prerequisites ())
                        add_completions_for_type (lang_serv, project, code_style, type, base_type.type_symbol,
                                                  completions, current_scope, in_oce, false, seen_props, seen_type_symbols);
                }
            }
        } else if (type_symbol is Vala.Enum) {
            /**
             * Complete members of this enum, such as the values, methods,
             * and constants.
             */
            var enum_sym = (Vala.Enum) type_symbol;

            foreach (var method_sym in enum_sym.get_methods ()) {
                if (method_sym.is_instance_member () != is_instance
                    || !CodeHelp.is_symbol_accessible (method_sym, current_scope))
                    continue;
                var completion = new CompletionItem.from_symbol (type, method_sym, current_scope, CompletionItemKind.Method, lang_serv.get_symbol_documentation (project, method_sym));
                completion.insertText = generate_insert_text_for_callable (type, method_sym, current_scope, method_spaces);
                completion.insertTextFormat = InsertTextFormat.Snippet;
                completions.add (completion);
            }

            if (!is_instance) {
                foreach (var constant_sym in enum_sym.get_constants ()) {
                    if (!CodeHelp.is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (type, constant_sym, current_scope, CompletionItemKind.Constant, lang_serv.get_symbol_documentation (project, constant_sym)));
                }
                foreach (var value_sym in enum_sym.get_values ())
                    completions.add (new CompletionItem.from_symbol (type, value_sym, current_scope, CompletionItemKind.EnumMember, lang_serv.get_symbol_documentation (project, value_sym)));
            }
        } else if (type_symbol is Vala.ErrorDomain) {
            /**
             * Get all the members of the error domain, such as the error
             * codes and the methods.
             */
            var errdomain_sym = (Vala.ErrorDomain) type_symbol;

            foreach (var code_sym in errdomain_sym.get_codes ()) {
                // error codes are treated as non-instance members, but if we're in an OCE they
                // can also be used as pseudo-creation methods
                if (code_sym.is_instance_member () != is_instance && !in_oce)
                    continue;
                completions.add (new CompletionItem.from_symbol (type, code_sym, current_scope, CompletionItemKind.Value, lang_serv.get_symbol_documentation (project, code_sym)));
            }

            if (!in_oce) {
                foreach (var method_sym in errdomain_sym.get_methods ()) {
                    if (method_sym.is_instance_member () != is_instance
                        || !CodeHelp.is_symbol_accessible (method_sym, current_scope))
                        continue;
                    var completion = new CompletionItem.from_symbol (type, method_sym, current_scope, CompletionItemKind.Method, lang_serv.get_symbol_documentation (project, method_sym));
                    completion.insertText = generate_insert_text_for_callable (type, method_sym, current_scope, method_spaces);
                    completion.insertTextFormat = InsertTextFormat.Snippet;
                    completions.add (completion);
                }
            }

            if (is_instance && !in_oce) {
                Vala.Scope topmost = get_topmost_scope (current_scope);

                Vala.Symbol? gerror_sym = topmost.lookup ("GLib");
                if (gerror_sym != null) {
                    gerror_sym = gerror_sym.scope.lookup ("Error");
                    if (gerror_sym == null || !(gerror_sym is Vala.Class))
                        warning ("GLib.Error not found");
                    else
                        add_completions_for_type (lang_serv, project, code_style,
                            type, (Vala.TypeSymbol) gerror_sym, completions, 
                            current_scope, in_oce, false, seen_props, seen_type_symbols);
                } else
                    warning ("GLib not found");
            }
        } else if (type_symbol is Vala.Struct) {
            /**
             * Gets all of the members of the struct.
             */
            var struct_sym = (Vala.Struct) type_symbol;

            foreach (var field_sym in struct_sym.get_fields ()) {
                // struct fields are always public
                if (field_sym.is_instance_member () != is_instance)
                    continue;
                completions.add (new CompletionItem.from_symbol (type, field_sym, current_scope, CompletionItemKind.Field, lang_serv.get_symbol_documentation (project, field_sym)));
            }

            foreach (var method_sym in struct_sym.get_methods ()) {
                if (!should_show_method_for_object_or_struct (type_symbol,
                        method_sym,
                        current_scope,
                        is_instance,
                        in_oce,
                        is_cm_this_or_base_access))
                    continue;
                var completion = new CompletionItem.from_symbol (type, method_sym, current_scope, CompletionItemKind.Method, lang_serv.get_symbol_documentation (project, method_sym));
                completion.insertText = generate_insert_text_for_callable (type, method_sym, current_scope, method_spaces);
                completion.insertTextFormat = InsertTextFormat.Snippet;
                completions.add (completion);
            }

            foreach (var prop_sym in struct_sym.get_properties ()) {
                if (prop_sym.is_instance_member () != is_instance
                    || !CodeHelp.is_symbol_accessible (prop_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (type, prop_sym, current_scope, CompletionItemKind.Property, lang_serv.get_symbol_documentation (project, prop_sym)));
            }

            if (!is_instance) {
                foreach (var constant_sym in struct_sym.get_constants ()) {
                    if (!CodeHelp.is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (type, constant_sym, current_scope, CompletionItemKind.Constant, lang_serv.get_symbol_documentation (project, constant_sym)));
                }
            }
        } else if (type_symbol is Vala.TypeParameter) {
            var typeparam_sym = (Vala.TypeParameter) type_symbol;
            var generic_type = new Vala.GenericType (typeparam_sym);
            completions.add (new CompletionItem.from_symbol (type, generic_type.get_member ("dup"), current_scope, CompletionItemKind.Field, new DocComment (@"a function that knows how to duplicate instances of $(typeparam_sym.name)")));
            completions.add (new CompletionItem.from_symbol (type, generic_type.get_member ("destroy"), current_scope, CompletionItemKind.Field, new DocComment (@"a function that knows how to destroy instances of $(typeparam_sym.name)")));
        } else {
            warning (@"other type symbol $type_symbol.\n");
        }
    }

    /**
     * Use this when we're completing members of a namespace.
     */
    void add_completions_for_ns (Server lang_serv, Project project, CodeStyleAnalyzer? code_style, Vala.Namespace ns, Vala.Scope scope, Set<CompletionItem> completions, bool in_oce) {
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;
        foreach (var class_sym in ns.get_classes ())
            add_class_completion (lang_serv, project, code_style, class_sym, scope, in_oce, completions);
        // this is outside of the OCE check because while we cannot create new instances of 
        // raw interfaces, it's possible for interfaces to contain instantiable types declared inside,
        // so that we would call `new Iface.Thing ()'
        foreach (var iface_sym in ns.get_interfaces ())
            completions.add (new CompletionItem.from_symbol (null, iface_sym, scope, CompletionItemKind.Interface, lang_serv.get_symbol_documentation (project, iface_sym)));
        foreach (var struct_sym in ns.get_structs ())
            completions.add (new CompletionItem.from_symbol (null, struct_sym, scope, CompletionItemKind.Struct, lang_serv.get_symbol_documentation (project, struct_sym)));
        foreach (var err_sym in ns.get_error_domains ())
            completions.add (new CompletionItem.from_symbol (null, err_sym, scope, CompletionItemKind.Enum, lang_serv.get_symbol_documentation (project, err_sym)));
        foreach (var ns_sym in ns.get_namespaces ())
            completions.add (new CompletionItem.from_symbol (null, ns_sym, scope, CompletionItemKind.Module, lang_serv.get_symbol_documentation (project, ns_sym)));
        if (!in_oce) {
            foreach (var const_sym in ns.get_constants ())
                completions.add (new CompletionItem.from_symbol (null, const_sym, scope, CompletionItemKind.Constant, lang_serv.get_symbol_documentation (project, const_sym)));
            foreach (var method_sym in ns.get_methods ()) {
                var completion = new CompletionItem.from_symbol (null, method_sym, scope, CompletionItemKind.Method, lang_serv.get_symbol_documentation (project, method_sym));
                completion.insertText = generate_insert_text_for_callable (null, method_sym, scope, method_spaces);
                completion.insertTextFormat = InsertTextFormat.Snippet;
                completions.add (completion);
            }
            foreach (var delg_sym in ns.get_delegates ())
                completions.add (new CompletionItem.from_symbol (null, delg_sym, scope, CompletionItemKind.Interface, lang_serv.get_symbol_documentation (project, delg_sym)));
            foreach (var enum_sym in ns.get_enums ())
                completions.add (new CompletionItem.from_symbol (null, enum_sym, scope, CompletionItemKind.Enum, lang_serv.get_symbol_documentation (project, enum_sym)));
            foreach (var field_sym in ns.get_fields ())
                completions.add (new CompletionItem.from_symbol (null, field_sym, scope, CompletionItemKind.Field, lang_serv.get_symbol_documentation (project, field_sym)));
        }
    }
    
    /**
     * Use this to complete members of a signal.
     */
    void add_completions_for_signal (CodeStyleAnalyzer? code_style, Vala.DataType? instance_type, Vala.Signal sig, Vala.Scope scope, Set<CompletionItem> completions) {
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;
        var sig_type = new Vala.SignalType (sig);
        completions.add_all_array (new CompletionItem []{
            new CompletionItem.from_symbol (instance_type, sig_type.get_member ("connect"), scope, CompletionItemKind.Method, 
                new DocComment ("Connect to signal")) {
                insertText = generate_insert_text_for_callable (instance_type, sig_type.get_member ("connect") as Vala.Method, scope, method_spaces),
                insertTextFormat = InsertTextFormat.Snippet
            },
            new CompletionItem.from_symbol (instance_type, sig_type.get_member ("connect_after"), scope, CompletionItemKind.Method,
                new DocComment ("Connect to signal after default handler")) {
                insertText = generate_insert_text_for_callable (instance_type, sig_type.get_member ("connect_after") as Vala.Method, scope, method_spaces),
                insertTextFormat = InsertTextFormat.Snippet
            },
            new CompletionItem.from_symbol (instance_type, sig_type.get_member ("disconnect"), scope, CompletionItemKind.Method,
                new DocComment ("Disconnect signal")) {
                insertText = generate_insert_text_for_callable (instance_type, sig_type.get_member ("disconnect") as Vala.Method, scope, method_spaces),
                insertTextFormat = InsertTextFormat.Snippet
            }
        });
    }

    /**
     * Use this to complete members of an array.
     */
    void add_completions_for_array_type (CodeStyleAnalyzer? code_style,
                                         Vala.ArrayType atype, Vala.Scope scope, Set<CompletionItem> completions) {
        var length_member = atype.get_member ("length");
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;
        if (length_member != null)
            completions.add (new CompletionItem.from_symbol (
                atype,
                length_member, 
                scope,
                CompletionItemKind.Property,
                (atype.fixed_length && atype.length != null ? 
                    new DocComment (@"(= $(CodeHelp.get_code_node_source (atype.length)))") : null)));
        foreach (string method_name in new string[] {"copy", "move", "resize"}) {
            var method = atype.get_member (method_name);
            if (method is Vala.Method) {
                completions.add (new CompletionItem.from_symbol (
                        atype,
                        method,
                        scope,
                        CompletionItemKind.Method,
                        null) {
                    insertText = generate_insert_text_for_callable (atype, (Vala.Method)method, scope, method_spaces),
                    insertTextFormat = InsertTextFormat.Snippet
                });
            }
        }
    }

    /**
     * Use this to complete members of an async method.
     */
    void add_completions_for_async_method (CodeStyleAnalyzer? code_style,
                                           Vala.DataType? instance_type, Vala.Method m, Vala.Scope scope, Set<CompletionItem> completions) {
        Vala.Scope topmost = get_topmost_scope (scope);
        Vala.Symbol? glib_ns = topmost.lookup ("GLib");
        // don't show async members if we don't have GAsyncResult available (included in gio-2.0)
        if (glib_ns != null && glib_ns.scope.lookup ("AsyncResult") != null) {
            completions.add_all_array(new CompletionItem []{
                new CompletionItem.from_symbol (instance_type, m, scope, CompletionItemKind.Method,
                    new DocComment ("Begin asynchronous operation"), "begin") {
                    insertText = generate_insert_text_for_callable (instance_type, m, scope, code_style.average_spacing_before_parens, "begin"),
                    insertTextFormat = InsertTextFormat.Snippet
                },
                new CompletionItem.from_symbol (instance_type, m.get_end_method (), scope, CompletionItemKind.Method,
                    new DocComment ("Get results of asynchronous operation")) {
                    insertText = generate_insert_text_for_callable (instance_type, m.get_end_method (), scope, code_style.average_spacing_before_parens),
                    insertTextFormat = InsertTextFormat.Snippet
                },
                new CompletionItem.from_symbol (instance_type, m.get_callback_method (), scope, CompletionItemKind.Field,
                    new DocComment ("Callback into asynchronous method"))
            });
        }
    }

    void add_completions_for_class_access (Server lang_serv, Project project,
                                           CodeStyleAnalyzer? code_style,
                                           Vala.Class class_sym, Vala.Scope current_scope,
                                           Set<CompletionItem> completions) {
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;
        var klasses = new GLib.Queue<Vala.Class> ();
        var seen_klasses = new HashSet<Vala.Class> ();
        klasses.push_tail (class_sym);

        while (!klasses.is_empty ()) {
            var ks = klasses.pop_head ();
            if (ks in seen_klasses)     // work around recursive types
                break;
            seen_klasses.add (ks);
            foreach (var method_sym in ks.get_methods ()) {
                if (!(method_sym is Vala.CreationMethod) && method_sym.is_class_member ()) {
                    var completion = new CompletionItem.from_symbol (null,
                                                                     method_sym, current_scope,
                                                                     CompletionItemKind.Method,
                                                                     lang_serv.get_symbol_documentation (project, method_sym));
                    completion.insertText = generate_insert_text_for_callable (null, method_sym, current_scope, method_spaces);
                    completion.insertTextFormat = InsertTextFormat.Snippet;
                    completions.add (completion);
                }
            }
            foreach (var field_sym in ks.get_fields ()) {
                if (field_sym.is_class_member ())
                    completions.add (new CompletionItem.from_symbol (null,
                                                                     field_sym, current_scope,
                                                                     CompletionItemKind.Field,
                                                                     lang_serv.get_symbol_documentation (project, field_sym)));
            }
            foreach (var prop_sym in ks.get_properties ()) {
                if (prop_sym.is_class_member ())
                    completions.add (new CompletionItem.from_symbol (null,
                                                                     prop_sym, current_scope,
                                                                     CompletionItemKind.Property,
                                                                     lang_serv.get_symbol_documentation (project, prop_sym)));
            }
            // look at base types
            foreach (var base_type in ks.get_base_types ()) {
                if (base_type.type_symbol is Vala.Class)
                    klasses.push_tail ((Vala.Class) base_type.type_symbol);
            }
        }
    }

    /**
     * Show a suggestion for a class symbol and/or the default class
     * constructor, depending on the context.
     */
    void add_class_completion (Server lang_serv, Project project,
                               Vls.CodeStyleAnalyzer? code_style,
                               Vala.Class class_sym, Vala.Scope scope,
                               bool in_oce, Set<CompletionItem> completions) {
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;

        bool has_named_ctors = false;
        foreach (var method in class_sym.get_methods ()) {
            if (method is Vala.CreationMethod && method.name != ".new") {
                has_named_ctors = true;
                break;
            }
        }

        if (!in_oce || has_named_ctors
            || !class_sym.get_classes ().is_empty || !class_sym.get_interfaces ().is_empty
            || !class_sym.get_structs ().is_empty) {
            completions.add (new CompletionItem.from_symbol (
                null,
                class_sym,
                scope,
                CompletionItemKind.Class,
                lang_serv.get_symbol_documentation (project, class_sym)) {
                insertText = generate_insert_text_for_type_symbol (class_sym, scope, method_spaces),
                insertTextFormat = InsertTextFormat.Snippet
            });
        }

        if (in_oce && !class_sym.is_abstract && class_sym.default_construction_method != null) {
            var ctor_documentation = lang_serv.get_symbol_documentation (project, class_sym.default_construction_method);
            if (ctor_documentation == null)
                ctor_documentation = lang_serv.get_symbol_documentation (project, class_sym);
            completions.add (new CompletionItem.from_symbol (
                null,
                class_sym.default_construction_method,
                scope,
                CompletionItemKind.Constructor,
                ctor_documentation,
                class_sym.name) {
                insertText = generate_insert_text_for_callable (null, class_sym.default_construction_method, scope, method_spaces),
                insertTextFormat = InsertTextFormat.Snippet
            });
        }
    }

    Vala.Scope get_topmost_scope (Vala.Scope topmost) {
        for (Vala.Scope? current_scope = topmost;
             current_scope != null;
             current_scope = current_scope.parent_scope)
            topmost = current_scope;

        return topmost;
    }
}
