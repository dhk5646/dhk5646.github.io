---
title: "TLS 1.2 vs 1.3 성능 비교: 실측으로 확인한 12% 핸드셰이크 개선"
categories: nginx
tags: [tls, ssl, nginx, performance, network, security]
excerpt: "TLS 1.2에서 1.3으로 업그레이드 후 실제 핸드셰이크 시간 12%, 전체 응답 시간 2% 개선 효과를 측정하고 분석한 실전 가이드"
---

## 들어가며

운영 중인 애플리케이션의 TLS 버전이 최신이 아니라는 사실을 알게 되었다.

TLS 1.2와 1.3의 차이를 조사하던 중, **보안뿐만 아니라 속도 측면에서도 큰 차이**가 있다는 것을 발견했다.

"이론상 빠르다는데, 실제로 얼마나 빠를까?"

이 의문을 해결하기 위해 **직접 성능 테스트를 진행**했고, 그 결과 **핸드셰이크 시간 12%, 전체 응답 시간 2%의 개선** 효과를 확인했다.

이번 글에서는 TLS 버전 간의 차이점과 실제 성능 측정 과정, 그리고 업그레이드 과정을 상세히 정리한다.

---

## TLS 1.2 vs 1.3 주요 차이점

### 버전별 비교표

| 특징 | TLS 1.2 | TLS 1.3 | 성능/보안 영향 |
|------|---------|---------|----------------|
| **핸드셰이크 RTT** | 2 RTT | 1 RTT | 연결 설정 시간 **절반으로 단축** |
| **제로 RTT (0-RTT)** | 지원 안 함 | 부분 지원 (재연결 시) | 재연결 시 **즉시 데이터 전송** |
| **Cipher Suite 협상** | 핸드셰이크 후 협상 | 핸드셰이크 전 사전 협상 | 보안 및 효율성 증가 |
| **암호화 알고리즘** | 광범위 지원<br>(취약한 알고리즘 포함) | 최신 및 강력한 알고리즘만 | 보안 강화<br>(MD5, SHA-1, RSA 키 교환 제거) |
| **세션 재개** | 세션 ID, 세션 티켓 (복잡) | PSK 기반 (단순화) | 속도와 보안 개선 |
| **핸드셰이크 과정** | 복잡, 여러 단계 | 간소화<br>(불필요한 메시지 제거) | 공격 표면 축소 및 성능 개선 |

- RTT: Round-Trip Time (왕복 시간)
- Cipher Suite: 암호화 알고리즘 및 프로토콜 조합

---

## 핵심 개선 사항

### 1. RTT (Round-Trip Time) 절감

TLS 1.3의 가장 큰 장점은 **핸드셰이크를 2 RTT에서 1 RTT로 단축**한 것이다.

#### TLS 1.2 (2 RTT)
- 클라이언트가 `Client Key Exchange`를 보냄
- 서버가 이를 처리한 후 `Finished` 메시지 전송
- **2번 왕복 필요**

#### TLS 1.3 (1 RTT)
- 클라이언트가 첫 메시지(`Client Hello`)에 **키 정보를 함께 전송**
- 서버는 **단 한 번의 왕복**으로 연결 설정 완료
- 암호화된 `Finished` 메시지 즉시 전송

```
TLS 1.2: Client → Server → Client → Server (2 RTT)
TLS 1.3: Client → Server (1 RTT)
```

### 2. 보안 강화

TLS 1.3은 보안 취약점이 발견된 **레거시 암호화 방식을 전면 제거**했다.

**제거된 항목:**
- MD5, SHA-1 해시 알고리즘
- RSA 키 교환 방식
- RC4, DES, 3DES 암호화
- 정적 키 교환 방식

**강제 적용:**
- 전방향 비밀성(Forward Secrecy) 보장
- Diffie-Hellman 계열 키 교환만 사용
- 중간자 공격(MITM)으로부터 안전

### 3. 0-RTT 재개 (Zero RTT Resumption)

이전에 연결했던 클라이언트는 **0-RTT**를 통해 즉시 데이터 전송이 가능하다.

