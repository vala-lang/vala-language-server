/* reporter.vala
 *
 * Copyright 2017-2018 Ben Iofel <ben@iofel.me>
 * Copyright 2020 Princeton Ferro <princetonferro@gmail.com>
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

using Lsp;
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
    public ConcurrentList<SourceMessage> messages = new ConcurrentList<SourceMessage> ();
    private ConcurrentList<Vala.SourceReference?> cache = new ConcurrentList<Vala.SourceReference?> (compare_sourcerefs);
    private int consecutive_cache_hits = 0;

    public Reporter (bool fatal_warnings = false) {
        this.fatal_warnings = fatal_warnings;
    }

    static bool compare_sourcerefs (Vala.SourceReference? src1, Vala.SourceReference? src2) {
        if (src1 == src2)
            return true;
        if (src1 != null && src2 != null) {
            return src1.begin.line == src2.begin.line && src1.begin.column == src2.begin.column
                && src1.end.line == src2.end.line && src2.end.column == src2.end.column;
        }
        return false;
    }

    public void add_message (Vala.SourceReference? source, string message, DiagnosticSeverity severity) {
        // mitigate potential infinite loop bugs in Vala parser
        if (source in cache)
            AtomicInt.inc (ref consecutive_cache_hits);
        else {
            AtomicInt.set (ref consecutive_cache_hits, 0);
            if (cache.size > 20)
                cache.remove_at (0);
            cache.add (source);
        }

        if (source != null && consecutive_cache_hits >= 100) {
            GLib.error ("parser infinite loop detected! (seen \"%s\" @ %s at least %u times in a row)\n"
                        + "note: please report this bug with the source code that causes this error at https://gitlab.gnome.org/GNOME/vala", 
                         message, source.to_string (), consecutive_cache_hits);
        }
        messages.add (new SourceMessage (source, message, severity));
    }

    public override void depr (Vala.SourceReference? source, string message) {
        if (fatal_warnings)
            err (source, message);
        else {
            add_message (source, message, DiagnosticSeverity.Warning);
            AtomicInt.inc (ref warnings);
        }
    }
    public override void err (Vala.SourceReference? source, string message) {
        if (source == null) { // non-source compiler error
            stderr.printf ("Error: %s\n", message);
        } else {
            add_message (source, message, DiagnosticSeverity.Error);
            AtomicInt.inc (ref errors);
        }
    }
    public override void note (Vala.SourceReference? source, string message) {
        if (fatal_warnings)
            err (source, message);
        else {
            add_message (source, message, DiagnosticSeverity.Information);
            AtomicInt.inc (ref warnings);
        }
    }
    public override void warn (Vala.SourceReference? source, string message) {
        if (fatal_warnings)
            err (source, message);
        else {
            add_message (source, message, DiagnosticSeverity.Warning);
            AtomicInt.inc (ref warnings);
        }
    }
}
