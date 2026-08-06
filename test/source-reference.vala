/* source-reference.vala
 *
 * Copyright 2026 Princeton Ferro <princetonferro@gmail.com>
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

using Gee;
using Lsp;

private Vala.SourceReference make_source_ref (
    Vala.SourceFile file,
    int begin_line,
    int begin_column,
    int end_line,
    int end_column
) {
    return new Vala.SourceReference (
        file,
        Vala.SourceLocation (null, begin_line, begin_column),
        Vala.SourceLocation (null, end_line, end_column));
}

private void test_source_ref_map_keys () {
    var context = new Vala.CodeContext ();
    var first_file = new Vala.SourceFile (
        context, Vala.SourceFileType.SOURCE, "/workspace/first.vala");
    var equivalent_file = new Vala.SourceFile (
        context, Vala.SourceFileType.SOURCE, "/workspace/first.vala");
    var second_file = new Vala.SourceFile (
        context, Vala.SourceFileType.SOURCE, "/workspace/second.vala");
    var original = make_source_ref (first_file, 2, 3, 2, 8);
    var equivalent = make_source_ref (equivalent_file, 2, 3, 2, 8);
    var other_file = make_source_ref (second_file, 2, 3, 2, 8);
    var references = new HashMap<Vala.SourceReference, string> (
        Vls.Util.source_ref_hash,
        Vls.Util.source_ref_equal);

    references[original] = "original";
    references[equivalent] = "equivalent";
    assert (references.size == 1);
    assert (references[original] == "equivalent");

    // Equal coordinates in different files identify different references.
    references[other_file] = "other file";
    assert (references.size == 2);
}

private void test_range_conversion () {
    var context = new Vala.CodeContext ();
    var file = new Vala.SourceFile (
        context, Vala.SourceFileType.SOURCE, "/workspace/main.vala");
    var range = Range (Position (2, 3), Position (4, 5));
    var source_ref = Vls.Util.sourceref_from_range (file, range);

    assert (Vls.Util.range_equal (
        Vls.Util.range_from_sourceref (source_ref),
        range));
}

private int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/util/source-reference/map-keys", test_source_ref_map_keys);
    Test.add_func ("/util/source-reference/range-conversion", test_range_conversion);
    return Test.run ();
}
