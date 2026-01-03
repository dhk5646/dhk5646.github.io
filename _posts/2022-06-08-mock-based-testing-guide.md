---
title: "Mock을 활용한 테스트 코드 개선: 느리고 깨지는 테스트를 빠르고 안정적으로"
categories: java
tags: [java, spring, test, mock, mockito, unit-test, tdd]
excerpt: "Spring Context 로드로 인한 느린 테스트와 DB 의존성으로 인한 불안정한 테스트를 Mock 기반 테스트로 개선하여 지속 가능한 테스트 환경을 구축한 실전 경험"
---

## 들어가며

스프링부트 환경에서 MVC 패턴으로 서비스를 운영하면서, **테스트 코드를 통해 시스템을 더욱 견고하게 관리**하고자 노력했다.

하지만 시간이 지날수록 다음과 같은 문제들이 발생했다:

- 테스트 코드 하나 실행하는 데 **1분 이상** 소요
- 개발 DB 데이터 변경으로 인한 **잦은 테스트 실패**
- 결국 테스트 코드 작성과 실행을 **기피**하게 됨

이 글에서는 **Mock을 활용하여 테스트 코드를 개선**하고, 지속 가능한 테스트 환경을 구축한 경험을 공유한다.

---

## 문제 상황

### 1. 테스트 코드 실행 속도의 저하

**초기 상황:**
```
개발 초기: 테스트 실행 시간 5-10초
프로젝트 성장 후: 테스트 실행 시간 60초 이상
```

**원인:**

**Spring Context 로드 시간 증가**
```
초기 프로젝트:
- Bean 개수: 50개
- Context 로드: 3초

성장한 프로젝트:
- Bean 개수: 500개
- Context 로드: 40초
```

**컴파일 시간 증가**
- 클래스 파일 증가
- 의존성 라이브러리 증가
- 빌드 도구 오버헤드

**결과:**

간단한 로직 하나를 검증하기 위해 1분 이상 기다려야 하는 상황.

```java
@Test
void 간단한_검증() {
    // 이 한 줄을 확인하기 위해 1분 대기...
    assertEquals("expected", service.getSomething());
}
```

**개발자의 심리:**
```
테스트 작성 → 실행 → 1분 대기 → 수정 → 다시 실행 → 1분 대기 → ...
"차라리 수동으로 확인하고 말지..."
```

### 2. 테스트 코드의 높은 취약성

**문제 상황:**

서비스 계층 테스트를 **개발 DB와 연결**하여 실행했다.

```java
@SpringBootTest
public class OccupantServiceTest {
    
    @Autowired
    private OccupantMoveInService occupantMoveInService;
    
    @Test
    void 입주자_등록_테스트() {
        // 개발 DB에 직접 저장
        Occupant occupant = occupantMoveInService.moveIn(...);
        assertNotNull(occupant);
    }
}
```

**발생한 문제들:**

**1) 데이터 중복으로 인한 실패**
```
첫 실행: 성공 ✓
두 번째 실행: 실패 ✗
Caused by: SQLIntegrityConstraintViolationException: 
Duplicate entry '1동-101호' for key 'uk_dong_ho'
```

**2) 예상하지 못한 데이터**
```java
@Test
void 입주자_수_조회() {
    // 예상: 5명
    int count = occupantService.getCount("1동");
    assertEquals(5, count);
    
    // 실제: 다른 개발자가 데이터 추가 → 7명
    // 테스트 실패!
}
```

**3) 데이터 의존성**
```java
@Test
void 특정_입주자_조회() {
    // ID=1인 입주자가 있다고 가정
    Occupant occupant = occupantService.findById(1L);
    assertNotNull(occupant);
    
    // 누군가 DB 초기화 → ID=1 삭제됨
    // 테스트 실패!
}
```

**4) 트랜잭션 격리 수준 이슈**

동시에 여러 테스트를 실행하면 데이터 충돌 발생.

**결과:**

"테스트가 자주 깨지니까 믿을 수 없어..."
"테스트 실패 = 코드 문제인지, DB 문제인지 구분 불가"

---

## 기존 코드의 문제점

### [AS-IS] @SpringBootTest 기반 테스트

```java
@SpringBootTest
public class OccupantServiceTest {

    @Autowired
    private OccupantMoveInService occupantMoveInService;

    @Test
    @DisplayName("새로운 입주자가 입주한다.")
    void testCase1() {
        
        // given
        OccupantDto occupantDto = OccupantDto.of(
            "잠실 1단지", "1동", "101호", "동구리"
        );
        
        // when
        Occupant 신규_입주자 = occupantMoveInService.moveIn(occupantDto);

        // then
        assertNotNull(신규_입주자);
    }
}
```

