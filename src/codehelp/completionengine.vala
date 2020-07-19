using LanguageServer;
using Gee;

namespace Vls.CompletionEngine {
    void begin_response (Server lang_serv, Project project,
                         Jsonrpc.Client client, Variant id, string method,
                         Vala.SourceFile doc, Compilation compilation,
                         Position pos, CompletionContext? completion_context) {
        bool is_pointer_access = false;
        long idx = (long) Util.get_string_pos (doc.content, pos.line, pos.character);

        Position end_pos = pos.dup ();
        bool is_member_access = false;

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
            if (doc.content[lb_idx] == '.' || (lb_idx >= 1 && doc.content[lb_idx-1] == '-' && doc.content[lb_idx] == '>')) {
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
        } else if (doc.content[idx] == '.') {
            // pos = pos.translate (0, -1);
            // debug ("[%s] found member access", method);
            is_member_access = true;
        } else {
            // The editor requested a member access completion from a '>'.
            // This is a hack since the LSP doesn't allow us to specify a trigger string ("->" in this case)
            if (completion_context != null && completion_context.triggerKind == CompletionTriggerKind.TriggerCharacter) {
                // completion conditions are not satisfied
                finish (client, id, completions);
                return;
            }
            // TODO: incomplete completions
        }

        Vala.CodeContext.push (compilation.code_context);
        if (is_member_access) {
            // attempt SymbolExtractor first, and if that fails, then wait for
            // the next context update

            var se = new SymbolExtractor (pos, doc);
            if (se.extracted_expression != null)
                show_members (lang_serv, project, doc, compilation, is_pointer_access, se.extracted_expression is Vala.ObjectCreationExpression, 
                              se.extracted_expression, se.block.scope, completions, false);

            if (completions.is_empty) {
                // debug ("[%s] trying MA completion again after context update ...", method);
                lang_serv.wait_for_context_update (id, request_cancelled => {
                    if (request_cancelled) {
                        Server.reply_null (id, client, method);
                        return;
                    }

                    Vala.CodeContext.push (compilation.code_context);
                    show_members_with_updated_context (lang_serv, project,
                                                       client, id, 
                                                       doc, compilation, 
                                                       is_pointer_access, 
                                                       pos, end_pos, completions);
                    finish (client, id, completions);
                    Vala.CodeContext.pop ();
                });
            } else {
                finish (client, id, completions);
            }
        } else {
            Vala.Scope best_scope;
            Vala.Symbol nearest_symbol;
            bool in_loop;
            bool showing_override_suggestions = false;
            walk_up_current_scope (lang_serv, doc, pos, out best_scope, out nearest_symbol, out in_loop);
            if (nearest_symbol is Vala.Class) {
                var results = gather_missing_prereqs_and_unimplemented_symbols ((Vala.Class) nearest_symbol);
                // TODO: use missing prereqs (results.first)
                list_implementable_symbols (lang_serv, project, doc, (Vala.Class) nearest_symbol, best_scope, results.second, completions);
                showing_override_suggestions = !completions.is_empty;
            }
            if (nearest_symbol is Vala.ObjectTypeSymbol) {
                list_implementable_symbols (lang_serv, project, doc, (Vala.ObjectTypeSymbol) nearest_symbol, best_scope,
                                            gather_base_virtual_symbols_not_overridden ((Vala.ObjectTypeSymbol) nearest_symbol),
                                            completions);
            }
            if (!showing_override_suggestions) {
                list_symbols (lang_serv, project, doc, pos, best_scope, completions);
                list_keywords (lang_serv, doc, nearest_symbol, in_loop, completions);
            }
            finish (client, id, completions);
        }
        Vala.CodeContext.pop ();
    }

    void finish (Jsonrpc.Client client, Variant id, Collection<CompletionItem> completions) {
        var json_array = new Json.Array ();
        foreach (CompletionItem comp in completions)
            json_array.add_element (Json.gobject_serialize (comp));

        try {
            Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
            client.reply (id, variant_array, Server.cancellable);
        } catch (Error e) {
            warning (@"[textDocument/completion] failed to reply to client: $(e.message)");
        }
    }

