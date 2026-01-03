---
title: "Linux systemd 서비스 등록: 부팅 시 자동 실행 적용하기"
categories: linux
tags: [linux, systemd, service, devops, automation, aws]
excerpt: "AWS 비용 절감을 위한 서버 재시작 시마다 수동으로 서비스를 구동하는 번거로움을 systemd 서비스 등록으로 해결하는 실전 가이드"
---

## 들어가며

### 문제 상황

AWS 환경에서 서비스를 운영하던 중, **비용 절감 방안**으로 개발 서버의 야간 중지 정책을 시행하게 되었다.

**운영 프로세스:**
```
퇴근 전: 서버 중지 (Stop Instance)
출근 후: 서버 기동 (Start Instance)
```

하지만 문제가 있었다.

**매번 반복되는 작업:**
```bash
# 서버 기동 후 매번 수동으로 실행
$ /app/tomcat/bin/startup.sh
$ /app/nginx/sbin/nginx
$ /app/application/start.sh
...
```

처음에는 이런 쉘 스크립트를 만들어 사용했다:

```bash
#!/bin/bash
# start_all.sh

echo "Tomcat 시작..."
/app/tomcat/bin/startup.sh

echo "Nginx 시작..."
/app/nginx/sbin/nginx

echo "Application 시작..."
/app/application/start.sh
```

하지만 **매번 SSH 접속해서 스크립트를 실행하는 것조차 번거로웠다**.

그때 Windows의 "시작프로그램"이 떠올랐다.

Linux에도 분명 부팅 시 자동으로 실행되는 메커니즘이 있을 것이다.

바로 **systemd 서비스**다.

---

## systemd란?

### 개요

**systemd**는 Linux 시스템의 초기화 및 서비스 관리를 담당하는 시스템 데몬이다.

### 주요 기능

**1. 서비스 관리**
- 서비스 시작/중지/재시작
- 서비스 상태 확인
- 부팅 시 자동 시작

**2. 병렬 실행**
- 여러 서비스를 동시에 시작
- 빠른 부팅 시간

**3. 의존성 관리**
- 서비스 간 의존 관계 정의
- 순서 보장

**4. 로그 관리**
- journalctl을 통한 통합 로그
- 서비스별 로그 추적

### systemd vs init.d

| 구분 | init.d (구형) | systemd (현대) |
|------|--------------|----------------|
| **설정 파일** | Shell Script | Unit File (INI 형식) |
| **실행 순서** | 순차적 | 병렬 |
| **의존성** | 수동 관리 | 자동 관리 |
| **로그** | 개별 로그 파일 | 통합 journalctl |
| **속도** | 느림 | 빠름 |

---

## systemd 서비스 등록 실전

### 환경 정보

- **OS**: CentOS 7+ / Ubuntu 16.04+
- **대상 서비스**: Tomcat, Nginx, 사용자 애플리케이션
- **사용자**: 일반 사용자 (sudo 권한 필요)

### 1단계: 서비스 파일 위치 확인

systemd 서비스 파일은 다음 디렉토리에 위치한다:

```bash
# 시스템 전역 서비스 (관리자 권한 필요)
/usr/lib/systemd/system/          # CentOS/RHEL
/lib/systemd/system/               # Ubuntu/Debian

# 사용자 정의 서비스 (권장)
/etc/systemd/system/

# 사용자별 서비스 (sudo 불필요)
~/.config/systemd/user/
```

**권장 위치:**
```bash
/etc/systemd/system/
```

이유: 시스템 업그레이드 시에도 유지되며, 관리가 용이함

### 2단계: Tomcat 서비스 파일 작성

**서비스 파일 생성:**

```bash
# 서비스 디렉토리로 이동
cd /etc/systemd/system

# 서비스 파일 생성
sudo vi tomcat.service
```

**기본 설정:**

