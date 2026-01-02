---
title: "Business Exception의 적절한 로그 레벨은 무엇인가?"
categories: java
tags: [java, spring, logging, exception, best-practice]
excerpt: "비즈니스 예외와 시스템 예외를 구분하고, 환경별 로그 레벨 정책을 수립하여 효율적인 장애 대응 체계 구축하기"
---

## 들어가며

운영 중인 시스템의 `error.log` 파일을 열어보면, 수많은 로그들 사이에서 **진짜 중요한 에러를 찾기 어려운 경우**가 많다.

특히 `Business Exception` 같은 **비즈니스 예외**가 ERROR 레벨로 무분별하게 기록되면, 정작 시스템 장애를 나타내는 에러들이 묻혀버리는 문제가 발생한다.

이번 글에서는 비즈니스 예외와 시스템 예외를 명확히 구분하고, `Business Exception`의 적절한 로그 레벨과 환경별 최적의 로그 정책을 제안한다.

---

## 문제 상황

### 실제 error.log 사례

운영 중인 시스템의 `error.log` 일부를 살펴보자.

```java
com.techpost.exception.Business Exception: 유효하지 않은 계정 요청입니다.
    at com.techpost.appapi.common.security.UserContextHolder.getContext(UserContextHolder.java:13)
    ...

com.techpost.exception.Business Exception: ID가 없거나 Password가 틀립니다.
    at com.techpost.appapi.domain.login.service.LoginService.authenticate(LoginService.java:149)
    ...

java.lang.NullPointerException: null
    at com.techpost.common.util.FileUtil.flush(FileUtil.java:118)
    ...
```

### 이 중 진짜 ERROR는 무엇인가?

위 세 가지 로그 중 **진짜 ERROR는 무엇일까?**

1. `유효하지 않은 계정 요청입니다.`
2. `ID가 없거나 Password가 틀립니다.`
3. `NullPointerException: null`

**정답: 3번 `NullPointerException` 만이 진짜 ERROR다.**

- 1번, 2번: **예상 가능한 비즈니스 예외** → 사용자의 잘못된 요청
- 3번: **예상하지 못한 시스템 오류** → 개발자의 버그

---

## 로그 레벨 이해하기

로그 레벨을 올바르게 사용하면 장애 파악 속도가 빨라지고, 불필요한 알람이 줄어들며, 디스크 용량을 효율적으로 사용할 수 있다.

### 로그 레벨 정의

#### 1. ERROR
- **의미**: 시스템이 정상 동작할 수 없는 상태, 즉시 조치가 필요한 장애
- **예시**: DB 커넥션 실패, 외부 API 통신 불가, NullPointerException, 개발자 버그

#### 2. WARN
- **의미**: 정상 처리 불가능하지만 시스템 전체에 영향은 적은 상황, 예상 가능한 예외 흐름
- **예시**: 유효하지 않은 요청, 비즈니스 조건 미충족, 사용자 입력 오류

#### 3. INFO
- **의미**: 비즈니스 흐름의 중요한 이벤트
- **예시**: 회원 가입 성공, 주문 완료, 배치 작업 완료

#### 4. DEBUG
- **의미**: 개발/테스트 환경에서 필요한 상세 정보
- **예시**: 파라미터 값, SQL 파싱 결과, 메서드 진입/종료

#### 5. TRACE
- **의미**: 내부 흐름까지 모두 기록, 거의 사용되지 않음
- **예시**: 프레임워크 내부 동작

---

## Business Exception은 ERROR가 적절한가?

### 결론

**"Business Exception을 ERROR로 기록하는 것은 적절하지 않다."**

`Business Exception`은 일반적으로 **비즈니스 로직상 발생 가능한 예외**를 다루기 때문이다.

### 예외 상황별 분석

| 예외 상황 | 성격 | 적절한 로그 레벨 |
|-----------|------|------------------|
| 주문하려는 상품이 품절 | 예상 가능한 비즈니스 예외 | **WARN** |
| 인증 실패 (ID/PW 오류) | 잘못된 사용자 요청 | **WARN** |
| 요청 파라미터는 정상인데 로직상 특정 조건 불충족 | 비즈니스 예외 | **WARN** |
| 외부 시스템 연동 중 장애 발생 | 시스템 오류 | **ERROR** |
| 개발자의 실수로 인한 NPE | 시스템 오류 | **ERROR** |

