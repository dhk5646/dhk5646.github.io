---
title: "Java SSL 인증서 오류 해결: PKIX path building failed 분석"
categories: java
tags: [java, ssl, tls, certificate, security, troubleshooting]
excerpt: "WebClient 사용 중 발생한 SSL 인증서 오류를 해결하고, 인증서 체인의 동작 원리와 근본 원인을 분석한 실전 가이드"
---

## 들어가며

WebClient를 통해 외부 사이트에 로그인하여 데이터를 조회하는 작업 중 SSL 인증서 관련 오류가 발생했다.

처음에는 인증서를 수동으로 Java의 cacerts에 등록하여 문제를 해결했지만, 시간이 지나 **등록했던 인증서가 만료되었음에도 통신이 정상 작동**하는 현상을 발견했다.

이 글에서는 문제 해결 과정과 함께 **인증서 신뢰 체인의 동작 원리**를 깊이 있게 분석하고, 근본적인 해결 방법을 제시한다.

---

## 문제 상황

### 발생한 오류

```
reactor.core.Exceptions$ReactiveException: 
javax.net.ssl.SSLHandshakeException: 
PKIX path building failed: 
sun.security.provider.certpath.SunCertPathBuilderException: 
unable to find valid certification path to requested target
```

### 환경

- 애플리케이션: Spring WebClient
- 대상: 외부 사이트 (https://example.com)
- Java 버전: Java 11

---

## 1차 시도: 임시 해결 (인증서 수동 등록)

### 원인 파악

Java에서 SSL 인증서를 검증하는 과정에서 발생하는 오류로, 주요 원인은 다음과 같다:

1. **신뢰할 수 없는 인증서**: 서버가 제공하는 SSL 인증서가 Java의 truststore에 등록되지 않은 경우
2. **인증서 체인 문제**: 서버의 인증서 체인이 불완전하거나 루트 인증서가 누락된 경우
3. **Java 버전 문제**: 사용 중인 Java 버전의 truststore(cacerts)가 최신 루트 인증서를 포함하지 않은 경우

### Java의 인증서 검증 메커니즘

Java는 SSL/TLS 통신 시 다음과 같이 인증서를 검증한다:

1. 서버가 전송한 인증서를 받음
2. Java의 **truststore(기본: cacerts 파일)**에 등록된 인증서와 비교
3. 신뢰할 수 있는 인증서가 아니면 `PKIX path building failed` 오류 발생

Java는 기본적으로 `$JAVA_HOME/jre/lib/security/cacerts` 파일을 truststore로 사용한다.

---

## 해결 방법 1: 인증서 수동 등록

### 1단계: 인증서 다운로드

**Chrome 브라우저에서 인증서 다운로드:**

1. 대상 사이트 접속
2. 주소창의 **[자물쇠 아이콘]** 클릭
3. **[인증서]** 선택
4. **[자세히]** 탭 선택
5. **[파일에 복사]** 클릭
6. 인증서 내보내기 마법사:
   - 형식: **DER로 인코딩된 바이너리 X.509(.CER)**
   - 저장 위치 지정
   - 완료

결과: `example.com.cer` 파일 생성

### 2단계: Java cacerts에 인증서 등록

```bash
# 1. SSL 인증서 관리 폴더 생성
mkdir -p /home/ssl

# 2. Java의 lib/security 폴더로 이동 (cacerts 파일 위치)
cd /usr/java11_64/jre/lib/security

# 3. 안전한 작업을 위해 기존 cacerts 백업
cp cacerts cacerts.$(date +'%Y%m%d')

# 4. 기존 인증서 삭제 (이미 등록된 경우)
/usr/java11_64/bin/keytool -delete \
  -alias example \
  -keystore /usr/java11_64/jre/lib/security/cacerts \
  -storepass changeit

# 5. 새 인증서 등록
/usr/java11_64/bin/keytool -importcert \
  -keystore /usr/java11_64/jre/lib/security/cacerts \
  -trustcacerts \
  -alias example \
  -file "/home/ssl/example.com.cer" \
  -storepass changeit

# 입력 프롬프트
# 키 스토어 비밀번호 입력: changeit
# 이 인증서를 신뢰합니까? y
# 인증서가 키 스토어에 추가되었습니다.

# 6. 인증서 등록 확인
/usr/java11_64/bin/keytool -list -keystore cacerts -storepass changeit
/usr/java11_64/bin/keytool -list -v -keystore cacerts > ./list.txt
```

### keytool 명령어 옵션 설명

| 옵션 | 설명 |
|------|------|
| `-importcert` | 인증서 등록 |
| `-delete` | 인증서 삭제 |
| `-list` | 인증서 목록 조회 |
| `-alias` | 인증서 별칭 (식별자) |
| `-keystore` | keystore 파일 경로 |
| `-storepass` | keystore 비밀번호 (기본값: `changeit`) |
| `-trustcacerts` | CA 인증서로 신뢰 |
| `-file` | 인증서 파일 경로 |

### keytool이란?

**keytool**은 Java Key and Certificate Management Tool의 약자로, Java에서 제공하는 키스토어와 인증서를 관리하는 명령어 기반 도구다.

**주요 기능:**
- 키스토어 생성 및 관리
- 인증서 임포트, 삭제, 목록 조회
- SSL/TLS 통신을 위한 인증서 관리

### 서버 재시작 필요성

**왜 서버를 재시작해야 하는가?**

Java 애플리케이션이 JVM(Java Virtual Machine) 실행 시 truststore를 로드하고 이를 **캐싱**하기 때문이다.

1. JVM 시작 시 `javax.net.ssl.trustStore`에 지정된 truststore를 메모리에 로드
2. JVM이 실행되는 동안 변경 사항을 **자동으로 반영하지 않음**
3. 인증서를 추가하거나 수정한 경우, **JVM 재시작 필요**

### 결과

서버 재시작 후 외부 사이트와의 통신이 정상적으로 동작했다.

---

## 문제 발견: 이후 인증서가 만료되었음에도 통신이 되는 현상

### 의문점

시간이 지나 등록했던 인증서가 **만료**되었음에도 불구하고, 외부 사이트와의 통신이 **여전히 정상 작동**하는 현상이 발견되었다.

이는 단순한 임시 해결책이 아니라, **근본적인 원인을 이해하지 못했다**는 신호였다.

---

## 핵심 개념: 인증서 신뢰 체인 (Chain of Trust)

### 인증서 계층 구조

SSL 인증서는 단독으로 존재하지 않고, **상위 기관이 하위 기관을 보증하는 계층 구조**를 가진다.

```
루트 인증서 (Root CA)
    ↓ 발급 및 서명
중간 인증서 (Intermediate CA)
    ↓ 발급 및 서명
개별 인증서 (Leaf/End-Entity)
```

### 1. 루트 인증서 (Root CA)

**신뢰의 최상위 뿌리**

- 전 세계적으로 공인된 기관이 발행 (예: DigiCert, Let's Encrypt, USERTrust)
- Java 설치 시 **cacerts에 이미 포함**되어 있음
- 자체 서명(Self-Signed)
- 유효 기간: 수십 년

**예시:**
- USERTrust RSA Certification Authority
- DigiCert Global Root CA
- Let's Encrypt Root X3

### 2. 중간 인증서 (Intermediate CA)

**루트와 개별 인증서 사이의 징검다리**

- 루트 인증서로부터 권한을 위임받음
- 보안상 루트 인증서를 직접 사용하지 않고 중간 인증서를 통해 발급
- 루트 인증서가 유출되면 전체 신뢰 체계가 무너지므로, 중간 인증서로 위험 분산

**예시:**
- Sectigo RSA Domain Validation Secure Server CA
- Let's Encrypt Authority X3

### 3. 개별 인증서 (Leaf/End-Entity)

**실제 서비스 도메인에 발급된 인증서**

- 실제 웹사이트가 사용하는 인증서
- 도메인 정보 포함 (예: www.example.com)
- 유효 기간: 일반적으로 **1년** (보안 강화 목적)

**예시:**
- www.example.com
- api.example.com

---

## 신뢰 체인 검증 과정

### 정상적인 검증 흐름

```
1. 클라이언트가 서버에 접속
   ↓
2. 서버가 인증서 체인 전송
   - Leaf Certificate (개별)
   - Intermediate Certificate (중간)
   - (선택) Root Certificate (루트)
   ↓
3. 클라이언트(Java)의 검증 과정
   a. Leaf 인증서 확인
   b. Intermediate로 Leaf 서명 검증
   c. Root로 Intermediate 서명 검증
   d. Root가 truststore에 있는지 확인
   ↓
4. 신뢰 체인 완성 → 통신 성공
```

### 시각화

```
[서버]                          [클라이언트 - Java]
┌──────────────────┐           ┌──────────────────┐
│ Leaf Certificate │           │                  │
│ (example.com)    │────전송───→│                  │
├──────────────────┤           │                  │
│ Intermediate CA  │────전송───→│    검증 과정       │
│ (Sectigo RSA)    │           │                  │
└──────────────────┘           │                  │
                               │   cacerts에서     │
                               │   Root CA 확인    │
                               │   (USERTrust)    │
                               └───────────── ────┘
```

---

## 근본 원인 분석

### 처음에 왜 PKIX 에러가 발생했는가?

**문제: 서버의 인증서 체인 구성 미흡**

서버가 통신 시 **개별 인증서만** 보내고, 이를 루트와 이어줄 **중간 인증서를 누락**했다.

```
[서버 - 과거]
┌──────────────────┐
│ Leaf Certificate │ ──전송──→ [클라이언트]
│ (example.com)    │
└──────────────────┘
     중간 인증서 누락!
```

**결과:**

Java는 루트 인증서를 가지고 있었음에도 불구하고, **중간 다리가 없어** 신뢰 경로를 완성하지 못해 "믿을 수 없는 대상"으로 판단했다.

### 수동 등록 시 해결된 이유

`keytool`을 통해 개별 인증서를 직접 cacerts에 등록하는 행위는:

**"중간 다리(Chain)를 따지지 말고, 이 인증서 자체를 무조건 신뢰하라"**

고 Java에게 **지름길(Shortcut)**을 만들어 준 것과 같다.

```
[직접 등록 후]
┌─────────────────┐
│ cacerts         │
├─────────────────┤
│ Root CA         │ ← 원래부터 있음
│ (USERTrust)     │
├─────────────────┤
│ example.com     │ ← 수동으로 추가
│ (직접 신뢰)       │
└─────────────────┘
```

이 방식은 **임시 방편**이며, 다음과 같은 문제가 있다:

1. 인증서 만료 시마다 재등록 필요
2. 관리 포인트 증가
3. 보안 위험 (검증 우회)

---

## 만료 후에도 통신이 되는 이유

### 서버 설정의 변화

현재 서버 상태를 `openssl s_client`로 확인한 결과, **3개의 인증서 블록(Full Chain)**이 확인되었다.

```bash
# 서버가 전송하는 인증서 체인 확인
openssl s_client -connect example.com:443 -showcerts
```

**결과:**

```
Certificate chain
 0 s:/CN=example.com
   i:/C=US/O=Sectigo/CN=Sectigo RSA Domain Validation...
   -----BEGIN CERTIFICATE-----
   MIIFXzCCBEegAwIBAgIRAIu...
   -----END CERTIFICATE-----

 1 s:/C=US/O=Sectigo/CN=Sectigo RSA Domain Validation...
   i:/C=US/O=USERTrust/CN=USERTrust RSA Certification Authority
   -----BEGIN CERTIFICATE-----
   MIIGCDCCA/CgAwIBAgIQKy...
   -----END CERTIFICATE-----

 2 s:/C=US/O=USERTrust/CN=USERTrust RSA Certification Authority
   i:/C=GB/O=AddTrust/CN=AddTrust External CA Root
   -----BEGIN CERTIFICATE-----
   MIIF3jCCA8agAwIBAgIQAf...
   -----END CERTIFICATE-----
```

**3개의 인증서 블록 의미:**

1. **0번 블록**: Leaf Certificate (example.com)
2. **1번 블록**: Intermediate CA (Sectigo RSA)
3. **2번 블록**: Root CA (USERTrust)

### 서버 설정의 정상화

과거와 달리 현재 서버는 **개별 - 중간 - 루트 인증서를 모두 세트로 묶어서 전송**하고 있다.

```
[서버 - 현재]
┌──────────────────┐
│ Leaf Certificate │ ─┐
├──────────────────┤  │
│ Intermediate CA  │  ├─ Full Chain 전송
├──────────────────┤  │
│ Root CA          │ ─┘
└──────────────────┘
```

### 신뢰 체인의 완성

서버가 전송한 **중간 인증서** 덕분에 Java는 내부에 미리 설치되어 있던 **USERTrust RSA CA (루트)**까지의 신뢰 경로를 **스스로 찾아낼 수 있게** 되었다.

**검증 흐름:**

```
1. Leaf (example.com) 받음
   ↓
2. Intermediate (Sectigo RSA)로 Leaf 서명 검증
   ↓
3. Root (USERTrust)로 Intermediate 서명 검증
   ↓
4. cacerts에서 USERTrust 발견
   ↓
5. 신뢰 체인 완성 ✓
```

### 결론

기존에 수동 등록했던 개별 인증서 별칭은 이미 **만료되어 무시**되지만, **Java의 표준 신뢰 메커니즘(공인 루트 인증서 기반)**에 의해 통신이 성공하고 있는 것이다.

---

## 개선 방안

### 문제점: 인증서 수동 관리의 한계

1. **인증서 만료 주기**: 대부분의 CA는 보안상 이유로 **1년 단위**로 인증서 발급
2. **반복 작업**: 매년 인증서를 다운로드하고 keytool로 등록해야 함
3. **관리 부담**: 만료일을 추적하고 갱신 작업을 예약해야 함
4. **장애 위험**: 갱신을 놓치면 서비스 장애 발생

### 개선 포인트 1: 쉘 스크립트 자동화

인증서 등록 작업을 자동화하는 쉘 스크립트를 작성했다.

**ssl_regist.sh:**

```bash
#!/bin/bash

URL="$1"  # 예: example.com

# 서버별 설정 정보
JAVA_HOME="/usr/java11_64"
SSL_PATH="/home/ssl"

# 키스토어 경로 및 비밀번호 설정
CERT_PATH="$SSL_PATH/$URL.pem"
KEYSTORE_PATH="$JAVA_HOME/jre/lib/security/cacerts"
KEYTOOL_DIR="$JAVA_HOME/bin"
KEYSTORE_PASSWORD="changeit"
KEYSTORE_BACKUP_PATH=$KEYSTORE_PATH.$(date +'%Y%m%d_%H%M%S')

# 디렉터리 생성
mkdir -p $SSL_PATH

# 키스토어 백업
echo "키스토어 백업 중..."
cp "$KEYSTORE_PATH" "$KEYSTORE_BACKUP_PATH"
if [ $? -eq 0 ]; then
    echo "키스토어 백업 성공: $KEYSTORE_BACKUP_PATH"
else
    echo "키스토어 백업 실패"
    exit 1
fi

# 인증서 다운로드
echo ""
echo "인증서를 다운로드 중..."
echo | openssl s_client -connect $URL:443 -servername $URL 2>/dev/null | \
  openssl x509 > $CERT_PATH

if [ $? -eq 0 ]; then
    echo "인증서 다운로드 성공: $CERT_PATH"
else
    echo "인증서 다운로드 실패"
    exit 1
fi

# 기존 인증서가 존재하는지 확인하고 삭제
echo ""
echo "기존 인증서 확인 중..."

cd $KEYTOOL_DIR
CERT_EXIST=$(keytool -list -keystore "$KEYSTORE_PATH" \
  -storepass "$KEYSTORE_PASSWORD" | grep "$URL")

if [ -z "$CERT_EXIST" ]; then
    echo "기존 인증서가 없습니다."
else
    keytool -delete -alias $URL -keystore $KEYSTORE_PATH \
      -storepass "$KEYSTORE_PASSWORD" -noprompt
    
    if [ $? -ne 0 ]; then
        echo "인증서 삭제에 실패했습니다."
        exit 1
    else
        echo "기존 인증서를 삭제하였습니다."
    fi
fi

# 새 인증서 등록
echo ""
echo "새 인증서 등록 중..."
keytool -importcert -file $CERT_PATH -keystore $KEYSTORE_PATH \
  -alias $URL -storepass $KEYSTORE_PASSWORD \
  -trustcacerts -noprompt

echo "인증서가 키스토어에 성공적으로 등록되었습니다."

# 인증서 만료일자
echo ""
echo "인증서 만료일자를 캘린더에 등록하세요."
EXPIRY_DATE=$(echo | openssl s_client -connect $URL:443 \
  -servername $URL 2>/dev/null | \
  openssl x509 -noout -enddate | awk -F= '{print $2}')
echo "인증서 만료일자: $EXPIRY_DATE"
```

**스크립트 기능:**

1. 키스토어 백업 (타임스탬프 포함)
2. openssl로 인증서 자동 다운로드
3. 기존 인증서 자동 삭제
4. 새 인증서 자동 등록
5. 만료일자 출력

**사용 방법:**

```bash
# 실행 권한 부여
chmod +x ssl_regist.sh

# 인증서 등록
./ssl_regist.sh example.com
```

**실행 결과:**

```
키스토어 백업 중...
키스토어 백업 성공: /usr/java11_64/jre/lib/security/cacerts.20250106_143022

인증서를 다운로드 중...
인증서 다운로드 성공: /home/ssl/example.com.pem

기존 인증서 확인 중...
기존 인증서가 없습니다.

새 인증서 등록 중...
인증서가 키스토어에 성공적으로 등록되었습니다.

인증서 만료일자를 캘린더에 등록하세요.
인증서 만료일자: Jan 6 23:59:59 2026 GMT
```

### 개선 포인트 2: 근본적인 해결 방법

**임시 방편이 아닌 근본 해결:**

1. **서버 측 Full Chain 설정 요청**
   - 개별, 중간, 루트 인증서를 모두 전송하도록 서버 설정
   - Nginx, Apache 등 웹서버에서 설정 가능

2. **공인 CA 사용**
   - 공인 인증 기관(Let's Encrypt, DigiCert 등)의 인증서 사용
   - Java의 cacerts에 이미 루트 인증서가 포함되어 있음

3. **Java 버전 업데이트**
   - 최신 Java 버전은 최신 루트 인증서를 포함

4. **모니터링 및 알람**
   - 인증서 만료일 모니터링
   - 만료 30일 전 알람 설정

---

## 알아두면 좋은 것!

### SSL 이슈 발생 시 체크리스트

**1. 서버가 보내는 인증서 체인 확인**

```bash
openssl s_client -connect example.com:443 -showcerts
```

**블록이 1개라면?**
- 서버가 개별 인증서만 전송
- **서버 측에 Full Chain 설정 요청 필요**

**블록이 2-3개인데도 안 된다면?**
- 클라이언트의 cacerts에 루트 인증서가 없음
- Java 버전 업데이트 또는 루트 인증서 수동 설치

**2. 인증서 만료일 확인**

```bash
echo | openssl s_client -connect example.com:443 2>/dev/null | \
  openssl x509 -noout -dates
```

**3. Java의 truststore 확인**

```bash
keytool -list -keystore $JAVA_HOME/jre/lib/security/cacerts \
  -storepass changeit | grep -i "issuer"
```

**4. 특정 CA가 truststore에 있는지 확인**

```bash
keytool -list -keystore $JAVA_HOME/jre/lib/security/cacerts \
  -storepass changeit | grep -i "usertrust"
```

---

## 최종 정리

### 해결책 비교

| 방법 | 장점 | 단점 | 권장도 |
|------|------|------|--------|
| **개별 인증서 수동 등록** | 빠른 임시 해결 | 관리 부담, 만료 시 장애 위험 | 비권장 |
| **쉘 스크립트 자동화** | 작업 간소화 | 여전히 주기적 작업 필요 | 차선책 |
| **서버 Full Chain 설정** | 근본적 해결, 관리 불필요 | 서버 측 협조 필요 | **강력 권장** |

### 핵심 원칙

1. **임시 방편보다 근본 해결**
   - 개별 인증서 등록은 임시 조치
   - 서버가 Full Chain을 전송하도록 설정하는 것이 정석

2. **신뢰 체인 이해**
   - 루트 - 중간 - 개별 인증서의 관계 이해
   - 각 인증서의 역할과 검증 흐름 파악

3. **공인 CA 활용**
   - Let's Encrypt 등 무료 공인 CA 활용
   - Java의 표준 신뢰 메커니즘 활용

4. **모니터링 체계 구축**
   - 인증서 만료일 추적
   - 자동화된 갱신 프로세스 구축

### 마지막으로

SSL 인증서 문제는 **증상 해결**에 머무르지 말고, **근본 원인**을 이해하는 것이 중요하다.

인증서 신뢰 체인의 동작 원리를 이해하면, 비슷한 문제가 발생했을 때 빠르게 원인을 파악하고 올바른 해결책을 선택할 수 있다.

---

## Reference

- [Oracle Java Keytool Documentation](https://docs.oracle.com/javase/8/docs/technotes/tools/unix/keytool.html)
- [OpenSSL s_client Manual](https://www.openssl.org/docs/man1.1.1/man1/s_client.html)
- [RFC 5280 - Internet X.509 PKI Certificate](https://datatracker.ietf.org/doc/html/rfc5280)
- [Let's Encrypt Chain of Trust](https://letsencrypt.org/certificates/)
- [Java Secure Socket Extension (JSSE) Reference Guide](https://docs.oracle.com/javase/8/docs/technotes/guides/security/jsse/JSSERefGuide.html)

