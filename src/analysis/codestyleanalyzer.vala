/* codestyleanalyzer.vala
 *
 * Copyright 2021-2022 Princeton Ferro <princetonferro@gmail.com>
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

using Vala;

/**
 * Collects statistics by 
 */
class Vls.CodeStyleAnalyzer : CodeVisitor, CodeAnalyzer {
    private uint _total_spacing;
    private uint _num_callable;
    private SourceFile? current_file;

    public override DateTime last_updated { get; set; }

    /**
     * Average spacing before parentheses in method and delegate declarations.
     */
    public uint average_spacing_before_parens {
        get {
            if (_num_callable == 0)
                return 1;
            return (_total_spacing + _num_callable / 2) / _num_callable;
        }
    }

    public CodeStyleAnalyzer (SourceFile source_file) {
        this.visit_source_file (source_file);
    }

    /**
     * Get the indentation of a statement or symbol at a given nesting level. At nesting
     * level 0, gets the indentation of the statement. At level 1, gets the
     * indentation of a statement inside this statement, and so on...
     *
     * @param stmt_or_sym       a statement or symbol
     * @param nesting_level     the nesting level inside the statement
     *
     * @return an empty string if indentation couldn't be determined
     */
    public string get_indentation (CodeNode stmt_or_sym, uint nesting_level = 0)
        requires (stmt_or_sym is Statement || stmt_or_sym is Symbol)
    {
        if (stmt_or_sym.source_reference == null)
            return "";

        var source = stmt_or_sym.source_reference;
        var parent = stmt_or_sym.parent_node;

        // refine the parent to something better
        if (parent is Block)
            parent = parent.parent_node;

        // use the indentation within the statement's parent to determine the prefix
        int coldiff = source.begin.column;
        if ((parent is Statement || parent is Symbol) && parent.source_reference != null)
            coldiff -= parent.source_reference.begin.column;

        // walk back from the statement/symbol to the next newline
        var offset = (long)((source.begin.pos - (char *)source.file.content) - 1);

        // keep track of last indent and outer indent
        var suffix = new StringBuilder ();
        var indent = new StringBuilder ();
        for (int col = coldiff; offset > 0; --col, --offset) {
            char c = stmt_or_sym.source_reference.file.content[offset];
            if (Util.is_newline (c) || !c.isspace ())
                break;
            if (col > 0)
                suffix.prepend_c (c);
            else
                indent.prepend_c (c);
        }
        for (uint l = 0; l <= nesting_level; ++l)
            indent.append (suffix.str);
        return indent.str;
    }

    public override void visit_source_file (SourceFile source_file) {
        current_file = source_file;
        source_file.accept_children (this);
        current_file = null;
    }

    public override void visit_namespace (Namespace ns) {
        if (ns.source_reference != null && ns.source_reference.file != current_file)
            return;
        ns.accept_children (this);
    }

    public override void visit_class (Class cl) {
        if (cl.source_reference == null || cl.source_reference.file != current_file)
            return;
        cl.accept_children (this);
    }

    public override void visit_interface (Interface iface) {
        if (iface.source_reference == null || iface.source_reference.file != current_file)
            return;
        iface.accept_children (this);
    }

    public override void visit_enum (Enum en) {
        if (en.source_reference == null || en.source_reference.file != current_file)
            return;
        en.accept_children (this);
    }

    public override void visit_struct (Struct st) {
        if (st.source_reference == null || st.source_reference.file != current_file)
            return;
        st.accept_children (this);
    }

    private void analyze_callable (Callable callable) {
        _num_callable++;

        // because we allow content to be temporarily inconsistent with the
        // parse tree (to allow for fast code completion), we have to use
        // [last_fresh_content]
        unowned var content = (current_file is TextDocument) ?
            ((TextDocument)current_file).last_fresh_content : current_file.content;
        var sr = callable.source_reference;
        var zero_idx = (long) Util.get_string_pos (content, sr.end.line - 1, sr.end.column);
        unowned string text = content.offset (zero_idx);
        var spaces = 0;
        unichar c = '\0';
        for (var i = 0; text.get_next_char (ref i, out c) && c != '(' && !(c == '\r' || c == '\n');)
            spaces++;
        if (c == '\r' || c == '\n')
            spaces = 1;
        _total_spacing += spaces;
    }

    public override void visit_delegate (Delegate d) {
        if (d.source_reference == null || d.source_reference.file != current_file ||
            d.source_reference.begin.pos == null)
            return;
        analyze_callable (d);
    }

    public override void visit_method (Method m) {
        if (m.source_reference == null || m.source_reference.file != current_file || m.source_reference.begin.pos == null)
            return;
        analyze_callable (m);
    }
}
