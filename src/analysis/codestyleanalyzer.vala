/* codestyleanalyzer.vala
 *
 * Copyright 2021 Princeton Ferro <princetonferro@gmail.com>
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

    public CodeStyleAnalyzer (Vala.SourceFile source_file) {
        this.visit_source_file (source_file);
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
            ((TextDocument)current_file).last_compiled_content : current_file.content;
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
        if (m.source_reference == null || m.source_reference.begin.pos == null)
            return;
        analyze_callable (m);
    }
}
