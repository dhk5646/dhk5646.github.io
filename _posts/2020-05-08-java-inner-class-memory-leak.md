---
title: "Non-static 내부 클래스가 일으킨 '조용한 메모리 누수' 해결기"
categories: java
tags: [java, memory-leak, inner-class, gc, heap-dump, troubleshooting]
excerpt: "Full GC 이후에도 Heap 점유율이 우상향하는 현상의 원인은 non-static 내부 클래스의 숨겨진 참조였다. Eclipse MAT를 활용한 메모리 누수 추적부터 해결까지의 실전 기록"
---

## 들어가며

운영 중인 시스템에서 **메모리가 조금씩 증가하는 현상**을 발견했다.

명확한 트래픽 증가나 캐시 사용량 변화가 없었음에도, Full GC 이후 Heap 점유율의 하한선이 계속 높아지는 이상 증상이었다.

이 글에서는 **non-static 내부 클래스의 암묵적 참조**로 인한 메모리 누수를 추적하고 해결한 과정을 상세히 기록한다.

---

## 문제 상황

### 증상 (Symptom)

특정 배치성 비동기 작업이 반복될 때마다 시스템의 가용 메모리가 미세하게 줄어드는 현상이 관찰되었다.

**메모리 사용 패턴:**

```
Heap 사용량 (시간 경과)

4GB ┤            ╱─────╮
    │          ╱       │
3GB ┤        ╱         │    ╱─────╮
    │      ╱           ╰──╱       │
2GB ┤    ╱                        │    ╱─────
    │  ╱                          ╰──╱
1GB ┤╱
    └────────────────────────────────────────→
     배치1  GC  배치2  GC  배치3  GC  배치4

문제: Full GC 이후 최저점이 계속 상승
```

### 주요 징후

**1. Step-wise Memory Increase**
```
Full GC 후 Heap 점유율:
1차 배치 후: 1.2 GB
2차 배치 후: 1.5 GB
3차 배치 후: 1.8 GB
...
```

**2. 명확한 원인 없음**
- 트래픽 급증: 없음
- 캐시 사용량 증가: 없음
- 대용량 파일 처리: 없음
- 데이터베이스 커넥션 누수: 없음

**3. GC 로그 분석**

```
[Full GC] 4096M->2048M(4096M), 2.345 secs
[Full GC] 4096M->2304M(4096M), 2.567 secs
[Full GC] 4096M->2560M(4096M), 2.789 secs
```

Full GC 이후 회수되는 메모리가 점점 줄어듦.

### 판단

**객체 생명주기 관리 실패로 인한 Memory Leak 가능성이 높다.**

---

## 원인 추적 (Root Cause Analysis)

### Heap Dump 생성

**운영 중 Heap Dump 생성:**

```bash
# jmap 사용
jmap -dump:live,format=b,file=/tmp/heap.hprof <PID>

# 또는 JVM 옵션으로 자동 생성
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/tmp/heap.hprof
```

**주의사항:**
- `live` 옵션: Full GC 후 살아있는 객체만 덤프
- 운영 중 덤프 생성 시 STW(Stop-The-World) 발생
- 가급적 트래픽이 적은 시간대에 수행

### Eclipse MAT 분석

**1. Heap Dump 열기**

Eclipse MAT(Memory Analyzer Tool)로 덤프 파일 열기:

```
File > Open Heap Dump > heap.hprof
```

**2. Leak Suspects Report**

MAT가 자동으로 의심스러운 메모리 누수 후보를 리포트:

```
Problem Suspect 1:

One instance of "java.util.ArrayList" loaded by "<system class loader>"
occupies 512 MB (12.5%) of 4 GB total heap.

The instance is referenced by:
  - class com.example.batch.BatchJob, field LISTENERS
```

**3. Dominator Tree 분석**

메모리를 가장 많이 점유하는 객체 확인:

```
Class Name                    | Shallow Heap | Retained Heap
------------------------------|--------------|---------------
ArrayList                     | 48 bytes     | 512 MB
└─ JobListener[]              | 1 MB         | 511 MB
   └─ JobListener             | 32 bytes     | 510 MB
      └─ this$0 → JobService  | 1 KB         | 510 MB
```

**핵심 발견:**
- `JobService` 객체가 예상보다 **과도하게 Heap을 점유**
- `JobService`는 비동기 작업 후 소멸되어야 하나, **GC Root로부터 이어진 참조 사슬**이 끊기지 않음

**4. Path to GC Roots**

객체가 왜 회수되지 않는지 참조 경로 추적:

