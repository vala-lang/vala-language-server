/* textdocument.vala
 *
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

using Vala;

class Vls.TextDocument : SourceFile {
    /**
     * This must be manually updated by anything that changes the content
     * of this document.
     */
    public DateTime last_updated { get; set; default = new DateTime.now (); }
    public int version { get; set; }

    /**
     * Used along with {@link last_saved_content} for checkpoint and restore.
     */
    public int last_saved_version { get; private set; }
    private string? _last_saved_content = null;
    public string last_saved_content {
        get {
            if (_last_saved_content == null)
                return this.content;
            return _last_saved_content;
        }
        set {
            _last_saved_content = value;
            last_saved_version = version;
        }
    }

    private string? _last_compiled_content = null;

    /**
     * The contents at the last time the code context was compiled, that is,
     * before any intermediate modifications.
     */
    public string last_compiled_content {
        get {
            if (_last_compiled_content == null)
                return this.content;
            return _last_compiled_content;
        }
        set {
            _last_compiled_content = value;
        }
    }

    public TextDocument (CodeContext context, File file, string? content = null, bool cmdline = false) throws FileError {
        string? cont = content;
        string uri = file.get_uri ();
        string? path = file.get_path ();
        path = path != null ? Util.realpath (path) : null;
        if (path != null && cont == null)
            FileUtils.get_contents (path, out cont);
        else if (path == null && cont == null)
            throw new FileError.NOENT (@"file $uri does not exist either on the system or in memory");
        SourceFileType ftype;
        if (uri.has_suffix (".vapi") || uri.has_suffix (".gir"))
            ftype = SourceFileType.PACKAGE;
        else if (uri.has_suffix (".vala") || uri.has_suffix (".gs"))
            ftype = SourceFileType.SOURCE;
        else {
            ftype = SourceFileType.NONE;
            warning ("TextDocument: file %s is neither a package nor a source file", uri);
        }
        // prefer paths to URIs, unless we don't have a path
        // (this happens when we have just opened a new file in some editors)
        base (context, ftype, path ?? uri, cont, cmdline);
    }

    public TextDocument.clone (CodeContext context, TextDocument document) {
        base (context, document.file_type, document.filename, document.content, document.from_commandline);
        this.last_updated = document.last_updated;
        this.version = document.version;
        this.last_saved_version = document.last_saved_version;
        this._last_saved_content = document._last_saved_content;
        this._last_compiled_content = document._last_compiled_content;
    }
}
