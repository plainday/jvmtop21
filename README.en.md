> 한국어: [README.md](README.md)

# jvmtop21 — jvmtop ported to JDK 21

A port of [patric-r/jvmtop](https://github.com/patric-r/jvmtop) 0.8.0 to build and run on JDK 21.
The original project is discontinued and only works up to JDK 8. License and attribution follow the original (Apache 2.0, see [LICENSE](LICENSE)).

---

## Requirements

- **JDK 21** (not a JRE — must be a full JDK with `javac`)
- Attaching to a target JVM requires running as the **same OS user** as that JVM

---

## Build

```sh
JAVA_HOME=/path/to/jdk21
mvn package
```

Output: `target/jvmtop.jar`

---

## Running

Place `jvmtop.sh` and `jvmtop.jar` in the same directory, then run:

```sh
# Copy the launcher script next to the jar after building
cp src/main/wrappers/jvmtop.sh target/

# Run (JAVA_HOME must point to JDK 21)
JAVA_HOME=/path/to/jdk21 target/jvmtop.sh                   # overview: list running JVMs
JAVA_HOME=/path/to/jdk21 target/jvmtop.sh <pid>            # detail: per-thread CPU, etc.
JAVA_HOME=/path/to/jdk21 target/jvmtop.sh --profile <pid>  # CPU profiler mode
```

The only verified launcher is **`jvmtop.sh` (Linux)**.  
`jvmtop.bat` is not provided by this project — Windows is untested.

---

## Key changes from the original

| Change | Reason |
|--------|--------|
| Removed `tools.jar` dependency → `public com.sun.tools.attach.VirtualMachine` + JMX path | `tools.jar` was removed in JDK 9+; replaced with the public API now part of the `jdk.attach` module |
| Removed `sun.jvmstat`-based VM enumeration → `VirtualMachine.list()` | `sun.jvmstat` is a private internal; `VirtualMachine.list()` (public) provides an equivalent list |
| Removed attach from list-building phase (lazy-attach) — actual attach is deferred to the first metric fetch | Slow VMs caused multi-second stalls during list construction. Deferring attach lets the overview list appear immediately |
| Removed `getProcessCpuTime()` reflection → direct use of `com.sun.management.OperatingSystemMXBean` | In JDK 21, `ManagementFactory.newPlatformMXBeanProxy()` gives direct access to the public API |
| Added `-Djdk.attach.allowAttachSelf=true` to `jvmtop.sh` (included by default) | JDK 21 changed the default for self-attach to `false` |
| Set attach timeout to 3 s in `jvmtop.sh` (`-Dsun.tools.attach.attachTimeout=3000`) | Even with lazy-attach, each individual attach can take up to 10 s (default). Capping at 3 s further reduces how long a slow VM can delay the overview refresh |

---

## Known behavior / limitations

- **JDK 21 targets only.** This port builds and runs on JDK 21 and attaches to processes running on JDK 21. Cross-version attach (targeting a different JDK version) is out of scope.

- **Attach can fail under certain conditions:** If the target JVM is unresponsive due to a long stop-the-world GC pause or a hang, it may not reply to the attach request and the attach will fail. This is not specific to jvmtop — it is a general behavior of the HotSpot attach mechanism. If `jstack` / `jcmd` also fail against the same PID, the issue is with the target JVM itself.

- **Verified environments:** Ubuntu (development) and RHEL 8/9 (production). **Windows is untested.**

---

## License

Follows the license of the original [patric-r/jvmtop](https://github.com/patric-r/jvmtop) (Apache 2.0). See [LICENSE](LICENSE).