```ini
[Unit]
Description=Apache Tomcat Web Application Container
After=syslog.target network.target

[Service]
Type=forking
User=svcuser
Group=svcuser
Environment="JAVA_HOME=/usr/lib/jvm/java-11-openjdk"
Environment="CATALINA_HOME=/home/svcuser/apps/tomcat"
Environment="CATALINA_BASE=/home/svcuser/apps/tomcat"
ExecStart=/home/svcuser/apps/tomcat/bin/startup.sh
ExecStop=/home/svcuser/apps/tomcat/bin/shutdown.sh
WorkingDirectory=/home/svcuser/apps/tomcat

[Install]
WantedBy=multi-user.target
```

### Unit 파일 구조 상세 설명

#### [Unit] 섹션

서비스의 기본 정보와 의존성을 정의한다.

**Description**
```ini
Description=Apache Tomcat Web Application Container
```
서비스에 대한 간단한 설명 (systemctl status에서 표시)

**After**
```ini
After=syslog.target network.target
```
- 이 서비스가 시작되기 **전에 완료되어야 할 서비스** 목록
- `network.target`: 네트워크가 준비된 후 시작
- `syslog.target`: 로깅 시스템이 준비된 후 시작

**Before**
```ini
Before=nginx.service
```
이 서비스가 완료된 **후에 시작될 서비스** (선택 사항)

**Requires / Wants**
```ini
Requires=network.target
Wants=postgresql.service
```
- `Requires`: 필수 의존성 (실패 시 이 서비스도 실패)
- `Wants`: 권장 의존성 (실패해도 이 서비스는 시작)

#### [Service] 섹션

서비스의 실행 방식을 정의한다.

**Type**

서비스의 시작 방식을 정의한다.

```ini
Type=forking
```

**주요 Type 설명:**

| Type | 설명 | 사용 사례 |
|------|------|----------|
| **simple** | ExecStart 프로세스가 메인 프로세스 (기본값) | 단순한 포그라운드 애플리케이션 |
| **forking** | ExecStart가 자식 프로세스를 생성하고 종료 | Tomcat, Nginx (데몬 방식) |
| **oneshot** | 한 번 실행하고 종료 | 초기화 스크립트 |
| **notify** | 서비스가 준비 완료를 systemd에 알림 | 현대적인 애플리케이션 |
| **idle** | 다른 작업이 없을 때 실행 | 부하를 주지 않는 백그라운드 작업 |

**Tomcat은 왜 forking?**
- `startup.sh`는 Tomcat 프로세스를 백그라운드로 실행하고 종료됨
- 실제 메인 프로세스는 자식 프로세스로 남음

**User / Group**
```ini
User=svcuser
Group=svcuser
```
서비스를 실행할 사용자 및 그룹 (보안상 root 사용 지양)

**Environment**
```ini
Environment="JAVA_HOME=/usr/lib/jvm/java-11-openjdk"
Environment="CATALINA_HOME=/home/svcuser/apps/tomcat"
```
환경 변수 설정 (여러 개 가능)

**환경 변수 파일 사용:**
```ini
EnvironmentFile=/home/svcuser/apps/tomcat/conf/tomcat.env
```

**tomcat.env 파일 예시:**
```bash
JAVA_HOME=/usr/lib/jvm/java-11-openjdk
CATALINA_HOME=/home/svcuser/apps/tomcat
CATALINA_OPTS="-Xms512m -Xmx2048m"
```

**ExecStart / ExecStop**
```ini
ExecStart=/home/svcuser/apps/tomcat/bin/startup.sh
ExecStop=/home/svcuser/apps/tomcat/bin/shutdown.sh
```
- `ExecStart`: 서비스 시작 명령어 (절대 경로 사용)
- `ExecStop`: 서비스 중지 명령어

**ExecStartPre / ExecStartPost**
```ini
ExecStartPre=/usr/bin/sleep 5
ExecStartPost=/usr/bin/curl http://localhost:8080/health
```
- `ExecStartPre`: 시작 전 실행할 명령어
- `ExecStartPost`: 시작 후 실행할 명령어

