---
title: "데이터는 있는데 처리가 안 됐다? - Redis Stream으로 해결한 장애 이야기"
categories: backend
tags: [redis, stream, message-queue, data-consistency, async]
excerpt: "배치-API 간 비동기 통신에서 발생한 데이터 유실 문제를 Redis Stream으로 해결한 경험"
---

## 들어가며

운영 중인 시스템에서 가장 무서운 상황은 **"데이터는 존재하는데, 처리가 안 된 경우"**다.

어느 날, 이런 요청을 받았다.

"김과장, a 계좌에 입금된 데이터는 존재하는데 관리비 자동수납 처리가 되지 않았어요. 원인 확인 부탁드립니다."

단순 장애라기엔 애매했고, 로그를 보니 더 애매한 상황이었다.

이번 글에서는 배치-API 간 비동기 통신에서 발생한 데이터 정합성 문제를 Redis Stream으로 해결한 경험을 정리해보려고 한다.

---

## 1. 시스템 구조

먼저 전체 흐름을 간단히 정리해보자.

**배치 애플리케이션:**
- A 은행으로부터 특정 계좌(a 계좌)의 입출금 내역 조회
- 조회한 원본 데이터를 DB에 저장 (AccountTransactions 테이블)
- API 애플리케이션에 관리비 자동수납 처리 요청 (비동기 HTTP 호출)

**API 애플리케이션:**
- 배치에서 전달받은 HTTP 요청을 기반으로
- 관리비 자동수납 도메인 로직 수행
- 수납 데이터 생성 (Payment 테이블)

**중요한 점:**

배치와 API가 다루는 데이터는 서로 다르다.

| 구분 | 배치 | API |
|------|------|-----|
| 저장 테이블 | AccountTransactions | Payment |
| 데이터 성격 | 외부 원본 데이터 | 실무 비즈니스 데이터 |
| 역할 | 은행 거래 내역 수집 | 관리비 수납 처리 |

**배치가 API를 호출하는 이유:**

관리비 수납 로직이 매우 복잡하고, 이미 API 애플리케이션에 집중적으로 관리되고 있었기 때문이다.

**비동기 호출 이유:**

관리비 수납 처리 시간이 길어 동기 방식으로 호출 시 timeout이 빈번하게 발생했다. 이를 해결하기 위해 배치는 API에 요청만 전달하고 즉시 완료처리할 수 있도록 비동기 방식으로 전환했다.

```
동기 방식:
배치 → API 호출 → 응답 대기(timeout 발생) → 완료처리

비동기 방식:
배치 → API 호출 → 완료처리
        API는 백그라운드에서 처리
```

```
[배치 애플리케이션]
    |
    | 1. A 은행 계좌 조회
    | 2. AccountTransactions 저장 (원본 데이터)
    | 3. API 비동기 HTTP 호출
    | 4. 배치 완료 처리
    v
[API 애플리케이션]
    |
    | 4. 관리비 수납 로직 수행
    | 5. Payment 저장 (실무 데이터)
    v
[처리 완료]
```

---

## 2. 문제 상황 - 데이터는 있는데, 처리는 안 됐다

문제의 핵심은 이거였다.

- 계좌 입출금 내역 원본 데이터는 DB에 존재 (AccountTransactions 테이블)
- 관리비 자동수납 데이터는 생성되지 않음 (Payment 테이블)

즉, 배치는 정상 동작한 것처럼 보였고, API 쪽에서는 아무 일도 없었던 것처럼 보였다.

**상황 정리:**

```
[배치] AccountTransactions 저장 O
       ↓ (비동기 HTTP 호출)
[API]  Payment 생성 X

결과: 원본 데이터만 있고, 실무 데이터는 없음
```

**더 큰 문제:**
- 오류 로그조차 남아있지 않았다

---

## 3. 원인 추적 - 시간 순으로 추적하다

배치 애플리케이션과 API 애플리케이션의 로그를 시간 기준으로 하나하나 맞춰보기 시작했다.

그러던 중, 한 팀원이 다가와 말했다.

"김과장... 혹시 제가 API 서버 핫픽스 배포한 거랑 관련 있을까요?"

시간을 확인해보니 관련이 있었다.

```
배치 트리거 시각: 14:00
API 서버 배포 시각: 14:02
```

**상황 재구성:**

```
14:00:00 - 배치: A 은행 계좌 조회
14:00:02 - 배치: AccountTransactions 저장 (원본 데이터) 
14:00:05 - 배치: API 서버에 비동기 HTTP 호출로 관리비 수납 요청
14:00:10 - API: Payment 생성 로직 시작
14:02:00 - API 서버 배포 시작 (프로세스 종료)
14:02:30 - 처리 완료 전 서버 종료
         → Payment 데이터는 생성되지 않음 
         → 배치는 이미 "호출 완료"로 판단
         
결과:
- AccountTransactions: 존재 (배치가 저장)
- Payment: 부재 (API 처리 실패)
```

