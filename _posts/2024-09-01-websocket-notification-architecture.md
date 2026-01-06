---
title: "WebSocket + Redis Pub/Sub으로 실시간 알림 시스템 구축기"
categories: Backend
tags: [WebSocket, STOMP, Redis, Spring Boot, Vue.js]
excerpt: "WebSocket + STOMP + Redis Pub/Sub로 구축한 실시간 알림 시스템. 서버 분리, 확장성, 자동 재연결까지 고려한 실무 설계 사례"
---

## 들어가며

우리 시스템에는 여러 가지 비동기 처리가 필요한 영역이 있었다.

- 관리비 부과 처리 (배치 처리)
- 알림톡 발송
- 사용자 실시간 알림 (공지사항, 민원 등)

하지만 이러한 기능들이 제대로 동작하지 않거나, 사용자가 결과를 확인하기 위해서는 페이지를 새로고침하거나 주기적으로 확인해야 하는 불편함이 있었다. 특히 공지사항과 같은 중요한 알림은 실시간으로 전달되지 않아 사용자 경험이 아쉬웠다.

이를 개선하고자 실시간 알림 기능을 만들기로 결정했다.

이 글은 알림 기능을 기획부터 설계, 개발까지 전 과정을 기록한 내용이다.

## 1. 요구사항 정리

### 1.1. 현재 시스템의 문제점

**사용자 관점**
- 새로운 공지사항이 등록되어도 알 수 없음
- 페이지를 새로고침해야만 새로운 내용 확인 가능
- 중요한 공지를 놓칠 수 있음

**기술적 관점**
- 폴링(Polling) 방식 사용 시:
  - 불필요한 서버 요청 증가
  - 네트워크 트래픽 낭비
  - 실시간성 부족 (주기적 확인)
- 비동기 처리 결과를 사용자에게 전달할 방법 없음

### 1.2. 기능 요구사항

**필수 기능**
- 서버에서 클라이언트로 즉시 알림 전달 (Push 방식)
- 사용자별 알림 구독 (내가 받아야 할 알림만 수신)
- 단지별 알림 지원 (특정 단지의 사용자들에게만 전달)
- 토스트 메시지 형태로 알림 표시
- 알림 클릭 시 관련 페이지로 이동

**비기능 요구사항**
- 네트워크 장애 시 자동 재연결
- 서버 확장 가능한 구조
- 인증 기반 보안
- 알림 이력 관리 (DB 저장)

### 1.3. 대상 사용자

**사용자 알림**
- 시스템 공지사항
- 긴급 공지
- 서비스 점검 안내

**단지 사용자 알림**
- 단지별 공지사항
- 단지 내 이벤트 (민원등록, 행사 등)
- 단지별 관리비 부과 완료 알림

### 1.4. 성공 기준

- 알림 발송 후 1초 이내 사용자에게 전달
- 네트워크 장애 발생 시 30초 이내 자동 재연결
- 알림 전달 실패율 1% 이하
- 서버 부하 감소 (폴링 대비)

## 2. 기술 선택

### 2.1. 실시간 통신 방식 비교

실시간 알림을 구현하기 위한 방법을 검토했다.

**Polling (단기 폴링)**
- 클라이언트가 주기적으로 서버에 요청
- 장점: 구현 간단
- 단점:
  - 불필요한 요청 증가
  - 실시간성 부족 (폴링 주기만큼 지연)
  - 서버 부하 증가

**Server-Sent Events (SSE)**
- 서버에서 클라이언트로 단방향 스트리밍
- 장점: 간단한 구현, HTTP 기반
- 단점:
  - 단방향 통신만 가능
  - 브라우저 연결 수 제한 (6개)

**WebSocket**
- 양방향 실시간 통신
- 장점:
  - 진짜 실시간 통신
  - 낮은 레이턴시
  - 양방향 통신 가능
  - 표준 프로토콜
- 단점:
  - 구현 복잡도 증가
  - 프록시/방화벽 이슈 가능

결론: WebSocket 선택
- 실시간성이 가장 중요한 요구사항
- 향후 양방향 통신 기능 확장 가능성 (채팅 등)
- Spring Boot의 WebSocket 지원 우수

### 2.2. STOMP 프로토콜

