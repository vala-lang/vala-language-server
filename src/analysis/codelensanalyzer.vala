using Gee;

/**
 * Collects only those symbols of interest to the code lens. Currently these are:
 * 
 * * methods and properties that override or implement a base symbol
 * * abstract and virtual methods and properties that are overridden
 * * methods and properties that hide a base symbol
 */
class Vls.CodeLensAnalyzer : Vala.CodeVisitor, CodeAnalyzer {
    public DateTime last_updated { get; set; }

    /**
     * Collection of methods/properties that override a base symbol.
     *
     * Maps a symbol to the base symbol it overrides.
     */
    public HashMap<Vala.Symbol, Vala.Symbol> found_overrides { get; private set; }

    /**
     * Collection of methods/properties that implement a base symbol.
     *
     * Maps a symbol to the abstract symbol it implements.
     */
    public HashMap<Vala.Symbol, Vala.Symbol> found_implementations { get; private set; }

    /**
     * Collection of methods/properties that hide a base symbol.
     *
     * Maps a symbol to the symbol it hides.
     */
    public HashMap<Vala.Symbol, Vala.Symbol> found_hides { get; private set; }

    private Vala.SourceFile file;

    public CodeLensAnalyzer (Vala.SourceFile file) {
        this.file = file;
        this.found_overrides = new HashMap<Vala.Symbol, Vala.Symbol> ();
        this.found_implementations = new HashMap<Vala.Symbol, Vala.Symbol> ();
        this.found_hides = new HashMap<Vala.Symbol, Vala.Symbol> ();
        visit_source_file (file);
    }

    public override void visit_source_file (Vala.SourceFile file) {
        file.accept_children (this);
    }

    public override void visit_namespace (Vala.Namespace ns) {
        ns.accept_children (this);
    }

    public override void visit_class (Vala.Class cl) {
        if (cl.source_reference.file != null && cl.source_reference.file != file)
            return;
        cl.accept_children (this);
    }

    public override void visit_interface (Vala.Interface iface) {
        if (iface.source_reference.file != null && iface.source_reference.file != file)
            return;
        iface.accept_children (this);
    }

    public override void visit_struct (Vala.Struct st) {
        if (st.source_reference.file != null && st.source_reference.file != file)
            return;
        st.accept_children (this);
    }

    public override void visit_method (Vala.Method m) {
        if (m.source_reference.file != file)
            return;

        if (m.base_interface_method != null && m.base_interface_method != m) {
            if (CodeHelp.base_method_requires_override (m.base_interface_method))
                found_overrides[m] = m.base_interface_method;
            else
                found_implementations[m] = m.base_interface_method;
        } else if (m.base_method != null && m.base_method != m) {
            if (CodeHelp.base_method_requires_override (m.base_method))
                found_overrides[m] = m.base_method;
            else
                found_implementations[m] = m.base_method;
        }

        var hidden_member = m.get_hidden_member ();
        if (m.hides && hidden_member != null)
            found_hides[m] = hidden_member;
    }

    public override void visit_property (Vala.Property prop) {
        if (prop.source_reference.file != file)
            return;

        if (prop.base_interface_property != null && prop.base_interface_property != prop) {
            if (CodeHelp.base_property_requires_override (prop.base_interface_property))
                found_overrides[prop] = prop.base_interface_property;
            else
                found_implementations[prop] = prop.base_interface_property;
        } else if (prop.base_property != null && prop.base_property != prop) {
            if (CodeHelp.base_property_requires_override (prop.base_property))
                found_overrides[prop] = prop.base_property;
            else
                found_implementations[prop] = prop.base_property;
        }

        var hidden_member = prop.get_hidden_member ();
        if (prop.hides && hidden_member != null)
            found_hides[prop] = hidden_member;
    }
}
