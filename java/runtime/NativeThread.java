
package jmercury.runtime;

/**
 * Native thread.
 *
 * A Native thread is created by Mercury to tasks created with
 * spawn_native/4.
 */
public class NativeThread extends MercuryThread
{
    private Runnable task;

    /**
     * Create a new native thread.
     * @param id The id for the new thread.
     * @param task The task to execute.
     */
    public NativeThread(int id, Runnable task) {
        super("Mercury Native Thread", id);
        this.task = task;
    }

    public void run() {
        task.run();
    }

    /**
     * no-op
     */
    public void blocked() {
        ;
    }

    /**
     * no-op
     */
    public void running() {
        ;
    }
}