**결론:**
- 두 애플리케이션이 너무 강하게 결합되어 있었다
- "요청 전달"과 "처리 완료"가 분리되어 있지 않았다

---

## 4. 문제의 본질 - 강결합 + 비동기 호출

이 구조의 문제는 단순한 배포 이슈가 아니었다.

```
배치는 API 호출이 성공했다고 믿고
API는 처리를 끝내지 못했는데
그 사실을 누구도 알 수 없었다
```

**기존 구조의 문제점:**

| 문제 | 설명 |
|------|------|
| 강결합 | 배치가 API 서버 상태에 직접 의존 |
| 유실 위험 | 배포/재기동 시 처리 중인 요청 유실 |
| 재처리 불가 | 실패한 요청을 다시 처리할 방법 없음 |
| 추적 어려움 | 어디서 문제가 생겼는지 알기 어려움 |

이 순간 들었던 생각은 하나였다.

**"이건 Queue가 필요하다."**

---

## 5. 대안 고민 - 현실적인 선택이 필요했다

### 5.1. DB Queue 테이블?

처음에는 이렇게 생각했다.

```
어차피 두 애플리케이션이 같은 DB를 사용 중
Queue 테이블 하나 만들어서 처리 상태 관리하면 되지 않을까?
```

**하지만 현실:**
- 재처리 정책 설계
- 중복 처리 방지 로직
- 소비 완료 여부 관리
- 장애 복구 시 처리 순서
- DB 부하 (Polling 방식)

"생각보다 Queue를 직접 구현하는 비용이 너무 크다..."

### 5.2. Kafka / RabbitMQ?

물론 가장 이상적인 선택일 수 있다.

**하지만 당시 상황:**
- 트래픽 규모가 크지 않음
- 운영 복잡도 증가
- 인프라, 모니터링, 학습 비용
- 배보다 배꼽이 더 큰 상황

### 5.3. Redis Stream (선택)

그러다 문득 떠오른 사실 하나.

**"우리는 이미 Redis를 쓰고 있지 않은가?"**

- 세션 관리
- 캐시 서버

그리고 알게 된 사실:

**Redis는 단순 캐시 서버가 아니라 Stream, Consumer Group, Queue 패턴을 제공한다.**

---

## 6. 우리 사례에 Redis Stream이 적합했던 이유

정리해보면 우리가 원했던 건 이거였다.

**요구사항:**
1. API 서버가 내려가도 요청이 유실되지 않을 것
2. 처리 완료 여부를 명확히 알 수 있을 것
3. 재처리가 가능할 것
4. 인프라 부담이 크지 않을 것

**Redis Stream의 해결:**

| 요구사항 | Redis Stream 해결 방법 |
|---------|---------------------|
| 메시지 유실 방지 | PEL (Pending Entries List) |
| 처리 완료 보장 | ACK 기반 |
| 재처리 | PEL 활용 |
| 운영 부담 | 기존 Redis 재사용 |
| 분산 처리 | Consumer Group 지원 |

---

## 7. Redis Stream이란?

Redis Stream은 Redis 5.0부터 도입된 **로그 기반 메시징 자료구조**이다.

간단히 말하면, **"이벤트 로그" 형태로 데이터를 저장하고, Consumer Group 기반 소비를 지원하는 자료구조다.**

**핵심 차이점:**

Redis Stream은 단순 Queue와 다르게 **메시지를 "흘려보내지 않고 기록"**한다.

---

## 8. Redis Stream 핵심 개념

이 문제를 해결하기 위해서 알아야 할 Redis Stream의 핵심 개념을 정리합니다.

### 8.1. Stream: 메시지를 흘려보내지 않는 로그

Redis Stream은 메시지를 **Append-only 로그 형태로 저장**합니다.

**특징:**
- 메시지는 소비 여부와 관계없이 기록됨
- 고유한 ID (`<timestamp>-<sequence>`) 보유

**차이점:**

기존 HTTP 호출은 받는 쪽이 죽으면 요청이 사라지지만, Stream은 **"API 서버가 죽어 있어도 메시지는 Redis에 안전하게 남는다"**는 점이 모든 문제 해결의 출발점입니다.

```
일반 HTTP 호출:
배치 → API 서버 (다운) → 요청 유실

Redis Stream:
배치 → Stream 저장 → API 서버 복구 → 처리 가능
```

---

### 8.2. Consumer Group: 중복 처리 방지 장치

서버가 여러 대(이중화)일 때, 동일한 메시지를 모든 서버가 처리하려고 들면 중복 데이터가 발생합니다.

**역할:**

하나의 Stream을 여러 Consumer가 나눠서 처리하게 해주는 장치입니다.

**분배:**

그룹 내에서는 하나의 메시지를 **단 하나의 Consumer만 처리**하도록 보장하여 이중화 환경에서도 정합성을 지켜줍니다.

```
[Consumer Group: auto-payment-group]
API 서버 1 → Message-1 읽음
API 서버 2 → Message-2 읽음
API 서버 1 → Message-3 읽음

결과: 중복 없이 분산 처리
```

---

### 8.3. Message ID: 모든 판단의 기준

