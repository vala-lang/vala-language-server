/* signaturehelpengine.vala
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

using Gee;
using Lsp;

namespace Vls.SignatureHelpEngine {
    async void begin_response_async (Server lang_serv, Project project,
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
            show_help (lang_serv,
                       project,
                       method, se.extracted_expression, se.block.scope, compilation,
                       signatures, ref active_param);
        } else {
            // debug ("[%s] could not get extracted expression", method);
        }
        
        if (signatures.is_empty) {
            if (!yield lang_serv.wait_for_context_update_async (id, method)) {
                Vala.CodeContext.pop ();
                yield Server.reply_null_async (id, client, method);
                return;
            }

            show_help_with_updated_context (lang_serv, project,
                                            method,
                                            doc, compilation, pos, 
                                            signatures, ref active_param);
        }

        Vala.CodeContext.pop ();
        if (signatures.is_empty)
            yield Server.reply_null_async (id, client, method);
        else
            yield finish_async (client, id, signatures, active_param);
    }

    void show_help (Server lang_serv, Project project,
                    string method, Vala.CodeNode result, Vala.Scope scope,
                    Compilation compilation,
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
        Vala.List<Vala.Parameter>? ellipsis_override_params = null;
        // either "begin" or "end" or null
        string? coroutine_name = null;

        if (result is Vala.MethodCall) {
            var mc = result as Vala.MethodCall;
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

                if (mt.method_symbol.printf_format || mt.method_symbol.scanf_format) {
                    ellipsis_override_params = generate_parameters_for_printf_method (mt.method_symbol, mc, compilation.code_context,
                                                                                      param_list != null ? param_list.size - 1 : 0);
                    if (ellipsis_override_params != null) {
                        var new_param_list = new Vala.ArrayList<Vala.Parameter> ();
                        // replace '...' with generated params
                        if (param_list != null) {
                            foreach (var parameter in param_list) {
                                if (parameter.ellipsis)
                                    break;
                                new_param_list.add (parameter);
                            }
                        }
                        new_param_list.add_all (ellipsis_override_params);
                        param_list = new_param_list;
                    }
                } else {
                    // handle special cases for .begin() and .end() in coroutines (async methods)
                    string[] async_methods = {"begin", "end"};
                    if (mc.call is Vala.MemberAccess && mt.method_symbol.coroutine
                        && ((Vala.MemberAccess)mc.call).member_name in async_methods) {
                        coroutine_name = ((Vala.MemberAccess)mc.call).member_name;
                        if (coroutine_name == "begin") {
                            param_list = mt.method_symbol.get_async_begin_parameters ();
                        } else if (coroutine_name == "end") {
                            param_list = mt.method_symbol.get_async_end_parameters ();
                            explicit_sym = mt.method_symbol.get_end_method ();
                        }
                    }
                }
            }

            // now make data_type refer to the parent expression's type (if it exists)
            // note: if this is a call like `this(...)` or `base(...)`, then the data_type
            // will already be the parent type of the implied default constructor
            if (!(data_type is Vala.ObjectType || data_type is Vala.StructValueType || data_type is Vala.DelegateType)) {
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

        si.label = CodeHelp.get_symbol_representation (data_type, explicit_sym, scope, true, method_type_arguments,
                                                       coroutine_name, true, false, ellipsis_override_params);
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
                    label = CodeHelp.get_symbol_representation (data_type, parameter, scope, false, method_type_arguments),
                    documentation = param_doc_comment != null ? new MarkupContent.from_markdown (param_doc_comment) : null
                });
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

        show_help (lang_serv, project, method, result, scope, compilation, signatures, ref active_param);
    }

    async void finish_async (Jsonrpc.Client client, Variant id, Collection<SignatureInformation> signatures, int active_param) {
        try {
            // debug ("sending with active_param = %d", active_param);
            yield client.reply_async (id, Util.object_to_variant (new SignatureHelp () {
                signatures = signatures,
                activeParameter = active_param
            }), Server.cancellable);
        } catch (Error e) {
            warning (@"[textDocument/signatureHelp] failed to reply to client: $(e.message)");
        }
    }

    Vala.List<Vala.Parameter>? generate_parameters_for_printf_method (Vala.Method method,
                                                                      Vala.MethodCall mc,
                                                                      Vala.CodeContext context,
                                                                      int initial_arg_count) {
        debug ("generating printf-style arguments for %s", CodeHelp.get_symbol_name_representation (method, null));

        var format_literal = mc.get_format_literal ();

        // if a format literal wasn't found, try to hack our way to a solution
        if (format_literal == null && (method.printf_format || method.scanf_format)) {
            // first handle the case <string literal>.printf ()
            if (mc.call is Vala.MemberAccess)
                format_literal = ((Vala.MemberAccess)mc.call).inner as Vala.StringLiteral;

            // if that fails, try to get the first argument as the string literal
            if (format_literal == null && !mc.get_argument_list ().is_empty)
                format_literal = mc.get_argument_list ().first () as Vala.StringLiteral;
        }

        if (format_literal == null) {
            // debug ("could not get format literal");
            return null;
        }


        string format = format_literal.eval ();
        unowned string format_it = format;
        unichar format_char = format_it.get_char ();

        // debug ("iterating through format literal `%s` ...", format);

        var generated_params = new Vala.ArrayList<Vala.Parameter> ();

        while (format_char != '\0') {
            if (format_char != '%') {
                format_it = format_it.next_char ();
                format_char = format_it.get_char ();
                continue;
            }

            format_it = format_it.next_char ();
            format_char = format_it.get_char ();

            // flags
            while (format_char == '#' || format_char == '0' || format_char == '-' || format_char == ' ' || format_char == '+') {
                format_it = format_it.next_char ();
                format_char = format_it.get_char ();
            }
            // field width
            while (format_char >= '0' && format_char <= '9') {
                format_it = format_it.next_char ();
                format_char = format_it.get_char ();
            }
            // precision
            if (format_char == '.') {
                format_it = format_it.next_char ();
                format_char = format_it.get_char ();
                while (format_char >= '0' && format_char <= '9') {
                    format_it = format_it.next_char ();
                    format_char = format_it.get_char ();
                }
            }
            // length modifier
            int length = 0;
            if (format_char == 'h') {
                length = -1;
                format_it = format_it.next_char ();
                format_char = format_it.get_char ();
                if (format_char == 'h') {
                    length = -2;
                    format_it = format_it.next_char ();
                    format_char = format_it.get_char ();
                }
            } else if (format_char == 'l') {
                length = 1;
                format_it = format_it.next_char ();
                format_char = format_it.get_char ();
            } else if (format_char == 'z') {
                length = 2;
                format_it = format_it.next_char ();
                format_char = format_it.get_char ();
            }
            // conversion specifier
            Vala.DataType? param_type = null;
            if (format_char == 'd' || format_char == 'i' || format_char == 'c') {
                // integer
                if (length == -2) {
                    param_type = context.analyzer.int8_type;
                } else if (length == -1) {
                    param_type = context.analyzer.short_type;
                } else if (length == 0) {
                    param_type = context.analyzer.int_type;
                } else if (length == 1) {
                    param_type = context.analyzer.long_type;
                } else if (length == 2) {
                    param_type = context.analyzer.ssize_t_type;
                }
            } else if (format_char == 'o' || format_char == 'u' || format_char == 'x' || format_char == 'X') {
                // unsigned integer
                if (length == -2) {
                    param_type = context.analyzer.uchar_type;
                } else if (length == -1) {
                    param_type = context.analyzer.ushort_type;
                } else if (length == 0) {
                    param_type = context.analyzer.uint_type;
                } else if (length == 1) {
                    param_type = context.analyzer.ulong_type;
                } else if (length == 2) {
                    param_type = context.analyzer.size_t_type;
                }
            } else if (format_char == 'e' || format_char == 'E' || format_char == 'f' || format_char == 'F'
                       || format_char == 'g' || format_char == 'G' || format_char == 'a' || format_char == 'A') {
                // double
                param_type = context.analyzer.double_type;
            } else if (format_char == 's') {
                // string
                param_type = context.analyzer.string_type;
            } else if (format_char == 'p') {
                // pointer
                param_type = new Vala.PointerType (new Vala.VoidType ());
            } else if (format_char == '%') {
                // literal %
            } else {
                break;
            }
            if (param_type == null)
                param_type = new Vala.InvalidType ();
            var parameter = new Vala.Parameter ("arg%d".printf (initial_arg_count + generated_params.size), param_type);
            if (method.scanf_format && !(param_type is Vala.ReferenceType))
                parameter.direction = Vala.ParameterDirection.OUT;
            generated_params.add (parameter);
            if (format_char != '\0') {
                format_it = format_it.next_char ();
                format_char = format_it.get_char ();
            }
        }

        return generated_params;
    }
}
