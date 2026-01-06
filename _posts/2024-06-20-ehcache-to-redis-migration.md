---
title: "Ehcache에서 Redis로 전환: 이중화 환경에서 캐시 동기화 문제 해결"
categories: redis
tags: [redis, cache, ehcache, distributed-system, synchronization, pub-sub]
excerpt: "이중화된 서버 환경에서 로컬 캐시의 동기화 문제를 Redis 중앙 캐시로 전환하여 해결하고, 데이터 일관성을 확보한 실전 사례"
---

## 들어가며

이중화된 서버 환경에서 로컬 캐시(Ehcache)를 사용하던 중, **서버마다 다른 캐시 데이터**를 제공하는 문제가 발생했다.

Redis Pub/Sub으로 동기화를 시도했지만, **비동기 단방향 통신의 한계**로 완벽한 해결이 어려웠다.

이 글에서는 Ehcache를 Redis 중앙 캐시로 전환하여 **캐시 동기화 문제를 근본적으로 해결**한 과정을 상세히 기록한다.

---

## 문제 상황

### 시스템 구조

**대상 기능:**
- 동호범위 Selectbox 데이터 캐싱
- 아파트 단지의 동/호수 목록 제공

**현재 구조:**

```
┌─────────────┐        ┌─────────────┐
│  Server A   │        │  Server B   │
│             │        │             │
│  Ehcache    │        │  Ehcache    │
│  (로컬 메모리) │        │ (로컬 메모리)  │
└──────┬──────┘        └──────┬──────┘
       │                      │
       └──────────┬───────────┘
                  │
            ┌─────┴─────┐
            │   Redis   │
            │  Pub/Sub  │
            └───────────┘
```

**캐시 기술:**
- Ehcache (로컬 캐시)
- 각 서버의 메모리 영역에 캐시 저장

**데이터 동기화 방식:**
- 동호범위 관련 데이터 변경 시
- Redis Pub/Sub을 통해 다른 서버에 변경 사항 전달

### 문제점 분석

#### 1. Ehcache의 로컬 캐시 특성

**문제:**

```
사용자가 Server A로 요청 → 동호 데이터 수정 → Server A의 캐시만 갱신
다른 사용자가 Server B로 요청 → 이전 데이터 조회 (캐시 미갱신)
```

**발생 시나리오:**

```
1. 관리자가 "1동 101호" 추가 (Server A 처리)
   └─ Server A Ehcache: 갱신 
   └─ Server B Ehcache: 이전 데이터 

2. 사용자가 동호 목록 조회 (Server B 처리)
   └─ "1동 101호"가 목록에 없음 

3. 30초 후 같은 사용자 재조회 (Server A 처리)
   └─ "1동 101호"가 목록에 있음 

결과: 사용자 혼란 ("방금 없었는데 갑자기 생겼어요?")
```

#### 2. Redis Pub/Sub의 한계

**Redis Pub/Sub 방식:**

```java
// Server A: 데이터 변경 후 메시지 발행
public void updateDongData(CompleDto dto) {
    // 1. DB 업데이트
    dongRepository.save(dong);
    
    // 2. 로컬 캐시 갱신
    ehcacheManager.getCache("dongData").evict(compleId);
    
    // 3. 다른 서버에 알림
    redisTemplate.convertAndSend(
        "cache:evict:dongData", 
        compleId
    );
}

// Server B: 메시지 수신 후 캐시 갱신
@RedisMessageListener
public void onMessage(String message) {
    try {
        String compleId = message;
        ehcacheManager.getCache("dongData").evict(compleId);
    } catch (Eception e) {
        // 문제: 예외 발생 시 폴백 처리 불가
        log.error("캐시 갱신 실패", e);
    }
}
```

**문제점:**

**1) 비동기 단방향 통신**
```
Server A → Redis Pub/Sub → Server B

- Server B가 메시지를 받았는지 확인 불가
- 처리 성공 여부를 알 수 없음
```

**2) 폴백 처리 불가능**
```
네트워크 문제 발생 → 메시지 전달 실패 → 캐시 미반영
Server B에서 예외 발생 → 캐시 갱신 실패 → 데이터 불일치
```

**3) 캐시 동기화 실패 사례**

