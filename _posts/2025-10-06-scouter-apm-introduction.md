---
title: "Scouter APM 도입 사례 - 운영 환경 전환을 위한 오픈소스 APM 구축기"
categories: devops
tags: [apm, scouter, monitoring, performance, java]
excerpt: "Agent 기반 오픈소스 APM Scouter를 도입하여 실시간 모니터링 체계를 구축한 경험과 운영 노하우"
---

## 들어가며

시스템이 운영 모드로 전환되면서 장애 대응 방식에 근본적인 변화가 필요했다. 

특히, JPA 기반으로 개발을 하면서 쿼리를 직접 관리하지 않는 특성상, 성능 저하 원인을 신속히 파악하는 것이 중요했다.

ERP 특성상 트랜잭션이 복잡하고, 장애 발생 시점에 빠르게 병목 지점을 찾아내는 것이 운영 안정성 확보의 핵심이었다.


**기존 방식의 한계:**
- 로그 기반 사후 분석
- 사용자 제보 후에야 문제 인지
- 병목 지점 파악까지 오랜 시간 소요

**운영 환경에서 필요한 것:**
- 실시간 상태 파악
- 병목 지점의 즉시 식별
- 무중단 적용 가능

이러한 요구사항을 충족하기 위해 Agent 기반 오픈소스 APM을 검토했고, 최종적으로 **Scouter APM**을 선택하여 도입했다.

---

## 1. Scouter APM이란?

### 핵심 특징

**Java 기반 웹 애플리케이션을 위한 오픈소스 APM**
- Agent 기반 구조로 무중단 적용 가능
- 실시간 모니터링에 특화
- 국내 개발자들이 주도하는 활발한 커뮤니티

### 주요 기능

**실시간 성능 지표**
- TPS (Transaction Per Second)
- 응답 시간

**상세 추적**
- SQL 호출 추적
- HTTP 호출 추적
- Slow Query 분석 용이

**JVM 모니터링**
- Heap / GC 상태
- Thread 상태
- 메모리 누수 감지

**서버 자원 모니터링**
- CPU 사용률
- Memory 사용률
- Swap 상태

**트랜잭션 추적**
- XLog 기반 요청 흐름 추적
- 병목 구간 식별

### 사용 버전

```
Scouter v2.20.0
```

---

## 2. Scouter 전체 아키텍처

### 구성도

```
┌─────────────────┐
│  Host Agent     │──┐
└─────────────────┘  │    ┌──────────────────────┐    ┌──────────┐
                     ├──▶ │ Collector Server     │───▶│  Client  │
┌─────────────────┐  │    └──────────────────────┘    └──────────┘
│  Java Agent     │──┘    
└─────────────────┘
```

### 구성 요소

| 구성 | 역할 | 설명 |
|------|------|------|
| Collector Server | 메트릭 수집 및 저장 | 모든 Agent로부터 데이터를 받아 저장 |
| Agent.host | 서버 자원 모니터링 | CPU, Memory, Disk, Network 등 |
| Agent.java | 애플리케이션 모니터링 | JVM, SQL, Active Service, Error 등 |
| Client | 모니터링 UI | 실시간 데이터 시각화 및 분석 |

**운영 포인트:**
- Host Agent와 Java Agent는 반드시 함께 사용
- Java Agent만 사용하면 서버 병목 원인 파악이 어려움

---

## 3. 소스코드 관리 전략

### 소스 다운로드

