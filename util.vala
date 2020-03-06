namespace Vls {
    public static T? parse_variant<T> (Variant variant) {
        var json = Json.gvariant_serialize (variant);
        return Json.gobject_deserialize (typeof (T), json);
    }

    public static Variant object_to_variant (Object object) throws Error {
        var json = Json.gobject_serialize (object);
        return Json.gvariant_deserialize (json, null);
    }

    public static size_t get_string_pos (string str, uint lineno, uint charno) {
        int linepos = -1;

        for (uint lno = 0; lno < lineno; ++lno) {
            int pos = str.index_of_char ('\n', linepos + 1);
            if (pos == -1)
                break;
            linepos = pos;
        }

        return linepos + 1 + charno;
    }

    public static string? get_file_id (File file) {
        try {
            var finfo = file.query_info (FileAttribute.ID_FILE, FileQueryInfoFlags.NONE);
            return finfo.get_attribute_string (FileAttribute.ID_FILE);
        } catch (Error e) {
            warning ("could not get file ID of %s: %s", file.get_uri (), e.message);
            return null;
        }
    }
}