**핵심 판단 기준:**
```
도메인 로직이 처리할 수 없는 상태(SYSTEM ERROR)가 아니라면 ERROR로 기록하지 않는다.
```

---

## Business Exception의 올바른 방향

### Business Exception = 비즈니스 예외 (WARN 레벨)

```java
public class BusinessException extends RuntimeException {
    private final ErrorCode errorCode;
    
    public BusinessException(ErrorCode errorCode) {
        super(errorCode.getMessage());
        this.errorCode = errorCode;
    }
}

// 사용 예시
@Service
public class OrderService {
    
    public void order(Long productId, int quantity) {
        Product product = productRepository.findById(productId)
            .orElseThrow(() -> new BusinessException(ErrorCode.PRODUCT_NOT_FOUND));
        
        if (product.getStock() < quantity) {
            // 비즈니스 예외 → WARN 레벨
            throw new BusinessException(ErrorCode.OUT_OF_STOCK);
        }
        
        // 주문 처리...
    }
}
```

**특징:**
- 서비스 로직에서 **의도적으로 throw** 가능
- 대부분 **사용자 요청** 또는 **비즈니스 조건** 문제
- 트랜잭션 롤백 여부는 **별도 정책**으로 처리
- **로그 레벨: WARN**

### Exception = 시스템 예외 (ERROR 레벨)

```java
@Service
public class PaymentService {
    
    public void processPayment(PaymentRequest request) {
        try {
            // 외부 결제 API 호출
            paymentClient.charge(request);
        } catch (HttpClientErrorException e) {
            // 시스템 예외 → ERROR 레벨
            log.error("결제 API 통신 실패", e);
            throw new SystemException("결제 처리 중 오류 발생", e);
        } catch (NullPointerException e) {
            // 개발자 버그 → ERROR 레벨
            log.error("결제 처리 중 NPE 발생", e);
            throw e;
        }
    }
}
```

**특징:**
- 네트워크 장애, DB 장애, **개발자 버그**
- **장애 알람**을 발생시켜야 하는 수준
- **로그 레벨: ERROR**

---

## 환경별 로그 정책

### 로그 파일 구성

운영 환경에서는 로그를 **목적에 따라 분리**하는 것이 핵심이다.

| 파일 | 용도 | 포함되는 로그 레벨 |
|------|------|-------------------|
| **basic.log** | 서비스 일반 흐름 및 상태 기록 | INFO, WARN |
| **error.log** | 장애 분석 전용 파일 (스택트레이스 포함) | ERROR |

**장점:**
- 비즈니스 흐름은 `basic.log`에서 확인
- 장애는 `error.log`에서 빠르게 추적
- 불필요한 로그로 인한 혼란 최소화

---

## 환경별 권장 설정

### Local (개발자 로컬 환경)

**목적: 디버깅 최우선**

```xml
<!-- logback-local.xml -->
<configuration>
    <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
        <encoder>
            <pattern>%d{HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n</pattern>
        </encoder>
    </appender>
    
    <root level="DEBUG">
        <appender-ref ref="CONSOLE"/>
    </root>
    
    <!-- SQL 로그 -->
    <logger name="org.hibernate.SQL" level="DEBUG"/>
    <logger name="org.hibernate.type.descriptor.sql.BasicBinder" level="TRACE"/>
</configuration>
```

**설정:**
- 콘솔 출력: **DEBUG**
- SQL 로그: **DEBUG** 허용
- 프레임워크 DEBUG: 허용

**특징:**
- 개발 중 문제 파악에 필요한 **모든 정보 노출**
- 파일 용량 걱정 없음 (로컬 환경)

---

### Dev (개발 서버 / 테스트 서버)

**목적: QA 테스트 + 운영과 유사한 흐름 검증**

