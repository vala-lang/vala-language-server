using Gee;

/**
 * Represents a documentation comment after it has been
 * formatted into Markdown.
 */
class Vls.DocComment {
    /**
     * The main body of the comment, in Markdown.
     * {@inheritDoc}
     */
    public string body { get; private set; default = ""; }

    /**
     * The list of parameters for this symbol. The key is the
     * parameter name and the value is the Markdown documentation for 
     * that parameter.
     */
    public HashMap<string, string> parameters { get; private set; default = new HashMap<string, string> (); }

    /**
     * The comment about the return value, if applicable.
     */
    public string? return_body { get; private set; }

    /**
     * Create a documentation comment from a Markdown string. No rendering is done.
     */
    public DocComment (string markdown_doc) {
        body = markdown_doc;
    }

#if PARSE_SYSTEM_GIRS
    /**
     * Render a GTK-Doc-formatted comment into Markdown.
     *
     * see [[https://developer.gnome.org/gtk-doc-manual/stable/documenting_syntax.html.en]]
     *
     * @param comment           A comment in GTK-Doc format
     * @param documentation     Holds GIR documentation and renders the comment
     * @param compilation       The current compilation that is the context of the comment
     */
    public DocComment.from_gir_comment (Vala.Comment comment, GirDocumentation documentation, Compilation compilation) throws RegexError {
        body = documentation.render_gtk_doc_comment (comment, compilation);
        if (comment is Vala.GirComment) {
            var gir_comment = (Vala.GirComment) comment;
            for (var it = gir_comment.parameter_iterator (); it.next (); )
                parameters[it.get_key ()] = documentation.render_gtk_doc_comment (it.get_value (), compilation);
            if (gir_comment.return_content != null)
                return_body = documentation.render_gtk_doc_comment (gir_comment.return_content, compilation);
        }
    }
#endif

