---
title: "이중화 환경에서 무중단 배포 프로세스 설계 - Maintenance 기반 L4 헬스체크와 Graceful Shutdown"
categories: devops
tags: [deployment, zero-downtime, graceful-shutdown, load-balancer, spring-boot]
excerpt: "L4 헬스체크 제어와 Spring Graceful Shutdown을 결합한 진짜 무중단 배포 프로세스 설계 및 구현"
---

## 들어가며

이중화 환경에서 배포를 진행하면 당연히 무중단일 것이라 생각했다.

하지만 실제로는:
- 배포 시점에 일부 요청이 5xx 에러 발생
- 처리 중인 요청이 강제 종료됨
- "이중화인데 왜?" 라는 의문

**핵심 문제:**
- L4가 서버로 트래픽을 계속 보내는 상태에서 재기동
- 처리 중인 요청을 기다리지 않고 즉시 종료

이 문제를 해결하기 위해 **L4 헬스체크 제어 + Graceful Shutdown**을 결합한 무중단 배포 프로세스를 설계했다.

---

## 1. 무중단 배포의 핵심 조건

### 무중단 배포란?

서비스 전체의 가용성을 유지한 채 서버를 순차적으로 교체/재기동하는 것

### 반드시 만족해야 할 조건

**1. 배포 대상 서버로 신규 요청이 유입되지 않아야 함**
- L4에서 해당 서버를 Down으로 인식
- 모든 신규 트래픽을 다른 서버로 전환

**2. 이미 처리 중인 요청은 안전하게 종료되어야 함**
- 요청 처리 중 강제 종료 방지
- 모든 Thread가 작업 완료 후 종료

### 현재 구조

```
          [L4 / ADC]
         /           \
    [L7-1]         [L7-2]
      |              |
  [app-api]     [app-api]
```

**배포 방식:**
- L7-1 배포 → L7-2 배포 (순차)
- 항상 최소 1대는 트래픽 처리

---

## 2. L4 헬스체크 구조

### 헬스체크 방식

L4(ADC)가 주기적으로 L7 서버의 상태를 확인

**동작:**
- 5초 간격으로 헬스체크 URL 호출
- HTTP 200 → 서버 Up
- HTTP 200 이외 → 서버 Down
- 연속 실패 시 트래픽 차단

### 현재 헬스체크 엔드포인트

```java
@RestController
@RequestMapping("/monitor")
public class MonitorController {
    
    @Value("${health.check.file.path}")
    private String checkFilePath;
    
    @GetMapping("/l7check")
    public ResponseEntity<String> checkL4ToL7() {
        return ResponseEntity.status(getHttpStatus()).build();
    }
    
    private HttpStatus getHttpStatus() {
        return isDeployMode() ? HttpStatus.SERVICE_UNAVAILABLE : HttpStatus.OK;
    }
    
    private boolean isDeployMode() {
        return Files.exists(Path.of(checkFilePath));
    }
}
```

**핵심 로직:**
- `maintenance` 파일 존재 여부로 배포 모드 판단
- 배포 모드 → 503 응답 → L4가 Down으로 인식

### application.yml 설정

```yaml
health:
  check:
    file:
      path: /app/maintenance
```

---

## 3. Maintenance 파일 기반 트래픽 제어

### 설계 원리

**파일 기반 제어의 장점:**
- 서버 재기동 없이 트래픽 제어
- L4 설정 변경 불필요
- 애플리케이션 레벨에서 완전 제어

### 동작 방식

```bash
# 1. maintenance 파일 생성
$ touch /app/maintenance

# 헬스체크 응답: 503 Service Unavailable
# L4가 서버 Down으로 인식
# 신규 트래픽 차단

# 2. 배포 완료 후 파일 제거
$ rm /app/maintenance

# 헬스체크 응답: 200 OK
# L4가 서버 Up으로 인식
# 트래픽 복구
```

### L4 헬스체크 실패 처리 시간

ADC 벤더별 Down 인지 소요 시간:

| ADC 벤더 | Down 인지 시간 |
|---------|--------------|
| A10 | 약 15 ~ 20초 |
| Citrix | 약 7 ~ 12초 |

**중요:**
- maintenance 생성 후 **충분한 대기 시간 필수**
- 너무 짧으면 트래픽이 계속 유입

