---
title: "IP 기반 인증 장애 사례와 OAuth 2.0 Credential 기반 인증으로의 개선기"
categories: backend
tags: [authentication, oauth, jwt, nginx, api, security]
excerpt: "간헐적 403 장애를 통해 발견한 IP 기반 인증의 한계와 OAuth 2.0 Client Credentials 기반 인증으로의 전환 과정"
---

## 들어가며

"김과장, 지금 A 업체에서 우리 측 API 호출할 때 통신이 안 된다고 하는데 확인해 주세요."

어느 날 받은 팀장님의 확인 요청이었다.

**첫 번째 확인:**
- A 업체 사이트에 직접 접속
- 우리 서비스와 연계된 기능 호출
- 정상 동작 확인

**혼란의 시작:**
- 우리 쪽에서는 정상
- 상대 업체에서는 간헐적으로 실패
- 재현도 쉽지 않음

이 글은 간헐적 통신 장애를 추적하며 발견한 IP 기반 인증의 구조적 한계와, 이를 OAuth 2.0 Client Credentials 기반 인증으로 개선한 과정에 대한 기록이다.

---

## 1. 장애 추적 - 간헐적 403 Forbidden

### 확인된 사실

**통신 오류 패턴:**
- 항상 발생하지 않음
- 특정 상황에서만 403 Forbidden 발생
- 요청이 들어오는 IP가 매번 동일하지 않음

### 결정적 단서 발견

**로그 분석 결과:**

```bash
# Nginx access log
XXX.XXX.XXX.100 - - [08/Jan/2025] "GET /public-api/occupant?aptNo=101&dongNo=1001 HTTP/1.1" 200
YYY.YYY.YYY.200 - - [08/Jan/2025] "GET /public-api/occupant?aptNo=101&dongNo=1001 HTTP/1.1" 403
XXX.XXX.XXX.100 - - [08/Jan/2025] "GET /public-api/occupant?aptNo=102&dongNo=1002 HTTP/1.1" 200
YYY.YYY.YYY.200 - - [08/Jan/2025] "GET /public-api/occupant?aptNo=102&dongNo=1002 HTTP/1.1" 403
```

**발견한 사실:**
- 정상 처리: XXX.XXX.XXX.100
- 403 발생: YYY.YYY.YYY.200
- 우리 서비스에 등록되지 않은 IP로 호출되고 있었다

### 원인 파악

**A 업체의 인프라 구조:**
- 서버가 2대 운영 중
- 그중 1대의 IP가 변경됨
- IP가 변경된 서버: 403 발생
- 기존 서버: 정상 처리

**결론:**
> "간헐적" 장애처럼 보였던 이유는 로드밸런싱으로 인해 두 서버로 요청이 분산되었기 때문

---

## 2. 기존 구조 - Nginx IP 기반 인증

### Nginx 설정 확인

**public-api.conf:**

```nginx
location /public-api {

    set $allowed_ip 0;

    # A 업체 IP 허용
    if ($http_x_forwarded_for = "XXX.XXX.XXX.100") {
        set $allowed_ip 1;
    }

    # B 업체 IP 허용
    if ($http_x_forwarded_for = "XXX.XXX.XXX.101") {
        set $allowed_ip 1;
    }

    # 허용되지 않은 IP는 403 반환
    if ($allowed_ip = 0) {
        return 403 "403 Forbidden";
    }

    proxy_redirect     off;
    proxy_set_header   Host              $host;
    proxy_set_header   X-Real-IP         $remote_addr;
    proxy_set_header   X-Forwarded-For   $http_x_forwarded_for;

    proxy_pass http://tomcat;
}
```

### 구조의 특징

**장점:**
- 설정이 간단함
- 빠른 적용 가능
- 웹 서버 레벨에서 차단

**문제점:**
- 인증 로직이 Nginx 설정에 숨어 있음
- 애플리케이션 코드에서는 보이지 않음
- IP 변경 시 즉시 장애 발생

---

## 3. 단기 해결 - IP 추가 등록

### 즉시 조치

**변경된 Nginx 설정:**

```nginx
location /public-api {

    set $allowed_ip 0;

    # A 업체 IP 허용 (기존)
    if ($http_x_forwarded_for = "XXX.XXX.XXX.100") {
        set $allowed_ip 1;
    }

    # A 업체 IP 허용 (신규 추가)
    if ($http_x_forwarded_for = "YYY.YYY.YYY.200") {
        set $allowed_ip 1;
    }

    # 이하 동일
    ...
}
```

**결과:**
- 즉각적으로 장애 해소
- A 업체의 두 서버 모두 정상 통신

### 하지만 찜찜함

```
이 방식으로 계속 운영해도 괜찮을까?
다음에 또 IP가 변경되면?
```

---

## 4. 근본적인 문제점 분석

### 문제 1. 인증 로직의 위치가 불명확

**상황:**
- 인증이 Nginx 설정에 숨어 있음
- 히스토리를 모르는 개발자는 소스 코드를 아무리 봐도 인증 로직을 찾을 수 없음

