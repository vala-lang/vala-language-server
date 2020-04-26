using Gee;
using LanguageServer;

namespace Vls.SignatureHelpEngine {
    void begin_response (Server lang_serv,
                         Jsonrpc.Client client, Variant id, string method,
                         Vala.SourceFile doc, Compilation compilation,
                         Position pos) {
        long idx = (long) Util.get_string_pos (doc.content, pos.line, pos.character);

        if (idx >= 2 && doc.content[idx-1:idx] == "(") {
            debug ("[textDocument/signatureHelp] possible argument list");
        } else if (idx >= 1 && doc.content[idx-1:idx] == ",") {
            debug ("[textDocument/signatureHelp] possible ith argument in list");
        }

        var signatures = new ArrayList<SignatureInformation> ();
        int active_param = 0;

        Vala.CodeContext.push (compilation.code_context);
        var se = new SymbolExtractor (pos, doc, compilation.code_context);
        if (se.extracted_expression != null)
            show_help (lang_serv, method, se.extracted_expression, signatures, ref active_param);
        
        if (signatures.is_empty) {
            lang_serv.wait_for_context_update (id, request_cancelled => {
                if (request_cancelled) {
                    Server.reply_null (id, client, method);
                    return;
                }

                Vala.CodeContext.push (compilation.code_context);
                show_help_with_updated_context (lang_serv,
                                                method,
                                                doc, compilation, pos, 
                                                signatures, ref active_param);
                
                if (!signatures.is_empty)
                    finish (client, id, signatures, active_param);
                else
                    Server.reply_null (id, client, method);
                Vala.CodeContext.pop ();
            });
        } else {
            finish (client, id, signatures, active_param);
        }
        Vala.CodeContext.pop ();
    }

    void show_help (Server lang_serv,
                    string method, Vala.CodeNode result,
                    Collection<SignatureInformation> signatures,
                    ref int active_param) {
        if (result is Vala.ExpressionStatement) {
            var estmt = result as Vala.ExpressionStatement;
            result = estmt.expression;
            debug (@"[$method] peeling away expression statement: $(result)");
        }

        var si = new SignatureInformation ();
        Vala.List<Vala.Parameter>? param_list = null;
        // The explicit symbol referenced, like a local variable
        // or a method. Could be null if we invoke an array element, 
        // for example.
        Vala.Symbol? explicit_sym = null;
        // The symbol referenced indirectly
        Vala.Symbol? type_sym = null;
        // The parent symbol (useful for creation methods)
        Vala.Symbol? parent_sym = null;
        // either "begin" or "end" or null
        string? coroutine_name = null;

        if (result is Vala.MethodCall) {
            var mc = result as Vala.MethodCall;
            var arg_list = mc.get_argument_list ();
            // TODO: NamedArgument's, whenever they become supported in upstream
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
            active_param = mc.initial_argument_count - 1;
#endif
            if (active_param < 0)
                active_param = 0;
            foreach (var arg in arg_list) {
                debug (@"[$method] $mc: found argument ($arg)");
            }

            // get the method type from the expression
            Vala.DataType data_type = mc.call.value_type;
            explicit_sym = mc.call.symbol_reference;

            if (data_type is Vala.CallableType) {
                var ct = data_type as Vala.CallableType;
                param_list = ct.get_parameters ();
    
                if (ct is Vala.DelegateType) {
                    var dt = ct as Vala.DelegateType;
                    type_sym = dt.delegate_symbol;
                } else if (ct is Vala.MethodType) {
                    var mt = ct as Vala.MethodType;
                    type_sym = mt.method_symbol;

                    // handle special cases for .begin() and .end() in coroutines (async methods)
                    if (mc.call is Vala.MemberAccess && mt.method_symbol.coroutine &&
                        (explicit_sym == null || (((Vala.MemberAccess)mc.call).inner).symbol_reference == explicit_sym)) {
                        coroutine_name = ((Vala.MemberAccess)mc.call).member_name ?? "";
                        if (coroutine_name[0] == 'S')   // is possible because of incomplete member access
                            coroutine_name = null;
                        if (coroutine_name == "begin")
                            param_list = mt.method_symbol.get_async_begin_parameters ();
                        else if (coroutine_name == "end") {
                            param_list = mt.method_symbol.get_async_end_parameters ();
                            type_sym = mt.method_symbol.get_end_method ();
                            coroutine_name = null;  // .end() is its own method
                        } else if (coroutine_name != null) {
                            debug (@"[$method] coroutine name `$coroutine_name' not handled");
                        }
                    }
                } else if (ct is Vala.SignalType) {
                    var st = ct as Vala.SignalType;
                    type_sym = st.signal_symbol;
                }
            }
        } else if (result is Vala.ObjectCreationExpression
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
                    && ((Vala.ObjectCreationExpression)result).initial_argument_count != -1
#endif
        ) {
            var oce = result as Vala.ObjectCreationExpression;
            var arg_list = oce.get_argument_list ();
            // TODO: NamedArgument's, whenever they become supported in upstream
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
            active_param = oce.initial_argument_count - 1;
#endif
            if (active_param < 0)
                active_param = 0;
            foreach (var arg in arg_list) {
                debug (@"$oce: found argument ($arg)");
            }

            explicit_sym = oce.symbol_reference;

            if (explicit_sym == null && oce.member_name != null) {
                explicit_sym = oce.member_name.symbol_reference;
                debug (@"[textDocument/signatureHelp] explicit_sym = $explicit_sym $(explicit_sym.type_name)");
            }

            if (explicit_sym != null && explicit_sym is Vala.Callable) {
                var callable_sym = explicit_sym as Vala.Callable;
                param_list = callable_sym.get_parameters ();
            }

            parent_sym = explicit_sym.parent_symbol;
        } else {
            debug (@"[$method] %s neither a method call nor (complete) object creation expr", result.to_string ());
            return;     // early exit
        } 

        if (explicit_sym == null && type_sym == null) {
            debug (@"[$method] could not get explicit_sym and type_sym from $(result.type_name)");
            return;     // early exit
        }

        if (explicit_sym == null) {
            si.label = Server.get_symbol_data_type (type_sym, false, null, true);
            si.documentation = lang_serv.get_symbol_documentation (type_sym);
        } else {
            // TODO: need a function to display symbol names correctly given context
            if (type_sym != null) {
                si.label = Server.get_symbol_data_type (type_sym, false, null, true, coroutine_name);
                si.documentation = lang_serv.get_symbol_documentation (type_sym);
            } else {
                si.label = Server.get_symbol_data_type (explicit_sym, false, parent_sym, true, coroutine_name);
            }
            // try getting the documentation for the explicit symbol
            // if the type does not have any documentation
            if (si.documentation == null)
                si.documentation = lang_serv.get_symbol_documentation (explicit_sym);
        }

        if (param_list != null) {
            foreach (var parameter in param_list) {
                si.parameters.add (new ParameterInformation () {
                    label = Server.get_symbol_data_type (parameter, false, null, true),
                    documentation = lang_serv.get_symbol_documentation (parameter)
                });
                debug (@"found parameter $parameter (name = $(parameter.ellipsis ? "..." :parameter.name))");
            }
            signatures.add (si);
        }
    }

