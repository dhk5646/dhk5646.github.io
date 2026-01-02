---
title: "외부 연계 테스트 전략: Interface 를 활용한 개발 생산성 향상"
categories: java
tags: [java, spring, mock, test, integration, architecture]
excerpt: "외부 업체의 개발 환경 부재로 인한 테스트 어려움을 Interface 기반 Mock Server 도입으로 해결하고, 개발 생산성과 안정성을 동시에 확보한 실전 사례"
---

## 들어가며

외부 시스템과 연계하는 프로젝트를 진행하던 중, **외부 업체가 개발 서버를 제공하지 않고 운영 서버만 가용**한 상황에 직면했다.

이로 인해 로컬 및 개발 단계에서 실시간 연동 테스트가 불가능했고, 실제 응답 값을 확인하지 못한 채 비즈니스 로직을 개발해야 하는 리스크가 발생했다.

이 글에서는 **Interface 기반 Mock Server를 도입**하여 외부 환경에 의존하지 않는 테스트 전략을 구축한 과정과, 그를 통해 얻은 개발 생산성 향상 효과를 공유한다.

---

## 문제 상황

### 1. 환경 불일치

외부 업체가 개발 서버를 제공하지 않고 **운영 서버만 가용**함에 따라, 로컬 및 개발 단계에서 실시간 연동 테스트가 불가능한 상황이었다.

**문제점:**
- 로컬 개발 시 외부 API 응답을 확인할 수 없음
- 개발 서버에서 통합 테스트 불가
- 운영 서버를 직접 호출할 수 없는 보안 정책

### 2. 리스크 상승

실제 응답 값을 확인하지 못한 채 비즈니스 로직을 개발해야 했으며, 이는 **운영 배포 직전까지 시스템 안정성을 담보하기 어려운 구조**였다.

**발생 가능한 문제:**
- 응답 데이터 구조 불일치로 인한 파싱 오류
- 예상치 못한 응답 케이스 미처리
- 에러 핸들링 로직 검증 불가
- 운영 배포 후 장애 발견 위험

### 3. 생산성 저하

외부 업체 환경에 의존적인 구조로 인해 **개발 사이클이 끊기는 병목 현상**이 발생했다.

**개발 흐름의 단절:**
```
개발 → 로컬 테스트 불가 → 운영 배포 → 문제 발견 → 수정 → 재배포
                ↑
          병목 지점 발생
```

---

## 해결 전략

### 핵심 아이디어: 느슨한 결합 (Loose Coupling)

외부 API의 응답을 가상화하여 **외부 환경에 대한 의존성을 제거**하는 전략을 수립했다.

### 설계 원칙

**1. Interface 기반 추상화**
- 실제 API 호출부와 비즈니스 로직을 분리
- 구현체 교체만으로 환경 전환 가능
- 확장성 및 유지보수성 확보

**2. Mock Implementation 구현**
- 로컬/개발 환경에서는 사전 정의된 응답(Mock Data) 반환
- 실제 API 명세에 기반한 정확한 Mock Data 작성
- 다양한 시나리오(정상, 오류, 예외) 대응

**3. Profile별 전략적 주입**
- Spring Profile을 활용한 환경별 Bean 주입
- 설정 파일만으로 구현체 전환
- 코드 수정 없이 환경 변경 가능

### 아키텍처 개요

```
[비즈니스 로직]
       ↓
[ExternalApiConnector Interface]
       ↓
   ┌───┴────┐
   ↓        ↓
[Real]   [Mock]
운영환경  로컬/개발
```

---

## 상세 설계 및 구현

### 1단계: 연계 인터페이스 정의

외부 연동을 규격화하여 **실제 통신 여부와 관계없이** 비즈니스 로직이 동작할 수 있는 틀을 만든다.

```java
public interface ExternalApiConnector {
    /**
     * 외부 API 요청 전송
     * @param request 요청 데이터
     * @return 응답 데이터
     * @throws ExternalApiException 외부 API 호출 실패 시
     */
    ApiResponse sendRequest(ApiRequest request);
    
    /**
     * 외부 API 상태 확인
     * @return 연결 가능 여부
     */
    boolean healthCheck();
}
```

**설계 포인트:**
- 인터페이스는 비즈니스 요구사항만 정의
- 구현 세부사항(HTTP, 인증 등)은 구현체가 담당
- 명확한 예외 처리 정의