```
시나리오 1: 네트워크 지연
- Server A: 메시지 발행
- Network Delay...
- Server B: 메시지 수신 지연 (10초 후)
- 그 사이 사용자 요청: 이전 데이터 조회 

시나리오 2: Server B 재시작 중
- Server B: 재부팅 중
- Server A: 메시지 발행
- Server B: 메시지 유실 (구독 중단)
- 재시작 후에도 이전 캐시 유지 

시나리오 3: 예외 발생
- Server B: 메시지 수신
- Ehcache 예외 발생 (메모리 부족, 락 등)
- 캐시 갱신 실패 
```

#### 3. 결과: 데이터 불일치

**조회 API 응답이 서버마다 다름:**

```
# 같은 단지 ID로 조회

Server A 응답:
{
  "dongs": ["1동", "2동", "3동", "101동"]  // 최신
}

Server B 응답:
{
  "dongs": ["1동", "2동", "3동"]  // 이전 데이터
}
```

**사용자 경험 저하:**
- "왜 새로고침하면 데이터가 달라져요?"
- "방금 추가한 동이 안 보여요"
- "다른 컴퓨터에서는 보이는데 제 화면에서는 안 보여요"

---

## 해결 방안

### 전략: Ehcache → Redis 전환

**핵심 아이디어:**
> 분산된 로컬 캐시를 중앙 집중식 캐시로 전환하여 **단일 진실 공급원(Single Source of Truth)** 구축

**변경 후 구조:**

```
┌─────────────┐        ┌─────────────┐
│  Server A   │        │  Server B   │
│             │        │             │
│  (캐시 없음)  │        │  (캐시 없음)  │
└──────┬──────┘        └──────┬──────┘
       │                      │
       └──────────┬───────────┘
                  │
            ┌─────┴─────┐
            │   Redis   │
            │ (중앙 캐시) │
            └───────────┘
```

### 변경 전후 비교

| 항목 | 변경 전 (Ehcache) | 변경 후 (Redis) |
|------|-------------------|-----------------|
| **캐시 저장 위치** | 각 서버 메모리 (로컬) | 중앙 Redis 서버 (공유) |
| **동기화 방식** | Pub/Sub (비동기) | 불필요 (공통 저장소) |
| **데이터 일관성** | 서버마다 다름 | 모든 서버 동일 |
| **장애 대응** | 폴백 불가 | Redis 장애 시만 영향 |
| **확장성** | 서버 추가 시 동기화 복잡도 증가 | 서버 추가 시 영향 없음 |
| **운영 복잡도** | 높음 (동기화 관리) | 낮음 (단순 조회) |

---

## 사전 분석

### 1. 용량 측정

**목적:**
Redis에 적재해도 되는 적절한 용량인지 확인

**측정 대상:**
약 797세대 → 800세대로 가정

**API 요청:**

```bash
GET https://eample.com/comple/1/dong
```

**응답 데이터 예시:**

```json
{
  "dongs": [
    {
      "dong": "101동",
      "hoList": [
        {"ho": "101", ..},
        {"ho": "102", ..},
        ...
      ]
    },
    {
      "dongName": "102동",
      "hoList": [...]
    },
    ...
  ]
}
```

**용량 측정 방법:**

Redis Insight Tool에서 실제 JSON 데이터를 추가하여 측정:

```
Key: comple:dong:1
Value: (위 JSON 데이터)
```

**측정 결과:**

```
800세대 기준: 6 KB
```

**용량 계산:**

```
1세대당 용량 = 6 KB / 800세대 = 0.0075 KB = 7.5 Bytes

목표 세대 수: 1,000,000세대
예상 용량 = 1,000,000세대 × 7.5 Bytes = 7,500,000 Bytes = 7.5 MB
```

**결론:**
100만 세대 기준 **7.5MB**로 Redis에 충분히 저장 가능한 용량

### 2. Redis 가용 메모리 확인

**확인 방법:**

Redis Insight CLI에서 실행:

```bash
INFO MEMORY
```

**결과:**

```
# Memory
used_memory:563642016
used_memory_human:537.53M
used_memory_peak:1103483064
used_memory_peak_human:1.03G
used_memory_peak_perc:51.08%
used_memory_dataset:540897000
used_memory_dataset_perc:96.10%
total_system_memory:16791674880
total_system_memory_human:15.64G
mamemory:0
mamemory_human:0B
mamemory_policy:allkeys-lru
mem_fragmentation_ratio:1.06
```

**주요 지표 해석:**

