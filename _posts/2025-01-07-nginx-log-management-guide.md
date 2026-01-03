---
title: "Nginx 로그 관리 및 정책 수립: logrotate 로컬 방식으로 구성하기"
categories: nginx
tags: [nginx, logrotate, log-management, linux, devops, troubleshooting]
excerpt: "운영 환경에서 무한 증가하는 Nginx 로그 파일을 logrotate로 자동 관리하고, 디스크 용량 문제를 예방하는 실전 가이드"
---

## 들어가며

### 문제 상황

신규 시스템을 구축 후 운영 단계로 넘어온 지 얼마 되지 않았을 때, 로그를 확인하려고 `vi access.log`를 실행했는데 **한참을 기다려도 열리지 않았다**.

처음에는 서버 성능 문제인가 싶었지만, 원인은 간단했다.

```bash
$ ls -lh access.log
-rw-r--r-- 1 nginx nginx 47G  1월  2 14:30 access.log
```

**47GB의 단일 로그 파일.**

하나의 `access.log` 파일에 계속해서 append만 하고 있었던 것이 문제였다.

이 글에서는 Nginx 로그 파일을 `logrotate` 유틸리티를 활용하여 자동으로 관리하고, 디스크 용량 문제를 예방하는 방법을 정리한다.

---

## 로그 관리가 필요한 이유

### 방치했을 때의 문제점

**1. 디스크 용량 고갈**
```bash
$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       100G   95G   5G  95% /
```

로그로 인해 디스크가 가득 차면:
- 새로운 로그 기록 불가
- 애플리케이션 장애 발생
- 파일 시스템 손상 위험

**2. 로그 분석 불가**

```bash
# 파일이 너무 커서 열 수 없음
$ vi access.log
E342: Out of memory
```

일반적인 텍스트 편집기로는 수 GB 파일을 열 수 없다.

**3. 성능 저하**

```bash
# grep 명령어도 느림
$ grep "ERROR" access.log
(수십 분 소요...)
```

파일이 클수록 검색 속도가 느려진다.

**4. 백업 및 전송 어려움**

수십 GB 파일을 백업하거나 다른 서버로 전송하는 것은 비현실적이다.

---

## logrotate란?

### 개요

**logrotate**는 Linux/Unix 시스템에 기본 탑재된 로그 관리 도구다.

### 주요 기능

**1. 로그 파일 회전(Rotation)**
```
access.log            → access.log.1
access.log (새로생성)
```

**2. 압축**
```
access.log.1 → access.log.1.gz (용량 90% 감소)
```

**3. 자동 삭제**
```
오래된 로그 자동 삭제 (예: 7일 이상)
```

**4. 권한 관리**
```
신규 로그 파일의 소유자 및 권한 자동 설정
```

### 동작 원리

```
1. 기존 로그 파일 rename
   access.log → access.log.20250102
   
2. 새 로그 파일 생성
   access.log (빈 파일)
   
3. Nginx에 시그널 전송
   kill -USR1 <nginx_pid>
   → Nginx가 새 로그 파일에 쓰기 시작
   
4. 이전 로그 압축 (선택)
   access.log.20250102 → access.log.20250102.gz
   
5. 오래된 로그 삭제
   7일 이전 로그 자동 삭제
```

---

## 로그 관리 정책 수립

### 대상 로그

**Nginx 기본 로그:**
- `access.log` - 모든 HTTP 요청 기록
- `error.log` - 오류 및 경고 메시지

**로그 위치:**
```bash
/home/svcuser/logs/nginx/nginx-1.24.0/access.log
/home/svcuser/logs/nginx/nginx-1.24.0/error.log
```

### 보관 정책

| 항목 | 설정값 | 이유 |
|------|--------|------|
| **회전 주기** | 일(Daily) | 하루 단위로 파일 분리 |
| **보관 기간** | 7일 | 일주일간 로그 추적 가능 |
| **압축** | 활성화 | 디스크 용량 90% 절감 |
| **날짜 형식** | YYYYMMDD | 직관적인 파일명 |
| **최소 파일 크기** | 제한 없음 | 모든 로그 회전 |

### 용량 예측

**회전 전:**
```
access.log: 47GB (누적)
```

**회전 후 (압축 적용):**
```
access.log.20250102.gz: 500MB
access.log.20250101.gz: 480MB
...
총 7개 파일: 약 3.5GB
```

