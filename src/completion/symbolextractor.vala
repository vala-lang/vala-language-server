using LanguageServer;

/**
 * A backwards parser that makes extraordinary attempts to find the current
 * symbol at the cursor. This is less accurate than the Vala parser.
 */
class Vls.SymbolExtractor : Object {
    private long idx;
    private Position pos;
    public Vala.Symbol block { get; private set; }
    private Vala.SourceFile source_file;
    private Vala.CodeContext context;

    private bool attempted_extract;
    private Vala.MemberAccess? _extracted_expression;
    public Vala.MemberAccess? extracted_expression {
        get {
            if (_extracted_expression == null && !attempted_extract)
                compute_extracted_expression ();
            return _extracted_expression;
        }
    }

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

    private void compute_extracted_expression () {
        var queue = new Queue<string> ();

        debug ("extracting symbol at %s (char = %c) ...", pos.to_string (), source_file.content[idx]);

        skip_whitespace ();
        skip_char ('.');
        skip_whitespace ();
        for (string? ident = null; (ident = parse_ident ()) != null; ) {
            queue.push_head (ident);
            skip_whitespace ();
            if (!skip_char ('.'))
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

        string first_part = queue.pop_head ();
        Vala.Symbol? current_block = block;
        Vala.Symbol? head_sym = null;
        bool might_exist = false;
        while (current_block != null &&
               current_block.scope != null && 
               head_sym == null) {
            head_sym = current_block.scope.lookup (first_part);
            if (head_sym == null) {
                var symtab = current_block.scope.get_symbol_table ();
                if (symtab != null && symtab.contains (first_part)) {
                    debug ("found first part `%s' in symbol table @ %s, but the symbol was null",
                           first_part, current_block.source_reference.to_string ());
                    // exit this loop early and go to the other measure
                    might_exist = true;
                    break;
                }
                current_block = current_block.parent_symbol;
            }
        }

        Vala.Symbol? container = context.root;
        if (head_sym == null) {
            debug ("symbol has entry, but entry is null; performing exhaustive search within %s",
                   (current_block ?? block).to_string ());
            var pair = find_variable_visible_in_block (first_part, current_block ?? block);
            if (pair != null) {
                head_sym = pair.first;
                container = pair.second;
                debug ("exhaustive search found symbol %s in %s (%s)",
                head_sym.to_string (), pair.second.to_string (), pair.second.type_name);
            }
        }

        if (head_sym == null) {
            debug ("failed to find symbol for head symbol %s", first_part);
            return;
        }

        context.analyzer.current_symbol = container;

        var ma = new Vala.MemberAccess (null, first_part);
        ma.symbol_reference = head_sym;
        Vala.DataType? current_data_type = get_data_type (head_sym);

        debug ("current type sym is %s", current_data_type != null ? current_data_type.to_string () : null);
        while (!queue.is_empty ()) {
            string member_name = queue.pop_head ();
            Vala.Symbol? member = null;
            if (current_data_type != null) {
                member = Vala.SemanticAnalyzer.symbol_lookup_inherited (current_data_type.type_symbol, member_name);
                debug ("symbol_lookup_inherited (%s, %s) = %s", 
                       current_data_type.to_string (), member_name, member != null ? member.to_string () : null);
            } else if (ma.symbol_reference != null) {
                member = lookup_symbol_member (ma.symbol_reference, member_name);
                debug ("lookup_symbol_member (%s, %s) = %s",
                ma.symbol_reference.to_string (), member_name, member != null ? member.to_string () : null);
            }
            ma = new Vala.MemberAccess (ma, member_name);
            ma.symbol_reference = member;
            if (member != null) {
                current_data_type = get_data_type (member);
                debug ("current type sym is %s", current_data_type != null ? current_data_type.to_string () : null);
                ma.value_type = current_data_type;
            }
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
}