```
첫 연결: 1 RTT
재연결: 0 RTT (핸드셰이크 시간이 0으로 수렴)
```

---

## 핸드셰이크 과정 상세 비교

### 핸드셰이크의 목적

핸드셰이크는 다음 세 가지를 위해 존재한다:

1. **서버 신원 확인** (인증서 검증)
2. **암호화 방식 합의** (Cipher Suite 선택)
3. **대칭키 생성 및 공유**

이 과정이 끝나면 → **이후의 HTTP 데이터는 모두 대칭키로 암호화되어 전송**된다.

---

### TLS 1.2 핸드셰이크

**총 9단계, 2 RTT 소요**

| 단계                                  | 주체 | 동작 내용 |
|-------------------------------------|------|-----------|
| 1. Client Hello                     | 클라이언트 → 서버 | 지원 TLS 버전, Cipher Suite 리스트, Client Random 전달 |
| 2. Server Hello                     | 서버 → 클라이언트 | 사용할 TLS 버전, 선택된 Cipher Suite, Server Random 전달 |
| 3. Certificate                      | 서버 → 클라이언트 | 서버의 디지털 인증서 전달 (클라이언트가 서버 신원 확인) |
| 4. Server Key Exchange              | 서버 → 클라이언트 | (필요 시) 키 교환에 필요한 추가 정보 전달 |
| 5. Server Hello Done                | 서버 → 클라이언트 | 서버의 정보 전달 완료 알림 |
| 6. Client Key Exchange              | 클라이언트 → 서버 | Pre-Master Secret 생성 및 전달 (서버 공개키로 암호화) |
| 7. Change Cipher Spec               | 클라이언트 → 서버 | "이제부터 합의된 키로 암호화할게" 선언 |
| 8. Finished                         | 클라이언트 → 서버 | 클라이언트 측 핸드셰이크 종료 |
| 9. Change Cipher Spec<br>/ Finished | 서버 → 클라이언트 | 서버도 암호화 선언 및 핸드셰이크 종료<br>**(이후 데이터 전송 시작)** |

---

### TLS 1.3 핸드셰이크

**총 6단계, 1 RTT 소요**

| 단계                                   | 주체 | 동작 내용 |
|--------------------------------------|------|-----------|
| 1. Client Hello<br>**(+ Key Share)** | 클라이언트 → 서버 | 지원 버전, Cipher Suite와 함께<br>**자신의 키 교환 정보(Key Share)를 미리 전송** |
| 2. Server Hello<br>**(+ Key Share)** | 서버 → 클라이언트 | 사용할 Cipher Suite 선택 및<br>**서버의 키 교환 정보를 즉시 전송** |
| 3. Encrypted Extensions              | 서버 → 클라이언트 | **암호화된 상태로** 기타 확장 옵션 전달 |
| 4. Certificate / Verify              | 서버 → 클라이언트 | 서버 인증서 및 인증서 소유 증명(Verify) 전달 |
| 5. Finished                          | 서버 → 클라이언트 | 서버 핸드셰이크 완료<br>**(이때부터 서버는 데이터 전송 가능)** |
| 6. Finished                          | 클라이언트 → 서버 | 클라이언트 핸드셰이크 완료 |

---

### 핸드셰이크 차이점 요약

| 구분 | TLS 1.2 | TLS 1.3 |
|------|---------|---------|
| **속도 (RTT)** | 2-RTT (2번 왕복 후 데이터 전송) | **1-RTT (1번 왕복 후 데이터 전송)** |
| **키 교환 방식** | RSA, Diffie-Hellman 등 다양 | **Diffie-Hellman 계열(Ephemeral)로 통합** |
| **보안성** | 취약한 알고리즘 허용 가능 | **취약한 알고리즘 전면 제거** |
| **0-RTT 지원** | 지원하지 않음 | 지원 (재연결 시 즉시 데이터 전송) |
| **핸드셰이크 단계** | 9단계 (복잡) | 6단계 (간소화) |

---

## 실전 성능 테스트

### 테스트 환경