**용량 절감:**
```
47GB → 3.5GB (92% 감소)
```

---

## 구성 가이드

### 환경 정보

- **계정:** `svcuser`
- **권한:** 일반 사용자 (sudo 권한 없음)
- **Nginx 경로:** `/home/svcuser/apps/nginx`
- **로그 경로:** `/home/svcuser/logs/nginx/nginx-1.24.0`

**제약 사항:**
- `/etc/logrotate.d` 디렉토리 접근 불가
- 시스템 전역 설정 불가
- **로컬 방식 (사용자 디렉토리에서 실행) 적용**

### 1단계: 디렉토리 구조 생성

```bash
# 로그 관리 디렉토리 생성
mkdir -p /home/svcuser/apps/nginx/conf/log

# 디렉토리 구조 확인
tree /home/svcuser/apps/nginx/conf
```

**결과:**
```
/home/svcuser/apps/nginx/conf/
└── log/
    ├── logrotate-nginx.conf  (설정 파일)
    └── logrotate.status      (상태 파일)
```

### 2단계: logrotate 상태 파일 생성

```bash
# 빈 파일 생성
touch /home/svcuser/apps/nginx/conf/log/logrotate.status

# 권한 확인
ls -l /home/svcuser/apps/nginx/conf/log/logrotate.status
```

**상태 파일의 역할:**
- 마지막 회전 시간 기록
- 중복 실행 방지
- 회전 이력 추적

### 3단계: logrotate 설정 파일 작성

```bash
vi /home/svcuser/apps/nginx/conf/log/logrotate-nginx.conf
```

**기본 설정:**

```conf
/home/svcuser/logs/nginx/nginx-1.24.0/*.log {
    daily                       # 매일 로그 회전
    rotate 7                    # 최근 7개 로그 보관
    missingok                   # 로그 파일이 없어도 에러 발생 안 함
    notifempty                  # 빈 파일은 회전하지 않음
    compress                    # 회전된 로그 압축
    delaycompress               # 최신 로그는 다음 회전 때 압축
    dateext                     # 로그 파일명에 날짜 확장자 추가
    dateformat -%Y%m%d          # 파일명 형식: -YYYYMMDD
    create 0644 svcuser svcuser   # 신규 로그 권한 및 소유자 지정
    sharedscripts               # 회전 후 스크립트는 한 번만 실행
    postrotate
        [ -s /home/svcuser/apps/nginx/nginx.pid ] && \
        kill -USR1 `cat /home/svcuser/apps/nginx/nginx.pid`
    endscript
}
```

### 설정 옵션 상세 설명

**회전 주기 설정:**

```conf
daily           # 매일
weekly          # 매주
monthly         # 매월
size 100M       # 파일 크기가 100MB 초과 시
```

**보관 개수:**

```conf
rotate 7        # 7개 파일 보관 (7일치)
rotate 30       # 30개 파일 보관 (30일치)
```

**압축 설정:**

```conf
compress                # 압축 활성화
delaycompress           # 최신 파일은 다음 회전 때 압축
compresscmd /bin/gzip   # 압축 명령어 (기본값)
compressext .gz         # 압축 파일 확장자 (기본값)
compressoptions -9      # 최대 압축률
```

`delaycompress`가 중요한 이유:
- 최신 로그는 압축하지 않아 즉시 조회 가능
- 압축/해제 오버헤드 감소

**오류 처리:**

```conf
missingok       # 파일 없어도 오류 없음
notifempty      # 빈 파일은 회전 안 함
```

**파일명 형식:**

```conf
dateext                     # 날짜 확장자 사용
dateformat -%Y%m%d          # -20250102 형식

# dateext 미사용 시:
# access.log → access.log.1, access.log.2, ...

# dateext 사용 시:
# access.log → access.log-20250102, access.log-20250101, ...
```

**권한 설정:**

```conf
create 0644 svcuser svcuser
# 0644: 소유자 읽기/쓰기, 그룹/기타 읽기
# svcuser svcuser: 소유자 및 그룹
```

**postrotate 스크립트:**

```conf
postrotate
    [ -s /home/svcuser/apps/nginx/nginx.pid ] && \
    kill -USR1 `cat /home/svcuser/apps/nginx/nginx.pid`
endscript
```

