---
title: "Spring Boot + Ehcache로 데이터베이스 부하 줄이기"
categories: java
tags: [spring, ehcache, cache, performance, optimization]
excerpt: "공통코드와 대시보드 캐싱으로 데이터베이스 부하를 줄이고 성능을 개선한 실전 사례"
---

## 들어가며

애플리케이션을 운영하다 보면 **동일한 데이터를 반복적으로 조회**하는 경우가 많다.

특히 다음과 같은 상황에서 문제가 발생한다:
- 변경이 거의 없는 데이터를 매번 DB 조회
- 짧은 주기로 반복 조회되는 대시보드
- 높은 트래픽으로 인한 DB 부하

이 글에서는 **Ehcache를 활용하여 데이터베이스 부하를 줄이고 성능을 개선**한 실전 사례를 공유한다.

---

## Ehcache란?

Ehcache 공식 사이트에서는 다음과 같이 소개하고 있다:

> Ehcache는 가장 널리 사용되는 Java 기반 캐시로, 성능을 향상시키고 데이터베이스 부하를 줄이며 확장성을 간소화하는 데 사용되는 오픈 소스 및 표준 기반의 캐시이다.

### 동작 방식

**Before (캐시 없음):**
```
사용자 요청 → 애플리케이션 → 데이터베이스
                              ↑
                        매번 DB 조회
```

**After (캐시 적용):**
```
사용자 요청 → 애플리케이션 (캐시 확인)
                ↓ (캐시 Hit)
            캐시된 데이터 반환
                
                ↓ (캐시 Miss)
            데이터베이스 → 캐시 저장 → 반환
```

### 주요 특징

**1. 메모리 캐싱**
- 데이터를 메모리에 캐시하여 성능 향상
- DB나 외부 서비스 조회 시간 단축

**2. 다양한 캐시 설정**
- 캐시 크기, 만료 정책, 메모리 사용량 조절 가능
- TTL(Time To Live) 설정

**3. 다양한 저장소 지원**
- Heap: JVM 힙 메모리
- Off-Heap: JVM 외부 메모리
- Disk: 디스크 저장

---

## Ehcache 적용 케이스

다음과 같은 경우에 Ehcache 적용을 고려할 수 있다:

1. **요청 빈도가 높은 경우**
2. **변경 빈도가 낮은 데이터**
3. **부하가 큰 요청 처리**

---

## 적용 사례 1: 공통코드 캐싱

### 문제 상황

차량 관제 시스템을 운영할 당시, 다음과 같은 문제가 있었다:

```java
// 화면 로딩 시마다 공통코드 조회
@GetMapping("/common-codes")
public List<CommonCode> getCommonCodes() {
    return commonCodeRepository.findAll();  // 매번 DB 조회!
}
```

**문제점:**
- 화면이 열릴 때마다 공통코드 조회 API 호출
- 공통코드는 변경이 거의 없는데도 매번 DB 조회
- 하루 화면 오픈 횟수: **약 1,300회**

### 해결 방법

**Ehcache 적용:**

```java
@Service
@RequiredArgsConstructor
public class CommonCodeService {
    
    private final CommonCodeRepository commonCodeRepository;
    
    // 캐시 적용
    @Cacheable(cacheNames = "commonCodeCache", key = "'all'")
    public List<CommonCode> getAllCommonCodes() {
        return commonCodeRepository.findAll();
    }
}
```

**캐시 설정:**

```java
private CacheConfiguration<String, List<CommonCode>> createCommonCodeCache() {
    return CacheConfigurationBuilder
        .newCacheConfigurationBuilder(
            String.class,
            List.class,
            ResourcePoolsBuilder.heap(10L))
        .withExpiry(ExpiryPolicyBuilder.timeToLiveExpiration(Duration.ofMinutes(30)))
        .build();
}
```

### 성과

**정량적 성과 (연간 기준):**