Stream의 모든 메시지는 고유 ID를 가집니다.

**형식:**
```
1704445200000-0
(타임스탬프-순번)
```

**의미:**

메시지의 순서를 보장할 뿐만 아니라, "어디까지 처리했는지", "어떤 메시지를 재처리해야 하는지"를 결정하는 시스템적 식별자가 됩니다.

---

### 8.4. ACK (Acknowledgment): 처리 완료의 명확한 신호

**개념:**

Consumer가 비즈니스 로직을 성공적으로 마친 후 Redis에 보내는 확인 응답입니다.

**중요성:**

ACK가 가야만 해당 메시지는 시스템적으로 **"처리 완료" 확정 상태**가 됩니다.

---

### 8.5. PEL (Pending Entries List): 장애 상황의 안전장치

**이것이 우리 문제의 핵심 해결책입니다.**

PEL은 **"메시지를 읽어갔지만 아직 ACK를 보내지 않은" 목록**을 관리합니다.

**역할:**

API 서버가 배포나 OOM 등으로 갑자기 종료되어도, 처리 중이던 메시지는 사라지지 않고 **PEL에 보관**됩니다.

**핵심:**

이 목록이 있기에 "처리 중이던 작업"을 나중에 다시 살릴 수 있습니다. **PEL이 없다면 Redis Stream은 휘발성인 Pub/Sub과 다를 게 없습니다.**

**사례:**

```
14:00:00 - API 서버 1: Message-1 읽음
         → PEL에 추가
         
14:02:00 - API 서버 1: 배포로 종료
         → ACK 못 보냄
         → PEL에 계속 남음
         
14:05:00 - API 서버 1: 배포 완료
         → PEL 조회: Message-1 발견
         → 재처리 완료

결과: 데이터 유실 없음
```

---

### 8.6. XAUTOCLAIM: 자동 소유권 이전과 장애 복구

만약 특정 서버가 메시지를 가져간 뒤(PEL 상태) 완전히 죽어버린다면 어떻게 될까요?

**개념:**

XAUTOCLAIM은 **Pending 메시지 조회와 소유권 이전을 한 번에 처리**하는 명령입니다. (Redis 6.2+)

오랫동안 처리되지 않은 메시지를 자동으로 찾아서, 다른 살아있는 서버가 소유권을 가져옵니다.

**필요성:**

이 기능 덕분에 특정 서버에 장애가 생겨도 전체 시스템의 처리는 끊기지 않고 계속될 수 있습니다.

**동작 방식:**

```
14:00:00 - API 서버 1: Message-1 읽음
         → PEL에 추가

14:02:00 - API 서버 1: 장애로 다운
         → Message-1은 PEL에 계속 남음

14:10:00 - XAUTOCLAIM 스케줄러 동작 (API 서버 2)
         → "10분 이상 Pending 메시지 자동 탐색"
         → Message-1 소유권 자동 이전 (서버 1 → 서버 2)
         → 재처리 완료

결과: 별도 조회 없이 자동 복구
```

---

### 8.7. At-Least-Once와 멱등성 (Idempotency)

Redis Stream은 강력한 유실 방지(At-Least-Once)를 제공하지만, 그 대가로 중복이 발생할 수 있습니다.

**필연적 중복:**

네트워크 장애나 재처리(Claim) 과정에서 메시지가 다시 올 수 있습니다.

**애플리케이션 책임:**

따라서 수신 측(API)에서는 중복 체크나 DB Unique Index를 통해 **멱등성을 반드시 보장**해야 합니다.

---

### 메시지의 생애 주기 (Life Cycle)

**1. 발행 (Publish)**

배치가 이벤트를 발행하여 Stream에 기록

**2. 분배 (Consume)**

이중화된 API 중 하나가 읽어감 (Consumer Group 소유권 발생)

**3. 대기 (Pending)**

비즈니스 로직 수행 중 (PEL에 보관)

**4. 확정 (Acknowledge)**

처리 완료 후 ACK 전송 (PEL에서 삭제)

**5. 복구 (Recover)**

서버 장애 시 다른 서버가 소유권을 가져와 재처리 (XAUTOCLAIM)

```
정상 흐름:
발행 → 분배 → 대기 → 확정

장애 흐름:
발행 → 분배 → 대기 → (서버 다운) → 복구 → 확정
```

---

### 핵심 정리

**우리 문제 해결에 필요했던 핵심 개념:**

| 개념 | 역할 | 문제 해결 기여 |
|------|------|---------------|
| Stream  | 메시지 로그  | 배포 중에도 메시지 보존 |
| Consumer Group | 분산 처리 | 이중화 환경 중복 방지 |
| Message ID | 식별자 | 순서 보장 |
| ACK | 완료 신호 | 처리 상태 명확화 |
| **PEL** | **처리 추적** | **유실 방지의 핵심** |
| XAUTOCLAIM | 자동 소유권 이전 | 장애 시 자동 복구 |
| 멱등성 | 중복 방지 | At-Least-Once 보완 |

