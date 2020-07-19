using LanguageServer;
using Gee;

/**
 * A backwards parser that makes extraordinary attempts to find the current
 * symbol at the cursor. This is less accurate than the Vala parser.
 */
class Vls.SymbolExtractor : Object {
    /**
     * Represents a fake expression that the SE extracted.
     */
    abstract class FakeExpr {
        public FakeExpr? inner { get; private set; }

        protected FakeExpr (FakeExpr? inner) {
            this.inner = inner;
        }

        public abstract string to_string ();
    }

    class FakeMemberAccess : FakeExpr {
        public string member_name { get; private set; }
        public ArrayList<FakeMemberAccess> type_arguments { get; private set; }

        public FakeMemberAccess (string member_name, ArrayList<FakeMemberAccess>? type_arguments = null, FakeExpr? inner = null) {
            base (inner);
            this.member_name = member_name;
            this.type_arguments = type_arguments ?? new ArrayList<FakeMemberAccess> ();
        }

        public override string to_string () {
            if (inner != null)
                return @"$inner.$member_name";
            return member_name;
        }
    }

    class FakeMethodCall : FakeExpr {
        public int arguments_count { get; private set; }
        public FakeMemberAccess member_access {
            get { return (FakeMemberAccess) inner; }
        }

        public FakeMethodCall (int arguments_count, FakeMemberAccess member_access) {
            base (member_access);
            this.arguments_count = arguments_count;
        }

        public override string to_string () {
            return @"$member_access ([$arguments_count arg(s)])";
        }
    }

    class FakeObjectCreationExpr : FakeExpr {
        private FakeObjectCreationExpr () { base (null); }

        public FakeObjectCreationExpr.with_method_call (FakeMethodCall method_call) {
            base (method_call);
        }

        public FakeObjectCreationExpr.with_member_access (FakeMemberAccess member_access) {
            base (member_access);
        }

        public override string to_string () {
            return @"new $inner";
        }
    }

    class FakeEmptyExpr : FakeExpr {
        public FakeEmptyExpr () {
            base (null);
        }

        public override string to_string () {
            return "<empty>";
        }
    }

    abstract class FakeLiteral : FakeExpr {
        public string value { get; private set; }
        protected FakeLiteral (string value) {
            base (null);
            this.value = value;
        }
    }

    class FakeStringLiteral : FakeLiteral {
        public FakeStringLiteral (string value) {
            base (value);
        }

        public override string to_string () {
            return @"\"$value\"";
        }
    }

    class FakeRealLiteral : FakeLiteral {
        public FakeRealLiteral (string value) {
            base (value);
        }

        public override string to_string () {
            return @"(real) $value";
        }
    }

    class FakeIntegerLiteral : FakeLiteral {
        public FakeIntegerLiteral (string value) {
            base (value);
        }

        public override string to_string () {
            return @"(integer) $value";
        }
    }

    class FakeBooleanLiteral : FakeLiteral {
        public bool bool_value { get; private set; }

        public FakeBooleanLiteral (string value) {
            assert (value == "true" || value == "false");
            base (value);
            bool_value = value == "true";
        }

        public override string to_string () {
            return @"(bool) $value";
        }
    }

    class FakeCharacterLiteral : FakeLiteral {
        public FakeCharacterLiteral (string value) {
            base (value);
        }

        public override string to_string () {
            return @"(char) $value";
        }
    }

    private long idx;
    private Position pos;
    public Vala.Symbol block { get; private set; }
    private Vala.SourceFile source_file;
    private Vala.CodeContext context;

    private bool attempted_extract_expression;
    private Vala.Expression? _extracted_expression;
    public Vala.Expression? extracted_expression {
        get {
            if (_extracted_expression == null && !attempted_extract_expression)
                compute_extracted_expression ();
            return _extracted_expression;
        }
    }


#if !VALA_FEATURE_INITIAL_ARGUMENT_COUNT
    /**
     * If extracted_expression is a method call, this is the number of
     * arguments supplied to that method call.
     * This feature is only used if the version of Vala VLS was compiled
     * with lacks initial_argument_count fields for `Vala.MethodCall`
     */
    public int method_arguments { get; private set; default = -1; }
#endif

