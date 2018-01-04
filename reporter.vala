class Vls.SourceError {
    public Vala.SourceReference? loc;
    public string message;

    public SourceError (Vala.SourceReference? loc, string message) {
        this.loc = loc;
        this.message = message;
    }
}

class Vls.Reporter : Vala.Report {
    public GenericArray<SourceError> errorlist = new GenericArray<SourceError> ();
    public GenericArray<SourceError> warnlist = new GenericArray<SourceError> ();

    public override void depr (Vala.SourceReference? source, string message) {
        warnlist.add (new SourceError (source, message));
        ++warnings;
    }
    public override void err (Vala.SourceReference? source, string message) {
        if (source == null) { // non-source compiler error
            stderr.printf ("Error: %s\n", message);
        } else {
            errorlist.add (new SourceError (source, message));
            ++errors;
        }
    }
    public override void note (Vala.SourceReference? source, string message) {
        warnlist.add (new SourceError (source, message));
        ++warnings;
    }
    public override void warn (Vala.SourceReference? source, string message) {
        warnlist.add (new SourceError (source, message));
        ++warnings;
    }
}