**실제 경험:**

```java
@RestController
@RequestMapping("/public-api")
public class PublicApiController {
    
    @GetMapping("/occupant")
    public ApiResponse getOccupant(@RequestParam String aptNo,
                                    @RequestParam String dongNo) {
        // 인증 로직이 어디에도 없다!
        // 어떻게 인증되는 거지?
        return occupantService.getOccupant(aptNo, dongNo);
    }
}
```

**문제:**
- "왜 403이 나는지" 파악하는 데 시간이 오래 걸림
- 인프라 담당자에게 문의해야 원인 파악 가능

### 문제 2. IP 기반 인증의 구조적 한계

**1. 인프라 변경에 매우 취약**

```
시나리오:
- 서버 증설
- 서버 교체
- 클라우드 오토스케일링
- IP 변경

결과:
- 무조건 장애 발생
```

**2. 간헐적 장애를 유발**

```
멀티 서버 환경에서:
- 서버 A: 정상
- 서버 B: 403

결과:
- 로드밸런싱으로 인해 간헐적 실패
- 재현이 어려움
- 장애 추적 시간 증가
```

**3. 인증 주체 식별 불가**

```
현재:
- "어디서 호출했는지"만 확인 가능
- XXX.XXX.XXX.100 → 허용
- YYY.YYY.YYY.200 → 차단

필요:
- "누가 호출했는지" 식별
- A 업체 → 허용
- B 업체 → 허용
- 미등록 업체 → 차단
```

**4. 보안 확장성 부족**

```
문제:
- IP 유출 시 즉시 무력화
- 호출 주체별 권한 분리 어려움
- 접근 로그에서 업체 구분 불가
- 통계 및 모니터링 한계
```

### 종합 정리

| 문제 | 영향 | 심각도 |
|------|------|--------|
| 인증 로직 불명확 | 유지보수 어려움 | 중 |
| 인프라 변경 취약 | 잦은 장애 발생 | 상 |
| 간헐적 장애 유발 | 재현 및 추적 어려움 | 상 |
| 인증 주체 미식별 | 운영 및 모니터링 한계 | 중 |
| 보안 확장성 부족 | 장기 운영 리스크 | 중 |

---

## 5. 개선 방향 - 인증 체계 전환

### 개선 전략 수립

**핵심 원칙:**

```
1. 인증 로직을 애플리케이션 레벨로 이동
2. IP가 아닌 Credential 기반 인증
3. 인증 주체 식별 가능
4. 확장 가능한 구조
```

### 인증 방식 검토

**초기 고민: API Key 방식**

IP 기반 인증을 개선하기로 하면서 가장 먼저 떠올린 방식은 API Key였다.

```http
GET /public-api/occupant?aptNo=101
X-API-Key: abc123def456
```

**장점:**
- 구현이 매우 간단
- 빠른 적용 가능
- IP 변경과 무관

하지만 "API 인증 표준 방식"을 검색해보니...

### 발견한 사실: OAuth 2.0이 표준

**검색 결과:**
- Google Cloud API: OAuth 2.0
- AWS API: OAuth 2.0 (SigV4)
- GitHub API: OAuth 2.0
- 대부분의 공개 API: OAuth 2.0

**OAuth 2.0 Client Credentials Grant:**

```http
# 1단계: Token 발급
POST /public-api/auth/token
{
  "clientId": "...",
  "clientSecret": "..."
}

# 2단계: Token으로 API 호출
GET /public-api/occupant?aptNo=101
Authorization: Bearer {JWT}
```

### 왜 OAuth + JWT를 선택했는가?

**1. 업계 표준이었다**

```
상황:
"어떻게 인증 구현하지?" 
→ 구글 검색: "REST API 인증 방식"
→ 결과: OAuth 2.0이 표준

생각:
"표준을 따르는 게 맞지 않을까?"
"나중에 문제 생겨도 참고할 자료 많을 것 같은데?"
```

**2. 우리 상황과 정확히 일치했다**

**OAuth 2.0 Client Credentials Grant 사용 시나리오:**
- Server-to-Server 통신
- 사용자가 아닌 애플리케이션 인증
- 외부 업체 API 연동

**우리 상황:**
- A 업체 서버 → 우리 서버 (Server-to-Server)
- 사용자 로그인 없음 (애플리케이션 인증)
- 외부 업체 연동

```
"어? 우리 상황이랑 정확히 똑같네?"
```

**3. 팀 내 커뮤니케이션이 쉬웠다**

```
만약 "API Key 방식"이라고 하면:
PM: "어떻게 발급하나요?"
개발자A: "만료는 어떻게 관리하나요?"
개발자B: "갱신은 어떻게 하나요?"
→ 매번 우리만의 방식 설명 필요

"OAuth 2.0 Client Credentials 방식"이라고 하면:
PM: "아, OAuth네요"
개발자A: "그럼 Client ID/Secret 발급하고"
개발자B: "Token 발급 API 만들고, JWT로 검증하는 거네요"
→ 부연 설명 없이 즉시 이해

이게 표준의 힘이다.
```

