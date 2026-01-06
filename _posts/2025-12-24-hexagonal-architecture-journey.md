---
title: "헥사고날 아키텍처, 책으로는 이해 안 돼서 직접 만들어봤다"
categories: Backend
tags: [Hexagonal Architecture, Port and Adapter, Spring Boot, Clean Code]
excerpt: "헥사고날 아키텍처를 ‘왜’ 쓰는지 이해하기 위해, 계층형 구조에서 출발해 직접 구조를 깨고 다시 쌓아본 기록"
---

## 들어가며

한 팀원이 어느 날 책 한 권을 소개해줬다.

**「만들면서 배우는 헥사고날 아키텍처」**

포트, 어댑터, 의존성 역전, 고수준, 저수준…
단어만 훑어보는데 머리가 하얘지기 시작했다.

**"이걸 실무에서 진짜 쓰긴 하는 건가?"**

그런데 이상하게도, 전혀 낯설지만은 않았다.
내가 계층형 아키텍처에서 늘 고민하던 지점들이 보였기 때문이다.

- 서비스를 행위 중심으로 나누어 관리하는 방식
- Entity와 Domain 모델을 분리하려는 시도
- 비즈니스 로직을 기술로부터 떼어내려는 구조

"이거… 내가 그동안 어렴풋이 고민하던 것들이잖아?"

아키텍처에 관심이 많았던 터라 망설임 없이 책을 사서 읽기 시작했다.
하지만 몇 장을 넘기고 나서 들었던 솔직한 감정은 이거였다.

**이해는 되는 것 같은데, 손에 잡히지는 않는다.**

구조는 알겠는데,
왜 이렇게 나눠야 하는지,
실제 프로젝트에서는 어디까지 적용해야 하는지,
명확한 그림이 그려지지 않았다.

그래서 결론을 내렸다.

**"그럼 직접 만들어보자."**

---

이 글은
헥사고날 아키텍처를 이해한 사람의 설명서가 아니다.

헥사고날 아키텍처를 만들어가며 이해하려고 발버둥쳤던 기록,
그리고 그 과정에서 내 나름의 기준으로 정리한 구조에 대한 이야기다.

완벽한 정답은 없었다.
대신 수많은 질문과 선택, 그리고 시행착오가 있었다.

헥사고날 아키텍처가 궁금하지만
여전히 막연하게 느껴지는 사람이라면,
이 여정이 조금은 도움이 되었으면 한다.




## 1. 내가 만든 헥사고날 아키텍처 구조

