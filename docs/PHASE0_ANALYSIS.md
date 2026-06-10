# Phase 0 Analysis — jvmtop JDK 21 포팅 정찰

작성일: 2026-06-08  
환경: Ubuntu 22.04 (Linux 6.8.0-106, x86_64) / Cowork VM

---

## 1. 환경 확인 (Gating Checks)

### Check 0 — OS/아키텍처

```
uname -a
→ Linux claude 6.8.0-106-generic ... x86_64 x86_64 x86_64 GNU/Linux
```

✅ Ubuntu VM 확인. MINGW64 아님.

### Check 0b — JDK 아키텍처

```
file jdk/jdk8/bin/java
→ ELF 64-bit LSB pie executable, x86-64 ... dynamically linked

file jdk/jdk21/bin/java
→ ELF 64-bit LSB pie executable, x86-64 ... dynamically linked
```

✅ 두 JDK 모두 Linux x86_64 ELF. VM 아키텍처와 일치.

```
jdk/jdk8/bin/java -version
→ openjdk version "1.8.0_492" (Temurin)

jdk/jdk21/bin/java -version  (확인 필요 — Phase 1에서 명시)
```

### Check 1 — Attach 가능 여부 (Golden Reference 캡처)

JDK 8로 victim(CpuBurner)을 띄우고 원본 jvmtop 0.8.0으로 attach 확인.

**Overview 출력 (golden reference):**

```
 JvmTop 0.8.0 alpha - 01:11:24,  amd64,  2 cpus, Linux 6.8.0-106, load avg 0.47
 https://github.com/patric-r/jvmtop

  PID MAIN-CLASS      HPCUR HPMAX NHCUR NHMAX    CPU     GC    VM USERNAME   #T DL
   18 m.jvmtop.JvmTop    8m  871m   15m   n/a  2.00%  0.00% T8U49 admiring   16   
    3 CpuBurner         11m  871m   12m   n/a  0.00%  0.00% T8U49 admiring   10   
```

**Thread Detail 출력 (golden reference — n=3, d=5):**

```
 PID 3: CpuBurner
 VM: Temurin OpenJDK 64-Bit Server VM 1.8.0_492
 UP:  0: 0m  #THR: 10   #THRPEAK: 10   #THRCREATED: 10
 CPU:  0.00% GC:  0.00% HEAP:  12m / 871m NONHEAP:  12m /  n/a

    TID NAME                                    STATE      CPU    TOTALCPU BLOCKEDBY
      8 CPU-BURNER                           RUNNABLE  0.00%    97.56%
      1 IDLE-MAIN                       TIMED_WAITING  0.00%     0.30%
```

✅ Attach 성공. CPU-BURNER RUNNABLE + TOTALCPU ~97% 확인.

> **참고 — CPU% 0.00% 원인 분석:**  
> Cowork VM의 CPU throttle(~16% 실효율) 때문에 jvmtop의 짧은 측정 구간에서
> `getThreadCpuTime()` delta가 표시 해상도 이하로 나온다. `getThreadCpuTime()` 자체는
> 정상 동작하며 (`TestCpuTime.java`로 확인: delta=32ms/wall=200ms),
> TOTALCPU 컬럼(누적)은 정상 표시된다. 포팅 완료 후 더 긴 interval로 재확인할 것.

---

## 2. 소스 구조

### 2.1 빌드 도구 및 진입점

- 빌드: **Maven** (`pom.xml`), `jdk.version=1.6`, `source/target=1.6`
- 진입점: `com.jvmtop.JvmTop.main()`
- 주요 artifact: `target/jvmtop.jar` (shade 포함, `MANIFEST.MF`의 `Main-Class` 없음 — launcher에서 명시)

### 2.2 패키지 구조 (14개 파일)