### 문제점 분석

**1. @SpringBootTest의 무거움**

```
테스트 실행 시퀀스:
1. Spring Application Context 로드 (40초)
2. 모든 Bean 초기화
   - Controller (불필요)
   - Service (필요)
   - Repository (불필요 - DB 직접 접근)
   - 외부 API 클라이언트 (불필요)
   - 스케줄러 (불필요)
3. 실제 테스트 실행 (1초)
4. Context 정리

총 소요 시간: 60초
실제 필요한 시간: 1초
```

**2. 실제 DB 의존성**

```
개발 DB ──연결──> Spring Context ──주입──> Test Code

문제:
- DB 데이터 변경 시 테스트 실패
- 중복 데이터로 제약 조건 위반
- 트랜잭션 롤백 누락 시 잔여 데이터 축적
```

**3. 테스트 격리 실패**

```
Test A: 1동 101호 입주자 등록
Test B: 1동 101호 입주자 조회

순서:
A → B: 성공 ✓
B → A: A 실패 (이미 존재) ✗
```

테스트 순서에 따라 결과가 달라짐.

**4. 무엇을 테스트하는가?**

```java
Occupant 신규_입주자 = occupantMoveInService.moveIn(occupantDto);
assertNotNull(신규_입주자);
```

이 테스트는 무엇을 검증하는가?

- 서비스 로직? (일부)
- DB 저장? (Yes)
- JPA 설정? (Yes)
- 트랜잭션 관리? (Yes)
- 네트워크 연결? (Yes)

**단위 테스트가 아닌 통합 테스트**가 되어버렸다.

---

## 해결 방법: Mock 활용

### Mock이란?

**Mock 객체:**
- 실제 객체를 **모방(Mocking)**한 가짜 객체
- 미리 정의된 동작만 수행
- 외부 의존성(DB, 네트워크, 파일 시스템 등) 제거

**개념:**

```
실제 환경:
Service → Repository → DB

Mock 환경:
Service → Mock Repository (가짜, 동작을 미리 정의)
```

### [TO-BE] Mock 기반 테스트

```java
@ExtendWith(MockitoExtension.class)  // JUnit 5
public class OccupantServiceTest {

    @InjectMocks
    private OccupantMoveInService occupantMoveInService;

    @Mock
    private OccupantRepository occupantRepository;

    @Test
    @DisplayName("새로운 입주자가 입주한다.")
    void testCase1() {

        // given
        OccupantDto occupantDto = OccupantDto.of(
            "잠실 1단지", "1동", "101호", "동구리"
        );
        Occupant occupant = createOccupant(occupantDto);
        
        // mocking: Repository 동작 정의
        when(occupantRepository.existsByComplexAndDongAndHo(
            any(), any(), any()
        )).thenReturn(false);
        
        when(occupantRepository.save(any())).thenReturn(occupant);

        // when
        Occupant 신규_입주자 = occupantMoveInService.moveIn(occupantDto);

        // then
        assertNotNull(신규_입주자);
        assertEquals("동구리", 신규_입주자.getName());
        
        // verify: Repository 메서드가 호출되었는지 검증
        verify(occupantRepository, times(1)).existsByComplexAndDongAndHo(
            any(), any(), any()
        );
        verify(occupantRepository, times(1)).save(any());
    }

    private Occupant createOccupant(OccupantDto occupantDto) {
        return Occupant.create(occupantDto);
    }
}
```

### 개선된 점

**1. Spring Context 로드 제거**

```
Before:
테스트 실행 시간: 60초
- Context 로드: 40초
- 실제 테스트: 1초

After:
테스트 실행 시간: 1초 이하
- Context 로드: 0초
- 실제 테스트: 1초

개선율: 60배 빠름
```

**2. DB 의존성 제거**

```
Before:
Test → Spring Context → Repository → DB

After:
Test → Service → Mock Repository (가짜)
```

DB 데이터와 무관하게 **일관된 결과** 보장.

**3. 테스트 격리**

```
각 테스트마다 새로운 Mock 객체 생성
→ 테스트 간 영향 없음
→ 실행 순서 무관
```

**4. 명확한 검증 대상**