| 항목 | 값 | 설명 |
|------|-----|------|
| **used_memory** | 537.53 MB | 현재 Redis 사용 중인 메모리 |
| **used_memory_peak** | 1.03 GB | 가장 많이 사용했던 시점의 메모리 |
| **total_system_memory** | 15.64 GB | Redis 인스턴스 실행 중인 시스템 전체 메모리 |
| **mamemory** | 0 (제한 없음) | 메모리 제한 없음 (계속 증가 가능) |
| **mamemory_policy** | allkeys-lru | 메모리 부족 시 LRU 방식으로 키 제거 |
| **mem_fragmentation_ratio** | 1.06 | 단편화 비율 낮음 (정상) |

**판단:**

```
현재 사용량: 537 MB
가용 메모리: 15 GB
추가 필요 용량: 7.5 MB (100만 세대 기준)

537 MB + 7.5 MB = 544.5 MB << 15 GB

결론: 용량 문제 없다고 판단
```

### 3. 대단지 성능 테스트

**목적:**
대규모 데이터에서도 성능이 문제없는지 확인

**테스트 대상:**
3,691세대 대단지 데이터

**예상 용량:**

```
3,691세대 × 7.5 Bytes = 27,682.5 Bytes ≈ 28 KB
```

**측정:**

```bash
GET https://eample.com/comple/2/dong
```

```
Redis에 저장된 용량: 28 KB
조회 응답 시간: 15ms (평균)
```

**결론:**
대단지도 충분히 빠른 응답 속도 (15ms) 

---

## 구현

### 1단계: Redis 캐시 설정

**build.gradle 의존성 추가:**

```gradle
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-data-redis'
    implementation 'org.springframework.boot:spring-boot-starter-cache'
}
```

**application.yml 설정:**

```yaml
spring:
  redis:
    host: redis-eample.com
    port: 6379
    password: ${REDIS_PASSWORD}
    timeout: 3000ms
    lettuce:
      pool:
        ma-active: 10
        ma-idle: 10
        min-idle: 2
  
  cache:
    type: redis
    redis:
      time-to-live: 3600000  # 1시간
      cache-null-values: false
      key-prefi: "cache:"
```

### 2단계: Redis Cache Configuration

**RedisCacheConfig.java:**

```java
@Configuration
@EnableCaching
public class RedisCacheConfig {
    
    @Bean
    public RedisCacheManager cacheManager(
        RedisConnectionFactory connectionFactory
    ) {
        // 기본 캐시 설정
        RedisCacheConfiguration defaultConfig = RedisCacheConfiguration
            .defaultCacheConfig()
            .serializeKeysWith(
                RedisSerializationContet.SerializationPair
                    .fromSerializer(new StringRedisSerializer())
            )
            .serializeValuesWith(
                RedisSerializationContet.SerializationPair
                    .fromSerializer(new GenericJackson2JsonRedisSerializer())
            )
            .entryTtl(Duration.ofHours(1))  // 기본 1시간
            .disableCachingNullValues();
        
        // 캐시별 커스텀 설정
        Map<String, RedisCacheConfiguration> cacheConfigurations = 
            new HashMap<>();
        
        // 동호 데이터: 1시간 TTL
        cacheConfigurations.put(
            "dongData",
            defaultConfig.entryTtl(Duration.ofHours(1))
        );
        
        return RedisCacheManager.builder(connectionFactory)
            .cacheDefaults(defaultConfig)
            .withInitialCacheConfigurations(cacheConfigurations)
            .build();
    }
}
```

### 3단계: 서비스 코드 변경

**[AS-IS] Ehcache 사용:**

```java
@Service
@RequiredArgsConstructor
public class DongService {
    
    private final DongRepository dongRepository;
    private final CacheManager ehcacheManager;
    private final RedisTemplate<String, String> redisTemplate;
    
    @Cacheable(value = "dongData", key = "#compleId")
    public List<DongDto> getDongList(Long compleId) {
        // Ehcache에 캐싱됨 (로컬 메모리)
        return dongRepository.findByCompleId(compleId)
            .stream()
            .map(DongDto::from)
            .collect(Collectors.toList());
    }
    
    @Transactional
    public void updateDong(DongDto dto) {
        // 1. DB 업데이트
        Dong dong = dongRepository.save(Dong.from(dto));
        
        // 2. 로컬 캐시 삭제
        ehcacheManager.getCache("dongData").evict(dto.getCompleId());
        
        // 3. 다른 서버에 캐시 삭제 메시지 발행
        redisTemplate.convertAndSend(
            "cache:evict:dongData",
            dto.getCompleId().toString()
        );
    }
}

// 메시지 리스너
@Component
@RequiredArgsConstructor
public class CacheEvictListener {
    
    private final CacheManager ehcacheManager;
    
    @RedisMessageListener(topic = "cache:evict:dongData")
    public void onCacheEvictMessage(String compleId) {
        try {
            ehcacheManager.getCache("dongData").evict(
                Long.parseLong(compleId)
            );
            log.info("캐시 삭제 완료: {}", compleId);
        } catch (Eception e) {
            // 예외 발생 시 폴백 불가능
            log.error("캐시 삭제 실패: {}", compleId, e);
        }
    }
}
```

