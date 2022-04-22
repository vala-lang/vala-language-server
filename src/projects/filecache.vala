/* filecache.vala
 *
 * Copyright 2022 Princeton Ferro <princetonferro@gmail.com>
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

/**
 * In-memory file metadata cache. Used to check whether files remain the same
 * after context updates.
 */
class Vls.FileCache : Object {
    /**
     * File metadata.
     */
    public class ContentStatus {
        /**
         * The time this information was last updated. This may be earlier than
         * the time the file was last updated if the file is the same after an
         * update.
         */
        public DateTime last_updated { get; set; }

        /**
         * The time this file was last updated. Can be null if we're unable to
         * query this info from the file system.
         */
        public DateTime? file_last_updated { get; set; }

        /**
         * The size of the file.
         */
        public size_t size { get; set; }

        /**
         * The checksum of the file.
         */
        public string checksum { get; set; }

        /**
         * Create a new content status.
         *
         * @param data                  data loaded from a file
         * @param last_modified         the last time the file was modified
         */
        public ContentStatus (Bytes data, DateTime? last_modified) {
            this.last_updated = new DateTime.now ();
            this.file_last_updated = last_modified;
            this.size = data.get_size ();
            // MD5 is fastest and we don't have any security issues even if there are collisions
            this.checksum = Checksum.compute_for_bytes (ChecksumType.MD5, data);
        }
        
        /**
         * Create a new content status for an empty/non-existent file.
         */
        public ContentStatus.empty () {
            this.last_updated = new DateTime.now ();
            this.file_last_updated = null;
            this.size = 0;
            this.checksum = Checksum.compute_for_data (ChecksumType.MD5, {});
        }
    }

    private HashMap<File, ContentStatus> _content_cache;

    public FileCache () {
        _content_cache = new HashMap<File, ContentStatus> (Util.file_hash, Util.file_equal);
    }

    /**
     * Updates the file in the cache. Will perform I/O, but will check the file
     * modification time first. If the file does not exist, its metadata will
     * be created in an empty configuration.
     *
     * @param file              the file to add or update in the cache
     * @param cancellable       (optional) a way to cancel the I/O operation
     */
    public void update (File file, Cancellable? cancellable = null) throws Error {
        ContentStatus? status = _content_cache[file];
        DateTime? last_modified = null;
        bool file_exists = false;
        try {
            FileInfo info = file.query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE, cancellable);
#if GLIB_2_62
            last_modified = info.get_modification_date_time ();
#else
            TimeVal time_last_modified = info.get_modification_time ();
            last_modified = new DateTime.from_iso8601 (time_last_modified.to_iso8601 (), null);
#endif
            file_exists = true;
        } catch (IOError.NOT_FOUND e) {
            // we only want to catch file-not-found errors. if there was some other error 
            // with querying the file system, we want to exit this function
        }

        if (file_exists && last_modified == null)
            warning ("could not get last modified time of %s", file.get_uri ());

        if (status == null) {
            // the file is being entered into the cache for the first time
            if (file_exists)
                _content_cache[file] = new ContentStatus (file.load_bytes (cancellable), last_modified);
            else
                _content_cache[file] = new ContentStatus.empty ();
            return;
        }

        // the file is in the cache already.
        // check modification time to avoid having to recompute the hash
        if (last_modified != null && status.file_last_updated != null && last_modified.compare (status.file_last_updated) <= 0)
            return;

        // recompute the hash
        ContentStatus new_status;
        if (file_exists)
            new_status = new ContentStatus (file.load_bytes (cancellable), last_modified);
        else
            new_status = new ContentStatus.empty ();
        if (new_status.checksum == status.checksum && new_status.size == status.size)
            return;

        _content_cache[file] = new_status;
        return;
    }

    /**
     * Gets the content status of the file if it's in the cache.
     */
    public new ContentStatus? get (File file) {
        return _content_cache[file];
    }
}
