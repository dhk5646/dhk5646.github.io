---
title: "JVM 메모리 구조 분석: Heap, GC, 그리고 Java 25의 변화"
categories: java
tags: [java, jvm, gc, memory, performance, java25]
excerpt: "JVM 메모리 구조를 Heap 중심으로 상세히 분석하고, G1 GC의 동작 원리와 Java 25의 주요 변화까지 다룬 가이드"
---

## 들어가며

백엔드 개발자로서 JVM(Java Virtual Machine)의 메모리 구조를 이해하는 것은 **성능 이슈 분석, GC 튜닝, 장애 대응**의 기초가 된다.

특히 운영 환경에서 발생하는 다음과 같은 문제들을 해결하려면 JVM 메모리에 대한 깊이 있는 이해가 필수적이다:

- OutOfMemoryError 발생 시 원인 파악
- GC로 인한 애플리케이션 지연 현상
- Heap 크기 최적화
- Memory Leak 진단

이 글에서는 JVM 메모리 구조를 **Heap 중심**, 그리고 **G1 GC 기준**으로 쉽고 명확하게 정리하고, Java 25에서의 주요 변화까지 다룬다.

---

## JVM 메모리 전체 구조

JVM 메모리는 크게 **Heap**과 **Non-Heap(힙 외 영역)**으로 나뉜다.

### 메모리 구조 다이어그램

```
JVM Memory
├── Heap (GC 대상)
│   ├── Young Generation
│   │   ├── Eden Space
│   │   └── Survivor Space (S0, S1)
│   └── Old Generation
│
└── Non-Heap
    ├── Metaspace (Class Metadata)
    ├── Thread Stack (각 스레드별)
    ├── Code Cache (JIT 컴파일 코드)
    └── Native Memory
```

### 핵심 원칙

**GC의 대상이 되는 영역은 Heap만이다.**

Non-Heap 영역은 GC의 대상이 아니며, 명시적인 해제나 JVM 종료 시 정리된다.

---

## Heap 메모리 구조 상세

### Young Generation (신생 영역)

새로 생성되는 객체가 저장되는 영역이다. 대부분의 객체는 오래 살아남지 않기 때문에(약 95% 이상) Young 영역에서 빠르게 정리된다.

#### Eden Space

**역할:**
- 객체가 **최초로 생성되는 공간**
- `new` 키워드로 생성된 모든 객체는 Eden에 먼저 할당됨

**동작:**
```java
// Eden에 객체 생성
User user = new User("홍길동"); // Eden Space에 할당
Order order = new Order(1000);  // Eden Space에 할당
```

**GC 트리거:**
- Eden이 가득 차면 **Minor GC(Young GC)** 발생
- 매우 빈번하게 발생 (수 초 ~ 수십 초 간격)
- Stop-The-World 시간: 매우 짧음 (보통 수 ms ~ 수십 ms 수준)

#### Survivor Space (S0, S1)

**역할:**
- Eden에서 살아남은 객체가 이동하는 임시 공간
- S0과 S1 중 **하나는 항상 비어있음**

**동작 방식:**

```
1차 Minor GC:
Eden (가득) → S0 (이동)
Eden (비움)

2차 Minor GC:
Eden (가득) + S0 → S1 (이동)
Eden (비움), S0 (비움)

3차 Minor GC:
Eden (가득) + S1 → S0 (이동)
Eden (비움), S1 (비움)
```

**Age(나이) 개념:**
- 객체가 Minor GC에서 살아남을 때마다 Age 증가
- Age가 임계값(기본 15)에 도달하면 Old Generation으로 승격(Promotion)

**실제 예시:**
```java
public class ObjectLifecycle {
    public void process() {
        // Eden에 생성
        List<String> temp = new ArrayList<>();  // Age 0
        
        // Minor GC 발생 → S0으로 이동 (Age 1)
        // 또 Minor GC 발생 → S1으로 이동 (Age 2)
        // ...
        // Age 15 도달 → Old Generation으로 승격
        
        // 메서드 종료 후에도 참조가 유지되면 승격
        cache.put("key", temp);  // Old로 승격 가능
    }
}
```

### Old Generation (노년 영역)