**4. 참고 자료가 풍부했다**

```
API Key 방식:
- 구글링해도 각 회사마다 구현 방식 다름
- "우리만의 방식" 설계 필요
- 레퍼런스 부족

OAuth 2.0:
- RFC 6749 표준 문서
- Spring Security OAuth 라이브러리
- 수많은 블로그, 예제 코드
- 외부 업체 개발자도 익숙함

"삽질하지 말고 검증된 방식 쓰자"
```

**5. 외부 업체 입장에서도 편했다**

```
연동 가이드 작성 시:

"우리 회사 방식":
- 처음부터 끝까지 설명 필요
- 샘플 코드 직접 작성
- Q&A 많이 발생

"OAuth 2.0 표준":
- "OAuth 2.0 Client Credentials 방식입니다"
- 기존 OAuth 라이브러리 사용 가능
- 외부 개발자들도 이미 아는 방식
```

---

## 6. OAuth 2.0 Client Credentials Grant란?

### 간단하게 알아보자

앞서 우리는 OAuth 2.0 Client Credentials Grant 방식을 선택하기로 했다.

그런데 이게 정확히 뭘까?

**가장 간단한 설명:**
```
"서버가 다른 서버의 API를 호출할 때 사용하는 인증 방식"
```

### OAuth 2.0 개요

**OAuth 2.0이란?**

인증(Authentication)과 인가(Authorization)를 위한 업계 표준 프로토콜

**4가지 Grant Type:**

| Grant Type | 사용 시나리오 | 예시 |
|-----------|-------------|------|
| Authorization Code | 사용자 인증 (가장 일반적) | 소셜 로그인, "구글 계정으로 로그인" |
| Implicit | 단순화된 사용자 인증 | SPA (deprecated) |
| Password Credentials | 사용자명/비밀번호 직접 사용 | 신뢰할 수 있는 앱 |
| **Client Credentials** | **서버 간 통신** | **우리 케이스** |

### Client Credentials Grant의 특징

**사용 시나리오:**
- 사용자가 아닌 **애플리케이션 자체가 인증 주체**
- Server-to-Server 통신
- 백그라운드 작업, 배치 처리
- 외부 업체 API 연동

**우리 상황:**
```
A 업체 서버 → 우리 서버
- 사용자 로그인 없음
- 24시간 자동으로 데이터 조회
- Server-to-Server 통신

→ Client Credentials Grant 사용
```

**표준 OAuth 2.0 흐름:**

```
[Client Application]
    |
    | POST /oauth/token
    | Content-Type: application/x-www-form-urlencoded
    |
    | grant_type=client_credentials
    | client_id={CLIENT_ID}
    | client_secret={CLIENT_SECRET}
    v
[Authorization Server]
    |
    | 1. Client Credentials 검증
    | 2. Access Token 발급
    |
    | Response:
    | {
    |   "access_token": "...",
    |   "token_type": "Bearer",
    |   "expires_in": 3600
    | }
    v
[Client Application]
    |
    | GET /api/resource
    | Authorization: Bearer {access_token}
    v
[Resource Server]
```

### 핵심 구성 요소 이해

OAuth 2.0 Client Credentials Grant는 3가지 핵심 요소로 구성된다.

**1. Client ID (클라이언트 식별자)**

```
역할: 
  클라이언트 애플리케이션의 공개 식별자
  
특징:
  - Public Identifier (공개되어도 무방)
  - 애플리케이션을 식별하는 용도
  - URL에 포함되거나 로그에 노출 가능
  - Username과 유사한 개념

예시:
  company_a_20250108_a1b2c3d4
  
비유:
  은행 계좌번호 (공개 가능)
```

**Client ID 생성 로직:**

```java
private String generateClientId(String appName) {
    // 1. 앱 이름을 prefix로 사용 (알파벳/숫자만)
    String prefix = appName.toLowerCase()
        .replaceAll("[^a-z0-9]", "");
    
    // 2. 생성 날짜 (yyyyMMdd)
    String timestamp = LocalDateTime.now()
        .format(DateTimeFormatter.ofPattern("yyyyMMdd"));
    
    // 3. 랜덤 8자리
    String random = UUID.randomUUID()
        .toString()
        .substring(0, 8);
    
    // 결과: companya_20250108_a1b2c3d4
    return String.format("%s_%s_%s", prefix, timestamp, random);
}
```

**2. Client Secret (클라이언트 비밀키)**

```
역할:
  클라이언트 애플리케이션의 비밀 키
  
특징:
  - Private Key (절대 공개되면 안 됨)
  - Password처럼 안전하게 보관
  - 주기적 갱신 필요 (예: 1년마다)
  - 반드시 해싱하여 DB 저장
  
예시:
  a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0u1v2w3x4y5z6
  (64자리 랜덤 문자열)
  
비유:
  은행 계좌 비밀번호 (절대 공개 금지)
```

**Client Secret 생성 및 저장:**

