using LanguageServer;
using Gee;

class Vls.FindScope : Vala.CodeVisitor {
    Vala.CodeContext context;
    Vala.SourceFile file;
    Position pos;
    ArrayList<Vala.Symbol> candidate_blocks = new ArrayList<Vala.Symbol> ();

    private Vala.Symbol _best_block;

    public Vala.Symbol best_block {
        get {
            if (_best_block == null)
                compute_best_block ();
            return _best_block;
        }
    }

    public FindScope (Vala.SourceFile file, Position pos) {
        assert (Vala.CodeContext.get () == file.context);
        this.context = file.context;
        this.file = file;
        this.pos = pos;
        this.visit_source_file (file);
    }

    void compute_best_block () {
        Vala.Symbol smallest_block = context.root;
        Range? best_range = smallest_block.source_reference != null ?
            new Range.from_sourceref (smallest_block.source_reference) : null;

        foreach (Vala.Symbol block in candidate_blocks) {
            var scope_range = new Range.from_sourceref (block.source_reference);
            if (best_range == null ||
                best_range.start.compare_to (scope_range.start) <= 0 && scope_range.end.compare_to (best_range.end) <= 0 &&
                !(best_range.start.compare_to (scope_range.start) == 0 && scope_range.end.compare_to (best_range.end) == 0)) {
                smallest_block = block;
                best_range = scope_range;
            }
        }

        _best_block = smallest_block;
    }

    void add_if_matches (Vala.CodeNode node) {
        var sr = node.source_reference;
        if (sr == null) {
            // debug ("node %s has no source reference", node.type_name);
            return;
        }

        if (sr.file != file) {
            return;
        }

        if (sr.begin.line > sr.end.line) {
            warning (@"wtf vala: $(node.type_name): $sr");
            return;
        }

        if (!(node is Vala.Block || node is Vala.Namespace || node is Vala.TypeSymbol))
            return;
        
        var range = new Range.from_sourceref (sr);
        if (range.contains (pos))
            candidate_blocks.add ((Vala.Symbol) node);
    }

    public override void visit_source_file (Vala.SourceFile file) {
        file.accept_children (this);
    }

    public override void visit_block (Vala.Block b) {
        add_if_matches (b);
        b.accept_children (this);
    }

    public override void visit_catch_clause (Vala.CatchClause clause) {
        clause.accept_children (this);
    }

    public override void visit_class (Vala.Class cl) {
        add_if_matches (cl);
        cl.accept_children (this);
    }

    public override void visit_constructor (Vala.Constructor c) {
        add_if_matches (c);
        c.accept_children (this);
    }

    public override void visit_creation_method (Vala.CreationMethod m) {
        add_if_matches (m);
        m.accept_children (this);
    }

    public override void visit_destructor (Vala.Destructor d) {
        add_if_matches (d);
        d.accept_children (this);
    }

    public override void visit_do_statement (Vala.DoStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_for_statement (Vala.ForStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_foreach_statement (Vala.ForeachStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_if_statement (Vala.IfStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_interface (Vala.Interface iface) {
        add_if_matches (iface);
        iface.accept_children (this);
    }

    public override void visit_lambda_expression (Vala.LambdaExpression expr) {
        expr.accept_children (this);
    }

    public override void visit_lock_statement (Vala.LockStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_loop (Vala.Loop stmt) {
        stmt.accept_children (this);
    }

    public override void visit_method (Vala.Method m) {
        add_if_matches (m);
        m.accept_children (this);
    }

    public override void visit_namespace (Vala.Namespace ns) {
        add_if_matches (ns);
        ns.accept_children (this);
    }

    public override void visit_property (Vala.Property prop) {
        add_if_matches (prop);
        prop.accept_children (this);
    }

    public override void visit_property_accessor (Vala.PropertyAccessor acc) {
        add_if_matches (acc);
        acc.accept_children (this);
    }

    public override void visit_struct (Vala.Struct st) {
        add_if_matches (st);
        st.accept_children (this);
    }

    public override void visit_switch_label (Vala.SwitchLabel label) {
        label.accept_children (this);
    }

    public override void visit_switch_section (Vala.SwitchSection section) {
        add_if_matches (section);
        section.accept_children (this);
    }

    public override void visit_switch_statement (Vala.SwitchStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_try_statement (Vala.TryStatement stmt) {
        stmt.accept_children (this);
    }

    public override void visit_while_statement (Vala.WhileStatement stmt) {
        stmt.accept_children (this);
    }
}