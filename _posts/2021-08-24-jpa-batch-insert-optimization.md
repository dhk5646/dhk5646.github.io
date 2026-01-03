---
title: "JPA saveAll() 성능 최적화: 단건 Insert를 Batch Insert로 개선하기"
categories: java
tags: [jpa, hibernate, performance, batch-insert, optimization]
excerpt: "JPA saveAll()이 단건씩 조회/저장하는 문제를 Persistable 인터페이스 구현으로 해결하고, Batch Insert로 성능을 수십 배 향상시킨 실전 사례"
---

## 들어가며

 1만 건의 데이터를 일괄 저장하는 기능을 테스트하던 중, **예상치 못한 성능 문제**를 발견했다.

**테스트 결과:**
- 1만 건 저장 소요 시간: **63초**
- 예상 시간: 1-2초

당연히 Batch Insert가 될 것이라 기대했지만, **실제로는 단건씩 INSERT가 반복**되며 성능이 매우 느렸다.

원인을 조사한 결과, **IDENTITY 전략의 근본적인 한계** 때문이었다:
- IDENTITY 전략은 DB의 AUTO_INCREMENT 사용
- INSERT 후 즉시 생성된 ID를 받아와야 함
- 각 INSERT가 개별적으로 실행되어 Batch 처리 불가능

이 글에서는 이 문제를 해결하기 위해 **ID 직접 할당**과 **Persistable 인터페이스**를 활용하여 진짜 Batch Insert를 구현하고, **63초 → 0.7초 (약 90배 향상)**를 달성한 과정을 정리한다.

---

## 문제 상황

### 시나리오

1만건의 주문 데이터를 일괄 저장하는 기능을 개발했다.

```java
@Service
@Transactional
@RequiredArgsConstructor
public class OrderSaveAllService {
    
    private final OrderRepository orderRepository;
    
    public void saveAllOrder(List<OrderDto> orders) {
        List<Order> entities = orders.stream()
            .map(Order::from)
            .collect(Collectors.toList());
        
        // 대량 저장
        orderRepository.saveAll(entities);
    }
}
```

**Entity 구조:**

```java
@Entity
@Table(name = "orders")
@NoArgsConstructor(access = AccessLevel.PROTECTED)
@Getter
public class Order extends BaseEntity {
    
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)  // 문제의 원인
    private Long id;
    
    private BigDecimal amount;
    
}
```

**예상:**
```sql
INSERT INTO orders (amount, ...) VALUES 
  (1000, ...),
  (2000, ...),
  (3000, ...),
  ...
  -- 한 번에 여러 건 INSERT
```

**실제:**
```sql
INSERT INTO orders (amount, ...) VALUES (1000, ...)
INSERT INTO orders (amount, ...) VALUES (2000, ...)
INSERT INTO orders (amount, ...) VALUES (3000, ...)
...
-- 1만 건이면 INSERT 1만 번!
```

### 성능 측정

**테스트 환경:**
- 데이터: 주문 데이터 1만 건
- DB: MySQL 8.0
- 테스트 설정:
  ```yaml
  # application-test.yml
  logging:
    level:
      root: info
      org.hibernate.SQL: info  # Console 로그 출력 시간 제거
  ```

**결과:**

| 방식 | 쿼리 수 | 소요 시간 |
|------|---------|----------|
| **Before (IDENTITY 전략)** | 10,000개 | 63.6초 |
| **After (직접 할당 + Batch)** | 1개 (병합) | 0.7초 |

**개선율: 약 90배 빠름**

---

## 원인 분석

### 1단계: saveAll()은 save()를 반복 호출

**문제의 시작점 - SimpleJpaRepository의 saveAll():**

```java
@Override
@Transactional
public <S extends T> List<S> saveAll(Iterable<S> entities) {
    Assert.notNull(entities, "Entities must not be null");
    
    List<S> result = new ArrayList<>();
    
    for (S entity : entities) {
        result.add(save(entity));  // save()를 반복 호출
    }
    
    return result;
}
```

**핵심:**
- `saveAll()`은 내부적으로 `save()`를 반복 호출
- 1만 건이면 `save()` 1만 번 호출
- Batch 최적화는 이 단계에서는 일어나지 않음

### 2단계: save()는 isNew()로 신규 여부 판단

