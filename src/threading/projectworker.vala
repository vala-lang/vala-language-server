/* projectworker.vala
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
 * A worker attached to a project.
 */
class Vls.ProjectWorker : Worker {
    /**
     * The status of the project.
     */
    public enum Status {
        /**
         * Not configured for the first time or is currently reconfiguring.
         */
        NOT_CONFIGURED = 0,

        /**
         * Reconfigured but not yet built.
         */
        CONFIGURED     = 1,

        /**
         * Reconfigured and built.
         */
        COMPLETE       = 2
    }

    public ProjectWorker (string root_path) {
        this.name = @"Project($root_path)";
    }

    /**
     * Updates the status atomically.
     */
    public void update (Status new_status) {
        update_status (new_status);
    }

    /**
     * Schedules the function to be run after the project worker is in the
     * {@link Status.NOT_CONFIGURED} status.
     *
     * @param writes            whether the function modifies the project or updates
     *                          the worker status
     * @param next_status       the next greater status to set after this task is finished
     */
    public async T run_not_configured<T> (owned Scheduler.Func<T> func, bool writes,
                                          Status next_status = Status.NOT_CONFIGURED) throws Error {
        assert (next_status >= Status.NOT_CONFIGURED);
        SourceFunc callback = run_not_configured<T>.callback;
        var task = new Task<T> (this, writes, (owned)func, Status.NOT_CONFIGURED, next_status, (owned)callback);
        work_list.push (task);

        yield;

        if (task.error != null)
            throw task.error;
        return task.result;
    }

    /**
     * Schedules the function to be run after the project worker is in the
     * {@link Status.CONFIGURED} status, that is, after the project is
     * (re)configured.
     *
     * @param writes            whether the function modifies the project or updates
     *                          the worker status
     * @param next_status       the next greater status to set after this task is finished
     */
    public async T run_configured<T> (owned Scheduler.Func<T> func, bool writes,
                                      Status next_status = Status.CONFIGURED) throws Error {
        assert (next_status >= Status.CONFIGURED);
        SourceFunc callback = run_configured<T>.callback;
        var task = new Task<T> (this, writes, (owned)func, Status.CONFIGURED, next_status, (owned)callback);
        work_list.push (task);

        yield;

        if (task.error != null)
            throw task.error;
        return task.result;
    }

    /**
     * Schedules the function to be run after the project worker is in the
     * {@link Status.COMPLETE} state, that is, after the project is
     * (re)configured and (re)built.
     *
     * @param writes    whether the function modifies the project or updates
     *                  the worker status
     */
    public override async T run<T> (owned Scheduler.Func<T> func, bool writes) throws Error {
        SourceFunc callback = run<T>.callback;
        var task = new Task<T> (this, writes, (owned)func, Status.COMPLETE, Status.COMPLETE, (owned)callback);
        work_list.push (task);

        yield;

        if (task.error != null)
            throw task.error;
        return task.result;
    }
}