**[TO-BE] Redis 캐시 사용:**

```java
@Service
@RequiredArgsConstructor
public class DongService {
    
    private final DongRepository dongRepository;
    
    // Redis 캐시 자동 적용
    @Cacheable(
        value = "dongData",
        key = "#compleId",
        unless = "#result == null || #result.isEmpty()"
    )
    public List<DongDto> getDongList(Long compleId) {
        log.info("DB 조회 - compleId: {}", compleId);
        
        return dongRepository.findByCompleId(compleId)
            .stream()
            .map(DongDto::from)
            .collect(Collectors.toList());
    }
    
    @Transactional
    @CacheEvict(value = "dongData", key = "#dto.compleId")
    public void updateDong(DongDto dto) {
        // 1. DB 업데이트
        Dong dong = dongRepository.save(Dong.from(dto));
        
        // 2. Redis 캐시 자동 삭제 (@CacheEvict)
        // 3. Pub/Sub 불필요 (중앙 캐시이므로)
        
        log.info("동 정보 업데이트 완료 - compleId: {}", dto.getCompleId());
    }
    
    @CacheEvict(value = "dongData", key = "#compleId")
    public void evictCache(Long compleId) {
        log.info("캐시 수동 삭제 - compleId: {}", compleId);
    }
    
    @CacheEvict(value = "dongData", allEntries = true)
    public void evictAllCache() {
        log.info("전체 동 캐시 삭제");
    }
}
```

**주요 변경 사항:**

1. **Ehcache 제거**
   - CacheManager 의존성 제거
   - 수동 캐시 관리 코드 제거

2. **Redis Pub/Sub 제거**
   - RedisTemplate 메시지 발행 제거
   - CacheEvictListener 제거
   - 동기화 로직 불필요

3. **Spring Cache 어노테이션 활용**
   - `@Cacheable`: 자동 캐싱
   - `@CacheEvict`: 자동 캐시 삭제
   - 선언적 캐싱으로 코드 간결화

### 4단계: 캐시 키 전략

**캐시 키 구조:**

```
cache:dongData::{compleId}

예시:
cache:dongData::1
cache:dongData::2
```

**Redis 저장 데이터 구조:**

```json
{
  "@class": "com.eample.dto.DongDto",
  "compleId": 1,
  "dongs": [
    {
      "dong": "101동",
      "hoList": [
        {"ho": "101", "area": "84.9"},
        {"ho": "102", "area": "84.9"}
      ]
    }
  ]
}
```

---

## 검증

### 1. 캐시 동작 확인

**시나리오: 동 정보 조회**

```bash
# 1차 조회 (Cache Miss)
GET /api/comple/1/dong

로그:
[DongService] DB 조회 - compleId: 1
[Redis] 캐시 저장 - Key: cache:dongData::1

응답 시간: 150ms (DB 조회 시간 포함)

# 2차 조회 (Cache Hit)
GET /api/comple/1/dong

로그:
[Redis] 캐시 조회 - Key: cache:dongData::1
(DB 조회 로그 없음)

응답 시간: 15ms (Redis 조회만)
```

**Redis Insight로 확인:**

```bash
# Redis CLI
127.0.0.1:6379> KEYS cache:dongData::*
1) "cache:dongData::1"
2) "cache:dongData::2"

127.0.0.1:6379> GET cache:dongData::1
"{\"compleId\":1,...}"

127.0.0.1:6379> TTL cache:dongData::1
(integer) 3456  # 3456초 남음 (약 58분)
```

### 2. 캐시 삭제 확인

**시나리오: 동 정보 수정**

