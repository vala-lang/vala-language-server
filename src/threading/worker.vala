/* worker.vala
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
 * Coordinates work on a shared resource.
 */
abstract class Vls.Worker : Object {
    /**
     * All tasks that are either currently running or will be soon.
     * This is a bit field with [num readers ... | 0 or 1 for writer | 4 bits for status]
     */
    int flags;

    /**
     * List of work to schedule.
     */
    protected AsyncQueue<Task> work_list = new AsyncQueue<Task> ();

    protected string name;

    static inline int flags_get_readers (int flags) {
        return flags >> 5;
    }

    static inline int flags_get_writer (int flags) {
        return (flags >> 4) & 1;
    }

    static inline int flags_get_status (int flags) {
        return flags & 0xf;
    }

    static inline int flags_create (int readers, int writer, int status) {
        return (readers << 5) | ((writer & 1) << 4) | (status & 0xf);
    }

    /**
     * Update the status atomically.
     */
    protected void update_status (int new_status) {
        int status = 0;
        int readers = 0;
        int writer = 0;
        do {
            int flags = AtomicInt.get (ref this.flags);
            status = flags_get_status (flags);
            readers = flags_get_readers (flags);
            writer = flags_get_writer (flags);
        } while (!AtomicInt.compare_and_exchange (ref this.flags,
                                                  flags_create (readers, writer, status),
                                                  flags_create (readers, writer, new_status)));
    }

    /**
     * A task to perform on any thread, handled by a particular worker. The
     * task manipulates the internal state of the worker and that's why it
     * appears here.
     */
    public class Task<T> {
        Worker worker;
        public bool writes;
        Scheduler.Func<T> func;
        int min_status;
        int next_status;
        SourceFunc? callback;
        public T? result;
        public Error? error;
        
        /**
         * Creates a new task.
         *
         * @param worker        the worker for a shared resource (ex: source file, project)
         * @param func          the computation to run
         * @param writes        whether the task modifies the resource held by the worker
         *                      (ex: source file, project) or the worker itself
         * @param min_status    minimum status of the worker in order to schedule this task
         * @param next_status   the next status minimum after this task is done
         * @param callback      the callback to invoke when done
         */
        public Task (Worker worker, bool writes, owned Scheduler.Func<T> func, int min_status, int next_status, owned SourceFunc? callback) {
            this.worker = worker;
            this.writes = writes;
            this.func = (owned)func;
            this.min_status = min_status;
            this.next_status = next_status;
            this.callback = (owned)callback;
        }

        /**
         * Checks whether this task is blocked until other tasks complete.
         */
        public bool can_schedule () {
            if (writes) {
                int flags = AtomicInt.get (ref worker.flags);
                int status = flags_get_status (flags);
                if (status >= min_status)
                    return AtomicInt.compare_and_exchange (ref worker.flags,
                                                           flags_create (0, 0, status),
                                                           flags_create (0, 1, status));
            } else {
                int flags = AtomicInt.get (ref worker.flags);
                int readers = flags_get_readers (flags);
                int status = flags_get_status (flags);
                if (status >= min_status)
                    return AtomicInt.compare_and_exchange (ref worker.flags,
                                                           flags_create (readers, 0, status),
                                                           flags_create (readers + 1, 0, status));
            }
            return false;
        }
        
        /**
         * Runs the computation in the current thread and schedules the callback on
         * the main loop after. This is usually called by the scheduler.
         */
        public void run () {
            try {
                result = func ();
            } catch (Error e) {
                error = e;
            }

            if (writes) {
                debug ("writer task is done - %s", worker.name);
                int status = 0;
                do {
                    int flags = AtomicInt.get (ref worker.flags);
                    status = flags_get_status (flags);
                } while (!AtomicInt.compare_and_exchange (ref worker.flags,
                                                          flags_create (0, 1, status),
                                                          flags_create (0, 0, int.max(status, next_status))));
            } else {
                debug ("reader task is done - %s", worker.name);
                int readers = 0, status = 0;
                do {
                    int flags = AtomicInt.get (ref worker.flags);
                    readers = flags_get_readers (flags);
                    status = flags_get_status (flags);
                } while (!AtomicInt.compare_and_exchange (ref worker.flags,
                                                          flags_create (readers, 0, status),
                                                          flags_create (readers - 1, 0, int.max(status, next_status))));
            }

            if (callback != null)
                Idle.add ((owned)callback);
        }
    }

    /**
     * Acquire this worker for writing to the shared resource.
     */
    public void acquire (Cancellable? cancellable) throws Error {
        int status = 0;
        uint trip_count = 0;
        do {
            if (trip_count++ > 0) {
                debug ("attempting to acquire worker, try #%u", trip_count);
                cancellable.set_error_if_cancelled ();
                Thread.usleep (50000);
            }
            int flags = AtomicInt.get (ref this.flags);
            status = flags_get_status (flags);
        } while (!AtomicInt.compare_and_exchange (ref this.flags,
                                                  flags_create (0, 0, status),
                                                  flags_create (0, 1, status)));
        debug ("acquired worker %s", name);
    }

    /**
     * Release this worker for writing to the shared resource.
     */
    public void release (Cancellable? cancellable) throws Error {
        int status = 0;
        int readers = 0;
        int writer = 0;
        uint trip_count = 0;
        do {
            if (trip_count++ > 0) {
                debug ("attempting to release worker, try #%u", trip_count);
                cancellable.set_error_if_cancelled ();
                Thread.usleep (50000);
            }
            int flags = AtomicInt.get (ref this.flags);
            readers = flags_get_readers (flags);
            writer = flags_get_writer (flags);
            status = flags_get_status (flags);
            if (readers + writer == 0)
                error ("worker %s has already been released!", name);
        } while (!AtomicInt.compare_and_exchange (ref this.flags,
                                                  flags_create (0, 1, status),
                                                  flags_create (0, 0, status)));
        debug ("released worker %s", name);
    }

    /**
     * Schedules the function to be run when the resource is ready.
     *
     * @param writes    whether the function modifies the resource
     *
     * @throws GLib.Error the error thrown by the function, or an error when scheduling the task
     */
    public abstract async T run<T> (owned Scheduler.Func<T> func, bool writes) throws Error;

    /**
     * Queues ready tasks with the scheduler.
     */
    public void enqueue_tasks (Scheduler scheduler) throws ThreadError {
        work_list.lock ();
        while (work_list.length_unlocked () > 0)
            scheduler.schedule_task (work_list.pop_unlocked ());
        work_list.unlock ();
    }
}