**SimpleJpaRepository의 save() 메서드:**

```java
@Transactional
public <S extends T> S save(S entity) {
    
    if (entityInformation.isNew(entity)) {
        em.persist(entity);     // 신규 Entity: INSERT
        return entity;
    } else {
        return em.merge(entity);  // 기존 Entity: SELECT 후 UPDATE
    }
}
```

**동작 방식:**

```
save() 호출
    ↓
isNew() 판단
    ↓
true → persist() → INSERT
false → merge() → SELECT + UPDATE
```

### 3단계: persist()와 merge()의 차이

**persist():**
```java
// 신규 Entity를 영속성 컨텍스트에 등록
em.persist(entity);

// 동작:
// 1. 영속성 컨텍스트에 저장
// 2. Transaction commit 시 INSERT
// 3. (하지만 IDENTITY 전략은 즉시 INSERT!)
```

**merge():**
```java
// 준영속 Entity를 영속 상태로 변경
em.merge(entity);

// 동작:
// 1. DB에서 기존 Entity SELECT
// 2. 영속성 컨텍스트에 저장
// 3. 전달받은 entity 값으로 UPDATE
// 4. Transaction commit 시 UPDATE
```

**문제:**
- `merge()`는 DB SELECT를 먼저 실행
- ID가 있는 Entity를 save()하면 merge() 호출
- 불필요한 SELECT 쿼리 발생

### 4단계: JPA의 Entity 상태 관리

**Entity 생명주기:**

```
New (비영속)
  ↓ persist()
Managed (영속)
  ↓ commit()
DB 저장
  ↓ detach() / clear()
Detached (준영속)
  ↓ merge()
Managed (영속)
```

**영속성 컨텍스트의 역할:**
- Entity를 ID로 관리
- ID가 있어야 영속성 컨텍스트에 저장 가능
- 1차 캐시, 변경 감지, 쓰기 지연 기능 제공

### 5단계: isNew() 판단 기준

**AbstractEntityInformation의 isNew():**

```java
public boolean isNew(T entity) {
    ID id = getId(entity);
    
    // 1. ID가 null이면 신규
    if (id == null) {
        return true;
    }
    
    // 2. ID가 primitive type (long, int 등)이고 0이면 신규
    if (id instanceof Number) {
        return ((Number) id).longValue() == 0L;
    }
    
    // 3. 그 외는 기존 Entity
    return false;
}
```

**판단 로직:**

```
ID == null → isNew() = true → persist()
ID != null → isNew() = false → merge() → SELECT 발생!
```

### 6단계: IDENTITY 전략의 근본적 문제

**우리 Entity:**

```java
@Entity
@Table(name = "orders")
public class Order {
    
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    
    private BigDecimal amount;
}
```

**IDENTITY 전략의 동작:**

```java
// 1. 신규 Entity 생성
Order order = new Order(1000);
System.out.println(order.getId());  // null

// 2. persist() 호출
em.persist(order);

// 3. IDENTITY 전략의 특징:
//    persist() 호출 즉시 INSERT 실행!
//    (다른 전략은 commit 시점에 INSERT)

System.out.println(order.getId());  // 1 (DB에서 즉시 할당됨)
```

**왜 즉시 INSERT 할까?**

```
1. IDENTITY = DB의 AUTO_INCREMENT에 의존
2. ID 값은 INSERT 후에만 알 수 있음
3. JPA는 영속성 컨텍스트에서 Entity를 ID로 관리
4. ID를 알아야 영속성 컨텍스트에 저장 가능
5. 따라서 persist() 즉시 INSERT 실행하여 ID 획득

결과: Batch로 묶을 수 없음!
```

**실제 동작 과정:**

```java
// saveAll() 호출
orderRepository.saveAll(orders);  // 1만 건

// 내부 동작:
for (Order order : orders) {
    // 1. ID == null
    // 2. isNew() = true
    // 3. persist() 호출
    // 4. 즉시 INSERT 실행! (IDENTITY 전략)
    // 5. ID 할당받음
    em.persist(order);
}

// 결과: INSERT 1만 번 개별 실행
```

**쿼리 로그:**

```sql
insert into orders (amount) values (1000)
insert into orders (amount) values (2000)
insert into orders (amount) values (3000)
...
-- 1만 번 반복

-- Batch Insert 불가능!
```