```
GC Root (Static Field)
  └─ BatchJob.LISTENERS (ArrayList)
     └─ JobListener (Inner Class Instance)
        └─ this$0 → JobService (Outer Class Instance)
           └─ Large Data Structures
```

**참조 경로 (Reference Path):**
```
static List<JobListener> 
    → JobListener (Instance) 
    → this$0 (JobService 참조)
    → JobService의 모든 필드
```

---

## 문제의 코드 및 메커니즘

### [AS-IS] 문제가 된 코드 구조

```java
public class BatchJob {
    // Static 컬렉션: GC Root
    private static final List<JobListener> LISTENERS = new ArrayList<>();

    public void executeBatch() {
        // 배치 작업마다 새로운 서비스 인스턴스 생성
        JobService service = new JobService();
        
        // 내부 클래스 인스턴스를 static 리스트에 추가
        LISTENERS.add(service.new JobListener());
        
        // 비동기 작업 수행
        service.processAsync();
        
        // 메서드 종료 (service는 로컬 변수이므로 참조 해제?)
    }
    
    class JobService {
        // 대용량 데이터 필드
        private List<Data> largeDataSet = new ArrayList<>();
        private Map<String, Object> cache = new HashMap<>();
        
        void processAsync() {
            // 비동기 작업 처리...
        }
        
        // non-static 내부 클래스
        class JobListener {
            void onComplete() {
                System.out.println("Job completed");
            }
        }
    }
}
```

### 왜 메모리 누수가 발생하는가?

**Java의 non-static 내부 클래스 메커니즘:**

Java에서 **non-static 내부 클래스**는 컴파일 시 다음과 같이 변환된다:

```java
// 개발자가 작성한 코드
class JobService {
    class JobListener {
        void onComplete() { /* ... */ }
    }
}

// 컴파일러가 실제로 생성하는 코드
class JobService {
    static class JobListener {
        final JobService this$0;  // 외부 인스턴스 참조 (숨겨진 필드)
        
        JobListener(JobService outer) {
            this.this$0 = outer;  // 생성자에서 자동 주입
        }
        
        void onComplete() { /* ... */ }
    }
}
```

**메모리 누수 발생 과정:**

**1단계: JobListener 인스턴스 생성**
```java
service.new JobListener()
```
이 순간 `JobListener` 인스턴스는 `this$0` 필드에 `JobService` 인스턴스의 참조를 저장한다.

**2단계: Static 리스트에 추가**
```java
LISTENERS.add(service.new JobListener());
```
`JobListener`가 static 컬렉션에 등록된다.

**3단계: 참조 체인 형성**
```
GC Root (Static Field)
    ↓
LISTENERS (ArrayList)
    ↓
JobListener 인스턴스
    ↓
this$0 (숨겨진 필드)
    ↓
JobService 인스턴스
    ↓
largeDataSet, cache (대용량 데이터)
```

**4단계: 메모리 누수**
- `executeBatch()` 메서드가 종료되어도 `JobService`는 회수되지 않음
- static 컬렉션 → `JobListener` → `this$0` → `JobService`로 이어지는 **강한 참조**
- 배치 작업이 반복될수록 `LISTENERS`에 계속 쌓임
- Full GC에서도 회수 불가능 (GC Root에서 도달 가능)

### 숨겨진 참조의 문제

**일반적인 인식:**
```java
JobService service = new JobService();
// 메서드 종료 후 service는 회수될 것이다
```

**실제 상황:**
```java
JobService service = new JobService();
LISTENERS.add(service.new JobListener());
// service는 JobListener를 통해 계속 참조됨
// 메서드 종료 후에도 회수되지 않는다!
```

**문제의 핵심:**
- `this$0` 참조는 **코드상에 명시되지 않음**
- 컴파일러가 **자동으로 생성**
- 개발자가 **의도하지 않은 강한 참조**

---

## 해결책 (The Solution)

### [TO-BE] Static 내부 클래스로 전환

**핵심 원칙:**
> 외부 클래스의 인스턴스 멤버에 접근하지 않는다면, 내부 클래스는 반드시 `static`으로 선언한다.

**개선된 코드:**

```java
public class BatchJob {
    private static final List<JobListener> LISTENERS = new ArrayList<>();

    public void executeBatch() {
        JobService service = new JobService();
        
        // static 내부 클래스 사용
        LISTENERS.add(new JobService.JobListener());
        
        service.processAsync();
    }
    
    static class JobService {
        private List<Data> largeDataSet = new ArrayList<>();
        private Map<String, Object> cache = new HashMap<>();
        
        void processAsync() {
            // 비동기 작업 처리...
        }
        
        // static 내부 클래스
        static class JobListener {
            void onComplete() {
                System.out.println("Job completed");
            }
        }
    }
}
```