```
com.jvmtop/
  JvmTop.java                    # CLI 진입점, iteration loop
  monitor/
    VMInfo.java                  # 단일 JVM 지표 모델 + attach 조율
    VMInfoState.java             # 상태 enum (ATTACHED, DETACHED, ERROR …)
  openjdk/tools/                 # ★ vendored JDK internals (핵심 문제)
    LocalVirtualMachine.java     # VM 열거 + management agent 로드
    ProxyClient.java             # JMX 프록시 + SnapshotMBeanServerConnection
    ConnectionState.java         # enum
    MemoryPoolStat.java          # (메모리풀 stat DTO — internal 의존 없음)
  view/
    ConsoleView.java             # interface
    AbstractConsoleView.java     # 공통 유틸 (toMB, toHHMM, sortByValue …)
    VMOverviewView.java          # 전체 JVM 목록 출력
    VMDetailView.java            # per-thread CPU 상세 출력
    VMProfileView.java           # CPU sampler 출력
  profiler/
    CPUSampler.java              # 스택 샘플링 기반 CPU 프로파일러
    MethodStats.java             # 메서드 통계 DTO
```

### 2.3 데이터 흐름 요약

```
JvmTop.main()
  └─ VMOverviewView / VMDetailView / VMProfileView
       └─ LocalVirtualMachine.getAllVirtualMachines()   ← VM 열거
            ├─ getMonitoredVMs()   ← sun.jvmstat (internal ★)
            └─ getAttachableVMs()  ← VirtualMachine.list() (public ✓)
       └─ VMInfo.processNewVM(localVm, pid)
            └─ ProxyClient.getProxyClient(lvm).connect()
                 └─ lvm.startManagementAgent()          ← management-agent.jar ★
                      → JMXServiceURL → JMXConnector → MBeanServerConnection
       └─ vmInfo.update()
            ├─ proxyClient.getSunOperatingSystemMXBean()  → reflection ★
            ├─ proxyClient.getThreadMXBean()              → public JMX ✓
            └─ proxyClient.getProcessCpuTime()            → reflection ★
```

---

## 3. Internal 의존 목록 (파일·라인 단위)

### 3.1 `LocalVirtualMachine.java` — `sun.jvmstat.*` (6 import)

| 라인 | 심볼 | 용도 |
|------|------|------|
| 41 | `sun.jvmstat.monitor.HostIdentifier` | 로컬 호스트 식별자 생성 |
| 42 | `sun.jvmstat.monitor.MonitorException` | 예외 타입 |
| 43 | `sun.jvmstat.monitor.MonitoredHost` | hsperfdata 기반 VM 목록 조회 |
| 44 | `sun.jvmstat.monitor.MonitoredVm` | 개별 VM 모니터링 |
| 45 | `sun.jvmstat.monitor.MonitoredVmUtil` | command line, attachable 여부 |
| 46 | `sun.jvmstat.monitor.VmIdentifier` | VM 식별 URI |

**사용 위치:** `getMonitoredVMs()` 메서드 전체 (L190~L241).  
**목적:** `/tmp/hsperfdata_*` perf 파일로 VM 커맨드라인과 attachable 여부를 빠르게 얻음.

### 3.2 `LocalVirtualMachine.java` — `sun.management.ConnectorAddressLink`

| 라인 | 심볼 | 용도 |
|------|------|------|
| 47 | `sun.management.ConnectorAddressLink` | perf 파일에서 JMX connector address 읽기 |

**사용 위치:** `getMonitoredVMs()` L254 — `ConnectorAddressLink.importFrom(pid)`.  
**목적:** attach 없이 perf 파일로 직접 connector address를 읽어 빠른 연결 시도.

### 3.3 `LocalVirtualMachine.java` — `management-agent.jar` 하드코딩

**사용 위치:** `loadManagementAgent()` L352~L391.  
```java
String agent = home + "/jre/lib/management-agent.jar";  // or /lib/...
vm.loadAgent(agent, "com.sun.management.jmxremote");
```
**목적:** JMX agent가 아직 시작되지 않은 VM에 JMX를 동적으로 활성화.

### 3.4 `ProxyClient.java` — `sun.rmi.*` (2 import)

| 라인 | 심볼 | 용도 |
|------|------|------|
| 89 | `sun.rmi.server.UnicastRef2` | SSL RMI stub 검증 |
| 90 | `sun.rmi.transport.LiveRef` | SSL RMI stub에서 socket factory 추출 |