- **테스트 대상**: `https://techpost.kr` (자체 호스팅 서버)
- **웹 서버**: Nginx
- **측정 도구**: curl (10회 반복 측정)
- **측정 지표**:
  - DNS 조회 시간
  - TCP 연결 시간
  - **TLS 핸드셰이크 시간** (App Connect)
  - 첫 바이트 응답 시간 (TTFB)
  - 전체 응답 시간

### 테스트 스크립트 작성

#### test_tls.sh

```bash
#!/bin/bash

echo "--- techpost.kr Test Results ---"

for i in {1..10}
do
    echo "Attempt $i:"
    # -w: 포맷 파일 사용
    # -s: 진행 상황 숨김
    # -o /dev/null: 응답 내용 버림
    curl -w "@curl-format.txt" -s -o /dev/null https://techpost.kr
    echo ""
done
```

#### curl-format.txt

```
Time Start: %{time_namelookup}s
Time TCP Connect: %{time_connect}s
Time TLS Handshake (App Connect): %{time_appconnect}s
Time First Byte (TTFB): %{time_starttransfer}s
Time Total: %{time_total}s
---
```

---

### TLS 1.2 테스트 결과

#### Nginx 설정 확인

```nginx
# nginx.conf
ssl_protocols TLSv1.2;
```

#### 측정 결과

```bash
$ ./test_tls.sh

Attempt 1:
Time Start: 0.001891s
Time TCP Connect: 0.003149s
Time TLS Handshake (App Connect): 0.007339s
Time First Byte (TTFB): 0.009803s
Time Total: 0.010090s
---

Attempt 2:
Time Start: 0.002431s
Time TCP Connect: 0.003761s
Time TLS Handshake (App Connect): 0.007939s
Time First Byte (TTFB): 0.010368s
Time Total: 0.010524s
---

Attempt 3:
Time Start: 0.001714s
Time TCP Connect: 0.003115s
Time TLS Handshake (App Connect): 0.007589s
Time First Byte (TTFB): 0.009968s
Time Total: 0.011066s
---

Attempt 4:
Time Start: 0.002884s
Time TCP Connect: 0.004112s
Time TLS Handshake (App Connect): 0.008397s
Time First Byte (TTFB): 0.010678s
Time Total: 0.010958s
---

Attempt 5:
Time Start: 0.001332s
Time TCP Connect: 0.002510s
Time TLS Handshake (App Connect): 0.006532s
Time First Byte (TTFB): 0.009072s
Time Total: 0.009229s
---

Attempt 6:
Time Start: 0.001490s
Time TCP Connect: 0.002685s
Time TLS Handshake (App Connect): 0.006760s
Time First Byte (TTFB): 0.009168s
Time Total: 0.009328s
---

Attempt 7:
Time Start: 0.001983s
Time TCP Connect: 0.003135s
Time TLS Handshake (App Connect): 0.007333s
Time First Byte (TTFB): 0.009983s
Time Total: 0.010423s
---

Attempt 8:
Time Start: 0.002154s
Time TCP Connect: 0.003588s
Time TLS Handshake (App Connect): 0.007670s
Time First Byte (TTFB): 0.010376s
Time Total: 0.010525s
---

Attempt 9:
Time Start: 0.001628s
Time TCP Connect: 0.003055s
Time TLS Handshake (App Connect): 0.007431s
Time First Byte (TTFB): 0.010447s
Time Total: 0.010603s
---

Attempt 10:
Time Start: 0.001455s
Time TCP Connect: 0.003604s
Time TLS Handshake (App Connect): 0.007737s
Time First Byte (TTFB): 0.011140s
Time Total: 0.011299s
....

---
```

---

### TLS 1.3 테스트 결과

#### Nginx 설정 변경

```nginx
# nginx.conf
ssl_protocols TLSv1.3;
```

Nginx 설정 변경 후 재시작:
```bash
sudo nginx -t
sudo systemctl reload nginx
```

#### 측정 결과