- [Techpost BE GitHub Repository](https://github.com/techpost-kr/techpost-be)

글을 이해하기 쉽게 하기 위해 내가 만든 헥사고날 아키텍처 프로젝트 구조를 먼저 소개한다.

이 구조가 왜 이렇게 나뉘어야 했는지는 뒤에서 하나씩 만들어가며 다시 설명한다.

### 1.1. 전체 모듈 구조
```
project/
├── app-api            (module)
├── application        (module)
├── domain             (module)
└── infrastructure-jpa (module)
```

### 1.2. 모듈별 의존성 방향

```
[바깥쪽: Adapters]          [안쪽: Core]           [바깥쪽: Adapters]

   app-api (In)  ──────▶  application  ◀──────  infrastructure-jpa (Out)
    (Controller)           (UseCase)             (Persistence Adapter)
                                │
                                ▼
                             domain
                           (Pure Model)
```

### 1.3. 각 모듈의 역할

| 모듈 | 역할 | Spring 의존 | JPA 의존 |
|------|------|------------|---------|
| **app-api** | REST API, DTO, 인증/인가 | O | X |
| **application** | 유스케이스, 포트 정의, 비즈니스 흐름 | O (최소) | X |
| **domain** | 순수 비즈니스 로직, 도메인 모델 | X | X |
| **infrastructure-jpa** | 포트 구현, JPA Entity, 영속화 | O | O |


## 2. 시작은 계층형 아키텍처였다

### 2.1. 내가 알던 계층형 구조

헥사고날을 시도하기 전, 내가 사용하던 구조:

```java
@RestController
public class PostController {
    private final PostService service;

    @PostMapping("/post")
    public void create(@RequestBody PostRequest request) {
        service.save(request);  // Request 전달
    }
}

@Service
public class PostService {
    private final PostRepository repository;
    
    @Transactional
    public void save(PostRequest request) {
        Post post = Post.of(request);  // request → Post 변환
        repository.save(post);
    }
}

@Repository
public interface PostRepository extends JpaRepository<Post, Long> {
}

// Entity (domain?)
@Entity
@Table(name = "post")
public class Post {
    @Id
    @GeneratedValue
    private Long id;
    
    @Column
    private String title;

    // getter, setter
    
    // 정적 팩토리 메서드가 Request DTO를 받고 있다!
    public static Post of(PostRequest request) {  // Entity 가 웹 계층의 DTO를 알게 됨
        Post post = new Post();
        post.setTitle(request.getTitle());
        post.setUrl(request.getUrl());
        // Request 필드가 변경되면 Domain도 수정해야 함
        return post;
    }
}
```

### 2.2. 뭐가 문제지?

이 코드를 보고 이런 생각이 들었다:

"잘 동작하는데 뭐가 문제지?"

하지만 책을 읽으며 다음 질문들이 생겼다:

**질문 1**: Post에 @Entity가 있는데 이게 순수한 도메인인가?
- JPA 어노테이션에 의존하고 있다
- JPA 없이는 테스트도 어렵다

**질문 2**: Domain이 Controller의 Request DTO를 알아야 하나?
- Service에서 Request DTO를 받아 Domain의 정적 팩토리 메서드로 생성
- `Post.of(request.getTitle(), request.getUrl(), ...)` 형태
- Domain이 웹 계층의 DTO를 의존하게 되는 건 아닌가?
- Domain이 Controller의 변경에 영향을 받게 된다

**질문 3**: Service가 Repository를 직접 의존한다
- JPA에서 MyBatis로 바꾸면?
- Service도 수정해야 한다

### 2.3. "도메인을 보호한다"는 말의 의미

책에서 계속 나오는 말:

"도메인을 기술로부터 보호해야 한다"

처음에는 이해가 안 됐다. 하지만 다시 생각해보니:

**내 Post는 JPA가 없으면 존재할 수 없다.**

```java
@Entity  // JPA!
public class Post {
    @Id  // JPA!
    @GeneratedValue  // JPA!
    private Long id;
}
```

Post는 "게시물"이라는 비즈니스 개념인데, 왜 JPA를 알아야 할까?

**이 질문이 헥사고날 아키텍처를 이해하는 시작점이었다.**

## 3. 첫 시도: Domain에서 JPA 제거하기
“도메인은 기술을 몰라도 된다”


### 3.1. 순수 Domain 모델 만들기

가장 먼저 시도한 것: Domain에서 JPA를 제거

```java
// domain/Post.java (JPA 제거!)
public class Post {
    private final PostId postId;
    private final String title;
    private final String url;
    private final LocalDateTime publishedAt;
    
    // 생성자는 private
    private Post(PostId postId, String title, 
                 String url, LocalDateTime publishedAt) {
        this.postId = postId;
        this.title = title;
        this.url = url;
        this.publishedAt = publishedAt;
    }
    
    // 정적 팩토리 메서드
    public static Post of(String title, String url, LocalDateTime publishedAt) {
        validateTitle(title);
        return new Post(PostId.newId(), title, url, publishedAt);
    }
    
    private static void validateTitle(String title) {
        if (title == null || title.isBlank()) {
            throw new IllegalArgumentException("제목은 필수입니다");
        }
    }
}
```

**변화**:
- @Entity 제거
- 불변 객체 (final)
- 생성 로직에 검증 포함
- 정적 팩토리 메서드

### 3.2. 그럼 JPA Entity는 어디에?

문제가 생겼다: "그럼 DB에는 어떻게 저장하지?"

해결: **Domain과 Entity를 분리**

```java
// infrastructure-jpa/PostJpaEntity.java
@Entity
@Table(name = "post")
public class PostJpaEntity {
    @Id
    private String postId;
    
    private String title;
    private String url;
    private LocalDateTime publishedAt;
    
    // Domain → Entity
    public static PostJpaEntity from(Post post) {
        PostJpaEntity entity = new PostJpaEntity();
        entity.postId = post.getPostId().getValue();
        entity.title = post.getTitle();
        entity.url = post.getUrl();
        entity.publishedAt = post.getPublishedAt();
        return entity;
    }
    
    // Entity → Domain
    public Post toDomain() {
        return Post.of(
            PostId.of(this.postId),
            this.title,
            this.url,
            this.publishedAt
        );
    }
}
```

**깨달은 것**:
- Domain: 비즈니스 개념 (Post)
- Entity: 영속화 방법 (PostJpaEntity)
- 두 개는 다른 책임을 가진다

### 3.3. 역할의 명확한 분리

| 항목 | Domain | Entity |
|------|--------|--------|
| 위치 | domain 모듈 | infrastructure-jpa 모듈 |
| 목적 | 비즈니스 규칙 | 영속화 |
| 어노테이션 | 없음 | @Entity, @Table, @Id 등 |
| 변경 이유 | 비즈니스 규칙 변경 | 기술 스택 변경 |

**핵심**: Domain은 JPA를 모른다. Entity는 Domain을 안다.

## 4. Port와 Adapter 이해하기
“의존성 역전은 인터페이스를 어디에 두느냐의 문제다”


### 4.1. "Port"가 뭔데?

책을 읽으며 가장 이해하기 어려웠던 개념: **Port**

"인터페이스인가? 그럼 왜 Port라고 부르지?"

다시 생각해보니:

**Port = 애플리케이션의 경계에서 외부와 소통하는 창구**

실제 항구(Port)를 떠올려보면:
- 항구는 배가 드나드는 곳
- 안쪽(도시)과 바깥쪽(바다)를 연결
- 규격이 정해져 있음

애플리케이션에서도:
- Port는 애플리케이션이 외부와 소통하는 곳
- 안쪽(비즈니스 로직)과 바깥쪽(기술)을 연결
- 인터페이스로 계약을 정의

### 4.2. Inbound Port vs Outbound Port

헥사고날에서 Port는 두 종류:

**Inbound Port**: 외부 → 애플리케이션
- "애플리케이션이 제공하는 기능"
- UseCase 인터페이스
- 예: PostSaveUseCase, PostSearchUseCase
- **왜 UseCase인가?**: Inbound Port는 "서비스의 기능 흐름"을 정의하기 때문에 UseCase라는 이름을 사용한다.

**Outbound Port**: 애플리케이션 → 외부
- "애플리케이션이 필요로 하는 기능"
- Repository, 외부 API 추상화
- 예: PostSavePort, PostSearchPort
- **왜 Port인가?**: Outbound Port는 기술적 관심사(저장, 조회)를 추상화하므로 Port라는 이름을 그대로 사용한다.

```
┌─────────────────────────────────────────┐
│         Application                     │
│                                         │
│  [Inbound Port]  ←── Controller         │
│      ↓                  (Adapter)       │
│   Service                               │
│      ↓                                  │
│  [Outbound Port] ──→ JPA Repository     │
│                      (Adapter)          │
└─────────────────────────────────────────┘
```

### 4.3. 실제 코드로 보는 Port

**Inbound Port**:
```java
// application/post/save/port/in/PostSaveUseCase.java
public interface PostSaveUseCase {
    void save(PostSaveCommand command);
}
```

**Outbound Port**:
```java
// application/post/save/port/out/PostSavePort.java
public interface PostSavePort {
    Post save(Post post);
}
```

**Service (Port 사용)**:
```java
// application/post/save/service/PostSaveService.java
@Service
@Transactional
public class PostSaveService implements PostSaveUseCase {
    
    private final PostSavePort postSavePort;
    
    @Override
    public void save(PostSaveCommand command) {
        Post post = command.toPost();
        postSavePort.save(post);
    }
}
```

**Adapter (Port 구현)**:
```java
// infrastructure-jpa/PostSavePersistenceAdapter.java
@Component
public class PostSavePersistenceAdapter implements PostSavePort {
    
    private final PostJpaRepository repository;
    
    @Override
    public Post save(Post post) {
        PostJpaEntity entity = PostJpaEntity.from(post);
        PostJpaEntity saved = repository.save(entity);
        return saved.toDomain();
    }
}
```

**핵심**:
- Service는 Port(인터페이스)만 의존
- Adapter가 Port를 구현
- Service는 Adapter의 존재를 모름

### 4.4. "의존성 역전"을 체감한 순간

기존 계층형:
```
Service → Repository (구현체)
```
- Service가 JPA Repository를 직접 의존
- JPA 변경 시 Service도 영향

헥사고날:
```
Service → Port (인터페이스) ← Adapter (구현체)
```
- Service는 Port만 의존
- Adapter가 Port를 구현
- Service는 변경 없음

**실험**: JPA를 MyBatis로 교체해보기

변경 전:
```java
@Component
public class PostSavePersistenceAdapter implements PostSavePort {
    private final PostJpaRepository repository; // JPA
    
    @Override
    public Post save(Post post) {
        // JPA 사용
    }
}
```

변경 후:
```java
@Component
public class PostSaveMyBatisAdapter implements PostSavePort {
    private final PostMapper mapper; // MyBatis
    
    @Override
    public Post save(Post post) {
        // MyBatis 사용
    }
}
```

**결과**: application 코드는 단 한 줄도 수정하지 않았다.

"아, 이게 의존성 역전이구나."

## 5. Application Layer의 역할

### 5.1. Application Layer가 필요한 이유

깨달은 것:

**Domain**: 비즈니스 규칙 (단일 객체의 일관성)
**Application**: 비즈니스 흐름 (여러 객체의 조합)

예시로 이해하기:

```java
// Domain: 규칙
public class Post {
    public static Post create(String title, ...) {
        validateTitle(title);  // 규칙: 제목 검증
        return new Post(...);
    }
}

// Application: 흐름
@Service
@Transactional  // 흐름: 트랜잭션 관리
public class PostSaveService implements PostSaveUseCase {
    
    private final PostSavePort postSavePort;
    private final PublisherPort publisherPort;
    
    @Override
    public void save(PostSaveCommand command) {
        // 흐름 1: Publisher 조회
        Publisher publisher = publisherPort.findById(command.getPublisherId());
        
        // 흐름 2: Post 생성 (Domain 규칙 사용)
        Post post = Post.create(command.getTitle(), command.getUrl(), publisher);
        
        // 흐름 3: 저장
        postSavePort.save(post);
    }
}
```

### 5.2. Command 객체의 필요성

초기에는 UseCase가 PostSaveWebRequest를 직접 받았다:

```java
public interface PostSaveUseCase {
    void save(PostRequest request);  // Web Request를 직접?
}
```

**문제**: 
- UseCase가 웹 계층(Controller)의 DTO에 의존
- Application이 외부 기술(웹)에 결합됨

**개선**: Command 객체 도입

```java
public interface PostSaveUseCase {
    void save(PostSaveCommand command);  // Command 객체
}

@Getter
@Builder
public class PostSaveCommand {
    private final String title;
    private final String url;
    private final LocalDateTime publishedAt;
    
    // Domain 변환 로직 캡슐화
    public Post toPost() {
        return Post.of(title, url, publishedAt);
    }
}
```

**장점**:
- Controller는 Command만 알면 됨
- Domain 생성 로직은 Command에 캡슐화
- UseCase의 의도가 명확함

### 5.3. Application의 기술 의존 최소화

Application Layer는 비즈니스 흐름을 작성하는 곳이지, 
기술을 직접 사용하는 곳이 아니다.

**application/build.gradle** (최소한의 Spring만):
```groovy
plugins {
    id 'java-library'
    id 'io.spring.dependency-management'
}

dependencies {
    implementation project(':domain')
    implementation project(':common')

    // Spring - 최소한만 사용
    implementation 'org.springframework:spring-context'  // @Service
    implementation 'org.springframework:spring-tx'       // @Transactional
    
    // JPA, Web, Security 등은 없음
}
```

**핵심 차이**:
```java
// Application은 이렇게 작성 (기술 최소화)
@Service  // Spring
@Transactional  // Spring
public class PostSaveService implements PostSaveUseCase {
    
    private final PostSavePort postSavePort;  // 인터페이스만
    
    @Override
    public void save(PostSaveCommand command) {
        // 순수 비즈니스 흐름만 작성
        Post post = command.toPost();
        postSavePort.save(post);  // 어떻게 저장되는지 모름
    }
}

// 기술은 infrastructure에서 (JPA, QueryDSL 등)
@Component
public class PostSavePersistenceAdapter implements PostSavePort {
    
    private final PostJpaRepository repository;  // JPA
    private final JPAQueryFactory queryFactory;   // QueryDSL
    
    @Override
    public Post save(Post post) {
        // JPA 기술 사용
        PostJpaEntity entity = PostJpaEntity.from(post);
        PostJpaEntity saved = repository.save(entity);
        return saved.toDomain();
    }
}
```

**Application은**:
- @Service, @Transactional 같은 최소한의 Spring 기능만 사용
- Port(인터페이스)를 통해 기술과 소통
- "무엇을 할지(What)"만 정의, "어떻게 할지(How)"는 infrastructure에 위임

**Infrastructure는**:
- JPA, QueryDSL, WebClient 등 모든 기술 사용
- Port를 구현하여 실제 동작 제공

이렇게 분리하면:
- Application은 기술 변경에 영향받지 않음
- 기술만 바꾸고 싶을 때 infrastructure만 수정

### 5.4. Application Layer의 책임 정리

| 책임 | Domain | Application |
|------|--------|-------------|
| 단일 객체 규칙 | O | X |
| 여러 객체 조합 | X | O |
| 트랜잭션 | X | O |
| Port 사용 | X | O |
| 기술 의존 | X | O (최소) |

## 6. 행위 중심 패키지 구조

### 6.1. 계층 중심의 한계

초기에는 계층 중심으로 구조를 잡았다:

```
application/post/
├── service/
│   ├── PostSaveService.java
│   ├── PostSearchService.java
│   └── PostUpdateService.java
├── port/in/
│   ├── PostSaveUseCase.java
│   ├── PostSearchUseCase.java
│   └── PostUpdateUseCase.java
└── port/out/
    ├── PostSavePort.java
    ├── PostSearchPort.java
    └── PostUpdatePort.java
```

**문제**:
- 저장 관련 코드가 service, port/in, port/out에 흩어짐
- 새 기능 추가 시 여러 곳을 수정
- 관련 코드를 찾기 어려움

### 6.2. 행위 중심으로 변경

책에서 본 행위 중심 구조가 흥미로웠다:

```
application/post/
├── save/
│   ├── service/PostSaveService.java
│   └── port/
│       ├── in/PostSaveUseCase.java
│       └── out/PostSavePort.java
├── search/
│   ├── service/PostSearchService.java
│   └── port/
│       ├── in/PostSearchUseCase.java
│       └── out/PostSearchPort.java
└── update/
    ├── service/PostUpdateService.java
    └── port/
        ├── in/PostUpdateUseCase.java
        └── out/PostUpdatePort.java
```

**장점**:
- 저장 관련 모든 코드가 `save/`에
- 기능 단위로 코드가 응집
- 패키지명만 봐도 기능 파악 가능
- 새 기능은 새 패키지만 추가

### 6.3. "스크리밍 아키텍처"

Uncle Bob이 말한 "Screaming Architecture":

"아키텍처는 기능을 외쳐야 한다"

**Before**:
```
service/
port/
adapter/
```
→ 기술 구조만 보인다

**After**:
```
post/save/
post/search/
post/update/
```
→ 비즈니스 기능이 보인다

## 7. 고민했던 지점들

### 7.1. Domain은 어디까지 알아야 할까

**고민 상황**:
```java
// Domain이 Port를 알아도 될까?
public class Post {
    public void publish(PublisherPort port) {  // Port 의존?
        Publisher publisher = port.findById(this.publisherId);
        // ...
    }
}
```

**결론**: 안 된다.
- Domain은 Port를 몰라야 함
- Port는 application의 관심사
- Domain은 순수 Java만

**해결**:
```java
// Domain은 순수 로직만
public class Post {
    public void publish(Publisher publisher) {  // Domain 객체만
        // 검증 로직
    }
}

// Application에서 Port 사용
@Service
public class PostPublishService {
    public void publish(PostId postId) {
        Post post = postPort.findById(postId);
        Publisher publisher = publisherPort.findById(post.getPublisherId());
        
        post.publish(publisher);  // Domain 호출
        
        postPort.save(post);
    }
}
```

### 7.2. Application의 경계

**고민**: 이 검증은 Domain? Application?

```java
// 어디에?
if (command.getTitle().length() > 200) {
    throw new IllegalArgumentException("제목 길이 초과");
}
```

**내가 세운 기준**:

| 종류 | 위치 | 예시 |
|------|------|------|
| **불변 규칙** | Domain | 제목은 필수, 길이 제한 |
| **상태 전이 규칙** | Domain | 발행된 게시물은 삭제 불가 |
| **비즈니스 흐름** | Application | Publisher 조회 후 Post 생성 |
| **트랜잭션** | Application | @Transactional |

### 7.3. Adapter의 비즈니스 로직

**고민**:
```java
// Adapter에서 필터링?
@Component
public class PostSearchAdapter implements PostSearchPort {
    
    @Override
    public List<Post> findAll() {
        return repository.findAll().stream()
                .filter(e -> e.getDeletedAt() == null)  // 비즈니스 로직?
                .map(PostJpaEntity::toDomain)
                .collect(Collectors.toList());
    }
}
```

**내가 세운 기준**:

**허용**:
- 기술적 필터링 (Soft Delete)
- 쿼리 최적화
- Domain ↔ Entity 변환

**불허**:
- 비즈니스 규칙 (특정 상태 필터링)
- 도메인 로직

**해결**:
```java
// 기술적 필터링은 쿼리로
@Query("SELECT p FROM PostJpaEntity p WHERE p.deletedAt IS NULL")
List<PostJpaEntity> findAllNotDeleted();
```


## 8. 멀티 모듈의 의미

### 8.1. 왜 멀티 모듈인가

처음에는 패키지 분리만 했다:

```
src/
├── domain/
├── application/
└── infrastructure/
```

**문제**:
- domain이 application을 import할 수 있음 (의존성 역전 실패)
- domain만 테스트하기 어려움
- 빌드 단위가 불명확

**해결**: 멀티 모듈

```
project/
├── domain/
├── application/
├── infrastructure-jpa/
└── app-api/
``` 

- **의존성 역전을 강제로 지킴**
- 각 모듈 독립적 테스트 가능
- 빌드 단위 명확


### 8.2. 컴파일 타임 의존성 검증

**domain/build.gradle**:
```groovy
plugins {
    id 'java-library'  // Spring 없음
}

dependencies {
    // Spring 의존성 없음
}
```

**효과**:
- domain에서 Spring을 import하면 컴파일 에러
- 의존성 방향을 강제할 수 있음

### 8.3. 독립적 테스트

```bash
./gradlew :domain:test  # domain만 테스트 (빠름)
./gradlew :application:test  # application만 테스트
```

**장점**:
- Spring Context 없이 domain 테스트
- 테스트 속도 향상
- 명확한 테스트 범위

## 9. 내가 정의한 헥사고날 아키텍처

### 9.1. 최종 구조

```
techpost-be/
│
├── domain/                                 # 도메인 계층 (순수 비즈니스 로직)
│   └── src/main/java/com/techpost/domain/
│       └── post/
│           ├── model/                      # 도메인 모델
│           │   ├── Post.java               # 게시글 Aggregate Root
│           │   ├── PostId.java             # 게시글 ID Value Object
│           └── exception/
│               └── PostDomainException.java
│
├── application/                            # 애플리케이션 계층 (Use Case)
│   └── src/main/java/com/techpost/application/
│       └── post/
│           ├── save/                       # 저장 기능 유스케이스
│           │   ├── port/
│           │   │   ├── in/                 # 인바운드 포트
│           │   │   │   ├── PostSaveUseCase.java
│           │   │   │   └── PostSaveCommand.java
│           │   │   └── out/                # 아웃바운드 포트
│           │   │       └── PostSavePort.java
│           │   └── service/
│           │       └── PostSaveService.java
│           └── search/                     # 조회 기능 유스케이스
│               ├── port/
│               │   ├── in/
│               │   │   ├── PostSearchUseCase.java
│               │   │   ├── PostSearchQuery.java
│               │   │   └── PostSearchResult.java
│               │   └── out/
│               │       └── PostSearchPort.java
│               └── service/
│                   └── PostSearchService.java
│
├── infrastructure-jpa/                     # 인프라 계층 (JPA 구현체)
│   └── src/main/java/com/techpost/infrastructure/jpa/
│       ├── common/
│       │   ├── config/
│       │   │   ├── JpaConfig.java
│       │   │   └── QuerydslConfig.java
│       └── post/
│           ├── common/
│           │   ├── entity/
│           │   │   └── PostJpaEntity.java  # JPA 엔티티
│           │   └── repository/
│           │       └── PostJpaRepository.java
│           ├── save/
│           │   └── adapter/out/persistence/
│           │       └── PostSavePersistenceAdapter.java
│           └── search/
│               └── adapter/out/persistence/
│                   └── PostSearchPersistenceAdapter.java
│
└── app-api/                                # API 애플리케이션 (REST API)
   └── src/main/java/com/techpost/
       ├── AppApiApplication.java
       └── appapi/
           ├── common/
           └── post/
               ├── save/
               │   └── adapter/in/web/     # 인바운드 어댑터
               │       ├── PostSaveController.java
               │       └── dto/
               │           ├── PostSaveRequest.java
               │           └── PostSaveResponse.java
               └── search/
                   └── adapter/in/web/     # 인바운드 어댑터
                       ├── PostSearchController.java
                       └── dto/
                           ├── PostSearchRequest.java
                           └── PostSearchResponse.java


```

### 9.2. 각 레이어 책임

**domain**:
- 비즈니스 규칙
- 도메인 모델
- 의존성 없음

**application**:
- 유스케이스 정의 (Inbound Port)
- 외부 의존성 추상화 (Outbound Port) **(의존성역전)**
- 비즈니스 흐름 (Service, 유스케이스 구현)
- 트랜잭션

**infrastructure**:
- Port 구현
- JPA Entity
- Domain ↔ Entity 변환

**app-api**:
- REST API
- 유스케이스 호출
- DTO 변환
- 인증/인가

### 9.3. 핵심 원칙

**1) Domain은 순수하게**:
- Spring, JPA 의존성 없음
- 이 원칙은 절대 지킴