**동작 원리:**
1. `[ -s nginx.pid ]`: PID 파일 존재 및 비어있지 않은지 확인
2. `cat nginx.pid`: Nginx 프로세스 ID 읽기
3. `kill -USR1`: Nginx에 USR1 시그널 전송
4. Nginx가 로그 파일을 다시 열어 새 파일에 쓰기 시작

**USR1 시그널의 의미:**
- Nginx를 재시작하지 않고 로그 파일만 다시 열기
- 무중단으로 로그 회전 가능
- Graceful하게 처리

### 4단계: 개선된 설정 (권장)

기본 설정을 더욱 안전하고 효율적으로 개선한 버전:

```conf
# Nginx 로그 회전 설정 (개선 버전)
/home/svcuser/logs/nginx/nginx-1.24.0/*.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
    dateext
    dateformat -%Y%m%d
    create 0644 svcuser svcuser
    sharedscripts
    
    # 최소 파일 크기 설정 (1KB 이상만 회전)
    minsize 1k
    
    # 최대 파일 크기 설정 (1GB 넘으면 강제 회전)
    maxsize 1G
    
    # postrotate 개선: 오류 처리 강화
    postrotate
        if [ -f /home/svcuser/apps/nginx/nginx.pid ]; then
            PID=$(cat /home/svcuser/apps/nginx/nginx.pid 2>/dev/null)
            if [ -n "$PID" ] && kill -0 $PID 2>/dev/null; then
                kill -USR1 $PID
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Nginx 로그 회전 완료 (PID: $PID)" >> /home/svcuser/apps/nginx/conf/log/logrotate.log
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') - 경고: Nginx 프로세스를 찾을 수 없음" >> /home/svcuser/apps/nginx/conf/log/logrotate.log
            fi
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 오류: PID 파일이 존재하지 않음" >> /home/svcuser/apps/nginx/conf/log/logrotate.log
        fi
    endscript
}
```

**개선 사항:**

1. **minsize 1k**: 너무 작은 파일은 회전하지 않음
2. **maxsize 1G**: 1GB 넘으면 daily 주기와 무관하게 강제 회전
3. **오류 처리 강화**: 
   - PID 파일 존재 확인
   - 프로세스 실행 여부 확인 (`kill -0`)
   - 로그 기록으로 추적 가능
4. **회전 이력 로그**: 문제 발생 시 원인 분석 용이

### 5단계: 설정 검증

**문법 검사:**

```bash
# dry-run으로 실제 회전 없이 테스트
/usr/sbin/logrotate -d \
  -s /home/svcuser/apps/nginx/conf/log/logrotate.status \
  /home/svcuser/apps/nginx/conf/log/logrotate-nginx.conf
```

**강제 실행 테스트:**

```bash
# 강제로 회전 실행 (주기와 무관)
/usr/sbin/logrotate -f \
  -s /home/svcuser/apps/nginx/conf/log/logrotate.status \
  /home/svcuser/apps/nginx/conf/log/logrotate-nginx.conf
```

**결과 확인:**

```bash
# 로그 파일 목록 확인
ls -lhrt /home/svcuser/logs/nginx/nginx-1.24.0/

# 예상 결과:
# -rw-r--r-- 1 svcuser svcuser 512M  1월  2 00:00 access.log-20250102.gz
# -rw-r--r-- 1 svcuser svcuser 498M  1월  1 00:00 access.log-20250101.gz
# -rw-r--r-- 1 svcuser svcuser 1.2M  1월  3 14:30 access.log
```

### 6단계: cron 자동 실행 등록

**crontab 편집:**

```bash
crontab -e
```

**기본 설정 (매일 자정):**

```cron
# Nginx 로그 회전 (매일 0시)
0 0 * * * /usr/sbin/logrotate -s /home/svcuser/apps/nginx/conf/log/logrotate.status /home/svcuser/apps/nginx/conf/log/logrotate-nginx.conf
```

**개선된 설정 (로그 기록 포함):**

```cron
# Nginx 로그 회전 (매일 0시) - 표준 출력/에러를 로그 파일로 리다이렉트
0 0 * * * /usr/sbin/logrotate -s /home/svcuser/apps/nginx/conf/log/logrotate.status /home/svcuser/apps/nginx/conf/log/logrotate-nginx.conf >> /home/svcuser/apps/nginx/conf/log/cron.log 2>&1
```

**시간대별 옵션:**