    /**
     * Render a ValaDoc-formatted comment into Markdown.
     *
     * see [[https://valadoc.org/markup.htm]]
     * 
     * @param comment           a comment in ValaDoc format
     * @param symbol            the symbol associated with the comment
     * @param compilation       the current compilation that is the context of the comment
     */
    public DocComment.from_valadoc_comment (Vala.Comment comment, Vala.Symbol symbol, Compilation compilation) throws RegexError {
        body = comment.content;

        // strip the comment of asterisks
        body = /^[\t\f\v ]*\*+[ \t\f]*(.*)$/m.replace (body, body.length, 0, "\\1");

        // render highlighting hints: bold, underlined, italic, and block quote
        // bold
        body = /''(.*?)''/.replace (body, body.length, 0, "**\\1**");
        // underlined
        body = /__(.*)__/.replace (body, body.length, 0, "<ins>\\1</ins>");
        // italic
        body = /\/\/(.*?)\/\//.replace (body, body.length, 0, "_\\1_");
        // quotes
        body = /\n?(?<!`)``([^`]+([^`]|`(?!``))*?)``\n{0,2}/s.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            string quote = match_info.fetch (1) ?? "";

            if (quote.index_of_char ('\n') == -1) {
                // inline quotes
                result.append_c ('`');
                result.append (quote);
                result.append_c ('`');
            } else {
                // block quotes
                result.append_c ('\n');
                foreach (string line in quote.split ("\n")) {
                    result.append ("> ");
                    result.append (line);
                    result.append_c ('\n');
                }
                result.append_c ('\n');
            }
            return false;
        });

        // TODO: we'll avoid rendering all of the kinds of lists now, since some are already
        // supported by markdown

        // code blocks (with support for a non-standard language specifier)
        body = /{{{(\w+)?(.*?)}}}/s.replace (body, body.length, 0, "```\\1\\2```");

        // images and links
        body = /(\[\[|{{)([~:\/\\\w-.]+)(\|(.*?))?(\]\]|}})/
            .replace_eval (body, body.length, 0, 0, (match_info, result) => {
                string type = match_info.fetch (1) ?? "";
                string href = match_info.fetch (2) ?? "";
                string name = match_info.fetch (4) ?? "";
                string end = match_info.fetch (5) ?? "";

                if (!(type == "[[" && end == "]]" || type == "{{" && end == "}}")) {
                    result.append ((!) match_info.fetch (0));
                } else {                    // image or link
                    if (name == "" && type == "[[")
                        result.append (href);
                    else {
                        if (type == "{{")
                            result.append_c ('!');
                        result.append_c ('[');
                        result.append (name);
                        result.append ("](");
                        result.append (href);
                        result.append_c (')');
                    }
                }
                return false;
            });

        // tables
        body = /(?'header'\|\|(.*?\|\|)+(\n|$))(?'rest'(?&header)+)/
            .replace_eval (body, body.length, 0, 0, (match_info, result) => {
                string header = match_info.fetch_named ("header") ?? "";
                string rest = match_info.fetch_named ("rest") ?? "";
                var columns_regex = /\|\|((([^`\n\r]|`.*?`)*?)(?=\|\|))?/;
                MatchInfo header_minfo;

                if (!columns_regex.match (header, 0, out header_minfo)) {
                    result.append ("\n\n(failed to render ValaDoc table)\n\n");
                    return false;
                }

                try {
                    result.append (columns_regex.replace (header, header.length, 0, "|\\1"));
                    result.append_c ('|');
                    string header_content = "";
                    while (header_minfo.matches () && (header_content = (header_minfo.fetch (1) ?? "")).strip () != "") {
                        result.append (string.nfill (header_content.length, '-'));
                        result.append_c ('|');
                        header_minfo.next ();
                    }
                    result.append_c ('\n');
                    result.append (columns_regex.replace (rest, rest.length, 0, "|\\1"));
                } catch (RegexError e) {
                    warning ("failed to render ValaDoc table - %s", e.message);
                    result.append ("\n\n(failed to render ValaDoc table)\n\n");
                }

                return false;
            });

        // render headlines
        body = /^(?<prefix>=+) (.+?) (?P=prefix)$/m
            .replace_eval (body, body.length, 0, 0, (match_info, result) => {
                string prefix = (!) match_info.fetch_named ("prefix");
                string heading = (!) match_info.fetch (2);

                result.append (string.nfill (prefix.length, '#'));
                result.append_c (' ');
                result.append (heading);
                return false;
            });

        // inline taglets
        DocComment? parent_comment = null;
        bool computed_parent = false;
        body = /{@inheritDoc}/.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            if (!computed_parent) {
                computed_parent = true;
                if (symbol.parent_symbol != null && symbol.parent_symbol.comment != null) {
                    try {
                        parent_comment = new DocComment.from_valadoc_comment (symbol.parent_symbol.comment, symbol.parent_symbol, compilation);
                    } catch (RegexError e) {
                        warning ("could not render comment - could not render parent comment - %s", e.message);
                        result.append ("(could not render parent comment - ");
                        result.append (e.message);
                        result.append_c (')');
                        return true;
                    }
                }
                if (parent_comment != null)
                    result.append (parent_comment.body);
            }
            return false;
        });

        // inline references to other symbols (XXX: should we tranform these into links?)
        body = /{@link ((?'ident'[A-Za-z_]\w*)(\.(?&ident))*?)}/.replace (body, body.length, 0, "**\\1**");

        // block taglets: @param
        body = /^@param ([A-Za-z_]\w*)[\t\f\v ]+(.+(\n[\t\f ]?([^@]|@(?!deprecated|see|param|since|return|throws))+)*)$/m
            .replace_eval (body, body.length, 0, 0, (match_info, result) => {
                string param_name = (!) match_info.fetch (1);
                string param_description = (!) match_info.fetch (2);

                parameters[param_name] = param_description;
                return false;
            });

        // block taglets: @return
        body = /^@return[\t\f\v ]+(.+(\n[\t\f ]?([^@]|@(?!deprecated|see|param|since|return|throws))+)*)$/m
            .replace_eval (body, body.length, 0, 0, (match_info, result) => {
                return_body = (!) match_info.fetch (1);
                return false;
            });

        // block taglets: @see
        body = /^@see[\t\f ]+((?'ident'[A-Za-z_]\w*)(\.(?&ident))*?)$/m
            .replace_eval (body, body.length, 0, 0, (match_info, result) => {
                string symbol_name = match_info.fetch (1);
                result.append ("\n\n**see** ");
                result.append ("`");
                result.append (symbol_name);
                result.append ("`");
                return false;
            });
    }
}