WebSocket은 저수준 프로토콜이기 때문에, 메시지 라우팅과 구독 관리를 위해 상위 프로토콜이 필요했다.

**STOMP (Simple Text Oriented Messaging Protocol)**
- WebSocket 위에서 동작하는 메시징 프로토콜
- Pub/Sub 패턴 지원
- 구독(Subscribe) 기반 메시지 라우팅
- Spring Boot에서 완벽 지원

**왜 STOMP인가?**
- 사용자별, 단지별 구독 경로 관리 용이
- 메시지 브로커 패턴 사용 가능
- 클라이언트 라이브러리 풍부 (SockJS, stomp.js)

### 2.3. Redis Pub/Sub

WebSocket 의 수평 확장을 고려하여 즉, WebSocket 서버가 여러 대일 때, 어떤 서버에 연결된 사용자에게도 알림을 전달해야 했다.

**문제 상황**
```
사용자 A → WebSocket 서버 1
사용자 B → WebSocket 서버 2

app-api 서버에서 알림 발송
→ WebSocket 서버 1에만 전달?
→ 사용자 B는 알림 받지 못함!
```

**해결 방법: Redis Pub/Sub**
- 모든 WebSocket 서버가 Redis를 구독
- app-api는 Redis에 메시지 발행
- 모든 WebSocket 서버가 메시지 수신 후 클라이언트에 전달

**장점**
- app-api와 websocket-api 간 느슨한 결합
- 수평 확장 가능 (WebSocket 서버 N대 가능)
- 이미 Redis를 사용 중이라 추가 인프라 불필요

### 2.4. 최종 기술 스택

**백엔드**
- Spring Boot 2.x
- Spring WebSocket (STOMP)
- Redis Pub/Sub
- JPA (알림 이력 관리)

**프론트엔드**
- Vue.js 2.x
- Vuex (상태 관리)
- SockJS (WebSocket Fallback)
- stomp.js (STOMP 클라이언트)

**인증**
- JWT (Bearer Token)
- STOMP 인터셉터로 인증 처리

## 3. 시스템 설계

이 장에서는 알림 시스템을 구성하는 요소와 각 컴포넌트의 책임을 설명한다.
실제 동작 순서는 다음 장에서 다룬다.

### 3.1. 서비스 구성과 책임

시스템은 크게 4개의 서비스로 구성된다.

| 서비스 | 책임 | 주요 컴포넌트 |
|--------|------|---------------|
| **app-api** | 알림 생성, 도메인 규칙, Redis 메시지 발행 | NoticeService<br>NotificationNotifier<br>RedisNotificationPublisher |
| **redis** | 서버 간 메시지 브로커 (Pub/Sub) | Topic: /notification/user<br>Topic: /notification/complex/user |
| **websocket-api** | Redis 메시지 구독, WebSocket 세션 관리 | RedisNotificationSubscriber<br>SimpMessagingTemplate |
| **app-fe** | WebSocket 연결, 알림 UI 표시 | WebSocketClient<br>NotificationToastMessage |

### 3.2. 통신 구조

**핵심 원칙**: app-api와 websocket-api는 직접 통신하지 않는다.

```
app-api  →  Redis Pub/Sub  →  websocket-api  →  app-fe
```

**왜 이렇게 설계했는가?**

- **느슨한 결합**: app-api는 websocket-api의 존재를 알 필요 없음
- **수평 확장**: websocket-api 서버를 N대로 확장 가능
- **장애 격리**: websocket-api 장애가 app-api에 영향 주지 않음

### 3.3. app-api 내부 구조

app-api는 알림 발송 책임을 추상화하여 관리한다.

```
NoticeService (비즈니스 로직)
    │
    ▼
NoticeNotificationNotifier (Factory Pattern)
    ├─> NoticeAllUserNotificationNotifier (사용자 알림)
    └─> NoticeComplexUserNotificationNotifier (단지 사용자 알림)
              │
              ▼
    AbstractNotificationNotifier (Template Method)
              │
              ├─> 알림 타입 조회
              ├─> Notification 엔티티 생성 및 저장
              ├─> 메시지 변환 (Converter)
              └─> Redis 발행 (Publisher)
```