```bash
# 동 정보 수정 요청
PUT /api/comple/1/dong
{
  "dong": "101동",
  "hoList": [...]
}

로그:
[DongService] 동 정보 업데이트 완료 - compleId: 1
[Redis] 캐시 삭제 - Key: cache:dongData::1

# 수정 후 즉시 조회
GET /api/comple/1/dong

로그:
[DongService] DB 조회 - compleId: 1 (캐시 삭제되어 DB 조회)
[Redis] 캐시 저장 - Key: cache:dongData::1

결과: 수정된 데이터 즉시 반영 
```

### 3. 서버 간 데이터 일관성 확인

**시나리오: 서버 A에서 수정, 서버 B에서 조회**

```
1. Server A로 동 정보 수정 요청
   POST /api/comple/1/dong
   
   Server A 로그:
   [DongService] 동 정보 업데이트 완료
   [Redis] 캐시 삭제 - cache:dongData::1

2. Server B로 동 정보 조회 요청 (즉시)
   GET /api/comple/1/dong
   
   Server B 로그:
   [DongService] DB 조회 - compleId: 1
   [Redis] 캐시 저장 - cache:dongData::1
   
   결과: 수정된 최신 데이터 조회 

3. Server B로 재조회 (캐시 히트)
   GET /api/comple/1/dong
   
   Server B 로그:
   [Redis] 캐시 조회 - cache:dongData::1
   (DB 조회 없음)
   
   결과: 동일한 최신 데이터 조회 
```

**결론:**
서버 A에서 수정한 내용이 서버 B에서도 **즉시 반영** 확인

### 4. 성능 비교

**측정 환경:**
- 단지: 3,691세대
- 측정 횟수: 100회
- 측정 방식: JMeter

**결과:**

| 구분 | Ehcache (기존) | Redis (변경 후) |
|------|----------------|-----------------|
| **Cache Miss (DB 조회)** | 150ms | 150ms |
| **Cache Hit** | 5ms | 15ms |
| **평균 응답 시간** | 10ms | 18ms |
| **데이터 일관성** | 불일치 발생 | 100% 일관성 |

**분석:**

**성능:**
- Redis가 Ehcache보다 약간 느림 (10ms → 18ms)
- 하지만 여전히 충분히 빠름 (20ms 이하)
- 네트워크 통신 비용 (약 8ms)

**일관성:**
- Ehcache: 서버마다 다른 데이터 (불일치 발생)
- Redis: 모든 서버 동일한 데이터 (100% 일관성)

**결론:**
약간의 성능 저하를 감수하고 **데이터 일관성 확보**

---

## 기대 효과

### 1. 데이터 일관성 확보

**Before:**
```
Server A: ["1동", "2동", "3동", "101동"]
Server B: ["1동", "2동", "3동"]
→ 불일치
```

**After:**
```
Server A: Redis에서 조회 → ["1동", "2동", "3동", "101동"]
Server B: Redis에서 조회 → ["1동", "2동", "3동", "101동"]
→ 일치 
```

### 2. 구조 간소화

**Before:**
```
동 정보 업데이트 로직:
1. DB 저장
2. 로컬 Ehcache 삭제
3. Redis Pub/Sub 메시지 발행
4. 다른 서버에서 메시지 수신
5. 다른 서버 Ehcache 삭제
6. 예외 처리 로직

총 6단계 + 예외 처리
```

**After:**
```
동 정보 업데이트 로직:
1. DB 저장
2. Redis 캐시 자동 삭제 (@CacheEvict)

총 2단계 (자동화)
```

### 3. 장애 리스크 제거

**Before:**
```
가능한 장애:
- Pub/Sub 메시지 전달 실패
- 메시지 수신 서버 예외 발생
- 네트워크 지연으로 인한 타이밍 이슈
- 서버 재시작 중 메시지 유실
```

**After:**
```
가능한 장애:
- Redis 서버 장애 (이 경우 DB 조회로 폴백)
```

### 4. 운영 편의성 향상

**모니터링:**
```bash
# Redis Insight로 실시간 캐시 현황 확인
- 캐시 키 목록
- 캐시 용량
- TTL 남은 시간
- 캐시 히트율
```

**수동 캐시 관리:**
```bash
# 필요 시 수동으로 캐시 삭제 가능
127.0.0.1:6379> DEL cache:dongData::1
(integer) 1
```

### 5. 확장성 향상

**서버 추가 시:**