---

## 4. Graceful Shutdown의 필요성

### 문제 상황

"L4에서 트래픽을 막았으니 이제 안전한가?"

**아니다**

**왜?**
- 서버 내부에는 처리 중인 요청(Thread)이 존재
- 이 상태에서 서버를 종료하면?
- 요청 도중 강제 종료

### 기존 stop.sh의 문제점

```bash
#!/bin/sh

# 기존 종료 스크립트
PID=$(cat /app/app.pid)

# SIGTERM 전송
kill -15 $PID

# 2초 대기
sleep 2

# 최대 4회 확인
for i in {1..4}; do
    if ! ps -p $PID > /dev/null; then
        echo "프로세스 종료됨"
        exit 0
    fi
    sleep 2
done

# 강제 종료
kill -9 $PID
```

**문제:**
- `kill -15` (SIGTERM) 전송 시 Spring은 **즉시 종료**
- 처리 중인 요청을 기다려주지 않음
- 요청 처리 Thread에 `InterruptedException` 발생

### SIGTERM에 대한 흔한 오해

**오해:**
> "kill -15면 스프링이 알아서 다 끝내고 종료하지 않을까?"

**실제:**
- **설정이 없으면 즉시 종료**
- 처리 중인 요청 무시
- 무중단 배포 실패

---

## 5. Spring Boot Graceful Shutdown 적용

### 설정

**application.yml:**

```yaml
server:
  shutdown: graceful  # immediate(기본값) → graceful로 변경

spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s  # 최대 대기 시간
```

### 동작 방식

**1. SIGTERM 수신**
```
kill -15 → Spring이 종료 신호 수신
```

**2. 신규 요청 차단**
```
새로운 요청 → 503 Service Unavailable
```

**3. 기존 요청 처리 대기**
```
처리 중인 Thread들이 작업 완료될 때까지 대기
최대 timeout-per-shutdown-phase 시간까지
```

**4. 안전한 종료**
```
모든 요청 완료 → 애플리케이션 종료
또는 타임아웃 초과 시 강제 종료
```

---

## 6. Graceful Shutdown 동작 검증

### 테스트 Controller

```java
@RestController
@Slf4j
public class TestController {
    
    @GetMapping("/test/long-request")
    public ResponseEntity<String> longRequest() {
        log.info("요청 처리 시작");
        
        try {
            // 60초 동안 처리 중인 요청 시뮬레이션
            Thread.sleep(60000);
            log.info("요청 처리 완료");
            return ResponseEntity.ok("Success");
        } catch (InterruptedException e) {
            log.error("요청 처리 중 인터럽트 발생", e);
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR)
                .body("Interrupted");
        }
    }
}
```

### Case 1: Immediate 모드 (기본값)

**설정:**
```yaml
server:
  shutdown: immediate  # 기본값
```

**테스트:**
```bash
# 1. 요청 전송 (60초 대기)
$ curl http://localhost:8080/test/long-request &

# 2. 서버 종료
$ kill -15 $(cat app.pid)
```

**결과:**
```
[1] 요청 처리 시작
[2초 후] 요청 처리 중 인터럽트 발생: InterruptedException
[2초 후] 서버 종료됨
```

**약 2초 후 즉시 종료, 요청 실패**

### Case 2: Graceful 모드

**설정:**
```yaml
server:
  shutdown: graceful
spring:
  lifecycle:
    timeout-per-shutdown-phase: 30s
```

**테스트:**
```bash
# 동일한 테스트 실행
$ curl http://localhost:8080/test/long-request &
$ kill -15 $(cat app.pid)
```

**결과:**
```
[1] 요청 처리 시작
[30초 대기] ...
[30초 후] 요청 처리 완료: Success
[30초 후] 서버 종료됨
```

**최대 30초 대기, 요청 정상 완료**

### 검증 로그

**Graceful 모드 로그:**
```
2025-01-04 10:15:30.123  INFO --- [http-nio-8080-exec-1] : 요청 처리 시작
2025-01-04 10:15:32.456  INFO --- [main] o.s.b.w.e.tomcat.GracefulShutdown  : Commencing graceful shutdown. Waiting for active requests to complete
2025-01-04 10:16:00.789  INFO --- [http-nio-8080-exec-1] : 요청 처리 완료
2025-01-04 10:16:01.012  INFO --- [main] o.s.b.w.e.tomcat.GracefulShutdown  : Graceful shutdown complete
```

