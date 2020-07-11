using LanguageServer;
using Gee;

/** 
 * Contains routines for analyzing references to symbols across the project.
 * Used by `textDocument/definition`, `textDocument/rename`, `textDocument/prepareRename`,
 * `textDocument/references`, and `textDocument/documentHighlight`.
 */
namespace Vls.SymbolReferences {
    /**
     * Find a symbol in ``context`` matching ``symbol`` or ``null``.
     *
     * @param context       the {@link Vala.CodeContext} to search for a matching symbol in
     * @param symbol        the symbol to match, which comes from a different {@link Vala.CodeContext}
     * @return              the matching symbol in ``context``, or ``null`` if one could not be found
     */
    public Vala.Symbol? find_matching_symbol (Vala.CodeContext context, Vala.Symbol symbol) {
        var symbols = new GLib.Queue<Vala.Symbol> ();
        Vala.Symbol? matching_sym = null;

        // walk up the symbol hierarchy to the root
        for (Vala.Symbol? current_sym = symbol;
             current_sym != null && current_sym.name != null && current_sym.to_string () != "(root namespace)";
             current_sym = current_sym.parent_symbol) {
            symbols.push_head (current_sym);
        }

        matching_sym = context.root.scope.lookup (symbols.pop_head ().name);
        while (!symbols.is_empty () && matching_sym != null) {
            var parent_sym = matching_sym;
            var symtab = parent_sym.scope.get_symbol_table ();
            if (symtab != null) {
                var current_sym = symbols.pop_head ();
                matching_sym = symtab[current_sym.name];
                string? gir_name = null;
                // look for the GIR version of current_sym instead
                if (matching_sym == null && (gir_name = current_sym.get_attribute_string ("GIR", "name")) != null) {
                    matching_sym = symtab[gir_name];
                    if (matching_sym != null && matching_sym.source_reference.file.file_type != Vala.SourceFileType.PACKAGE)
                        matching_sym = null;
                }
            } else {
                // workaround: "GLib" namespace may be empty when dealing with GLib-2.0.gir (instead, "G" namespace will be populated)
                if (matching_sym.name == "GLib") {
                    matching_sym = context.root.scope.lookup ("G");
                } else 
                    matching_sym = null;
            }
        }

        if (!symbols.is_empty ())
            return null;

        return matching_sym;
    }

    /**
     * Gets the symbol you really want, not something from a generated file.
     *
     * If `symbol` comes from a generated file (eg. a VAPI), then
     * it would be more useful to show the file specific to the compilation
     * that generated the file.
     */
    Vala.Symbol find_real_symbol (Project project, Vala.Symbol symbol) {
        if (symbol.source_reference == null || symbol.source_reference.file == null)
            return symbol;

        Compilation alter_comp;
        if (project.lookup_compilation_for_output_file (symbol.source_reference.file.filename, out alter_comp)) {
            Vala.Symbol? matching_sym;
            if ((matching_sym = SymbolReferences.find_matching_symbol (alter_comp.code_context, symbol)) != null)
                return matching_sym;
        }
        return symbol;
    }

    /**
     * Gets the range of a symbol name in a code node. For example, 
     * if we are replacing a method symbol, for each method call where that symbol
     * appears, we only want to replace the portion of the text that contains the 
     * symbol. This means we have to narrow the {@link Vala.SourceReference} of
     * the expression. This same problem exists for data types, where we may wish
     * to replace ``TypeName`` in every instance of ``Namespace.TypeName``.
     *
     * @param code_node             A code node in the AST. Its ``source_reference`` must be non-``null``.
     * @param symbol                The symbol to replace inside the code node.
     * @return                      The replacement range, or ``null`` if ``symbol.name`` is not inside it
     */
    Range? get_replacement_range (Vala.CodeNode code_node, Vala.Symbol symbol) {
        var range = new Range.from_sourceref (code_node.source_reference);

        string representation = CodeHelp.get_expression_representation (code_node);
        int last_index_of_symbol;
        MatchInfo match_info;

        if (/^\s*foreach\s?\(.+\s+(\S+)\s+in\s+.+\)\s*$/m.match (representation, 0, out match_info)) {
            int start, end;
            if (match_info.fetch_pos (1, out start, out end) && match_info.fetch (1) == symbol.name)
                last_index_of_symbol = start;
            else
                last_index_of_symbol = -1;
        } else
            last_index_of_symbol = representation.last_index_of (symbol.name);

        if (last_index_of_symbol == -1)
            return null;
        
        // move the start of the range up [last_index_of_symbol] characters
        string prefix = representation[0:last_index_of_symbol];
        int last_index_of_newline_in_prefix = prefix.last_index_of_char ('\n');

        if (last_index_of_newline_in_prefix == -1) {
            range.start = range.start.translate (0, last_index_of_symbol);
        } else {
            int newline_count = 0;

            foreach (uint character in prefix.data)
                if ((char)character == '\n')
                    newline_count++;

            range.start = range.start.translate (newline_count, last_index_of_symbol - last_index_of_newline_in_prefix);
        }

        // move the end of the range back [length(symbol_name)] characters
        string suffix = representation[(last_index_of_symbol+symbol.name.length):representation.length];
        int last_index_of_newline_in_suffix = suffix.last_index_of_char ('\n');

        if (last_index_of_newline_in_suffix == -1) {
            range.end = range.end.translate (0, -(representation.length - (last_index_of_symbol + symbol.name.length)));
        } else {
            int newline_count = 0;

            foreach (uint character in suffix.data)
                if ((char)character == '\n')
                    newline_count++;
            
            range.end = range.end.translate (-newline_count, -(last_index_of_newline_in_suffix - (last_index_of_symbol + symbol.name.length)));
        }

        return range;
    }