**WorkingDirectory**
```ini
WorkingDirectory=/home/svcuser/apps/tomcat
```
명령어 실행 시 작업 디렉토리

**Restart**
```ini
Restart=on-failure
RestartSec=10
```
- `no`: 재시작 안 함 (기본값)
- `on-failure`: 비정상 종료 시만 재시작
- `on-abnormal`: 비정상 종료 + 시그널 종료 시 재시작
- `on-abort`: 시그널로 종료 시 재시작
- `always`: 항상 재시작

**Timeout**
```ini
TimeoutStartSec=90
TimeoutStopSec=30
```
- `TimeoutStartSec`: 시작 타임아웃 (기본 90초)
- `TimeoutStopSec`: 중지 타임아웃 (기본 90초)

**PID 파일**
```ini
PIDFile=/home/svcuser/apps/tomcat/tomcat.pid
```
프로세스 ID 파일 위치 (forking Type에서 권장)

#### [Install] 섹션

서비스 활성화 시 동작을 정의한다.

**WantedBy**
```ini
WantedBy=multi-user.target
```

**주요 Target 설명:**

| Target | 설명 | 런레벨 |
|--------|------|--------|
| **multi-user.target** | 다중 사용자 모드 (일반적인 서버) | 3 |
| **graphical.target** | 그래픽 환경 | 5 |
| **network.target** | 네트워크 활성화 | - |

대부분의 서버 서비스는 `multi-user.target` 사용

### 3단계: 개선된 Tomcat 서비스 파일

기본 설정에 안정성과 모니터링을 강화한 버전:

```ini
[Unit]
Description=Apache Tomcat Web Application Container
Documentation=https://tomcat.apache.org/
After=syslog.target network.target

[Service]
Type=forking

# 사용자 설정
User=svcuser
Group=svcuser

# 환경 변수
Environment="JAVA_HOME=/usr/lib/jvm/java-11-openjdk"
Environment="CATALINA_HOME=/home/svcuser/apps/tomcat"
Environment="CATALINA_BASE=/home/svcuser/apps/tomcat"
Environment="CATALINA_PID=/home/svcuser/apps/tomcat/tomcat.pid"
Environment="CATALINA_OPTS=-Xms512m -Xmx2048m -XX:+UseG1GC"

# 실행 명령
ExecStartPre=/bin/sleep 3
ExecStart=/home/svcuser/apps/tomcat/bin/startup.sh
ExecStop=/home/svcuser/apps/tomcat/bin/shutdown.sh

# PID 파일
PIDFile=/home/svcuser/apps/tomcat/tomcat.pid

# 작업 디렉토리
WorkingDirectory=/home/svcuser/apps/tomcat

# 재시작 정책
Restart=on-failure
RestartSec=10

# 타임아웃
TimeoutStartSec=120
TimeoutStopSec=60

# 표준 출력/에러 로그
StandardOutput=journal
StandardError=journal
SyslogIdentifier=tomcat

[Install]
WantedBy=multi-user.target
```

**개선 사항:**

1. **Documentation**: 문서 URL 추가
2. **CATALINA_PID**: PID 파일 명시
3. **CATALINA_OPTS**: JVM 옵션 설정
4. **ExecStartPre**: 시작 전 3초 대기 (의존 서비스 안정화)
5. **Restart**: 실패 시 자동 재시작
6. **RestartSec**: 재시작 전 10초 대기
7. **Timeout**: 시작/중지 타임아웃 증가
8. **StandardOutput/Error**: journalctl 로그 연동
9. **SyslogIdentifier**: 로그 식별자 지정

### 4단계: Nginx 서비스 파일 예시

```bash
sudo vi /etc/systemd/system/nginx.service
```