**2) Port로 경계 정의**:
- Inbound: 제공하는 기능
- Outbound: 필요로 하는 기능

**3) 의존성은 안쪽으로**:
- 모든 화살표가 domain을 향함
- 외부가 내부를 의존

**4) 행위 중심 구조**:
- 기능 단위로 코드 응집
- 패키지가 기능을 외침

## 10. 한계와 트레이드오프

### 10.1. 장점

**1) 테스트 용이성**:
```java
// Port를 Mock으로 대체
@Test
void test() {
    PostSavePort mockPort = mock(PostSavePort.class);
    PostSaveService service = new PostSaveService(mockPort);
    
    service.save(command);
    
    verify(mockPort).save(any());
}
```

**2) 기술 교체 유연성**:
- JPA → MyBatis: 1시간
- domain, application: 변경 없음

**3) 명확한 책임**:
- 어디에 코드를 작성할지 명확
- 팀 컨벤션 수립 용이

### 10.2. 단점

**1) 코드량 증가**:
- UseCase, Command, Service, Port, Adapter, Mapper, Domain, Entity
- 간단한 CRUD도 많은 파일 필요
- **'매핑 코드를 유지보수하는 리소스'** 가 필요하다.

예시: 단순한 게시물 저장 하나에도:
```
1. PostSaveUseCase.java (Inbound Port)
2. PostSaveCommand.java (Command)
3. PostSaveService.java (Service)
4. PostSavePort.java (Outbound Port)
5. PostSavePersistenceAdapter.java (Adapter)
6. PostEntityMapper.java (Mapper)
7. Post.java (Domain)
8. PostJpaEntity.java (Entity)
```