```cron
# 새벽 2시 (서버 한가한 시간)
0 2 * * * /usr/sbin/logrotate ...

# 매시간 (로그가 매우 많은 경우)
0 * * * * /usr/sbin/logrotate ...

# 크기 기반 (hourly + maxsize)
0 * * * * /usr/sbin/logrotate ...
```

**crontab 확인:**

```bash
# 등록된 cron 확인
crontab -l

# cron 서비스 상태 확인
systemctl status crond
```

---

## 모니터링 및 트러블슈팅

### 상태 확인 스크립트

**check_logrotate.sh 생성:**

```bash
vi /home/svcuser/apps/nginx/conf/log/check_logrotate.sh
```

**내용:**

```bash
#!/bin/bash

LOG_DIR="/home/svcuser/logs/nginx/nginx-1.24.0"
STATUS_FILE="/home/svcuser/apps/nginx/conf/log/logrotate.status"

echo "========================================="
echo "Nginx 로그 회전 상태 확인"
echo "========================================="
echo ""

# 1. 현재 로그 파일 크기
echo "1. 현재 로그 파일 크기:"
ls -lh ${LOG_DIR}/*.log 2>/dev/null || echo "로그 파일 없음"
echo ""

# 2. 회전된 로그 목록 (최근 10개)
echo "2. 회전된 로그 목록 (최근 10개):"
ls -lhrt ${LOG_DIR}/*.log* 2>/dev/null | tail -10
echo ""

# 3. 디스크 사용량
echo "3. 로그 디렉토리 디스크 사용량:"
du -sh ${LOG_DIR}
echo ""

# 4. 마지막 회전 시간
echo "4. 마지막 logrotate 실행 시간:"
if [ -f ${STATUS_FILE} ]; then
    stat -c "수정 시간: %y" ${STATUS_FILE}
else
    echo "상태 파일 없음"
fi
echo ""

# 5. Nginx 프로세스 상태
echo "5. Nginx 프로세스 상태:"
if [ -f /home/svcuser/apps/nginx/nginx.pid ]; then
    PID=$(cat /home/svcuser/apps/nginx/nginx.pid)
    if ps -p $PID > /dev/null 2>&1; then
        echo "Nginx 실행 중 (PID: $PID)"
    else
        echo "경고: PID 파일은 있으나 프로세스가 없음"
    fi
else
    echo "경고: PID 파일이 없음"
fi
echo ""

# 6. 로그 파일 개수
echo "6. 로그 파일 개수:"
echo "- 압축되지 않은 로그: $(ls ${LOG_DIR}/*.log 2>/dev/null | wc -l)개"
echo "- 압축된 로그: $(ls ${LOG_DIR}/*.gz 2>/dev/null | wc -l)개"
echo ""

echo "========================================="
```

**실행 권한 부여 및 실행:**

```bash
chmod +x /home/svcuser/apps/nginx/conf/log/check_logrotate.sh
/home/svcuser/apps/nginx/conf/log/check_logrotate.sh
```

### 트러블슈팅 가이드

**문제 1: 로그 회전이 안 됨**

**증상:**
```bash
$ ls -lh access.log
-rw-r--r-- 1 svcuser svcuser 5.2G  1월  3 14:30 access.log

# 회전된 파일이 없음
```

**원인 및 해결:**

```bash
# 1. cron 실행 확인
grep logrotate /var/log/cron

# 2. 수동 실행으로 오류 확인
/usr/sbin/logrotate -v -f \
  -s /home/svcuser/apps/nginx/conf/log/logrotate.status \
  /home/svcuser/apps/nginx/conf/log/logrotate-nginx.conf

# 3. 권한 확인
ls -l /home/svcuser/logs/nginx/nginx-1.24.0/
ls -l /home/svcuser/apps/nginx/conf/log/

# 4. logrotate 경로 확인
which logrotate
```

**문제 2: Nginx가 새 로그 파일에 쓰지 않음**

**증상:**
```bash
# 로그 회전 후에도 이전 파일에 계속 쓰기
$ lsof | grep access.log
nginx  12345  access.log-20250102 (deleted)
```

**원인:**
postrotate 스크립트가 실행되지 않았거나, USR1 시그널 전송 실패

**해결:**

```bash
# 1. Nginx PID 확인
cat /home/svcuser/apps/nginx/nginx.pid

# 2. 수동으로 USR1 시그널 전송
kill -USR1 $(cat /home/svcuser/apps/nginx/nginx.pid)

# 3. Nginx 프로세스 확인
ps aux | grep nginx

# 4. 로그 파일 핸들 확인
lsof -p $(cat /home/svcuser/apps/nginx/nginx.pid) | grep log
```