**역할:**
- Young Generation에서 **오래 살아남은 객체**가 저장되는 영역
- 수명이 긴 객체들이 모임 (캐시, 싱글톤, 커넥션 풀 등)

**특징:**
- 크기가 크고 GC 비용이 높음
- GC 빈도는 낮지만 소요 시간은 김
- G1 GC에서는 Old 영역도 여러 개의 **Region**으로 관리됨

**Old Generation으로 직접 할당되는 경우:**
1. 큰 객체(Large Object): Eden에 할당할 수 없을 정도로 큰 경우
2. Age 임계값 도달
3. Survivor 공간 부족

---

## Non-Heap 메모리 구조

### Metaspace

**역할:**
- 클래스 메타정보 저장
  - Class 구조 (필드, 메서드 정보)
  - Method 바이트코드
  - 상수 풀(Constant Pool)
  - Static 변수

**Java 8 이전과의 차이:**
```
Java 7 이전: PermGen (Permanent Generation)
- Heap의 일부
- 고정된 크기 (-XX:MaxPermSize)
- OutOfMemoryError: PermGen space 빈번

Java 8 이후: Metaspace
- Native Memory 사용
- 동적 크기 조정 (기본값: 무제한)
- 유연한 메모리 관리
```

**설정 옵션:**
```bash
# Metaspace 초기 크기
-XX:MetaspaceSize=256m

# Metaspace 최대 크기
-XX:MaxMetaspaceSize=512m
```

**Metaspace가 부족할 때:**
```
java.lang.OutOfMemoryError: Metaspace
```

**주요 원인:**
- 클래스 로딩이 과도한 경우 (동적 클래스 생성)
- 클래스 로더 누수
- 많은 수의 클래스 로딩 (대규모 애플리케이션)

### Thread Stack

**역할:**
- 각 스레드마다 독립적으로 생성
- 메서드 호출 스택 프레임 저장
- 지역 변수, 메서드 파라미터 저장

**스택 프레임 구조:**
```java
public void methodA() {
    int a = 10;          // 스택에 저장
    String str = "test"; // 참조는 스택, 실제 객체는 Heap
    methodB(a);
}

public void methodB(int param) {
    int b = param * 2;   // 스택에 저장
}
```

**스택 메모리 구조:**
```
Thread Stack
├── methodB 프레임
│   ├── param: 10
│   └── b: 20
└── methodA 프레임
    ├── a: 10
    └── str: 0x12345678 (Heap 참조)
```

**설정 옵션:**
```bash
# 스레드 스택 크기 설정
-Xss1m  # 1MB
```

**StackOverflowError 발생:**
- 재귀 호출이 너무 깊을 때
- 스택 크기가 너무 작을 때

### Code Cache

**역할:**
- JIT(Just-In-Time) 컴파일러가 생성한 네이티브 코드 저장
- 자주 실행되는 코드를 기계어로 컴파일하여 성능 향상

**동작 방식:**
```
Java 바이트코드 (느림)
    ↓ JIT 컴파일 (Hot Code 감지)
네이티브 코드 (빠름) → Code Cache 저장
```

**설정 옵션:**
```bash
# Code Cache 크기 설정
-XX:ReservedCodeCacheSize=256m
```

---

## G1 GC 기준 GC 동작 방식

G1(Garbage First) GC는 **Heap을 동일한 크기의 Region으로 나누어 관리**하며, Garbage가 많은 Region을 우선 수집한다.

### G1 GC의 Region 구조

```
Heap (G1 GC)
┌─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┐
│ E   │ E   │ S   │ E   │ O   │ O   │ H   │     │
├─────┼─────┼─────┼─────┼─────┼─────┼─────┼─────┤
│ O   │ S   │ E   │ O   │ H   │     │ E   │ O   │
└─────┴─────┴─────┴─────┴─────┴─────┴─────┴─────┘

E: Eden Region
S: Survivor Region
O: Old Region
H: Humongous Region (큰 객체)
```

**특징:**
- 각 Region은 1MB ~ 32MB (기본 크기 자동 결정)
- 물리적으로 연속되지 않아도 됨
- 동적으로 역할 변경 가능 (E → S → O)