```
화면 오픈: 1,300회/일
쿼리 성능: 1ms
캐시 적용 후: 첫 조회만 DB 접근

연간 절감:
- DB 조회 횟수: 1,300회/일 × 365일 = 474,500회 → 365회
- 절감 시간: 474,500ms = 7.9분
```

**부수적 효과:**
- DB 커넥션 풀 여유 증가
- DB 부하 감소로 다른 쿼리 성능 개선
- 네트워크 트래픽 감소

---

## 적용 사례 2: 대시보드 캐싱

### 문제 상황

물류센터의 도크(Dock) 예약 관리 시스템을 운영할 당시:

```javascript
// 대시보드: 5분마다 자동 조회
setInterval(() => {
    fetch('/api/dashboard/dock-status')
        .then(response => response.json())
        .then(data => updateDashboard(data));
}, 300000);  // 5분 = 300,000ms
```

**문제점:**
- 사업 확장으로 물류센터 증가
- 각 센터마다 대시보드 디바이스 운영
- **100개 디바이스 × 288회/일 = 28,800회/일**
- DB 부하 급증

**도크(Dock)란?**
- 물류센터에서 차량 적재를 위한 수평 이동 시설
- 창고 안에서 차량으로 직접 물품 적재 가능

### 해결 방법

**서비스 레이어에 캐시 적용:**

```java
@Service
@RequiredArgsConstructor
public class DashboardService {
    
    private final DockReservationRepository dockReservationRepository;
    
    // 5분 TTL 캐시
    @Cacheable(cacheNames = "dashboardCache", key = "'dockStatus'")
    public DockStatusResponse getDockStatus() {
        // 복잡한 조회 쿼리 (Join, 집계 등)
        return dockReservationRepository.findDockStatusWithReservations();
    }
}
```

**캐시 설정:**

```java
private CacheConfiguration<String, DockStatusResponse> createDashboardCache() {
    return CacheConfigurationBuilder
        .newCacheConfigurationBuilder(
            String.class,
            DockStatusResponse.class,
            ResourcePoolsBuilder.heap(1L))  // 1개만 유지
        .withExpiry(ExpiryPolicyBuilder.timeToLiveExpiration(Duration.ofMinutes(5)))
        .withDispatcherConcurrency(2)
        .build();
}
```

### 성과

**정량적 성과 (월간 기준):**

```
디바이스 수: 100개
호출 주기: 5분 (하루 288회)
월간 호출: 100 × 288 × 30 = 864,000회

캐시 적용 후:
- DB 조회: 8,640회 (5분마다 1회만 DB 조회)
- 절감률: 99% 감소
```

**부수적 효과:**
- DB 커넥션 타임아웃 해소
- 대시보드 응답 속도 개선 (평균 500ms → 10ms)
- 사업 확장에도 안정적 운영 가능

---

## Spring Boot에서 Ehcache 적용하기

실제 코드로 Ehcache를 적용하는 방법을 알아보자.

