/**
 * Phase 0 victim: JVM to attach to during testing.
 * Produces a clearly-named high-CPU thread and a clearly-named idle thread
 * so jvmtop output can be verified structurally.
 */
public class CpuBurner {
    public static void main(String[] args) throws Exception {
        Thread burner = new Thread(() -> {
            double x = 0;
            while (true) { x += Math.sqrt(Math.random()); }
        }, "CPU-BURNER");
        burner.setDaemon(false);
        burner.start();
        // idle thread for contrast
        Thread.currentThread().setName("IDLE-MAIN");
        while (true) Thread.sleep(60_000);
    }
}