**보일러플레이트 코드**: 
- 각 계층을 연결하는 단순 변환 코드가 많아짐
- Domain → Entity, Entity → Domain 변환
- Request → Command, Result → Response 변환
- 실제 비즈니스 로직보다 변환 코드가 더 많을 수 있음

이러한 보일러플레이트는:
- 단순 CRUD에서는 과도하게 느껴짐
- 하지만 복잡한 도메인 로직에서는 명확한 책임 분리의 장점이 더 큼

**2) 학습 곡선**:
- 팀원 교육 시간 필요
- "왜 이렇게 복잡하게?" 질문에 답해야 함

**3) 오버엔지니어링 유혹**:
- 단순한 기능에도 모든 레이어 생성
- 때로는 Service에서 Repository 직접 사용이 더 간단

### 10.3. 적용 기준

내가 세운 기준:

**헥사고날 적용**:
- 도메인 로직이 복잡
- 기술 변경 가능성
- 팀원이 이해 가능

**적용하지 않음**:
- 단순 CRUD
- 빠른 MVP
- 소규모 프로젝트

## 마치며

### 그래서, MVC로는 안 되는 걸까?

결론부터 말하면 **아니다**.
MVC 구조에서도 충분히 좋은 도메인을 만들 수 있다.

문제는 MVC가 아니라,
- Entity = Domain으로 쓰는 관성
- Service에 모든 책임과 규칙을 몰아넣는 구조
- 기술 의존성을 당연하게 받아들이는 문화다.