**사용 위치:** `checkStub()` 메서드 (L194~L232).  
**호출 경로:** `checkSslConfig()` → `vmConnector=true`(원격 hostname:port 접속)일 때만.  
jvmtop의 주 사용 패턴(로컬 attach)에서는 이 경로가 실행되지 않음.

### 3.5 `ProxyClient.java` — `getProcessCpuTime()` reflection 패턴

**사용 위치:** `getProcessCpuTime()` L1078~L1120.  
```java
// com.sun.management.OperatingSystemMXBean.getProcessCpuTime() 를
// Proxy InvocationHandler를 통해 reflection으로 호출
Class.forName("com.sun.management.OperatingSystemMXBean")
     .getMethod("getProcessCpuTime")
```
`com.sun.management.OperatingSystemMXBean`은 `jdk.management` 모듈의 **public API**지만,
JMX proxy 객체로 감싸져 있어 직접 cast가 안 된다는 가정 하에 reflection을 사용.
JDK 21에서는 `ManagementFactory.newPlatformMXBeanProxy(..., com.sun.management.OperatingSystemMXBean.class)`로
직접 proxy를 얻을 수 있어 reflection이 불필요.

### 3.6 `pom.xml` — `tools.jar` system dependency

```xml
<dependency>
    <groupId>com.sun</groupId>
    <artifactId>tools</artifactId>
    <scope>system</scope>
    <systemPath>${toolsjar}</systemPath>  <!-- ${java.home}/../lib/tools.jar -->
</dependency>
```

**JDK 9+에서 제거됨.** `com.sun.tools.attach.*`는 이제 `jdk.attach` 모듈에 정식 포함.  
빌드 오류 원인 #1.

### 3.7 `jvmtop.sh` — `tools.jar` classpath 강제

```sh
TOOLSJAR="$JAVA_HOME/lib/tools.jar"
if [ ! -f "$TOOLSJAR" ] ; then
    echo "$JAVA_HOME seems to be no JDK!" >&2
    exit 1
fi
java ... -cp "$DIR/jvmtop.jar:$TOOLSJAR" com.jvmtop.JvmTop
```

JDK 9+에서 `tools.jar`이 없으므로 launcher 자체가 즉시 종료됨. 런타임 오류 원인 #1.

---

## 4. 처리 방안 (SPEC §3 기준)

| # | 의존 | 분류 | 처리 방안 |
|---|------|------|-----------|
| 1 | `sun.jvmstat.monitor.*` (6개) | **internal 제거** | `getMonitoredVMs()` 전체 제거. `getAttachableVMs()`이 이미 `VirtualMachine.list()` (public, `jdk.attach`)로 같은 목록을 제공함. command line은 `VirtualMachineDescriptor.displayName()`으로 대체. |
| 2 | `sun.management.ConnectorAddressLink` | **internal 제거** | jvmstat 경로 제거와 함께 삭제. connector address는 attach 후 `vm.getAgentProperties()` 에서 얻음 (이미 `getAttachableVMs()`에 구현됨). |
| 3 | `management-agent.jar` 하드코딩 | **internal 제거** | `loadManagementAgent()`를 JDK 9+ 방식으로 교체: `VirtualMachine.startLocalManagementAgent()` 호출 → connector address를 직접 반환. `management-agent.jar` 경로 탐색 로직 제거. |
| 4 | `sun.rmi.server.UnicastRef2` + `sun.rmi.transport.LiveRef` | **제거 (기능 비핵심)** | `checkStub()` 메서드 제거 또는 no-op화. 이 코드는 원격 hostname:port JMX 접속 시 SSL stub 검증 용도로, jvmtop의 주 기능(로컬 attach)과 무관. |
| 5 | `getProcessCpuTime()` reflection | **public API로 직접 대체** | `ManagementFactory.newPlatformMXBeanProxy(mbsc, "java.lang:type=OperatingSystem", com.sun.management.OperatingSystemMXBean.class)` 로 proxy 생성 후 직접 `.getProcessCpuTime()` 호출. reflection 제거. |
| 6 | `tools.jar` system scope (pom.xml) | **의존 제거** | `pom.xml`에서 `<dependency>com.sun:tools</dependency>` 삭제. `jdk.attach` 모듈은 JDK 9+에 자동 포함. |
| 7 | `jvmtop.sh`의 `tools.jar` 검사·classpath | **launcher 재작성** | Phase 4에서 정리. `tools.jar` 검사 제거, JDK 여부는 `bin/java` 존재로만 확인. classpath에서 `:$TOOLSJAR` 제거. |