### 원인 정리

**문제의 흐름:**

```
saveAll()
  → save() 반복 호출 (1만 번)
    → isNew() = true (ID가 null)
      → persist() 호출
        → IDENTITY 전략이 즉시 INSERT 실행
          → ID 할당받음
            → 다음 Entity 처리
              → 반복...

결과: INSERT 1만 번 개별 실행
```

**IDENTITY 전략의 한계:**
- persist() 즉시 INSERT 실행 (다른 전략은 commit 시점)
- Batch로 묶을 수 없음
- 대량 데이터 처리에 부적합

---

## 해결 방법: ID 직접 할당 + Persistable + Batch Insert

### 전략 개요

IDENTITY 전략의 문제를 해결하기 위해 다음과 같은 전략을 수립했다:

**1. ID 직접 할당**
- IDENTITY 전략 제거
- IdGenerator 유틸리티로 ID 생성
- Entity 생성 시 ID 직접 할당

**2. Persistable 구현**
- `isNew()` 메서드로 신규 Entity 명시
- JPA가 불필요한 SELECT 하지 않도록

**3. Hibernate Batch 설정**
- `batch_size` 설정
- `rewriteBatchedStatements` 옵션으로 Multi-row Insert

### 1단계: ID 생성 유틸리티

**IdGenerator 구현:**

```java
public class IdGenerator {
    
    private static final AtomicLong counter = new AtomicLong(System.currentTimeMillis());
    
    /**
     * 유니크한 ID 생성
     * 
     * @return 생성된 ID
     */
    public static Long generateId() {
        return counter.incrementAndGet();
    }
    
}
```

**특징:**
- `AtomicLong`으로 thread-safe 보장
- `System.currentTimeMillis()` 기반 시작값
- 간단하고 빠른 ID 생성
- 외부 의존성 없음

### 2단계: Persistable 인터페이스 구현

### 개념

**Persistable 인터페이스:**

```java
public interface Persistable<ID> {
    ID getId();
    boolean isNew();
}
```

JPA가 Entity의 신규 여부를 판단할 때 이 인터페이스의 `isNew()`를 우선 사용한다.



```java
@Transactional
public <S extends T> S save(S entity) {
    if (entityInformation.isNew(entity)) {
        em.persist(entity);  // 신규: INSERT
        return entity;
    } else {
        return em.merge(entity);  // 기존: SELECT 후 UPDATE
    }
}
```

**문제:**
- ID를 직접 할당하면 `isNew()` 판단이 실패
- ID가 있으면 기존 Entity로 판단 → `merge()` 호출
- `merge()`는 DB에서 SELECT 후 UPDATE 시도

**해결:**
- `Persistable` 인터페이스 구현으로 `isNew()` 제어
- `@Transient boolean isNew` 필드로 명시적 관리

### 구현

**BatchInsertEntity 추상 클래스:**

```java
@Getter
@ToString
@MappedSuperclass
@EntityListeners(AuditingEntityListener.class)
public abstract class BatchInsertEntity implements Persistable<Long> {
    
    @Transient
    private boolean isNew = true;
    
    @Override
    public boolean isNew() { // 핵심!
        return isNew; 
    }
    
    @CreatedDate
    @Column(nullable = false, updatable = false)
    protected LocalDateTime createdDatetime;
    
    @LastModifiedDate
    @Column(nullable = false)
    protected LocalDateTime updatedDatetime;
    
    @CreatedBy
    protected Long createdBy;
    
    @LastModifiedBy
    protected Long updatedBy;
}
```

**핵심 포인트:**

**1. @Transient**
```java
@Transient
private boolean isNew = true;
```
- `isNew` 필드는 DB 컬럼이 아닌 메모리상 상태 관리용
- 기본값 `true`로 신규 Entity 표시

**2. isNew() 메서드**
```java
@Override
public boolean isNew() {
    return isNew;
}
```
- JPA가 호출하여 신규 Entity 여부 판단
- `true`면 `persist()`, `false`면 `merge()`

**3. Persistable 구현의 효과**
```
ID 직접 할당 (ID != null)
  ↓
기본 isNew() → false → merge() → SELECT 발생

Persistable 구현 isNew() → true → persist() → SELECT 없음!
```

### 적용