---

## 7. 최종 무중단 배포 프로세스

### 전체 배포 플로우

```
[L7-1 배포]
1. maintenance 생성
2. L4가 Down 인식 대기 (20초)
3. 서버 종료 (Graceful Shutdown)
4. 새 버전 배포
5. 서버 기동
6. 헬스체크 검증
7. maintenance 제거
8. L4가 Up 인식 대기

[L7-2 배포]
9. 동일 프로세스 반복
```

### deploy.sh 스크립트

```bash
#!/bin/sh

SERVICE_NAME="app-api"
SERVICE_PORT=8080
MAINTENANCE_FILE="/app/maintenance"

echo "=========================================="
echo "${SERVICE_NAME} 무중단 배포 시작"
echo "=========================================="

# Step 1: Maintenance 모드 진입
echo "[Step 1] Maintenance 모드 진입"
touch ${MAINTENANCE_FILE}
echo "- maintenance 파일 생성 완료"

# Step 2: L4 헬스체크 실패 대기
echo "[Step 2] L4 트래픽 차단 대기 (20초)"
echo "- L4가 서버 Down 상태로 인식할 때까지 대기"
sleep 20
echo "- 트래픽 차단 완료"

# Step 3: 서버 종료 (Graceful Shutdown)
echo "[Step 3] 서버 종료 (Graceful Shutdown)"
./stop.sh
if [ $? -ne 0 ]; then
    echo "[ERROR] 서버 종료 실패"
    rm ${MAINTENANCE_FILE}
    exit 1
fi
echo "- 서버 정상 종료 완료"

# Step 4: 새 버전 배포
echo "[Step 4] 새 버전 배포"
# WAR 파일 복사, 설정 파일 업데이트 등
cp build/libs/${SERVICE_NAME}.jar /app/
echo "- 배포 완료"

# Step 5: 서버 기동
echo "[Step 5] 서버 기동"
./start.sh
if [ $? -ne 0 ]; then
    echo "[ERROR] 서버 기동 실패"
    exit 1
fi
echo "- 서버 기동 완료"

# Step 6: 헬스체크 검증
echo "[Step 6] 애플리케이션 헬스체크"
./deploy_health_check.sh ${SERVICE_PORT}
if [ $? -ne 0 ]; then
    echo "[ERROR] 헬스체크 실패"
    exit 1
fi
echo "- 헬스체크 정상"

# Step 7: Maintenance 모드 해제
echo "[Step 7] Maintenance 모드 해제"
rm ${MAINTENANCE_FILE}
echo "- maintenance 파일 제거 완료"

# Step 8: L4 헬스체크 성공 대기
echo "[Step 8] L4 트래픽 복구 대기 (10초)"
echo "- L4가 서버 Up 상태로 인식할 때까지 대기"
sleep 10
echo "- 트래픽 복구 완료"

echo "=========================================="
echo "${SERVICE_NAME} 무중단 배포 완료"
echo "=========================================="
exit 0
```

### stop.sh (Graceful Shutdown 지원)

```bash
#!/bin/sh

PID_FILE="/app/app.pid"
SHUTDOWN_TIMEOUT=40  # Graceful Shutdown 타임아웃 + 여유

if [ ! -f ${PID_FILE} ]; then
    echo "[WARN] PID 파일이 없습니다."
    exit 0
fi

PID=$(cat ${PID_FILE})

if ! ps -p ${PID} > /dev/null; then
    echo "[INFO] 프로세스가 이미 종료되었습니다."
    rm ${PID_FILE}
    exit 0
fi

echo "[INFO] 프로세스 종료 시작 (PID: ${PID})"
echo "- Graceful Shutdown 진행 중..."

# SIGTERM 전송
kill -15 ${PID}

# Graceful Shutdown 대기
for ((i=1; i<=${SHUTDOWN_TIMEOUT}; i++)); do
    if ! ps -p ${PID} > /dev/null; then
        echo "[SUCCESS] 프로세스 정상 종료 (${i}초 소요)"
        rm ${PID_FILE}
        exit 0
    fi
    
    if [ $((i % 5)) -eq 0 ]; then
        echo "- 종료 대기 중... (${i}/${SHUTDOWN_TIMEOUT}초)"
    fi
    
    sleep 1
done

# 타임아웃 시 강제 종료
echo "[WARN] Graceful Shutdown 타임아웃, 강제 종료 시도"
kill -9 ${PID}
sleep 2

if ! ps -p ${PID} > /dev/null; then
    echo "[SUCCESS] 프로세스 강제 종료 완료"
    rm ${PID_FILE}
    exit 0
else
    echo "[ERROR] 프로세스 종료 실패"
    exit 1
fi
```