**결론:**

"데이터는 있는데 처리가 안 됐다" → **PEL + XAUTOCLAIM + 멱등성**으로 완벽 해결

---

## 9. 전체 구조 변경

### 9.1. Before (기존 구조)

```
[배치 App] --HTTP 비동기 호출--> [API App]

문제:
- 배치가 API 서버 상태에 의존
- 배포 중 요청 유실
```

### 9.2. After (개선된 구조)

```
[배치 App] --이벤트 발행--> [Redis Stream] <--Consumer-- [API App]

개선:
- 배치와 API 분리
- 메시지 유실 방지
- 재처리 가능
```

**핵심 변화:**

"호출"이 아니라 "이벤트 발행"으로 바뀌었다.

---

## 10. Stream & Consumer Group 설계

### 10.1. Stream 설계

**Stream Key:**
```
auto-payment-stream
```

**메시지 구조:**
```json
{
  "accountNo": "1234567890",
  "transactionDate": "2025-01-08T14:00:00",
  "amount": "50000",
  "transactionId": "TXN202501081400001"
}
```

**필드 설명:**
- `accountNo`: 계좌번호
- `transactionDate`: 거래일시
- `amount`: 거래금액
- `transactionId`: 거래 고유 ID (중복 방지용)

**참고:**
- 이 메시지는 배치가 저장한 AccountTransactions 테이블의 원본 데이터를 기반으로 생성
- API는 이 이벤트를 받아 실무 비즈니스 로직을 수행하고 Payment 테이블에 저장

### 10.2. Consumer Group 설계

**Consumer Group:**
```
auto-payment-group
```

**Consumer:**
- API 서버 인스턴스마다 1개
- 서버 수만큼 Consumer 증가 가능

**예시:**
```
API 서버 3대 운영 시:
- Consumer-1 (API 서버 1번)
- Consumer-2 (API 서버 2번)
- Consumer-3 (API 서버 3번)
```

---

## 11. 구현 - 메시지 Publisher (배치 애플리케이션)

### 11.1. 의존성 추가

```gradle
implementation 'org.springframework.boot:spring-boot-starter-data-redis'
```

### 11.2. Stream에 이벤트 발행

```java
@Service
@RequiredArgsConstructor
@Slf4j
public class AutoPaymentEventPublisher {

    private final RedisTemplate<String, String> redisTemplate;
    private static final String STREAM_KEY = "auto-payment-stream";
    private static final long MAX_STREAM_LENGTH = 10000L; // 메모리 관리를 위한 최대 길이

    public void publishAutoPaymentEvent(AutoPaymentEvent event) {
        Map<String, String> message = new HashMap<>();
        message.put("accountNo", event.getAccountNo());
        message.put("transactionDate", String.valueOf(event.getTransactionDate()));
        message.put("amount", String.valueOf(event.getAmount()));
        message.put("transactionId", event.getTransactionId());

        // MAXLEN 옵션을 추가하여 Redis 메모리 폭주 방지
        RecordId recordId = redisTemplate.opsForStream()
                .add(StreamRecords.mapBacked(message).withStreamKey(STREAM_KEY),
                        MAX_STREAM_LENGTH,
                        true); // 성능을 위해 대략적으로 자르기(~) 옵션 활성화

        log.info("이벤트 발행 완료 - RecordId: {}, TransactionId: {}",
                recordId, event.getTransactionId());
    }
}
```

**이 시점에서 배치 애플리케이션의 책임은 끝이다:**
- API 서버 상태를 알 필요 없음
- 성공/실패를 신경 쓸 필요 없음
- 이벤트는 Redis에 안전하게 저장됨

---

## 12. 구현 - Consumer Group 생성 (API 애플리케이션)

API 애플리케이션 기동 시 한 번만 실행되도록 구성했다.

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class StreamInitializer {
    
    private final RedisTemplate<String, String> redisTemplate;
    private static final String STREAM_KEY = "auto-payment-stream";
    private static final String GROUP_NAME = "auto-payment-group";
    
    @PostConstruct
    public void init() {
        try {
            redisTemplate.opsForStream().createGroup(
                STREAM_KEY,
                ReadOffset.from("0-0"),  // Stream의 첫 메시지부터 읽기
                GROUP_NAME
            );
            log.info("Consumer Group 생성 완료: {}", GROUP_NAME);
        } catch (RedisSystemException e) {
            if (e.getCause() instanceof RedisCommandExecutionException) {
                log.info("Consumer Group 이미 존재: {}", GROUP_NAME);
            } else {
                throw e;
            }
        }
    }
}
```

**주의사항:**
- `BUSYGROUP` 에러는 이미 그룹이 존재한다는 의미
- 정상 상황이므로 무시

### 12.1. ReadOffset 설정의 중요성

**ReadOffset 옵션별 차이:**

| ReadOffset | 시작 위치 | 사용 시기 |
|-----------|---------|---------|
| `from("0-0")` | Stream의 첫 메시지 | **최초 생성 시에만** |
| `latest()` | 현재 시점 이후의 새 메시지 | 과거 메시지 무시 |
| `lastConsumed()` | 마지막 소비 지점 | 재기동 시 권장 |

**중요:**

Consumer Group은 한 번 생성되면 자신의 offset을 유지한다. 따라서:

1. **최초 생성 시**: `ReadOffset.from("0-0")` 사용
   - Stream에 쌓인 과거 메시지부터 처리
   
2. **재기동 시**: createGroup이 실패 (이미 존재)
   - 기존 offset을 그대로 사용
   - 처리 중이던 지점부터 계속 진행

**운영 중 Consumer Group 삭제 시 주의:**

```java
// 운영 중 Consumer Group을 삭제하면 안 되는 이유
redisTemplate.opsForStream().destroyGroup(STREAM_KEY, GROUP_NAME);