```xml
<!-- logback-dev.xml -->
<configuration>
    <!-- basic.log: INFO 이상 -->
    <appender name="BASIC_FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <file>logs/basic.log</file>
        <filter class="ch.qos.logback.classic.filter.ThresholdFilter">
            <level>INFO</level>
        </filter>
        <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
            <fileNamePattern>logs/basic.%d{yyyy-MM-dd}.log</fileNamePattern>
            <maxHistory>30</maxHistory>
        </rollingPolicy>
        <encoder>
            <pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n</pattern>
        </encoder>
    </appender>
    
    <!-- error.log: ERROR만 -->
    <appender name="ERROR_FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <file>logs/error.log</file>
        <filter class="ch.qos.logback.classic.filter.LevelFilter">
            <level>ERROR</level>
            <onMatch>ACCEPT</onMatch>
            <onMismatch>DENY</onMismatch>
        </filter>
        <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
            <fileNamePattern>logs/error.%d{yyyy-MM-dd}.log</fileNamePattern>
            <maxHistory>90</maxHistory>
        </rollingPolicy>
        <encoder>
            <pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n%ex</pattern>
        </encoder>
    </appender>
    
    <root level="INFO">
        <appender-ref ref="BASIC_FILE"/>
        <appender-ref ref="ERROR_FILE"/>
    </root>
    
    <!-- SQL 로그는 WARN 또는 OFF -->
    <logger name="org.hibernate.SQL" level="WARN"/>
</configuration>
```

**설정:**
- `basic.log`: **INFO 이상**
- `error.log`: **ERROR 이상**
- SQL 로그: **WARN** 또는 **OFF** (테스트 데이터 많은 경우 OFF 권장)

**특징:**
- 과도한 DEBUG 출력 차단 → QA 효율 향상
- WARN 로그로 비즈니스 예외를 명확히 확인
- 운영과 유사한 로그 흐름 검증 가능

---

### Prod (운영 환경)

**목적: 중요 정보만 남기고 장애 파악 속도 극대화**

```xml
<!-- logback-prod.xml -->
<configuration>
    <!-- basic.log: INFO, WARN -->
    <appender name="BASIC_FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <file>logs/basic.log</file>
        <filter class="ch.qos.logback.classic.filter.LevelFilter">
            <level>ERROR</level>
            <onMatch>DENY</onMatch>
            <onMismatch>ACCEPT</onMismatch>
        </filter>
        <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
            <fileNamePattern>logs/basic.%d{yyyy-MM-dd}.log.gz</fileNamePattern>
            <maxHistory>30</maxHistory>
            <totalSizeCap>10GB</totalSizeCap>
        </rollingPolicy>
        <encoder>
            <pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n</pattern>
        </encoder>
    </appender>
    
    <!-- error.log: ERROR 전용 (스택트레이스 필수) -->
    <appender name="ERROR_FILE" class="ch.qos.logback.core.rolling.RollingFileAppender">
        <file>logs/error.log</file>
        <filter class="ch.qos.logback.classic.filter.LevelFilter">
            <level>ERROR</level>
            <onMatch>ACCEPT</onMatch>
            <onMismatch>DENY</onMismatch>
        </filter>
        <rollingPolicy class="ch.qos.logback.core.rolling.TimeBasedRollingPolicy">
            <fileNamePattern>logs/error.%d{yyyy-MM-dd}.log.gz</fileNamePattern>
            <maxHistory>90</maxHistory>
        </rollingPolicy>
        <encoder>
            <pattern>%d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n%ex{full}</pattern>
        </encoder>
    </appender>
    
    <root level="INFO">
        <appender-ref ref="BASIC_FILE"/>
        <appender-ref ref="ERROR_FILE"/>
    </root>
    
    <!-- SQL 로그는 항상 OFF -->
    <logger name="org.hibernate.SQL" level="OFF"/>
    
    <!-- 비즈니스 예외는 WARN -->
    <logger name="com.techpost.exception.BusinessException" level="WARN"/>
</configuration>
```

**설정:**
- `basic.log`: **INFO, WARN** 출력 (ERROR 제외)
- 비즈니스 예외(`BusinessException`): **WARN**
- SQL 로그: **항상 OFF**
- `error.log`: **ERROR 전용** (스택트레이스 무조건 포함)

**특징:**
- 운영 디스크 효율 극대화
- 장애성 로그만 `error.log`에 쌓여 **탐색 시간 최소화**
- `basic.log`를 통해 운영 흐름 충분히 파악 가능

---

## 환경별 설정 요약

| 구분 | Local | Dev | Prod |
|------|-------|-----|------|
| **목적** | 디버깅 | QA 테스트 | 장애 파악 |
| **콘솔 출력** | DEBUG | - | - |
| **basic.log** | - | INFO+ | INFO, WARN |
| **error.log** | - | ERROR | ERROR (full trace) |
| **SQL 로그** | DEBUG | WARN/OFF | OFF |
| **BusinessException** | DEBUG | WARN | WARN |
| **파일 압축** | X | X | O (gz) |
| **보관 기간** | - | 30일 | 90일 |