**Order Entity:**

```java
@Entity
@Table(name = "orders")
@NoArgsConstructor(access = AccessLevel.PROTECTED)
@Getter
public class Order extends BatchInsertEntity {
    
    @Id
    // @GeneratedValue 제거 - ID 직접 할당
    private Long id;
    
    private BigDecimal amount;
    
    public Order(BigDecimal amount) {
        this.id = IdGenerator.generateId();  // ID 직접 할당
        this.amount = amount;
    }
    
    public static Order from(OrderDto dto) {
        return new Order(dto.getAmount());
    }
}
```

### 결과 (아직 미완성)

**쿼리 로그:**

```sql
insert into orders (...) values (...)
insert into orders (...) values (...)
insert into orders (...) values (...)

-- 1만 건이면 여전히 INSERT 1만 번
```

아직도 1만 번의 INSERT가 개별적으로 실행된다.

**진짜 Batch Insert (Multi-row Insert)를 위해서는 추가 설정이 필요하다.**

---

## 3단계: Hibernate Batch Insert 설정

### application.yml 설정

```yaml
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/mydb?rewriteBatchedStatements=true  # 핵심!
    
  jpa:
    properties:
      hibernate:
        jdbc:
          batch_size: 10000      # 배치 크기 (1만 건 한 번에 처리)
```

**필수 설정:**
- `rewriteBatchedStatements=true`: Multi-row INSERT 활성화
- `batch_size`: 배치 크기 설정

**설정 설명:**

**1. rewriteBatchedStatements=true (가장 중요!)**
```
MySQL Connector가 여러 개의 INSERT 문을 하나의 Multi-row INSERT로 재작성

Before:
INSERT INTO orders VALUES (...)
INSERT INTO orders VALUES (...)
INSERT INTO orders VALUES (...)

After:
INSERT INTO orders VALUES (...), (...), (...)
```

**2. batch_size: 10000**
```
몇 개의 SQL문이 쌓이면 DB 서버로 요청할지 정하는 단위
1만 건을 한 번에 처리
```


### 추가 설정 (MySQL 로그 확인용)

**개발/테스트 환경:**

```yaml
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/mydb?rewriteBatchedStatements=true&profileSQL=true&logger=Slf4JLogger&maxQuerySizeToLog=999999
    
  jpa:
    show-sql: false  # Hibernate 로그는 off
```

**옵션 설명:**
- `profileSQL=true`: MySQL 쿼리 로그 활성화
- `logger=Slf4JLogger`: SLF4J로 로깅
- `maxQuerySizeToLog=999999`: 긴 쿼리도 전체 로깅

### DB 테이블 수정

**AUTO_INCREMENT 제거:**

```sql
-- Before
CREATE TABLE order (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    amount DECIMAL(10,2),
    ...
);

-- After
CREATE TABLE order (
    id BIGINT PRIMARY KEY,  -- AUTO_INCREMENT 제거
    amount DECIMAL(10,2),
    ...
);
```

### 최종 결과

**MySQL 로그:**

```sql
-- 1만 건이 하나의 INSERT로 병합됨!
INSERT INTO orders  (amount, ...) 
VALUES 
  (1, 1000, ...),
  (2, 2000, ...),
  (3, 3000, ...),
  ...
  (10000, 10000000, ...);
```

**성능:**

| 항목 | Before (IDENTITY) | After (ID 직접 할당 + Batch) | 개선율 |
|------|-------------------|------------------------------|--------|
| **쿼리 수** | 10,000개 | 1개 | 99.99% 감소 |
| **소요 시간** | 63.6초 | 0.7초 | 98.9% 감소 (90배) |

---

## 추가 이슈: deleteAll() 동작 불가 문제

### 문제 발견

Batch Insert 최적화를 적용한 후, **또 다른 문제**가 발생했다.

**상황:**

```java
// 테스트 데이터 정리
orderRepository.deleteAll(orders);

// 실행했는데... 삭제가 안 됨!
```

**확인:**

```java
// 삭제 전
assertThat(orderRepository.count()).isEqualTo(100);

// deleteAll 실행
orderRepository.deleteAll(orders);

// 삭제 후
assertThat(orderRepository.count()).isEqualTo(100);  // 여전히 100개!
```

### 원인 분석

