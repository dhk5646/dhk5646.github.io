---
title: "배포 후 헬스체크 자동화 - 안전한 배포를 위한 검증 스크립트"
categories: devops
tags: [deployment, health-check, shell-script, automation]
excerpt: "배포 후 애플리케이션이 정상적으로 기동되었는지 자동으로 검증하는 헬스체크 스크립트 설계"
---

## 들어가며

배포 자동화를 구축하면서 가장 중요하게 고민했던 부분은 **"배포는 성공했는데, 서비스가 정상적으로 동작하지 않는다면?"** 이었다.

애플리케이션을 재시작한 후:
- 프로세스는 떠 있지만 내부 초기화 실패
- 포트는 열렸지만 요청 처리 불가
- 일부 기능만 동작하는 부분 장애

이런 상황을 방지하기 위해 **배포 후 자동 헬스체크 스크립트**를 도입했다.

---

## 1. 문제 상황

### 기존 배포 프로세스의 문제점

```
1. 애플리케이션 종료
2. 새 버전 배포
3. 애플리케이션 시작
4. 배포 완료 (실제 동작 여부 미확인)
```

**실제로 겪었던 문제들:**

**1. 프로세스만 떠있고 서비스는 죽은 경우**
- Spring Boot 기동 중 Exception 발생
- 프로세스는 살아있지만 요청 처리 불가

**2. DB 연결 실패**
- 커넥션 풀 초기화 실패
- 서비스는 떠 있지만 모든 요청이 500 에러

**3. 외부 연동 초기화 실패**
- 외부 API 연동 실패
- 일부 기능만 동작하는 상태

### 필요했던 것

배포 완료 후 **실제로 서비스가 정상 동작하는지 자동 검증**하는 메커니즘

---

## 2. 해결 방법: 헬스체크 스크립트

### 설계 원칙

**1. 충분한 대기 시간 제공**
- Spring Boot 애플리케이션이 완전히 기동될 때까지 대기
- 최대 120초 동안 반복 체크

**2. 실제 요청 기반 검증**
- 프로세스 존재 여부가 아닌 HTTP 요청으로 검증
- `/monitor/health` 엔드포인트 호출

**3. 실패 시 배포 중단**
- 헬스체크 실패 시 배포 프로세스 종료
- 롤백 등 후속 조치 가능

### 스크립트 구현

```bash
#!/bin/sh

# 배포 이후 헬스체크 목적으로 사용

SERVICE_PORT=$1

# 서비스가 건강한가? 0(참) or 1(거짓)
function hasServiceHealthy() {

    # 최대 120초 동안 1초 간격으로 헬스체크
    for ((i=1; i<=120; i++)); do

        local status=$(curl -s -m 1 -o /dev/null -w "%{http_code}" \
            "http://localhost:${SERVICE_PORT}/monitor/health")
        
        if [ $status -eq 200 ]; then
            echo "[SUCCESS] 헬스체크 성공 (${i}초 소요)"
            return 0; # 서비스 정상
        fi

        echo "[${i}/120] 헬스체크 대기 중... (HTTP ${status})"
        sleep 1
    done

    echo "[FAILED] 헬스체크 실패: 120초 내 응답 없음"
    return 1; # 서비스 비정상
}

###############################################################
# Main
###############################################################
if [ -z "$SERVICE_PORT" ]; then
    echo "[ERROR] 사용법: $0 <SERVICE_PORT>"
    exit 1
fi

echo "=========================================="
echo "헬스체크 시작: PORT=${SERVICE_PORT}"
echo "=========================================="

if ! hasServiceHealthy; then
    echo "[ERROR] 배포 실패: 서비스가 정상 기동되지 않음"
    exit 1 # 오류
fi

echo "[SUCCESS] 배포 완료: 서비스 정상 동작"
exit 0 # 정상
```

### 스크립트 설명

**파라미터:**
- `$1`: 서비스 포트 (예: 8080)

**hasServiceHealthy 함수:**
- 최대 120초 동안 1초 간격으로 헬스체크
- curl로 `/monitor/health` 엔드포인트 호출
- HTTP 200 응답 시 성공
- 120초 내 응답 없으면 실패

**curl 옵션:**
- `-s`: 진행 상황 숨김 (silent)
- `-m 1`: 최대 대기 1초 (timeout)
- `-o /dev/null`: 응답 본문 버림
- `-w "%{http_code}"`: HTTP 상태 코드만 출력

**Main 로직:**
- 포트 파라미터 검증
- 헬스체크 실행
- 실패 시 exit 1 (배포 중단)
- 성공 시 exit 0 (배포 계속)

---

## 3. Health Check API 구현

### Controller

```java
@RestController
@RequestMapping("/monitor")
public class MonitorController {
    
    private final HealthChecker healthChecker;
    
    @GetMapping("/health")
    public ResponseEntity<HealthCheckResponse> health() {
        HealthCheckResponse response = healthChecker.check();
        
        if (response.isHealthy()) {
            return ResponseEntity.ok(response);
        }
        
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
            .body(response);
    }
}
```

### HealthChecker

```java
@Component
@RequiredArgsConstructor
public class HealthChecker {
    
    private final DataSource dataSource;
    // private final ExternalApiClient externalApiClient;
    
    public HealthCheckResponse check() {
        List<String> errors = new ArrayList<>();
        
        // 1. DB 연결 체크
        if (!checkDatabase()) {
            errors.add("DB 연결 실패");
        }
        
        // 2. 외부 API 연결 체크 (선택)
        // if (!checkExternalApi()) {
        //     errors.add("외부 API 연결 실패");
        // }
        
        boolean healthy = errors.isEmpty();
        
        return HealthCheckResponse.of(healthy, errors);
    }
    
    private boolean checkDatabase() {
        try (Connection conn = dataSource.getConnection()) {
            return conn.isValid(1); // 1초 타임아웃
        } catch (Exception e) {
            log.error("DB 헬스체크 실패", e);
            return false;
        }
    }
}
```