    public SymbolExtractor (Position pos, Vala.SourceFile source_file, Vala.CodeContext? context = null) {
        this.idx = (long) Util.get_string_pos (source_file.content, pos.line, pos.character);
        this.pos = pos;
        this.source_file = source_file;
        if (context != null)
            this.context = context;
        else {
            assert (Vala.CodeContext.get () == source_file.context);
            this.context = source_file.context;
        }
        this.block = new FindScope (source_file, pos).best_block;
    }

    private Pair<Vala.Symbol, Vala.Symbol>? find_variable_visible_in_block (string variable_name, Vala.Symbol closest_block) {
        Vala.Block? actual_block = null;

        if (closest_block is Vala.Block)
            actual_block = (Vala.Block) closest_block;
        else if (closest_block is Vala.Method)
            actual_block = ((Vala.Method) closest_block).body;
        else {
            var member = Vala.SemanticAnalyzer.symbol_lookup_inherited (closest_block, variable_name);
            if (member != null)
                return new Pair<Vala.Symbol, Vala.Symbol> (member, closest_block);
            // try base types
            if (closest_block is Vala.Class) {
                var cl = (Vala.Class) closest_block;
                foreach (var base_type in cl.get_base_types ()) {
                    member = Vala.SemanticAnalyzer.symbol_lookup_inherited (base_type.type_symbol, variable_name);
                    if (member != null)
                        return new Pair<Vala.Symbol, Vala.Symbol> (member, closest_block);
                }
            } else if (closest_block is Vala.Interface) {
                var iface = (Vala.Interface) closest_block;
                foreach (var prereq_type in iface.get_prerequisites ()) {
                    member = Vala.SemanticAnalyzer.symbol_lookup_inherited (prereq_type.type_symbol, variable_name);
                    if (member != null)
                        return new Pair<Vala.Symbol, Vala.Symbol> (member, closest_block);
                }
            }
        }

        if (actual_block != null) {
            foreach (var lconst in actual_block.get_local_constants ())
                if (lconst.name == variable_name)
                    return new Pair<Vala.Symbol, Vala.Symbol> (lconst, actual_block.parent_symbol);
            foreach (var lvar in actual_block.get_local_variables ())
                if (lvar.name == variable_name)
                    return new Pair<Vala.Symbol, Vala.Symbol> (lvar, actual_block.parent_symbol);
        }

        // attempt parent block if we didn't succeed
        if (closest_block.parent_symbol != null)
            return find_variable_visible_in_block (variable_name, (!) closest_block.parent_symbol);
        else {
            // otherwise, as a final attempt, look in the imported using directives
            foreach (var ud in source_file.current_using_directives) {
                var ns = (Vala.Namespace) ud.namespace_symbol;
                var member = Vala.SemanticAnalyzer.symbol_lookup_inherited (ns, variable_name);

                if (member != null)
                    return new Pair<Vala.Symbol, Vala.Symbol> (member, ns);
            }
        }

        return null;
    }

    static Vala.CallableType? get_callable_type_for_callable (Vala.Callable callable) {
        if (callable is Vala.Method)
            return new Vala.MethodType ((Vala.Method) callable);
        if (callable is Vala.Signal)
            return new Vala.SignalType ((Vala.Signal) callable);
        if (callable is Vala.DelegateType)
            return new Vala.DelegateType ((Vala.Delegate) callable);
        critical ("unknown Callable node %s", callable.type_name);
        return null;
    }

    static Vala.DataType? get_data_type_for_symbol (Vala.Symbol symbol) {
        if (symbol is Vala.Variable)
            return ((Vala.Variable)symbol).variable_type;
        else if (symbol is Vala.Property)
            return ((Vala.Property)symbol).property_type;
        else if (symbol is Vala.Callable)
            return get_callable_type_for_callable ((Vala.Callable)symbol);
        return null;
    }