**문제 3: 디스크 용량이 여전히 부족**

**증상:**
```bash
$ df -h
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       100G   98G   2G  98% /
```

**원인 및 해결:**

```bash
# 1. 로그 디렉토리 용량 확인
du -sh /home/svcuser/logs/nginx/nginx-1.24.0/

# 2. 큰 파일 찾기
find /home/svcuser/logs/nginx -type f -size +1G -exec ls -lh {} \;

# 3. 오래된 압축 로그 수동 삭제
find /home/svcuser/logs/nginx -name "*.gz" -mtime +7 -delete

# 4. rotate 개수 조정 (7→3)
vi /home/svcuser/apps/nginx/conf/log/logrotate-nginx.conf
# rotate 3으로 변경
```

**문제 4: 압축이 안 됨**

**증상:**
```bash
$ ls -lh
-rw-r--r-- 1 svcuser svcuser 512M  1월  2 access.log-20250102
-rw-r--r-- 1 svcuser svcuser 498M  1월  1 access.log-20250101
```

**원인:**
`delaycompress` 옵션으로 인해 최신 로그는 다음 회전 때 압축됨

**확인:**
```bash
# 하루 더 지나면 압축됨
# 또는 compress 옵션 확인
grep compress /home/svcuser/apps/nginx/conf/log/logrotate-nginx.conf
```

---

## 고급 설정

### 시나리오별 최적화

**시나리오 1: 트래픽이 매우 많은 서비스**

```conf
# 시간별 회전 + 크기 기반
/home/svcuser/logs/nginx/nginx-1.24.0/*.log {
    hourly              # 시간별 회전
    rotate 168          # 7일 * 24시간 = 168개 보관
    size 500M           # 500MB 넘으면 강제 회전
    compress
    delaycompress
    dateext
    dateformat -%Y%m%d-%H
    create 0644 svcuser svcuser
    sharedscripts
    postrotate
        [ -s /home/svcuser/apps/nginx/nginx.pid ] && \
        kill -USR1 `cat /home/svcuser/apps/nginx/nginx.pid`
    endscript
}
```

```cron
# cron을 매시간으로 변경
0 * * * * /usr/sbin/logrotate ...
```

**시나리오 2: access.log와 error.log 분리 관리**

```conf
# access.log - 7일 보관
/home/svcuser/logs/nginx/nginx-1.24.0/access.log {
    daily
    rotate 7
    compress
    delaycompress
    dateext
    dateformat -%Y%m%d
    create 0644 svcuser svcuser
    sharedscripts
    postrotate
        [ -s /home/svcuser/apps/nginx/nginx.pid ] && \
        kill -USR1 `cat /home/svcuser/apps/nginx/nginx.pid`
    endscript
}

# error.log - 30일 보관 (중요)
/home/svcuser/logs/nginx/nginx-1.24.0/error.log {
    daily
    rotate 30
    compress
    delaycompress
    dateext
    dateformat -%Y%m%d
    create 0644 svcuser svcuser
    sharedscripts
    postrotate
        [ -s /home/svcuser/apps/nginx/nginx.pid ] && \
        kill -USR1 `cat /home/svcuser/apps/nginx/nginx.pid`
    endscript
}
```

**시나리오 3: 외부 로그 서버로 전송**

```conf
/home/svcuser/logs/nginx/nginx-1.24.0/*.log {
    daily
    rotate 7
    compress
    delaycompress
    dateext
    dateformat -%Y%m%d
    create 0644 svcuser svcuser
    sharedscripts
    postrotate
        # Nginx 시그널 전송
        [ -s /home/svcuser/apps/nginx/nginx.pid ] && \
        kill -USR1 `cat /home/svcuser/apps/nginx/nginx.pid`
        
        # 회전된 로그를 외부 서버로 전송
        LOG_DATE=$(date -d "yesterday" +%Y%m%d)
        scp /home/svcuser/logs/nginx/nginx-1.24.0/*-${LOG_DATE} \
            logserver:/backup/nginx/
    endscript
}
```

### 알림 설정

**로그 회전 실패 시 이메일 알림:**

```bash
# crontab에 MAILTO 추가
crontab -e
```