```java
// 서비스 로직만 검증
when(occupantRepository.save(any())).thenReturn(occupant);

Occupant 신규_입주자 = occupantMoveInService.moveIn(occupantDto);

// 검증:
// 1. DTO → Entity 변환 로직
// 2. 비즈니스 로직 (중복 체크, 유효성 검증)
// 3. Repository 호출 여부
```

---

## Mock 기반 테스트의 장점

### 1. 테스트 속도 개선

**측정 결과:**

```
@SpringBootTest 기반:
- 개별 테스트: 60초
- 10개 테스트: 10분

Mock 기반:
- 개별 테스트: 0.5초
- 10개 테스트: 5초

개선율: 120배
```

**개발자 경험 개선:**

```
Before:
"테스트 하나 돌리는데 1분? 그냥 안 돌리지..."

After:
"0.5초? 자주 돌려서 확인하자!"
```

### 2. 테스트 안정성 확보

**DB 변경에 독립적:**

```java
// DB에 어떤 데이터가 있든 상관없음
when(occupantRepository.findById(1L))
    .thenReturn(Optional.of(occupant));

// 항상 동일한 결과
```

**환경에 독립적:**

```
로컬, 개발, 스테이징, 운영 어디서든 동일한 결과
```

### 3. 기능 검증의 최소 요건 충족

**검증 가능한 항목:**

**1) 비즈니스 로직**
```java
@Test
void 중복_입주자_검증() {
    // given
    when(occupantRepository.existsByComplexAndDongAndHo(
        any(), any(), any()
    )).thenReturn(true);  // 이미 존재
    
    // when & then
    assertThrows(DuplicateOccupantException.class, () -> {
        occupantMoveInService.moveIn(occupantDto);
    });
}
```

**2) 메서드 호출 여부**
```java
verify(occupantRepository, times(1)).save(any());
verify(occupantRepository, never()).delete(any());
```

**3) 메서드 호출 순서**
```java
InOrder inOrder = inOrder(occupantRepository);
inOrder.verify(occupantRepository).existsByComplexAndDongAndHo(...);
inOrder.verify(occupantRepository).save(...);
```

**4) 올바른 인자 전달**
```java
ArgumentCaptor<Occupant> captor = ArgumentCaptor.forClass(Occupant.class);
verify(occupantRepository).save(captor.capture());

Occupant saved = captor.getValue();
assertEquals("동구리", saved.getName());
assertEquals("1동", saved.getDong());
```

### 4. 문서로서의 역할

**테스트 코드는 살아있는 문서:**

```java
@Test
@DisplayName("입주자는 동일한 동호수에 중복으로 등록할 수 없다")
void 중복_입주자_방지() {
    // given: 이미 1동 101호에 입주자가 있음
    when(occupantRepository.existsByComplexAndDongAndHo(
        "잠실 1단지", "1동", "101호"
    )).thenReturn(true);
    
    // when: 동일한 동호수에 새로운 입주자 등록 시도
    // then: 예외 발생
    assertThrows(DuplicateOccupantException.class, () -> {
        occupantMoveInService.moveIn(occupantDto);
    });
}
```

**효과:**
- 기획 요구사항이 코드로 표현됨
- 다른 개발자가 의도를 이해하기 쉬움
- 인수인계 시 도움

---

## 실전 적용 가이드

### Mock 작성 패턴

**기본 패턴: given-when-then**

```java
@Test
void 테스트_이름() {
    // given: 테스트 전제 조건
    // - 테스트 데이터 준비
    // - Mock 동작 정의
    
    // when: 테스트 대상 실행
    // - 실제로 테스트할 메서드 호출
    
    // then: 결과 검증
    // - 반환값 확인
    // - 상태 변화 확인
    // - 메서드 호출 확인
}
```

**예시:**

```java
@Test
@DisplayName("입주자 정보를 수정한다")
void updateOccupant() {
    // given
    Long occupantId = 1L;
    Occupant existingOccupant = Occupant.builder()
        .id(occupantId)
        .name("홍길동")
        .build();
    
    OccupantDto updateDto = OccupantDto.of(
        "잠실 1단지", "2동", "202호", "김철수"
    );
    
    when(occupantRepository.findById(occupantId))
        .thenReturn(Optional.of(existingOccupant));
    when(occupantRepository.save(any()))
        .thenAnswer(invocation -> invocation.getArgument(0));
    
    // when
    Occupant updated = occupantService.update(occupantId, updateDto);
    
    // then
    assertNotNull(updated);
    assertEquals("김철수", updated.getName());
    assertEquals("2동", updated.getDong());
    
    verify(occupantRepository).findById(occupantId);
    verify(occupantRepository).save(any());
}
```

