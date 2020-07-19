using LanguageServer;
using Gee;

/*
 * Since we can have many of these, we want to keep this lightweight
 * by not extending GObject.
 */
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
    public bool fatal_warnings { get; private set; }
    public GenericArray<SourceMessage> messages = new GenericArray<SourceMessage> ();
    private HashMap<string, HashMap<string, uint>> messages_by_srcref = new HashMap<string, HashMap<string, uint>> ();

    public Reporter (bool fatal_warnings = false) {
        this.fatal_warnings = fatal_warnings;
    }

    public void add_message (Vala.SourceReference? source, string message, DiagnosticSeverity severity) {
        // mitigate potential infinite loop bugs in Vala parser
        HashMap<string, uint>? messages_count = null;
        if ((messages_count = messages_by_srcref[source.to_string ()]) == null) {
            messages_count = new HashMap<string, uint> ();
            messages_by_srcref[source.to_string ()] = messages_count;
        }
        if (!messages_count.has_key (message))
            messages_count[message] = 0;
        messages_count[message] = messages_count[message] + 1;

        if (source != null && messages_count[message] >= 100) {
            GLib.error ("parser infinite loop detected! (seen \"%s\" @ %s at least %u times)\n"
                        + "note: please report this bug with the source code that causes this error at https://gitlab.gnome.org/GNOME/vala",
                         message, source.to_string (), messages_count[message]);
        }
        messages.add (new SourceMessage (source, message, severity));
    }

    public override void depr (Vala.SourceReference? source, string message) {
        if (fatal_warnings)
            err (source, message);
        else {
            add_message (source, message, DiagnosticSeverity.Warning);
            ++warnings;
        }
    }
    public override void err (Vala.SourceReference? source, string message) {
        if (source == null) { // non-source compiler error
            stderr.printf ("Error: %s\n", message);
        } else {
            add_message (source, message, DiagnosticSeverity.Error);
            ++errors;
        }
    }
    public override void note (Vala.SourceReference? source, string message) {
        if (fatal_warnings)
            err (source, message);
        else {
            add_message (source, message, DiagnosticSeverity.Information);
            ++warnings;
        }
    }
    public override void warn (Vala.SourceReference? source, string message) {
        if (fatal_warnings)
            err (source, message);
        else {
            add_message (source, message, DiagnosticSeverity.Warning);
            ++warnings;
        }
    }
}