**적용된 설계 패턴**:
- **Factory Pattern**: 알림 대상에 따라 적절한 Notifier 선택
- **Template Method**: 알림 발송 프로세스의 공통 로직 정의
- **Strategy Pattern**: 메시지 변환 및 발행 전략 분리

### 3.4. websocket-api 내부 구조

websocket-api는 Redis 메시지를 받아 WebSocket으로 전송한다.

```
RedisNotificationSubscriber (Redis 구독)
    │
    ├─> RedisUserNotificationSubscriber
    │       └─> onMessage() → UserNotificationMessageSender
    │
    └─> RedisComplexUserNotificationSubscriber
            └─> onMessage() → ComplexUserNotificationMessageSender
                                    │
                                    ▼
                        SimpMessagingTemplate (STOMP)
                                    │
                                    ▼
                            /topic/notification/...
```

**WebSocket 구독 경로**:
- 사용자 알림: `/topic/notification/user/{userSeq}`
- 단지 사용자 알림: `/topic/notification/complex/{complexSeq}/user/{userSeq}`

### 3.5. app-fe 내부 구조

app-fe는 WebSocket 연결과 알림 UI를 관리한다.

```
WebSocketClient (Singleton)
    ├─> SockJS + STOMP 연결
    ├─> JWT 인증
    └─> 자동 재연결 (Exponential Backoff)
         │
         ▼
Vuex Store
    ├─> webSocket Module (연결 상태 관리)
    └─> notification Module (알림 상태 관리)
         │
         ▼
NotificationToastMessage (Singleton)
    └─> 토스트 UI 생성 및 관리 (최대 3개)
```

---

지금까지는 알림 시스템을 구성하는 구조와 역할을 설명했다.
다음 장에서는 이 구조가 실제로 어떤 순서로 동작하는지를 살펴본다.

## 4. 알림 동작 플로우

- 3장에서 설명한 시스템 구조가 실제로 어떻게 동작하는지를 **관리자 공지사항 등록** 시나리오를 바탕으로 시간 순서로 설명한다.

### 4.1. 사용자 로그인: WebSocket 연결 

알림을 받기 위해서는 먼저 WebSocket 연결이 맺어져 있어야 한다.

```
1. 사용자 로그인 (Browser → app-api)
   ↓
2. 로그인 성공 후 JWT Token 발급
   ↓
3. app-fe에서 WebSocket 연결 시도
   │
   │ const socket = new SockJS('/ws')
   │ stompClient = Stomp.over(socket)
   │ stompClient.connect({ Authorization: `Bearer ${token}` })
   ↓
4. websocket-api에서 JWT 검증 (StompAuthInterceptor)
   ↓
5. 연결 성공
   ↓
6. app-fe에서 토픽 구독
   │
   │ stompClient.subscribe(
   │   '/topic/notification/user/{userSeq}',
   │   (message) => { /* 알림 수신 처리 */ }
   │ )
   │
   │ stompClient.subscribe(
   │   '/topic/notification/complex/{complexSeq}/user/{userSeq}',
   │   (message) => { /* 알림 수신 처리 */ }
   │ )
   ↓
7. 연결 완료 (isConnected = true)
```

이제 사용자는 실시간 알림을 받을 준비가 완료되었다.

### 4.2. 공지사항 등록: 알림 전송

**단계별 흐름**

```
1. 관리자가 공지사항 등록 (Browser → app-api)
   ↓
2. app-api에서 Notice / Notification 엔티티 저장 (DB)
   ↓
3. Redis로 알림 이벤트 발행
   ↓
4. websocket-api가 Redis 메시지 수신
   ↓
5. 사용자별 WebSocket destination으로 전송
   ↓
6. app-fe에서 토스트 표시
   ↓
7. Browser에 토스트 UI 렌더링
```

#### 4.3. 연결 끊김: 재연결 플로우

소켓통신은 연결이 끊길 수 있는 상황을 고려해야 한다.

- 네트워크 장애
- 서버 재시작
- 브라우저 탭 전환 등
- 사용자 행동 (뒤로 가기, 새로고침)

```
1. 연결 끊김 감지 (onclose 이벤트)
   ↓
2. reconnect() 함수 실행
   ↓
3. 대기 시간 계산
   - delay = Math.min(1000 * 2 ** retryCount, 30000)
   - 1초 → 2초 → 4초 → 8초 → 16초 → 30초 (최대)
   ↓
4. setTimeout 후 재연결 시도
   ↓
5. connect() 재실행 (retryCount + 1)
```

