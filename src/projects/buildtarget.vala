/* buildtarget.vala
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

using Gee;

abstract class Vls.BuildTarget : Object, Hashable<BuildTarget> {
    public string output_dir { get; construct; }
    public string name { get; construct; }
    public string id { get; construct; }
    public int no { get; construct set; }

    /**
     * Input to the build target
     */
    public ArrayList<File> input { get; private set; default = new ArrayList<File> (Util.file_equal); }

    /**
     * Output of the build target
     */
    public ArrayList<File> output { get; private set; default = new ArrayList<File> (Util.file_equal); }

    public HashMap<File, BuildTarget> dependencies { get; private set; default = new HashMap<File, BuildTarget> (Util.file_hash, Util.file_equal); }

    /**
     * The time this target was last updated. Defaults to the start of the Unix epoch.
     */
    public DateTime last_updated { get; protected set; default = new DateTime.from_unix_utc (0); }

    protected BuildTarget (string output_dir, string name, string id, int no) {
        Object (output_dir: output_dir, name: name, id: id, no: no);
        DirUtils.create_with_parents (output_dir, 0755);
    }

    /**
     * Build the target only if it needs to be built from its sources and if
     * its dependencies are newer than this target. This does not take care of 
     * building the target's dependencies.
     */
    public abstract async void rebuild_async (Cancellable? cancellable = null) throws Error;

    public bool equal_to (BuildTarget other) {
        return output_dir == other.output_dir && name == other.name && id == other.id;
    }

    public uint hash () {
        return @"$output_dir::$name::$id".hash ();
    }
}