**Before (Ehcache + Pub/Sub):**
```
- 새 서버에 Pub/Sub 리스너 설정 필요
- 기존 서버와 동기화 설정 필요
- 복잡도 (N)
```

**After (Redis):**
```
- 새 서버는 그냥 Redis 연결만 하면 됨
- 추가 설정 불필요
- 복잡도 (1)
```

---

## 추가 고려사항

### 1. Redis 장애 대응

**문제:**
Redis 서버가 다운되면 캐시를 사용할 수 없음

**해결 방법 1: Redis 센티널 (고가용성)**

**해결 방법 2: 캐시 실패 시 폴백**

```java
@Service
public class DongService {
    
    @Cacheable(value = "dongData", key = "#compleId")
    public List<DongDto> getDongList(Long compleId) {
        return getDongListFromDB(compleId);
    }
    
    // 캐시 실패 시 자동으로 이 메서드 호출됨
    private List<DongDto> getDongListFromDB(Long compleId) {
        return dongRepository.findByCompleId(compleId)
            .stream()
            .map(DongDto::from)
            .collect(Collectors.toList());
    }
}
```

### 2. 캐시 워밍업

**문제:**
서버 재시작 후 첫 요청이 느림 (Cache Miss)

**해결:**

```java
@Component
@RequiredArgsConstructor
public class CacheWarmer {
    
    private final DongService dongService;
    private final CompleRepository compleRepository;
    
    @EventListener(ApplicationReadyEvent.class)
    public void warmUpCache() {
        log.info("캐시 워밍업 시작");
        
        // 주요 단지의 동 정보 미리 로드
        List<Long> majorCompleIds = compleRepository
            .findMajorCompleIds();
        
        majorCompleIds.forEach(compleId -> {
            try {
                dongService.getDongList(compleId);
                log.info("캐시 로드 완료: {}", compleId);
            } catch (Eception e) {
                log.warn("캐시 로드 실패: {}", compleId, e);
            }
        });
        
        log.info("캐시 워밍업 완료");
    }
}
```

---

## 정리

### 핵심 요약

**1. 문제 상황**
- Ehcache 로컬 캐시: 서버마다 다른 데이터
- Redis Pub/Sub: 비동기 단방향, 폴백 불가
- 결과: 데이터 불일치, 사용자 혼란

**2. 해결 방법**
- Ehcache → Redis 중앙 캐시 전환
- Pub/Sub 동기화 로직 제거
- Spring Cache 어노테이션 활용

**3. 개선 효과**
- 데이터 일관성: 100% 확보
- 구조 간소화: 6단계 → 2단계
- 장애 리스크: 대폭 감소
- 운영 편의성: 향상

**4. 트레이드오프**
- 성능: 10ms → 18ms (약간 느림)
- 일관성: 불일치 → 완전 일치
- 결론: 성능보다 일관성이 중요

### 설계 원칙

**1. 단일 진실 공급원 (Single Source of Truth)**
> 분산 환경에서는 중앙 집중식 데이터 저장소가 일관성을 보장한다.

**2. 간결함 (Simplicity)**
> 복잡한 동기화 로직보다 간단한 중앙 캐시가 유지보수에 유리하다.

**3. 실용주의 (Pragmatism)**
> 완벽한 성능보다 안정적인 일관성이 사용자 경험에 더 중요하다.

### 적용 시 고려사항

**Redis 캐시 전환이 적합한 경우:**
- [ ] 이중화된 서버 환경
- [ ] 데이터 일관성이 중요
- [ ] 캐시 데이터가 자주 변경됨
- [ ] 실시간 동기화 필요
- [ ] 캐시 용량이 적당함 (수십 MB 이하)

**Ehcache가 적합한 경우:**
- [ ] 단일 서버 환경
- [ ] 읽기 전용 데이터 (변경 없음)
- [ ] 초고속 응답 필요 (5ms 이하)
- [ ] 네트워크 비용 최소화

### 마지막으로

**캐시는 성능 최적화 수단이지만, 일관성을 해치면 안 된다.**

이중화 환경에서 로컬 캐시는 **데이터 불일치**라는 더 큰 문제를 야기할 수 있다.

약간의 성능을 희생하더라도 **중앙 집중식 캐시**로 일관성을 확보하는 것이 장기적으로 더 나은 선택이다.

**"빠른 것보다 올바른 것이 먼저다."**

---