---

## 5. 백엔드 설계 패턴

### 5.1. Factory Pattern

**NoticeNotificationNotifier**

```java
@Service
@RequiredArgsConstructor
public class NoticeNotificationNotifier {
    private final NoticeAllUserNotificationNotifier noticeAllUserNotificationNotifier;
    private final NoticeComplexUserNotificationNotifier noticeComplexUserNotificationNotifier;

    public void notify(Notice notice) {
        if (NoticeTargetEnum.ALL.getCode().equals(notice.getNoticeTargetEnum())) {
            noticeAllUserNotificationNotifier.notify(notice);
        } else {
            noticeComplexUserNotificationNotifier.notify(notice);
        }
    }
}
```

장점:
- 클라이언트 코드에서 구현체 선택 로직 분리
- 새로운 알림 타입 추가 시 팩토리만 수정
- NoticeService의 복잡도 감소

### 5.2. Template Method Pattern

**AbstractNotificationNotifier**

```java
public abstract class AbstractNotificationNotifier<T, M extends NotificationMessage> {
    
    @Transactional
    public void notify(T domain) {
        try {
            // 1. 알림 타입 조회
            NotificationType notificationType = findNotificationType();

            // 2. 도메인 → Notification 변환 (하위 클래스 구현)
            List<Notification> notifications = 
                convertToNotifications(domain, notificationType);

            // 3. DB 저장
            saveNotifications(notifications);

            // 4. 메시지 변환
            List<M> messages = 
                getMessageConverter().convertToMessages(notifications);

            // 5. Redis 발행
            getMessagePublisher().publish(messages);

        } catch (Exception e) {
            log.error("알림 처리 중 오류 발생", e);
            throw new RuntimeException("알림 처리 실패", e);
        }
    }

    // 하위 클래스에서 구현
    protected abstract NotificationTypeCode getNotificationTypeCode();
    protected abstract List<Notification> convertToNotifications(
        T domain, NotificationType notificationType
    );
    protected abstract NotificationMessageConverter<M> getMessageConverter();
    protected abstract NotificationMessagePublisher<M> getMessagePublisher();
}
```

장점:
- 알림 발송 프로세스의 공통 로직 재사용
- 확장 포인트 명확화
- 새로운 알림 타입 추가 용이

**상속 구조**:
```
AbstractNotificationNotifier
    ├─> AbstractUserNotificationNotifier
    │       └─> NoticeAllUserNotificationNotifier
    │
    └─> AbstractComplexUserNotificationNotifier
            └─> NoticeComplexUserNotificationNotifier
```

### 5.3. Strategy Pattern

**Converter & Publisher**

```java
// 인터페이스
public interface NotificationMessageConverter<M> {
    List<M> convertToMessages(List<Notification> notifications);
}

public interface NotificationMessagePublisher<M> {
    void publish(List<M> messages);
}

// 구현체
@Component
public class UserNotificationMessageConverter 
    implements NotificationMessageConverter<UserNotificationMessage> {
    // 구현...
}

@Component
public class ComplexUserNotificationMessageConverter 
    implements NotificationMessageConverter<ComplexUserNotificationMessage> {
    // 구현...
}
```

장점:
- 메시지 변환/발행 전략을 런타임에 교체 가능
- 새로운 메시지 타입 추가 용이
- 테스트 시 Mock 객체 주입 용이

## 6. Redis Pub/Sub 구조

### 6.1. Publisher (app-api)

app-api 내부에서 Redis로 메시지를 발행한다.

```java
@Component
@RequiredArgsConstructor
public class RedisNotificationPublisher implements NotificationPublisher {
    private final RedisTemplate<String, String> redisTemplate;
    private final ObjectMapper objectMapper;

    @Override
    public void publishUsers(List<UserNotificationMessage> messages) {
        String message = objectMapper.writeValueAsString(messages);
        redisTemplate.convertAndSend(
            TopicConstants.USER_NOTIFICATION_BROKER_TOPIC, 
            message
        );
    }

    @Override
    public void publishComplexUsers(List<ComplexUserNotificationMessage> messages) {
        String message = objectMapper.writeValueAsString(messages);
        redisTemplate.convertAndSend(
            TopicConstants.COMPLEX_USER_NOTIFICATION_BROKER_TOPIC, 
            message
        );
    }
}
```