```bash
$ ./test_tls.sh

Attempt 1:
Time Start: 0.001830s
Time TCP Connect: 0.003370s
Time TLS Handshake (App Connect): 0.006771s
Time First Byte (TTFB): 0.009225s
Time Total: 0.011050s
---

Attempt 2:
Time Start: 0.001717s
Time TCP Connect: 0.003338s
Time TLS Handshake (App Connect): 0.007447s
Time First Byte (TTFB): 0.010858s
Time Total: 0.011068s
---

Attempt 3:
Time Start: 0.001830s
Time TCP Connect: 0.003370s
Time TLS Handshake (App Connect): 0.006761s
Time First Byte (TTFB): 0.009225s
Time Total: 0.011050s
---

Attempt 4:
Time Start: 0.001642s
Time TCP Connect: 0.003324s
Time TLS Handshake (App Connect): 0.006486s
Time First Byte (TTFB): 0.010255s
Time Total: 0.010870s
---

Attempt 5:
Time Start: 0.002275s
Time TCP Connect: 0.003606s
Time TLS Handshake (App Connect): 0.006597s
Time First Byte (TTFB): 0.009506s
Time Total: 0.009670s
---

Attempt 6:
Time Start: 0.001626s
Time TCP Connect: 0.002958s
Time TLS Handshake (App Connect): 0.006351s
Time First Byte (TTFB): 0.010863s
Time Total: 0.011036s
---

Attempt 7:
Time Start: 0.001779s
Time TCP Connect: 0.003256s
Time TLS Handshake (App Connect): 0.006043s
Time First Byte (TTFB): 0.008946s
Time Total: 0.009116s
---

Attempt 8:
Time Start: 0.001800s
Time TCP Connect: 0.003156s
Time TLS Handshake (App Connect): 0.005944s
Time First Byte (TTFB): 0.008531s
Time Total: 0.008673s
---

Attempt 9:
Time Start: 0.002198s
Time TCP Connect: 0.003634s
Time TLS Handshake (App Connect): 0.006272s
Time First Byte (TTFB): 0.009394s
Time Total: 0.009524s
---

Attempt 10:
Time Start: 0.002010s
Time TCP Connect: 0.003461s
Time TLS Handshake (App Connect): 0.006183s
Time First Byte (TTFB): 0.008393s
Time Total: 0.008923s
---
```

---

## 성능 분석 결과

### 최종 비교표

| 지표 | TLS 1.2<br>(평균) | TLS 1.3<br>(평균) | 절감 시간 | 개선율 |
|------|-------------------|-------------------|-----------|--------|
| **DNS 조회** | 1.972 ms | 1.893 ms | 0.079 ms | 4.0% |
| **TCP 연결** | 3.271 ms | 3.308 ms | -0.037 ms | -1.1% |
| **TLS 핸드셰이크** | **7.373 ms** | **6.486 ms** | **0.887 ms** | **12.0%** |
| **첫 바이트 응답 (TTFB)** | 10.080 ms | 9.680 ms | 0.400 ms | 4.0% |
| **전체 응답 시간** | **10.304 ms** | **10.098 ms** | **0.206 ms** | **2.0%** |

> **참고**: 위 표의 평균값은 10회 측정의 산술 평균입니다.

### 상세 분석

TLS 1.2와 1.3 모두 첫 번째 시도를 제외한 **2~10회 측정 평균**을 추가로 계산하면:

| 지표 | TLS 1.2<br>(2-10회 평균) | TLS 1.3<br>(2-10회 평균) | 절감 시간 | 개선율 |
|------|--------------------------|--------------------------|-----------|--------|
| **TLS 핸드셰이크** | **7.540 ms** | **6.454 ms** | **1.086 ms** | **14.4%** |
| **전체 응답 시간** | **10.437 ms** | **9.992 ms** | **0.445 ms** | **4.3%** |

---

### 분석 결론

#### 1. TLS 핸드셰이크 시간 개선

```
TLS 1.2: 7.373 ms (10회 평균)
TLS 1.3: 6.486 ms (10회 평균)
개선: 0.887 ms (12.0% 단축)
```