**핵심 변경 사항:**
- 타임아웃을 40초로 증가 (Graceful Shutdown 30초 + 여유 10초)
- 5초마다 대기 상태 로깅
- 타임아웃 초과 시에만 강제 종료

---

## 8. Jenkins 파이프라인 통합

### Jenkinsfile

```groovy
pipeline {
    agent any
    
    parameters {
        choice(name: 'TARGET_SERVER', choices: ['L7-1', 'L7-2', 'ALL'], description: '배포 대상 서버')
    }
    
    stages {
        stage('Build') {
            steps {
                sh './gradlew clean build'
            }
        }
        
        stage('Deploy to L7-1') {
            when {
                expression { params.TARGET_SERVER == 'L7-1' || params.TARGET_SERVER == 'ALL' }
            }
            steps {
                script {
                    deployToServer('L7-1', '192.168.1.10')
                }
            }
        }
        
        stage('Deploy to L7-2') {
            when {
                expression { params.TARGET_SERVER == 'L7-2' || params.TARGET_SERVER == 'ALL' }
            }
            steps {
                script {
                    deployToServer('L7-2', '192.168.1.11')
                }
            }
        }
    }
    
    post {
        success {
            echo "배포 성공"
        }
        failure {
            echo "배포 실패"
            // 알림 전송 등
        }
    }
}

def deployToServer(String serverName, String serverIp) {
    echo "=========================================="
    echo "${serverName} 배포 시작"
    echo "=========================================="
    
    // JAR 파일 전송
    sh "scp build/libs/app-api.jar ${serverIp}:/app/"
    
    // 무중단 배포 스크립트 실행
    def result = sh(
        script: "ssh ${serverIp} '/app/deploy.sh'",
        returnStatus: true
    )
    
    if (result != 0) {
        error("${serverName} 배포 실패")
    }
    
    echo "${serverName} 배포 완료"
}
```

---

## 9. 배포 시나리오별 동작 흐름

### 시나리오 1: 정상 배포

```
[L7-1]
10:00:00 | maintenance 생성
10:00:00 | L4 헬스체크 시작 실패
10:00:20 | L4가 L7-1 Down 인식 → 모든 트래픽 L7-2로
10:00:20 | 서버 종료 시작 (Graceful Shutdown)
10:00:50 | 처리 중이던 요청 모두 완료 → 서버 종료
10:00:55 | 새 버전 배포 및 기동
10:01:30 | 헬스체크 성공
10:01:30 | maintenance 제거
10:01:30 | L4 헬스체크 성공
10:01:40 | L4가 L7-1 Up 인식 → 트래픽 분산 재개

[L7-2]
10:02:00 | L7-1과 동일한 프로세스 반복
```

**결과:**
- 전 과정에서 사용자 요청 실패 0건
- 항상 최소 1대가 서비스 제공

### 시나리오 2: 애플리케이션 기동 실패

```
[L7-1]
10:00:00 ~ 10:00:20 | maintenance 생성 및 대기
10:00:20 ~ 10:00:50 | 서버 종료 (Graceful)
10:00:55 | 서버 기동 시작
10:01:30 | 헬스체크 실패 (DB 연결 오류)

[배포 스크립트]
[ERROR] 헬스체크 실패
exit 1 → 배포 중단

[현재 상태]
- L7-1: Down (maintenance 유지)
- L7-2: Up (정상 서비스)
서비스 가용성 유지
```

**결과:**
- 배포 실패했지만 서비스는 정상
- L7-2가 모든 트래픽 처리
- L7-1 문제 해결 후 재배포

---

## 10. 모니터링 및 검증

