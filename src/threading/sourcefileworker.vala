/* sourcefileworker.vala
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
using Lsp;

/**
 * A worker attached to a source file.
 */
class Vls.SourceFileWorker : Worker {
    /**
     * The status of the source file.
     */
    public enum Status {
        NOT_PARSED         = 0,
        PARSED             = 1,
        SYMBOLS_RESOLVED   = 2,
        SEMANTICS_ANALYZED = 3,
        /**
         * flow analyzer + used analyzer + all other custom analyses
         */
        COMPLETE           = 4
    }

    /**
     * The source file this worker holds.
     */
    public Vala.SourceFile source_file { get; private set; }

    public SourceFileWorker (Vala.SourceFile source_file) {
        this.source_file = source_file;
        this.name = @"File($(source_file.filename))";
    }

    /**
     * Updates the status atomically.
     */
    public void update (Status new_status) {
        update_status (new_status);
    }

    /**
     * Schedules the function to be run in the earliest possible state, before
     * parsing.
     *
     * @param writes            whether the function modifies the source file or its
     *                          AST, or updates the worker status
     * @param next_status       the next greater status to set after this task is finished
     */
    public async T run_early<T> (owned Scheduler.Func<T> func, bool writes,
                                 Status next_status = Status.NOT_PARSED) throws Error {
        assert (next_status >= Status.NOT_PARSED);
        SourceFunc callback = run_early<T>.callback;
        var task = new Task<T> (this, writes, (owned)func, Status.NOT_PARSED, next_status, (owned)callback);
        work_list.push (task);

        yield;

        if (task.error != null)
            throw task.error;
        return task.result;
    }

    /**
     * Schedules the function to be run after the file is parsed.
     *
     * @param writes            whether the function modifies the source file or its
     *                          AST, or updates the worker status
     * @param next_status       the next greater status to set after this task is finished
     */
    public async T run_parsed<T> (owned Scheduler.Func<T> func, bool writes,
                                  Status next_status = Status.PARSED) throws Error {
        assert (next_status >= Status.PARSED);
        SourceFunc callback = run_parsed<T>.callback;
        var task = new Task<T> (this, writes, (owned)func, Status.PARSED, next_status, (owned)callback);
        work_list.push (task);

        yield;

        if (task.error != null)
            throw task.error;
        return task.result;
    }


    /**
     * Schedules the function to be run after the source file worker is in the
     * {@link Status.SYMBOLS_RESOLVED} state.
     *
     * @param writes            whether the function modifies the source file or its
     *                          AST, or updates the worker status
     * @param next_status       the next greater status to set after this task is finished
     */
    public async T run_symbols_resolved<T> (owned Scheduler.Func<T> func, bool writes,
                                            Status next_status = Status.SYMBOLS_RESOLVED) throws Error {
        assert (next_status >= Status.SYMBOLS_RESOLVED);
        SourceFunc callback = run_symbols_resolved<T>.callback;
        var task = new Task<T> (this, writes, (owned)func, Status.SYMBOLS_RESOLVED, next_status, (owned)callback);
        work_list.push (task);

        yield;

        if (task.error != null)
            throw task.error;
        return task.result;
    }

    /**
     * Schedules the function to be run after the source file worker is in the
     * {@link Status.SEMANTICS_ANALYZED} state.
     *
     * @param writes            whether the function modifies the source file or its
     *                          AST, or updates the worker status
     * @param next_status       the next greater status to set after this task is finished
     */
    public async T run_semantics_analyzed<T> (owned Scheduler.Func<T> func, bool writes,
                                              Status next_status = Status.SEMANTICS_ANALYZED) throws Error {
        assert (next_status >= Status.SEMANTICS_ANALYZED);
        SourceFunc callback = run_semantics_analyzed<T>.callback;
        var task = new Task<T> (this, writes, (owned)func, Status.SEMANTICS_ANALYZED, next_status, (owned)callback);
        work_list.push (task);

        yield;

        if (task.error != null)
            throw task.error;
        return task.result;
    }

    /**
     * Schedules the function to be run after the source file worker is in the
     * {@link Status.COMPLETE} state, that is, after all analyses have been run
     * on the file.
     *
     * @param writes    whether the function modifies the source file or its
     *                  AST, or updates the worker status
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
