/* server.vala
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

/**
 * Schedules work to be run on worker threads.
 */
namespace Vls {
    /**
     * A cancellable task that may throw an error.
     */
    delegate T TaskFunc<T> (Cancellable? cancellable = null) throws Error;

    class Scheduler : Object {
        ThreadPool<Worker> _thread_pool;

        /**
         * Creates a new scheduler for running tasks.
         */
        public Scheduler () throws ThreadError {
            _thread_pool = new ThreadPool<Worker>.with_owned_data (worker => worker.run (), (int) get_num_processors (), false);
        }

        /**
         * Schedules a task to be run on a worker thread. If the task throws an
         * error, it will be propagated to the caller.
         */
        public async T run<T> (owned TaskFunc<T> task, Cancellable? cancellable = null) throws Error {
            SourceFunc callback = run<T>.callback; // create a callback to ourselves

            var worker = new Worker<T> ((owned) task, (owned) callback, cancellable);
            _thread_pool.add (worker);

            // suspend ourselves and come back when the callback is invoked
            yield;

            if (worker.error != null)
                throw worker.error;

            return worker.result;
        }
    }

    /**
     * Works on the AST of a file and may produce a result.
     */
    class Worker<T> {
        public T? result { get; private set; }
        public Error? error { get; private set; }

        TaskFunc<T> _task;
        SourceFunc _callback;
        Cancellable? _cancellable;

        /**
         * @param task        the computation
         * @param callback    what is invoked after the computation is run
         * @param cancellable (optional) a way to cancel the task
         */
        public Worker (owned TaskFunc<T> task, owned SourceFunc callback, Cancellable? cancellable = null) {
            _task = task;
            _callback = callback;
            _cancellable = cancellable;
        }

        /**
         * Executes this task synchronously and schedules the callback on the
         * event loop when done or an error occurred.
         */
        public void run () {
            try {
                if (_cancellable != null)
                    _cancellable.set_error_if_cancelled ();
                result = _task (_cancellable);
            } catch (Error e) {
                error = e;
            }

            // schedule the callback on the main thread's event loop
            Idle.add ((owned) _callback);
        }
    }
}