    /** 
     * Because a {@link Vala.DataType} or {@link Vala.Symbol} code node 
     * does not have precise source reference information for each component
     * that the parser found before this data type/symbol was constructed by the
     * semantic analyzer, we use this to get all of the visible components
     * (that is, part of the original source
     * code spanning the {@link Vala.SourceReference}) of the ``code_node``.
     * If ``code_node.source_reference`` is ``null``, then this function returns
     * an empty list.
     *
     * @param code_node         The code node. Should be either a 
     *                          {@link Vala.DataType}, a {@link Vala.MemberAccess},
     *                          or a {@link Vala.Namespace}.
     * @return                  A collection of components found at the source code 
     *                          spanned by the data type code node. For example, if
     *                          the data type is {@link GLib.File}, then perhaps the
     *                          source code was ``File`` (if ``GLib`` is imported
     *                          elsewhere), or perhaps it was ``GLib.File``. If the
     *                          former, then the returned collection contains just
     *                          ``File``. If the latter, then the returned collection
     *                          contains both ``GLib`` and ``File``.
     */
    Collection<Pair<Vala.Symbol, Range>> get_visible_components_of_code_node (Vala.CodeNode code_node) {
        var components = new ArrayQueue<Pair<Vala.Symbol, Range>> ();
        Vala.Symbol? symbol = null;

        if (code_node is Vala.DataType)
            symbol = get_symbol_data_type_refers_to ((Vala.DataType) code_node);
        else if (code_node is Vala.Symbol)
            symbol = (Vala.Symbol) code_node;
        else if (code_node is Vala.MemberAccess)
            symbol = ((Vala.MemberAccess)code_node).symbol_reference;

        if (code_node.source_reference != null && symbol != null) {
            string representation = CodeHelp.get_expression_representation (code_node);
            int end = representation.length;

            // debug ("got representation for (%s) %s @ %s => %s", code_node.type_name, code_node.to_string (), code_node.source_reference.to_string (), representation);
            if (code_node is Vala.TypeSymbol || code_node is Vala.Namespace) {
                MatchInfo match_info;
                if (/((public|private|protected|internal)?\s*?(abstract)?\s*?(class|interface|errordomain|struct|enum|namespace)\s+)?(\w+(\.\w+)*)/m
                    .match (representation, 0, out match_info)) {
                    representation = (!) match_info.fetch (0);
                    end = representation.length;
                    // debug ("refined %s representation => %s", code_node.type_name, representation);
                }
            }

            // skip '?'
            if (end > 0 && representation[end - 1] == '?')
                end--;

            // skip any type parameters
            if (end > 0 && representation[end - 1] == '>') {
                end--;

                int unbalanced_rangles = 1;
                while (unbalanced_rangles > 0 && end > 0) {
                    if (representation[end - 1] == '<')
                        unbalanced_rangles--;
                    else if (representation[end - 1] == '>')
                        unbalanced_rangles++;
                    end--;
                }

                if (unbalanced_rangles != 0)
                    warning ("unbalanced right angles in representation of code node %s: %s", code_node.type_name, representation);
            }

            for (var current_sym = symbol; 
                current_sym != null && current_sym.name != null && end >= current_sym.name.length;
                current_sym = current_sym.parent_symbol) {
                int last_dot_char = -1;
                for (int i = 0; i < end; i++)
                    if (representation[i] == '.')
                        last_dot_char = i;
                if (representation.substring (last_dot_char + 1, end - (last_dot_char + 1)) == current_sym.name) {
                    int start = end - current_sym.name.length;

                    string prefix = representation[0:start+1];
                    int last_nl_pos;
                    int nl_count = (int) Util.count_chars_in_string (prefix, '\n', out last_nl_pos);
                    int begin_line = code_node.source_reference.begin.line + nl_count;
                    int begin_column = last_nl_pos == -1 ? code_node.source_reference.begin.column + start : start - last_nl_pos;
                    int end_line = begin_line;
                    int end_column = begin_column + current_sym.name.length - 1;
                    var sr = new Vala.SourceReference (code_node.source_reference.file,
                        Vala.SourceLocation (null, begin_line, begin_column),
                        Vala.SourceLocation (null, end_line, end_column));

                    components.offer_head (new Pair<Vala.Symbol, Range> (current_sym, new Range.from_sourceref (sr)));

                    end -= current_sym.name.length;
                    // skip spaces, then '.', then spaces
                    while (end > 0 && representation[end - 1].isspace ())
                        end--;
                    if (end > 0 && representation[end - 1] == '.') {
                        end--;
                    } else if (end > 0) {
                        string substring = representation.substring (0, end);
                        // get last word
                        int last_space_pos = substring.last_index_of_char (' ');
                        if (last_space_pos != -1)
                            substring = substring.substring (last_space_pos + 1);
                        if (substring != "unowned" && substring != "owned" && substring != "weak" && substring != "namespace" &&
                            substring != "class" && substring != "interface" && substring != "struct" &&
                            substring != "errordomain" && substring != "enum")
                            warning ("expected `.', got `%s' in symbol %s for %s (%s)", substring, symbol.get_full_name (), symbol.type_name, representation);
                        else
                            end = 0;
                        break;
                    }
                    while (end > 0 && representation[end - 1].isspace ())
                        end--;
                } else {
                    break;
                }
            }
        }

        return components;
    }