```ini
[Unit]
Description=Nginx HTTP Server
After=network.target

[Service]
Type=forking
User=svcuser
Group=svcuser
PIDFile=/home/svcuser/apps/nginx/logs/nginx.pid
ExecStartPre=/home/svcuser/apps/nginx/sbin/nginx -t
ExecStart=/home/svcuser/apps/nginx/sbin/nginx
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
PrivateTmp=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

**특징:**
- **ExecStartPre**: 시작 전 설정 파일 검증 (`nginx -t`)
- **ExecReload**: reload 명령어 (HUP 시그널)
- **PrivateTmp**: 임시 디렉토리 격리 (보안)
- **$MAINPID**: systemd가 자동으로 PID 주입

### 5단계: Spring Boot 애플리케이션 서비스

```bash
sudo vi /etc/systemd/system/myapp.service
```

```ini
[Unit]
Description=My Spring Boot Application
After=syslog.target network.target

[Service]
Type=simple
User=svcuser
Group=svcuser
WorkingDirectory=/home/svcuser/apps/myapp
ExecStart=/usr/bin/java -jar \
    -Xms512m -Xmx1024m \
    -Dspring.profiles.active=prod \
    /home/svcuser/apps/myapp/application.jar
SuccessExitStatus=143
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=myapp

[Install]
WantedBy=multi-user.target
```

**특징:**
- **Type=simple**: 포그라운드 실행
- **SuccessExitStatus=143**: SIGTERM(143) 정상 종료로 간주
- **Restart=always**: 항상 재시작

### 6단계: 서비스 등록 및 활성화

**서비스 파일 권한 설정:**

```bash
# 권한 확인 (644 권장)
sudo chmod 644 /etc/systemd/system/tomcat.service

# 소유자 확인 (root 권장)
sudo chown root:root /etc/systemd/system/tomcat.service
```

**systemd 데몬 리로드:**

```bash
# 설정 파일 변경 후 반드시 실행
sudo systemctl daemon-reload
```

**서비스 활성화 (부팅 시 자동 시작):**

```bash
# 서비스 등록
sudo systemctl enable tomcat.service

# 출력 예시:
# Created symlink from /etc/systemd/system/multi-user.target.wants/tomcat.service 
# to /etc/systemd/system/tomcat.service
```

**서비스 시작:**

```bash
# 서비스 시작
sudo systemctl start tomcat.service
```

**서비스 상태 확인:**

```bash
sudo systemctl status tomcat.service
```

**출력 예시:**

```
● tomcat.service - Apache Tomcat Web Application Container
   Loaded: loaded (/etc/systemd/system/tomcat.service; enabled; vendor preset: disabled)
   Active: active (running) since Wed 2025-01-08 09:30:15 KST; 2min ago
  Process: 12345 ExecStart=/home/svcuser/apps/tomcat/bin/startup.sh (code=exited, status=0/SUCCESS)
 Main PID: 12350 (java)
    Tasks: 45 (limit: 4915)
   Memory: 512.5M
   CGroup: /system.slice/tomcat.service
           └─12350 /usr/bin/java -Djava.util.logging.config.file=...

 1월 08 09:30:15 server systemd[1]: Starting Apache Tomcat Web Application Container...
 1월 08 09:30:15 server systemd[1]: Started Apache Tomcat Web Application Container.