    /**
     * Reinterprets a member access as a data type. For example, if we have `Vala.List<int>`,
     * this is a member access (`Vala` and then `List`) that is a type symbol with parameter `int`. 
     * This method handles the type arguments of the member access so that they become the type 
     * arguments of the data type.
     *
     * @return the new data type, or invalid if the member access is not of a type symbol
     */
    private Vala.DataType? convert_member_access_to_data_type (Vala.MemberAccess ma_expr) {
        var data_type = Vala.SemanticAnalyzer.get_data_type_for_symbol (ma_expr.symbol_reference);
        var data_type_type_arguments = data_type.get_type_arguments ();
        // add type arguments of this type argument, if there are any
        // NOTE: we can't get this information through type_expr.value_type; we must get it from the type arguments
        var type_arguments = ma_expr.get_type_arguments ();
        if (type_arguments != null) {
            Vala.List<Vala.TypeParameter>? type_parameters = null;
            if (ma_expr.symbol_reference is Vala.ObjectTypeSymbol)
                type_parameters = ((Vala.ObjectTypeSymbol)ma_expr.symbol_reference).get_type_parameters ();
            else if (ma_expr.symbol_reference is Vala.Struct)
                type_parameters = ((Vala.Struct)ma_expr.symbol_reference).get_type_parameters ();
            if (type_parameters != null) {
                foreach (var type_parameter in type_parameters) {
                    int idx = ((Vala.TypeSymbol)ma_expr.symbol_reference).get_type_parameter_index (type_parameter.name);
                    if (idx < type_arguments.size && idx < data_type_type_arguments.size)
                        data_type.replace_type (data_type_type_arguments[idx], type_arguments[idx]);
                    else
                        break;
                }
            }
        }
        data_type.value_owned = true;
        return data_type;
    }