---

## 실전 적용 예시

### GlobalExceptionHandler에서 로그 레벨 구분

```java
@RestControllerAdvice
public class GlobalExceptionHandler {
    
    private static final Logger log = LoggerFactory.getLogger(GlobalExceptionHandler.class);
    
    /**
     * 비즈니스 예외 처리 → WARN 레벨
     */
    @ExceptionHandler(BusinessException.class)
    public ResponseEntity<ErrorResponse> handleBusinessException(BusinessException e) {
        log.warn("비즈니스 예외 발생: {}", e.getMessage());
        
        return ResponseEntity
            .status(e.getErrorCode().getHttpStatus())
            .body(ErrorResponse.of(e.getErrorCode()));
    }
    
    /**
     * 시스템 예외 처리 → ERROR 레벨
     */
    @ExceptionHandler(Exception.class)
    public ResponseEntity<ErrorResponse> handleException(Exception e) {
        log.error("시스템 예외 발생", e); // 스택트레이스 포함
        
        return ResponseEntity
            .status(HttpStatus.INTERNAL_SERVER_ERROR)
            .body(ErrorResponse.of(ErrorCode.INTERNAL_SERVER_ERROR));
    }
}
```

### Service Layer에서의 로그 사용

```java
@Service
@RequiredArgsConstructor
public class OrderService {
    
    private static final Logger log = LoggerFactory.getLogger(OrderService.class);
    
    private final OrderRepository orderRepository;
    private final ProductRepository productRepository;
    
    @Transactional
    public OrderResponse createOrder(OrderRequest request) {
        // 1. 비즈니스 유효성 검증 → WARN
        Product product = productRepository.findById(request.getProductId())
            .orElseThrow(() -> {
                log.warn("존재하지 않는 상품 ID: {}", request.getProductId());
                return new BusinessException(ErrorCode.PRODUCT_NOT_FOUND);
            });
        
        if (product.getStock() < request.getQuantity()) {
            log.warn("재고 부족 - 상품ID: {}, 요청수량: {}, 현재재고: {}", 
                product.getId(), request.getQuantity(), product.getStock());
            throw new BusinessException(ErrorCode.OUT_OF_STOCK);
        }
        
        // 2. 주문 생성 → INFO
        Order order = Order.create(product, request.getQuantity());
        orderRepository.save(order);
        
        log.info("주문 생성 완료 - 주문ID: {}, 상품ID: {}, 수량: {}", 
            order.getId(), product.getId(), request.getQuantity());
        
        return OrderResponse.from(order);
    }
}
```

---

## 마무리

### 핵심 원칙

```
Business Exception(비즈니스 예외) = WARN
Exception(시스템 예외) = ERROR
```

### 올바른 로그 레벨 선택의 장점

1. **빠른 장애 파악**
   - `error.log`에는 진짜 장애만 기록
   - 불필요한 로그로 인한 혼란 제거

2. **효율적인 알람 운영**
   - ERROR 로그에만 알람 설정
   - 비즈니스 예외로 인한 오알람 방지

3. **디스크 공간 절약**
   - 환경별 적절한 로그 레벨 설정
   - 로그 파일 압축 및 보관 기간 관리

4. **운영 안정성 향상**
   - 명확한 로그 정책으로 일관성 유지
   - 개발자 간 혼란 최소화

### 권장 사항

- 새 프로젝트 시작 시 로그 정책을 **사전에 수립**
- GlobalExceptionHandler에서 **명확히 구분**하여 처리
- 환경별 logback 설정 파일을 **분리**하여 관리
- 정기적으로 로그를 **검토**하고 정책 개선

**Business Exception의 로그 레벨은 ERROR가 아닌 WARN이 적절하다.**

ERROR는 의도하지 않게 발생하거나 즉시 해결해야 하는 "장애"에만 사용해야 하고, Business Exception은 "예상 가능한 비즈니스 예외"이므로 WARN이 더 명확하고 운영도 안정적이다.

---

## Reference

- [SLF4J Manual](http://www.slf4j.org/manual.html)
- [Logback Official Documentation](https://logback.qos.ch/manual/)
- [Spring Boot Logging](https://docs.spring.io/spring-boot/docs/current/reference/html/features.html#features.logging)
- [Effective Exception Handling in Spring Boot](https://www.baeldung.com/exception-handling-for-rest-with-spring)