### Minor GC (Young GC)

**발생 시점:**
- Eden Region이 가득 찼을 때

**대상:**
- Eden + Survivor Region

**동작 과정:**
```
1. Stop-The-World 발생
   ↓
2. Eden과 Survivor의 살아있는 객체 식별
   ↓
3. 살아있는 객체를 다른 Survivor 또는 Old로 복사
   ↓
4. Eden과 기존 Survivor Region 비움
   ↓
5. 애플리케이션 재개
```

**성능 특성:**
- 빈도: 매우 높음 (초 단위)
- 소요 시간: 매우 짧음 (10-50ms)
- Stop-The-World: 발생하지만 짧음

**JVM 로그 예시:**
```
[GC pause (G1 Evacuation Pause) (young) 512M->128M(2048M), 0.0234567 secs]
```

### Concurrent Marking (동시 마킹)

**발생 시점:**
- Old Generation 사용률이 일정 비율(기본 45%)에 도달했을 때

**목적:**
- Old Region 중 가비지가 많은 Region 식별
- Mixed GC 준비

**단계:**
1. **Initial Mark**: Young GC와 함께 실행 (STW)
2. **Root Region Scan**: 애플리케이션과 동시 실행
3. **Concurrent Mark**: 살아있는 객체 마킹 (동시 실행)
4. **Remark**: 최종 마킹 (STW)
5. **Cleanup**: 완전히 비어있는 Region 회수 (STW)

**특징:**
- 대부분 애플리케이션과 **동시 실행**
- Stop-The-World 최소화

### Mixed GC (G1 GC 전용)

**발생 시점:**
- Concurrent Mark 단계 완료 후
- Old Region 사용률이 높을 때

**대상:**
- Young Generation 전체
- 일부 Old Region (가비지가 많은 Region 우선)

**동작 과정:**
```
1. Young GC와 유사하게 시작
   ↓
2. 동시에 선택된 Old Region도 정리
   ↓
3. 살아있는 객체를 다른 Region으로 이동
   ↓
4. 비워진 Region 회수
```

**목적:**
- Full GC 없이 Old 영역을 점진적으로 정리
- 예측 가능한 Stop-The-World 시간 유지

**JVM 로그 예시:**
```
[GC pause (G1 Evacuation Pause) (mixed) 1536M->768M(2048M), 0.0456789 secs]
```

**Mixed GC 횟수 제어:**
```bash
# Mixed GC 최대 횟수
-XX:G1MixedGCCountTarget=8
```

### Full GC

**발생 시점 (최후의 수단):**
1. **Mixed GC로도 메모리 확보 실패**
   - Old Generation이 계속 증가
   - 회수할 공간이 부족

2. **Promotion 실패 (Promotion Failure)**
   - Young에서 Old로 승격할 공간이 없음
   - Old Region 단편화 심각

3. **Humongous 객체 할당 실패**
   - 큰 객체를 저장할 연속된 Region 부족

4. **Metaspace 부족**
   - 클래스 메타정보 공간 부족

5. **명시적 호출**
   - `System.gc()` 호출

**특징:**
- **Heap 전체 Stop-The-World**
- 가장 비용이 큼 (수백 ms ~ 수 초)
- 단편화 해소 및 Compaction 수행
- 성능에 치명적인 영향

**JVM 로그 예시:**
```
[Full GC (Allocation Failure) 2048M->1024M(2048M), 1.2345678 secs]
```

**Full GC 방지 전략:**
1. Heap 크기 적절히 설정
2. Old Generation 비율 조정
3. Mixed GC 빈도 증가
4. 큰 객체 사용 자제

---

## GC 흐름 전체 요약

### 정상적인 GC 흐름

```
객체 생성 (Eden)
    ↓
Eden 가득 참
    ↓
Minor GC (Young GC)
    ↓
Survivor 이동 / Age 증가
    ↓
Age 15 도달 또는 Survivor 부족
    ↓
Old Generation으로 승격 (Promotion)
    ↓
Old 사용률 45% 도달
    ↓
Concurrent Marking 시작
    ↓
Mixed GC 반복 (Old 점진적 정리)
    ↓
정상 상태 유지
```