    private Vala.Expression resolve_typed_expression (FakeExpr fake_expr) throws TypeResolutionError {
        if (fake_expr is FakeMemberAccess) {
            var fake_ma = (FakeMemberAccess) fake_expr;
            if (fake_ma.inner == null) {
                // attempt to resolve first expression
                Vala.Symbol? current_block = block;
                Vala.Symbol? resolved_sym = null;

                while (current_block != null &&
                        current_block.scope != null &&
                        resolved_sym == null) {
                    resolved_sym = current_block.scope.lookup (fake_ma.member_name);
                    if (resolved_sym == null) {
                        var symtab = current_block.scope.get_symbol_table ();
                        if (symtab != null && symtab.contains (fake_ma.member_name)) {
                            // found first part in symbol table, but the symbol was null
                            break;
                        }
                        current_block = current_block.parent_symbol;
                    }
                }

                if (resolved_sym == null) {
                    // perform exhaustive search
                    var pair = find_variable_visible_in_block (fake_ma.member_name, current_block ?? block);
                    if (pair != null) {
                        resolved_sym = pair.first;
                    } else if (fake_ma.member_name == "base") {
                        Vala.DataType? found_base_type = null;
                        // attempt to resolve this as a base access
                        for (var starting_block = current_block ?? block;
                             starting_block != null && found_base_type == null;
                             starting_block = starting_block.parent_symbol) {
                            if (starting_block is Vala.Class) {
                                foreach (var base_type in ((Vala.Class)starting_block).get_base_types ()) {
                                    if (base_type.type_symbol is Vala.Class) {
                                        found_base_type = base_type;
                                        break;
                                    }
                                }
                            } else if (starting_block is Vala.Struct) {
                                found_base_type = ((Vala.Struct) starting_block).base_type;
                            }
                        }

                        if (found_base_type != null) {
                            return new Vala.BaseAccess () {
                                symbol_reference = found_base_type.symbol,
                                value_type = found_base_type
                            };
                        }
                    }
                }

                if (resolved_sym == null) {
                    throw new TypeResolutionError.FIRST_EXPRESSION ("could not resolve symbol `%s'", fake_ma.member_name);
                }

                var expr = new Vala.MemberAccess (null, fake_ma.member_name);
                foreach (var type_argument in fake_ma.type_arguments) {
                    var type_expr = resolve_typed_expression (type_argument);
                    var data_type = convert_member_access_to_data_type ((Vala.MemberAccess)type_expr);
                    expr.add_type_argument (data_type);
                }
                expr.symbol_reference = resolved_sym;
                expr.value_type = get_data_type_for_symbol (resolved_sym);
                return expr;
            } else {
                Vala.Expression inner = resolve_typed_expression (fake_ma.inner);
                Vala.List<Vala.DataType>? method_type_arguments = null;
                Vala.Symbol? symbol;

                if (inner is Vala.MemberAccess)
                    method_type_arguments = ((Vala.MemberAccess)inner).get_type_arguments ();

                if (inner.value_type != null) {
                    symbol = Vala.SemanticAnalyzer.get_symbol_for_data_type (inner.value_type);
                    if (symbol == null)
                        throw new TypeResolutionError.NTH_EXPRESSION ("could not get symbol for inner data type");
                } else {
                    symbol = inner.symbol_reference;
                    if (symbol == null)
                        throw new TypeResolutionError.NTH_EXPRESSION ("inner expr `%s' has no symbol reference", inner.to_string ());
                }
                Vala.Symbol? member = Vala.SemanticAnalyzer.symbol_lookup_inherited (symbol, fake_ma.member_name);
                if (member == null)
                    throw new TypeResolutionError.NTH_EXPRESSION ("could not resolve member `%s' from inner", fake_ma.member_name);
                var expr = new Vala.MemberAccess (inner, fake_ma.member_name);
                foreach (var type_argument in fake_ma.type_arguments) {
                    var type_expr = resolve_typed_expression (type_argument);
                    var data_type = convert_member_access_to_data_type ((Vala.MemberAccess)type_expr);
                    expr.add_type_argument (data_type);
                }
                expr.symbol_reference = member;
                expr.value_type = get_data_type_for_symbol (member);
                if (expr.value_type != null)
                    expr.value_type = expr.value_type.get_actual_type (inner.value_type, method_type_arguments, expr);
                return expr;
            }
        } else if (fake_expr is FakeMethodCall) {
            var fake_mc = (FakeMethodCall) fake_expr;
            Vala.Expression call = resolve_typed_expression (fake_mc.inner);
            Vala.List<Vala.DataType>? method_type_arguments = null;
            if (call is Vala.MemberAccess)
                method_type_arguments = ((Vala.MemberAccess)call).get_type_arguments ();
            var expr = new Vala.MethodCall (call);
            Vala.Callable? callable;
            if (call.value_type != null) {
                callable = Vala.SemanticAnalyzer.get_symbol_for_data_type (call.value_type) as Vala.Callable;
                if (callable == null && !(fake_mc.inner is FakeMemberAccess &&
                        ((FakeMemberAccess)fake_mc.inner).member_name == "this" ||
                        ((FakeMemberAccess)fake_mc.inner).member_name == "base"))
                    throw new TypeResolutionError.NTH_EXPRESSION ("could not get callable symbol for inner data type");
            } else {
                callable = call.symbol_reference as Vala.Callable;
                // callable symbol may be null if we're in an OCE
            }
            if (callable != null)
                expr.value_type = callable.return_type;
            if (call is Vala.MemberAccess && ((Vala.MemberAccess)call).inner != null) {
                var call_inner = ((Vala.MemberAccess)call).inner;
                if (call_inner.value_type != null)
                    expr.value_type = expr.value_type.get_actual_type (call_inner.value_type, method_type_arguments, expr);
            }
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
            expr.initial_argument_count = fake_mc.arguments_count;
#endif
            return expr;
        } else if (fake_expr is FakeObjectCreationExpr) {
            var fake_oce = (FakeObjectCreationExpr) fake_expr;
            Vala.Expression inner = resolve_typed_expression ((!) fake_oce.inner);
            if (fake_oce.inner is FakeMethodCall) {
                var inner_ma = (Vala.MemberAccess) ((Vala.MethodCall) inner).call;
                var inner_sym = inner_ma.symbol_reference;
                var expr = new Vala.ObjectCreationExpression (inner_ma);
                if (inner_sym is Vala.Class) {
                    expr.symbol_reference = ((Vala.Class)inner_sym).default_construction_method;
                    expr.value_type = convert_member_access_to_data_type (inner_ma);
                } else if (inner_sym is Vala.Method) {
                    if (!(inner_sym is Vala.CreationMethod))
                        throw new TypeResolutionError.NTH_EXPRESSION ("OCE: inner expr not CreationMethod");
                    expr.symbol_reference = inner_sym;
                    expr.value_type = convert_member_access_to_data_type ((Vala.MemberAccess)inner_ma.inner);
                } else {
                    throw new TypeResolutionError.NTH_EXPRESSION ("OCE: inner expr neither Class nor method");
                }
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
                expr.initial_argument_count = ((FakeMethodCall)fake_oce.inner).arguments_count;
#endif
                return expr;
            } else {
                // inner is Vala.MemberAccess
                // this is an incomplete MA
                var inner_ma = (Vala.MemberAccess) inner;
                inner_ma.value_type = convert_member_access_to_data_type (inner_ma);
                return new Vala.ObjectCreationExpression (inner_ma);
            }
        } else if (fake_expr is FakeLiteral) {
            if (fake_expr is FakeStringLiteral) {
                var fake_str = (FakeStringLiteral) fake_expr;
                var expr = new Vala.StringLiteral (fake_str.value);
                expr.value_type = context.analyzer.string_type;
                return expr;
            } else if (fake_expr is FakeRealLiteral) {
                var fake_real = (FakeRealLiteral) fake_expr;
                var expr = new Vala.RealLiteral (fake_real.value);
                expr.value_type = context.analyzer.double_type;
                return expr;
            } else if (fake_expr is FakeIntegerLiteral) {
                var fake_int = (FakeIntegerLiteral) fake_expr;
                var expr = new Vala.IntegerLiteral (fake_int.value);
                expr.value_type = context.analyzer.int_type;
                return expr;
            } else if (fake_expr is FakeBooleanLiteral) {
                var fake_bool = (FakeBooleanLiteral) fake_expr;
                var expr = new Vala.BooleanLiteral (fake_bool.bool_value);
                expr.value_type = context.analyzer.bool_type;
                return expr;
            } else if (fake_expr is FakeCharacterLiteral) {
                var fake_char = (FakeCharacterLiteral) fake_expr;
                var expr = new Vala.CharacterLiteral (fake_char.value);
                expr.value_type = context.analyzer.char_type;
                return expr;
            }
            assert_not_reached ();
        }
        assert_not_reached ();
    }