### 6.2. Subscriber (websocket-api)

websocket-api 서버에서 Redis 메시지를 구독하고, WebSocket으로 클라이언트에 전송한다.

```java
@Component
@RequiredArgsConstructor
public class RedisUserNotificationSubscriber implements MessageListener {
    private final RedisMessageListenerContainer container;
    private final UserNotificationMessageSender notificationMessageSender;
    private final ObjectMapper objectMapper;

    @PostConstruct
    public void subscribeUser() {
        container.addMessageListener(
            this, 
            new ChannelTopic(TopicConstants.USER_NOTIFICATION_BROKER_TOPIC)
        );
    }

    @Override
    public void onMessage(Message message, byte[] pattern) {
        List<UserNotificationMessage> notificationMessages = 
            objectMapper.readValue(
                message.getBody(), 
                new TypeReference<>() {}
            );
        notificationMessageSender.send(notificationMessages);
    }
}
```

**Redis Pub/Sub의 역할**
- app-api와 websocket-api 간 느슨한 결합
- 서버 간 메시지 브로커
- 수평 확장 가능 (여러 websocket-api 인스턴스 지원)
- app-api는 어떤 websocket-api 서버가 떠 있는지 알 필요 없음

## 7. WebSocket 설정 (websocket-api)

### 7.1. Spring Boot 설정

```java
@Configuration
@EnableWebSocketMessageBroker
@RequiredArgsConstructor
public class WebSocketConfig implements WebSocketMessageBrokerConfigurer {
    private final StompAuthInterceptor stompAuthInterceptor;

    @Override
    public void configureMessageBroker(MessageBrokerRegistry registry) {
        // 메시지를 구독하는 요청 URL prefix
        registry.enableSimpleBroker("/topic");
    }

    @Override
    public void registerStompEndpoints(StompEndpointRegistry registry) {
        // WebSocket 연결 엔드포인트
        registry.addEndpoint("/ws")
                .setAllowedOrigins("*")
                .withSockJS();
    }

    @Override
    public void configureClientInboundChannel(ChannelRegistration registration) {
        // JWT 인증 인터셉터
        registration.interceptors(stompAuthInterceptor);
    }
}
```

주요 설정:
- 엔드포인트: `/ws`
- 토픽 prefix: `/topic`
- SockJS 지원 (WebSocket 미지원 브라우저 대응)
- JWT 인증 인터셉터 적용

### 7.2. 메시지 전송

```java
@Component
@RequiredArgsConstructor
public class UserNotificationMessageSender {
    private final SimpMessagingTemplate messagingTemplate;

    public void send(List<UserNotificationMessage> notificationMessages) {
        notificationMessages.forEach(notificationMessage -> {
            String destination = String.format(
                "/topic/notification/user/%s", 
                notificationMessage.getUserSeq()
            );
            messagingTemplate.convertAndSend(destination, notificationMessage);
        });
    }
}
```

## 8. 프론트엔드 구조 (app-fe)

### 8.1. 전체 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│                    WebSocket Server                         │
└───────────────────────────┬─────────────────────────────────┘
                            │ SockJS + STOMP
                            │ (Bearer Token Auth)
                            ↓
┌─────────────────────────────────────────────────────────────┐
│               WebSocketClient (libs/webSocketClient.js)     │
│  - 연결 관리 (connect/disconnect)                             │
│  - 구독 관리 (subscribe)                                      │
│  - 자동 재연결 (exponential backoff)                           │
└───────────────────────────┬─────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│         Vuex Store: webSocket Module                        │
│  - 연결 상태 관리 (isConnected)                                │
│  - 구독 설정 (사용자/단지 채널)                                   │
│  - 메시지 라우팅                                               │
└───────────────────────────┬─────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│         Vuex Store: notification Module                     │
│  - 알림 상태 관리 (hasNewNotification)                          │
│  - 토스트 메시지 표시                                            │
│  - 미읽음 알림 카운트 조회                                        │
└───────────────────────────┬─────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│         NotificationToastMessage Service                    │
│  - 토스트 UI 생성/관리                                          │
│  - 최대 3개 제한                                               │
│  - 클릭 이벤트 처리                                             │
└─────────────────────────────────────────────────────────────┘
```

### 8.2. WebSocketClient (Singleton)

```javascript
// libs/webSocketClient.js
class WebSocketClient {
    constructor() {
        this.stompClient = null;
    }