```

**상태 의미:**

| 상태 | 의미 |
|------|------|
| **Loaded** | 서비스 파일 로드 상태 |
| **Active: active (running)** | 정상 실행 중 |
| **Active: inactive (dead)** | 중지됨 |
| **Active: failed** | 실행 실패 |
| **enabled** | 부팅 시 자동 시작 활성화 |
| **disabled** | 부팅 시 자동 시작 비활성화 |

---

## 서비스 관리 명령어

### 기본 명령어

**서비스 시작:**
```bash
sudo systemctl start tomcat.service
```

**서비스 중지:**
```bash
sudo systemctl stop tomcat.service
```

**서비스 재시작:**
```bash
sudo systemctl restart tomcat.service
```

**서비스 리로드 (설정 반영):**
```bash
sudo systemctl reload tomcat.service
```

**서비스 상태 확인:**
```bash
sudo systemctl status tomcat.service
```

**서비스 활성화 (부팅 시 자동 시작):**
```bash
sudo systemctl enable tomcat.service
```

**서비스 비활성화:**
```bash
sudo systemctl disable tomcat.service
```

**서비스 활성화 여부 확인:**
```bash
systemctl is-enabled tomcat.service
```

**서비스 실행 여부 확인:**
```bash
systemctl is-active tomcat.service
```

### 고급 명령어

**모든 서비스 목록:**
```bash
systemctl list-units --type=service
```

**활성화된 서비스만:**
```bash
systemctl list-unit-files --type=service --state=enabled
```

**실패한 서비스:**
```bash
systemctl --failed
```

**서비스 의존성 확인:**
```bash
systemctl list-dependencies tomcat.service
```

**서비스 설정 파일 위치:**
```bash
systemctl show tomcat.service | grep FragmentPath
```

---

## 로그 확인

### journalctl 사용법

**서비스 로그 실시간 보기:**
```bash
sudo journalctl -u tomcat.service -f
```

**최근 로그 50줄:**
```bash
sudo journalctl -u tomcat.service -n 50
```

**특정 시간 이후 로그:**
```bash
sudo journalctl -u tomcat.service --since "2025-01-08 09:00:00"
```

**특정 시간 범위:**
```bash
sudo journalctl -u tomcat.service --since "09:00" --until "10:00"
```

**오늘 로그:**
```bash
sudo journalctl -u tomcat.service --since today
```

**어제 로그:**
```bash
sudo journalctl -u tomcat.service --since yesterday --until today
```

**우선순위별 필터:**
```bash
# 에러만
sudo journalctl -u tomcat.service -p err

# 경고 이상
sudo journalctl -u tomcat.service -p warning
```

**로그 삭제 (디스크 정리):**
```bash
# 7일 이상 된 로그 삭제
sudo journalctl --vacuum-time=7d

# 1GB 이하로 유지
sudo journalctl --vacuum-size=1G
```

---

## 트러블슈팅

### 문제 1: 서비스 시작 실패

**증상:**
```bash
$ sudo systemctl status tomcat.service
● tomcat.service - Apache Tomcat Web Application Container
   Loaded: loaded (/etc/systemd/system/tomcat.service; enabled)
   Active: failed (Result: exit-code)
```

**원인 및 해결:**

**1. 로그 확인:**
```bash
sudo journalctl -u tomcat.service -n 100 --no-pager
```

**2. 설정 파일 검증:**
```bash
# systemd 설정 검증
sudo systemd-analyze verify /etc/systemd/system/tomcat.service

# Tomcat 설정 검증
/home/svcuser/apps/tomcat/bin/catalina.sh configtest
```

**3. 권한 확인:**
```bash
# 실행 파일 권한
ls -l /home/svcuser/apps/tomcat/bin/startup.sh

# 실행 권한 부여
chmod +x /home/svcuser/apps/tomcat/bin/startup.sh
```

**4. 환경 변수 확인:**
```bash
# JAVA_HOME 확인
echo $JAVA_HOME
ls -l $JAVA_HOME/bin/java
```

### 문제 2: PID 파일 관련 오류

**증상:**
```
Failed to start tomcat.service: PID file not readable
```

**해결:**

```ini
# PID 파일 경로 확인 및 수정
[Service]
PIDFile=/home/svcuser/apps/tomcat/tomcat.pid

# startup.sh에서 PID 파일 생성 확인
# CATALINA_PID 환경 변수 설정
Environment="CATALINA_PID=/home/svcuser/apps/tomcat/tomcat.pid"
```

### 문제 3: 서비스는 시작되지만 포트가 열리지 않음

**증상:**
```bash
$ sudo systemctl status tomcat.service
Active: active (running)