### 다양한 Mocking 기법

**1. 반환값 정의**

```java
// 단순 반환
when(repository.findById(1L))
    .thenReturn(Optional.of(occupant));

// 예외 발생
when(repository.findById(1L))
    .thenThrow(new EntityNotFoundException());

// 연속 호출 시 다른 값 반환
when(repository.findAll())
    .thenReturn(List.of(occupant1))  // 첫 호출
    .thenReturn(List.of(occupant1, occupant2));  // 두 번째 호출

// 인자에 따라 다른 값 반환
when(repository.findById(1L))
    .thenReturn(Optional.of(occupant1));
when(repository.findById(2L))
    .thenReturn(Optional.of(occupant2));
```

**2. 인자 매처 활용**

```java
// any(): 모든 인자
when(repository.save(any())).thenReturn(occupant);

// anyString(), anyInt() 등: 타입별
when(repository.findByName(anyString())).thenReturn(occupant);

// eq(): 특정 값
when(repository.findByName(eq("홍길동"))).thenReturn(occupant);

// argThat(): 조건 검증
when(repository.save(argThat(o -> o.getName().equals("홍길동"))))
    .thenReturn(occupant);
```

**3. Answer로 동적 처리**

```java
// 전달받은 인자를 그대로 반환
when(repository.save(any()))
    .thenAnswer(invocation -> invocation.getArgument(0));

// 복잡한 로직
when(repository.save(any()))
    .thenAnswer(invocation -> {
        Occupant arg = invocation.getArgument(0);
        arg.setId(1L);  // ID 자동 생성 시뮬레이션
        return arg;
    });
```

**4. void 메서드 Mocking**

```java
// 아무것도 안 함 (기본)
doNothing().when(repository).delete(any());

// 예외 발생
doThrow(new RuntimeException()).when(repository).delete(any());
```

### 검증 기법

**1. 호출 횟수 검증**

```java
// 정확히 1번
verify(repository, times(1)).save(any());

// 한 번도 호출 안 됨
verify(repository, never()).delete(any());

// 최소 1번
verify(repository, atLeastOnce()).findById(any());

// 최대 2번
verify(repository, atMost(2)).findAll();
```

**2. 인자 검증**

```java
// ArgumentCaptor로 전달된 인자 캡처
ArgumentCaptor<Occupant> captor = 
    ArgumentCaptor.forClass(Occupant.class);
verify(repository).save(captor.capture());

Occupant captured = captor.getValue();
assertEquals("홍길동", captured.getName());
```

**3. 호출 순서 검증**

```java
InOrder inOrder = inOrder(repository);
inOrder.verify(repository).findById(1L);
inOrder.verify(repository).save(any());
```

---

## 실전 시나리오

### 시나리오 1: 복잡한 비즈니스 로직

```java
public class OccupantMoveOutService {
    
    private final OccupantRepository occupantRepository;
    private final ContractRepository contractRepository;
    private final PaymentService paymentService;
    
    public void moveOut(Long occupantId) {
        // 1. 입주자 조회
        Occupant occupant = occupantRepository.findById(occupantId)
            .orElseThrow(() -> new OccupantNotFoundException());
        
        // 2. 미납금 확인
        if (paymentService.hasUnpaidAmount(occupantId)) {
            throw new UnpaidAmountException();
        }
        
        // 3. 계약 종료
        contractRepository.terminateByOccupantId(occupantId);
        
        // 4. 입주자 상태 변경
        occupant.moveOut();
        occupantRepository.save(occupant);
    }
}
```

**테스트 코드:**