### 헬스체크 엔드포인트 확장

```java
@RestController
@RequestMapping("/monitor")
@RequiredArgsConstructor
public class MonitorController {
    
    private final HealthChecker healthChecker;
    
    @Value("${health.check.file.path}")
    private String checkFilePath;
    
    // L4 헬스체크용
    @GetMapping("/l7check")
    public ResponseEntity<String> checkL4ToL7() {
        if (isDeployMode()) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .body("Deploy Mode");
        }
        return ResponseEntity.ok("OK");
    }
    
    // 상세 헬스체크용 (배포 검증)
    @GetMapping("/health")
    public ResponseEntity<HealthCheckResponse> health() {
        if (isDeployMode()) {
            return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE)
                .body(HealthCheckResponse.deployMode());
        }
        
        HealthCheckResponse response = healthChecker.check();
        return ResponseEntity.status(response.isHealthy() ? 
            HttpStatus.OK : HttpStatus.SERVICE_UNAVAILABLE)
            .body(response);
    }
    
    private boolean isDeployMode() {
        return Files.exists(Path.of(checkFilePath));
    }
}
```

### HealthChecker 구현

```java
@Component
@RequiredArgsConstructor
@Slf4j
public class HealthChecker {
    
    private final DataSource dataSource;
    
    public HealthCheckResponse check() {
        List<String> errors = new ArrayList<>();
        
        // DB 연결 체크
        if (!checkDatabase()) {
            errors.add("DB 연결 실패");
        }
        
        // 필요 시 외부 API 체크
        // if (!checkExternalApi()) {
        //     errors.add("외부 API 연결 실패");
        // }
        
        boolean healthy = errors.isEmpty();
        return HealthCheckResponse.of(healthy, errors);
    }
    
    private boolean checkDatabase() {
        try (Connection conn = dataSource.getConnection()) {
            return conn.isValid(1);
        } catch (Exception e) {
            log.error("DB 헬스체크 실패", e);
            return false;
        }
    }
}
```

### HealthCheckResponse

```java
@Getter
@AllArgsConstructor
public class HealthCheckResponse {
    private String status;
    private boolean healthy;
    private List<String> errors;
    private LocalDateTime checkTime;
    
    public static HealthCheckResponse of(boolean healthy, List<String> errors) {
        return new HealthCheckResponse(
            healthy ? "UP" : "DOWN",
            healthy,
            errors,
            LocalDateTime.now()
        );
    }
    
    public static HealthCheckResponse deployMode() {
        return new HealthCheckResponse(
            "MAINTENANCE",
            false,
            List.of("서버가 배포 모드입니다"),
            LocalDateTime.now()
        );
    }
}
```

### 배포 중 상태 확인

```bash
# L4 헬스체크 상태
$ curl http://localhost:8080/monitor/l7check
503 Service Unavailable (배포 모드)

# 상세 헬스체크
$ curl http://localhost:8080/monitor/health
{
  "status": "MAINTENANCE",
  "healthy": false,
  "errors": ["서버가 배포 모드입니다"],
  "checkTime": "2025-01-04T10:00:00"
}
```

---

## 11. 주의사항 및 트러블슈팅

### 1. L4 대기 시간 부족

**증상:**
- 배포 중 일부 요청이 배포 대상 서버로 유입
- 503 에러 발생

**원인:**
- L4가 Down을 인식하기 전에 서버 종료

**해결:**
```bash
# 대기 시간 증가 (15초 → 25초)
sleep 25
```

### 2. Graceful Shutdown 타임아웃 부족

**증상:**
- 장시간 실행되는 배치 작업 중단
- 파일 업로드 중 연결 끊김

**원인:**
- 타임아웃(30초)보다 긴 작업 존재

**해결:**
```yaml
spring:
  lifecycle:
    timeout-per-shutdown-phase: 60s  # 타임아웃 증가
```

### 3. 동시 배포 방지

**문제:**
- L7-1, L7-2 동시 배포 시 전체 서비스 중단

**해결:**
```groovy
// Jenkinsfile에 lock 추가
stage('Deploy to L7-1') {
    steps {
        lock(resource: 'deployment-lock') {
            deployToServer('L7-1', '192.168.1.10')
        }
    }
}
```

### 4. Maintenance 파일 권한

