using LanguageServer;
class Vls.SourceMessage {
    public Vala.SourceReference? loc;
    public string message;
    public DiagnosticSeverity severity;

    public SourceMessage (Vala.SourceReference? loc, string message, DiagnosticSeverity severity) {
        this.loc = loc;
        this.message = message;
        this.severity = severity;
    }
}

class Vls.Reporter : Vala.Report {
    public GenericArray<SourceMessage> messages = new GenericArray<SourceMessage> ();

    public override void depr (Vala.SourceReference? source, string message) {
        messages.add (new SourceMessage (source, message, DiagnosticSeverity.Warning));
        ++warnings;
    }
    public override void err (Vala.SourceReference? source, string message) {
        if (source == null) { // non-source compiler error
            stderr.printf ("Error: %s\n", message);
        } else {
            messages.add (new SourceMessage (source, message, DiagnosticSeverity.Error));
            ++errors;
        }
    }
    public override void note (Vala.SourceReference? source, string message) {
        messages.add (new SourceMessage (source, message, DiagnosticSeverity.Information));
        ++warnings;
    }
    public override void warn (Vala.SourceReference? source, string message) {
        messages.add (new SourceMessage (source, message, DiagnosticSeverity.Warning));
        ++warnings;
    }
}
