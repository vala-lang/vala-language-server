class Vls.Report : Vala.Report {
    public override void depr (Vala.SourceReference? source, string message) {
        ++warnings;
    }
    public override void note (Vala.SourceReference? source, string message) {
        ++warnings;
    }
    public override void warn (Vala.SourceReference? source, string message) {
        ++warnings;
    }
    public override void err (Vala.SourceReference? source, string message) {
        ++errors;
    }
}
