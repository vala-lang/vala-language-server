namespace LanguageServer {
    /**
     * Defines how the host (editor) should sync document changes to the language server.
     */
    [CCode (default_value = "LANGUAGE_SERVER_TEXT_DOCUMENT_SYNC_KIND_Unset")]
    enum TextDocumentSyncKind {
        Unset = -1,
        /**
         * Documents should not be synced at all.
         */
        None = 0,
        /**
         * Documents are synced by always sending the full content of the document.
         */
        Full = 1,
        /**
         * Documents are synced by sending the full content on open. After that only incremental
         * updates to the document are sent.
         */
        Incremental = 2
    }

    enum DiagnosticSeverity {
        Unset = 0,
        /**
         * Reports an error.
         */
        Error = 1,
        /**
         * Reports a warning.
         */
        Warning = 2,
        /**
         * Reports an information.
         */
        Information = 3,
        /**
         * Reports a hint.
         */
        Hint = 4
    }

    class Position : Object, Gee.Comparable<Position> {
        /**
         * Line position in a document (zero-based).
         */
        public uint line { get; set; default = -1; }

        /**
         * Character offset on a line in a document (zero-based). Assuming that the line is
         * represented as a string, the `character` value represents the gap between the
         * `character` and `character + 1`.
         *
         * If the character value is greater than the line length it defaults back to the
         * line length.
         */
        public uint character { get; set; default = -1; }

        public int compare_to (Position other) {
            return line > other.line ? 1 :
                (line == other.line ?
                 (character > other.character ? 1 :
                  (character == other.character ? 0 : -1)) : -1);
        }

        public string to_string () {
            return @"$line:$character";
        }

        public Position.from_libvala (Vala.SourceLocation sloc) {
            line = sloc.line - 1;
            character = sloc.column;
        }

        public Position dup () {
            return this.translate ();
        }

        public Position translate (int dl = 0, int dc = 0) {
            return new Position () {
                line = this.line + dl,
                character = this.character + dc
            };
        }
    }

    class Range : Object, Gee.Hashable<Range>, Gee.Comparable<Range> {
        /**
         * The range's start position.
         */
        public Position start { get; set; }

        /**
         * The range's end position.
         */
        public Position end { get; set; }

        public string to_string () { return @"$start -> $end"; }

        public Range.from_sourceref (Vala.SourceReference sref) {
            this.start = new Position.from_libvala (sref.begin);
            this.end = new Position.from_libvala (sref.end);
            this.start.character -= 1;
        }

        public uint hash () {
            return this.to_string ().hash ();
        }

        public bool equal_to (Range other) { return this.to_string () == other.to_string (); }

        public int compare_to (Range other) {
            return start.compare_to (other.start);
        }

        /**
         * Return a new range that includes `this` and `other`.
         */
        public Range union (Range other) {
            return new Range () {
                start = start.compare_to (other.start) < 0 ? start : other.start,
                end = end.compare_to (other.end) < 0 ? other.end : end
            };
        }

        public bool contains (Position pos) {
            return start.compare_to (pos) <= 0 && pos.compare_to (end) <= 0;
        }
    }

    class Diagnostic : Object {
        /**
         * The range at which the message applies.
         */
        public Range range { get; set; }

        /**
         * The diagnostic's severity. Can be omitted. If omitted it is up to the
         * client to interpret diagnostics as error, warning, info or hint.
         */
        public DiagnosticSeverity severity { get; set; }

        /**
         * The diagnostic's code. Can be omitted.
         */
        public string? code { get; set; }

        /**
         * A human-readable string describing the source of this
         * diagnostic, e.g. 'typescript' or 'super lint'.
         */
        public string? source { get; set; }

        /**
         * The diagnostic's message.
         */
        public string message { get; set; }
    }

    /**
     * An event describing a change to a text document. If range and rangeLength are omitted
     * the new text is considered to be the full content of the document.
     */
    class TextDocumentContentChangeEvent : Object {
        public Range? range { get; set; }
        public int rangeLength { get; set; }
        public string text { get; set; }
    }

    enum MessageType {
        /**
         * An error message.
         */
        Error = 1,
        /**
         * A warning message.
         */
        Warning = 2,
        /**
         * An information message.
         */
        Info = 3,
        /**
         * A log message.
         */
        Log = 4
    }

    class TextDocumentIdentifier : Object {
        public string uri { get; set; }
    }

    class TextDocumentPositionParams : Object {
        public TextDocumentIdentifier textDocument { get; set; }
        public Position position { get; set; }
    }

    class ReferenceParams : TextDocumentPositionParams {
        public class ReferenceContext : Object {
            public bool includeDeclaration { get; set; }
        }
        public ReferenceContext? context { get; set; }
    }

    class Location : Object {
        public string uri { get; set; }
        public Range range { get; set; }

        internal Location () {}
        public Location.from_sourceref (Vala.SourceReference sref) {
            this.uri = File.new_for_commandline_arg (sref.file.filename).get_uri ();
            this.range = new Range.from_sourceref (sref);
        }
    }

    [CCode (default_value = "LANGUAGE_SERVER_DOCUMENT_HIGHLIGHT_KIND_Text")]
    enum DocumentHighlightKind {
        Text = 1,
        Read = 2,
        Write = 3
    }

    class DocumentHighlight : Object {
        public Range range { get; set; }
        public DocumentHighlightKind kind { get; set; }
    }

    class DocumentSymbolParams: Object {
        public TextDocumentIdentifier textDocument { get; set; }
    }

    class DocumentSymbol : Object, Json.Serializable {
        private Vala.SourceReference? _source_reference;
        public string name { get; set; }
        public string? detail { get; set; }
        public SymbolKind kind { get; set; }
        public bool deprecated { get; set; }
        private Range? _initial_range;
        public Range range {
            owned get {
                if (_initial_range == null)
                    _initial_range = new Range.from_sourceref (children.first ()._source_reference);

                return children.fold<Range> ((child, current_range) => current_range.union (child.range), _initial_range);
            }
        }
        public Range selectionRange { get; set; }
        public Gee.List<DocumentSymbol> children { get; private set; default = new Gee.LinkedList<DocumentSymbol> (); }

        /**
         * @param type the data type containing this symbol, if there was one (not available for Namespaces, for example)
         * @param sym the symbol
         */
        public DocumentSymbol.from_vala_symbol (Vala.DataType? type, Vala.Symbol sym, SymbolKind kind) {
            this._initial_range = new Range.from_sourceref (sym.source_reference);
            if (sym is Vala.Subroutine) {
                var sub = (Vala.Subroutine) sym;
                var body_sref = sub.body != null ? sub.body.source_reference : null;
                // debug ("subroutine %s found (body @ %s)", sym.get_full_name (),
                //         body_sref != null ? body_sref.to_string () : null);
                if (body_sref != null && (body_sref.begin.line < body_sref.end.line ||
                                          body_sref.begin.line == body_sref.end.line && body_sref.begin.pos <= body_sref.end.pos)) {
                    this._initial_range = this._initial_range.union (new Range.from_sourceref (body_sref));
                }
            }
            this.name = sym.name;
            this.detail = Vls.CodeHelp.get_symbol_representation (type, sym, null);
            this.kind = kind;
            this.selectionRange = new Range.from_sourceref (sym.source_reference);
            this.deprecated = sym.version.deprecated;
        }

        public new void Json.Serializable.set_property (ParamSpec pspec, Value value) {
            base.set_property (pspec.get_name (), value);
        }

        public new Value Json.Serializable.get_property (ParamSpec pspec) {
            Value val = Value (pspec.value_type);
            base.get_property (pspec.get_name (), ref val);
            return val;
        }

        public unowned ParamSpec? find_property (string name) {
            return this.get_class ().find_property (name);
        }

        public Json.Node serialize_property (string property_name, Value value, ParamSpec pspec) {
            if (property_name != "children")
                return default_serialize_property (property_name, value, pspec);
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.init_array (new Json.Array ());
            var array = node.get_array ();
            foreach (var child in children)
                array.add_element (Json.gobject_serialize (child));
            return node;
        }

        public bool deserialize_property (string property_name, out Value value, ParamSpec pspec, Json.Node property_node) {
            error ("deserialization not supported");
        }
    }

    class SymbolInformation : Object {
        public string name { get; set; }
        public SymbolKind kind { get; set; }
        public Location location { get; set; }
        public string? containerName { get; set; }

        public SymbolInformation.from_document_symbol (DocumentSymbol dsym, string uri) {
            this.name = dsym.name;
            this.kind = dsym.kind;
            this.location = new Location () {
                uri = uri,
                range = dsym.range
            };
        }
    }

    [CCode (default_value = "LANGUAGE_SERVER_SYMBOL_KIND_Variable")]
    enum SymbolKind {
        File = 1,
        Module = 2,
        Namespace = 3,
        Package = 4,
        Class = 5,
        Method = 6,
        Property = 7,
        Field = 8,
        Constructor = 9,
        Enum = 10,
        Interface = 11,
        Function = 12,
        Variable = 13,
        Constant = 14,
        String = 15,
        Number = 16,
        Boolean = 17,
        Array = 18,
        Object = 19,
        Key = 20,
        Null = 21,
        EnumMember = 22,
        Struct = 23,
        Event = 24,
        Operator = 25,
        TypeParameter = 26
    }

    class CompletionList : Object, Json.Serializable {
        public bool isIncomplete { get; set; }
        public Gee.List<CompletionItem> items { get; private set; default = new Gee.LinkedList<CompletionItem> (); }

        public new void Json.Serializable.set_property (ParamSpec pspec, Value value) {
            base.set_property (pspec.get_name (), value);
        }

        public new Value Json.Serializable.get_property (ParamSpec pspec) {
            Value val = Value (pspec.value_type);
            base.get_property (pspec.get_name (), ref val);
            return val;
        }

        public unowned ParamSpec? find_property (string name) {
            return this.get_class ().find_property (name);
        }

        public Json.Node serialize_property (string property_name, Value value, ParamSpec pspec) {
            if (property_name != "items")
                return default_serialize_property (property_name, value, pspec);
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.init_array (new Json.Array ());
            var array = node.get_array ();
            foreach (var child in items)
                array.add_element (Json.gobject_serialize (child));
            return node;
        }

        public bool deserialize_property (string property_name, out Value value, ParamSpec pspec, Json.Node property_node) {
            error ("deserialization not supported");
        }

    }

    [CCode (default_value = "LANGUAGE_SERVER_COMPLETION_TRIGGER_KIND_Invoked")]
    enum CompletionTriggerKind {
        /**
         * Completion was triggered by typing an identifier (24x7 code
         * complete), manual invocation (e.g Ctrl+Space) or via API.
         */
        Invoked = 1,

        /**
         * Completion was triggered by a trigger character specified by
         * the `triggerCharacters` properties of the `CompletionRegistrationOptions`.
         */
        TriggerCharacter = 2,

        /**
         * Completion was re-triggered as the current completion list is incomplete.
         */
        TriggerForIncompleteCompletions = 3
    }

    class CompletionContext : Object {
        public CompletionTriggerKind triggerKind { get; set;}
        public string? triggerCharacter { get; set; }
    }

    class CompletionParams : TextDocumentPositionParams {
        /**
         * The completion context. This is only available if the client specifies
         * to send this using `ClientCapabilities.textDocument.completion.contextSupport === true`
         */
        public CompletionContext? context { get; set; }
    }

    enum CompletionItemTag {
        // Render a completion as obsolete, usually using a strike-out.
        Deprecated = 1,
    }

    [CCode (default_value = "LANGUAGE_SERVER_INSERT_TEXT_FORMAT_PlainText")]
    enum InsertTextFormat {
        /**
         * The primary text to be inserted is treated as a plain string.
         */
        PlainText = 1,

        /**
         * The primary text to be inserted is treated as a snippet.
         *
         * A snippet can define tab stops and placeholders with `$1`, `$2`
         * and `${3:foo}`. `$0` defines the final tab stop, it defaults to
         * the end of the snippet. Placeholders with equal identifiers are linked,
         * that is typing in one will update others too.
         */
        Snippet = 2,
    }

    class CompletionItem : Object, Gee.Hashable<CompletionItem>, Json.Serializable {
        public string label { get; set; }
        public CompletionItemKind kind { get; set; }
        public string detail { get; set; }
        public MarkupContent? documentation { get; set; }
        public bool deprecated { get; set; }
        public Gee.List<CompletionItemTag> tags { get; private set; default = new Gee.ArrayList<CompletionItemTag> (); }
        public string? insertText { get; set; }
        public InsertTextFormat insertTextFormat { get; set; }
        private uint _hash;

        private CompletionItem () {}

        public CompletionItem.keyword (string keyword, string? insert_text = null, string? documentation = null) {
            this.label = keyword;
            this.kind = CompletionItemKind.Keyword;
            this.insertText = insert_text;
            if (insert_text != null && (insert_text.contains ("$0") || insert_text.contains ("${0")))
                this.insertTextFormat = InsertTextFormat.Snippet;
            if (documentation != null)
                this.documentation = new MarkupContent.from_plaintext (documentation);
            this._hash = this.label.hash ();
        }

        /**
         * A completion suggestion from an existing Vala symbol.
         * 
         * @param instance_type the parent data type of data type of the expression where this symbol appears, or null
         * @param sym the symbol itself
         * @param scope the scope to display this in
         * @param kind the kind of completion to display
         * @param documentation the documentation to display
         * @param label_override if non-null, override the displayed symbol name with this
         */
        public CompletionItem.from_symbol (Vala.DataType? instance_type, Vala.Symbol sym, Vala.Scope? scope,
            CompletionItemKind kind, Vls.DocComment? documentation, string? label_override = null) {
            this.label = label_override ?? sym.name;
            this.kind = kind;
            this.detail = Vls.CodeHelp.get_symbol_representation (instance_type, sym, scope, null, null, false);
            this._hash = this.label.hash ();

            if (documentation != null)
                this.documentation = new MarkupContent.from_markdown (documentation.body);

            var version = sym.get_attribute ("Version");
            if (version != null && (version.get_bool ("deprecated") || version.get_string ("deprecated_since") != null)) {
                this.tags.add (CompletionItemTag.Deprecated);
                this.deprecated = true;
            }
        }

        /**
         * A completion suggestion from a data type and a synthetic symbol name.
         *
         * @param symbol_type       the data type of the symbol
         * @param symbol_name       the name of the synthetic symbol
         * @param scope             the scope that this completion item is displayed in, or null
         * @param kind              the type of completion to display
         * @param documentation     the documentation for this symbol, or null
         */
        public CompletionItem.from_synthetic_symbol (Vala.DataType symbol_type, string symbol_name, Vala.Scope? scope,
                                                     CompletionItemKind kind, Vls.DocComment? documentation) {
            this.label = symbol_name;
            this.kind = kind;
            this.detail = @"$(Vls.CodeHelp.get_symbol_representation (symbol_type, null, scope, null, null, false)) $symbol_name";
            this._hash = this.label.hash ();

            if (documentation != null)
                this.documentation = new MarkupContent.from_markdown (documentation.body);
        }

        public CompletionItem.from_unimplemented_symbol (Vala.Symbol sym,
                                                         string label, CompletionItemKind kind,
                                                         string insert_text,
                                                         Vls.DocComment? documentation) {
            this.label = label;
            this.kind = kind;
            this.insertText = insert_text;
            if (insert_text.contains ("$0") || insert_text.contains ("${0"))
                this.insertTextFormat = InsertTextFormat.Snippet;
            this._hash = this.label.hash ();
            if (documentation != null)
                this.documentation = new MarkupContent.from_markdown (documentation.body);
        }

        public uint hash () {
            return this._hash;
        }

        public bool equal_to (CompletionItem other) {
            return other.label == this.label && other.kind == this.kind;
        }

        public new void Json.Serializable.set_property (ParamSpec pspec, Value value) {
            base.set_property (pspec.get_name (), value);
        }

        public new Value Json.Serializable.get_property (ParamSpec pspec) {
            Value val = Value (pspec.value_type);
            base.get_property (pspec.get_name (), ref val);
            return val;
        }

        public unowned ParamSpec? find_property (string name) {
            return this.get_class ().find_property (name);
        }

        public Json.Node serialize_property (string property_name, Value value, ParamSpec pspec) {
            if (property_name != "tags")
                return default_serialize_property (property_name, value, pspec);

            var node = new Json.Node (Json.NodeType.ARRAY);
            node.init_array (new Json.Array ());
            var array = node.get_array ();
            foreach (var tag in this.tags) {
                array.add_int_element (tag);
            }

            return node;
        }

        public bool deserialize_property (string property_name, out Value value, ParamSpec pspec, Json.Node property_node) {
            error ("deserialization not supported");
        }

    }

    class MarkupContent : Object {
        public string kind { get; set; }
        public string value { get; set; }

        private MarkupContent () {}

        /**
         * Create a MarkupContent with plain text.
         */
        public MarkupContent.from_plaintext (string doc) {
            this.kind = "plaintext";
            this.value = doc;
        }

        /**
         * Create a MarkupContent with markdown text.
         */
        public MarkupContent.from_markdown (string doc) {
            this.kind = "markdown";
            this.value = doc;
        }
    }

    [CCode (default_value = "LANGUAGE_SERVER_COMPLETION_ITEM_KIND_Text")]
    enum CompletionItemKind {
        Text = 1,
        Method = 2,
        Function = 3,
        Constructor = 4,
        Field = 5,
        Variable = 6,
        Class = 7,
        Interface = 8,
        Module = 9,
        Property = 10,
        Unit = 11,
        Value = 12,
        Enum = 13,
        Keyword = 14,
        Snippet = 15,
        Color = 16,
        File = 17,
        Reference = 18,
        Folder = 19,
        EnumMember = 20,
        Constant = 21,
        Struct = 22,
        Event = 23,
        Operator = 24,
        TypeParameter = 25
    }

    class TextDocumentClientCapabilities : Object {
        public class DocumentSymbolCapabilities : Object {
            public bool hierarchicalDocumentSymbolSupport { get; set; }
        }
        public DocumentSymbolCapabilities documentSymbol { get; set; default = new DocumentSymbolCapabilities ();}
    }

    class ClientCapabilities : Object {
        public TextDocumentClientCapabilities textDocument { get; set; default = new TextDocumentClientCapabilities (); }
    }

    class InitializeParams : Object {
        public int processId { get; set; }
        public string? rootPath { get; set; }
        public string? rootUri { get; set; }
        public ClientCapabilities capabilities { get; set; default = new ClientCapabilities (); }
    }

    class SignatureInformation : Object, Json.Serializable {
        public string label { get; set; }
        public MarkupContent documentation { get; set; }

        public Gee.List<ParameterInformation> parameters { get; private set; default = new Gee.LinkedList<ParameterInformation> (); }

        public new void Json.Serializable.set_property (ParamSpec pspec, Value value) {
            base.set_property (pspec.get_name (), value);
        }

        public new Value Json.Serializable.get_property (ParamSpec pspec) {
            Value val = Value (pspec.value_type);
            base.get_property (pspec.get_name (), ref val);
            return val;
        }

        public unowned ParamSpec? find_property (string name) {
            return this.get_class ().find_property (name);
        }

        public Json.Node serialize_property (string property_name, Value value, ParamSpec pspec) {
            if (property_name != "parameters")
                return default_serialize_property (property_name, value, pspec);
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.init_array (new Json.Array ());
            var array = node.get_array ();
            foreach (var child in parameters)
                array.add_element (Json.gobject_serialize (child));
            return node;
        }

        public bool deserialize_property (string property_name, out Value value, ParamSpec pspec, Json.Node property_node) {
            error ("deserialization not supported");
        }
    }

    class SignatureHelp : Object, Json.Serializable {
        public Gee.Collection<SignatureInformation> signatures { get; set; default = new Gee.ArrayList<SignatureInformation> (); }
        public int activeSignature { get; set; }
        public int activeParameter { get; set; }

        public Json.Node serialize_property (string property_name, Value value, ParamSpec pspec) {
            if (property_name != "signatures")
                return default_serialize_property (property_name, value, pspec);

            var node = new Json.Node (Json.NodeType.ARRAY);
            node.init_array (new Json.Array ());
            var array = node.get_array ();
            foreach (var child in signatures)
                array.add_element (Json.gobject_serialize (child));
            return node;
        }

        public bool deserialize_property (string property_name, out Value value, ParamSpec pspec, Json.Node property_node) {
            error ("deserialization not supported");
        }
    }

    class ParameterInformation : Object {
        public string label { get; set; }
        public MarkupContent documentation { get; set; }
    }

    class MarkedString : Object {
        public string language { get; set; }
        public string value { get; set; }
    }

    class Hover : Object, Json.Serializable {
        public Gee.List<MarkedString> contents { get; set; default = new Gee.ArrayList<MarkedString> (); }
        public Range range { get; set; }

        public new void Json.Serializable.set_property (ParamSpec pspec, Value value) {
            base.set_property (pspec.get_name (), value);
        }

        public new Value Json.Serializable.get_property (ParamSpec pspec) {
            Value val = Value (pspec.value_type);
            base.get_property (pspec.get_name (), ref val);
            return val;
        }

        public unowned ParamSpec? find_property (string name) {
            return this.get_class ().find_property (name);
        }

        public Json.Node serialize_property (string property_name, Value value, ParamSpec pspec) {
            if (property_name != "contents")
                return default_serialize_property (property_name, value, pspec);
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.init_array (new Json.Array ());
            var array = node.get_array ();
            foreach (var child in contents) {
                if (child.language != null)
                    array.add_element (Json.gobject_serialize (child));
                else
                    array.add_element (new Json.Node (Json.NodeType.VALUE).init_string (child.value));
            }
            return node;
        }

        public bool deserialize_property (string property_name, out Value value, ParamSpec pspec, Json.Node property_node) {
            error ("deserialization not supported");
        }
    }
}