### 개선 결과

**1. 참조 체인 단절**

```
Before:
GC Root → LISTENERS → JobListener → this$0 → JobService (회수 불가)

After:
GC Root → LISTENERS → JobListener (독립적)
JobService (메서드 종료 후 회수 가능)
```

**2. 컴파일된 코드 비교**

```java
// static 내부 클래스는 외부 참조를 갖지 않음
static class JobListener {
    // this$0 필드 없음!
    
    JobListener() {
        // 외부 인스턴스 참조 없음
    }
}
```

**3. 메모리 사용 패턴 개선**

```
Heap 사용량 (시간 경과)

4GB ┤
    │
3GB ┤    ╱─────╮    ╱─────╮    ╱─────╮
    │  ╱       │  ╱       │  ╱       │
2GB ┤╱         ╰╱         ╰╱         ╰
    │
1GB ┤ ← Full GC 후 항상 일정한 수준 유지
    └────────────────────────────────────────→
     배치1  GC  배치2  GC  배치3  GC  배치4

개선: Sawtooth 패턴으로 정상화
```

**4. 운영 환경 검증**

```
Before:
- Full GC 후 Heap: 1.2GB → 1.5GB → 1.8GB (증가)
- GC 빈도: 점점 증가
- GC 소요 시간: 점점 증가

After:
- Full GC 후 Heap: 1.2GB → 1.2GB → 1.2GB (일정)
- GC 빈도: 안정적
- GC 소요 시간: 일정
```

---

## 추가 고려사항

### 외부 인스턴스 접근이 필요한 경우

**시나리오:**
내부 클래스가 외부 클래스의 인스턴스 필드나 메서드에 접근해야 하는 경우

**해결 방법: 명시적 참조 전달**

```java
static class JobListener {
    private final JobService service;  // 명시적 참조
    
    JobListener(JobService service) {
        this.service = service;
    }
    
    void onComplete() {
        service.cleanup();  // 외부 메서드 호출
    }
}

// 사용
LISTENERS.add(new JobService.JobListener(service));
```

**장점:**
- 참조 관계가 **명시적**으로 드러남
- 메모리 누수 위험 인지 가능
- 필요한 만큼만 참조 유지


---

## 기술적 고찰 및 교훈

### 1. '숨겨진 참조'의 위험성

**교훈:**
컴파일러가 자동으로 생성하는 `this$0` 참조는 **코드상에 보이지 않아** 간과하기 쉽다.

특히 다음 경우에 주의:
- Static 컬렉션에 내부 클래스 인스턴스 저장
- Singleton 패턴에 내부 클래스 인스턴스 등록
- 캐시에 내부 클래스 인스턴스 보관
- 비동기 콜백으로 내부 클래스 사용

**예시: Singleton + 내부 클래스**

```java
public class ServiceManager {
    private static ServiceManager INSTANCE = new ServiceManager();
    
    public static ServiceManager getInstance() {
        return INSTANCE;
    }
    
    private List<Callback> callbacks = new ArrayList<>();
    
    public void registerCallback(Callback callback) {
        callbacks.add(callback);  // 위험!
    }
}

public class SomeService {
    private LargeObject data = new LargeObject();
    
    public void init() {
        // Non-static 내부 클래스를 Singleton에 등록
        ServiceManager.getInstance().registerCallback(new Callback() {
            @Override
            public void onEvent() {
                // this$0 → SomeService → data
            }
        });
        
        // SomeService가 회수되지 않음!
    }
}
```

### 2. Static 내부 클래스를 기본(Default)으로

**원칙:**
> 외부 클래스의 인스턴스 필드나 메서드에 직접 접근해야 하는 특수한 경우가 아니라면, 내부 클래스는 **항상 static으로 선언**한다.

**근거:**

**1) 메모리 누수 방지**
- 의도하지 않은 외부 참조 제거
- GC 효율성 향상

**2) 메모리 오버헤드 감소**
```
Non-static 내부 클래스: 객체당 8 bytes 추가 (this$0 참조)
Static 내부 클래스: 추가 오버헤드 없음

1000개 인스턴스: 8KB 절약
1,000,000개 인스턴스: 8MB 절약
```

**3) 직렬화 이슈 회피**
```java
// Non-static 내부 클래스는 직렬화 시 외부 인스턴스도 함께 직렬화
class Outer implements Serializable {
    private int x = 100;
    
    class Inner implements Serializable {
        // this$0(Outer 참조)도 직렬화됨
    }
}
```

**4) 코드 명확성**
- Static 선언으로 외부 의존성 없음을 명시
- 코드 리뷰 시 의도 파악 용이

