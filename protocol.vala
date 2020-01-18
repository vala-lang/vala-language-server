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

    class Position : Object {
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

        public int compare (Position other) {
            return line > other.line ? 1 :
                (line == other.line ?
                 (character > other.character ? 1 :
                  (character == other.character ? 0 : -1)) : -1);
        }

        public string to_string () { return @"$line:$character"; }

        public Position to_libvala () {
            return new Position () {
                line = this.line + 1,
                character = this.character
            };
        }

        public Position.from_libvala (Vala.SourceLocation sloc) {
            line = sloc.line - 1;
            character = sloc.column;
        }

        public Position translate (int dl = 0, int dc = 0) {
            return new Position () {
                line = this.line + dl,
                character = this.character + dc
            };
        }
    }

    class Range : Object, Gee.Hashable<Range> {
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

        /**
         * Return a new range that includes `this` and `other`.
         */
        public Range union (Range other) {
            return new Range () {
                start = start.compare (other.start) < 0 ? start : other.start,
                end = end.compare (other.end) < 0 ? other.end : end
            };
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
        public Range? range    { get; set; }
        public int rangeLength { get; set; }
        public string text     { get; set; }
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

    class Location : Object {
        public string uri { get; set; }
        public Range range { get; set; }
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
        public string name { get; set; }
        public string? detail { get; set; }
        public SymbolKind kind { get; set; }
        public bool deprecated { get; set; }
        public Range range { get; set; }
        public Range selectionRange { get; set; }
        public Gee.List<DocumentSymbol> children { get; private set; default = new Gee.LinkedList<DocumentSymbol> (); }

        public DocumentSymbol.from_vala_symbol (Vala.Symbol sym, SymbolKind kind) {
            this.name = sym.name;
            this.kind = kind;
            this.range = Vls.Server.get_best_range (sym);
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
            Value val = Value(pspec.value_type);
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

    class CompletionItem : Object, Gee.Hashable<CompletionItem> {
        public string label { get; set; }
        public CompletionItemKind kind { get; set; }
        public string detail { get; set; }
        public MarkupContent documentation { get; set; }
        private uint _hash;
        protected string _hash_string;

        private CompletionItem () {}

        public CompletionItem.from_symbol (Vala.Symbol sym, CompletionItemKind kind) {
            this.label = sym.name;
            this.kind = kind;
            this.detail = Vls.Server.get_symbol_data_type (sym);
            this.documentation = Vls.Server.get_symbol_comment (sym);
            this._hash_string = @"$label $(Vls.Server.get_symbol_data_type (sym, true)) $kind";
            this._hash = _hash_string.hash ();
        }

        public CompletionItem.for_signal (string label, string detail, string documentation) {
            this.label = label;
            this.kind = CompletionItemKind.Method;
            this.detail = detail;
            this.documentation = new MarkupContent () { value = documentation };
            this._hash_string = @"$label $kind";
            this._hash = _hash_string.hash ();
        }

        public uint hash () {
            return this._hash;
        }

        public bool equal_to (CompletionItem other) {
            return other._hash_string == this._hash_string;
        }
    }

    class MarkupContent : Object {
        public string kind { get; set; default = "plaintext"; }
        public string value { get; set; }
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
            Value val = Value(pspec.value_type);
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
            Value val = Value(pspec.value_type);
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