전체 코드는 [GitHub](https://github.com/dhk5646/study/pull/1)에서 확인 가능하다.

**개발 환경:**
- Java 17
- Spring Boot 3.2.4
- Gradle

### 1단계: 의존성 추가

**build.gradle:**

```gradle
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-web'
    
    // Ehcache 의존성
    implementation 'org.springframework.boot:spring-boot-starter-cache'
    implementation 'org.ehcache:ehcache:3.10.0'
    
    compileOnly 'org.projectlombok:lombok'
    annotationProcessor 'org.projectlombok:lombok'
}
```

**spring-boot-starter-cache:**
- Spring Framework의 캐시 추상화 제공
- `@Cacheable`, `@CachePut`, `@CacheEvict` 등 어노테이션 사용 가능

### 2단계: Ehcache 설정

**EhcacheConfig.java:**

```java
@EnableCaching  // 캐싱 활성화
@Configuration
public class EhcacheConfig {

    @Bean
    public CacheManager cacheManager() {
        // Ehcache 제공자 생성
        EhcacheCachingProvider provider = (EhcacheCachingProvider) Caching.getCachingProvider();
        
        // 캐시 설정 맵 생성
        Map<String, CacheConfiguration<?, ?>> cacheConfigMap = getCacheConfigurationMap();
        
        // Ehcache 기본 설정
        DefaultConfiguration config = new DefaultConfiguration(
            cacheConfigMap, 
            provider.getDefaultClassLoader()
        );
        
        // JCache Manager 생성
        javax.cache.CacheManager cacheManager = provider.getCacheManager(
            provider.getDefaultURI(), 
            config
        );
        
        // Spring CacheManager로 변환
        return new JCacheCacheManager(cacheManager);
    }

    private Map<String, CacheConfiguration<?, ?>> getCacheConfigurationMap() {
        Map<String, CacheConfiguration<?, ?>> cacheMap = new HashMap<>();
        
        // Person 캐시 등록
        cacheMap.put("personCache", createPersonCache());
        
        return cacheMap;
    }

    private CacheConfiguration<String, Person> createPersonCache() {
        return CacheConfigurationBuilder
            .newCacheConfigurationBuilder(
                String.class,
                Person.class,
                ResourcePoolsBuilder.heap(10L))  // 최대 10개 엔트리
            .withExpiry(new DefaultExpiry())     // 5분 TTL
            .withDispatcherConcurrency(2)        // 동시 처리
            .withDefaultEventListenersThreadPool()
            .withService(getCacheEventListenerConfig())
            .build();
    }
    
    private CacheEventListenerConfigurationBuilder getCacheEventListenerConfig() {
        return CacheEventListenerConfigurationBuilder
            .newEventListenerConfiguration(
                new EhcacheEventListener(),
                EventType.CREATED,
                EventType.UPDATED,
                EventType.EXPIRED,
                EventType.REMOVED
            )
            .unordered()
            .asynchronous();
    }
}
```

**@EnableCaching의 역할:**
- Spring 캐싱 기능 활성화
- 캐시 관련 어노테이션 사용 가능
- 캐시 관련 빈 자동 구성

### 3단계: 만료 정책 설정

**DefaultExpiry.java:**

```java
public class DefaultExpiry implements ExpiryPolicy<String, Person> {

    private static final Duration DEFAULT_DURATION = Duration.ofMinutes(5);

    @Override
    public Duration getExpiryForCreation(String key, Person value) {
        return DEFAULT_DURATION;  // 생성 시 5분
    }

    @Override
    public Duration getExpiryForAccess(String key, Supplier<? extends Person> value) {
        return DEFAULT_DURATION;  // 조회 시 5분 연장
    }

    @Override
    public Duration getExpiryForUpdate(String key, Supplier<? extends Person> oldValue, Person newValue) {
        return DEFAULT_DURATION;  // 수정 시 5분 연장
    }
}
```

**만료 정책 메서드:**
- `getExpiryForCreation`: 캐시 생성 시 만료 시간
- `getExpiryForAccess`: 캐시 조회 시 만료 시간 (연장 가능)
- `getExpiryForUpdate`: 캐시 수정 시 만료 시간

**주의사항:**
- 기본 만료 설정이 없으면 **영구 보관**
- 메모리 부족 위험 → 반드시 만료 정책 설정

### 4단계: 이벤트 리스너 설정

**EhcacheEventListener.java:**

```java
public class EhcacheEventListener implements CacheEventListener<Object, Object> {

    @Override
    public void onEvent(CacheEvent<? extends Object, ? extends Object> event) {
        System.out.println("Cache Event: " + event.getType());
        System.out.println("  Key: " + event.getKey());
        System.out.println("  Value: " + event.getNewValue());
    }
}
```

**이벤트 타입:**
- `CREATED`: 캐시 생성
- `UPDATED`: 캐시 수정
- `EXPIRED`: 캐시 만료
- `REMOVED`: 캐시 삭제

---

## 실전 예제

### Entity 및 Repository

**Person.java:**

```java
@NoArgsConstructor
@AllArgsConstructor
@ToString
@Getter
@EqualsAndHashCode
public class Person implements Serializable {
    private String id;
    private String name;

    public static Person create(String id, String name) {
        return new Person(id, name);
    }

    public void updateName(String newName) {
        this.name = newName;
    }
}
```

**Persons.java (DB 역할):**

```java
public class Persons {

    private static final List<Person> persons = new ArrayList<>();

    static {
        // 초기 데이터
        persons.add(Person.create("aks", "악스"));
    }

    public static Person getPerson(String id) {
        return persons.stream()
            .filter(person -> person.getId().equals(id))
            .findFirst()
            .orElseThrow(() -> new IllegalArgumentException("Person not found"));
    }

    public static void deletePerson(String id) {
        persons.removeIf(person -> person.getId().equals(id));
    }
}
```

**PersonRepository.java:**

```java
@Repository
public class PersonRepository {

    public Person selectPerson(String id) {
        return Persons.getPerson(id);
    }

    public void deletePerson(String id) {
        Persons.deletePerson(id);
    }
}
```

### Service (캐시 적용)

**PersonService.java:**

```java
@RequiredArgsConstructor
@Service
public class PersonService {

    private final PersonRepository personRepository;

    // 캐시 없이 조회
    public Person selectPerson(String id) {
        return personRepository.selectPerson(id);
    }

    // 캐시에서 조회
    @Cacheable(cacheNames = "personCache", key = "#id")
    public Person selectPersonFromCache(String id) {
        System.out.println("DB 조회: " + id);  // 캐시 미스 시에만 출력
        return personRepository.selectPerson(id);
    }

    // 캐시 업데이트
    @CachePut(cacheNames = "personCache", key = "#id")
    public Person updatePersonInCache(String id, String newName) {
        Person person = this.selectPerson(id);
        person.updateName(newName);
        return person;
    }

    // 캐시 삭제
    @CacheEvict(cacheNames = "personCache", key = "#id")
    public void deletePersonFromCache(String id) {
        personRepository.deletePerson(id);
    }
}
```

**캐시 어노테이션:**
- `@Cacheable`: 캐시 조회, 없으면 메서드 실행 후 캐시 저장
- `@CachePut`: 메서드 항상 실행 후 결과를 캐시에 저장
- `@CacheEvict`: 캐시에서 삭제

**주의사항: Self-Invocation**
```java
// 잘못된 예
@Cacheable(cacheNames = "personCache", key = "#id")
public Person selectPersonFromCache(String id) {
    return personRepository.selectPerson(id);
}

@CachePut(cacheNames = "personCache", key = "#id")
public Person updatePersonInCache(String id, String newName) {
    // this로 호출하면 AOP가 동작하지 않음!
    Person person = this.selectPersonFromCache(id);  // ✗
    person.updateName(newName);
    return person;
}

// 올바른 예
@CachePut(cacheNames = "personCache", key = "#id")
public Person updatePersonInCache(String id, String newName) {
    // 캐시 없이 직접 조회
    Person person = this.selectPerson(id);  // ✓
    person.updateName(newName);
    return person;
}
```

---

## 테스트 코드

**PersonServiceTest.java:**

```java
@SpringBootTest
public class PersonServiceTest {

    @Autowired
    private PersonService personService;

    @Autowired
    private CacheManager cacheManager;

    @AfterEach
    void afterEach() {
        // 각 테스트 후 캐시 초기화
        cacheManager.getCache("personCache").clear();
    }

    @Test
    public void selectPerson_호출시_캐싱되지않는다() {
        // given
        String id = "aks";

        // when
        personService.selectPerson(id);

        // then
        Cache.ValueWrapper cache = cacheManager.getCache("personCache").get(id);
        Assertions.assertNull(cache);
    }

    @Test
    public void selectPersonFromCache_호출시_캐싱된다() {
        // given
        String id = "aks";

        // when
        personService.selectPersonFromCache(id);

        // then
        Cache.ValueWrapper cache = cacheManager.getCache("personCache").get(id);
        Assertions.assertNotNull(cache);
    }

    @Test
    public void selectPersonFromCache_2회_호출시_1회만_DB조회() {
        // given
        String id = "aks";

        // when
        personService.selectPersonFromCache(id);  // DB 조회
        personService.selectPersonFromCache(id);  // 캐시 조회
        personService.selectPersonFromCache(id);  // 캐시 조회

        // then
        // 콘솔 출력으로 "DB 조회: aks"가 1번만 출력되는지 확인
        Cache.ValueWrapper cache = cacheManager.getCache("personCache").get(id);
        Assertions.assertNotNull(cache);
    }

    @Test
    public void updatePersonInCache_호출시_캐시가_변경된다() {
        // given
        String id = "aks";
        String expected = "스악";
        personService.selectPersonFromCache(id);  // 캐시 생성

        // when
        personService.updatePersonInCache(id, expected);  // 캐시 수정

        // then
        Cache.ValueWrapper wrapper = cacheManager.getCache("personCache").get(id);
        String actual = ((Person) wrapper.get()).getName();
        Assertions.assertEquals(expected, actual);
    }

    @Test
    public void deletePersonFromCache_호출시_캐시가_삭제된다() {
        // given
        String id = "aks";
        personService.selectPersonFromCache(id);  // 캐시 생성

        // when
        personService.deletePersonFromCache(id);  // 캐시 삭제

        // then
        Cache.ValueWrapper cache = cacheManager.getCache("personCache").get(id);
        Assertions.assertNull(cache);
    }
}
```

**테스트 결과:**

```
✓ selectPerson_호출시_캐싱되지않는다
✓ selectPersonFromCache_호출시_캐싱된다
✓ selectPersonFromCache_2회_호출시_1회만_DB조회
✓ updatePersonInCache_호출시_캐시가_변경된다
✓ deletePersonFromCache_호출시_캐시가_삭제된다

Cache Event: CREATED
  Key: aks
  Value: Person(id=aks, name=악스)

Cache Event: UPDATED
  Key: aks
  Value: Person(id=aks, name=스악)

Cache Event: REMOVED
  Key: aks
```

---

## 정리

### 핵심 요약

**문제:**
- 반복적인 DB 조회로 인한 부하
- 변경이 적은 데이터도 매번 조회
- 대시보드 등 주기적 조회로 인한 커넥션 부족

**해결:**
1. **Ehcache 도입**
   - 메모리 캐싱으로 DB 조회 최소화
   - TTL 설정으로 데이터 신선도 유지

2. **적용 사례**
   - 공통코드: 연 47만 회 → 365회 (99.9% 감소)
   - 대시보드: 월 86만 회 → 8,600회 (99% 감소)

3. **성과**
   - DB 부하 대폭 감소
   - 응답 속도 개선
   - 사업 확장에도 안정적 운영

### Ehcache 적용 가이드

**적용 검토:**
- [ ] 요청 빈도가 높은가?
- [ ] 변경 빈도가 낮은가?
- [ ] DB 부하가 문제인가?

**설정 체크리스트:**
- [ ] `@EnableCaching` 설정
- [ ] 캐시 설정 (크기, TTL)
- [ ] 만료 정책 설정 (필수!)
- [ ] 이벤트 리스너 (선택)
- [ ] 테스트 코드 작성

**주의사항:**
- 만료 정책 미설정 시 메모리 부족
- Self-invocation 문제 주의
- 캐시 일관성 관리 (수정/삭제 시 evict)

### 마지막으로

Ehcache는 간단한 설정만으로 **데이터베이스 부하를 크게 줄일 수 있는** 효과적인 도구다.

특히 **변경이 적고 조회가 잦은 데이터**에 적용하면 즉시 효과를 볼 수 있다.

**"반복되는 조회, 캐시로 해결하자."**

---

## Reference

- [Ehcache 공식 문서](https://www.ehcache.org/)
- [Spring Cache Abstraction](https://docs.spring.io/spring-framework/reference/integration/cache.html)
- [GitHub 예제 코드](https://github.com/dhk5646/study/pull/1)