**문제:**
- maintenance 파일 생성/삭제 권한 없음

**해결:**
```bash
# 배포 디렉토리 권한 확인
$ ls -la /app
drwxr-xr-x  deploy  deploy  /app

# 배포 사용자 권한 부여
$ chown -R deploy:deploy /app
```

---

## 12. 성능 영향 분석

### Graceful Shutdown의 오버헤드

**측정 환경:**
- 일반 요청: 평균 100ms
- Graceful Shutdown 설정: 30초

**결과:**
- 처리 중인 요청 없을 때: 즉시 종료 (1~2초)
- 처리 중인 요청 있을 때: 요청 완료 후 종료 (평균 5~10초)
- 타임아웃 대기: 최대 30초

**결론:**
- 성능 오버헤드 없음
- 무중단 배포를 위한 필수 대기 시간

### L4 헬스체크 주기 최적화

**현재:**
- 5초 간격 헬스체크
- 연속 실패 시 Down 처리

**고려사항:**
- 주기 짧음 → 빠른 복구, L4 부하 증가
- 주기 길음 → 느린 복구, L4 부하 감소

**권장:**
- 5초 주기 유지 (일반적인 설정)
- 배포 시 20초 대기 (여유 있게)

---

## 13. 실무 적용 체크리스트

### 배포 전 확인사항

```
□ application.yml에 Graceful Shutdown 설정 완료
□ L4 헬스체크 엔드포인트 정상 동작 확인
□ maintenance 파일 경로 및 권한 확인
□ 배포 스크립트 실행 권한 확인
□ 헬스체크 스크립트 동작 확인
□ Jenkins 파이프라인 설정 완료
□ 배포 순서 정의 (L7-1 → L7-2)
```

### 배포 중 확인사항

```
□ L4에서 대상 서버 Down 상태 확인
□ 다른 서버로 트래픽 전환 확인
□ 서버 종료 로그에서 Graceful Shutdown 확인
□ 헬스체크 성공 확인
□ L4에서 대상 서버 Up 상태 확인
```

### 배포 후 확인사항

```
□ 모든 서버 정상 기동 확인
□ L4 트래픽 분산 확인
□ 애플리케이션 로그 에러 확인
□ 모니터링 지표 정상 확인
□ 사용자 요청 성공률 확인
```

---

## 14. 결론

### 무중단 배포의 핵심

무중단 배포는 단일 기술로 해결되지 않는다.

**반드시 함께 가야 할 3가지:**

**1. L4 헬스체크 제어**
- Maintenance 파일 기반
- 신규 트래픽 차단

**2. Graceful Shutdown**
- 처리 중인 요청 보호
- 안전한 종료

**3. 체계적인 배포 프로세스**
- 충분한 대기 시간
- 헬스체크 검증
- 순차적 배포

### 트래픽 차단 + 안전한 종료 = 진짜 무중단 배포

```
이중화 환경이라고 무중단이 자동으로 되는 것이 아니다.
L4부터 애플리케이션까지 모든 레이어를 고려해야 한다.
```

---

## 15. 설계 과정에서 배운 것

**1. "이중화 = 무중단"이 아니다**
- 이중화는 조건이지 결과가 아님
- 올바른 배포 프로세스가 반드시 필요

**2. L4와 애플리케이션의 협력**
- L4 헬스체크만으로는 부족
- 애플리케이션의 Graceful Shutdown 필수

**3. 충분한 대기 시간의 중요성**
- 너무 짧으면 트래픽 차단 실패
- 너무 길면 배포 시간 증가
- 벤더별 특성 이해 필요

**4. 검증의 중요성**
- 배포 후 헬스체크 필수
- 실패 시 자동 중단 메커니즘 필요

**5. 모니터링과 로깅**
- 각 단계별 상태 로깅
- 문제 발생 시 추적 가능

---

## Reference

- [Spring Boot Graceful Shutdown](https://docs.spring.io/spring-boot/docs/current/reference/html/web.html#web.graceful-shutdown)
- [Spring Boot Lifecycle](https://docs.spring.io/spring-boot/docs/current/reference/html/features.html#features.spring-application.application-events-and-listeners)
- [A10 Networks Health Check](https://www.a10networks.com/products/thunder-adc/)