### 2단계: 운영 환경용 실제 구현체

실제 외부 API를 호출하는 구현체를 작성한다.

```java
@Slf4j
@Component
@Profile("prod")
@RequiredArgsConstructor
public class RealExternalApiConnector implements ExternalApiConnector {
    
    private final RestTemplate restTemplate;
    private final ExternalApiProperties properties;
    
    @Override
    public ApiResponse sendRequest(ApiRequest request) {
        log.info("실제 외부 API 호출 시작 - URL: {}", properties.getUrl());
        
        try {
            // 1. 헤더 설정 (인증, Content-Type 등)
            HttpHeaders headers = new HttpHeaders();
            headers.setContentType(MediaType.APPLICATION_JSON);
            headers.set("Authorization", "Bearer " + properties.getApiKey());
            
            // 2. 요청 엔티티 구성
            HttpEntity<ApiRequest> entity = new HttpEntity<>(request, headers);
            
            // 3. 실제 API 호출
            ResponseEntity<ApiResponse> response = restTemplate.exchange(
                properties.getUrl(),
                HttpMethod.POST,
                entity,
                ApiResponse.class
            );
            
            // 4. 응답 검증
            if (response.getStatusCode().is2xxSuccessful() && response.getBody() != null) {
                log.info("외부 API 호출 성공 - resultCode: {}", 
                    response.getBody().getResultCode());
                return response.getBody();
            } else {
                throw new ExternalApiException("응답 데이터가 올바르지 않습니다.");
            }
            
        } catch (HttpClientErrorException e) {
            log.error("외부 API 클라이언트 오류 - status: {}, body: {}", 
                e.getStatusCode(), e.getResponseBodyAsString());
            throw new ExternalApiException("외부 API 클라이언트 오류", e);
            
        } catch (HttpServerErrorException e) {
            log.error("외부 API 서버 오류 - status: {}", e.getStatusCode());
            throw new ExternalApiException("외부 API 서버 오류", e);
            
        } catch (Exception e) {
            log.error("외부 API 호출 중 예외 발생", e);
            throw new ExternalApiException("외부 API 호출 실패", e);
        }
    }
    
    @Override
    public boolean healthCheck() {
        try {
            ResponseEntity<String> response = restTemplate.getForEntity(
                properties.getUrl() + "/health",
                String.class
            );
            return response.getStatusCode().is2xxSuccessful();
        } catch (Exception e) {
            log.warn("외부 API Health Check 실패", e);
            return false;
        }
    }
}
```

**구현 포인트:**
- 상세한 로깅으로 운영 모니터링 지원
- 예외 상황별 세분화된 에러 핸들링
- 인증 및 헤더 설정 포함
- Health Check 기능 제공

### 3단계: 로컬/개발 환경용 Mock 구현체

사전에 정의된 Mock Data를 반환하는 구현체를 작성한다.

```java
@Slf4j
@Component
@Profile({"local", "dev"})
public class MockExternalApiConnector implements ExternalApiConnector {
    
    private final Map<String, ApiResponse> mockDataStore = new ConcurrentHashMap<>();
    
    @PostConstruct
    public void init() {
        // Mock 데이터 초기화
        initSuccessScenario();
        initErrorScenarios();
    }
    
    @Override
    public ApiResponse sendRequest(ApiRequest request) {
        log.info("Mock Server 활성화 - 가상 데이터를 반환합니다.");
        log.debug("요청 데이터: {}", request);
        
        // 요청 타입에 따라 다른 Mock 데이터 반환
        ApiResponse response = mockDataStore.getOrDefault(
            request.getRequestType(),
            getDefaultSuccessResponse()
        );
        
        log.info("Mock 응답 반환 - resultCode: {}", response.getResultCode());
        log.debug("응답 데이터: {}", response);
        
        return response;
    }
    
    @Override
    public boolean healthCheck() {
        log.info("Mock Server Health Check - 항상 정상");
        return true;
    }
    
    /**
     * 정상 시나리오 Mock 데이터 초기화
     */
    private void initSuccessScenario() {
        // 사용자 조회 성공
        mockDataStore.put("USER_INQUIRY", ApiResponse.builder()
            .resultCode("SUCCESS")
            .message("사용자 조회 성공")
            .data(UserData.builder()
                .userId("TEST001")
                .userName("홍길동")
                .email("test@example.com")
                .status("ACTIVE")
                .build())
            .build());
        
        // 주문 생성 성공
        mockDataStore.put("ORDER_CREATE", ApiResponse.builder()
            .resultCode("SUCCESS")
            .message("주문 생성 성공")
            .data(OrderData.builder()
                .orderId("ORD20250106001")
                .orderDate(LocalDateTime.now())
                .totalAmount(50000)
                .status("PENDING")
                .build())
            .build());
    }
    
    /**
     * 오류 시나리오 Mock 데이터 초기화
     */
    private void initErrorScenarios() {
        // 사용자 없음
        mockDataStore.put("USER_NOT_FOUND", ApiResponse.builder()
            .resultCode("USER_NOT_FOUND")
            .message("사용자를 찾을 수 없습니다.")
            .build());
        
        // 권한 없음
        mockDataStore.put("UNAUTHORIZED", ApiResponse.builder()
            .resultCode("UNAUTHORIZED")
            .message("접근 권한이 없습니다.")
            .build());
        
        // 시스템 오류
        mockDataStore.put("SYSTEM_ERROR", ApiResponse.builder()
            .resultCode("SYSTEM_ERROR")
            .message("시스템 오류가 발생했습니다.")
            .build());
    }
    
    /**
     * 기본 성공 응답
     */
    private ApiResponse getDefaultSuccessResponse() {
        return ApiResponse.builder()
            .resultCode("SUCCESS")
            .message("테스트용 성공 데이터")
            .data(new DefaultData())
            .build();
    }
    
}
```