```java
/**
 * Client Secret 생성 및 저장
 * 
 * @param app ExternalApp 엔티티
 * @return 평문 Client Secret (1회만 반환)
 */
private String generateAndSaveClientSecret(ExternalApp app) {
    // 1. 생성: 64자리 랜덤 문자열
    String plainSecret = generateRandomSecret();
    
    // 2. 해싱 후 저장
    String hashedSecret = passwordEncoder.encode(plainSecret);
    app.setClientSecret(hashedSecret);
    
    // 3. 평문 반환 (DB에는 해싱된 값만 저장됨)
    return plainSecret;
}

/**
 * 랜덤 Secret 생성
 * 
 * @return 64자리 랜덤 문자열
 */
private String generateRandomSecret() {
    return UUID.randomUUID().toString().replace("-", "") +
           UUID.randomUUID().toString().replace("-", "");
}
```

**중요: Client Secret는 재조회 불가능**

```
Q: 웹 포털에서 Client Secret를 다시 확인할 수 있나요?

A: 아니요, 절대 불가능합니다.

이유:
1. DB에 해싱되어 저장 (복호화 불가능)
2. 평문은 생성/갱신 시 화면에 1회만 표시
3. [주의] 화면을 닫거나 새로고침 하면 영구적으로 확인 불가
4. 확인하지 못한 경우 → Client Secret 갱신 필요

웹 포털 동작 방식:
- 생성/갱신 시: 모달 창에 평문 표시 + 복사 버튼
- 모달 닫기 전 경고: "이 창을 닫으면 다시 확인할 수 없습니다"
- 모달 닫은 후: 마스킹 처리 (********************************)
```

**웹 포털 화면에서 표시 방식:**

```
[생성/갱신 직후 - 모달 창]
┌─────────────────────────────────────────────┐
│  Client Secret 발급 완료                      │
├─────────────────────────────────────────────┤
│                                             │
│  Client Secret (1회만 표시됩니다):              │
│  ┌─────────────────────────────────────────┐│
│  │ a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6...     ││
│  └─────────────────────────────────────────┘│
│                          [복사] [다운로드]      │
│                                             │
│  [주의사항]                                   │
│  • 이 화면을 닫으면 다시 확인할 수 없습니다.          │
│  • 반드시 복사하거나 안전한 곳에 저장하세요           │
│  • 분실 시 갱신을 통해 새로 발급받아야 합니다         │
│                                             │
│              [확인했습니다]                     │
└─────────────────────────────────────────────┘

[모달 닫은 후 - 일반 화면]
Client ID: company_a_20250108_a1b2c3d4 [복사]
Client Secret: ******************************** [갱신]
             (마지막 생성: 2025-01-08)
             
※ Client Secret는 보안상 재조회할 수 없습니다.
   분실한 경우 갱신 버튼을 클릭하여 새로 발급받으세요.
```

**3. Access Token (JWT)**

```
역할:
  API 호출 시 사용하는 인증 토큰
  
특징:
  - 짧은 수명 (1시간 ~ 24시간)
  - 자체 검증 가능 (서명 포함)
  - Bearer 토큰으로 사용
  - 만료 시 재발급 필요
  
구조 (JWT):
  Header.Payload.Signature
  
예시:
  eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.
  eyJzdWIiOiJjb21wYW55LWEiLCJpYXQiOjE2NDA5OTUyMDAsImV4cCI6MTY0MTA4MTYwMH0.
  4Hb-5VxP8Qs_Yw1R2Zp3Xm6Nk7Lj8Ii9Hh0Gg1Ff2Ee3Dd
```

**JWT 구조 분석:**

```json
// Header (알고리즘 및 타입)
{
  "alg": "HS256",
  "typ": "JWT"
}

// Payload (실제 데이터)
{
  "sub": "company-a",           // Subject: 외부 앱 이름
  "iat": 1640995200,            // Issued At: 발급 시간
  "exp": 1641081600             // Expiration: 만료 시간
}

// Signature (서명)
HMACSHA256(
  base64UrlEncode(header) + "." +
  base64UrlEncode(payload),
  secret
)
```

### JWT 서명으로 어떻게 인증하는가?

**핵심 원리: 서명 검증**

JWT의 가장 중요한 특징은 **자체 검증 가능(Self-contained)**하다는 것입니다.

**서명 생성 과정 (Token 발급 시):**

```java
// 1. Header + Payload 준비
String header = base64UrlEncode('{"alg":"HS256","typ":"JWT"}');
String payload = base64UrlEncode('{"sub":"company-a","iat":1640995200,"exp":1641081600}');

// 2. 서명 생성
String data = header + "." + payload;
String signature = HMACSHA256(data, secretKey);

// 3. JWT 완성
String jwt = header + "." + payload + "." + signature;
// 결과: eyJhbGc...xyz.eyJzdWI...abc.4Hb5VxP...def
```

**서명 검증 과정 (API 호출 시):**