### 문제 상황 흐름

```
Mixed GC로 메모리 확보 실패
    ↓
Old Generation 계속 증가
    ↓
Promotion Failure 또는 할당 실패
    ↓
Full GC 발생 (Stop-The-World)
    ↓
성능 저하 발생
```

---

## 실전 GC 모니터링 및 튜닝

### GC 로그 활성화

```bash
# Java 8
-XX:+PrintGCDetails
-XX:+PrintGCDateStamps
-XX:+PrintGCTimeStamps
-Xloggc:/path/to/gc.log

# Java 9+
-Xlog:gc*:file=/path/to/gc.log:time,level,tags
```

### 주요 GC 모니터링 지표

**1. Minor GC 빈도 및 시간**
```
목표: 10-50ms 이내, 빈도는 환경에 따라 다름
문제: 100ms 이상 소요 → Young Generation 크기 조정 필요
```

**2. Mixed GC 빈도 및 시간**
```
목표: 예측 가능한 시간 내 완료
문제: 너무 자주 발생 → Old Generation 크기 증가 고려
```

**3. Full GC 발생 여부**
```
목표: 발생하지 않음
문제: 발생 시 → 근본 원인 분석 필수
```

**4. Heap 사용률**
```
목표: 70-80% 이하 유지
문제: 90% 이상 → Heap 크기 증가 또는 Memory Leak 확인
```

### G1 GC 튜닝 옵션

```bash
# Heap 크기 설정
-Xms2g                          # 초기 Heap 크기
-Xmx4g                          # 최대 Heap 크기

# G1 GC 활성화 (Java 9+ 기본값)
-XX:+UseG1GC

# 목표 Stop-The-World 시간 설정
-XX:MaxGCPauseMillis=200        # 기본 200ms

# Old Generation 비율 설정
-XX:G1HeapRegionSize=16m        # Region 크기 (1-32MB)

# Concurrent Marking 시작 임계값
-XX:InitiatingHeapOccupancyPercent=45  # 기본 45%

# Mixed GC 설정
-XX:G1MixedGCCountTarget=8      # Mixed GC 횟수
-XX:G1MixedGCLiveThresholdPercent=85  # Old Region 선택 기준

# 큰 객체(Humongous) 임계값
# Region 크기의 50% 이상이면 Humongous
```

### 실전 튜닝 시나리오

**시나리오 1: Minor GC가 너무 자주 발생**
```bash
# Young Generation 크기 증가
-XX:G1NewSizePercent=10         # Young 최소 비율 (기본 5%)
-XX:G1MaxNewSizePercent=40      # Young 최대 비율 (기본 60%)
```

**시나리오 2: Full GC가 자주 발생**
```bash
# Heap 크기 증가
-Xmx8g

# Mixed GC 빈도 증가
-XX:InitiatingHeapOccupancyPercent=35
-XX:G1MixedGCCountTarget=12
```

**시나리오 3: Stop-The-World 시간이 너무 길다**
```bash
# 목표 시간 단축
-XX:MaxGCPauseMillis=100

# Region 크기 감소 (더 세밀한 제어)
-XX:G1HeapRegionSize=8m
```

---

## Java 25의 주요 변화

Java 25(2025년 9월 예정)에서는 GC와 메모리 관리에 여러 개선 사항이 포함되어 있다.

### 1. Generational ZGC (JEP 474)

**개요:**
- ZGC(Z Garbage Collector)에 세대별 수집(Generational) 개념 도입
- 기존 ZGC는 Non-Generational(단일 세대)

**변경 사항:**
```
기존 ZGC:
- 모든 객체를 동일하게 취급
- Young/Old 구분 없음

Generational ZGC (Java 25):
- Young Generation과 Old Generation 구분
- Weak Generational Hypothesis 활용
- Minor GC와 Major GC 분리
```

**활성화 방법:**
```bash
# Java 21-24: Non-Generational ZGC (기본)
-XX:+UseZGC

# Java 25+: Generational ZGC (기본)
-XX:+UseZGC
-XX:+ZGenerational  # Java 25 기준으로 Generational ZGC는 기본 모드로 전환될 가능성이 높으며, 기존 Non-Generational ZGC도 옵션으로 유지된다.

# Non-Generational ZGC 사용 (하위 호환)
-XX:+UseZGC
-XX:-ZGenerational
```