$ curl http://localhost:8080
curl: (7) Failed to connect to localhost port 8080
```

**원인 및 해결:**

**1. 프로세스 확인:**
```bash
ps aux | grep tomcat
```

**2. 포트 확인:**
```bash
sudo netstat -nltp | grep 8080
sudo ss -nltp | grep 8080
```

**3. 로그 확인:**
```bash
tail -f /home/svcuser/apps/tomcat/logs/catalina.out
```

**4. 타임아웃 증가:**
```ini
[Service]
TimeoutStartSec=300  # 5분으로 증가
```

### 문제 4: 부팅 시 자동 시작 안 됨

**증상:**
서버 재부팅 후 서비스가 시작되지 않음

**해결:**

**1. 활성화 확인:**
```bash
systemctl is-enabled tomcat.service

# disabled라면 활성화
sudo systemctl enable tomcat.service
```

**2. 심볼릭 링크 확인:**
```bash
ls -l /etc/systemd/system/multi-user.target.wants/tomcat.service
```

**3. 의존성 확인:**
```bash
# network.target 이후 시작되도록 설정
[Unit]
After=network.target network-online.target
Wants=network-online.target
```

### 문제 5: 서비스 중지가 느림

**증상:**
```bash
$ sudo systemctl stop tomcat.service
(30초 이상 대기...)
```

**원인:**
Tomcat이 정상 종료되지 않아 TimeoutStopSec 후 강제 종료됨

**해결:**

**1. 타임아웃 증가:**
```ini
[Service]
TimeoutStopSec=60
```

**2. shutdown.sh 확인:**
```bash
# shutdown.sh가 정상 동작하는지 확인
/home/svcuser/apps/tomcat/bin/shutdown.sh
```

**3. 강제 종료 추가:**
```ini
[Service]
ExecStop=/home/svcuser/apps/tomcat/bin/shutdown.sh
KillMode=mixed
KillSignal=SIGTERM
```

---

## 실전 활용 시나리오

### 시나리오 1: 여러 서비스 순차 시작

Tomcat → Nginx 순서로 시작:

**tomcat.service:**
```ini
[Unit]
Description=Apache Tomcat
After=network.target

[Service]
Type=forking
ExecStart=/home/svcuser/apps/tomcat/bin/startup.sh
...

[Install]
WantedBy=multi-user.target
```

**nginx.service:**
```ini
[Unit]
Description=Nginx
After=network.target tomcat.service
Requires=tomcat.service

[Service]
Type=forking
ExecStart=/home/svcuser/apps/nginx/sbin/nginx
...

[Install]
WantedBy=multi-user.target
```

**의존성:**
- `After=tomcat.service`: Tomcat 시작 후 Nginx 시작
- `Requires=tomcat.service`: Tomcat 실패 시 Nginx도 시작 안 함

### 시나리오 2: 헬스 체크 추가

```ini
[Unit]
Description=My Application
After=network.target

[Service]
Type=simple
ExecStart=/home/svcuser/apps/myapp/start.sh
ExecStartPost=/bin/bash -c 'for i in {1..30}; do curl -f http://localhost:8080/health && break || sleep 1; done'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

**설명:**
- `ExecStartPost`: 시작 후 30초 동안 health check
- health check 성공 시 서비스 정상 완료
- 실패 시 Restart 정책에 따라 재시작

### 시나리오 3: 환경별 서비스 분리

```bash
# 개발 환경
/etc/systemd/system/myapp-dev.service

# 운영 환경
/etc/systemd/system/myapp-prod.service
```

**myapp-prod.service:**
```ini
[Unit]
Description=My App (Production)

[Service]
Type=simple
EnvironmentFile=/home/svcuser/apps/myapp/prod.env
ExecStart=/usr/bin/java -jar /home/svcuser/apps/myapp/app.jar

[Install]
WantedBy=multi-user.target
```

**prod.env:**
```bash
SPRING_PROFILES_ACTIVE=prod
SERVER_PORT=8080
DATABASE_URL=jdbc:postgresql://prod-db:5432/myapp
```

---

## 자동화 스크립트

### 서비스 파일 생성 스크립트

**create-service.sh:**

