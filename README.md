> English: [README.en.md](README.en.md)

# jvmtop21 — jvmtop JDK 21 포팅

[patric-r/jvmtop](https://github.com/patric-r/jvmtop) 0.8.0을 JDK 21에서 빌드·실행되도록 포팅한 프로젝트입니다.
원본은 개발 중단 상태이며 JDK 8까지만 동작합니다. 라이선스·출처는 원본을 따릅니다(Apache 2.0, [LICENSE](LICENSE) 참조).

---

## 요구사항

- **JDK 21** (JRE 아님 — `javac`가 포함된 JDK여야 합니다)
- attach는 기본적으로 타깃 JVM과 **동일 OS 사용자 권한**이 필요합니다

---

## 빌드

```sh
JAVA_HOME=/path/to/jdk21
mvn package
```

산출물: `target/jvmtop.jar`

---

## 실행

`jvmtop.jar`과 `jvmtop.sh`를 같은 디렉터리에 두고 실행합니다.

```sh
# 빌드 후 스크립트를 jar 옆에 복사
cp src/main/wrappers/jvmtop.sh target/

# 실행 (JAVA_HOME은 JDK 21을 가리켜야 합니다)
JAVA_HOME=/path/to/jdk21 target/jvmtop.sh                   # overview: 실행 중 JVM 목록
JAVA_HOME=/path/to/jdk21 target/jvmtop.sh <pid>            # 상세: thread별 CPU 등
JAVA_HOME=/path/to/jdk21 target/jvmtop.sh --profile <pid>  # CPU 프로파일 모드
```

검증된 실행 스크립트는 **`jvmtop.sh` (Linux) 뿐**입니다.  
`jvmtop.bat`은 이 프로젝트에서 검증하지 않습니다(Windows 미검증).

---

## 원본 대비 주요 변경

| 변경 | 이유 |
|------|------|
| `tools.jar` 의존 제거 → `public com.sun.tools.attach.VirtualMachine` + JMX 경로 | JDK 9+에서 `tools.jar`이 삭제됨. `jdk.attach` 모듈에 정식 포함된 public API로 대체 |
| `sun.jvmstat` 기반 VM 열거 제거 → `VirtualMachine.list()` 기반으로 교체 | `sun.jvmstat`은 비공개 internal. `VirtualMachine.list()`(public)이 동등한 목록을 제공 |
| VM 목록 구성 시 attach 제거(lazy-attach) — 실제 attach는 첫 지표 수집 시점으로 지연 | 응답이 느린 VM이 있을 때 목록 구성 단계에서 수십 초 지연이 발생. attach를 첫 지표 수집 시점으로 미뤄 overview 목록을 즉시 표시 |
| `getProcessCpuTime()` reflection 제거 → `com.sun.management.OperatingSystemMXBean` 직접 사용 | JDK 21에서 `ManagementFactory.newPlatformMXBeanProxy()`로 public API에 직접 접근 가능 |
| self 표시: `-Djdk.attach.allowAttachSelf=true` 추가 (`jvmtop.sh` 기본 포함) | JDK 21의 self-attach 기본값이 `false`로 변경됨 |
| attach 타임아웃 3 s 설정 (`jvmtop.sh`: `-Dsun.tools.attach.attachTimeout=3000`) | lazy-attach 이후에도 개별 VM 당 attach는 기본 최대 10 s까지 걸릴 수 있어 3 s로 단축. 느린 VM이 overview 갱신을 오래 막는 문제를 추가로 완화 |

---

## 알려진 동작 / 한계

- **JDK 21 타깃 전용.** 포팅본은 JDK 21로 빌드·실행되며, JDK 21로 동작하는 프로세스에 attach합니다. 다른 JDK 버전 타깃으로의 cross-version attach는 이 프로젝트의 범위 밖입니다.

- **Attach 실패 가능 조건:** 타깃 JVM이 긴 STW GC나 hang 상태이면 attach 요청에 응답하지 못해 실패할 수 있습니다. 이는 jvmtop 고유의 문제가 아니라 HotSpot attach 메커니즘 공통 현상입니다. `jstack` / `jcmd`로도 동일하게 실패한다면 타깃 JVM 자체의 문제입니다.

- **검증 환경:** Ubuntu(개발) 및 RHEL 8/9(실서버)에서 확인. **Windows는 미검증.**

---

## 라이선스

원본 [patric-r/jvmtop](https://github.com/patric-r/jvmtop)의 라이선스(Apache 2.0)를 따릅니다. [LICENSE](LICENSE) 참조.
