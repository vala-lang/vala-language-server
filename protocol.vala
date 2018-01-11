/**
 * Defines how the host (editor) should sync document changes to the language server.
 */
[CCode (default_value = "LANGUAGE_SERVER_TEXT_DOCUMENT_SYNC_KIND_Unset")]
enum LanguageServer.TextDocumentSyncKind {
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

enum LanguageServer.DiagnosticSeverity {
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

class LanguageServer.Position : Object {
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

	public LanguageServer.Position to_libvala () {
		return new Position () {
			line = this.line + 1,
			character = this.character
		};
	}
}

class LanguageServer.Range : Object {
	/**
	 * The range's start position.
	 */
	public Position start { get; set; }

	/**
	 * The range's end position.
	 */
	public Position end { get; set; }
}

class LanguageServer.Diagnostic : Object {
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
class LanguageServer.TextDocumentContentChangeEvent : Object {
	public Range? range 		{ get; set; }
	public int? rangeLength 	{ get; set; }
	public string text 			{ get; set; }
}

enum LanguageServer.MessageType {
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

class LanguageServer.TextDocumentIdentifier : Object {
	public string uri { get; set; }
}

class LanguageServer.TextDocumentPositionParams : Object {
	public TextDocumentIdentifier textDocument { get; set; }
	public Position position { get; set; }
}

class LanguageServer.Location : Object {
	public string uri { get; set; }
	public Range range { get; set; }
}