    connect(token, onConnected, onError, retryCount = 0) {
        const socket = new SockJS(process.env.VUE_APP_WEBSOCKET_URL);
        this.stompClient = Stomp.over(socket);

        // JWT 인증
        this.stompClient.connect(
            { Authorization: `Bearer ${token}` },
            onConnected,
            (error) => {
                console.error('WebSocket 연결 실패:', error);
                
                // Exponential Backoff 재연결
                const delay = Math.min(1000 * 2 ** retryCount, 30000);
                setTimeout(() => {
                    this.connect(token, onConnected, onError, retryCount + 1);
                }, delay);
            }
        );
    }

    subscribe(topic, callback) {
        if (this.stompClient && this.stompClient.connected) {
            return this.stompClient.subscribe(topic, (message) => {
                const parsedMessage = JSON.parse(message.body);
                callback(parsedMessage);
            });
        }
    }

    disconnect() {
        if (this.stompClient) {
            this.stompClient.disconnect();
        }
    }
}

export default new WebSocketClient();
```

특징:
- 싱글톤 패턴
- JWT 기반 인증
- 자동 재연결 (Exponential Backoff)
- 재연결 간격: 1초 → 2초 → 4초 → 8초 → 16초 → 30초 (최대)

### 8.3. Vuex webSocket Module

```javascript
// store/modules/common/webSocket.js
const actions = {
    connect({ dispatch, commit }) {
        const token = getAuthToken();
        const userSeq = getUserSeq();
        const complexSeq = getComplexSeq();

        // 기존 연결 해제
        webSocketClient.disconnect();

        webSocketClient.connect(
            token,
            () => {
                commit('SET_CONNECTED', true);

                // 1. 사용자별 알림 구독
                webSocketClient.subscribe(
                    `/topic/notification/user/${userSeq}`,
                    (userNotificationMessage) => {
                        const notificationMessage = 
                            NotificationMessage.ofUser(
                                complexSeq,
                                userNotificationMessage
                            );
                        dispatch('receiveNotification', notificationMessage);
                    }
                );

                // 2. 단지별 알림 구독
                webSocketClient.subscribe(
                    `/topic/notification/complex/${complexSeq}/user/${userSeq}`,
                    (complexUserNotificationMessage) => {
                        const notificationMessage = 
                            NotificationMessage.ofComplexUser(
                                complexUserNotificationMessage
                            );
                        dispatch('receiveNotification', notificationMessage);
                    }
                );
            },
            (error) => {
                commit('SET_CONNECTED', false);
                console.error('WebSocket 연결 실패:', error);
            }
        );
    },

    receiveNotification({ dispatch }, notificationMessage) {
        dispatch('notification/receiveNotification', notificationMessage, { root: true });
    },

    disconnect({ commit }) {
        webSocketClient.disconnect();
        commit('SET_CONNECTED', false);
    }
};
```

### 8.4. Vuex notification Module

```javascript
// store/modules/common/notification.js
const actions = {
    receiveNotification({ commit }, notificationMessage) {
        commit('SET_HAS_NEW_NOTIFICATION', true);

        try {
            notificationToastMessage.show(notificationMessage);
        } catch (error) {
            console.error('토스트 메시지 표시 중 오류:', error);
        }
    },

    updateHasNewNotificationByUnreadNotification({ commit }) {
        // API 호출로 미읽음 알림 개수 조회
        notificationApi.getUnreadCount().then((count) => {
            commit('SET_HAS_NEW_NOTIFICATION', count > 0);
        });
    },

    setHasNewNotification({ commit }, status) {
        commit('SET_HAS_NEW_NOTIFICATION', status);
    }
};
```

### 8.5. NotificationToastMessage Service (Singleton)

```javascript
// components/base/notification/toast-message/notificationToastMessage.js
class NotificationToastMessage {
    constructor() {
        this.toasts = [];
        this.maxToasts = 3;
    }

