/**
 * Represents a cancellable request from the client to the server.
 */
class Vls.Request : Object {
    private int64? int_value;
    private string? string_value;
    private string? method;

    public Request (Variant id, string? method = null) {
        assert (id.is_of_type (VariantType.INT64) || id.is_of_type (VariantType.STRING));
        if (id.is_of_type (VariantType.INT64))
            int_value = (int64) id;
        else
            string_value = (string) id;
        this.method = method;
    }

    public string to_string () {
        string id_string = int_value != null ? int_value.to_string () : string_value;
        return id_string + (method != null ? @":$method" : "");
    }

    public static uint hash (Request req) {
        if (req.int_value != null)
            return GLib.int64_hash (req.int_value);
        else
            return GLib.str_hash (req.string_value);
    }

    public static bool equal (Request reqA, Request reqB) {
        if (reqA.int_value != null) {
            assert (reqB.int_value != null);
            return reqA.int_value == reqB.int_value;
        } else {
            assert (reqB.string_value != null);
            return reqA.string_value == reqB.string_value;
        }
    }
}