    /**
     * List all references to @sym in @file
     *
     * @param file                  the file to search for references in
     * @param symbol                the symbol to search for references to
     * @param include_declaration   whether to include declarations in references
     * @param references            the collection to fill with references
     */
    void list_in_file (Vala.SourceFile file, Vala.Symbol symbol, bool include_declaration, HashMap<Range, Vala.CodeNode> references) {
        new SymbolVisitor<HashMap<Range, Vala.CodeNode>> (file, symbol, references, include_declaration,
        (node, symbol, references) => {
            Collection<Pair<Vala.Symbol, Range>>? components = null;

            if (node == symbol || CodeHelp.namespaces_equal (node, symbol)) {
                references[(!) get_replacement_range (node, (Vala.Symbol)node)] = node;
            } else if (node is Vala.Expression && ((Vala.Expression)node).symbol_reference == symbol) {
                if (node is Vala.MemberAccess)
                    components = get_visible_components_of_code_node (node);
            } else if (node is Vala.UsingDirective && ((Vala.UsingDirective)node).namespace_symbol == symbol) {
                references[(!) get_replacement_range (node, symbol)] = node;
            } else if (node is Vala.CreationMethod && ((Vala.CreationMethod)node).parent_symbol == symbol) {
                references[(!) get_replacement_range (node, symbol)] = node;
            } else if (node is Vala.Destructor && ((Vala.Destructor)node).parent_symbol == symbol) {
                references[(!) get_replacement_range (node, symbol)] = node;
            } else {
                if (node is Vala.Namespace || node is Vala.TypeSymbol)
                    components = get_visible_components_of_code_node (node);
                else if (node is Vala.DataType) {
                    // it's expensive to run get_visible_components_of_code_node() every time we
                    // see a ValaDataType, so only run it if the source reference for the ValaDataType
                    // could potentially match @symbol
                    for (var current_sym = get_symbol_data_type_refers_to ((Vala.DataType) node); 
                            current_sym != null;
                            current_sym = current_sym.parent_symbol) {
                        if (symbol == current_sym) {
                            components = get_visible_components_of_code_node (node);
                            break;
                        }
                    }
                }
            }

            if (components != null) {
                var result = components.first_match (pair => pair.first == symbol || CodeHelp.namespaces_equal (pair.first, symbol));
                if (result != null)
                    references[result.second] = node;
            }
        });
    }

    /** 
     * It's possible that a symbol can be used across build targets within a
     * project. This returns a list of all pairs of ``(compilation, symbol)``
     * matching @sym where ``symbol`` is defined within ``compilation``.
     *
     * @param project       the project to search for a symbol in
     * @param symbol        the symbol to search for
     * @return              a list of pairs of ``(compilation, symbol)``
     */
    Collection<Pair<Compilation, Vala.Symbol>> get_compilations_using_symbol (Project project, Vala.Symbol symbol) {
        var compilations = new ArrayList<Pair<Compilation, Vala.Symbol>> ();

        foreach (var compilation in project.get_compilations ()) {
            Vala.Symbol? matching_sym = find_matching_symbol (compilation.code_context, symbol);
            if (matching_sym != null)
                compilations.add (new Pair<Compilation, Vala.Symbol> (compilation, matching_sym));
        }

        // find_matching_symbol() isn't reliable with local variables, especially those declared
        // in lambdas, which can change names after recompilation.
        if (symbol is Vala.LocalVariable) {
            project.get_compilations ()
                .filter (c => symbol.source_reference.file in c.code_context.get_source_files ())
                .foreach (compilation => {
                    compilations.add (new Pair<Compilation, Vala.Symbol> (compilation, symbol));
                    return false;
                });
        }

        return compilations;
    }

    Vala.Symbol? get_symbol_data_type_refers_to (Vala.DataType data_type) {
        var error_type = data_type as Vala.ErrorType;
        var generic_type = data_type as Vala.GenericType;
        Vala.Symbol? symbol = null;

        if (error_type != null)
            symbol = error_type.error_code;
        else if (generic_type != null)
            symbol = generic_type.type_parameter;

        if (symbol == null)
            symbol = data_type.symbol;

        return symbol;
    }
}