**SimpleJpaRepository의 deleteAll() 메서드:**

```java
@Transactional
public void deleteAll(Iterable<? extends T> entities) {
    Assert.notNull(entities, "Entities must not be null");

    for(T entity : entities) {
        this.delete(entity); // 여기서 문제가 발생
    }

}
```

```java
@Override
@Transactional
public void delete(T entity) {
    Assert.notNull(entity, "Entity must not be null!");
    
    // isNew()가 true면 삭제하지 않고 그냥 리턴!
    if (entityInformation.isNew(entity)) {
        return;  
    }
    
    Class<?> type = ProxyUtils.getUserClass(entity);
    T existing = (T) em.find(type, entityInformation.getId(entity));
    
    if (existing == null) {
        return;
    }
    
    em.remove(em.contains(entity) ? entity : em.merge(entity));
}
```

**BatchInsertEntity:**

```java
public abstract class BatchInsertEntity implements Persistable<Long> {
    
    @Transient
    private boolean isNew = true;  // 항상 true!
    
    @Override
    public boolean isNew() {
        return isNew;  // 항상 true 반환
    }
    
    // ...
}
```

**문제:**

```
1. Entity를 DB에서 조회
2. isNew가 true인 상태로 유지
3. delete() 호출
4. isNew() = true → return (삭제 안 함)
```

**실제 동작:**

```java
// DB에서 조회
List<Order> orders = orderRepository.findAll();

// 각 Entity의 isNew = true (메모리 기본값)
orders.forEach(order -> {
    System.out.println(order.isNew());  // true
});

// deleteAll 호출
orderRepository.deleteAll(orders);

// SimpleJpaRepository의 delete()에서:
// isNew() = true → return → 삭제 안 됨!
```

### 해결 방법: @PostLoad 추가