    private void compute_extracted_expression () {
        // skip first member access
        skip_whitespace ();
        bool at_ma = skip_member_access ();
        skip_whitespace ();
        // check lookup was successful
        FakeExpr? expr = parse_fake_expr (true, true, at_ma);

        attempted_extract_expression = true;

        if (expr == null) {
            // debug ("failed to extract expression");
            return;
        }

        // debug ("extracted expression - %s", expr.to_string ());

        try {
            _extracted_expression = resolve_typed_expression (expr);
            // debug ("resolved extracted expression as %s", _extracted_expression.type_name);
        } catch (TypeResolutionError e) {
            // debug ("failed to resolve expression - %s", e.message);
        }

        if (expr is FakeMethodCall)
            method_arguments = ((FakeMethodCall)expr).arguments_count;
        else if (expr is FakeObjectCreationExpr && expr.inner is FakeMethodCall)
            method_arguments = ((FakeMethodCall)((FakeObjectCreationExpr)expr).inner).arguments_count;
    }

    private bool skip_char (char c) {
        if (idx > 0 && source_file.content[idx] == c) {
            idx--;
            return true;
        }
        return false;
    }

    private bool skip_string (string s) {
        if (idx >= s.length && idx + 1 <= source_file.content.length) {
            if (source_file.content[idx - s.length + 1 : idx + 1] == s) {
                idx -= s.length;
                return true;
            }
        }
        return false;
    }