```java
// 1. JWT를 "."으로 분리
String[] parts = jwt.split("\\.");
String header = parts[0];      // eyJhbGc...xyz
String payload = parts[1];     // eyJzdWI...abc
String signature = parts[2];   // 4Hb5VxP...def

// 2. 동일한 방식으로 서명 재생성
String data = header + "." + payload;
String expectedSignature = HMACSHA256(data, secretKey);

// 3. 비교
if (signature.equals(expectedSignature)) {
    // 검증 성공: 이 JWT는 우리가 발급한 것이 맞다
    // 내용이 변조되지 않았다
} else {
    // 검증 실패: 위조되었거나 변조되었다
}
```

**왜 안전한가?**

```
1. secretKey는 서버만 알고 있음
2. 공격자가 Payload를 변조하면:
   - 새로운 서명 = HMACSHA256(변조된데이터, ?)
   - secretKey를 모르므로 올바른 서명 생성 불가
3. 서버에서 검증 시:
   - 재계산한 서명 != JWT의 서명
   - 검증 실패
```

**실제 예시:**

```java
// 정상 JWT
header:  {"alg":"HS256","typ":"JWT"}
payload: {"sub":"company-a","exp":1641081600}
signature: 4Hb5VxP8Qs_Yw1R2Zp3Xm6Nk7Lj8Ii9

// 공격자가 만료시간을 변조 시도
payload: {"sub":"company-a","exp":9999999999}  // 만료시간 변조
signature: 4Hb5VxP8Qs_Yw1R2Zp3Xm6Nk7Lj8Ii9  // 기존 서명 그대로 사용

// 서버 검증
String expectedSignature = HMACSHA256(header + "." + 변조된payload, secretKey);
// expectedSignature: XYZ123... (다른 값)
// 실제 signature: 4Hb5VxP8... 

// 불일치! 검증 실패!
```

**DB 조회 없이 인증 가능:**

```java
// 기존 방식 (Session 등)
1. 클라이언트가 Token 전송
2. 서버가 DB에서 Token 조회
3. 유효한지 확인
4. 사용자 정보 조회

// JWT 방식
1. 클라이언트가 JWT 전송
2. 서버가 서명 검증 (DB 조회 없음)
3. Payload에서 바로 정보 추출 (sub, exp 등)
4. 끝!

→ DB 부하 감소, 빠른 검증
```

**우리 구현에서의 JWT 검증:**

```java
public void validateToken(String token) {
    try {
        Jwts.parser()
            .setSigningKey(secretKey)  // 서명 검증에 사용
            .parseClaimsJws(token);    // 자동으로 서명 검증
        // 검증 성공
    } catch (SignatureException e) {
        // 서명 불일치 → 위조된 토큰
        throw new JwtException("Invalid signature", e);
    } catch (ExpiredJwtException e) {
        // 만료된 토큰
        throw new JwtException("Token expired", e);
    }
}
```

**정리:**

```
Q: 서명 정보로 어떻게 인증하는가?

A: 
1. Token 발급 시: Header + Payload를 secretKey로 서명
2. API 호출 시: 동일한 secretKey로 서명 재계산
3. 비교: 일치하면 우리가 발급한 토큰
4. 결과: DB 조회 없이 빠른 인증 가능

핵심: secretKey를 아는 사람만 올바른 서명 생성 가능
     → secretKey는 절대 노출되면 안 됨!
```

### 우리 구현 vs 표준 OAuth 2.0

**표준 OAuth 2.0:**

```http
POST /oauth/token HTTP/1.1
Host: authorization-server.com
Content-Type: application/x-www-form-urlencoded

grant_type=client_credentials
&client_id=your_client_id
&client_secret=your_client_secret
&scope=read write
```

**우리 구현 (단순화):**

```http
POST /public-api/auth/token HTTP/1.1
Host: api.example.com
Content-Type: application/json

{
  "clientId": "your_client_id",
  "clientSecret": "your_client_secret"
}
```

**차이점:**
- OAuth 2.0 표준: grant_type, scope 등 더 많은 파라미터
- 우리 구현: 핵심 개념만 차용하여 단순화
- 목적: 복잡한 OAuth 서버 구축 없이 인증 개선

**장점:**
- 업계 표준 방식
- 다양한 라이브러리 지원
- 보안 베스트 프랙티스 적용
- 외부 업체가 이해하기 쉬움

---

## 7. 구현 - OAuth 2.0 Client Credentials 인증 시스템

**구현 개요:**
- 인증 방식: OAuth 2.0 Client Credentials Grant
- Token 포맷: JWT (JSON Web Token)
- JWT는 Access Token을 구현하는 방법 중 하나

### 7-1. 외부 연동 Key 관리

**설계 원칙:**

인증키 갱신을 API로 제공하지 않는 이유:
- API로 갱신 제공 시 인증키 유출자가 갱신 가능
- 보안 취약점 발생

**해결 방안:**
- 외부 업체가 우리 서비스에 회원가입
- 웹 포털을 통해 직접 인증키 관리
- 갱신 주체: 외부 업체 (셀프 서비스)
- 우리 팀 개입 최소화

**User 엔티티 (핵심 필드만):**