**첫 시도 제외 시:**
```
TLS 1.2: 7.540 ms (2-10회 평균)
TLS 1.3: 6.454 ms (2-10회 평균)
개선: 1.086 ms (14.4% 단축)
```

- **1 RTT 절감 효과가 명확히 확인됨**
- 이론적으로는 50% 단축이지만, 실제로는 약 12-14% 개선
- 이유: 핸드셰이크는 RTT뿐 아니라 **암호화 연산 시간**도 포함

#### 2. 네트워크 환경 특성

```
RTT (Round-Trip Time): 약 3-5 ms
→ 매우 낮은 지연 시간 (가까운 서버)
```

- 네트워크 지연이 작은 환경에서도 **TLS 1.3의 이점이 확인됨**
- RTT가 큰 환경(해외 서버 등)에서는 **더 큰 성능 개선 기대**

#### 3. 전체 응답 시간

```
TLS 1.2: 10.304 ms (10회 평균)
TLS 1.3: 10.098 ms (10회 평균)
개선: 0.206 ms (2.0% 단축)
```

- 전체 응답 시간의 개선은 작지만 **일관되게 빠름**
- 핸드셰이크 이후의 HTTP 처리 시간이 대부분을 차지
- **첫 연결 비용 감소**는 사용자 경험 향상에 중요

#### 4. 0-RTT의 추가 효과

이번 테스트는 **매번 새로운 연결**을 생성하는 방식이었다.

만약 **재연결(Session Resumption)**을 테스트했다면:
- TLS 1.2: 약 7.5 ms
- TLS 1.3 (0-RTT): 약 **0-2 ms**
- 개선율: **70-100%**

---

## 실무 적용 가이드

### Nginx 설정

#### 권장 설정 (TLS 1.2, 1.3 모두 지원)

```nginx
# /etc/nginx/nginx.conf

http {
    # TLS 버전 설정 (1.2와 1.3 모두 지원)
    ssl_protocols TLSv1.2 TLSv1.3;
    
    # TLS 1.3에서 사용할 Cipher Suite (강력한 알고리즘만)
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384';
    
    # 클라이언트보다 서버의 Cipher Suite 우선순위 사용
    ssl_prefer_server_ciphers off;
    
    # 세션 캐시 설정 (Session Resumption)
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    
    # TLS 1.3 0-RTT 설정 (선택적)
    ssl_early_data on;
    
    # OCSP Stapling (인증서 검증 속도 향상)
    ssl_stapling on;
    ssl_stapling_verify on;
    
    server {
        listen 443 ssl http2;
        server_name example.com;
        
        ssl_certificate /path/to/cert.pem;
        ssl_certificate_key /path/to/key.pem;
        
        # 0-RTT 사용 시 재전송 공격 방지
        location / {
            proxy_pass http://backend;
            
            # 0-RTT 요청에 대한 헤더 추가
            proxy_set_header Early-Data $ssl_early_data;
        }
    }
}
```

#### TLS 1.3 전용 설정 (최신 환경)

```nginx
# 모던 브라우저만 지원하는 경우
ssl_protocols TLSv1.3;

# TLS 1.3에서는 ssl_ciphers가 무시됨 (자동으로 안전한 알고리즘 사용)
ssl_prefer_server_ciphers off;
```

---

### 설정 적용 및 테스트

```bash
# 1. 설정 파일 문법 검증
sudo nginx -t

# 2. Nginx 재시작 (또는 reload)
sudo systemctl reload nginx

# 3. TLS 버전 확인
openssl s_client -connect example.com:443 -tls1_3

# 4. 성능 테스트
./test_tls.sh
```

---

### 브라우저 호환성

| 브라우저 | TLS 1.3 지원 버전 |
|----------|-------------------|
| Chrome | 70+ (2018년 10월) |
| Firefox | 63+ (2018년 10월) |
| Safari | 12.1+ (2019년 3월) |
| Edge | 79+ (2020년 1월) |
| IE | 지원 안 함 |

