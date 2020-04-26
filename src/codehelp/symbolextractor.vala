using LanguageServer;

/**
 * A backwards parser that makes extraordinary attempts to find the current
 * symbol at the cursor. This is less accurate than the Vala parser.
 */
class Vls.SymbolExtractor : Object {
    /**
     * Represents a fake expression that the SE extracted.
     */
    class FakeExpr {
        public string member_name { get; private set; }
        public int method_arguments { get; private set; }
        public bool is_methodcall {
            get { return method_arguments >= 0; }
        }

        public FakeExpr (string member_name, int method_arguments = -1) {
            this.member_name = member_name;
            this.method_arguments = method_arguments;
        }

        public string to_string () {
            return member_name + (is_methodcall ? @" ([$method_arguments arg(s)])" : "");
        }
    }

    private long idx;
    private Position pos;
    public Vala.Symbol block { get; private set; }
    private Vala.SourceFile source_file;
    private Vala.CodeContext context;

    private bool attempted_extract;
    private Vala.Expression? _extracted_expression;
    public Vala.Expression? extracted_expression {
        get {
            if (_extracted_expression == null && !attempted_extract)
                compute_extracted_expression ();
            return _extracted_expression;
        }
    }


#if !VALA_FEATURE_INITIAL_ARGUMENT_COUNT
    /**
     * If extracted_expression is a method call, this is the number of
     * arguments supplied to that method call.
     * This feature is only used if the version of Vala VLS was compiled
     * with lacks initial_argument_count fields for Vala.MethodCall
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
            var member = lookup_symbol_member (closest_block, variable_name);
            if (member != null)
                return new Pair<Vala.Symbol, Vala.Symbol> (member, closest_block);
            // try base types
            if (closest_block is Vala.Class) {
                var cl = (Vala.Class) closest_block;
                foreach (var base_type in cl.get_base_types ()) {
                    member = lookup_symbol_member (base_type.type_symbol, variable_name);
                    if (member != null)
                        return new Pair<Vala.Symbol, Vala.Symbol> (member, closest_block);
                }
            } else if (closest_block is Vala.Interface) {
                var iface = (Vala.Interface) closest_block;
                foreach (var prereq_type in iface.get_prerequisites ()) {
                    member = lookup_symbol_member (prereq_type.type_symbol, variable_name);
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
                var member = lookup_symbol_member (ns, variable_name);

                if (member != null)
                    return new Pair<Vala.Symbol, Vala.Symbol> (member, ns);
            }
        }

        return null;
    }

    static Vala.DataType? get_data_type (Vala.Symbol sym) {
        if (sym is Vala.Variable) {
            return ((Vala.Variable) sym).variable_type;
        } else if (sym is Vala.Property) {
            return ((Vala.Property) sym).property_type;
        }
        return null;
    }

    static Vala.Symbol? lookup_symbol_member (Vala.Symbol container, string member_name) {
        if (container is Vala.Namespace) {
            var ns = (Vala.Namespace) container;

            foreach (var cl in ns.get_classes ())
                if (cl.name == member_name)
                    return cl;

            foreach (var cnst in ns.get_constants ())
                if (cnst.name == member_name)
                    return cnst;

            foreach (var delg in ns.get_delegates ())
                if (delg.name == member_name)
                    return delg;

            foreach (var en in ns.get_enums ())
                if (en.name == member_name)
                    return en;

            foreach (var err in ns.get_error_domains ())
                if (err.name == member_name)
                    return err;

            foreach (var field in ns.get_fields ())
                if (field.name == member_name)
                    return field;

            foreach (var iface in ns.get_interfaces ())
                if (iface.name == member_name)
                    return iface;

            foreach (var m in ns.get_methods ())
                if (m.name == member_name)
                    return m;

            foreach (var n in ns.get_namespaces ())
                if (n.name == member_name)
                    return n;

            foreach (var st in ns.get_structs ())
                if (st.name == member_name)
                    return st;
        } else if (container is Vala.ObjectTypeSymbol) {
            var ots = (Vala.ObjectTypeSymbol) container;

            foreach (var cl in ots.get_classes ())
                if (cl.name == member_name)
                    return cl;

            foreach (var cotst in ots.get_constants ())
                if (cotst.name == member_name)
                    return cotst;

            foreach (var delg in ots.get_delegates ())
                if (delg.name == member_name)
                    return delg;

            foreach (var en in ots.get_enums ())
                if (en.name == member_name)
                    return en;

            foreach (var field in ots.get_fields ())
                if (field.name == member_name)
                    return field;

            foreach (var iface in ots.get_interfaces ())
                if (iface.name == member_name)
                    return iface;

            foreach (var m in ots.get_methods ())
                if (m.name == member_name)
                    return m;

            foreach (var p in ots.get_properties ())
                if (p.name == member_name)
                    return p;

            // signals can't be static

            foreach (var st in ots.get_structs ())
                if (st.name == member_name)
                    return st;
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
        warning ("unknown Callable node %s", callable.type_name);
        return null;
    }

    private void compute_extracted_expression (bool allow_parse_as_method_call = true) {
        var queue = new Queue<FakeExpr> ();

        debug ("extracting symbol at %s (char = %c) ...", pos.to_string (), source_file.content[idx]);

        skip_whitespace ();
        bool is_member_access = skip_member_access ();
        skip_whitespace ();
        for (FakeExpr? expr = null; (expr = parse_fake_expr (queue.is_empty () && 
                                                             !is_member_access &&
                                                             allow_parse_as_method_call)) != null; ) {
            queue.push_head (expr);
            debug ("got fake expression `%s'", expr.to_string ());
            skip_whitespace ();
            if (!skip_member_access ())
                break;
            skip_whitespace ();
        }

        attempted_extract = true;

        // perform lookup
        if (queue.length == 0) {
            debug ("could not parse a symbol");
            return;
        }

        // 1. find symbol coresponding to first component
        // 2. with the first symbol found, generate member accesses
        //    for additional components
        // 3. resolve the member accesses, and get the symbol_reference

        FakeExpr first_part = queue.pop_head ();
        Vala.Symbol? current_block = block;
        Vala.Symbol? head_sym = null;
        bool might_exist = false;
        while (current_block != null &&
               current_block.scope != null && 
               head_sym == null) {
            head_sym = current_block.scope.lookup (first_part.member_name);
            if (head_sym == null) {
                var symtab = current_block.scope.get_symbol_table ();
                if (symtab != null && symtab.contains (first_part.member_name)) {
                    debug ("found first part `%s' in symbol table @ %s, but the symbol was null",
                           first_part.member_name, current_block.source_reference.to_string ());
                    // exit this loop early and go to the other measure
                    might_exist = true;
                    break;
                }
                current_block = current_block.parent_symbol;
            }
        }

        Vala.Symbol? container = context.root;
        if (head_sym == null) {
            debug ("performing exhaustive search within %s", (current_block ?? block).to_string ());
            var pair = find_variable_visible_in_block (first_part.member_name, current_block ?? block);
            if (pair != null) {
                head_sym = pair.first;
                container = pair.second;
                debug ("exhaustive search found symbol %s in %s (%s)",
                head_sym.to_string (), pair.second.to_string (), pair.second.type_name);
            }
        }

        if (head_sym == null) {
            debug ("failed to find symbol for head symbol %s", first_part.member_name);
            // try again
            if (allow_parse_as_method_call)
                compute_extracted_expression (false);
            return;
        }

        context.analyzer.current_symbol = container;

        Vala.Expression ma = new Vala.MemberAccess (null, first_part.member_name);
        ma.symbol_reference = head_sym;
        Vala.DataType? current_data_type;

        if (first_part.is_methodcall && head_sym is Vala.Callable) {
            current_data_type = ((Vala.Callable) head_sym).return_type;
            ma = new Vala.MethodCall (ma);
            ma.value_type = current_data_type;
            ((Vala.MethodCall)ma).call.value_type = get_callable_type_for_callable ((Vala.Callable) head_sym);
        } else {
            current_data_type = get_data_type (head_sym);
        }

#if !VALA_FEATURE_INITIAL_ARGUMENT_COUNT
        this.method_arguments = first_part.method_arguments;
#endif

        debug ("current type sym is %s", current_data_type != null ? current_data_type.to_string () : null);
        while (!queue.is_empty ()) {
            FakeExpr expr = queue.pop_head ();
            Vala.Symbol? member = null;
            if (current_data_type != null) {
                member = Vala.SemanticAnalyzer.symbol_lookup_inherited (current_data_type.type_symbol, expr.member_name);
                debug ("symbol_lookup_inherited (%s, %s) = %s", 
                       current_data_type.to_string (), expr.member_name, member != null ? member.to_string () : null);
            } else if (ma.symbol_reference != null) {
                member = lookup_symbol_member (ma.symbol_reference, expr.member_name);
                debug ("lookup_symbol_member (%s, %s) = %s",
                ma.symbol_reference.to_string (), expr.member_name, member != null ? member.to_string () : null);
            }
            ma = new Vala.MemberAccess (ma, expr.member_name);
            ma.symbol_reference = member;
            if (member != null) {
                current_data_type = get_data_type (member);
                debug ("current type sym is %s", current_data_type != null ? current_data_type.to_string () : null);
                ma.value_type = current_data_type;

                if (expr.is_methodcall && member is Vala.Callable) {
                    current_data_type = ((Vala.Callable) member).return_type;
                    ma = new Vala.MethodCall (ma);
                    ma.value_type = current_data_type;
                    ((Vala.MethodCall) ma).call.value_type = get_callable_type_for_callable ((Vala.Callable) member);
#if VALA_FEATURE_INITIAL_ARGUMENT_COUNT
                    ((Vala.MethodCall) ma).initial_argument_count = expr.method_arguments;
#endif
                }
            }
#if !VALA_FEATURE_INITIAL_ARGUMENT_COUNT
            this.method_arguments = expr.method_arguments;
#endif
        }

        _extracted_expression = ma;
    }

    private bool skip_char (char c) {
        if (source_file.content[idx] == c) {
            if (idx > 0)
                idx--;
            return true;
        }
        return false;
    }

    private bool skip_string (string s) {
        if (idx >= s.length) {
            if (source_file.content[idx-s.length+1:idx+1] == s) {
                idx -= s.length;
                return true;
            }
        }
        return false;
    }

    private void skip_whitespace () {
        while (idx > 0 && source_file.content[idx].isspace ())
            idx--;
    }

    private string? parse_ident () {
        long lb_idx = idx;

        while (lb_idx > 0 && (source_file.content[lb_idx].isalnum () || source_file.content[lb_idx] == '_'))
            lb_idx--;

        string ident = source_file.content.substring (lb_idx + 1, idx - lb_idx);
        idx = lb_idx;   // update idx

        return ident.length == 0 ? null : ident;
    }

    private bool skip_member_access () {
        return skip_char ('.') || skip_string ("->");
    }

    private bool skip_method_arguments (bool accept_within_method_call, out int arg_count = null) {
        // TODO: skip arguments
        // allow for incomplete method call if first expression (useful for SignatureHelp)
        arg_count = -1;
        long saved_idx = this.idx;
        if (!skip_char (')') && !accept_within_method_call)
            return false;

        arg_count = 0;
        skip_whitespace ();
        if (accept_within_method_call) {
            if (skip_char (','))
                arg_count++;
        }
        skip_whitespace ();
        while (skip_fake_expr ()) {
            arg_count++;
            skip_whitespace ();
            if (skip_string ("out"))
                skip_whitespace ();
            else if (skip_string ("ref"))
                skip_whitespace ();
            skip_char (',');
        }
        if (skip_char ('('))
            return true;
        this.idx = saved_idx;           // restore saved index 
        arg_count = -1;
        return false;
    }

    private bool skip_fake_expr () {
        return parse_fake_expr () != null;
    }

    private FakeExpr? parse_fake_expr (bool accept_within_method_call = false) {
        int method_arguments;
        skip_method_arguments (accept_within_method_call, out method_arguments);
        skip_whitespace ();
        string? ident = parse_ident ();

        if (ident == null)
            return null;
        
        return new FakeExpr (ident, method_arguments);
    }
}