// 재생성 시
createGroup(..., ReadOffset.from("0-0"), ...);
// → 모든 메시지를 처음부터 다시 처리하게 됨
```

**만약 운영 중 Group을 재생성해야 한다면:**

```java
// 방법 1: latest() 사용 (과거 무시)
createGroup(STREAM_KEY, ReadOffset.latest(), GROUP_NAME);

// 방법 2: 특정 메시지 ID부터
createGroup(STREAM_KEY, ReadOffset.from("1704445200000-0"), GROUP_NAME);
```

**우리의 경우:**

- 최초 배포: Consumer Group이 없으므로 `0-0`부터 안전하게 생성
- 재기동: Group이 이미 존재하므로 createGroup 실패 → 기존 offset 유지
- 따라서 재처리 문제가 발생하지 않음

**하지만 주의해야 할 상황:**

```
1. 운영 중 Consumer Group 이름 변경
2. Stream 이름 변경
3. 장애 복구 중 수동으로 Group 삭제

→ 이런 경우 ReadOffset 전략을 신중히 선택해야 함
```

---

## 13. 구현 - 메시지 Consumer 등록 (API 애플리케이션)

```java
@Configuration
@RequiredArgsConstructor
public class RedisStreamConfig {
    
    private final RedisConnectionFactory connectionFactory;
    private final AutoPaymentMessageListener messageListener;
    
    private static final String STREAM_KEY = "auto-payment-stream";
    private static final String GROUP_NAME = "auto-payment-group";
    
    @Bean
    public StreamMessageListenerContainer<String, MapRecord<String, String, String>> streamContainer() {
        // 1. Container 옵션 설정
        StreamMessageListenerContainerOptions<String, MapRecord<String, String, String>> options =
            StreamMessageListenerContainerOptions.builder()
                .pollTimeout(Duration.ofMillis(100))  // 100ms마다 새 메시지 확인
                .targetStreamOffset(StreamOffset.create(STREAM_KEY, ReadOffset.lastConsumed()))
                .build();
        
        // 2. Container 생성
        StreamMessageListenerContainer<String, MapRecord<String, String, String>> container =
            StreamMessageListenerContainer.create(connectionFactory, options);
        
        // 3. Consumer 이름 생성 (서버별 고유)
        String consumerName = getConsumerName();
        
        // 4. Consumer 등록 및 메시지 리스너 연결
        container.receive(
            Consumer.from(GROUP_NAME, consumerName),  // 어떤 그룹의 어떤 Consumer인지
            StreamOffset.create(STREAM_KEY, ReadOffset.lastConsumed()),  // 어디서부터 읽을지
            messageListener  // 메시지 받았을 때 처리할 리스너
        );
        
        // 5. Container 시작
        container.start();
        
        log.info("Redis Stream Consumer 시작 - Consumer: {}", consumerName);
        
        return container;
    }
    
    /**
     * Consumer 이름 생성
     * - 서버 호스트명 사용 (api-server-1, api-server-2...)
     * - 호스트명 조회 실패 시 UUID로 대체
     */
    private String getConsumerName() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            return "consumer-" + UUID.randomUUID().toString().substring(0, 8);
        }
    }
}
```

**주요 설정 설명:**

**1. pollTimeout (100ms)**

```
의미: Redis Stream을 얼마나 자주 확인할 것인가

100ms = 0.1초마다 새 메시지 확인
- 값이 작을수록: 실시간성 ↑, CPU 사용률 ↑
- 값이 클수록: CPU 사용률 ↓, 지연 시간 ↑

우리의 선택: 100ms
- 실시간에 가까운 처리
- CPU 부하 적정 수준
```

**2. ReadOffset.lastConsumed()**

```
의미: Consumer Group이 마지막으로 소비한 지점부터 읽기

동작:
- 최초 실행: Consumer Group 생성 시 설정한 위치부터 (0-0)
- 재기동: 마지막 ACK 보낸 위치 다음부터

장점:
- 재기동 시 중복 읽기 방지
- 처리 중이던 메시지는 PEL에 남아있어 안전
```

**3. Consumer 이름 전략**

```
호스트명 사용 이유:
- API 서버별 고유한 이름 자동 부여
- 모니터링 시 어느 서버가 처리했는지 명확