    show(notificationMessage) {
        // 최대 3개 제한
        if (this.toasts.length >= this.maxToasts) {
            this.removeOldestToast();
        }

        // Vue 컴포넌트 동적 생성
        const ToastConstructor = Vue.extend(NotificationToastMessageTemplate);
        const toastInstance = new ToastConstructor({
            propsData: {
                notificationMessage,
                duration: 5000, // 5초 후 자동 사라짐
            },
        });

        toastInstance.$mount();
        document.body.appendChild(toastInstance.$el);
        this.toasts.push(toastInstance);

        this.updateToastPositions();
    }

    removeToast(toastInstance) {
        const index = this.toasts.indexOf(toastInstance);
        if (index > -1) {
            this.toasts.splice(index, 1);
            toastInstance.$destroy();
            toastInstance.$el.remove();
            this.updateToastPositions();
        }
    }

    updateToastPositions() {
        // 하단에서부터 20px + index * 90px
        this.toasts.forEach((toast, index) => {
            toast.$el.style.bottom = `${20 + index * 90}px`;
        });
    }

    publishClickEvent(notificationMessage) {
        this.$EventBus.$emit(
            'notification-toast-message-click', 
            notificationMessage
        );
    }
}

export default new NotificationToastMessage();
```

특징:
- 싱글톤 패턴
- 최대 3개 제한
- 5초 후 자동 사라짐
- 하단에서부터 90px씩 쌓임
- 클릭 시 전역 이벤트 발생

## 9. 메시지 구조

### 9.1. 사용자 알림 메시지

```json
{
  "notificationSeq": 123456789,
  "userSeq": 1001,
  "message": "새로운 공지사항이 등록되었습니다.",
  "createdDatetime": "2026-01-06T10:30:00",
  "code": "NOTICE",
  "name": "공지사항",
  "clickEventParams": "{\"noticeSeq\":42}"
}
```

**구독 경로**: `/topic/notification/user/{userSeq}`

### 9.2. 단지 사용자 알림 메시지

```json
{
  "notificationSeq": 123456789,
  "complexSeq": 500,
  "userSeq": 1001,
  "message": "새로운 공지사항이 등록되었습니다.",
  "createdDatetime": "2026-01-06T10:30:00",
  "code": "NOTICE",
  "name": "공지사항",
  "clickEventParams": "{\"noticeSeq\":42}"
}
```

**구독 경로**: `/topic/notification/complex/{complexSeq}/user/{userSeq}`

## 10. 핵심 강점

### 확장 가능한 아키텍처
- 템플릿 메서드 패턴으로 새로운 알림 타입 추가 용이
- 전략 패턴으로 Converter/Publisher 교체 가능

### 느슨한 결합
- Redis Pub/Sub로 app-api와 websocket-api 분리
- 인터페이스 기반 설계로 구현체 교체 용이

### 실시간 알림
- WebSocket(STOMP)으로 서버에서 클라이언트로 즉시 푸시
- 사용자별 개별 구독 경로

### 수평 확장 가능
- Redis Pub/Sub로 여러 websocket-api 서버 지원
- Stateless 설계

### 자동 재연결
- Exponential Backoff 전략
- 네트워크 장애 시 자동 복구

## 10. 한계와 트레이드오프

이 시스템은 실시간 알림에 최적화되어 있지만, 몇 가지 한계와 트레이드오프가 존재한다.

### 10.1. Redis Pub/Sub의 메시지 유실 가능성

**한계**:
- Redis Pub/Sub은 **Fire-and-Forget** 방식
- 메시지 발행 시점에 구독자가 없으면 메시지 유실
- Redis 서버 다운 시 메시지 재전송 불가
- 메시지 영속성 보장 안 됨

**왜 이 방식을 선택했는가?**:
- 이 시스템의 목적은 "실시간 UX 개선"
- 알림 이력은 DB에 저장되어 있음
- 사용자는 알림 목록에서 놓친 알림 확인 가능
- 실시간 전달 실패 시 다음 로그인 때 미읽음 알림으로 확인

**대안 (채택하지 않은 이유)**:
- Kafka/RabbitMQ: 메시지 영속성 보장하지만
  - 인프라 복잡도 증가
  - 운영 부담 증가
  - 우리 트래픽 규모에 과한 선택

**완화 방안**:
```java
// 알림 이력은 반드시 DB에 저장
saveNotifications(notifications);