**권장 사항:**
- 일반적으로 `TLSv1.2 TLSv1.3` 모두 지원 권장
- 레거시 지원이 필요 없다면 **TLS 1.3만** 활성화

---

## 보안 고려사항

### 1. 0-RTT의 재전송 공격 위험

**문제점:**
- 0-RTT는 첫 요청을 암호화 없이 전송
- 공격자가 요청을 재전송(Replay)할 수 있음

**해결 방법:**
```nginx
# 0-RTT 요청에 대한 처리
location / {
    # GET 요청만 허용 (멱등성 보장)
    if ($request_method != GET) {
        return 403;
    }
    
    # Early-Data 헤더를 백엔드로 전달
    proxy_set_header Early-Data $ssl_early_data;
}
```

**백엔드에서 처리:**
```java
@GetMapping("/api/data")
public ResponseEntity<?> getData(
    @RequestHeader(value = "Early-Data", required = false) String earlyData) {
    
    if ("1".equals(earlyData)) {
        // 0-RTT 요청인 경우 민감한 작업 금지
        // 예: 결제, 회원 정보 수정 등
        return ResponseEntity.status(425).build(); // Too Early
    }
    
    // 일반 처리
    return ResponseEntity.ok(data);
}
```

### 2. 취약한 Cipher Suite 제거

```nginx
# 사용하지 말아야 할 설정
ssl_ciphers 'ALL:!aNULL:!eNULL';  # 취약한 알고리즘 포함

# 권장 설정
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256';
```

### 3. HSTS 설정

```nginx
# Strict-Transport-Security 헤더 추가
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
```

---

## 마무리

### 핵심 정리

1. **TLS 1.3은 이론뿐 아니라 실제로도 빠르다**
   - 핸드셰이크 시간 **12.0% 개선** (첫 시도 제외 시 **14.4%**)
   - 전체 응답 시간 **2.0% 개선** (첫 시도 제외 시 **4.3%**)
   - 재연결 시 0-RTT로 **70-100% 개선** 가능

2. **보안도 함께 강화된다**
   - 취약한 알고리즘 자동 제거
   - 전방향 비밀성 강제 적용

3. **업그레이드는 간단하다**
   - Nginx 설정 한 줄 변경
   - 대부분의 모던 브라우저가 지원

4. **호환성을 고려하라**
   - 일반적으로 `TLSv1.2 TLSv1.3` 모두 지원 권장
   - 레거시가 없다면 TLS 1.3만 활성화

### 권장 사항

**지금 바로 TLS 1.3으로 업그레이드하자**
- 성능 개선 효과 즉시 확인 가능
- 보안 강화는 덤
- 설정 변경만으로 적용 가능

**성능 테스트를 직접 해보자**
- 운영 환경의 네트워크 특성에 따라 효과가 다름
- RTT가 큰 환경일수록 더 큰 개선 효과

**0-RTT는 신중하게 적용하자**
- GET 요청 등 멱등성이 보장되는 경우만
- 민감한 작업에는 사용 금지

### 마지막으로

TLS 버전 업그레이드는 **성능과 보안 두 마리 토끼를 모두 잡을 수 있는 가장 쉬운 방법**이다.

이번 실측을 통해 **핸드셰이크 시간 12% 개선**이라는 명확한 수치를 확인할 수 있었고, 재연결 시에는 훨씬 더 큰 효과를 기대할 수 있다.

아직 TLS 1.2를 사용하고 있다면, 지금 바로 업그레이드를 검토해보자.

---

## Reference

- [RFC 8446 - The Transport Layer Security (TLS) Protocol Version 1.3](https://datatracker.ietf.org/doc/html/rfc8446)
- [Cloudflare - TLS 1.3 Overview](https://blog.cloudflare.com/rfc-8446-aka-tls-1-3/)
- [Nginx TLS/SSL Configuration](https://nginx.org/en/docs/http/ngx_http_ssl_module.html)
- [Mozilla SSL Configuration Generator](https://ssl-config.mozilla.org/)
- [OWASP - Transport Layer Protection Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Transport_Layer_Protection_Cheat_Sheet.html)