### 3. IntelliJ IDEA 경고 활용

IntelliJ IDEA는 다음 경고를 제공한다:

```
Inner class may be 'static'
```

**설정 확인:**
```
Settings > Editor > Inspections 
> Java > Performance 
> Inner class may be 'static'
```

**자동 수정:**
```
Alt + Enter > Make 'JobListener' static
```

### 4. Effective Java 권장사항

**Effective Java 3rd Edition - Item 24:**
> Favor static member classes over nonstatic
> 
> 멤버 클래스가 외부 인스턴스에 접근하지 않는다면 항상 static 선언하라.
> Static 선언을 생략하면 외부 인스턴스로의 숨은 외부 참조를 갖게 되어 메모리 낭비와 GC 성능 저하를 초래할 수 있다.

### 5. 도구 기반의 의사결정

**교훈:**
막연한 추측 대신 **Heap Dump 분석**을 통해 실제 참조 관계를 시각화한 것이 문제 해결의 핵심이었다.

**"GC가 일을 안 한다"고 의심하기 전에:**
1. "내 코드가 객체를 붙잡고 있지 않은가?" 먼저 의심
2. Heap Dump로 참조 경로 확인
3. 데이터 기반의 의사결정

**유용한 도구:**
- **Eclipse MAT**: Heap 분석 (무료)

---

## 실전 체크리스트

### 내부 클래스 사용 시 점검 사항

- [ ] 외부 클래스의 인스턴스 멤버에 접근하는가?
  - **No** → `static` 선언 필수
  - **Yes** → 아래 추가 확인

- [ ] 내부 클래스 인스턴스의 생명주기가 외부 인스턴스보다 긴가?
  - **Yes** → `static`으로 변경
  - **No** → Non-static 사용 가능

- [ ] 내부 클래스 인스턴스를 다음 장소에 저장하는가?
  - Static 컬렉션
  - Singleton 패턴
  - 캐시
  - 장수명 컬렉션
  - **Yes** → `static` 선언 필수

- [ ] IntelliJ IDEA 경고가 있는가?
  - **Yes** → 경고 메시지 확인 및 수정

### 메모리 누수 의심 시 확인 순서

1. **GC 로그 확인**
   ```bash
   -Xlog:gc*:file=gc.log:time,level,tags
   ```
   Full GC 후 메모리 사용량 추이 확인

2. **Heap Dump 생성**
   ```bash
   jmap -dump:live,format=b,file=heap.hprof <PID>
   ```

3. **Eclipse MAT 분석**
   - Leak Suspects Report
   - Dominator Tree
   - Path to GC Roots

4. **참조 경로 확인**
   - Static 컬렉션 → 내부 클래스 → `this$0` 패턴 확인

5. **코드 수정**
   - Static 내부 클래스로 변경

6. **검증**
   - 운영 환경에서 메모리 사용량 모니터링
   - GC 로그 재확인

---

## 정리

**1. Non-static 내부 클래스의 숨겨진 비용**
- 컴파일러가 자동으로 `this$0` 참조 생성
- 외부 인스턴스가 GC되지 않을 수 있음
- 코드상에 보이지 않아 간과하기 쉬움

**2. Static 내부 클래스를 기본으로**
- 외부 인스턴스 접근이 불필요하면 반드시 `static`
- 메모리 누수 방지
- 메모리 오버헤드 감소

**3. 특히 주의해야 할 경우**
- Static 컬렉션에 저장
- Singleton에 등록
- 캐시에 보관
- 장수명 객체에 전달

**4. 도구 활용**
- Eclipse MAT로 Heap 분석
- IntelliJ IDEA 경고 활용
- GC 로그 모니터링

### 마지막으로

메모리 누수는 **조용히 시스템을 잠식**한다.

명확한 장애로 드러나지 않아 발견이 어렵고, 발견되었을 때는 이미 시스템에 심각한 영향을 미치고 있는 경우가 많다.

**내부 클래스를 사용할 때는 항상 static 여부를 고민하자.**

코드 한 줄의 차이가 운영 환경의 안정성을 좌우할 수 있다.

---

## Reference

- [Effective Java 3rd Edition - Item 24: Favor static member classes over nonstatic](https://www.oreilly.com/library/view/effective-java/9780134686097/)
- [Eclipse Memory Analyzer (MAT)](https://www.eclipse.org/mat/)
- [Java Language Specification - Inner Classes](https://docs.oracle.com/javase/specs/jls/se11/html/jls-8.html#jls-8.1.3)
- [Java Memory Leaks: How to Find and Fix Them](https://www.baeldung.com/java-memory-leaks)