// Redis 발행은 실패해도 핵심 기능에 영향 없음
try {
    getMessagePublisher().publish(messages);
} catch (Exception e) {
    log.error("Redis 발행 실패. 알림은 DB에 저장됨", e);
    // 시스템은 계속 동작
}
```

### 10.2. WebSocket 연결 수와 메모리

**한계**:
- WebSocket은 연결당 서버 메모리 소비
- 동시 접속자 수가 증가하면 메모리 사용량 증가
- 1만 명 동시 접속 시 약 1~2GB 메모리 필요 (서버 스펙에 따라 다름)

**현재 상황**:
- 우리 서비스의 동시 접속자: 평균 500~1000명
- 충분히 수용 가능한 규모

**확장 계획**:
- 동시 접속자 5000명 이상 시:
  - websocket-api 서버 수평 확장 (Redis Pub/Sub 덕분에 가능)
  - 서버당 접속자 수 분산

### 10.3. 알림 재전송 보장 없음

**한계**:
- 네트워크 순간 단절 시 메시지 유실 가능
- 브라우저 탭 전환 시 일부 OS에서 WebSocket 연결 끊김
- 재연결 중 발생한 알림은 수신 불가

**완화 방안**:
```javascript
// 재연결 성공 시 미읽음 알림 조회
webSocketClient.connect(token, () => {
    commit('SET_CONNECTED', true);
    
    // 재연결 후 놓친 알림 확인
    dispatch('notification/updateHasNewNotificationByUnreadNotification');
    
    // 구독 재개
    webSocketClient.subscribe(...);
});
```

- 알림 목록에서 미읽음 배지 표시
- 사용자가 능동적으로 확인 가능

### 10.4. 브로드캐스트 방식의 비효율

**한계**:
- 전체 사용자 알림 시, 모든 websocket-api 서버가 메시지 수신
- 각 서버는 자기가 관리하는 세션에만 전송
- 나머지 메시지는 버려짐 (불필요한 처리)

**예시**:
```
Redis에서 1000명 알림 발행
→ websocket-api 서버 5대가 각각 수신
→ 각 서버는 자기 관리 세션(200명)에만 전송
→ 800명분 메시지는 각 서버에서 버려짐
```

**왜 이 방식을 선택했는가?**:
- Redis Pub/Sub은 브로드캐스트 방식
- 특정 서버로만 전송하려면 복잡한 라우팅 로직 필요
- 메시지 크기가 작아 네트워크 비용 미미
- 구현 단순성 > 약간의 비효율

**대안 (채택하지 않은 이유)**:
- Redis Streams: Consumer Group으로 메시지 분배 가능하지만
  - 구현 복잡도 증가
  - 현재 트래픽에서는 불필요

### 10.6. 정리: 우리가 선택한 트레이드오프

| 항목 | 선택한 방식 | 포기한 것 | 이유 |
|------|------------|----------|------|
| 메시지 브로커 | Redis Pub/Sub | 메시지 영속성 | 실시간 UX가 목적, DB에 이력 저장됨 |
| 메시지 전달 | 브로드캐스트 | 약간의 비효율 | 구현 단순성, 트래픽 규모 작음 |
| 재전송 보장 | 없음 | 100% 전달 보장 | 미읽음 조회로 보완, UX 우선 |
| 연결 관리 | 상태 유지 (Stateful) | 메모리 사용 | 실시간성 우선, 확장 가능 |

**핵심 원칙**:
- "완벽한 메시지 전달"보다 "실시간 UX"를 우선
- 누락된 알림은 DB 조회로 보완 가능
- 운영 복잡도를 낮추고 안정성 확보

## 11. 마무리

WebSocket 기반 실시간 알림 시스템을 구축하면서:

**기술적 성과**:
- 실시간성 개선 (즉시 알림 전달)
- 확장 가능한 아키텍처 구축

**사용자 경험 개선**:
- 페이지 새로고침 없이 실시간 알림 수신

**운영 안정성**:
- 자동 재연결로 네트워크 장애 대응
- Redis Pub/Sub로 서버 간 느슨한 결합
- JWT 인증으로 보안 강화