```java
@Entity
@Table(name = "users")
@Getter
public class User {
    
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    
    @Column(nullable = false, unique = true)
    private String username;
    
    @Column(nullable = false)
    private String password;
    
    @Column(nullable = false)
    private String email;
    
    // ...existing fields...
}
```

**ExternalApp 엔티티:**

```java
@Entity
@Table(name = "external_app")
@Getter
public class ExternalApp {
    
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;
    
    // OAuth Credentials
    @Column(nullable = false, unique = true)
    private String appName;
    
    @Column(nullable = false, unique = true)
    private String clientId;
    
    @Column(nullable = false)
    private String clientSecret;  // 해싱되어 저장
    
    // 상태 관리
    @Column(nullable = false)
    private boolean enabled;
    
    @Column
    private LocalDateTime secretExpiresAt;
    
    // User 연관 (웹 포털 관리용)
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "user_id", nullable = false)
    private User user;
    
    // 핵심 비즈니스 로직
    public boolean isSecretExpired() {
        return secretExpiresAt != null && 
               LocalDateTime.now().isAfter(secretExpiresAt);
    }
    
    public void updateClientSecret(String newSecret, LocalDateTime expiresAt) {
        this.clientSecret = newSecret;
        this.secretExpiresAt = expiresAt;
    }
}
```

### 7-2. Token 발급 API

**TokenController:**

```java
@RestController
@RequestMapping("/public-api/auth")
@RequiredArgsConstructor
public class TokenController {
    
    private final TokenService tokenService;
    
    @PostMapping("/token")
    public ResponseEntity<TokenResponse> issueToken(
            @RequestBody TokenRequest request) {
        
        String token = tokenService.issueToken(
            request.getClientId(),
            request.getClientSecret()
        );
        
        return ResponseEntity.ok(
            TokenResponse.builder()
                .accessToken(token)
                .tokenType("Bearer")
                .expiresIn(86400) // 24시간
                .build()
        );
    }
}
```

**TokenService (핵심 로직만):**

```java
@Service
@RequiredArgsConstructor
public class TokenService {
    
    private final ExternalAppRepository externalAppRepository;
    private final PublicApiJwtManager jwtManager;
    private final PasswordEncoder passwordEncoder;
    
    @Transactional
    public String issueToken(String clientId, String clientSecret) {
        // 1. Client 조회
        ExternalApp app = externalAppRepository.findByClientId(clientId)
            .orElseThrow(() -> new UnauthorizedException("Invalid client"));
        
        // 2. 검증
        validateClient(app, clientSecret);
        
        // 3. JWT 발급
        return jwtManager.createToken(app.getAppName());
    }
    
    private void validateClient(ExternalApp app, String clientSecret) {
        if (!app.isEnabled()) {
            throw new UnauthorizedException("Client is disabled");
        }
        if (app.isSecretExpired()) {
            throw new UnauthorizedException("Client secret expired");
        }
        // 평문과 해싱값 비교
        if (!passwordEncoder.matches(clientSecret, app.getClientSecret())) {
            throw new UnauthorizedException("Invalid client secret");
        }
    }
}
```

### 7-3. JWT Manager (핵심 메서드만)

**PublicApiJwtManager:**

```java
@Component
public class PublicApiJwtManager {

    @Value("${jwt.secret}")
    private String secretKey;
    
    @Value("${jwt.expiration}")
    private long tokenValidMillisecond; // 24시간

    @PostConstruct
    void init() {
        this.secretKey = Base64.getEncoder()
                .encodeToString(secretKey.getBytes(StandardCharsets.UTF_8));
    }

    // JWT 토큰 생성
    public String createToken(String subject) {
        Claims claims = Jwts.claims().setSubject(subject);
        Date issuedDate = new Date();
        Date expiredDate = new Date(issuedDate.getTime() + tokenValidMillisecond);

        return Jwts.builder()
                .setClaims(claims)
                .setIssuedAt(issuedDate)
                .setExpiration(expiredDate)
                .signWith(SignatureAlgorithm.HS256, secretKey)
                .compact();
    }

    // HTTP 헤더에서 JWT 토큰 추출
    public String getToken(HttpServletRequest request) {
        String authHeader = request.getHeader("Authorization");
        if (StringUtils.hasText(authHeader) && authHeader.startsWith("Bearer ")) {
            return authHeader.substring(7);
        }
        return null;
    }

    // JWT 토큰 유효성 검증
    public void validateToken(String token) {
        try {
            Jwts.parser()
                .setSigningKey(secretKey)
                .parseClaimsJws(token);
        } catch (JwtException e) {
            throw new JwtException("Invalid token", e);
        }
    }

    // JWT 토큰에서 subject 추출
    public String getSubject(String token) {
        return Jwts.parser()
                .setSigningKey(secretKey)
                .parseClaimsJws(token)
                .getBody()
                .getSubject();
    }
}
```

### 7-4. Interceptor 구현 (핵심 로직만)