    private void skip_whitespace () {
        while (idx >= 0 && source_file.content[idx].isspace ())
            idx--;
    }

    private string? parse_ident () {
        long lb_idx = idx;

        while (lb_idx >= 0 && (source_file.content[lb_idx].isalnum () || source_file.content[lb_idx] == '_'))
            lb_idx--;

        if (lb_idx == idx || lb_idx < 0)
            return null;

        if (!(source_file.content[lb_idx + 1].isalpha () || source_file.content[lb_idx + 1] == '_'))
            // ident must start with alpha or underline character
            return null;

        string ident = source_file.content.substring (lb_idx + 1, idx - lb_idx);
        idx = lb_idx;   // update idx

        return ident.length == 0 ? null : ident;
    }

    private string? parse_string_literal () {
        long lb_idx = idx;

        if (lb_idx < 0)
            return null;

        if (source_file.content[lb_idx] != '"')
            return null;

        lb_idx--;

        while (lb_idx >= 0 && (source_file.content[lb_idx] != '"' || lb_idx > 0 && source_file.content[lb_idx - 1] == '\\'))
            lb_idx--;

        if (source_file.content[lb_idx] != '"')
            return null;

        // move behind the leftmost quote
        lb_idx--;

        if (lb_idx == idx || lb_idx < 0)
            return null;

        string str = source_file.content.substring (lb_idx + 2, idx - lb_idx - 1);
        idx = lb_idx;   // update idx

        return str;
    }

    private string? parse_integer () {
        long lb_idx = idx;

        while (lb_idx >= 0 && source_file.content[lb_idx].isdigit ())
            lb_idx--;

        if (lb_idx == idx || lb_idx < 0)
            return null;

        string str = source_file.content.substring (lb_idx + 1, idx - lb_idx);
        idx = lb_idx;

        return str;
    }

    private string? parse_real () {
        var saved_idx = this.idx;
        string? second_part = parse_integer ();
        bool has_decimal_point = skip_char ('.');
        string? first_part = parse_integer ();

        if ((first_part != null || second_part != null) && has_decimal_point)
            return (first_part ?? "") + "." + (second_part ?? "");

        this.idx = saved_idx;
        return null;
    }

    private string? parse_char_literal () {
        var lb_idx = idx;

        if (lb_idx >= 2 &&
            source_file.content[lb_idx] == '\'' &&
            source_file.content[lb_idx - 2] == '\'')
            lb_idx -= 2;
        else
            return null;

        lb_idx--;

        string str = source_file.content.substring (lb_idx + 1, idx - lb_idx);
        this.idx = lb_idx;

        return str;
    }

    private FakeLiteral? parse_literal () {
        string? str = parse_string_literal ();
        if (str != null)
            return new FakeStringLiteral (str);
        if ((str = parse_real ()) != null)
            return new FakeRealLiteral (str);
        if ((str = parse_integer ()) != null)
            return new FakeIntegerLiteral (str);
        if ((str = parse_char_literal ()) != null)
            return new FakeCharacterLiteral (str);
        return null;
    }

    private bool skip_member_access () {
        return skip_char ('.') || skip_string ("->");
    }

    private bool parse_expr_tuple (bool allow_no_right_paren, ArrayList<FakeExpr> expressions,
                                   char begin_separator = '(', char end_separator = ')') {
        // allow for incomplete method call if first expression (useful for SignatureHelp)
        long saved_idx = this.idx;
        if (!skip_char (end_separator) && !allow_no_right_paren) {
            this.idx = saved_idx;
            return false;
        }

        skip_whitespace ();
        if (allow_no_right_paren) {
            if (skip_char (','))
                expressions.insert (0, new FakeEmptyExpr ());
        }
        skip_whitespace ();
        FakeExpr? arg = null;
        while ((arg = parse_fake_expr (true)) != null) {
            // TODO: parse cast expressions here
            expressions.insert (0, arg);
            skip_whitespace ();
            if (!(arg is FakeObjectCreationExpr)) {
                if (skip_string ("out"))
                    skip_whitespace ();
                else if (skip_string ("ref"))
                    skip_whitespace ();
            }
            if (!skip_char (','))
                break;
        }
        if (skip_char (begin_separator))
            return true;
        this.idx = saved_idx;           // restore saved index 
        return false;
    }

