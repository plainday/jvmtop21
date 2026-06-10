# SPEC: jvmtop JDK 21 포팅

> 이 문서는 본 작업의 **single source of truth**다. 모든 phase에서 코드를 수정하기 전에 이 문서를 먼저 읽고, 여기 적힌 결정·제약·가드레일을 따른다. 이 문서와 충돌하는 판단이 필요하면 임의로 진행하지 말고 사람에게 먼저 묻는다.

---

## 1. 목표

[patric-r/jvmtop](https://github.com/patric-r/jvmtop) 0.8.0 (개발 중단, JDK 8까지만 동작)을 **JDK 21에서 빌드·실행**되도록 포팅한다.
포팅본은 JDK 21로 실행되어, JDK 21로 돌아가는 다른 Java 프로세스에 attach 해서 원본과 동등한 정보를 보여줘야 한다:

- 실행 중 JVM 목록 (overview)
- 프로세스별 heap / non-heap, GC, thread 수, CPU
- **per-thread CPU 소모율** (이 도구의 핵심 가치)

---

## 2. 배경 (왜 JDK 8에서 멈췄나)

단순 컴파일 문제가 아니다. 막힘은 계층적으로 쌓여 있다:

1. **`tools.jar` 제거 (JDK 9+)** — JPMS 도입으로 `$JAVA_HOME/lib/tools.jar`이 사라졌다. jvmtop의 실행 스크립트(`jvmtop.sh`/`.bat`)는 이 파일을 classpath에 강제하고, 없으면 `seems to be no JDK!`로 종료한다.
2. **internal 클래스 vendoring** — jvmtop은 JDK 내부 클래스를 자기 소스 트리에 복사해 뒀다 (`com.jvmtop.openjdk.tools.*` — `LocalVirtualMachine`, `ProxyClient` 등). 이 복사본은 JDK 6/7/8 internals 기준이라 JDK 21 내부와 맞지 않는다.
3. **internal API 캡슐화** — `sun.jvmstat.monitor.*`는 `jdk.internal.jvmstat` 모듈로, `sun.tools.attach.*`는 `jdk.attach` 모듈로 들어갔고 export 되지 않는다.
4. **strong encapsulation (JDK 16+)** — reflective/illegal access가 기본 차단된다.
5. **self-attach 기본 비활성화 (JDK 21)** — `jdk.attach.allowAttachSelf=false`가 기본이라, 자기 자신을 overview에 표시하려면 명시 옵션이 필요하다.

참고 이슈: upstream #119 (Java 11 no tools.jar), #122.

---

## 3. 핵심 설계 결정 (위임 금지 — 이미 결정됨)

**vendored 내부 클래스에 의존하지 말고, JDK 9+에서 표준이 된 public API로 재작성한다.**

- VM attach 및 목록 조회는 **public `com.sun.tools.attach.VirtualMachine`** 를 쓴다. 이 API는 이제 `jdk.attach` 모듈에 정식 포함되어 export 되며, `tools.jar` 없이 동작한다.
  - VM 열거는 가능하면 `sun.jvmstat`의 `MonitoredHost` 대신 **`VirtualMachine.list()`** 로 대체한다.
- attach 이후의 지표 수집은 **management agent 로드 → JMX(`javax.management`) + `com.sun.management`** 경로를 쓴다. per-thread CPU는 `com.sun.management.ThreadMXBean#getThreadCpuTime`(public, `jdk.management` 모듈)로 얻는다.
- **public API로 대체 불가능한 부분(예: 일부 jvmstat perf counter)만** internal에 fallback 하고, 그 경우에만 launcher에 `--add-exports`/`--add-opens`를 추가한다.

> 즉 기본 원칙: **internal 제거가 우선, flag는 최후 수단.** "복사된 내부 클래스를 JDK 21 internals에 맞춰 패치"하는 방향은 금지한다 (더 취약하고 다음 LTS에서 또 깨진다).

### 최종 launcher에 남을 가능성이 있는 옵션 (Phase 0/3에서 실제 필요 여부 확정)

```
-Djdk.attach.allowAttachSelf=true
--add-exports jdk.internal.jvmstat/sun.jvmstat.monitor=ALL-UNNAMED   # jvmstat 카운터를 끝내 못 버릴 경우에만
```

위 옵션은 **추정**이다. 실제 어떤 internal이 남는지는 Phase 0 분석으로 확정하고, 안 쓰게 되면 제거한다.

---

## 4. 스코프 / 제약

- **타깃: JDK 21 전용.** 포팅본은 JDK 21로 빌드·실행되고 **JDK 21 타깃 프로세스에 attach**한다. 이게 완료 기준이다.
- **cross-version attach(JDK 21 도구로 다른 JDK 버전 타깃에 attach)는 범위에서 제외.** 추구하지 않는다.
- **개발/빌드/1차 검증 환경: Claude Desktop의 Cowork(Tasks 모드)가 띄우는 로컬 Ubuntu VM** (Windows Intel 호스트 → Hyper-V, x86_64). **주의: Claude Code(Code/터미널)가 아니다** — Code 쪽은 Windows 호스트의 MINGW64에서 돌아 Linux x64 JDK가 실행되지 않는다. 반드시 **Cowork/Tasks 탭**에서 작업한다. Claude는 이 Ubuntu VM 안에서 빌드하고 §6.3을 통과시킨다. 원본 jvmtop이 distro를 가리지 않고 검증돼 있으므로 Ubuntu→RHEL 이전성은 양호하다고 본다. (Phase 0에서 attach 동작 확인 완료.)
- **RHEL 최종 검증은 사람(작업자)이 직접 수행**하고 결과를 Claude에게 전달한다(§6.4). Claude는 RHEL에서만 나타나는 이슈가 보고되면 그에 대응한다.
- Claude는 단일 OS(Linux) 안에서 작업하므로 Windows↔Linux cross-platform 위험은 대부분 사라진다. 다만 §5의 잔여 항목(특히 launcher의 OS별 구분)은 결과물 품질을 위해 유지한다.
- 원본의 출력 포맷·컬럼·CLI 인자(`--once`, `<pid>` 등)는 가능한 한 그대로 유지한다.
- 빌드는 **Maven(`pom.xml`, 원래 `source/target=1.6`)**으로 확인됨(Phase 0). Phase 1에서 `release 21`로 올린다.

---

## 5. 가드레일 (반드시 준수)

- **fake/stub 금지.** 테스트나 빌드를 통과시키려고 기능을 가짜로 채우지 않는다. 포팅 불가능하거나 불확실한 부분은 **숨기지 말고 명시적으로 flag**하고 사람에게 보고한다.
- **변경은 최소·추적 가능하게.** 논리 단위로 commit하고, 커밋 메시지에 "무엇을/왜"를 적는다. 대규모 재작성 전에는 사람에게 먼저 확인한다.
- **원본은 `upstream/`에 그대로 보존**하고 건드리지 않는다. 포팅은 `src/`(원본 복사본)에서 한다. 항상 `upstream/`과 diff 가능해야 한다.
- 의도를 모르는 코드를 추측으로 삭제하지 않는다. 먼저 `upstream/`과 비교해 원래 역할을 파악한다.
- 각 phase는 **exit 기준 충족 → commit → 사람 검토 → 다음 phase**. phase를 건너뛰지 않는다.
- **OS 이식성 (개발·검증은 Linux VM, 배포는 RHEL):**
  - 개발·검증이 모두 Linux에서 이뤄지므로 줄바꿈/경로 문제는 자연히 해소된다. 그래도 `.sh`는 LF로 유지(`.gitattributes`에 `*.sh text eol=lf`).
  - classpath 구분자(Linux `:`, Windows `;`)와 경로를 launcher·빌드에 하드코딩하지 말 것.
  - `jvmtop.sh`(Linux)를 1차 산출물로 갱신·검증한다. `jvmtop.bat`(Windows)는 동일 옵션으로 best-effort 갱신하되 이 프로젝트의 검증 대상은 아니다.

---

## 6. 검증 (Acceptance)

### 6.1 테스트 대상 (victim) 앱

CPU를 의도적으로 태우는, 이름 붙은 thread를 가진 최소 프로그램. Phase 0에서 `victim/CpuBurner.java`로 materialize 한다.

```java
public class CpuBurner {
    public static void main(String[] args) throws Exception {
        Thread burner = new Thread(() -> {
            double x = 0;
            while (true) { x += Math.sqrt(Math.random()); }
        }, "CPU-BURNER");
        burner.setDaemon(false);
        burner.start();
        // 한가한 thread도 하나 둬서 대비 확인용
        Thread.currentThread().setName("IDLE-MAIN");
        while (true) Thread.sleep(60_000);
    }
}
```

### 6.2 Golden reference

- 보관해 둔 **JDK 8 + 원본 jvmtop**으로 victim(JDK 8 실행본)에 attach 한 출력 = 정답지.
- 포팅본(JDK 21)이 victim(JDK 21 실행본)에 attach 한 출력이 이와 **구조적으로 동등**해야 한다 (컬럼, 단위, 의미).

### 6.3 통과 조건

1. JDK 21에서 `git`-clean 상태로 빌드 성공.
2. 포팅본이 JDK 21 victim 프로세스를 overview 목록에 표시.
3. attach 시 `CPU-BURNER` thread가 검출되고 `RUNNABLE` 상태이며 **누적 CPU(TOTALCPU)가 높게**, `IDLE-MAIN`은 낮게 표시. (순간 CPU%는 아래 주석 참고.)
4. heap/non-heap/GC/thread 수가 합리적인 값으로 출력 (JMX MBean 값과 대조).
5. `[ERROR: Could not attach to VM]` 류 오류 없이 정상 attach.
6. launcher가 `--add-opens` 류 옵션 없이도 동작하거나, 남은 옵션이 §3에서 정당화된 최소 집합일 것.

Phase 0에서 위 검증을 자동화하는 `scripts/verify.sh`(Linux)를 만든다: victim 기동 → jvmtop 실행 → 출력에서 `CPU-BURNER`가 검출·`RUNNABLE`·높은 TOTALCPU로 잡히는지 검사.

> **순간 CPU% (헤드라인 기능)에 관하여 — 필수 검증 항목:** jvmtop의 핵심 가치는 thread별 *순간* CPU%다. 그런데 Cowork VM은 CPU throttle(~16%)과 delta 샘플링 특성 때문에 순간 CPU%가 `0.00%`로 나올 수 있다(Phase 0에서 관찰; 누적 TOTALCPU는 ~97%로 정상, `getThreadCpuTime()` 자체는 정상 동작 확인됨). 그래서 VM 안 `verify.sh`는 순간 CPU%를 검사하지 않는다. **순간 CPU%가 의미 있는 값으로 나오는지는 반드시 별도로 확인한다:** (a) VM에서 더 긴 interval·다회 iteration으로 재시도해 비-0 값을 보거나, (b) 사람의 RHEL 검증(§6.4)에서 확인. 이 항목이 누락되면 도구의 핵심 기능이 깨진 채로 "통과"될 수 있으므로, 완료 판정 전에 둘 중 최소 하나로 반드시 확인한다.

### 6.4 역할 분담: Claude는 Ubuntu에서, RHEL은 사람이

- **Claude:** Cowork Ubuntu VM 안에서 §6.3 전체를 통과시키는 것이 Claude 측 완료 기준이다.
- **사람(작업자):** Claude가 만든 산출물(jar + `jvmtop.sh`)을 실제 RHEL 8/9에서 직접 실행·검증하고, 실패 시 로그/출력을 Claude에게 전달한다. Claude는 그 피드백으로 RHEL 고유 이슈를 수정한다.
  - RHEL 검증에는 **순간 CPU% 확인이 반드시 포함**된다(§6.3 주석): CPU-BURNER thread가 순간 CPU% 컬럼에서도 높은 값으로 나오는지 본다. (throttle 없는 RHEL에서는 정상 표시될 것으로 예상.)
- Claude는 RHEL 환경에 접근하지 않으므로 "RHEL에서 됐다"를 스스로 주장하지 않는다. RHEL 통과 여부의 최종 판단은 사람이 한다.

---

## 7. 단계 계획 (각 phase 끝에서 STOP, 사람 검토 대기)

### Phase 0 — 정찰 (코드 포팅 금지)
- **(최우선 0) 환경 확인:** `uname -a`로 진짜 Ubuntu VM인지 확인(§9 gating check 0). `MINGW64...`면 멈추고 보고. 이어 `file jdk/jdk8/bin/java`로 JDK 아키텍처가 환경과 맞는지 확인.
- **(최우선 1) attach 가능 여부 확인:** 제공된 `jdk/jdk8`로 victim을 띄우고 원본 jvmtop으로 attach가 되는지 확인(§9 gating check 1). 안 되면 멈추고 보고.
- 전체 소스 정독. 빌드 도구·진입점·패키지 구조 파악.
- 위 attach 확인 시 캡처한 출력을 **golden reference**로 저장한다.
- JDK 내부에 의존하는 **모든 지점**을 파일·라인 단위로 목록화 (`tools.jar`, `sun.jvmstat.*`, `sun.tools.attach.*`, vendored `com.jvmtop.openjdk.tools.*` 등).
- 각 의존을 §3 기준으로 "public API로 대체 / `--add-exports` fallback / 추가 조사 필요" 중 무엇으로 처리할지 제안.
- `victim/CpuBurner.java`, `scripts/verify.sh` 작성.
- **산출물:** `docs/PHASE0_ANALYSIS.md` (구조 + 의존 목록 + 처리 방안 + golden reference 출력). **여기서 멈추고 검토 요청.**

### Phase 1 — JDK 21 컴파일 통과
- 빌드 설정을 JDK 21(`release 21`)로. `tools.jar` 의존 제거.
- 컴파일을 막는 제거/변경 API 수정. 런타임 동작은 아직 기대하지 않는다.
- **Exit:** JDK 21에서 빌드 성공(jar 생성). STOP.

### Phase 2 — attach + overview
- public `com.sun.tools.attach.VirtualMachine` 기반으로 VM 열거·attach 동작.
- **Exit:** §6.3의 1·2·5 충족. STOP.

### Phase 3 — per-thread CPU / profiler
- JMX + `com.sun.management.ThreadMXBean` 경로로 thread별 CPU 및 heap/GC 지표.
- 남는 internal 의존과 그에 필요한 launcher 옵션을 확정·최소화.
- **Exit:** §6.3 전부 충족. STOP.

### Phase 4 — 마무리
- launcher 스크립트 정리(필요한 module 옵션 내장, JDK 검사 로직 현대화).
- README/사용법 갱신.
- **Exit:** 문서·스크립트 정리 완료.

---

## 8. 저장소 레이아웃

```
<repo>/
├── SPEC.md                  # 이 문서
├── upstream/                # 원본 jvmtop (수정 금지, 참조·diff용)
├── src/                     # 포팅 작업 대상 (upstream 복사본)
├── victim/                  # CpuBurner.java (테스트 대상)
├── scripts/verify.sh        # 자동 검증 (Linux)
├── jdk/                      # 사람이 넣어둔 Linux x64 JDK (jdk8/, jdk21/) — .gitignore, 커밋 금지
└── docs/PHASE0_ANALYSIS.md  # Phase 0 산출물 (이후 phase 기록도 여기)
```

> JDK는 **사람이 직접 내려받아 `jdk/jdk8`, `jdk/jdk21`에 배치**한다. Claude는 JDK를 다운로드/설치하지 말고, 이 경로를 `JAVA_HOME`으로 잡아 전환만 한다. `jdk/`는 `.gitignore`로 제외(용량/라이선스). **반드시 Linux x64 빌드**여야 한다 — 실행은 Windows가 아니라 Ubuntu VM 안에서 일어난다(Windows용 .zip/.exe 받지 말 것).

---

## 9. 환경 전제

- 실행 환경은 **Cowork(Tasks 모드)가 띄우는 로컬 Ubuntu VM**이다(Windows Intel 호스트에서는 Hyper-V, x86_64). 작업 레포(그 안의 `jdk/` 포함)는 Cowork에 **연결된 폴더(connected folder)** 안에 두어야 VM에서 접근된다.
- **[gating check 0 — 환경 확인] 무엇보다 먼저 `uname -a`로 진짜 Linux VM인지 확인한다.** `Linux ... Ubuntu`면 정상. `MINGW64_NT...`가 나오면 Cowork VM이 아니라 Windows 호스트(Claude Code)이므로 **즉시 멈추고 보고**한다(Tasks 탭에서 다시 실행 필요).
- **JDK는 사람이 `jdk/jdk8`·`jdk/jdk21`에 미리 배치**한다. Claude는 다운로드하지 말고 이 경로로 `JAVA_HOME`을 전환해 쓴다. **Linux x64** 빌드여야 한다(Phase 0에서 ELF x86-64 확인 완료). `file jdk/jdk8/bin/java`로 아키텍처가 실행 환경과 맞는지 확인한다.
- **[attach] VM 안 JVM→JVM attach는 Phase 0에서 동작 확인 완료**(JDK 8 victim + 원본 jvmtop, golden reference 캡처). 다만 Phase 2~3는 JDK 21 attach + management agent 로드 + JMX 연결이라는 더 무거운 경로를 타므로, 이 단계들에서 attach/JMX가 막히면 그때 보고한다.
- jvmtop은 JRE가 아니라 **JDK**로 실행해야 한다.

> 비상시 fallback(현재 발동 조건 없음): Cowork VM이 불안정하거나 이후 단계에서 attach/JMX가 막히면 **ARM(aarch64) Ubuntu 24 + Claude Code CLI**로 전환. 그 경우 JDK를 **aarch64 Linux 빌드로 교체**해야 한다. 사람에게 보고하고 환경을 교체해 달라고 요구 해야 한다. Claude 스스로 진행하면 안 된다.
