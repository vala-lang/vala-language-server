using Gee;
using LanguageServer;

namespace Vls.SignatureHelpEngine {
    void begin_response (Server lang_serv, Project project,
                         Jsonrpc.Client client, Variant id, string method,
                         Vala.SourceFile doc, Compilation compilation,
                         Position pos) {
        // long idx = (long) Util.get_string_pos (doc.content, pos.line, pos.character);

        // if (idx >= 2 && doc.content[idx-1:idx] == "(") {
        //     debug ("[textDocument/signatureHelp] possible argument list");
        // } else if (idx >= 1 && doc.content[idx-1:idx] == ",") {
        //     debug ("[textDocument/signatureHelp] possible ith argument in list");
        // }

        var signatures = new ArrayList<SignatureInformation> ();
        int active_param = -1;

        Vala.CodeContext.push (compilation.code_context);
        // debug ("[%s] extracting expression ...", method);
        var se = new SymbolExtractor (pos, doc, compilation.code_context);
        if (se.extracted_expression != null) {
#if !VALA_FEATURE_INITIAL_ARGUMENT_COUNT
            active_param = se.method_arguments - 1;
#endif
            show_help (lang_serv, project, method, se.extracted_expression, se.block.scope, signatures, ref active_param);
        } else {
            // debug ("[%s] could not get extracted expression", method);
        }

        if (signatures.is_empty) {
            lang_serv.wait_for_context_update (id, request_cancelled => {
                if (request_cancelled) {
                    Server.reply_null (id, client, method);
                    return;
                }

                Vala.CodeContext.push (compilation.code_context);
                show_help_with_updated_context (lang_serv, project,
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

    void show_help (Server lang_serv, Project project,
                    string method, Vala.CodeNode result, Vala.Scope scope,
                    Collection<SignatureInformation> signatures,
                    ref int active_param) {
        if (result is Vala.ExpressionStatement) {
            var estmt = result as Vala.ExpressionStatement;
            result = estmt.expression;
            // debug (@"[$method] peeling away expression statement: $(result)");
        }

        var si = new SignatureInformation ();
        Vala.List<Vala.Parameter>? param_list = null;
        // The explicit symbol referenced, like a local variable
        // or a method. Could be null if we invoke an array element, 
        // for example.
        Vala.Symbol? explicit_sym = null;
        // The data type of the expression
        Vala.DataType? data_type = null;
        Vala.List<Vala.DataType>? method_type_arguments = null;
        // either "begin" or "end" or null
        string? coroutine_name = null;

        if (result is Vala.MethodCall) {
            var mc = result as Vala.MethodCall;
            // var arg_list = mc.get_argument_list ();
            // TODO: NamedArgument's, whenever they become supported in upstream
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
            active_param = mc.initial_argument_count - 1;
#endif
            if (active_param < 0)
                active_param = 0;
            // foreach (var arg in arg_list) {
            //     debug (@"[$method] $mc: found argument ($arg)");
            // }

            // get the method type from the expression
            data_type = mc.call.value_type;
            explicit_sym = mc.call.symbol_reference;

            // this is only true if we have a call to a default constructor of `this` or `base`
            if (data_type is Vala.ObjectType || data_type is Vala.StructValueType) {
                Vala.CreationMethod? cm = null;

                for (var current_scope = scope; current_scope != null && cm == null;
                        current_scope = current_scope.parent_scope)
                    cm = current_scope.owner as Vala.CreationMethod;

                // Only show signature help for `this` or `base` accesses within a constructor.
                if (cm == null)
                    return;

                // If we have a call to a default constructor for either the
                // current class/struct or a base class/struct, then data_type
                // will either be an ObjectType or StructValueType instead of a
                // CallableType, and explicit_sym will refer to the class or
                // struct. In this case, we want explicit_sym to refer to the default
                // constructor for the type instead.
                if (data_type is Vala.ObjectType) {
                    var ots = ((Vala.ObjectType)data_type).object_type_symbol;
                    if (ots is Vala.Class)
                        explicit_sym = ((Vala.Class)ots).default_construction_method;
                } else {
                    var ts = ((Vala.StructValueType)data_type).type_symbol;
                    if (ts is Vala.Struct)
                        explicit_sym = ((Vala.Struct)ts).default_construction_method;
                }
            } else if (mc.call is Vala.MemberAccess)
                method_type_arguments = ((Vala.MemberAccess)mc.call).get_type_arguments ();

            if (data_type is Vala.CallableType)
                param_list = ((Vala.CallableType)data_type).get_parameters ();
            else if (data_type is Vala.ObjectType)
                param_list = ((Vala.ObjectType)data_type).get_parameters ();

            if (data_type is Vala.MethodType) {
                var mt = (Vala.MethodType) data_type;

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
                        explicit_sym = mt.method_symbol.get_end_method ();
                        coroutine_name = null;  // .end() is its own method
                    } else if (coroutine_name != null) {
                        debug (@"[$method] coroutine name `$coroutine_name' not handled");
                    }
                }
            }

            // now make data_type refer to the parent expression's type (if it exists)
            // note: if this is a call like `this(...)` or `base(...)`, then the data_type
            // will already be the parent type of the implied default constructor
            if (!(data_type is Vala.ObjectType || data_type is Vala.StructValueType)) {
                data_type = null;
                if (mc.call is Vala.MemberAccess && ((Vala.MemberAccess)mc.call).inner != null)
                    data_type = ((Vala.MemberAccess)mc.call).inner.value_type;
            }
        } else if (result is Vala.ObjectCreationExpression
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
                    && ((Vala.ObjectCreationExpression)result).initial_argument_count != -1
#endif
        ) {
            var oce = result as Vala.ObjectCreationExpression;
            // var arg_list = oce.get_argument_list ();
            // TODO: NamedArgument's, whenever they become supported in upstream
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
            active_param = oce.initial_argument_count - 1;
#endif
            if (active_param < 0)
                active_param = 0;
            // foreach (var arg in arg_list) {
            //     debug (@"$oce: found argument ($arg)");
            // }

            explicit_sym = oce.symbol_reference;
            data_type = oce.value_type;
            if (oce.member_name != null)
                method_type_arguments = oce.member_name.get_type_arguments ();

            if (explicit_sym == null && oce.member_name != null) {
                explicit_sym = oce.member_name.symbol_reference;
                // debug (@"[textDocument/signatureHelp] explicit_sym = $explicit_sym $(explicit_sym.type_name)");
            }

            if (explicit_sym != null && explicit_sym is Vala.Callable) {
                var callable_sym = explicit_sym as Vala.Callable;
                param_list = callable_sym.get_parameters ();
            }
        } else {
            // debug (@"[$method] %s neither a method call nor (complete) object creation expr", result.to_string ());
            return;     // early exit
        }

        if (explicit_sym == null && data_type == null) {
            // debug (@"[$method] could not get explicit_sym and data_type from $(result.type_name)");
            return;     // early exit
        }

        si.label = CodeHelp.get_symbol_representation (data_type, explicit_sym, scope, method_type_arguments);
        DocComment? doc_comment = null;
        if (explicit_sym != null) {
            doc_comment = lang_serv.get_symbol_documentation (project, explicit_sym);
            if (doc_comment != null) {
                si.documentation = new MarkupContent.from_markdown (doc_comment.body);
                if (doc_comment.return_body != null)
                    si.documentation.value += "\n\n---\n**returns** " + doc_comment.return_body;
            }
        }

        if (param_list != null) {
            foreach (var parameter in param_list) {
                var param_doc_comment = doc_comment != null ? doc_comment.parameters[parameter.name] : null;
                si.parameters.add (new ParameterInformation () {
                    label = CodeHelp.get_symbol_representation (data_type, parameter, scope, method_type_arguments),
                    documentation = param_doc_comment != null ? new MarkupContent.from_markdown (param_doc_comment) : null
                });
                // debug (@"found parameter $parameter (name = $(parameter.ellipsis ? "..." :parameter.name))");
            }
            if (!si.parameters.is_empty)
                signatures.add (si);
        }
    }

    void show_help_with_updated_context (Server lang_serv, Project project,
                                         string method,
                                         Vala.SourceFile doc, Compilation compilation,
                                         Position pos,
                                         Collection<SignatureInformation> signatures, ref int active_param) {
        var fs = new FindSymbol (doc, pos, true);

        // filter the results for MethodCall's and ExpressionStatements
        var fs_results = fs.result;
        fs.result = new Gee.ArrayList<Vala.CodeNode> ();

        foreach (var res in fs_results) {
            // debug (@"[textDocument/signatureHelp] found $(res.type_name) (semanalyzed = $(res.checked))");
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
            // debug (@"[$method] no results found");
            return;     // early exit
        }

        Vala.CodeNode result = Server.get_best (fs, doc);
        Vala.Scope scope = CodeHelp.get_scope_containing_node (result);
        // debug (@"[$method] got best: $(result.type_name) @ $(result.source_reference)");

        show_help (lang_serv, project, method, result, scope, signatures, ref active_param);
    }

    void finish (Jsonrpc.Client client, Variant id, Collection<SignatureInformation> signatures, int active_param) {
        var json_array = new Json.Array ();

        foreach (var sinfo in signatures)
            json_array.add_element (Json.gobject_serialize (sinfo));

        try {
            // debug ("sending with active_param = %d", active_param);
            client.reply (id, Util.object_to_variant (new SignatureHelp () {
                signatures = signatures,
                activeParameter = active_param
            }), Server.cancellable);
        } catch (Error e) {
            warning (@"[textDocument/signatureHelp] failed to reply to client: $(e.message)");
        }
    }
}