    private ArrayList<FakeMemberAccess>? parse_fake_type_arguments () {
        long saved_idx = this.idx;

        if (!skip_char ('>'))
            return null;
        skip_whitespace ();

        var type_arguments = new ArrayList<FakeMemberAccess> ();
        FakeMemberAccess? ma_expr = null;
        while ((ma_expr = parse_fake_member_access_expr (false)) != null) {
            type_arguments.insert (0, ma_expr);
            skip_whitespace ();
            if (!skip_char (','))
                break;
        }

        skip_whitespace ();
        if (!skip_char ('<')) {
            this.idx = saved_idx;
            return null;
        }

        return type_arguments;
    }

    private FakeMemberAccess? parse_fake_member_access_expr (bool allow_inner_exprs = true) {
        FakeMemberAccess? ma_expr = null;
        ArrayList<FakeMemberAccess>? type_arguments = null;
        string? ident;
        long saved_idx = this.idx;

        type_arguments = parse_fake_type_arguments ();
        if ((ident = parse_ident ()) != null) {
            FakeExpr? inner = null;
            skip_whitespace ();
            if (skip_member_access ()) {
                skip_whitespace ();
                inner = allow_inner_exprs ? parse_fake_expr () : parse_fake_member_access_expr ();
            }
            ma_expr = new FakeMemberAccess (ident, type_arguments, inner);
        } else {
            // reset
            this.idx = saved_idx;
        }

        return ma_expr;
    }

    private FakeExpr? parse_fake_expr (bool oce_allowed = false,
                                       bool accept_incomplete_method_call = false,
                                       bool at_member_access = false) {
        var method_arguments = new ArrayList<FakeExpr> ();
        bool have_tuple = parse_expr_tuple (!at_member_access && accept_incomplete_method_call, method_arguments);
        // debug ("after parsing tuple, char at idx is %c", source_file.content[idx]);
        skip_whitespace ();
        FakeExpr? expr = parse_fake_member_access_expr ();
        // debug ("after parsing member access, char at idx is %c", source_file.content[idx]);

        if (expr == null && have_tuple) {
            if (method_arguments.size != 1) {
                // invalid expression (<expr1>, ...)
                // debug ("invalid expression (<expr1>, ...)");
                return null;
            }
            if (!(method_arguments.first () is FakeEmptyExpr))
                // expression wrapped in parentheses
                return method_arguments.first ();
        }

        if (expr == null && (expr = parse_literal ()) != null)
            return expr;

        if (expr == null) {
            // debug ("expr is null and have_tuple = %s", have_tuple.to_string ());
            // try parsing array access
            if (parse_expr_tuple (!at_member_access && accept_incomplete_method_call, method_arguments, '[', ']')) {
                skip_whitespace ();
                expr = parse_fake_expr (/* oce_allowed = false */);
                if (expr != null)
                    return new FakeMethodCall (method_arguments.size, new FakeMemberAccess ("get", null, expr));
            }
            return null;
        }

        if (have_tuple)
            expr = new FakeMethodCall (method_arguments.size, (FakeMemberAccess)expr);

        if (oce_allowed) {
            skip_whitespace ();
            if (parse_ident () == "new") {
                if (have_tuple)
                    expr = new FakeObjectCreationExpr.with_method_call ((FakeMethodCall)expr);
                else
                    expr = new FakeObjectCreationExpr.with_member_access ((FakeMemberAccess)expr);
            }
        }

        return expr;
    }
}

/**
 * Emitted by the SymbolExtractor type resolution methods
 */
private errordomain Vls.TypeResolutionError {
    FIRST_EXPRESSION,
    NTH_EXPRESSION
}
