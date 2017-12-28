using Gee;

/**
 * Workarounds for memory leaks.
 */
namespace Vls {
    private static void break_ns_refs (Vala.Namespace ns) {
        ns.get_comments ().clear ();
        assert (ns.get_comments ().size == 0);
        ns.get_classes ().clear ();
        assert (ns.get_classes ().size == 0);
        ns.get_interfaces ().clear ();
        assert (ns.get_interfaces ().size == 0);
        ns.get_structs ().clear ();
        assert (ns.get_structs ().size == 0);
        ns.get_enums ().clear ();
        assert (ns.get_enums ().size == 0);
        ns.get_error_domains ().clear ();
        assert (ns.get_error_domains ().size == 0);
        ns.get_delegates ().clear ();
        assert (ns.get_delegates ().size == 0);
        ns.get_constants ().clear ();
        assert (ns.get_constants ().size == 0);
        ns.get_fields ().clear ();
        assert (ns.get_fields ().size == 0);
        ns.get_methods ().clear ();
        assert (ns.get_methods ().size == 0);
        ns.get_namespaces ().clear ();
        assert (ns.get_namespaces ().size == 0);
    }

    private static void break_symbol_refs (Vala.Symbol sym) {
        // do some specific things for specific symbols
        if (sym is Vala.Namespace)
            break_ns_refs (sym as Vala.Namespace);

        // the scope contains symbol tables
        if (sym.scope.get_symbol_table () != null) {
            foreach (var child_sym in sym.scope.get_symbol_table ().get_values ())
                break_symbol_refs (child_sym);
            sym.scope.get_symbol_table ().clear ();
            assert (sym.scope.get_symbol_table ().size == 0);
        }

        break_code_node_refs (sym);
    }

    private void break_using_directive_refs (Vala.UsingDirective ud) {
        break_symbol_refs (ud.namespace_symbol);
        break_code_node_refs (ud);
    }

    private void break_source_reference_refs (Vala.SourceReference sr) {
        foreach (var ud in sr.using_directives)
            break_using_directive_refs (ud);
        sr.using_directives.clear ();
        assert (sr.using_directives.size == 0);
    }

    private void break_code_node_refs (Vala.CodeNode cn) {
        if (cn.source_reference != null) {
            break_source_reference_refs (cn.source_reference);
            cn.source_reference = null;
        }
    }


    internal static void workaround_038 (Vala.CodeContext ctx, Collection<TextDocument> docs) {
        var fake_ctx = new Vala.CodeContext ();
        ctx.resolver.resolve (fake_ctx);
        ctx.flow_analyzer.analyze (fake_ctx);
        ctx.analyzer.context = null;

        // break namespace references
        break_symbol_refs (ctx.root);

        // break all UsingDirective references
        foreach (var doc in docs)
            foreach (var ud in doc.file.current_using_directives)
                break_using_directive_refs (ud);
    }
}
