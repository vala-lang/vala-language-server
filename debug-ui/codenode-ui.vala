class Vls.CodeNodeUI : Vala.CodeVisitor {
    Gtk.TreeStore store;
    Gtk.TreeIter current;
    Vala.CodeNode? highlight;
    Gtk.TreePath path = new Gtk.TreePath ();

    public CodeNodeUI (Vala.SourceFile? file, Vala.CodeNode? highlight) {
        this.highlight = highlight;

        var w = new Gtk.Window ();

        this.store = new Gtk.TreeStore (4,
            typeof(string), // type_name
            typeof(string), // class
            typeof(string), // source_reference
            typeof(bool)); // error

        this.visit_source_file (file);

        var scrollview = new Gtk.ScrolledWindow (null, null);

        var treeview = new Gtk.TreeView.with_model (store);

        treeview.append_column (new Gtk.TreeViewColumn.with_attributes ("Type Name", new Gtk.CellRendererText (), "text", 0));
        treeview.append_column (new Gtk.TreeViewColumn.with_attributes ("Class", new Gtk.CellRendererText (), "text", 1));
        treeview.append_column (new Gtk.TreeViewColumn.with_attributes ("Source Reference", new Gtk.CellRendererText (), "text", 2));
        treeview.append_column (new Gtk.TreeViewColumn.with_attributes ("Error", new Gtk.CellRendererToggle (), "active", 3));

        scrollview.add (treeview);

        //  treeview.expand_to_path (path);

        var sourcebuffer = new Gtk.SourceBuffer.with_language (new Gtk.SourceLanguageManager ().get_language ("vala"));
        sourcebuffer.text = file.content;
        var sourceview = new Gtk.SourceView.with_buffer (sourcebuffer);
        sourceview.editable = false;
        var scrollcode = new Gtk.ScrolledWindow (null, null);
        scrollcode.add (sourceview);

        var fileview = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        fileview.pack_start (new Gtk.Label (file.filename), false, false);
        fileview.pack_end (scrollcode, true, true);

        var paned = new Gtk.Paned (Gtk.Orientation.HORIZONTAL);
        paned.pack1 (fileview, true, true);
        paned.pack2 (scrollview, true, true);
        w.add (paned);

        w.default_height = 600;
        w.default_width = 800;
        w.show_all ();
    }

    string get_code (Vala.CodeNode node) {
        var sr = node.source_reference;
        var from = (long)get_string_pos (sr.file.content, sr.begin.line-1, sr.begin.column-1);
        var to = (long)get_string_pos (sr.file.content, sr.end.line-1, sr.end.column);
        return sr.file.content [from:to];
    }

    void add_iter_to_path (Vala.SourceReference sr, Gtk.TreeIter iter) {
        if ((sr.begin.line <= highlight.source_reference.begin.line && highlight.source_reference.end.line <= sr.end.line)
         || (sr.begin.column <= highlight.source_reference.begin.column && highlight.source_reference.end.column <= sr.end.column)) {
            Gtk.TreeIter parent;
            store.iter_parent (out parent, iter);
            path.append_index (store.iter_n_children (parent));
        }
    }

    public override void visit_source_file (Vala.SourceFile file) {
        path.append_index (0);
        Gtk.TreeIter thisTree, old = current;
        store.insert_with_values (out thisTree, null, -1, 0, file.filename, 1, "File", 2, "all", 3, false, -1);
        current = thisTree;
        file.accept_children (this);
        current = old;
    }

    private void visit_symbol (Vala.Symbol sym) {
        Gtk.TreeIter thisTree, old = current;
        store.insert_with_values (out thisTree, current, -1, 0, sym.name, 1, sym.type_name, 2, sym.source_reference.to_string (), 3, sym.error, -1);
        current = thisTree;
        add_iter_to_path (sym.source_reference, thisTree);
        sym.accept_children (this);
        current = old;
    }

    #if 0
    public override void visit_expression (Vala.Expression e) {
        Gtk.TreeIter thisTree, old = current;
        string row = e.value_type.to_string ();
        if (row == null || row.strip () == "") {
            row = get_code (e);
        }

        if (e.symbol_reference != null) {
            row += "; symbol_ref =";
        }
        store.insert_with_values (out thisTree, current, -1, 0, row, 1, e.type_name, 2, e.source_reference.to_string (), 3, e.error, -1);
        current = thisTree;
        add_iter_to_path (e.source_reference, thisTree);

        if (e.symbol_reference != null) {
            this.visit_symbol (e.symbol_reference);
        } else {
            store.insert_with_values (null, current, -1, 0, "symbol_ref = null", 1, "", 2, "", 3, false, -1);
        }

        e.accept_children (this);
        current = old;
    }
    #endif

    private void visit_statement (Vala.Statement st) {
        Gtk.TreeIter thisTree, old = current;
        string contents = get_code (st);

        store.insert_with_values (out thisTree, current, -1, 0, contents, 1, st.type_name, 2, st.source_reference.to_string (), 3, st.error, -1);
        current = thisTree;
        add_iter_to_path (st.source_reference, thisTree);
        st.accept_children (this);
        current = old;
    }

    //  public override void visit_addressof_expression (Vala.AddressofExpression expr) {
    //      this.visit_expression (expr);
    //  }
    //  public override void visit_array_creation_expression (Vala.ArrayCreationExpression expr) {
    //      this.visit_expression (expr);
    //  }
    //  public override void visit_assignment (Vala.Assignment a) {
    //      this.visit_expression (a);
    //  }
    //  public override void visit_base_access (Vala.BaseAccess expr) {
    //      this.visit_expression (expr);
    //  }
    //  public override void visit_binary_expression (Vala.BinaryExpression expr) {
    //      this.visit_expression (expr);
    //  }
    public override void visit_block (Vala.Block b) {
        this.visit_statement (b);
    }
    //  public virtual void visit_boolean_literal (Vala.BooleanLiteral lit);
    public override void visit_break_statement (Vala.BreakStatement stmt) {
        this.visit_statement (stmt);
    }
    //  public override void visit_cast_expression (Vala.CastExpression expr) {
    //      this.visit_expression (expr);
    //  }
    //  public virtual void visit_catch_clause (Vala.CatchClause clause);
    //  public override void visit_character_literal (Vala.CharacterLiteral lit) {
    //      this.visit_expression (lit);
    //  }
    public override void visit_class (Vala.Class cl) {
        this.visit_symbol (cl);
    }
    //  public override void visit_conditional_expression (Vala.ConditionalExpression expr) {
    //      this.visit_expression (expr);
    //  }
    public override void visit_constant (Vala.Constant c) {
        this.visit_symbol (c);
    }
    public override void visit_constructor (Vala.Constructor c) {
        this.visit_symbol (c);
    }
    public override void visit_continue_statement (Vala.ContinueStatement stmt) {
        this.visit_statement (stmt);
    }
    public override void visit_creation_method (Vala.CreationMethod m) {
        this.visit_symbol (m);
    }
    //  public virtual void visit_data_type (Vala.DataType type);
    public override void visit_declaration_statement (Vala.DeclarationStatement stmt) {
        this.visit_statement (stmt);
    }
    public override void visit_delegate (Vala.Delegate d) {
        this.visit_symbol (d);
    }
    public override void visit_delete_statement (Vala.DeleteStatement stmt) {
        this.visit_statement (stmt);
    }
    public override void visit_destructor (Vala.Destructor d) {
        this.visit_symbol (d);
    }
    public override void visit_do_statement (Vala.DoStatement stmt) {
        this.visit_statement (stmt);
    }
    //  public virtual void visit_element_access (Vala.ElementAccess expr);
    public override void visit_empty_statement (Vala.EmptyStatement stmt) {
        this.visit_statement (stmt);
    }
    //  public override void visit_end_full_expression (Vala.Expression expr) {
    //      this.visit_expression (expr);
    //  }
    public override void visit_enum (Vala.Enum en) {
        this.visit_symbol (en);
    }
    public override void visit_enum_value (Vala.EnumValue ev) {
        this.visit_symbol (ev);
    }
    public override void visit_error_code (Vala.ErrorCode ecode) {
        this.visit_symbol (ecode);
    }
    public override void visit_error_domain (Vala.ErrorDomain edomain) {
        this.visit_symbol (edomain);
    }
    public override void visit_expression_statement (Vala.ExpressionStatement stmt) {
        this.visit_statement (stmt);
    }
    public override void visit_field (Vala.Field f) {
        this.visit_symbol (f);
    }
    public override void visit_for_statement (Vala.ForStatement stmt) {
        this.visit_statement (stmt);
    }
    public override void visit_foreach_statement (Vala.ForeachStatement stmt) {
        this.visit_symbol (stmt);
    }
    //  public virtual void visit_formal_parameter (Vala.Parameter p);
    public override void visit_if_statement (Vala.IfStatement stmt) {
        this.visit_statement (stmt);
    }
    //  public override void visit_initializer_list (Vala.InitializerList list) {
    //      this.visit_expression (list);
    //  }
    //  public virtual void visit_integer_literal (Vala.IntegerLiteral lit);
    public override void visit_interface (Vala.Interface iface) {
        this.visit_symbol (iface);
    }
    //  public override void visit_lambda_expression (Vala.LambdaExpression expr) {
    //      this.visit_expression (expr);
    //  }
    public override void visit_local_variable (Vala.LocalVariable local) {
        this.visit_symbol (local);
    }
    public override void visit_lock_statement (Vala.LockStatement stmt) {
        this.visit_statement (stmt);
    }
    public override void visit_loop (Vala.Loop stmt) {
        this.visit_statement (stmt);
    }
    public override void visit_member_access (Vala.MemberAccess expr) {
        Gtk.TreeIter thisTree, old = current;
        if (expr.inner != null) {
            store.insert_with_values (out thisTree, current, -1,
                0, @"member=$(expr.member_name); inner =",
                1, "",
                2, "",
                3, false);
            current = thisTree;
            this.visit_expression (expr.inner);
            current = old;
        } else {
            store.insert_with_values (null, current, -1,
                0, "inner = null",
                1, "",
                2, "",
                3, false);
        }
    }
    public override void visit_method (Vala.Method m) {
        this.visit_symbol (m);
    }
    public override void visit_method_call (Vala.MethodCall expr) {
        Gtk.TreeIter thisTree, old = current;
        string contents = get_code (expr);

        string vt = expr.value_type.to_string () ?? "";
        string tt = expr.target_type.to_string () ?? "";
        string tvvt = expr.target_value != null
            ? expr.target_value.value_type != null
                ? expr.target_value.value_type.to_string ()
                : ""
            : "";

        store.insert_with_values (out thisTree, current, -1, 0, @"$contents:value_type=$(vt):target_type=$(tt):target_value=$(tvvt)", 1, expr.type_name, 2, expr.source_reference.to_string (), 3, expr.error, -1);
        current = thisTree;
        expr.accept_children (this);
        current = old;
    }
    //  public override void visit_named_argument (Vala.NamedArgument expr) {
    //      this.visit_expression (expr);
    //  }
    public override void visit_namespace (Vala.Namespace ns) {
        this.visit_symbol (ns);
    }
    //  public virtual void visit_null_literal (Vala.NullLiteral lit);
    //  public override void visit_object_creation_expression (Vala.ObjectCreationExpression expr) {
    //      this.visit_expression (expr);
    //  }
    //  public override void visit_pointer_indirection (Vala.PointerIndirection expr) {
    //      this.visit_expression (expr);
    //  }
    //  public override void visit_postfix_expression (Vala.PostfixExpression expr) {
    //      this.visit_expression (expr);
    //  }
    public override void visit_property (Vala.Property prop) {
        this.visit_symbol (prop);
    }
    public override void visit_property_accessor (Vala.PropertyAccessor acc) {
        this.visit_symbol (acc);
    }
    //  public virtual void visit_real_literal (Vala.RealLiteral lit);
    //  public override void visit_reference_transfer_expression (Vala.ReferenceTransferExpression expr) {
    //      this.visit_expression (expr);
    //  }
    //  public virtual void visit_regex_literal (Vala.RegexLiteral lit);
    public override void visit_return_statement (Vala.ReturnStatement stmt) {
        this.visit_statement (stmt);
    }
    public override void visit_signal (Vala.Signal sig) {
        this.visit_symbol (sig);
    }
    //  public override void visit_sizeof_expression (Vala.SizeofExpression expr) {
    //      this.visit_expression (expr);
    //  }
    //  public override void visit_slice_expression (Vala.SliceExpression expr) {
    //      this.visit_expression (expr);
    //  }
    //  public virtual void visit_string_literal (Vala.StringLiteral lit);
    public override void visit_struct (Vala.Struct st) {
        this.visit_symbol (st);
    }
    //  public virtual void visit_switch_label (Vala.SwitchLabel label);
    public override void visit_switch_section (Vala.SwitchSection section) {
        this.visit_symbol (section);
    }
    public override void visit_switch_statement (Vala.SwitchStatement stmt) {
        this.visit_statement (stmt);
    }
    //  public virtual void visit_template (Vala.Template tmpl);
    public override void visit_throw_statement (Vala.ThrowStatement stmt) {
        this.visit_statement (stmt);
    }
    public override void visit_try_statement (Vala.TryStatement stmt) {
        this.visit_statement (stmt);
    }
    //  public virtual void visit_tuple (Vala.Tuple tuple);
    //  public virtual void visit_type_check (Vala.TypeCheck expr);
    public override void visit_type_parameter (Vala.TypeParameter p) {
        this.visit_symbol (p);
    }
    //  public override void visit_typeof_expression (Vala.TypeofExpression expr) {
    //      this.visit_expression (expr);
    //  }
    //  public override void visit_unary_expression (Vala.UnaryExpression expr) {
    //      this.visit_expression (expr);
    //  }
    public override void visit_unlock_statement (Vala.UnlockStatement stmt) {
        this.visit_statement (stmt);
    }
    //  public virtual void visit_using_directive (Vala.UsingDirective ns);
    public override void visit_while_statement (Vala.WhileStatement stmt) {
        this.visit_statement (stmt);
    }
    public override void visit_yield_statement (Vala.YieldStatement y) {
        this.visit_statement (y);
    }
}

size_t get_string_pos (string str, uint lineno, uint charno) {
    int linepos = -1;

    for (uint lno = 0; lno < lineno; ++lno) {
        int pos = str.index_of_char ('\n', linepos + 1);
        if (pos == -1)
            break;
        linepos = pos;
    }

    return linepos + 1 + charno;
}