    void show_help_with_updated_context (Server lang_serv,
                                         string method,
                                         Vala.SourceFile doc, Compilation compilation,
                                         Position pos,
                                         Collection<SignatureInformation> signatures, ref int active_param) {
        var fs = new FindSymbol (doc, pos, true);

        // filter the results for MethodCall's and ExpressionStatements
        var fs_results = fs.result;
        fs.result = new Gee.ArrayList<Vala.CodeNode> ();

        foreach (var res in fs_results) {
            debug (@"[textDocument/signatureHelp] found $(res.type_name) (semanalyzed = $(res.checked))");
            if (res is Vala.ExpressionStatement || res is Vala.MethodCall
                || res is Vala.ObjectCreationExpression)
                fs.result.add (res);
        }

        if (fs.result.size == 0 && fs_results.size > 0) {
            // In cases where our cursor is to the right of a method call and
            // not inside it (most likely because the right parenthesis is omitted),
            // we might not find any MethodCall or ExpressionStatements, so instead
            // look at whatever we found and see if it is a child of what we want.
            foreach (var res in fs_results) {
                // walk up tree
                for (Vala.CodeNode? x = res; x != null; x = x.parent_node)
                    if (x is Vala.ExpressionStatement || x is Vala.MethodCall)
                        fs.result.add (x);
            }
        }

        if (fs.result.size == 0) {
            debug (@"[$method] no results found");
            return;     // early exit
        }

        Vala.CodeNode result = Server.get_best (fs, doc);
        debug (@"[$method] got best: $(result.type_name) @ $(result.source_reference)");

        show_help (lang_serv, method, result, signatures, ref active_param);
    }

    void finish (Jsonrpc.Client client, Variant id, Collection<SignatureInformation> signatures, int active_param) {
        var json_array = new Json.Array ();

        foreach (var sinfo in signatures)
            json_array.add_element (Json.gobject_serialize (sinfo));

        try {
            client.reply (id, Util.object_to_variant (new SignatureHelp () {
                signatures = signatures,
                activeParameter = active_param
            }), Server.cancellable);
        } catch (Error e) {
            debug (@"[textDocument/signatureHelp] failed to reply to client: $(e.message)");
        }
    }
}