**성능 개선:**
- Minor GC 빈도 증가하지만 소요 시간 대폭 감소
- Old Generation GC 빈도 감소
- 전체적인 처리량(Throughput) 향상
- Stop-The-World 시간 더욱 단축

**적용 시나리오:**
- 초저지연(Ultra-low Latency) 요구사항
- 대용량 Heap (수십 GB ~ TB 급)
- 응답 시간 일관성이 중요한 서비스

### 2. Late Barrier Expansion for G1 (JEP 475)

**개요:**
- G1 GC의 Write Barrier 최적화
- JIT 컴파일러가 Barrier 코드를 더 효율적으로 생성

**기술적 개선:**
```
기존 방식:
- Write Barrier가 초기 컴파일 단계에서 확장
- 최적화 기회 제한

Late Barrier Expansion:
- Write Barrier를 나중 단계에서 확장
- 더 많은 최적화 적용 가능
- 불필요한 Barrier 제거
```

**효과:**
- G1 GC 사용 시 처리량 2-5% 향상
- 특히 많은 객체 참조 변경이 있는 워크로드에서 효과적

**자동 적용:**
```bash
# Java 25에서는 기본으로 활성화
# 별도 설정 불필요
```

### 3. Class-File API 개선 (JEP 484)

**개요:**
- 클래스 파일을 파싱, 생성, 변환하는 표준 API 제공
- Metaspace 관련 디버깅 및 모니터링 개선

**활용:**
```java
// 클래스 파일 분석
ClassModel classModel = ClassFile.of().parse(classBytes);

// 메서드 정보 추출
classModel.methods().forEach(method -> {
    System.out.println("Method: " + method.methodName());
});
```

**Metaspace 영향:**
- 동적 클래스 로딩 최적화
- 클래스 메타데이터 효율적 관리

### 4. 기타 개선 사항

**Metaspace 최적화:**
- 메타데이터 압축 개선
- 메모리 할당 알고리즘 효율화

**String Deduplication 개선:**
- 중복 문자열 제거 성능 향상
- G1 GC에서 더 효과적으로 동작

```bash
# String Deduplication 활성화
-XX:+UseStringDeduplication
```

**Virtual Thread 최적화:**
- Thread Stack 메모리 사용 최적화
- 수백만 개의 Virtual Thread 지원 개선

### Java 25 마이그레이션 가이드

**1. GC 선택 전략:**

```bash
# 일반 웹 애플리케이션
-XX:+UseG1GC                    # 기본값, 추천

# 초저지연 요구사항
-XX:+UseZGC                     # Generational ZGC
-XX:+ZGenerational

# 높은 처리량 요구
-XX:+UseParallelGC              # Throughput 우선
```

**2. 호환성 확인:**

```bash
# Java 버전 확인
java -version

# GC 설정 확인
java -XX:+PrintFlagsFinal -version | grep -i gc
```

**3. 성능 테스트:**

```bash
# 기존 설정으로 벤치마크
java -XX:+UseG1GC -Xmx4g -jar app.jar

# Java 25 기본 설정으로 비교
java -Xmx4g -jar app.jar

# ZGC로 테스트
java -XX:+UseZGC -XX:+ZGenerational -Xmx4g -jar app.jar
```

---

## 실전 트러블슈팅 사례

### 사례 1: OutOfMemoryError - Java heap space

**증상:**
```
java.lang.OutOfMemoryError: Java heap space
```

**원인 분석:**
1. Heap 크기 부족
2. Memory Leak
3. 큰 객체 과다 생성

**해결 방법:**

```bash
# 1. Heap Dump 생성
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/path/to/dump

# 2. Heap 크기 증가
-Xms4g -Xmx8g

# 3. 모니터링
jstat -gcutil <pid> 1000
```

### 사례 2: OutOfMemoryError - Metaspace

**증상:**
```
java.lang.OutOfMemoryError: Metaspace
```