    void walk_up_current_scope (Server lang_serv, 
                                Vala.SourceFile doc, Position pos, 
                                out Vala.Scope best_scope, out Vala.Symbol nearest_symbol, out bool in_loop) {
        best_scope = new FindScope (doc, pos).best_block.scope;
        in_loop = false;
        nearest_symbol = null;
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
                       Vala.SourceFile doc, Position pos, 
                       Vala.Scope best_scope, 
                       Set<CompletionItem> completions) {
        string method = "textDocument/completion";
        bool in_instance = false;
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
                if (symtab == null)
                    continue;
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
            } else if (owner is Vala.TypeSymbol) {
                if (in_instance)
                    add_completions_for_type (lang_serv, project, Vala.SemanticAnalyzer.get_data_type_for_symbol (owner), (Vala.TypeSymbol) owner, completions, best_scope, false, false, seen_props);
                // always show static members
                add_completions_for_type (lang_serv, project, null, (Vala.TypeSymbol) owner, completions, best_scope, false, false, seen_props);
                // once we leave a type symbol, we're no longer in an instance
                in_instance = false;
            } else if (owner is Vala.Namespace) {
                add_completions_for_ns (lang_serv, project, (Vala.Namespace) owner, best_scope, completions, false);
            } else {
                debug (@"[$method] ignoring owner ($owner) ($(owner.type_name)) of scope");
            }
        }
        // show members of all imported namespaces
        foreach (var ud in doc.current_using_directives) {
            if (ud.namespace_symbol is Vala.Namespace)
                add_completions_for_ns (lang_serv, project, (Vala.Namespace) ud.namespace_symbol, best_scope, completions, false);
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
            if (!(nearest_symbol is Vala.TypeSymbol))
                completions.add (new CompletionItem.keyword ("namespace"));
            if (!(nearest_symbol is Vala.TypeSymbol) || nearest_symbol is Vala.ObjectTypeSymbol)
                completions.add (new CompletionItem.keyword ("struct"));

            completions.add_all_array ({
                new CompletionItem.keyword ("delegate"),
                new CompletionItem.keyword ("enum"),
                new CompletionItem.keyword ("errordomain"),
                new CompletionItem.keyword ("interface"),
                new CompletionItem.keyword ("internal"),
                new CompletionItem.keyword ("unowned"),
                new CompletionItem.keyword ("params"),
                new CompletionItem.keyword ("private"),
                new CompletionItem.keyword ("public"),
                new CompletionItem.keyword ("void"),
            });
        }

        if (nearest_symbol is Vala.Namespace || nearest_symbol is Vala.ObjectTypeSymbol) {
            completions.add_all_array ({
                new CompletionItem.keyword ("abstract"),
                new CompletionItem.keyword ("virtual"),
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
                new CompletionItem.keyword ("foreach", "foreach (${3:var} ${1:thing} in ${2:<expression>})$0"),
                new CompletionItem.keyword ("if", "if (${1:<condition>})$0"),
                new CompletionItem.keyword ("in"),
                new CompletionItem.keyword ("is"),
                new CompletionItem.keyword ("new"),
                new CompletionItem.keyword ("null"),
                new CompletionItem.keyword ("return"),
                new CompletionItem.keyword ("switch", "switch (${1:<expression>}) {$0}"),
                new CompletionItem.keyword ("throw"),
                new CompletionItem.keyword ("true"),
                new CompletionItem.keyword ("try", "try {$1} catch ($2) {$3}$0"),
                new CompletionItem.keyword ("var"),
                new CompletionItem.keyword ("while", "while (${1:<condition>})$0"),
                new CompletionItem.keyword ("yield"),
            });
        }

        if (nearest_symbol == Vala.CodeContext.get ().root)
            completions.add (new CompletionItem.keyword ("using"));

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
    void list_implementable_symbols (Server lang_serv, Project project,
                                     Vala.SourceFile doc, Vala.TypeSymbol type_symbol, Vala.Scope scope,
                                     Gee.List<Pair<Vala.DataType?, Vala.Symbol>> missing_symbols,
                                     Set<CompletionItem> completions) {
        foreach (var pair in missing_symbols) {
            var instance_type = pair.first;
            var sym = pair.second;
            var kind = CompletionItemKind.Method;

            if (sym is Vala.Property)
                kind = CompletionItemKind.Property;

            var label = new StringBuilder ();
            var insert_text = new StringBuilder ();

            bool is_virtual = (sym is Vala.Method) && ((Vala.Method)sym).is_virtual || 
                                (sym is Vala.Property) && ((Vala.Property)sym).is_virtual;

            label.append (sym.access.to_string ());
            label.append_c (' ');
            insert_text.append (sym.access.to_string ());
            insert_text.append_c (' ');

            if (sym.parent_symbol is Vala.Interface && !is_virtual) {
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

                label.append (" (");
                insert_text.append (" (");
                int i = 1;
                foreach (Vala.Parameter param in ((Vala.Callable) sym).get_parameters ()) {
                    if (i > 1) {
                        insert_text.append (", ");
                        label.append (", ");
                    }
                    insert_text.append (CodeHelp.get_symbol_representation (instance_type, param, scope, null, "${" + @"$i:$(param.name)}"));
                    label.append (CodeHelp.get_symbol_representation (instance_type, param, scope));
                    i++;
                }
                insert_text.append_c(')');
                label.append_c (')');
            } else if (sym is Vala.Property) {
                label.append (" {");
                insert_text.append (" {");
                int count = 1;
                if (((Vala.Property)sym).get_accessor != null) {
                    label.append (" get;");
                    insert_text.append (" ${");
                    insert_text.append_printf ("%d", count);
                    insert_text.append (":get;}");
                    count++;
                }
                if (((Vala.Property)sym).set_accessor != null) {
                    label.append (" set;");
                    insert_text.append (" ${");
                    insert_text.append_printf ("%d", count);
                    insert_text.append (":set;}");
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
     * also taken from `Vala.Class` in `vala/valaclass.vala`
     */
    private void get_all_prerequisites (Vala.Interface iface, Gee.List<Vala.TypeSymbol> list) {
        foreach (Vala.DataType prereq in iface.get_prerequisites ()) {
            Vala.TypeSymbol type = prereq.type_symbol;
            /* skip on previous errors */
            if (type == null) {
                continue;
            }

            list.add (type);
            if (type is Vala.Interface) {
                get_all_prerequisites ((Vala.Interface) type, list);

            }
        }
    }

    Gee.List<Vala.Symbol> get_virtual_symbols (Vala.ObjectTypeSymbol tsym) {
        var symbols = new ArrayList<Vala.Symbol> ();

        if (tsym is Vala.Class) {
            foreach (var method in ((Vala.Class)tsym).get_methods ()) {
                if (method.is_virtual)
                    symbols.add (method);
            }
            foreach (var property in ((Vala.Class)tsym).get_properties ()) {
                if (property.is_virtual)
                    symbols.add (property);
            }
        } else if (tsym is Vala.Interface) {
            foreach (var method in ((Vala.Interface)tsym).get_methods ()) {
                if (method.is_virtual)
                    symbols.add (method);
            }
            foreach (var property in ((Vala.Interface)tsym).get_properties ()) {
                if (property.is_virtual)
                    symbols.add (property);
            }
        }

        return symbols;
    }

    /**
     * Get base virtual/abstract methods and properties that haven't been overridden.
     */
    Gee.List<Pair<Vala.DataType?,Vala.Symbol>> gather_base_virtual_symbols_not_overridden (Vala.ObjectTypeSymbol tsym) {
        var implemented_symbols = new ArrayList<Vala.Symbol> ();
        var virtual_symbols = new ArrayList<Pair<Vala.DataType?,Vala.Symbol>> ();
        var base_types = new Vala.ArrayList<Vala.DataType> ();

        if (tsym is Vala.Class) {
            base_types.add_all (((Vala.Class) tsym).get_base_types ());
        } else if (tsym is Vala.Interface) {
            base_types.add_all (((Vala.Interface) tsym).get_prerequisites ());
        }

        foreach (var method in tsym.get_methods ())
            if (method.base_method != null && method.base_method != method ||
                method.base_interface_method != null && method.base_interface_method != method)
                implemented_symbols.add (method.base_method ?? method.base_interface_method);

        foreach (var property in tsym.get_properties ())
            if (property.base_property != null && property.base_property != property ||
                property.base_interface_property != null && property.base_interface_property != property)
                implemented_symbols.add (property.base_property ?? property.base_interface_property);

        // look for all virtual symbols in each base_type that have not been overridden
        foreach (var type in base_types)
            if (type.type_symbol is Vala.ObjectTypeSymbol) {
                foreach (var symbol in get_virtual_symbols ((Vala.ObjectTypeSymbol)type.type_symbol))
                    if (!(symbol in implemented_symbols)) {
                        virtual_symbols.add (new Pair<Vala.DataType?,Vala.Symbol> (type, symbol));
                    }
            }

        return virtual_symbols;
    }

    /**
     * Taken from `Vala.Class.check ()` in `vala/valaclass.vala`
     * @param doc the current document 
     * @param csym the class symbol
     */
    Pair<Gee.List<Vala.TypeSymbol>, Gee.List<Pair<Vala.DataType?,Vala.Symbol>>>? gather_missing_prereqs_and_unimplemented_symbols (Vala.Class csym) {
        if (csym.is_compact) {
            // compact classes cannot derive from anything
            return null;
        }

        /* gather all prerequisites */
        var prerequisites = new ArrayList<Vala.TypeSymbol> ();
        foreach (Vala.DataType base_type in csym.get_base_types ()) {
            if (base_type.type_symbol is Vala.Interface) {
                get_all_prerequisites ((Vala.Interface) base_type.type_symbol, prerequisites);
            }
        }
        /* check whether all prerequisites are met */
        var missing_prereqs = new ArrayList<Vala.TypeSymbol> ();
        foreach (Vala.TypeSymbol prereq in prerequisites) {
            if (!csym.is_a ((Vala.ObjectTypeSymbol) prereq)) {
                missing_prereqs.insert (0, prereq);
            }
        }

        var missing_symbols = new ArrayList<Pair<Vala.DataType?, Vala.Symbol>> ();
        /* VAPI classes don't have to specify overridden methods */
        if (csym.source_type == Vala.SourceFileType.SOURCE) {
            /* all abstract symbols defined in base types have to be at least defined (or implemented) also in this type */
            foreach (Vala.DataType base_type in csym.get_base_types ()) {
                if (base_type.type_symbol is Vala.Interface) {
                    unowned Vala.Interface iface = (Vala.Interface) base_type.type_symbol;

                    if (csym.base_class != null && csym.base_class.is_subtype_of (iface)) {
                        // reimplementation of interface, class is not required to reimplement all methods
                        break;
                    }

                    /* We do not need to do expensive equality checking here since this is done
                     * already. We only need to guarantee the symbols are present.
                     */

                    /* check methods */
                    foreach (Vala.Method m in iface.get_methods ()) {
                        if (m.is_abstract) {
                            var implemented = false;
                            unowned Vala.Class? base_class = csym;
                            while (base_class != null && !implemented) {
                                foreach (var impl in base_class.get_methods ()) {
                                    if (impl.base_interface_method == m || (base_class != csym
                                                                            && impl.base_interface_method == null && impl.name == m.name
                                                                            && (impl.base_interface_type == null || impl.base_interface_type.type_symbol == iface)
                                                                            && impl.compatible_no_error (m))) {
                                        implemented = true;
                                        break;
                                    }
                                }
                                base_class = base_class.base_class;
                            }
                            if (!implemented) {
                                missing_symbols.add (new Pair<Vala.DataType,Vala.Symbol> (base_type, m));
                            }
                        }
                    }

                    /* check properties */
                    foreach (Vala.Property prop in iface.get_properties ()) {
                        if (prop.is_abstract) {
                            Vala.Symbol sym = null;
                            unowned Vala.Class? base_class = csym;
                            while (base_class != null && !(sym is Vala.Property)) {
                                sym = base_class.scope.lookup (prop.name);
                                base_class = base_class.base_class;
                            }
                            if (sym is Vala.Property) {
                                var base_prop = (Vala.Property) sym;
                                string? invalid_match = null;
                                // No check at all for "new" classified properties, really?
                                if (!base_prop.hides && !base_prop.compatible (prop, out invalid_match)) {
                                    // we prefer to show fixup suggestions rather than completion suggestions for
                                    // this type of error, so ignore it

                                    // Report.error (source_reference, "Type and/or accessors of inherited properties `%s' and `%s' do not match: %s.".printf (prop.get_full_name (), base_prop.get_full_name (), invalid_match));
                                }
                            } else {
                                missing_symbols.add (new Pair<Vala.DataType,Vala.Symbol> (base_type, prop));
                            }
                        }
                    }
                }
            }

            /* all abstract symbols defined in base classes have to be implemented in non-abstract classes */
            if (!csym.is_abstract) {
                unowned Vala.Class? base_class = csym.base_class;
                while (base_class != null && base_class.is_abstract) {
                    foreach (Vala.Method base_method in base_class.get_methods ()) {
                        if (base_method.is_abstract) {
                            var override_method = Vala.SemanticAnalyzer.symbol_lookup_inherited (csym, base_method.name) as Vala.Method;
                            if (override_method == null || !override_method.overrides) {
                                missing_symbols.add (new Pair<Vala.DataType?, Vala.Symbol> (null, base_method));
                            }
                        }
                    }
                    foreach (Vala.Property base_property in base_class.get_properties ()) {
                        if (base_property.is_abstract) {
                            var override_property = Vala.SemanticAnalyzer.symbol_lookup_inherited (csym, base_property.name) as Vala.Property;
                            if (override_property == null || !override_property.overrides) {
                                missing_symbols.add (new Pair<Vala.DataType?, Vala.Symbol> (null, base_property));
                            }
                        }
                    }
                    base_class = base_class.base_class;
                }
            }
        }

        return new Pair<Gee.List<Vala.TypeSymbol>, Gee.List<Pair<Vala.DataType,Vala.Symbol>>> (missing_prereqs, missing_symbols);
    }

    /**
     * Fill the completion list with members of {@result}
     * If scope is null, the current scope will be calculated.
     */
    void show_members (Server lang_serv, Project project,
                       Vala.SourceFile doc, Compilation compilation,
                       bool is_pointer_access, bool in_oce,
                       Vala.CodeNode result, Vala.Scope? scope, Set<CompletionItem> completions,
                       bool retry_inner = true) {
        string method = "textDocument/completion";
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

            if (data_type != null && data_type.type_symbol != null)
                add_completions_for_type (lang_serv, project, data_type, data_type.type_symbol, completions, current_scope, in_oce, is_cm_this_or_base_access);
            else if (symbol is Vala.Signal)
                add_completions_for_signal (data_type, (Vala.Signal) symbol, current_scope, completions);
            else if (symbol is Vala.Namespace)
                add_completions_for_ns (lang_serv, project, (Vala.Namespace) symbol, current_scope, completions, in_oce);
            else if (symbol is Vala.Method && ((Vala.Method) symbol).coroutine)
                add_completions_for_async_method (data_type, (Vala.Method) symbol, current_scope, completions);
            else if (data_type is Vala.ArrayType)
                add_completions_for_array_type ((Vala.ArrayType) data_type, current_scope, completions);
            else if (symbol is Vala.TypeSymbol)
                add_completions_for_type (lang_serv, project, null, (Vala.TypeSymbol)symbol, completions, current_scope, in_oce, is_cm_this_or_base_access);
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
                debug ("[%s] could not get datatype for %s", method,
                        result == null ? "(null)" : @"($(result.type_name)) $result");
            }
            break;      // break by default
        } while (true);
    }

    /**
     * Use this for accurate member access completions after the code context has been updated.
     */
    void show_members_with_updated_context (Server lang_serv, Project project,
                                            Jsonrpc.Client client, Variant id,
                                            Vala.SourceFile doc, Compilation compilation,
                                            bool is_pointer_access,
                                            Position pos, Position? end_pos, Set<CompletionItem> completions) {
        string method = "textDocument/completion";
        // debug (@"[$method] FindSymbol @ $pos" + (end_pos != null ? @" -> $end_pos" : ""));
        Vala.CodeContext.push (compilation.code_context);

        var fs = new FindSymbol (doc, pos, true, end_pos);

        if (fs.result.size == 0) {
            debug (@"[$method] no results found for member access");
            Server.reply_null (id, client, method);
            Vala.CodeContext.pop ();
            return;
        }

        bool in_oce = false;

        foreach (var res in fs.result) {
            // debug (@"[$method] found $(res.type_name) (semanalyzed = $(res.checked))");
            in_oce |= res is Vala.ObjectCreationExpression;
        }

        Vala.CodeNode result = Server.get_best (fs, doc);
        show_members (lang_serv, project, doc, compilation, is_pointer_access, in_oce, result, null, completions);
        Vala.CodeContext.pop ();
    }

    /**
     * List all relevant members of a type. This is where completion options are generated.
     *
     * @param is_cm_this_or_base_access     Whether we are accessing `this` or `base` within a creation method.
     */
    void add_completions_for_type (Server lang_serv, Project project,
                                   Vala.DataType? type, 
                                   Vala.TypeSymbol type_symbol,
                                   Set<CompletionItem> completions, 
                                   Vala.Scope current_scope,
                                   bool in_oce,
                                   bool is_cm_this_or_base_access,
                                   Set<string> seen_props = new HashSet<string> ()) {
        bool is_instance = type != null;
        if (type_symbol is Vala.ObjectTypeSymbol) {
            /**
             * Complete the members of this object, such as the fields,
             * properties, and methods.
             */
            var object_sym = (Vala.ObjectTypeSymbol) type_symbol;

            // debug (@"type symbol is object $(object_sym.name) (is_instance = $is_instance, in_oce = $in_oce)");

            foreach (var method_sym in object_sym.get_methods ()) {
                if (method_sym.name == ".new") {
                    continue;
                } else if (is_instance && !in_oce) {
                    // for instance symbols, show only instance members
                    // except for creation methods, which are treated as instance members
                    if (!method_sym.is_instance_member () || method_sym is Vala.CreationMethod && !is_cm_this_or_base_access)
                        continue;
                } else if (in_oce) {
                    // only show creation methods for non-instance symbols within an OCE
                    if (!(method_sym is Vala.CreationMethod))
                        continue;
                } else {
                    // only show static methods for non-instance symbols
                    if (method_sym.is_instance_member ())
                        continue;
                }
                // check whether the symbol is accessible
                if (!CodeHelp.is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (type, method_sym, current_scope,
                    (method_sym is Vala.CreationMethod) ? CompletionItemKind.Constructor : CompletionItemKind.Method, 
                    lang_serv.get_symbol_documentation (project, method_sym)));
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
                    completions.add (new CompletionItem.from_symbol (type, signal_sym, current_scope, CompletionItemKind.Event, lang_serv.get_symbol_documentation (project, signal_sym)));
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
                    completions.add (new CompletionItem.from_symbol (type, class_sym, current_scope, CompletionItemKind.Class, lang_serv.get_symbol_documentation (project, class_sym)));

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
                        add_completions_for_type (lang_serv, project, type, base_type.type_symbol,
                                                  completions, current_scope, in_oce, false, seen_props);
                }
                if (object_sym is Vala.Interface) {
                    var iface_sym = (Vala.Interface) object_sym;
                    foreach (var base_type in iface_sym.get_prerequisites ())
                        add_completions_for_type (lang_serv, project, type, base_type.type_symbol,
                                                  completions, current_scope, in_oce, false, seen_props);
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
                completions.add (new CompletionItem.from_symbol (type, method_sym, current_scope, CompletionItemKind.Method, lang_serv.get_symbol_documentation (project, method_sym)));
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
                    completions.add (new CompletionItem.from_symbol (type, method_sym, current_scope, CompletionItemKind.Method, lang_serv.get_symbol_documentation (project, method_sym)));
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
                        add_completions_for_type (lang_serv, project,
                            type, (Vala.TypeSymbol) gerror_sym, completions, 
                            current_scope, in_oce, false, seen_props);
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
                if (method_sym.is_instance_member () != is_instance
                    || !CodeHelp.is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (type, method_sym, current_scope, CompletionItemKind.Method, lang_serv.get_symbol_documentation (project, method_sym)));
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
        } else {
            warning (@"other type symbol $type_symbol.\n");
        }
    }

    /**
     * Use this when we're completing members of a namespace.
     */
    void add_completions_for_ns (Server lang_serv, Project project, Vala.Namespace ns, Vala.Scope scope, Set<CompletionItem> completions, bool in_oce) {
        foreach (var class_sym in ns.get_classes ())
            completions.add (new CompletionItem.from_symbol (null, class_sym, scope, CompletionItemKind.Class, lang_serv.get_symbol_documentation (project, class_sym)));
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
            foreach (var method_sym in ns.get_methods ())
                completions.add (new CompletionItem.from_symbol (null, method_sym, scope, CompletionItemKind.Method, lang_serv.get_symbol_documentation (project, method_sym)));
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
    void add_completions_for_signal (Vala.DataType? instance_type, Vala.Signal sig, Vala.Scope scope, Set<CompletionItem> completions) {
        var sig_type = new Vala.SignalType (sig);
        completions.add_all_array (new CompletionItem []{
            new CompletionItem.from_symbol (instance_type, sig_type.get_member ("connect"), scope, CompletionItemKind.Method, 
                new DocComment ("Connect to signal")),
            new CompletionItem.from_symbol (instance_type, sig_type.get_member ("connect_after"), scope, CompletionItemKind.Method,
                new DocComment ("Connect to signal after default handler")),
            new CompletionItem.from_symbol (instance_type, sig_type.get_member ("disconnect"), scope, CompletionItemKind.Method,
                new DocComment ("Disconnect signal"))
        });
    }

    /**
     * Use this to complete members of an array.
     */
    void add_completions_for_array_type (Vala.ArrayType atype, Vala.Scope scope, Set<CompletionItem> completions) {
        var length_member = atype.get_member ("length");
        if (length_member != null)
            completions.add (new CompletionItem.from_symbol (
                atype,
                length_member, 
                scope,
                CompletionItemKind.Property,
                (atype.fixed_length && atype.length != null ? 
                    new DocComment (@"(= $(CodeHelp.get_expression_representation (atype.length)))") : null)));
        foreach (string method_name in new string[] {"copy", "move", "resize"}) {
            var method = atype.get_member (method_name);
            if (method != null)
                completions.add (new CompletionItem.from_symbol (
                    atype,
                    method,
                    scope,
                    CompletionItemKind.Method, null));
        }
    }

    /**
     * Use this to complete members of an async method.
     */
    void add_completions_for_async_method (Vala.DataType? instance_type, Vala.Method m, Vala.Scope scope, Set<CompletionItem> completions) {
        completions.add_all_array(new CompletionItem []{
            new CompletionItem.from_symbol (instance_type, m, scope, CompletionItemKind.Method,
                new DocComment ("Begin asynchronous operation"), "begin"),
            new CompletionItem.from_symbol (instance_type, m.get_end_method (), scope, CompletionItemKind.Method,
	    	    new DocComment ("Get results of asynchronous operation"))
        });
    }

    Vala.Scope get_topmost_scope (Vala.Scope topmost) {
        for (Vala.Scope? current_scope = topmost;
             current_scope != null;
             current_scope = current_scope.parent_scope)
            topmost = current_scope;

        return topmost;
    }
}