예시:
- API 서버 1: api-server-1
- API 서버 2: api-server-2
- API 서버 3: api-server-3

호스트명 조회 실패 시:
- consumer-a1b2c3d4 (UUID 앞 8자리)
```

**4. Consumer 등록 흐름**

```
1. Consumer.from(GROUP_NAME, consumerName)
   → "auto-payment-group의 api-server-1입니다"

2. StreamOffset.create(STREAM_KEY, ReadOffset.lastConsumed())
   → "auto-payment-stream을 마지막 소비 위치부터 읽겠습니다"

3. messageListener
   → "메시지 오면 이 리스너로 처리하겠습니다"
```


## 14. 구현 - 메시지 Listener (API 애플리케이션)

### 14.1. 메시지 처리 + ACK

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class AutoPaymentMessageListener implements StreamListener<String, MapRecord<String, String, String>> {
    
    private final RedisTemplate<String, String> redisTemplate;
    private final AutoPaymentService autoPaymentService;
    
    private static final String STREAM_KEY = "auto-payment-stream";
    private static final String GROUP_NAME = "auto-payment-group";
    
    @Override
    public void onMessage(MapRecord<String, String, String> message) {
        String messageId = message.getId().getValue();
        Map<String, String> value = message.getValue();
        
        log.info("메시지 수신 - ID: {}, TransactionId: {}", 
            messageId, value.get("transactionId"));
        
        try {
            // 비즈니스 로직 처리
            processAutoPayment(value);
            
            // 처리 완료 후 ACK
            redisTemplate.opsForStream().acknowledge(
                STREAM_KEY,
                GROUP_NAME,
                messageId
            );
            
            log.info("메시지 처리 완료 - ID: {}", messageId);
            
        } catch (Exception e) {
            log.error("메시지 처리 실패 - ID: {}, Error: {}", 
                messageId, e.getMessage(), e);
            // ACK 하지 않음 → PEL에 남음 → 재처리 대상
        }
    }
    
    private void processAutoPayment(Map<String, String> message) {
        AutoPaymentRequest request = AutoPaymentRequest.builder()
            .accountNo(message.get("accountNo"))
            .transactionDate(LocalDateTime.parse(message.get("transactionDate")))
            .amount(new BigDecimal(message.get("amount")))
            .transactionId(message.get("transactionId"))
            .build();
        
        autoPaymentService.process(request);
    }
}
```

**핵심 원칙:**

처리가 끝났을 때만 ACK

## 15. 구현 - 비즈니스 서비스에서 멱등성 보장 (API 애플리케이션)

Redis Stream은 At-Least-Once 방식으로 메시지 유실을 방지하지만, 그 대가로 **중복 처리가 발생할 수 있습니다.**

### 15.1. 멱등성 보장 전략

**이중 방어 구조:**

1. **애플리케이션 레벨**: transactionId로 중복 체크
2. **DB 레벨**: Unique Index로 최종 방어

```java
@Service
@RequiredArgsConstructor
public class AutoPaymentService {
    
    private final AutoPaymentRepository autoPaymentRepository;
    
    @Transactional
    public void process(AutoPaymentRequest request) {
        // 반드시 DB 트랜잭션 내부에서 멱등성 체크 + 저장을 수행해야 함
        
        // 1차 방어: 중복 체크
        if (autoPaymentRepository.existsByTransactionId(request.getTransactionId())) {
            log.warn("이미 처리된 트랜잭션");
            return;
        }
        
        try {
            // 비즈니스 로직
            AutoPayment payment = AutoPayment.create(request);
            autoPaymentRepository.save(payment);
            
        } catch (DataIntegrityViolationException e) {
            // 2차 방어: DB Unique Index 위반 시
            log.warn("중복 트랜잭션 차단 (DB 레벨)");
        }
    }
}
```

---

## 16. Consumer 전체 동작 흐름:

```
[애플리케이션 시작]
    ↓
[StreamConfig.streamContainer() 실행]
    ↓
[Container 옵션 설정]
- pollTimeout: 100ms
- ReadOffset: lastConsumed
    ↓
[Consumer 등록]
- Group: auto-payment-group
- Name: api-server-1
- Listener: AutoPaymentMessageListener
    ↓
[Container 시작]
    ↓
[100ms마다 새 메시지 확인]
    ↓ (메시지 발견)
[messageListener.onMessage() 호출]
    ↓
[비즈니스 로직 처리]
    ↓
[ACK 전송]
    ↓
[다시 100ms 대기...]
```

---

## 17. 구현 - PEL 재처리 스케쥴러 (API 애플리케이션)

