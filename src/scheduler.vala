/**
 * A task scheduler
 */
namespace Vls.Scheduler {
    public delegate T TaskFunc<T> () throws Error;

    class Worker<T> {
        private TaskFunc<T> func;
        public SourceFunc callback;
        public Cancellable? cancellable;
        public T? result;
        public Error? error;

        public Worker (owned TaskFunc<T> func, owned SourceFunc callback, Cancellable? cancellable = null) {
            this.func = (owned) func;
            this.callback = (owned) callback;
            this.cancellable = cancellable;
        }

        public void run () {
            try {
                this.cancellable.set_error_if_cancelled ();
                this.result = func ();
            } catch (Error e) {
                this.error = e;
            }

            Idle.add ((owned) this.callback);
        }
    }

    private ThreadPool<Worker>? thread_pool;

    /**
     * Schedules a new task to be run on a separate thread.
     */
    public async T run_async<T> (owned TaskFunc<T> func, Cancellable? cancellable = null) throws Error {
        if (thread_pool == null) {  // TODO: use GLib.Once<T>
            thread_pool = new ThreadPool<Worker>.with_owned_data (
                worker => worker.run (),
                (int) get_num_processors (),
                false
            );
        }
        
        SourceFunc callback = run_async.callback;
        var worker = new Worker<T> ((owned) func, (owned) callback, cancellable);
        thread_pool.add (worker);

        // suspend function and come back to it when the callback is invoked (when
        // the work is finished)
        yield;

        if (worker.error != null)
            throw worker.error;

        return worker.result;
    }
}