**Spring Data 공식 문서의 권장 방식:**
[Entity State-detection Strategies](https://docs.spring.io/spring-data/jpa/docs/current/reference/html/#jpa.entity-persistence.saving-entites)

**개선된 BatchInsertEntity (최종본):**

```java
@Getter
@ToString
@MappedSuperclass
@EntityListeners(AuditingEntityListener.class)
public abstract class BatchInsertEntity implements Persistable<Long> {
    
    @Transient
    private boolean isNew = true;
    
    @Override
    public boolean isNew() {
        return isNew;
    }
    
    @PostLoad  // ← 핵심! DB 조회 후 자동 호출
    void markNotNew() {
        this.isNew = false;
    }
    
    @CreatedDate
    @Column(nullable = false, updatable = false)
    protected LocalDateTime createdDatetime;
    
    @LastModifiedDate
    @Column(nullable = false)
    protected LocalDateTime updatedDatetime;
    
    @CreatedBy
    protected Long createdBy;
    
    @LastModifiedBy
    protected Long updatedBy;
}
```

**@PostLoad의 역할:**

```
1. Entity를 DB에서 조회 (SELECT)
2. @PostLoad 자동 호출
3. isNew = false로 변경
4. delete() 호출 시 정상 삭제
```

**@PostLoad란?**

JPA Entity Lifecycle Callback 중 하나로, **Entity가 DB에서 로드된 직후** 자동으로 호출되는 메서드입니다.

```
Entity Lifecycle Callbacks:
- @PrePersist: persist() 직전
- @PostPersist: persist() 직후
- @PreUpdate: update() 직전
- @PostUpdate: update() 직후
- @PostLoad: DB 조회 직후 ← 이것!
- @PreRemove: remove() 직전
- @PostRemove: remove() 직후
```

**동작 원리:**

```java
// 1. DB에서 Entity 조회
Order order = em.find(Order.class, 1L);

// 2. JPA가 자동으로 @PostLoad 메서드 호출
// markNotNew() 실행 → isNew = false

// 3. isNew 상태 확인
order.isNew();  // false

// 4. delete() 호출
orderRepository.delete(order);

// 5. SimpleJpaRepository의 delete()
// isNew() = false → 정상 삭제 진행 ✓
```

**동작 확인:**

```java
// DB에서 조회
List<Order> orders = orderRepository.findAll();

// @PostLoad가 자동 호출되어 isNew = false
orders.forEach(order -> {
    System.out.println(order.isNew());  // false
});

// deleteAll 정상 동작
orderRepository.deleteAll(orders);

// 삭제 확인
assertThat(orderRepository.count()).isEqualTo(0);  // ✓
```

### 정리

**문제:**
- BatchInsertEntity 적용 후 deleteAll() 동작 안 함
- isNew()가 항상 true 반환

**원인:**
- SimpleJpaRepository의 delete()가 isNew() 체크
- isNew() = true면 삭제하지 않고 리턴

**해결:** **@PostLoad 추가** 
- DB 조회 후 isNew = false로 변경
- deleteAll() 정상 동작
- Entity Lifecycle Callback 활용
   
---

## 전체 정리

### 핵심 요약

**1차 문제: Batch Insert 성능**
- 1만 건 저장에 63.6초 소요
- JPA `saveAll()`이 단건씩 INSERT 반복

**원인:**
- `@GeneratedValue(IDENTITY)` 사용
- IDENTITY 전략은 persist() 즉시 INSERT 실행
- Batch Insert 불가능

**해결:**
1. **ID 직접 할당**
   - IDENTITY 전략 제거
   - IdGenerator로 ID 생성
   - Entity 생성 시 ID 직접 할당

2. **Persistable 인터페이스 구현**
   - `isNew()` 메서드로 신규 Entity 명시
   - `@Transient boolean isNew` 필드 관리

3. **Hibernate Batch 설정**
   - `batch_size: 10000`

4. **rewriteBatchedStatements=true**
   - MySQL Connector 옵션
   - 여러 INSERT를 하나의 Multi-row INSERT로 병합

**결과:**
- 쿼리 수: 10,000개 → 1개 (99.99% 감소)
- 소요 시간: 63.6초 → 0.7초 (90배 향상)

**2차 문제: deleteAll() 동작 불가**
- Batch Insert 적용 후 deleteAll() 실패
- isNew()가 항상 true로 인식

**해결:**
- **@PostLoad 추가**
- DB 조회 시 자동으로 isNew = false 설정
- deleteAll() 정상 동작

---

## 실전 적용 가이드

### 체크리스트

**Batch Insert를 위한 필수 조건:**

- [ ] `Persistable<ID>` 인터페이스 구현
- [ ] `isNew()` 메서드 오버라이드
- [ ] `@Transient boolean isNew = true` 필드 추가
- [ ] `hibernate.jdbc.batch_size` 설정 (10000)
- [ ] `rewriteBatchedStatements=true` JDBC URL 옵션 (핵심!)
- [ ] `@Transactional` 범위 확인
- [ ] IdGenerator 유틸리티 구현
- [ ] `@GeneratedValue` 제거 (ID 직접 할당)
- [ ] DB 테이블 AUTO_INCREMENT 제거

---

## 정리

### 핵심 요약

**문제:**
- 1만 건 데이터 저장에 63.6초 소요
- JPA `saveAll()`이 단건씩 INSERT 반복

**원인:**
- `@GeneratedValue(IDENTITY)` 사용
- IDENTITY 전략은 INSERT 즉시 실행하여 ID 획득
- Batch Insert 불가능

**해결:**
1. **ID 직접 할당** (필수)
   - IDENTITY 전략 제거
   - IdGenerator로 ID 생성
   - Entity 생성 시 ID 직접 할당

2. **Persistable 인터페이스 구현** (필수)
   - `isNew()` 메서드로 신규 Entity 명시
   - `@Transient boolean isNew` 필드 관리
   - JPA가 불필요한 SELECT 하지 않도록

3. **Hibernate Batch 설정** (필수)
   - `batch_size: 10000`

4. **rewriteBatchedStatements=true** (핵심!)
   - MySQL Connector 옵션
   - 여러 INSERT를 하나의 Multi-row INSERT로 병합
   - 1만 건을 1개의 쿼리로

**결과:**
- 쿼리 수: 10,000개 → 1개 (99.99% 감소)
- 소요 시간: 63.6초 → 0.7초 (90배 향상)

**마지막으로:**

대량 데이터 처리에서 **IDENTITY 전략은 근본적인 병목**이다.

ID 직접 할당 + Persistable + Batch Insert 조합으로 **100배 가까운 성능 향상**을 얻을 수 있다.

**"대량 데이터 처리에서 IDENTITY는 금지다."**