### 17.1. Pending 메시지 자동 재처리

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class PendingMessageProcessor {
    
    private final RedisTemplate<String, String> redisTemplate;
    private final AutoPaymentMessageListener messageListener;
    
    private static final String STREAM_KEY = "auto-payment-stream";
    private static final String GROUP_NAME = "auto-payment-group";

    /**
     * 1분마다 Pending 메시지 확인 및 재처리
     * 10분 이상 처리되지 않은 메시지를 자동으로 가져와 재처리
     */
    @Scheduled(fixedDelay = 60000)  // 60초 = 1분
    public void autoClaim() {
        String consumerName = getConsumerName();
        
        try {
            // XAUTOCLAIM: 10분 넘은 Pending 메시지를 내가 가져옴
            AutoclaimResponse<String, String> response = redisTemplate.opsForStream()
                    .autoClaim(
                        STREAM_KEY,
                        CommandArgs.from(STREAM_KEY)
                            .group(GROUP_NAME)
                            .consumer(consumerName)
                            .minIdleTime(Duration.ofMinutes(10))  // 10분 이상 Pending 메시지
                            .count(10)  // 한 번에 최대 10개
                    );

            List<MapRecord<String, String, String>> messages = response.getMessages();
            
            if (!messages.isEmpty()) {
                log.info("Pending 메시지 {} 건 재처리 시작 - Consumer: {}", 
                    messages.size(), consumerName);
                
                // 각 메시지 재처리
                messages.forEach(messageListener::onMessage);
            }
            
        } catch (Exception e) {
            log.error("XAUTOCLAIM 실패 - Consumer: {}", consumerName, e);
        }
    }

    /**
     * Consumer 이름 생성 (StreamConfig와 동일)
     */
    private String getConsumerName() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            return "consumer-" + UUID.randomUUID().toString().substring(0, 8);
        }
    }
}
```

**주요 설정 설명:**

**1. @Scheduled(fixedDelay = 60000)**

```
의미: 이전 실행 완료 후 60초(1분) 대기 후 재실행

왜 1분?
- 너무 짧으면: CPU 부하, 불필요한 조회
- 너무 길면: 장애 복구 지연
- 1분 = 적절한 균형
```

**2. minIdleTime(Duration.ofMinutes(10))**

```
의미: 10분 이상 Pending 상태인 메시지만 대상

왜 10분?
- 정상 처리 시간: 평균 30초
- 안전 여유: 10배 (5분)
- 네트워크 지연: +5분
---
총: 10분

너무 짧으면: 정상 처리 중인데 가져올 수 있음, 이 경우 때문에 멱등성이 중요
너무 길면: 장애 복구가 늦어짐
```

**3. count(10)**

```
의미: 한 번에 최대 10개 메시지만 처리

이유:
- 한 번에 너무 많으면 처리 시간 증가
- 다른 Consumer의 기회 박탈 방지
- 10개 = 적정 배치 크기 (메시지당 30초 * 10 = 5분)
```

**4. XAUTOCLAIM 동작 방식**

```
기존 방식 (2단계):
1. XPENDING으로 Pending 목록 조회
2. 각 메시지마다 XCLAIM 호출

XAUTOCLAIM (1단계):
1. 조회 + 소유권 이전 동시 처리

장점:
- Redis 호출 횟수 감소
- 네트워크 오버헤드 감소
- 코드 간결
```

**전체 동작 흐름:**

```
[1분마다 실행]
    ↓
[XAUTOCLAIM 호출]
- 10분 이상 Pending 메시지 탐색
    ↓ (발견)
[소유권 이전]
- Message-1 (Consumer A → 나)
- Message-5 (Consumer B → 나)
    ↓
[메시지 재처리]
- forEach(messageListener::onMessage)
    ↓
[처리 완료 → ACK]
    ↓
[1분 대기 후 재실행...]
```

**실제 운영 시나리오:**

```
[장애 상황]
14:00 - API 서버 1 배포로 다운
     → Message-1, Message-2 PEL에 남음
     
14:10 - API 서버 2 스케줄러 실행
     → "10분 이상 Pending 발견"
     → XAUTOCLAIM으로 가져옴
     → 재처리 완료
     
14:11 - ACK 전송
     → PEL에서 제거
```

---

## 18. 도입 후 달라진 점

### 18.1. Before (도입 전)

```
문제:
- 배포 중 데이터 유실
- 재처리 방법 없음
- 원인 추적 어려움
- 배치-API 강결합

결과:
- "데이터는 있는데 처리 안 됨" 발생
- 수동 재처리 필요
- 운영 스트레스
```

### 18.2. After (도입 후)

```
개선:
- 배포 중에도 데이터 정합성 유지
- 자동 재처리 (PEL)
- 명확한 처리 상태 추적
- 배치-API 느슨한 결합

결과:
- 데이터 유실 제로
- 운영 안정성 향상
- 심리적 안정감 증가
```

### 18.3. 수치로 보는 개선 효과

| 지표 | Before | After |
|------|--------|-------|
| 데이터 유실 건수 | 월 2~3건 | 0건 |
| 수동 재처리 시간 | 건당 30분 | 0분 (자동) |
| 장애 재발 방지 | 불가능 | 구조적 해결 |

---

## 19. 주의사항

### 19.1. 메모리 관리

Stream은 메모리에 저장되므로 주의가 필요하다.

**관련 내용:** [11. 구현 - 메시지 발행 (배치 애플리케이션)](#11-구현---메시지-발행-배치-애플리케이션)

```java
redisTemplate.opsForStream()
    .add(StreamRecords.mapBacked(message)
        .withStreamKey(STREAM_KEY), 
        10000L,  // maxlen: 최대 10,000개까지만 유지
        true);   // approximateTrimming: 대략적인 trim