**Mock 구현의 핵심:**
- 다양한 시나리오별 Mock 데이터 준비
- 실제 API 명세에 부합하는 데이터 구조
- 정상/오류 케이스 모두 포함
- 로그를 통한 Mock 동작 명시

### 4단계: 비즈니스 로직에서의 활용

서비스 레이어는 **인터페이스에만 의존**하므로, 어떤 환경에서 실행되든 코드 수정 없이 로직 테스트가 가능하다.

```java
@Slf4j
@Service
@RequiredArgsConstructor
public class ExternalService {
    
    private final ExternalApiConnector apiConnector;
    private final OrderRepository orderRepository;
    
    /**
     * 외부 시스템과 연계하여 주문 처리
     */
    @Transactional
    public OrderResult processOrder(OrderRequest orderRequest) {
        log.info("주문 처리 시작 - orderNo: {}", orderRequest.getOrderNo());
        
        try {
            // 1. 요청 데이터 가공
            ApiRequest apiRequest = ApiRequest.builder()
                .requestType("ORDER_CREATE")
                .orderId(orderRequest.getOrderNo())
                .customerId(orderRequest.getCustomerId())
                .items(orderRequest.getItems())
                .totalAmount(orderRequest.getTotalAmount())
                .build();
            
            // 2. 외부 연계 (환경에 따라 Real 또는 Mock이 자동 주입됨)
            ApiResponse response = apiConnector.sendRequest(apiRequest);
            
            // 3. 응답 결과에 따른 후속 비즈니스 로직 처리
            if ("SUCCESS".equals(response.getResultCode())) {
                // 주문 정보 저장
                Order order = Order.builder()
                    .orderNo(orderRequest.getOrderNo())
                    .customerId(orderRequest.getCustomerId())
                    .status(OrderStatus.COMPLETED)
                    .externalOrderId(response.getData().getOrderId())
                    .build();
                
                orderRepository.save(order);
                
                log.info("주문 처리 완료 - orderNo: {}, externalOrderId: {}", 
                    orderRequest.getOrderNo(), response.getData().getOrderId());
                
                return OrderResult.success(order);
                
            } else {
                // 오류 처리
                log.warn("외부 시스템 오류 - resultCode: {}, message: {}", 
                    response.getResultCode(), response.getMessage());
                
                return OrderResult.failure(response.getResultCode(), response.getMessage());
            }
            
        } catch (ExternalApiException e) {
            log.error("외부 API 호출 실패", e);
            throw new BusinessException("주문 처리 중 오류가 발생했습니다.", e);
        }
    }
    
    /**
     * 사용자 정보 조회
     */
    public UserInfo getUserInfo(String userId) {
        log.info("사용자 정보 조회 - userId: {}", userId);
        
        ApiRequest request = ApiRequest.builder()
            .requestType("USER_INQUIRY")
            .userId(userId)
            .build();
        
        ApiResponse response = apiConnector.sendRequest(request);
        
        if ("SUCCESS".equals(response.getResultCode())) {
            UserData userData = (UserData) response.getData();
            return UserInfo.from(userData);
        } else if ("USER_NOT_FOUND".equals(response.getResultCode())) {
            throw new UserNotFoundException("사용자를 찾을 수 없습니다: " + userId);
        } else {
            throw new ExternalApiException("사용자 정보 조회 실패: " + response.getMessage());
        }
    }
}
```