```java
@ExtendWith(MockitoExtension.class)
class OccupantMoveOutServiceTest {
    
    @InjectMocks
    private OccupantMoveOutService moveOutService;
    
    @Mock
    private OccupantRepository occupantRepository;
    
    @Mock
    private ContractRepository contractRepository;
    
    @Mock
    private PaymentService paymentService;
    
    @Test
    @DisplayName("입주자가 정상적으로 퇴거한다")
    void moveOut_success() {
        // given
        Long occupantId = 1L;
        Occupant occupant = Occupant.builder()
            .id(occupantId)
            .status(OccupantStatus.ACTIVE)
            .build();
        
        when(occupantRepository.findById(occupantId))
            .thenReturn(Optional.of(occupant));
        when(paymentService.hasUnpaidAmount(occupantId))
            .thenReturn(false);
        
        // when
        moveOutService.moveOut(occupantId);
        
        // then
        assertEquals(OccupantStatus.MOVED_OUT, occupant.getStatus());
        
        // 올바른 순서로 호출되었는지 검증
        InOrder inOrder = inOrder(
            occupantRepository, 
            paymentService, 
            contractRepository
        );
        inOrder.verify(occupantRepository).findById(occupantId);
        inOrder.verify(paymentService).hasUnpaidAmount(occupantId);
        inOrder.verify(contractRepository).terminateByOccupantId(occupantId);
        inOrder.verify(occupantRepository).save(occupant);
    }
    
    @Test
    @DisplayName("미납금이 있으면 퇴거할 수 없다")
    void moveOut_unpaidAmount() {
        // given
        Long occupantId = 1L;
        Occupant occupant = Occupant.builder()
            .id(occupantId)
            .status(OccupantStatus.ACTIVE)
            .build();
        
        when(occupantRepository.findById(occupantId))
            .thenReturn(Optional.of(occupant));
        when(paymentService.hasUnpaidAmount(occupantId))
            .thenReturn(true);  // 미납금 있음
        
        // when & then
        assertThrows(UnpaidAmountException.class, () -> {
            moveOutService.moveOut(occupantId);
        });
        
        // 계약 종료가 호출되지 않았는지 확인
        verify(contractRepository, never()).terminateByOccupantId(any());
        verify(occupantRepository, never()).save(any());
    }
}
```

### 시나리오 2: 외부 API 호출

```java
public class WeatherService {
    
    private final WeatherApiClient weatherApiClient;
    
    public WeatherInfo getWeatherInfo(String location) {
        try {
            WeatherResponse response = 
                weatherApiClient.fetchWeather(location);
            return WeatherInfo.from(response);
        } catch (ApiException e) {
            throw new WeatherServiceException("날씨 정보 조회 실패", e);
        }
    }
}
```

**테스트 코드:**

```java
@ExtendWith(MockitoExtension.class)
class WeatherServiceTest {
    
    @InjectMocks
    private WeatherService weatherService;
    
    @Mock
    private WeatherApiClient weatherApiClient;
    
    @Test
    @DisplayName("날씨 정보를 정상적으로 조회한다")
    void getWeatherInfo_success() {
        // given
        String location = "서울";
        WeatherResponse response = WeatherResponse.builder()
            .temperature(25.0)
            .humidity(60)
            .build();
        
        when(weatherApiClient.fetchWeather(location))
            .thenReturn(response);
        
        // when
        WeatherInfo info = weatherService.getWeatherInfo(location);
        
        // then
        assertNotNull(info);
        assertEquals(25.0, info.getTemperature());
        assertEquals(60, info.getHumidity());
    }
    
    @Test
    @DisplayName("외부 API 오류 시 예외를 발생시킨다")
    void getWeatherInfo_apiError() {
        // given
        String location = "서울";
        when(weatherApiClient.fetchWeather(location))
            .thenThrow(new ApiException("API 오류"));
        
        // when & then
        assertThrows(WeatherServiceException.class, () -> {
            weatherService.getWeatherInfo(location);
        });
    }
}
```

---

## Mock의 한계와 보완 방법

### Mock 테스트의 한계

**1. 실제 동작을 검증하지 못함**

```java
// Mock 테스트
when(repository.save(any())).thenReturn(occupant);

// 실제로는:
// - DB 제약 조건 위반 가능
// - JPA 영속성 컨텍스트 이슈 가능
// - 트랜잭션 문제 가능
```

**2. 통합 지점의 문제 발견 불가**

```
Service ←→ Repository ←→ DB

Mock 테스트: Service 로직만 검증
놓치는 부분: Repository ←→ DB 통합
```

**3. 과도한 Mocking의 위험**

```java
// 나쁜 예: Mock이 너무 많음
@Mock private RepositoryA repositoryA;
@Mock private RepositoryB repositoryB;
@Mock private RepositoryC repositoryC;
@Mock private ServiceA serviceA;
@Mock private ServiceB serviceB;
@Mock private ClientA clientA;
@Mock private ClientB clientB;

// 테스트가 구현에 너무 의존적
```

### 보완 방법

**1. 통합 테스트와 병행**