```

**설명:**
- Stream은 Redis 메모리에 저장되므로 무한정 쌓이면 메모리 부족 발생
- `maxlen` 옵션으로 최대 메시지 수 제한
- `approximateTrimming=true`: 정확한 개수가 아닌 대략적으로 trim (성능 향상)

---

### 19.2. Consumer 이름 관리

Consumer 이름이 중복되면 같은 메시지를 받을 수 없다.

**관련 내용:** [13. 구현 - 메시지 소비 (API 애플리케이션)](#13-구현---메시지-소비-api-애플리케이션)

```java
// 서버 인스턴스별로 고유한 이름 사용
String consumerName = InetAddress.getLocalHost().getHostName();
```

**설명:**
- Consumer Group 내에서 Consumer 이름은 고유해야 함
- 같은 이름 사용 시: 동일 Consumer로 인식되어 메시지 분배 안 됨
- 호스트명 사용: api-server-1, api-server-2... (자동으로 고유)

---

### 19.3. ACK 타이밍

**관련 내용:** [14. 구현 - 메시지 처리 및 ACK (API 애플리케이션)](#14-구현---메시지-처리-및-ack-api-애플리케이션)

```java
// 잘못된 예
try {
    redisTemplate.opsForStream().acknowledge(...);  // 먼저 ACK
    processAutoPayment(message);  // 처리 실패 시 유실
} catch (Exception e) {
    // 이미 ACK 했으므로 재처리 불가
}

// 올바른 예
try {
    processAutoPayment(message);  // 처리 완료
    redisTemplate.opsForStream().acknowledge(...);  // 이후 ACK
} catch (Exception e) {
    // ACK 안 했으므로 PEL에 남아 재처리 가능
}
```

**핵심 원칙:**

**처리 완료 후에만 ACK 전송**

- ACK 먼저 보내면: 처리 실패 시 메시지 유실
- 처리 후 ACK: 실패 시 PEL에 남아 자동 재처리

---

### 19.4. Redis 버전 확인

**XAUTOCLAIM은 Redis 6.2 이상부터 지원됩니다.**

**관련 내용:** [15. 구현 - PEL 재처리 (API 애플리케이션)](#15-구현---pel-재처리-api-애플리케이션)

```bash
# Redis 버전 확인
redis-cli --version
# 또는
redis-cli INFO server | grep redis_version
```

**Redis 6.2 미만인 경우:**
- XAUTOCLAIM 사용 불가
- 기존 방식 사용: XPENDING + XCLAIM 조합

```java
// Redis 6.2 미만 대안 (XPENDING + XCLAIM)
PendingMessages pending = redisTemplate.opsForStream()
    .pending(STREAM_KEY, GROUP_NAME, Range.unbounded(), 100L);

for (PendingMessage pm : pending) {
    if (pm.getElapsedTimeSinceLastDelivery().toMinutes() > 10) {
        List<MapRecord> claimed = redisTemplate.opsForStream().claim(
            STREAM_KEY, GROUP_NAME, consumerName,
            Duration.ofMinutes(10), RecordId.of(pm.getIdAsString())
        );
        claimed.forEach(messageListener::onMessage);
    }
}
```

---


## 20. 마무리

이번 경험을 통해 다시 느낀 점은 이것이다.

**정합성 문제는 DB 트랜잭션만의 문제가 아니다.**

**시스템 간 이벤트 전달을 어떻게 보장하느냐의 문제다.**

Redis Stream은 "가볍지만 필요한 건 다 있는" 현실적인 선택지였다.

### 20.1. 핵심 교훈

**1. "호출"이 아니라 "이벤트"로 생각하라**

```
배치가 API를 "호출"한다 (X)
→ 강결합, 유실 위험

배치가 이벤트를 "발행"한다 (O)
→ 느슨한 결합, 유실 방지
```

**2. 메시지 큐는 대규모 서비스만의 것이 아니다**

```
"우리 트래픽은 작아서 큐가 필요 없어"
→ 잘못된 생각

데이터 정합성은 트래픽 크기와 무관
→ 올바른 생각
```

**3. 기존 인프라를 활용하라**

```
새로운 인프라 도입은 신중해야 하지만
이미 있는 인프라의 숨겨진 기능을 찾아보는 것도 중요
```

**마지막으로:**

"데이터는 있는데 처리가 안 됐다"는 말을 다시는 듣지 않게 되었다는 것만으로도, 이번 개선은 충분한 가치가 있었다.

---

## Reference

- [Redis Streams 공식문서](https://redis.io/docs/latest/develop/data-types/streams)
- [Spring Data Redis - Redis Streams](https://docs.spring.io/spring-data/redis/docs/current/reference/html/#redis.streams)