**비즈니스 로직의 장점:**
- 외부 환경과 무관하게 동일한 코드로 동작
- 인터페이스에만 의존하여 결합도 낮음
- 테스트 용이성 확보
- 환경 전환 시 코드 수정 불필요

### 5단계: 설정 파일 구성

환경별로 다른 구현체가 주입되도록 설정한다.

**application-local.yml:**

```yaml
spring:
  profiles:
    active: local

external-api:
  enabled: false
  mock-enabled: true

logging:
  level:
    com.example.connector: DEBUG
```

**application-dev.yml:**

```yaml
spring:
  profiles:
    active: dev

external-api:
  enabled: false
  mock-enabled: true

logging:
  level:
    com.example.connector: INFO
```

**application-prod.yml:**

```yaml
spring:
  profiles:
    active: prod

external-api:
  enabled: true
  url: https://api.external-company.com
  api-key: ${EXTERNAL_API_KEY}
  timeout: 5000
  retry:
    max-attempts: 3
    backoff-delay: 1000

logging:
  level:
    com.example.connector: WARN
```

### 6단계: 테스트 코드 작성

Mock 구현체를 활용한 단위 테스트를 작성한다.

```java
@SpringBootTest
@ActiveProfiles("local") // Mock Connector 사용
class ExternalServiceTest {
    
    @Autowired
    private ExternalService externalService;
    
    @Autowired
    private ExternalApiConnector apiConnector;
    
    @Test
    @DisplayName("주문 처리 성공 테스트")
    void testProcessOrderSuccess() {
        // given
        OrderRequest request = OrderRequest.builder()
            .orderNo("ORD001")
            .customerId("CUST001")
            .items(List.of(
                new OrderItem("ITEM001", 2, 10000),
                new OrderItem("ITEM002", 1, 30000)
            ))
            .totalAmount(50000)
            .build();
        
        // when
        OrderResult result = externalService.processOrder(request);
        
        // then
        assertThat(result.isSuccess()).isTrue();
        assertThat(result.getOrder().getStatus()).isEqualTo(OrderStatus.COMPLETED);
    }
    
    @Test
    @DisplayName("사용자 정보 조회 성공 테스트")
    void testGetUserInfoSuccess() {
        // when
        UserInfo userInfo = externalService.getUserInfo("TEST001");
        
        // then
        assertThat(userInfo).isNotNull();
        assertThat(userInfo.getUserId()).isEqualTo("TEST001");
        assertThat(userInfo.getUserName()).isEqualTo("홍길동");
    }
    
    @Test
    @DisplayName("Mock Connector가 주입되었는지 확인")
    void testMockConnectorInjected() {
        assertThat(apiConnector).isInstanceOf(MockExternalApiConnector.class);
    }
}
```

---

## 성과 및 효과

### 1. 개발 연속성 확보

외부 업체의 환경 구축 여부와 관계없이 **로컬에서 비즈니스 로직의 Full-Cycle 테스트**가 가능해졌다.

**Before:**
```
개발 → 테스트 불가 → 대기 → 운영 배포 → 검증
       ↑____________병목 발생
```

**After:**
```
개발 → 로컬 테스트 → 개발 서버 테스트 → 운영 배포
       ↑___________즉시 검증 가능
```

### 2. 개발 생산성 향상

**측정 가능한 개선 지표:**

| 항목 | Before | After | 개선율 |
|------|--------|-------|--------|
| 로컬 테스트 가능 여부 | 불가 | 가능 | - |
| 개발 사이클 시간 | 3-5일 | 1일 | 60-80% 단축 |
| 운영 배포 전 검증 | 불가능 | 완전 검증 | 100% 개선 |
| 버그 발견 시점 | 운영 배포 후 | 개발 단계 | 조기 발견 |

### 3. 유연한 대응

외부 업체의 사양 변경 시, **Mock 데이터만 수정**하여 로직을 선제적으로 검증할 수 있는 환경을 구축했다.