```
단위 테스트 (Mock 기반):
- 빠름
- 개별 로직 검증
- 자주 실행

통합 테스트 (@SpringBootTest):
- 느림
- 전체 흐름 검증
- 배포 전 실행
```

**2. 테스트 피라미드**

```
          /\
         /  \  E2E 테스트 (소수)
        /____\
       /      \
      / 통합    \
     / 테스트   \
    /____(중간)__\
   /              \
  /  단위 테스트    \
 /    (Mock)       \
/___________________ \ (다수)
```

**3. 핵심 흐름은 통합 테스트**

```java
// 핵심 시나리오는 실제 DB로 검증
@SpringBootTest
@Transactional
class OccupantIntegrationTest {
    
    @Test
    void 입주부터_퇴거까지_전체_흐름() {
        // 실제 DB에 저장하고 조회하며 검증
    }
}
```

---

## 개인적인 고민과 답

### 고민: "Mock 기반 테스트는 의미가 있을까?"

**의문:**
- Mock은 가짜 객체인데 의미가 있나?
- 실제 DB를 테스트하지 않으면 버그를 못 잡는 거 아닌가?
- 결국 통합 테스트를 해야 하는 거 아닌가?

### 답: "의미가 있다"

**1. 최소한의 검증**

```java
// 이것만으로도 많은 버그를 잡을 수 있다
- DTO → Entity 변환 로직
- 비즈니스 규칙 (중복 체크, 유효성 검증)
- 예외 처리
- 메서드 호출 순서
```

**2. 빠른 피드백**

```
1초 안에 버그 발견 > 10분 후 버그 발견
```

**3. 지속 가능성**

```
느리고 깨지는 테스트 → 아무도 안 돌림 → 의미 없음
빠르고 안정적인 테스트 → 자주 돌림 → 버그 조기 발견
```

**4. 문서로서의 가치**

```java
@Test
@DisplayName("입주자는 동일한 동호수에 중복 등록할 수 없다")
void test() { /* ... */ }

// 이 테스트만 보고도 비즈니스 규칙을 이해 가능
```

### 실용적인 접근

**균형잡힌 테스트 전략:**

```
단위 테스트 (Mock): 80%
- 빠른 피드백
- 개별 로직 검증
- 자주 실행 (저장 시, PR 시)

통합 테스트: 15%
- 핵심 시나리오 검증
- DB, 외부 API 통합 검증
- 배포 전 실행

E2E 테스트: 5%
- 주요 사용자 시나리오
- 스테이징 환경
- 정기적으로 실행
```

---

## 정리

### 핵심 요약

**1. 문제 상황**
- @SpringBootTest: 느림 (60초)
- 실제 DB 의존: 불안정함 (자주 깨짐)
- 결과: 테스트 기피

**2. 해결 방법**
- Mock 기반 테스트
- Spring Context 제거
- DB 의존성 제거

**3. 개선 효과**
- 속도: 60초 → 1초 (60배)
- 안정성: 일관된 결과
- 지속 가능성: 자주 실행 가능

**4. Mock의 가치**
- 빠른 피드백
- 최소한의 검증
- 문서로서의 역할
- 지속 가능한 테스트 환경

### 실전 적용 체크리스트

**Mock 테스트 작성 시:**

- [ ] @SpringBootTest 대신 @ExtendWith(MockitoExtension.class)
- [ ] 외부 의존성(Repository, Client 등)은 @Mock
- [ ] 테스트 대상은 @InjectMocks
- [ ] given-when-then 패턴 사용
- [ ] Mock 동작 정의 (when-thenReturn)
- [ ] 결과 검증 (assertEquals, verify)
- [ ] 테스트 이름은 명확하게 (@DisplayName)

**균형잡힌 테스트 전략:**

- [ ] 단위 테스트 (Mock): 많이 작성
- [ ] 통합 테스트: 핵심 시나리오만
- [ ] E2E 테스트: 주요 흐름만
- [ ] 빠른 테스트를 자주 실행
- [ ] 느린 테스트는 배포 전 실행

### 마지막으로

**테스트 코드의 가치는 "얼마나 자주 실행되느냐"에 달려있다.**

느리고 깨지는 테스트는 아무도 실행하지 않고, 결국 의미가 없다.

Mock을 활용하여 **빠르고 안정적인 테스트**를 만들고, **자주 실행**하여 버그를 조기에 발견하자.

**완벽한 테스트보다 지속 가능한 테스트가 더 가치 있다.**

---