헥사고날 아키텍처는
"MVC의 대체재"가 아니라
**MVC에서 놓치기 쉬운 경계를 강제로 드러내는 도구**에 가깝다.

포트와 어댑터라는 명시적 구조를 통해
"여기까지는 순수 비즈니스, 여기서부터는 기술"이라는 선을 긋는 것.

그래서 이 아키텍처가 필요한 순간은
복잡도가 높아서가 아니라,
**경계를 명확히 하고 싶을 때**다.

### 이해하게 된 것

헥사고날 아키텍처를 만들어가면서 이해한 것:

**1) 아키텍처는 도구다**:
- 목적이 아니라 수단
- 상황에 맞게 선택

**2) 완벽한 구조는 없다**:
- 트레이드오프가 항상 존재
- 팀과 프로젝트에 맞게 조정

**3) 핵심은 의존성 관리**:
- 구조보다 의존성 방향이 중요
- Domain을 보호하는 것이 목표

### 다음 프로젝트에서 가져갈 것

**반드시 지킬 것**:
- Domain은 순수하게
- 의존성은 안쪽으로

**상황에 맞게**:
- Port 분리 수준
- 멀티 모듈 적용 여부
- 패키지 구조

### 이 글을 쓴 이유

책을 읽으며 이해되지 않았던 나처럼, 헥사고날 아키텍처가 막연한 누군가에게:

"이론"보다 "과정"이 도움이 되길 바라며.

**"직접 만들어보면 이해된다."**

---