### 추가 필요 여부 예측 (Phase 0 → 확정은 Phase 3)

| 옵션 | 예상 필요 여부 | 근거 |
|------|---------------|------|
| `-Djdk.attach.allowAttachSelf=true` | **필요할 수 있음** | jvmtop 자신을 overview에 표시하려면 self-attach 필요 (JDK 21 기본값 false). overview에서 자기 자신을 제외하면 불필요. |
| `--add-exports jdk.internal.jvmstat/sun.jvmstat.monitor=ALL-UNNAMED` | **불필요** | 처리 방안 #1에 의해 jvmstat 의존 자체 제거. |
| `--add-exports` 기타 | **불필요** | sun.rmi, sun.management 의존도 제거 예정. |

→ **목표: launcher 옵션 추가 없이 동작.** `allowAttachSelf` 최대 1개가 남을 수 있으나,
자기 자신을 overview에서 숨기는 방향으로 처음부터 설계하면 이도 불필요.

---

## 5. 변경 범위 예측

Phase 1 변경 대상은 **2개 파일**에 집중된다:

- **`LocalVirtualMachine.java`**: `getMonitoredVMs()` 제거, `loadManagementAgent()` 교체, import 정리.
- **`ProxyClient.java`**: `checkStub()` 제거, `getProcessCpuTime()` reflection → 직접 호출.
- **`pom.xml`**: `tools.jar` 의존 제거, `source/target` 21로 변경.
- **`jvmtop.sh`**: Phase 4에서 정리.

나머지 10개 파일은 **컴파일 오류 없을 것으로 예측** (standard Java API만 사용).

---

## 6. verify.sh 기준 — Golden Reference 통과 조건

`scripts/verify.sh`가 확인하는 항목:

1. victim PID가 overview에 표시될 것
2. 상세 뷰에서 `CPU-BURNER` thread가 존재하고 `RUNNABLE` 상태일 것
3. `IDLE-MAIN` thread가 존재할 것
4. `ERROR.*attach` / `Could not attach` 류 오류 없을 것

Phase 0 기준(원본 jvmtop + JDK 8):

```
bash scripts/verify.sh upstream/target/jvmtop.jar jdk/jdk8 jdk/jdk21

INFO: Victim PID: 20
PASS: Victim visible in overview
PASS: CPU-BURNER thread visible
PASS: CPU-BURNER thread is RUNNABLE
PASS: IDLE-MAIN thread visible
PASS: No attach error
============================================
 ALL CHECKS PASSED
============================================
```

Phase 2+ 목표 (포팅본 + JDK 21):

```
bash scripts/verify.sh src/target/jvmtop.jar jdk/jdk8 jdk/jdk21
```

동일하게 ALL CHECKS PASSED 출력.

---

## 7. 알려진 제약 / Flag 사항

1. **instantaneous CPU% = 0.00% (원본 jvmtop 기준) — 포팅본에서 해소됨:** Phase 0에서 원본 jvmtop(JDK 8 내부 경로)으로 측정 시 0.00%였던 문제는, 포팅본(JDK 21 JMX `getThreadCpuTime()` 경로)에서 해소됐다. Phase 3에서 `-d 1` `-d 3` 두 조건 모두 CPU-BURNER 순간 CPU% 88~97% 확인(Cowork VM, JDK 21 victim). **RHEL에서도 정상 동작 예상.**
2. **cross-version attach 미검증:** Phase 0에서는 JDK 8 도구 → JDK 8 victim만 확인. Phase 4 stretch goal.
3. **RHEL 미검증:** Ubuntu VM에서만 확인. RHEL 검증은 사람(작업자)이 수행.
4. **`jvmtop.bat` 미업데이트:** Phase 4 best-effort 대상.
5. **`jvmtop.bat` 업데이트 필요:** Windows 런처도 `tools.jar` 제거 및 `allowAttachSelf` 옵션 추가 필요. Phase 4 best-effort 대상.

