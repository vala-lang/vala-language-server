namespace Vls {
    public static T? parse_variant<T> (Variant variant) {
        var json = Json.gvariant_serialize (variant);
        return Json.gobject_deserialize (typeof (T), json);
    }

    public static Variant object_to_variant (Object object) throws Error {
        var json = Json.gobject_serialize (object);
        return Json.gvariant_deserialize (json, null);
    }

    /**
     * Gets the offset, in bytes, of the UTF-8 character at the given line and
     * position.
     * Both lineno and charno must be zero-indexed.
     */
    public static size_t get_string_pos (string str, uint lineno, uint charno) {
        int linepos = -1;

        for (uint lno = 0; lno < lineno; ++lno) {
            int pos = str.index_of_char ('\n', linepos + 1);
            if (pos == -1)
                break;
            linepos = pos;
        }

        string remaining_str = str.substring (linepos + 1);

        return linepos + 1 + remaining_str.index_of_nth_char (charno);
    }
}