**사양 변경 대응 프로세스:**
1. 외부 업체로부터 변경 명세 수령
2. Mock 데이터 즉시 업데이트
3. 로컬에서 영향도 분석 및 테스트
4. 비즈니스 로직 수정
5. 검증 완료 후 배포

### 4. 리스크 감소

**운영 배포 전 검증 가능 항목:**
- 응답 데이터 파싱 로직
- 다양한 응답 케이스 처리
- 에러 핸들링 로직
- 비즈니스 로직의 정합성
- 예외 상황 대응

---

## 향후 개선 계획

### 1. 전문 Mock Server 도입

현재는 내부 Mock 객체를 사용하지만, **규모가 커진다면** 전문 도구 활용을 계획한다.

**WireMock 도입 검토:**

```java
@SpringBootTest
@AutoConfigureWireMock(port = 8080)
class WireMockIntegrationTest {
    
    @Test
    void testWithWireMock() {
        // Stub 설정
        stubFor(post(urlEqualTo("/api/order"))
            .willReturn(aResponse()
                .withStatus(200)
                .withHeader("Content-Type", "application/json")
                .withBody("{\"resultCode\":\"SUCCESS\",\"message\":\"주문 성공\"}")));
        
        // 실제 HTTP 호출로 테스트
        ApiResponse response = apiConnector.sendRequest(request);
        
        assertThat(response.getResultCode()).isEqualTo("SUCCESS");
    }
}
```

**장점:**
- 실제 HTTP 통신 레이어까지 테스트
- 네트워크 오류, 타임아웃 등 시뮬레이션 가능
- 외부 팀과 Mock API 스펙 공유 가능

### 2. Mock 데이터 관리 고도화

**Mock Data를 외부 파일로 관리:**

```
src/
└── test/
    └── resources/
        └── mock/
            ├── user-inquiry-success.json
            ├── user-not-found.json
            ├── order-create-success.json
            └── system-error.json
```

```java
@Component
@Profile({"local", "dev"})
public class MockExternalApiConnector implements ExternalApiConnector {
    
    @Override
    public ApiResponse sendRequest(ApiRequest request) {
        String mockFile = getMockFilePath(request.getRequestType());
        return loadMockDataFromFile(mockFile);
    }
    
    private ApiResponse loadMockDataFromFile(String filePath) {
        try {
            String json = new String(Files.readAllBytes(Paths.get(filePath)));
            return objectMapper.readValue(json, ApiResponse.class);
        } catch (IOException e) {
            throw new MockDataLoadException("Mock 데이터 로드 실패", e);
        }
    }
}
```

---

## 최종 정리

### 핵심 원칙

1. **Interface 기반 설계**
   - 구현체가 아닌 인터페이스에 의존
   - 확장과 변경에 유연한 구조

2. **환경별 전략 분리**
   - Profile을 활용한 자동 주입
   - 설정만으로 환경 전환 가능

3. **Mock의 정확성**
   - 실제 API 명세와 일치하는 Mock 데이터
   - 다양한 시나리오 커버


### 적용 가이드

**이런 상황에 적합:**
- 외부 시스템 연계가 필요한 프로젝트
- 외부 업체의 개발 환경 제공이 어려운 경우
- 안정적인 로컬 개발 환경이 필요한 경우
- 외부 의존성으로 인한 테스트 어려움

**도입 시 고려사항:**
- Mock 데이터의 정확성 유지 필요
- 실제 API와 Mock의 동기화 관리
- 운영 배포 전 실제 환경 검증 필수
- 팀 내 Mock 사용 규칙 합의

### 마지막으로

외부 시스템과의 연계는 항상 불확실성을 동반한다.

하지만 **Interface 기반의 Mock Server 전략**을 통해 외부 의존성을 최소화하고, 안정적이고 생산적인 개발 환경을 구축할 수 있다.

중요한 것은 Mock이 **실제를 대체하는 것이 아니라, 개발 단계에서의 불확실성을 제거하는 도구**라는 점이다.

운영 배포 전에는 반드시 실제 환경에서의 검증을 수행하고, Mock 데이터를 실제 API 명세와 지속적으로 동기화하는 것이 성공적인 Mock Server 운영의 핵심이다.

---

## Reference

- [Spring Boot Profiles](https://docs.spring.io/spring-boot/docs/current/reference/html/features.html#features.profiles)