---

## 8. Phase 2+ 결정 사항

### 8.1 ERROR_DURING_ATTACH 행 제외 (Phase 2 cleanup)

`VMOverviewView`에서 `ERROR_DURING_ATTACH` 상태의 VM 행을 오류 메시지 없이 조용히 제외한다.
이유: JDK 21 기본값(`jdk.attach.allowAttachSelf=false`)에서 jvmtop 자신의 PID에 attach를 시도하면
`IOException`이 발생하며 이 상태가 된다. 오류를 화면에 노출하지 않는 것이 더 깔끔한 UX이며,
self-attach 외에도 VM이 attach 도중 종료된 경우 등 일시적 실패를 포괄한다.

### 8.3 VM 목록 구성 전략 — attach 없는 목록 / per-VM 지연 attach / 짧은 타임아웃 (Phase 4)

**문제:** 원래 `getAttachableVMs()`는 `VirtualMachine.list()`로 PID를 나열한 뒤 각 VM에 `VirtualMachine.attach()`를 호출했다. 느린 VM(응답 지연 ~10.6 s)이 4개 있는 환경에서 overview/상세 진입 전 약 42 s 지연이 발생했다.

**해결 — 세 가지 변경:**

1. **목록 단계(Fix B):** `getAttachableVMs()`에서 `VirtualMachine.attach()` 제거. `VirtualMachineDescriptor`의 `id`·`displayName`만으로 목록을 구성한다(`attachable=true`, `address=null`). attach는 일절 없다.

2. **상세 모드(Fix A):** `getLocalVirtualMachine(vmid)`에서 `getAllVirtualMachines()` 호출 제거. `VirtualMachine.list()` 순회는 displayName 조회용으로만 사용하고(attach 없음), 지정된 vmid 단 하나에만 attach한다.

3. **attach 타임아웃(Fix C):** `jvmtop.sh`에 `-Dsun.tools.attach.attachTimeout=3000` 추가. 이 시스템 프로퍼티는 `sun.tools.attach.HotSpotVirtualMachine` 인스턴스 필드 `attachTimeout`을 통해 per-attach 시 읽힌다(상수가 아닌 인스턴스 필드 — 첫 attach 전에 설정하면 유효). 기본 10 s → 3 s로 단축.

**컬럼 영향:** 없음. `address=null`이면 `ProxyClient.connect()`가 `startManagementAgent()` → `loadManagementAgent()` → `VirtualMachine.attach()`를 호출한다(기존과 동일 경로). attach 실패 VM은 `ERROR_DURING_ATTACH` → overview에서 조용히 제외(§8.1과 동일). 성공 VM은 기존과 동일한 컬럼·값.

**트레이드오프:**
- 목록 화면은 즉시 표시된다. 각 VM의 JMX 지표(HPCUR, NHCUR, CPU% 등)는 첫 번째 overview 갱신 주기에 채워진다.
- 느린 VM 하나가 overview 전체를 막지 않는다(3 s 타임아웃 적용).
- 상세 모드에서는 지정 PID에만 attach하므로 다른 VM의 응답 속도가 영향을 주지 않는다.

### 8.2 -Djdk.attach.allowAttachSelf=true — §6.3-6 정당화된 최소 옵션

`src/src/main/wrappers/jvmtop.sh`에 `-Djdk.attach.allowAttachSelf=true`를 기본 포함한다.
- 원본 jvmtop 0.8.0(golden reference)은 자기 자신을 overview에 표시했다.
- JDK 21에서 self-attach를 허용하려면 이 플래그가 필요하다(JDK 21 기본: false).
- JDK 21 런처에 `tools.jar`는 존재하지 않으므로 `-cp ... tools.jar` 항목도 제거됐다.
- 이 두 가지 변경이 §6.3-6에서 허용되는 "정당화된 최소 launcher 옵션"이다.