**PublicApiJwtInterceptor:**

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class PublicApiJwtInterceptor extends HandlerInterceptorAdapter {

    private final PublicApiJwtManager jwtManager;
    private final ExternalAppRepository externalAppRepository;

    @Override
    public boolean preHandle(HttpServletRequest request,
                             HttpServletResponse response,
                             Object handler) throws Exception {

        // 1. 토큰 추출
        String token = jwtManager.getToken(request);
        if (token == null) {
            sendUnauthorized(response, "Missing token");
            return false;
        }

        // 2. 토큰 검증
        try {
            jwtManager.validateToken(token);
        } catch (JwtException e) {
            sendUnauthorized(response, "Invalid token");
            return false;
        }

        // 3. 앱 정보 추출 및 활성화 상태 확인
        String appName = jwtManager.getSubject(token);
        ExternalApp app = externalAppRepository.findByAppName(appName)
            .orElse(null);
        
        if (app == null || !app.isEnabled()) {
            sendUnauthorized(response, "Client is disabled");
            return false;
        }

        // 4. Context에 인증 정보 저장
        request.setAttribute("appName", appName);
        
        return true;
    }

    private void sendUnauthorized(HttpServletResponse response, String message) 
            throws IOException {
        response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
        response.setContentType("application/json");
        response.getWriter().write(
            String.format("{\"error\":\"%s\"}", message)
        );
    }
}
```

### 7-5. Interceptor 등록

**WebMvcConfiguration:**

```java
@Configuration
@RequiredArgsConstructor
public class WebMvcConfiguration implements WebMvcConfigurer {
    
    private final PublicApiJwtInterceptor publicApiJwtInterceptor;
    
    @Override
    public void addInterceptors(InterceptorRegistry registry) {
        registry.addInterceptor(publicApiJwtInterceptor)
                .addPathPatterns("/public-api/**")
                .excludePathPatterns("/public-api/auth/**"); // 토큰 발급 API 제외
    }
}
```

## 8. Nginx 설정 변경

### 변경 전 (IP 기반)

```nginx
location /public-api {
    set $allowed_ip 0;

    if ($http_x_forwarded_for = "XXX.XXX.XXX.100") {
        set $allowed_ip 1;
    }

    if ($allowed_ip = 0) {
        return 403 "403 Forbidden";
    }

    proxy_pass http://tomcat;
}
```

### 변경 후 (JWT 기반)

```nginx
location /public-api {
    # IP 체크 제거
    # 인증은 애플리케이션에서 처리
    
    proxy_redirect     off;
    proxy_set_header   Host              $host;
    proxy_set_header   X-Real-IP         $remote_addr;
    proxy_set_header   X-Forwarded-For   $http_x_forwarded_for;
    proxy_set_header   Authorization     $http_authorization;

    proxy_pass http://tomcat;
}
```

**변경 사항:**
- IP 체크 로직 제거
- Authorization 헤더 전달 추가
- 인증은 애플리케이션에서 처리

---

## 9. 외부 업체 연동 가이드

### 9-1. 초기 설정 프로세스

**Step 1: 웹 포털 접속**

```
1. 담당자 이메일로 발송된 초기 계정 정보 확인
   - Username: company-a-admin
   - Temp Password: Ab12Cd34
   
2. 웹 포털 접속: https://api-portal.example.com

3. 초기 비밀번호 변경 (필수)
   - 8자 이상
   - 영문, 숫자, 특수문자 조합
```

**Step 2: Client Credentials 확인**

```
1. 로그인 후 대시보드 접속

2. 발급된 Client Credentials 확인
   - Client ID: company_a_20250108_a1b2c3d4 (언제든지 조회 가능)
   - Client Secret: 생성 시 화면에 1회만 표시
   
3. Client Secret 보안 정책
   - 생성/갱신 시 모달 창에 평문 표시
   - 모달 창을 닫으면 영구적으로 재조회 불가능
   - DB에 해싱되어 저장되므로 복호화 불가
   - 분실 시 갱신을 통해 새로 발급
   
4. Client Secret 즉시 저장 (필수)
   - 모달 창의 [복사] 또는 [다운로드] 버튼 사용
   - 소스 코드에 하드코딩 절대 금지
```

**Step 3: 만료 관리**

```
1. 만료일 확인: 대시보드에서 확인 가능

2. 만료 30일 전 이메일 알림 발송

3. 만료 시 웹 포털에서 직접 갱신
   - [Client Secret 갱신] 버튼 클릭
   - 확인 모달 표시
   - 새로운 Secret가 모달 창에 표시 (1회만)
   - 반드시 복사 후 모달 닫기
   - 이전 Secret 즉시 무효화
   
4. 애플리케이션에 새로운 Secret 적용
   - 환경변수 업데이트
   - 애플리케이션 재기동 (또는 설정 리로드)
```

### 9-2. API 인증 가이드

**Token 발급:**

```markdown
## 1. Token 발급

### Request
POST /public-api/auth/token
Content-Type: application/json

{
  "clientId": "your_client_id",
  "clientSecret": "your_client_secret"
}

### Response
{
  "accessToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "tokenType": "Bearer",
  "expiresIn": 86400
}

