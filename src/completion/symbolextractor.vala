using LanguageServer;

/**
 * A backwards parser that makes extraordinary attempts to find the current
 * symbol at the cursor when all other methods have failed.
 */
class Vls.SymbolExtractor : Object {
    private long idx;
    private Position pos;
    private Vala.Symbol block;
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

    public SymbolExtractor (Position pos, Vala.Symbol block, Vala.SourceFile source_file, Vala.CodeContext? context = null) {
        this.idx = (long) Util.get_string_pos (source_file.content, pos.line - 1, pos.character);
        this.pos = pos;
        this.block = block;
        this.source_file = source_file;
        if (context != null)
            this.context = context;
        else {
            assert (Vala.CodeContext.get () == source_file.context);
            this.context = source_file.context;
        }
    }

    private void compute_extracted_expression () {
        var queue = new Queue<string> ();

        debug ("extracting symbol at %s (char = %c) ...", pos.to_string (), source_file.content[idx]);

        skip_whitespace ();
        skip_char ('.');
        for (string? ident = null; (ident = parse_ident ()) != null; ) {
            queue.push_head (ident);
            skip_whitespace ();
            if (!skip_char ('.'))
                break;
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
        while (current_block != null &&
               current_block.scope != null && 
               head_sym == null) {
            head_sym = current_block.scope.lookup (first_part);
            if (head_sym == null) {
                Vala.Scope? parent_scope = current_block.scope.parent_scope;
                current_block = parent_scope != null ? parent_scope.owner : null;
                if (current_block != null && current_block.source_reference != null)
                    debug ("symbol lookup in current scope failed, trying parent %s", current_block.source_reference.to_string ());
            }
        }

        if (head_sym == null) {
            debug ("failed to find symbol for head symbol %s", first_part);
            return;
        }

        var ma = new Vala.MemberAccess (null, first_part);
        ma.symbol_reference = head_sym;
        // set parent_node to current scope, which allows subsequent
        // completion phases to relearn the scope this expression appears in
        ma.parent_node = current_block;

        while (!queue.is_empty ()) {
            ma = new Vala.MemberAccess (ma, queue.pop_head ());
            ma.parent_node = current_block;
        }

        ma.check (this.context);
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