**GitHub Release 활용**
- [Scouter GitHub Releases](https://github.com/scouter-project/scouter/releases)
- Source code (tar.gz) 사용

**사내 보안 정책 고려:**
- 외부 GitHub 직접 접근 제한
- 내부 Git Repository로 미러링

### 내부 Repository 구조

```
scouter/
├── scouter.server/
├── agent.host/
└── agent.java/
```

**장점:**
- 외부 네트워크 의존성 제거
- 배포 일관성 유지
- 버전 관리 통제

---

## 4. Scouter Collector Server 설정

### 기본 설정 (scouter.conf)

```properties
# Server 식별자
server_id=SCOUTER-COLLECTOR

# HTTP API 활성화
net_http_server_enabled=true
net_http_api_enabled=true
net_http_api_swagger_enabled=true

# Data Retention (보관 주기)
mgr_purge_profile_keep_days=2      # Profile 데이터
mgr_purge_xlog_keep_days=5         # XLog 데이터
mgr_purge_counter_keep_days=15     # Counter 데이터

# SQL Profile
profile_sql_max_rows=50000
```

### 설정 상세 설명

**1. Data Retention 설정**

보관 주기를 분리하는 이유:
- Profile: 상세 정보, 디스크 사용량 높음 (2일)
- XLog: 트랜잭션 흐름, 장애 분석용 (5일)
- Counter: 통계 정보, 추세 분석용 (15일)

**2. profile_sql_max_rows**

대용량 조회 쿼리 조기 탐지:
- 50,000건 이상 조회 시 알림
- 성능 저하 원인 사전 파악

---

## 5. Agent 개념 정리

### Agent 종류와 역할

**1. agent.host (서버 레벨)**

**수집 정보:**
- CPU 사용률
- Memory 사용률
- Disk I/O
- Network 트래픽

**활용:**
- 서버 자원 병목 파악
- CPU Spike 감지
- Memory Leak 초기 탐지

**2. agent.java (애플리케이션 레벨)**

**수집 정보:**
- JVM Heap / GC
- Thread 상태
- SQL 실행 내역
- Active Service
- Error 발생 현황

**활용:**
- 애플리케이션 병목 파악
- Slow Query 식별
- 메모리 누수 추적

### 운영 Best Practice

```
반드시 host + java 함께 사용

host만 사용: 애플리케이션 병목 파악 어려움
java만 사용: 서버 자원 병목 파악 어려움
```

---

## 6. agent.host 설치

### 설치 프로세스

**1. 소스 배포**

```bash
# 내부 Repository에서 다운로드
cd /app/scouter
tar -xzf agent.host.tar.gz
```

**2. 설정 파일 수정 (conf/scouter.conf)**

```properties
# Collector 서버 정보
net_collector_ip=${SCOUTER_COLLECTOR_IP}
net_collector_udp_port=6100
net_collector_tcp_port=6100

# 서버 식별
obj_name=${HOSTNAME}
```

**3. 기동 스크립트 실행**

```bash
./host.sh
```

### 역할 및 활용

**주요 역할:**
- 서버 단위 자원 모니터링
- CPU Spike 조기 감지
- Memory Leak 초기 탐지

**운영 효과:**
- 애플리케이션 문제와 서버 문제 구분 가능
- 자원 부족으로 인한 성능 저하 사전 파악

---

## 7. agent.java 적용 전략

### 적용 방식

**기동 스크립트 기반 제어**
- 코드 수정 불필요
- JVM 옵션으로만 제어
- ON/OFF 쉽게 전환 가능

### JVM 옵션 구성

```bash
# Scouter Agent 활성화
-javaagent:${SCOUTER_AGENT_DIR}/scouter.agent.jar
-Dscouter.config=${SCOUTER_AGENT_DIR}/conf/scouter.conf
-Dobj_name=${APP_NAME}

# Java 17+ 필수 옵션
--add-opens=java.base/java.lang=ALL-UNNAMED
--add-exports=java.base/sun.net=ALL-UNNAMED
-Djdk.attach.allowAttachSelf=true
```

### start.sh 설계 (TCD 표준)

```bash
#!/bin/sh

APP_NAME=$1
ENV=$2
INSTANCE_NUM=$3
IS_SCOUTER_ACTIVE=${4:-"false"}

# Scouter 옵션 구성
SCOUTER_OPTS=""
if [ "$IS_SCOUTER_ACTIVE" = "true" ]; then
    SCOUTER_AGENT_DIR="/app/scouter/agent.java"
    SCOUTER_OPTS="-javaagent:${SCOUTER_AGENT_DIR}/scouter.agent.jar"
    SCOUTER_OPTS="${SCOUTER_OPTS} -Dscouter.config=${SCOUTER_AGENT_DIR}/conf/scouter.conf"
    SCOUTER_OPTS="${SCOUTER_OPTS} -Dobj_name=${APP_NAME}"
    SCOUTER_OPTS="${SCOUTER_OPTS} --add-opens=java.base/java.lang=ALL-UNNAMED"
    SCOUTER_OPTS="${SCOUTER_OPTS} --add-exports=java.base/sun.net=ALL-UNNAMED"
    SCOUTER_OPTS="${SCOUTER_OPTS} -Djdk.attach.allowAttachSelf=true"
fi

# Java 실행
java ${SCOUTER_OPTS} -jar ${APP_NAME}.jar
```

### 실행 예시

```bash
# Scouter 비활성화 (기본)
./start.sh app-api alpha 1

# Scouter 활성화
./start.sh app-api alpha 1 true
```

### 운영 장점

**무중단 제어 가능:**
- 운영 중 Scouter ON/OFF 전환
- 장애 상황에서만 활성화 가능

**배포 스크립트 재사용성:**
- 모든 애플리케이션 동일한 방식
- 표준화된 운영 절차

---

## 8. JVM 옵션 상세 설명

### 1. -javaagent:${SCOUTER_AGENT_DIR}/scouter.agent.jar

**역할:**
- Scouter Java Agent를 JVM에 로드
- 애플리케이션 바이트코드를 런타임에 계측(Instrumentation)

**왜 필요한가:**

Scouter는 다음을 코드 수정 없이 수집:
- 메서드 실행 시간
- SQL 호출
- 외부 API 호출

**운영 포인트:**
- JVM 기동 시점에만 적용 가능
- 실행 중 동적 부착보다 안정적
- 무중단 배포 구조에 적합

### 2. -Dscouter.config=${SCOUTER_AGENT_DIR}/conf/scouter.conf

**역할:**
- Scouter Agent 전용 설정 파일 경로 지정

**설정 파일 주요 내용:**

```properties
# Collector 서버 정보
net_collector_ip=${SCOUTER_COLLECTOR_IP}
net_collector_udp_port=6100
net_collector_tcp_port=6100

# Object 타입
obj_type=java

# 샘플링 설정
profile_sql_param_enabled=true
trace_http_client_ip_header_key=X-Forwarded-For

# 프로파일링 옵션
profile_connection_open_enabled=true
```

**왜 명시적으로 지정하는가:**
- 기본 경로 의존 방지
- 환경별 설정 분리 가능

**운영 Best Practice:**

```
conf/
├── scouter-alpha.conf
└── scouter-prod.conf
```

### 3. -Dobj_name=${APP_NAME}

**역할:**
- Scouter 상에서 표시되는 객체(Object) 이름 지정

**Scouter에서 표시되는 곳:**
- Active Service 목록
- XLog 화면
- Object 목록

**왜 중요한가:**

같은 서버에 여러 서비스가 존재하는 경우:
- app-api
- app-auth
- app-batch

obj_name 없으면 구분 불가능

**Best Practice:**

```bash
# 서비스명 그대로 사용
-Dobj_name=app-api
-Dobj_name=app-auth
-Dobj_name=app-batch

# 서버명과 혼동 방지
```

### 4. --add-opens=java.base/java.lang=ALL-UNNAMED

**역할:**
- Java 모듈 시스템(JPMS)에서 java.lang 패키지 접근 허용

**왜 필요한가:**

Java 9 이상부터 내부 API 접근 제한

Scouter는 다음 정보를 수집:
- Thread 상태
- ClassLoader 정보
- Runtime 정보

**없으면 발생 가능한 문제:**
- IllegalAccessError
- 일부 JVM 메트릭 수집 실패
- Agent 기동 실패

**운영 포인트:**
- Java 11 / 17 / 21 환경에서 필수
- 대부분의 APM이 동일하게 요구

### 5. --add-exports=java.base/sun.net=ALL-UNNAMED

**역할:**
- JDK 내부 패키지(sun.net) 접근 허용

**Scouter에서 왜 사용하나:**
- HTTP, 네트워크 관련 정보 수집
- URLConnection, Socket 추적

**없을 경우:**
- 외부 API 호출 추적 누락
- 네트워크 메트릭 일부 미수집

**운영 포인트:**
- 보안상 위험하지 않음
- Agent 전용 접근 허용

### 6. -Djdk.attach.allowAttachSelf=true

**역할:**
- JVM 자기 자신에 대한 Attach 허용

**Attach란:**

실행 중인 JVM에 대해:
- Agent 연결
- Thread Dump
- Heap 정보 접근

**왜 필요한가:**

Scouter는 다음을 Attach API로 수집:
- Thread 상태
- Active Service
- 실시간 JVM 정보

**없을 경우:**
- 일부 기능 제한
- Thread / Active 정보 누락 가능

### JVM 옵션 요약

| 옵션 | 목적 | 필수 여부 |
|------|------|----------|
| -javaagent | Scouter Agent 로딩 | 필수 |
| -Dscouter.config | Agent 설정 파일 지정 | 필수 |
| -Dobj_name | 서비스 식별 | 필수 |
| --add-opens | Java 모듈 접근 허용 | Java 9+ 필수 |
| --add-exports | 내부 네트워크 API 접근 | 권장 |
| -Djdk.attach.allowAttachSelf | JVM Attach 허용 | 권장 |

---

## 9. Scouter Client

### 다운로드 및 설치

**다운로드:**
- OS별 Client 제공
- [Scouter Releases](https://github.com/scouter-project/scouter/releases)
- v2.20.0 사용

**Mac OS 실행 오류 해결:**

```bash
# Gatekeeper 우회
xattr -cr scouter.client.app
```

### 접속 정보

| 항목 | 값        |
|------|----------|
| Address | ${SCOUTER_COLLECTOR_IP}:6100 |
| ID | admin    |
| Password | admin    |

### 초기 접속 후 설정

**1. Object 선택**
- 모니터링할 서비스 선택
- 여러 Object 동시 선택 가능

**2. 화면 Layout 구성**
- Active Service
- XLog
- TPS / Response Time
- SQL Profile

---

## 10. 운영 시 가장 먼저 보는 화면 Top 4

### 1. Active Service

**의미:**
- 현재 처리 중인 요청 수

**왜 중요한가:**
- 순간적인 트래픽 폭증 감지에 가장 빠름

**운영 기준:**

```
평소 평균 대비 2~3배 이상 지속 → 이상 징후
Active는 높고 TPS는 정체 → 병목 발생 가능성
```

### 2. TPS (Transaction Per Second)

**의미:**
- 초당 실제 처리량

**활용:**
- 트래픽 변화 추이 파악
- 처리 능력 한계 파악

**운영 기준:**

```
TPS ↓ + Active ↑ → 처리 지연
TPS ↑ + 응답시간 ↑ → 리소스 부족 가능성
```

### 3. Response Time

**의미:**
- 사용자 체감 성능 지표

**운영 기준 (예시):**

```
평균: 300~500ms
95% 이상이 1초 초과 → 즉시 확인 대상
```

### 4. JVM Heap / GC

**의미:**
- 메모리 사용 현황 및 GC 상태

**운영 기준:**

```
Old 영역 지속 증가
Full GC 발생 빈도 증가
GC 후 Heap 회복 안 됨 → 누수 의심
```

**왜 중요한가:**
- 메모리 문제는 항상 지연 후 폭발

---

## 11. XLog 중심 운영 전략

### XLog란?

**단일 요청의 전체 흐름을 추적**

```
Controller → Service → SQL → 외부 API
```

**장애 분석의 출발점**

### XLog 기본 활용 패턴

**1. 느린 요청 찾기**

```
1. XLog 화면에서 Response Time 기준 정렬
2. 상위 N건 확인
3. 패턴 분석
```

**2. 병목 구간 식별**

병목이 주로 발생하는 구간:
- SQL
- External API
- 특정 메서드

**경험상:**
> "느린 API"의 80%는 SQL 1~2개가 원인

### XLog에서 반드시 보는 항목

**1. Elapsed Time**
- 전체 처리 시간

**2. SQL**
- SQL 수행 시간
- SQL Count

**3. External Call**
- 외부 API 호출 여부
- 응답 시간

**4. Error**
- Exception 발생 여부
- Stack Trace

### XLog 실전 활용 사례

**Case 1: Slow API 분석**

```
증상: 특정 API 응답 시간 3초
XLog 확인:
- SQL 1개: 2.8초
- 나머지: 0.2초

원인: SQL 인덱스 누락
해결: 인덱스 추가 → 50ms로 개선
```

**Case 2: N+1 쿼리 감지**

```
증상: API 응답 시간 5초
XLog 확인:
- SQL Count: 201개
- 개별 SQL은 빠름 (10ms)

원인: N+1 쿼리
해결: Fetch Join 적용 → 200ms로 개선
```

---

## 12. Slow Query 실전 대응 패턴

### Slow Query 판단 기준

| 구분 | 기준 | 대응 |
|------|------|------|
| Warning | 1초 이상 | 개선 검토 |
| Critical | 3초 이상 | 즉시 개선 |

(서비스 특성에 따라 조정)

### 자주 만나는 Slow Query 유형

**1. 인덱스 누락**

```sql
-- 문제
SELECT * FROM orders 
WHERE user_id = ? 
AND status = 'PENDING';

-- 인덱스 없음: Full Table Scan
```

**해결:**

```sql
CREATE INDEX idx_orders_user_status 
ON orders(user_id, status);
```

**2. N+1 쿼리**

```
XLog에서 SQL Count 폭증
개별 SQL은 빠름
전체 응답 시간 느림
```

**해결:**

```java
// 문제
@OneToMany(fetch = FetchType.LAZY)
private List<OrderItem> items;

// 해결
@Query("SELECT o FROM Order o JOIN FETCH o.items WHERE o.id = :id")
Order findByIdWithItems(@Param("id") Long id);
```

**3. 대용량 ResultSet**

```
profile_sql_max_rows 초과
불필요한 컬럼 조회
```

**해결:**

```java
// 문제
List<Order> findAll();

// 해결
@Query("SELECT new OrderDto(o.id, o.status) FROM Order o")
List<OrderDto> findAllSimple();
```

### Scouter의 장점

> "어떤 요청에서 발생했는지" 바로 연결됨

일반 DB 로그:
- SQL만 보임
- 어떤 요청인지 모름

Scouter:
- SQL + 요청 URL + 파라미터
- 즉시 재현 가능

---

## 13. Active 증가 + TPS 정체 패턴 분석

### 가장 흔한 장애 전조

```
Active ↑↑
TPS →
Response Time ↑
```

### 의미

```
요청은 쌓이는데 처리 못 함
Thread / DB / External 병목
```

### 점검 순서

**1. XLog 상위 요청 확인**

```
Response Time 상위 10개
어떤 API가 느린가?
```

**2. SQL 지연 여부**

```
SQL 수행 시간 확인
Slow Query 존재 여부
```

**3. 외부 API 호출 여부**

```
External Call 확인
타임아웃 발생 여부
```

**4. JVM Thread 상태**

```
Thread 고갈 여부
Deadlock 발생 여부
```

### 실전 사례

**증상:**

```
10:30 AM
Active: 5 → 50
TPS: 100 → 100
Response Time: 300ms → 3s
```

**원인 분석:**

```
XLog 확인:
- 외부 결제 API 호출 시간: 평소 100ms → 5초
- Thread Pool 고갈

원인:
- 외부 API 장애
- Connection Timeout 설정 없음
```

**해결:**

```java
// Connection Timeout 설정
RestTemplate restTemplate = new RestTemplateBuilder()
    .setConnectTimeout(Duration.ofSeconds(3))
    .setReadTimeout(Duration.ofSeconds(5))
    .build();

// Circuit Breaker 적용 (장기)
@CircuitBreaker(name = "payment", fallbackMethod = "fallback")
public PaymentResponse payment(PaymentRequest request) {
    // ...
}
```

---

## 14. 실무 적용 체크리스트

### 도입 전 확인사항

```
□ Collector Server 구축
□ 내부 Repository 소스 관리
□ Agent ACL 설정
□ Data Retention 정책 수립
□ 네트워크 방화벽 오픈 (UDP/TCP 6100)
```

### 서버별 적용사항

```
□ agent.host 설치 및 기동
□ agent.java 설정 파일 배포
□ start.sh 수정 (Scouter 옵션 추가)
□ 테스트 환경 검증
□ 운영 환경 적용
```

### 운영 중 확인사항

```
□ Agent 정상 동작 확인
□ Collector 연결 상태 확인
□ 데이터 수집 여부 확인
□ XLog 정상 수집 확인
□ SQL Profile 정상 수집 확인
```

### 장애 대응 절차

```
1. Active Service 확인
2. TPS / Response Time 확인
3. XLog 상위 요청 분석
4. SQL / External Call 확인
5. JVM / Thread 상태 확인
```

---


## 15. 마무리

### Scouter 도입 핵심 효과

**1. 실시간 관찰 체계 확립**
- "문제 발생 후 분석" → "실시간 관찰"로 전환
- 장애 인지 시간 대폭 단축

**2. 무중단 적용 가능**
- 코드 수정 없이 JVM 옵션으로만 제어
- 운영 중 ON/OFF 자유로운 전환

**3. 오픈소스 기반 비용 절감**
- 상용 APM 대비 비용 부담 없음
- 활발한 커뮤니티 지원

**4. 병목 지점 즉시 식별**
- XLog 기반 트랜잭션 추적
- Slow Query 자동 탐지

### 운영 환경에서 APM의 의미

```
APM은 선택이 아니라 기본 인프라
실시간 관찰 없이는 안정적인 운영 불가능
```

---

## Reference

- [Scouter GitHub](https://github.com/scouter-project/scouter)
- [Scouter 공식 문서](https://github.com/scouter-project/scouter/blob/master/scouter.document/main/README.md)
- [Scouter APM 소소한 시리즈 - 기본 모니터링](https://github.com/scouter-project/scouter/blob/master/scouter.document/use-case/XLog-Monitoring.md)
- [Scouter APM 소소한 시리즈 - Active Service & XLog](https://github.com/scouter-project/scouter/blob/master/scouter.document/use-case/Active-Service-Monitoring.md)