## 2. API 호출

### Request
GET /public-api/company-a/occupant?aptNo=101&dongNo=1001
Authorization: Bearer {accessToken}

## 3. 주의사항

- Token은 24시간 유효
- 만료 전에 재발급 권장
- clientSecret은 안전하게 보관
- Authorization 헤더 필수
```

### 9-3. 샘플 코드

**Java 예시:**

```java
// 1. Token 발급
RestTemplate restTemplate = new RestTemplate();

TokenRequest request = TokenRequest.builder()
    .clientId("your_client_id")
    .clientSecret("your_client_secret")
    .build();

TokenResponse tokenResponse = restTemplate.postForObject(
    "https://api.example.com/public-api/auth/token",
    request,
    TokenResponse.class
);

String accessToken = tokenResponse.getAccessToken();

// 2. API 호출
HttpHeaders headers = new HttpHeaders();
headers.setBearerAuth(accessToken);

String url = "https://api.example.com/public-api/company-a/occupant?aptNo=101&dongNo=1001";
HttpEntity<Void> entity = new HttpEntity<>(headers);

OccupantResponse response = restTemplate.exchange(
    url,
    HttpMethod.GET,
    entity,
    OccupantResponse.class
).getBody();
```

---

## 10. 변경 전후 비교

### 인증 방식 비교

| 항목 | IP 기반 (변경 전) | Credential 기반 (변경 후) |
|------|-------------------|--------------------------|
| 인증 위치 | Nginx | 애플리케이션 |
| 인증 기준 | IP 주소 | Client Credentials |
| Token 포맷 | - | JWT |
| 장애 원인 파악 | 어려움 | 로그 기반 추적 가능 |
| IP 변경 대응 | 즉시 장애 | 영향 없음 |
| 호출 주체 식별 | 불가능 | 가능 |
| 권한 관리 | 어려움 | 업체별 관리 가능 |
| 확장성 | 낮음 | 높음 |
| 보안 수준 | 낮음 | 높음 |

---

## 11. 추가 보안 고려사항

### 11-1. Client Secret 주기적 갱신 (웹 포털)

**갱신 방식 설계 원칙:**

API로 갱신 제공 시 문제점:
```
시나리오: Client Secret 유출
→ 유출자가 API로 Secret 갱신 시도
→ 새로운 Secret도 탈취 가능
→ 보안 취약점
```

**해결 방안: 웹 포털 기반 셀프 서비스**

```
1. 외부 업체 담당자가 우리 서비스에 회원가입
2. 로그인 후 자신의 ExternalApp 관리
3. 웹 포털에서 Secret 갱신
```
---

## 12. 장단점 정리

### 장점

**운영 관점:**
- IP 변경과 무관한 안정성
- 인프라 확장 시 영향 없음
- 장애 추적 및 디버깅 용이

**보안 관점:**
- 업체별 Credential 관리
- 주기적 Secret 갱신 가능
- 접근 제어 강화

**개발 관점:**
- 인증 로직이 코드로 명확히 표현
- 테스트 작성 용이
- 유지보수 편의성 증가

### 단점

**초기 비용:**
- 설계 및 구현 시간 필요
- 테스트 및 검증 시간 필요
- 외부 업체 연동 변경 필요

**운영 복잡도:**
- Token 관리 로직 필요
- Client Secret 관리 필요
- 만료 정책 운영 필요

**학습 곡선:**
- JWT 이해 필요
- OAuth 개념 이해 필요

### 하지만

> IP 기반 인증의 장기 운영 리스크를 고려하면
> 초기 투자 대비 효과가 매우 큼

---

## 13. 마무리

### 핵심 교훈

**1. 간헐적 장애의 원인은 예상 밖에 있을 수 있다**

```
증상: 간헐적 403 Forbidden
원인: 로드밸런싱 + IP 변경
```

**2. 인증은 인프라 설정이 아니라 도메인 로직이다**

```
인증 로직이 Nginx에 숨어 있으면:
- 파악하기 어렵다
- 유지보수가 어렵다
- 확장이 어렵다
```

**3. 기술 부채는 쌓이기 전에 해결해야 한다**

```
"IP 하나만 추가하면 되는데..."
→ 다음에 또 발생
→ 점점 복잡해짐
→ 결국 큰 리팩토링 필요
```

### 개선의 효과

**Before:**
- IP 변경 시 즉시 장애
- 원인 파악 어려움
- 업체 식별 불가
- 확장 어려움

**After:**
- IP 변경과 무관
- 로그 기반 추적 가능
- 업체별 관리 가능
- 확장 용이

### 최종 메시지

> "인증이 어디서 어떻게 이루어지고 있는지
> 아무도 명확히 설명할 수 없는 구조"

이것이 이번 장애의 근본 원인이었다.

IP 기반 인증은 빠른 해결책일 수는 있지만,
운영이 길어질수록 기술 부채가 된다.

**인증은 인프라 설정이 아니라 도메인 로직으로 관리되어야 한다.**

---