**원인:**
- 동적 클래스 로딩 과다
- 클래스 로더 누수

**해결 방법:**

```bash
# Metaspace 크기 증가
-XX:MetaspaceSize=512m
-XX:MaxMetaspaceSize=1g

# 클래스 언로딩 활성화 (기본 활성화)
-XX:+ClassUnloadingWithConcurrentMark
```

### 사례 3: GC Overhead Limit Exceeded

**증상:**
```
java.lang.OutOfMemoryError: GC overhead limit exceeded
```

**의미:**
- GC에 너무 많은 시간 소비 (98% 이상)
- 회수되는 메모리는 적음 (2% 이하)

**해결 방법:**

```bash
# Heap 크기 증가
-Xmx8g

# 또는 제한 해제 (권장하지 않음)
-XX:-UseGCOverheadLimit
```

---

## 정리

### 핵심 원칙

1. **Young GC는 Eden 기준**으로 자주 발생 (빠름)
2. **Mixed GC는 Old 점유율 기준**으로 가끔 발생 (보통)
3. **Full GC는 최후의 수단** (느림, 피해야 함)

### 메모리 영역별 요약

| 영역 | GC 대상 | 주요 용도 | 설정 옵션 |
|------|---------|-----------|-----------|
| **Eden** | O | 새 객체 생성 | `-XX:G1NewSizePercent` |
| **Survivor** | O | 임시 저장 | 자동 조정 |
| **Old** | O | 장수 객체 | `-Xmx` |
| **Metaspace** | X | 클래스 메타정보 | `-XX:MaxMetaspaceSize` |
| **Thread Stack** | X | 메서드 호출 스택 | `-Xss` |
| **Code Cache** | X | JIT 컴파일 코드 | `-XX:ReservedCodeCacheSize` |

### GC 알고리즘 선택 가이드

| 요구사항 | 추천 GC | 설정 |
|----------|---------|------|
| **일반적인 웹 애플리케이션** | G1 GC | `-XX:+UseG1GC` (기본) |
| **초저지연 (< 10ms)** | ZGC | `-XX:+UseZGC -XX:+ZGenerational` |
| **높은 처리량** | Parallel GC | `-XX:+UseParallelGC` |
| **작은 Heap (< 100MB)** | Serial GC | `-XX:+UseSerialGC` |

### Java 25 업그레이드 체크리스트

- [ ] Java 25 호환성 확인
- [ ] GC 로그 비교 분석
- [ ] Generational ZGC 테스트
- [ ] 성능 벤치마크 수행
- [ ] 모니터링 지표 확인
- [ ] 운영 환경 단계적 적용

### 모니터링 필수 지표

**개발 단계:**
- Minor GC 빈도 및 시간
- Full GC 발생 여부
- Heap 사용률

**운영 단계:**
- GC 로그 분석
- APM 도구 활용 (Pinpoint, Scouter)
- Heap Dump 분석 (MAT, VisualVM)

### 마지막으로

JVM 메모리 구조와 GC에 대한 이해는 **성능 최적화와 장애 대응의 핵심**이다.

하지만 무분별한 튜닝보다는 **모니터링을 통한 현상 파악**이 우선이며, 대부분의 경우 **기본 설정만으로도 충분**하다는 점을 기억하자.

Java 25의 Generational ZGC와 G1 GC 개선은 애플리케이션 성능 향상에 큰 도움이 될 것이며, 적절한 테스트를 통해 도입을 검토해볼 가치가 있다.

---

## Reference

- [Oracle Java SE Documentation](https://docs.oracle.com/en/java/)
- [JEP 474: ZGC: Generational Mode by Default](https://openjdk.org/jeps/474)
- [JEP 475: Late Barrier Expansion for G1](https://openjdk.org/jeps/475)
- [Getting Started with the G1 Garbage Collector](https://www.oracle.com/technical-resources/articles/java/g1gc.html)
- [Java Platform, Standard Edition HotSpot Virtual Machine Garbage Collection Tuning Guide](https://docs.oracle.com/en/java/javase/21/gctuning/)
- [Understanding Java Garbage Collection](https://www.baeldung.com/jvm-garbage-collectors)

