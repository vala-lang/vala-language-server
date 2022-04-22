/* scheduler.vala
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
 * A work scheduler.
 */
class Vls.Scheduler {
    /**
     * A function to perform work in a task.
     */
    public delegate T Func<T> () throws Error;

    ThreadPool<Worker.Task> _thread_pool;
    ConcurrentList<Worker.Task> _wait_list;
    
    public Scheduler () throws ThreadError {
        _thread_pool = new ThreadPool<Worker.Task>.with_owned_data (
            execute,
            (int) get_num_processors (),
            false
        );
        _wait_list = new ConcurrentList<Worker.Task> ();
    }

    private void execute (owned Worker.Task task) {
        task.run ();
    }
    
    /**
     * Schedules a task for execution on one of the available threads.
     * If the task has dependencies, it will be placed on a wait list
     * and may be scheduled at the next call to {@link process_waitlist}.
     *
     * This may be called from any thread, but it's best to allow it to be
     * called by {@link Worker} on the main thread.
     */
    public void schedule_task (Worker.Task task) throws ThreadError {
        if (task.can_schedule ()) {
            debug ("scheduling %s task", task.writes ? "writer" : "reader");
            _thread_pool.add (task);
        } else {
            debug ("placing %s task on wait list", task.writes ? "writer" : "reader");
            _wait_list.add (task);
        }
    }

    /**
     * Goes over every item in the wait list and attempts to schedule it. This
     * should be called periodically from the main loop, but it may be called
     * from any thread.
     */
    public void process_waitlist () throws ThreadError {
        var waitlist_it = _wait_list.iterator ();
        while (waitlist_it.next ()) {
            Worker.Task task = waitlist_it.get ();
            if (task.can_schedule ()) {
                debug ("scheduling %s task from wait list", task.writes ? "writer" : "reader");
                waitlist_it.remove ();
                _thread_pool.add (task);
            }
        }
    }
}