```cron
MAILTO=admin@example.com

0 0 * * * /usr/sbin/logrotate \
  -s /home/svcuser/apps/nginx/conf/log/logrotate.status \
  /home/svcuser/apps/nginx/conf/log/logrotate-nginx.conf \
  || echo "Nginx logrotate 실패" | mail -s "Logrotate Alert" admin@example.com
```

**Slack 알림:**

```bash
# postrotate에 Slack 웹훅 추가
postrotate
    # Nginx 시그널 전송
    [ -s /home/svcuser/apps/nginx/nginx.pid ] && \
    kill -USR1 `cat /home/svcuser/apps/nginx/nginx.pid`
    
    # Slack 알림
    curl -X POST -H 'Content-type: application/json' \
      --data '{"text":"Nginx 로그 회전 완료"}' \
      YOUR_SLACK_WEBHOOK_URL
endscript
```

---

## 결과 확인

### 로그 파일 구조

**회전 후 디렉토리 구조:**

```bash
$ ls -lhrt /home/svcuser/logs/nginx/nginx-1.24.0/

-rw-r--r-- 1 svcuser svcuser 487M 12월 28 00:00 access.log-20241228.gz
-rw-r--r-- 1 svcuser svcuser 512M 12월 29 00:00 access.log-20241229.gz
-rw-r--r-- 1 svcuser svcuser 498M 12월 30 00:00 access.log-20241230.gz
-rw-r--r-- 1 svcuser svcuser 523M 12월 31 00:00 access.log-20241231.gz
-rw-r--r-- 1 svcuser svcuser 534M  1월  1 00:00 access.log-20250101.gz
-rw-r--r-- 1 svcuser svcuser 510M  1월  2 00:00 access.log-20250102
-rw-r--r-- 1 svcuser svcuser 1.2M  1월  3 14:30 access.log
```

**파일명 패턴:**
```
access.log                    ← 현재 로그
access.log-20250102           ← 어제 로그 (압축 전)
access.log-20250101.gz        ← 그제 로그 (압축됨)
access.log-20241231.gz
...
access.log-20241228.gz        ← 7일 전 로그 (다음 회전 시 삭제)
```

### 용량 비교

**Before:**
```bash
$ du -sh /home/svcuser/logs/nginx
47G     /home/svcuser/logs/nginx
```

**After:**
```bash
$ du -sh /home/svcuser/logs/nginx
3.5G    /home/svcuser/logs/nginx
```

**절감률: 92%**

---

## 정리

### 핵심 요약

1. **로그 관리는 logrotate로 자동화**
   - 수동 관리 불필요
   - 일정한 주기로 안정적 동작

2. **날짜 기반 파일명 (dateformat)**
   - 직관적인 파일 식별
   - 특정 날짜 로그 빠른 검색

3. **postrotate + USR1 시그널**
   - Nginx 재시작 없이 로그 회전
   - 무중단 서비스 유지

4. **압축으로 용량 절감**
   - 디스크 사용량 90% 감소
   - delaycompress로 최신 로그 즉시 조회 가능

5. **cron 자동 실행**
   - 매일 자정 자동 실행
   - 관리 부담 제로

### 체크리스트

로그 관리 구축 시 확인 사항:

- [ ] logrotate 설정 파일 작성
- [ ] 상태 파일 생성 및 권한 확인
- [ ] postrotate 스크립트 동작 확인
- [ ] 수동 실행 테스트 (-f 옵션)
- [ ] cron 등록 및 확인
- [ ] 첫 회전 후 결과 검증
- [ ] Nginx PID 파일 경로 확인
- [ ] 디스크 용량 모니터링 설정
- [ ] 백업 정책 수립 (선택)

### 추가 개선 사항

**1. 중앙 로그 서버 구축**
- ELK Stack (Elasticsearch, Logstash, Kibana)
- Filebeat로 로그 전송
- 실시간 로그 분석 및 시각화

**2. 로그 분석 자동화**
- GoAccess로 실시간 웹 로그 분석
- 주기적인 보고서 생성
- 이상 트래픽 감지

**3. S3 백업**
- 로그를 AWS S3에 자동 백업
- Glacier로 장기 보관
- 비용 효율적인 아카이빙

### 마지막으로

로그 관리는 **사후 대응이 아닌 사전 예방**이다.

디스크가 가득 차서 서비스 장애가 발생하기 전에, logrotate를 설정하여 안정적인 운영 환경을 구축하자.

**한 번 설정하면 평생 관리 걱정 없다.**

---
