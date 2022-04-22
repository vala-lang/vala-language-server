/* servertypes.vala
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

/**
 * Represents a cancellable request from the client to the server.
 */
class Vls.Request : Cancellable {
    private int64? int_value;
    private string? string_value;
    private string? method;

    /**
     * Creates a new cancellable request.
     *
     * @param id                the id of the JSON-RPC request
     * @param cancellable       a cancellable to chain
     * @param method            the method called by JSON-RPC
     */
    public Request (Variant id, Cancellable? cancellable, string? method = null) {
        assert (id.is_of_type (VariantType.INT64) || id.is_of_type (VariantType.STRING));
        if (id.is_of_type (VariantType.INT64))
            int_value = (int64) id;
        else
            string_value = (string) id;
        this.method = method;
        cancellable.connect (on_cancellable_cancelled);
    }

    private void on_cancellable_cancelled () {
        this.cancel ();
    }

    public string to_string () {
        string id_string = int_value != null ? int_value.to_string () : string_value;
        return id_string + (method != null ? @":$method" : "");
    }

    public static uint variant_id_hash (Variant id) {
        if (id.is_of_type (VariantType.INT64))
            return GLib.int64_hash ((int64)id);
        else
            return GLib.str_hash ((string)id);
    }

    public static bool variant_id_equal (Variant id1, Variant id2) {
        if (id1.is_of_type (VariantType.INT64)) {
            return (int64)id1 == (int64)id2;
        } else {
            return (string)id1 == (string)id2;
        }
    }
}