```bash
#!/bin/bash

# 사용법: ./create-service.sh tomcat /home/svcuser/apps/tomcat svcuser

SERVICE_NAME=$1
APP_HOME=$2
USER=$3

if [ -z "$SERVICE_NAME" ] || [ -z "$APP_HOME" ] || [ -z "$USER" ]; then
    echo "사용법: $0 <서비스명> <앱경로> <사용자>"
    echo "예시: $0 tomcat /home/svcuser/apps/tomcat svcuser"
    exit 1
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo "서비스 파일 생성 중: $SERVICE_FILE"

sudo tee $SERVICE_FILE > /dev/null <<EOF
[Unit]
Description=${SERVICE_NAME} Service
After=syslog.target network.target

[Service]
Type=forking
User=${USER}
Group=${USER}
ExecStart=${APP_HOME}/bin/startup.sh
ExecStop=${APP_HOME}/bin/shutdown.sh
WorkingDirectory=${APP_HOME}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "서비스 파일 생성 완료"
echo ""

# 권한 설정
sudo chmod 644 $SERVICE_FILE
sudo chown root:root $SERVICE_FILE

# systemd 리로드
echo "systemd 리로드 중..."
sudo systemctl daemon-reload

# 서비스 활성화
echo "서비스 활성화 중..."
sudo systemctl enable ${SERVICE_NAME}.service

echo ""
echo "========================================="
echo "서비스 등록 완료!"
echo "========================================="
echo "시작: sudo systemctl start ${SERVICE_NAME}.service"
echo "상태: sudo systemctl status ${SERVICE_NAME}.service"
echo "로그: sudo journalctl -u ${SERVICE_NAME}.service -f"
```

**사용 예시:**

```bash
chmod +x create-service.sh
./create-service.sh tomcat /home/svcuser/apps/tomcat svcuser
```

---

## 정리

### 핵심 요약

1. **systemd 서비스 등록으로 자동 시작**
   - 매번 수동 실행 불필요
   - 서버 재부팅 후 자동 기동

2. **서비스 파일 작성 위치**
   - `/etc/systemd/system/` 권장
   - Unit 파일 형식 (INI)

3. **필수 섹션**
   - `[Unit]`: 설명 및 의존성
   - `[Service]`: 실행 방식 및 명령어
   - `[Install]`: 활성화 타겟

4. **Type 선택**
   - `simple`: 포그라운드 실행
   - `forking`: 데몬 방식 (Tomcat, Nginx)

5. **로그 관리**
   - journalctl로 통합 관리
   - 실시간 모니터링 가능

### 체크리스트

서비스 등록 시 확인 사항:

- [ ] 서비스 파일 작성 (`/etc/systemd/system/`)
- [ ] 절대 경로 사용 (ExecStart, ExecStop)
- [ ] User/Group 설정 (보안)
- [ ] 환경 변수 설정 (JAVA_HOME 등)
- [ ] Type 올바르게 선택
- [ ] After 의존성 설정
- [ ] Restart 정책 설정
- [ ] Timeout 설정 (충분히)
- [ ] PID 파일 설정 (forking)
- [ ] daemon-reload 실행
- [ ] enable로 활성화
- [ ] start로 시작
- [ ] status로 확인
- [ ] 재부팅 테스트

### AWS 비용 절감 효과

**Before:**
```
1. 서버 시작
2. SSH 접속
3. Tomcat 시작 스크립트 실행
4. Nginx 시작 스크립트 실행
5. 애플리케이션 시작 스크립트 실행
(매일 반복...)
```

**After:**
```
1. 서버 시작
(끝!)
```

**추가 이점:**
- 휴먼 에러 제거 (시작 깜빡함)
- 시간 절약 (하루 5분 × 20일 = 100분/월)
- 서비스 안정성 향상 (자동 재시작)

### 마지막으로

systemd 서비스 등록은 **한 번 설정하면 평생 편하다**.

AWS 비용 절감을 위해 서버를 껐다 켰다 하는 환경에서는 **필수**이며, 운영 환경에서도 서비스 관리를 체계적으로 할 수 있다.

**오늘 설정하면 내일부터 자동이다.**

---