### Response DTO

```java
@Getter
@AllArgsConstructor
public class HealthCheckResponse {
    private boolean healthy;
    private List<String> errors;
    private LocalDateTime checkTime;
    
    public static HealthCheckResponse of(boolean healthy, List<String> errors) {
        return new HealthCheckResponse(healthy, errors, LocalDateTime.now());
    }
}
```

---

## 4. Jenkins 배포 파이프라인 통합

### Jenkinsfile 예시

```groovy
pipeline {
    agent any
    
    stages {
        stage('Build') {
            steps {
                sh './gradlew clean build'
            }
        }
        
        stage('Deploy') {
            steps {
                sh '''
                    # 기존 프로세스 종료
                    ./shutdown.sh
                    
                    # 새 버전 배포
                    cp build/libs/app.jar /app/
                    
                    # 애플리케이션 시작
                    ./startup.sh
                '''
            }
        }
        
        stage('Health Check') {
            steps {
                script {
                    def result = sh(
                        script: './deploy_health_check.sh 8080',
                        returnStatus: true
                    )
                    
                    if (result != 0) {
                        error("헬스체크 실패: 배포 중단")
                    }
                }
            }
        }
    }
    
    post {
        failure {
            // 헬스체크 실패 시 롤백
            sh './rollback.sh'
        }
    }
}
```

**핵심:**
- Health Check 단계에서 스크립트 실행
- exit 1 반환 시 배포 중단
- 실패 시 자동 롤백 가능

---

## 5. 사용 방법

### 기본 사용

```bash
# 8080 포트로 기동된 서비스 헬스체크
$ ./deploy_health_check.sh 8080

==========================================
헬스체크 시작: PORT=8080
==========================================
[1/120] 헬스체크 대기 중... (HTTP 000)
[2/120] 헬스체크 대기 중... (HTTP 000)
[3/120] 헬스체크 대기 중... (HTTP 200)
[SUCCESS] 헬스체크 성공 (3초 소요)
[SUCCESS] 배포 완료: 서비스 정상 동작
```

### 실패 케이스

```bash
$ ./deploy_health_check.sh 8080

==========================================
헬스체크 시작: PORT=8080
==========================================
[1/120] 헬스체크 대기 중... (HTTP 000)
[2/120] 헬스체크 대기 중... (HTTP 500)
...
[120/120] 헬스체크 대기 중... (HTTP 500)
[FAILED] 헬스체크 실패: 120초 내 응답 없음
[ERROR] 배포 실패: 서비스가 정상 기동되지 않음
```

---

## 6. 주의사항 및 개선 포인트

### 타임아웃 조정

애플리케이션 특성에 따라 120초는 부족할 수 있다.

**조정이 필요한 경우:**
- 대용량 캐시 로딩
- 배치 데이터 초기화
- 복잡한 외부 연동 초기화

```bash
# 타임아웃 180초로 증가
for ((i=1; i<=180; i++)); do
```

### 헬스체크 엔드포인트 보안

```java
// IP 기반 접근 제어
@GetMapping("/health")
public ResponseEntity<HealthCheckResponse> health(HttpServletRequest request) {
    String remoteAddr = request.getRemoteAddr();
    
    // 로컬호스트만 허용
    if (!"127.0.0.1".equals(remoteAddr) && !"0:0:0:0:0:0:0:1".equals(remoteAddr)) {
        return ResponseEntity.status(HttpStatus.FORBIDDEN).build();
    }
    
    // ...
}
```

### Spring Boot Actuator 활용

Spring Boot Actuator를 사용하면 더 풍부한 헬스체크가 가능하다.

```yaml
# application.yml
management:
  endpoints:
    web:
      exposure:
        include: health
  endpoint:
    health:
      show-details: always
```

```bash
# Actuator 헬스체크
curl http://localhost:8080/actuator/health
```

---

## 7. 설계 과정에서 배운 것

**1. 배포 != 서비스 정상 동작**
- 프로세스가 떠있다고 서비스가 정상인 것은 아님
- 실제 요청 기반 검증 필수

**2. 충분한 대기 시간 제공**
- Spring Boot 기동 시간을 고려
- 너무 짧으면 false negative (정상인데 실패 판정)

**3. 배포 파이프라인에 통합**
- 헬스체크 실패 시 배포 자동 중단
- 롤백 등 후속 조치 가능

**4. 로깅 중요성**
- 몇 초 만에 성공했는지 기록
- 실패 시 어떤 상태였는지 추적

---

## 8. 정리

### 핵심 요약

**구조는 단순:**
```
배포 → 시작 → 헬스체크 → 성공/실패
```

**검증은 확실:**
- HTTP 200 응답 확인
- 최대 120초 대기
- 실패 시 배포 중단

**운영은 안전:**
- 자동화된 검증
- 배포 파이프라인 통합
- 롤백 가능

### 실무에 적용하면서 느낀 점

배포 자동화에서 가장 중요한 것은 **"배포 후 검증"**이었다.

스크립트 하나 추가했을 뿐인데:
- 배포 실패를 즉시 발견
- 장애 시간 대폭 감소
- 배포에 대한 신뢰도 상승

"배포했으니까 정상이겠지"라는 가정을 버리고,
**"배포 후 검증까지가 배포다"**라는 원칙을 세웠다.

---

## Reference

- [Spring Boot Actuator Health Check](https://docs.spring.io/spring-boot/docs/current/reference/html/actuator.html#actuator.endpoints.health)
- [Jenkins Pipeline Syntax](https://www.jenkins.io/doc/book/pipeline/syntax/)

