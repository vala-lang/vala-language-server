using LanguageServer;
using Gee;

namespace Vls.CompletionEngine {
    void begin_response (Server lang_serv,
                         Jsonrpc.Client client, Variant id, string method,
                         Vala.SourceFile doc, Compilation compilation,
                         Position pos, CompletionContext? completion_context) {
        bool is_pointer_access = false;
        long idx = (long) Util.get_string_pos (doc.content, pos.line, pos.character);

        Position end_pos = pos.dup ();
        bool is_member_access = false;

        // move back to the nearest member access if there is one
        long lb_idx = idx;

        // first, move back off the end of the current line
        if (doc.content[lb_idx] == '\n') {
            lb_idx--;
            if (doc.content[lb_idx] == '\r')    // TODO: is this really necessary?
                lb_idx--;
        }

        // now move back to an identifier
        while (lb_idx > 0 && !doc.content[lb_idx].isalnum () 
               && doc.content[lb_idx] != '_' && !doc.content[lb_idx-1].isspace ()
               && doc.content[lb_idx] != '.' && !(doc.content[lb_idx-1] == '-' && doc.content[lb_idx] == '>'))
            lb_idx--;

        // now attempt to find a member access
        while (lb_idx >= 0 && !doc.content[lb_idx].isspace ()) {
            if (doc.content[lb_idx] == '.' || (lb_idx >= 1 && doc.content[lb_idx-1] == '-' && doc.content[lb_idx] == '>')) {
                var new_pos = pos.translate (0, (int) (lb_idx - idx));
                debug ("[%s] moved cursor back from '%c'@%s -> '%c'@%s",
                    method, doc.content[idx], pos.to_string (), doc.content[lb_idx], new_pos.to_string ());
                idx = lb_idx;
                pos = new_pos;
                end_pos = pos.dup ();
                break;
            } else if (!doc.content[lb_idx].isalnum() && doc.content[lb_idx] != '_') {
                // if this character does not belong to an identifier, break
                debug ("[%s] breaking, since we could not find a member access", method);
                var new_pos = pos.translate (0, (int) (lb_idx - idx));
                debug ("[%s] moved cursor back from '%c'@%s -> '%c'@%s",
                    method, doc.content[idx], pos.to_string (), doc.content[lb_idx], new_pos.to_string ());
                break;
            }
            lb_idx--;
        }
        
        if (idx >= 1 && doc.content[idx-1] == '-' && doc.content[idx] == '>') {
            is_pointer_access = true;
            is_member_access = true;
            debug (@"[$method] found pointer access @ $pos");
            // pos = pos.translate (0, -2);
        } else if (doc.content[idx] == '.') {
            // pos = pos.translate (0, -1);
            is_member_access = true;
        } else if (completion_context != null) {
            if (completion_context.triggerKind == CompletionTriggerKind.TriggerCharacter) {
                // pos = pos.translate (0, -1);
                is_member_access = true;
            } else if (completion_context.triggerKind == CompletionTriggerKind.Invoked)
                debug (@"[$method] invoked @ $pos");
            // TODO: incomplete completions
        }

        var completions = new HashSet<CompletionItem> ();

        Vala.CodeContext.push (compilation.code_context);
        if (is_member_access) {
            // attempt SymbolExtractor first, and if that fails, then wait for
            // the next context update

            var se = new SymbolExtractor (pos, doc);
            if (se.extracted_expression != null)
                show_members (lang_serv, doc, compilation, is_pointer_access, false /* TODO */, 
                              se.extracted_expression, se.block.scope, completions, false);

            if (completions.is_empty) {
                debug ("[%s] trying MA completion again after context update ...", method);
                lang_serv.wait_for_context_update (id, request_cancelled => {
                    if (request_cancelled) {
                        Server.reply_null (id, client, method);
                        return;
                    }

                    Vala.CodeContext.push (compilation.code_context);
                    show_members_with_updated_context (lang_serv, client, id, 
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
            list_symbols (lang_serv, doc, pos, completions);
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
            debug (@"[textDocument/completion] failed to reply to client: $(e.message)");
        }
    }

    /**
     * Fill the completion list with all scope-visible symbols
     */
    void list_symbols (Server lang_serv, Vala.SourceFile doc, Position pos, Set<CompletionItem> completions) {
        string method = "textDocument/completion";
        Vala.Scope best_scope = new FindScope (doc, pos).best_block.scope;
        bool in_instance = false;
        var seen_props = new HashSet<string> ();

        if (best_scope.owner.source_reference != null)
            debug (@"[$method] best scope SR is $(best_scope.owner.source_reference)");
        else
            debug (@"[$method] listing symbols from $(best_scope.owner)");
        for (Vala.Scope? current_scope = best_scope;
                current_scope != null;
                current_scope = current_scope.parent_scope) {
            Vala.Symbol owner = current_scope.owner;
            if (owner is Vala.Callable || owner is Vala.Statement || owner is Vala.Block || 
                owner is Vala.Subroutine) {
                Vala.Symbol? this_param = null;
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
                    // add `this' parameter
                    completions.add (new CompletionItem.from_symbol (this_param, CompletionItemKind.Constant, lang_serv.get_symbol_documentation (this_param)));
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
                    completions.add (new CompletionItem.from_symbol (sym, 
                        (sym is Vala.Constant) ? CompletionItemKind.Constant : CompletionItemKind.Variable,
                        lang_serv.get_symbol_documentation (sym)));
                }
            } else if (owner is Vala.TypeSymbol) {
                if (in_instance)
                    add_completions_for_type (lang_serv, (Vala.TypeSymbol) owner, completions, best_scope, true, false, seen_props);
                // always show static members
                add_completions_for_type (lang_serv, (Vala.TypeSymbol) owner, completions, best_scope, false, false, seen_props);
                // once we leave a type symbol, we're no longer in an instance
                in_instance = false;
            } else if (owner is Vala.Namespace) {
                add_completions_for_ns (lang_serv, (Vala.Namespace) owner, completions, false);
            } else {
                debug (@"[$method] ignoring owner ($owner) ($(owner.type_name)) of scope");
            }
        }
        // show members of all imported namespaces
        foreach (var ud in doc.current_using_directives)
            add_completions_for_ns (lang_serv, (Vala.Namespace) ud.namespace_symbol, completions, false);
    }   

    /**
     * Fill the completion list with members of {@result}
     * If scope is null, the current scope will be calculated.
     */
    void show_members (Server lang_serv,
                       Vala.SourceFile doc, Compilation compilation,
                       bool is_pointer_access, bool in_oce,
                       Vala.CodeNode result, Vala.Scope? scope, Set<CompletionItem> completions,
                       bool retry_inner = true) {
        string method = "textDocument/completion";
        Vala.CodeNode? peeled = null;
        Vala.Scope current_scope = scope ?? get_scope_containing_node (result);

        debug (@"[$method] member: got best, $(result.type_name) `$result' (semanalyzed = $(result.checked)))");

        do {
            if (result is Vala.MemberAccess) {
                var ma = result as Vala.MemberAccess;
                for (Vala.Expression? code_node = ma.inner; code_node != null; ) {
                    debug (@"[$method] MA inner: $code_node");
                    if (code_node is Vala.MemberAccess)
                        code_node = ((Vala.MemberAccess)code_node).inner;
                    else
                        code_node = null;
                }
                if (ma.symbol_reference != null) {
                    debug (@"peeling away symbol_reference from MemberAccess: $(ma.symbol_reference.type_name)");
                    peeled = ma.symbol_reference;
                } else {
                    debug ("MemberAccess does not have symbol_reference");
                    if (!ma.checked) {
                        for (Vala.CodeNode? parent = ma.parent_node; 
                            parent != null;
                            parent = parent.parent_node)
                        {
                            debug (@"parent ($parent) semanalyzed = $(parent.checked)");
                        }
                    }
                }
            }

            bool is_instance = true;
            Vala.TypeSymbol? type_sym = Server.get_type_symbol (compilation.code_context, 
                                                                result, is_pointer_access, ref is_instance);

            // try again
            if (type_sym == null && peeled != null)
                type_sym = Server.get_type_symbol (compilation.code_context,
                                                   peeled, is_pointer_access, ref is_instance);

            if (type_sym != null)
                add_completions_for_type (lang_serv, type_sym, completions, current_scope, is_instance, in_oce);
            // and try some more
            else if (peeled is Vala.Signal)
                add_completions_for_signal ((Vala.Signal) peeled, completions);
            else if (peeled is Vala.Namespace)
                add_completions_for_ns (lang_serv, (Vala.Namespace) peeled, completions, in_oce);
            else if (peeled is Vala.Method && ((Vala.Method) peeled).coroutine)
                add_completions_for_async_method ((Vala.Method) peeled, completions);
            else {
                if (result is Vala.MemberAccess &&
                    ((Vala.MemberAccess)result).inner != null &&
                    // don't try inner if the outer expression already has a symbol reference
                    peeled == null &&
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
    void show_members_with_updated_context (Server lang_serv,
                                            Jsonrpc.Client client, Variant id,
                                            Vala.SourceFile doc, Compilation compilation,
                                            bool is_pointer_access,
                                            Position pos, Position? end_pos, Set<CompletionItem> completions) {
        string method = "textDocument/completion";
        debug (@"[$method] FindSymbol @ $pos" + (end_pos != null ? @" -> $end_pos" : ""));
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
            debug (@"[$method] found $(res.type_name) (semanalyzed = $(res.checked))");
            in_oce |= res is Vala.ObjectCreationExpression;
        }

        Vala.CodeNode result = Server.get_best (fs, doc);
        show_members (lang_serv, doc, compilation, is_pointer_access, in_oce, result, null, completions);
        Vala.CodeContext.pop ();
    }

    /**
     * List all relevant members of a type. This is where completion options are generated.
     */
    void add_completions_for_type (Server lang_serv,
                                   Vala.TypeSymbol type, 
                                   Set<CompletionItem> completions, 
                                   Vala.Scope current_scope,
                                   bool is_instance,
                                   bool in_oce,
                                   Set<string> seen_props = new HashSet<string> ()) {
        if (type is Vala.ObjectTypeSymbol) {
            /**
             * Complete the members of this object, such as the fields,
             * properties, and methods.
             */
            var object_type = type as Vala.ObjectTypeSymbol;

            debug (@"completion: type is object $(object_type.name) (is_instance = $is_instance, in_oce = $in_oce)");

            foreach (var method_sym in object_type.get_methods ()) {
                if (method_sym.name == ".new") {
                    continue;
                } else if (is_instance && !in_oce) {
                    // for instance symbols, show only instance members
                    // except for creation methods, which are treated as instance members
                    if (!method_sym.is_instance_member () || method_sym is Vala.CreationMethod)
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
                if (!is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (method_sym, (method_sym is Vala.CreationMethod) ? 
                    CompletionItemKind.Constructor : CompletionItemKind.Method, lang_serv.get_symbol_documentation (method_sym)));
            }

            if (!in_oce) {
                foreach (var field_sym in object_type.get_fields ()) {
                    if (field_sym.name[0] == '_' && seen_props.contains (field_sym.name[1:field_sym.name.length])
                        || field_sym.is_instance_member () != is_instance
                        || !is_symbol_accessible (field_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (field_sym, CompletionItemKind.Field, lang_serv.get_symbol_documentation (field_sym)));
                }
            }

            if (!in_oce && is_instance) {
                foreach (var signal_sym in object_type.get_signals ()) {
                    if (signal_sym.is_instance_member () != is_instance 
                        || !is_symbol_accessible (signal_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (signal_sym, CompletionItemKind.Event, lang_serv.get_symbol_documentation (signal_sym)));
                }

                foreach (var prop_sym in object_type.get_properties ()) {
                    if (prop_sym.is_instance_member () != is_instance
                        || !is_symbol_accessible (prop_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (prop_sym, CompletionItemKind.Property, lang_serv.get_symbol_documentation (prop_sym)));
                    seen_props.add (prop_sym.name);
                }
            }

            // get inner types and constants
            if (!is_instance && !in_oce) {
                foreach (var constant_sym in object_type.get_constants ()) {
                    if (!is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (constant_sym, CompletionItemKind.Constant, lang_serv.get_symbol_documentation (constant_sym)));
                }

                foreach (var enum_sym in object_type.get_enums ())
                    completions.add (new CompletionItem.from_symbol (enum_sym, CompletionItemKind.Enum, lang_serv.get_symbol_documentation (enum_sym)));

                foreach (var delegate_sym in object_type.get_delegates ())
                    completions.add (new CompletionItem.from_symbol (delegate_sym, CompletionItemKind.Interface, lang_serv.get_symbol_documentation (delegate_sym)));
            }

            // if we're inside an OCE (which are treated as instances), get only inner types
            if (!is_instance || in_oce) {
                foreach (var class_sym in object_type.get_classes ())
                    completions.add (new CompletionItem.from_symbol (class_sym, CompletionItemKind.Class, lang_serv.get_symbol_documentation (class_sym)));

                foreach (var iface_sym in object_type.get_interfaces ())
                    completions.add (new CompletionItem.from_symbol (iface_sym, CompletionItemKind.Interface, lang_serv.get_symbol_documentation (iface_sym)));

                foreach (var struct_sym in object_type.get_structs ())
                    completions.add (new CompletionItem.from_symbol (struct_sym, CompletionItemKind.Struct, lang_serv.get_symbol_documentation (struct_sym)));
            }

            // get instance members of supertypes
            if (is_instance && !in_oce) {
                if (object_type is Vala.Class) {
                    var class_sym = object_type as Vala.Class;
                    foreach (var base_type in class_sym.get_base_types ())
                        add_completions_for_type (lang_serv, base_type.type_symbol,
                                                  completions, current_scope, is_instance, in_oce, seen_props);
                }
                if (object_type is Vala.Interface) {
                    var iface_sym = object_type as Vala.Interface;
                    foreach (var base_type in iface_sym.get_prerequisites ())
                        add_completions_for_type (lang_serv, base_type.type_symbol,
                                                  completions, current_scope, is_instance, in_oce, seen_props);
                }
            }
        } else if (type is Vala.Enum) {
            /**
             * Complete members of this enum, such as the values, methods,
             * and constants.
             */
            var enum_type = type as Vala.Enum;

            foreach (var method_sym in enum_type.get_methods ()) {
                if (method_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method, lang_serv.get_symbol_documentation (method_sym)));
            }

            if (!is_instance) {
                foreach (var constant_sym in enum_type.get_constants ()) {
                    if (!is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (constant_sym, CompletionItemKind.Constant, lang_serv.get_symbol_documentation (constant_sym)));
                }
                foreach (var value_sym in enum_type.get_values ())
                    completions.add (new CompletionItem.from_symbol (value_sym, CompletionItemKind.EnumMember, lang_serv.get_symbol_documentation (value_sym)));
            }
        } else if (type is Vala.ErrorDomain) {
            /**
             * Get all the members of the error domain, such as the error
             * codes and the methods.
             */
            var errdomain_type = type as Vala.ErrorDomain;

            foreach (var code_sym in errdomain_type.get_codes ()) {
                if (code_sym.is_instance_member () != is_instance)
                    continue;
                completions.add (new CompletionItem.from_symbol (code_sym, CompletionItemKind.Value, lang_serv.get_symbol_documentation (code_sym)));
            }

            if (!in_oce) {
                foreach (var method_sym in errdomain_type.get_methods ()) {
                    if (method_sym.is_instance_member () != is_instance
                        || !is_symbol_accessible (method_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method, lang_serv.get_symbol_documentation (method_sym)));
                }
            }

            if (is_instance && !in_oce) {
                Vala.Scope topmost = get_topmost_scope (current_scope);

                Vala.Symbol? gerror_sym = topmost.lookup ("GLib");
                if (gerror_sym != null) {
                    gerror_sym = gerror_sym.scope.lookup ("Error");
                    if (gerror_sym == null)
                        debug ("GLib.Error not found");
                    else
                        add_completions_for_type (lang_serv, 
                            (Vala.TypeSymbol) gerror_sym, completions, 
                            current_scope, is_instance, in_oce, seen_props);
                } else
                    debug ("GLib not found");
            }
        } else if (type is Vala.Struct) {
            /**
             * Gets all of the members of the struct.
             */
            var struct_type = type as Vala.Struct;

            foreach (var field_sym in struct_type.get_fields ()) {
                // struct fields are always public
                if (field_sym.is_instance_member () != is_instance)
                    continue;
                completions.add (new CompletionItem.from_symbol (field_sym, CompletionItemKind.Field, lang_serv.get_symbol_documentation (field_sym)));
            }

            foreach (var method_sym in struct_type.get_methods ()) {
                if (method_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (method_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method, lang_serv.get_symbol_documentation (method_sym)));
            }

            foreach (var prop_sym in struct_type.get_properties ()) {
                if (prop_sym.is_instance_member () != is_instance
                    || !is_symbol_accessible (prop_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol (prop_sym, CompletionItemKind.Property, lang_serv.get_symbol_documentation (prop_sym)));
            }

            if (!is_instance) {
                foreach (var constant_sym in struct_type.get_constants ()) {
                    if (!is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol (constant_sym, CompletionItemKind.Constant, lang_serv.get_symbol_documentation (constant_sym)));
                }
            }
        } else {
            debug (@"other type node $(type).\n");
        }
    }

    /**
     * Use this when we're completing members of a namespace.
     */
    void add_completions_for_ns (Server lang_serv, Vala.Namespace ns, Set<CompletionItem> completions, bool in_oce) {
        foreach (var class_sym in ns.get_classes ())
            completions.add (new CompletionItem.from_symbol (class_sym, CompletionItemKind.Class, lang_serv.get_symbol_documentation (class_sym)));
        // this is outside of the OCE check because while we cannot create new instances of 
        // raw interfaces, it's possible for interfaces to contain instantiable types declared inside,
        // so that we would call `new Iface.Thing ()'
        foreach (var iface_sym in ns.get_interfaces ())
            completions.add (new CompletionItem.from_symbol (iface_sym, CompletionItemKind.Interface, lang_serv.get_symbol_documentation (iface_sym)));
        foreach (var struct_sym in ns.get_structs ())
            completions.add (new CompletionItem.from_symbol (struct_sym, CompletionItemKind.Struct, lang_serv.get_symbol_documentation (struct_sym)));
        foreach (var err_sym in ns.get_error_domains ())
            completions.add (new CompletionItem.from_symbol (err_sym, CompletionItemKind.Enum, lang_serv.get_symbol_documentation (err_sym)));
        foreach (var ns_sym in ns.get_namespaces ())
            completions.add (new CompletionItem.from_symbol (ns_sym, CompletionItemKind.Module, lang_serv.get_symbol_documentation (ns_sym)));
        if (!in_oce) {
            foreach (var const_sym in ns.get_constants ())
                completions.add (new CompletionItem.from_symbol (const_sym, CompletionItemKind.Constant, lang_serv.get_symbol_documentation (const_sym)));
            foreach (var method_sym in ns.get_methods ())
                completions.add (new CompletionItem.from_symbol (method_sym, CompletionItemKind.Method, lang_serv.get_symbol_documentation (method_sym)));
            foreach (var delg_sym in ns.get_delegates ())
                completions.add (new CompletionItem.from_symbol (delg_sym, CompletionItemKind.Interface, lang_serv.get_symbol_documentation (delg_sym)));
            foreach (var enum_sym in ns.get_enums ())
                completions.add (new CompletionItem.from_symbol (enum_sym, CompletionItemKind.Enum, lang_serv.get_symbol_documentation (enum_sym)));
            foreach (var field_sym in ns.get_fields ())
                completions.add (new CompletionItem.from_symbol (field_sym, CompletionItemKind.Field, lang_serv.get_symbol_documentation (field_sym)));
        }
    }
    
    /**
     * Use this to complete members of a signal.
     */
    void add_completions_for_signal (Vala.Signal sig, Set<CompletionItem> completions) {
        var sig_type = new Vala.SignalType (sig);
        completions.add_all_array (new CompletionItem []{
            new CompletionItem.from_symbol (sig_type.get_member ("connect"), CompletionItemKind.Method, 
                new MarkupContent.plaintext ("Connect to signal")),
            new CompletionItem.from_symbol (sig_type.get_member ("connect_after"), CompletionItemKind.Method,
                new MarkupContent.plaintext ("Connect to signal after default handler")),
            new CompletionItem.from_symbol (sig_type.get_member ("disconnect"), CompletionItemKind.Method,
                new MarkupContent.plaintext ("Disconnect signal"))
        });
    }

    /**
     * Use this to complete members of an async method.
     */
    void add_completions_for_async_method (Vala.Method m, Set<CompletionItem> completions) {
        string param_string = "";
        bool at_least_one = false;
        foreach (var p in m.get_async_begin_parameters ()) {
            if (at_least_one)
                param_string += ", ";
            param_string += Server.get_symbol_data_type (p, false, null, true);
            at_least_one = true;
        }
        completions.add_all_array(new CompletionItem []{
            new CompletionItem.from_symbol (m, CompletionItemKind.Method,
                new MarkupContent.plaintext ("Begin asynchronous operation"), "begin"),
            new CompletionItem.from_symbol (m.get_end_method (), CompletionItemKind.Method,
	    	new MarkupContent.plaintext ("Get results of asynchronous operation"))
        });
    }

    /**
     * see `vala/valamemberaccess.vala`
     * This determines whether we can access a symbol in the current scope.
     */
    bool is_symbol_accessible (Vala.Symbol member, Vala.Scope current_scope) {
        if (member.access == Vala.SymbolAccessibility.PROTECTED && member.parent_symbol is Vala.TypeSymbol) {
            var target_type = (Vala.TypeSymbol) member.parent_symbol;
            bool in_subtype = false;

            for (Vala.Symbol? this_symbol = current_scope.owner; 
                 this_symbol != null;
                 this_symbol = this_symbol.parent_symbol) {
                if (this_symbol == target_type) {
                    in_subtype = true;
                    break;
                }

                var cl = this_symbol as Vala.Class;
                if (cl != null && cl.is_subtype_of (target_type)) {
                    in_subtype = true;
                    break;
                }
            }

            return in_subtype;
        } else if (member.access == Vala.SymbolAccessibility.PRIVATE) {
            var target_type = member.parent_symbol;
            bool in_target_type = false;

            for (Vala.Symbol? this_symbol = current_scope.owner;
                 this_symbol != null;
                 this_symbol = this_symbol.parent_symbol) {
                if (this_symbol == target_type) {
                    in_target_type = true;
                    break;
                }
            }

            return in_target_type;
        }
        return true;
    }

    Vala.Scope get_scope_containing_node (Vala.CodeNode code_node) {
        Vala.Scope? best = null;

        for (Vala.CodeNode? node = code_node; node != null; node = node.parent_node) {
            if (node is Vala.Symbol) {
                var sym = (Vala.Symbol) node;
                best = sym.scope;
                break;
            }
        }

        assert (best != null);

        return (!) best;
    }

    Vala.Scope get_topmost_scope (Vala.Scope topmost) {
        for (Vala.Scope? current_scope = topmost;
             current_scope != null;
             current_scope = current_scope.parent_scope)
            topmost = current_scope;

        return topmost;
    }
}
