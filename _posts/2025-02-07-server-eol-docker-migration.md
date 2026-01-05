---
title: "아무도 모르는 Node 레거시의 습격, Docker로 5시간 삽질을 10분으로"
categories: devops
tags: [docker, node, server-migration, eol, infrastructure]
excerpt: "3년 전 퇴사자가 남긴 서비스 마이그레이션과 Docker 이미지 기반 배포 경험기"
---

## 들어가며

서버 EOL(End Of Life)은 언젠가 반드시 찾아온다.

하지만 그 순간이 왔을 때, 우리가 얼마나 준비되어 있는가가 문제다.

**우리 팀의 상황:**
- 대부분 Java/Spring 기반 백엔드 개발자
- Node 전문 인력 부재
- 팀 초기에 구축된 Node 서비스 존재
- 구축 담당자 퇴사 후 3년 경과

그리고 그 3년 후, 서버 EOL이 발생했다.

이 글은 그 과정에서 겪은 시행착오와, Docker를 통해 어떻게 근본적인 문제를 해결했는지에 대한 기록이다.

---

## 1. 문제의 시작: 아무도 모르는 서비스

### 상황 정리

**Node 서비스의 배경:**
- 팀 초기 멤버 1명이 구축
- 해당 인력 퇴사 이후
  - 문서 없음
  - 설치 방법, 실행 방법, 의존성 정보 부재
  - 현행화도 전혀 되지 않은 상태

**현실:**
> "잘 돌아가고는 있지만, 아무도 정확히 모르는 서비스"

### 서버 이전 작업 시작

```bash
# 기존 서버 접속
$ ssh old-server

# 무엇이 설치되어 있는가?
$ node -v
v14.17.0

$ npm -v
6.14.13

$ pm2 -v
5.1.0

# 서비스는 어떻게 기동되는가?
$ ps aux | grep node
```

이 과정에서 **예상치 못한 시행착오가 발생**했다.

---

## 2. 시행착오 ① - Node/npm 버전 지옥

### 문제 발생

신규 서버 환경:

```bash
$ node -v
v16.14.0  # 기존 v14.17.0

$ npm -v
8.3.1     # 기존 6.14.13
```

### 실제 발생한 문제

**npm install 실패:**

```bash
$ npm install
npm ERR! code ERESOLVE
npm ERR! ERESOLVE unable to resolve dependency tree
npm ERR! 
npm ERR! While resolving: app@1.0.0
npm ERR! Found: express@4.17.1
npm ERR! node_modules/express
npm ERR!   express@"^4.17.1" from the root project
npm ERR! 
npm ERR! Could not resolve dependency:
npm ERR! peer express@"^4.16.0" of body-parser@1.19.0
```

**package-lock.json 버전 충돌:**

```bash
npm WARN old lockfile 
npm WARN old lockfile The package-lock.json file was created with an old version of npm,
npm WARN old lockfile so supplemental metadata must be fetched from the registry.
```

### 해결 시도의 연속

```bash
# 1차 시도: 그냥 실행
$ npm install
# 실패

# 2차 시도: package-lock.json 삭제
$ rm package-lock.json
$ npm install
# 다른 의존성 에러

# 3차 시도: node_modules 삭제
$ rm -rf node_modules
$ npm install
# 여전히 실패

# 4차 시도: npm 버전 다운그레이드
$ npm install -g npm@6.14.13
# 권한 문제 발생

# 5차 시도: nvm으로 Node 버전 변경
$ nvm install 14.17.0
$ nvm use 14.17.0
# 드디어 성공
```

**소요 시간: 약 2시간**

> "이게 왜 안 되지?"의 연속

---

## 3. 시행착오 ② - pm2 설치의 미스터리

### 문제 발견

서비스 기동 명령:

```bash
$ pm2 reload ecosystem.config.js
```

하지만 신규 서버에는:

```bash
$ pm2 reload ecosystem.config.js
bash: pm2: command not found
```

### pm2가 npm install 대상이 아니었다

**package.json 확인:**

```json
{
  "dependencies": {
    "express": "^4.17.1",
    "body-parser": "^1.19.0"
    // pm2가 없다!
  },
  "devDependencies": {
    // 여기도 없다!
  }
}
```

**결국 글로벌 설치가 필요:**

```bash
$ npm install -g pm2
```

### 추가 문제들

**1. 글로벌 설치 경로 문제:**

```bash
# root로 설치한 경우
$ which pm2
/usr/local/bin/pm2

# 일반 유저로 실행 시
$ pm2 reload ecosystem.config.js
pm2: command not found
```

**2. 실행 계정 문제:**

```bash
# deploy 계정으로 서비스 실행
$ su - deploy
$ pm2 reload ecosystem.config.js

# 하지만 pm2는 root 계정에만 설치됨
```

**3. ecosystem.config.js 경로 문제:**

```bash
$ pm2 reload ecosystem.config.js
[PM2] Spawning PM2 daemon with pm2_home=/home/deploy/.pm2
[PM2] PM2 Successfully daemonized

# 하지만 설정 파일을 못 찾음
Error: ENOENT: no such file or directory, open 'ecosystem.config.js'
```

**해결까지 소요 시간: 약 1.5시간**

---

## 4. 본질적인 문제 인식

### 문제는 문서가 없어서가 아니다

만약 완벽한 문서가 있었다면?

**설치 가이드 문서:**

```markdown
# Node 서비스 설치 가이드

## 1. Node 설치
nvm install 14.17.0
nvm use 14.17.0

## 2. npm 설치
npm install -g npm@6.14.13

## 3. pm2 설치
npm install -g pm2

## 4. 환경변수 설정
export DB_HOST=...
export DB_PORT=...

## 5. 설정 파일 복사
...

## 6. 의존성 설치
npm install

## 7. 서비스 기동
pm2 reload ecosystem.config.js
```

**문제는:**
- 이 문서가 어디 있는지 모름
- 최신 버전인지 확신할 수 없음
- 실제로 동작하는지 검증 안 됨
- 3년 전 작성된 문서는 이미 outdated

### 근본 원인

> **"설치와 실행 방식이 코드로 남아있지 않다"**

다시 질문해보자:

> "이 서비스를 다시 이전해야 한다면,
> 우리는 똑같은 시행착오를 반복할까?"

답은 **YES**

---

## 5. 해결책: Docker

### Docker를 선택한 이유

**핵심 장점:**

1. **설치 과정을 코드로 남김**
   - Dockerfile = 실행 가능한 명세서
   - 버전 관리 가능

2. **실행 환경을 명확하게 고정**
   - OS 차이 제거
   - 패키지 버전 고정
   - 설치 순서 보장

3. **서버 이전 부담 제거**
   - Docker만 설치되면 어디서든 동작
   - 재현 가능한 환경

### Docker 적용 전략

**목표:**
> Node 서비스 실행에 필요한 모든 것을 Dockerfile 하나로 표현

**접근 방식:**
- Node 버전 명시
- npm / pm2 설치 명시
- 환경변수 명시
- 실행 명령 명시

---

## 6. Dockerfile 작성

### 최종 Dockerfile

```dockerfile
# Node 버전 명시
FROM node:14.17.0-alpine

# pm2 글로벌 설치
RUN npm install -g pm2@5.1.0

# 작업 디렉토리 설정
WORKDIR /app

# 의존성 파일 복사
COPY package*.json ./

# 의존성 설치
RUN npm ci --only=production

# 소스 코드 복사
COPY . .

# 환경변수 설정
ENV NODE_ENV=production
ENV PORT=3000

# 포트 노출
EXPOSE 3000

# pm2로 서비스 기동
CMD ["pm2-runtime", "start", "ecosystem.config.js"]
```

### 핵심 포인트

**1. Node 버전 고정:**

```dockerfile
FROM node:14.17.0-alpine
```

- 더 이상 nvm 필요 없음
- 서버 기본 Node 버전과 무관

**2. pm2 글로벌 설치 명시:**

```dockerfile
RUN npm install -g pm2@5.1.0
```

- 설치 방법 명확
- 버전 고정

**3. npm ci 사용:**

```dockerfile
RUN npm ci --only=production
```

- package-lock.json 기준으로 정확한 버전 설치
- npm install보다 빠르고 안정적

**4. pm2-runtime 사용:**

```dockerfile
CMD ["pm2-runtime", "start", "ecosystem.config.js"]
```

일반 `pm2 start`가 아닌 `pm2-runtime`을 사용하는 이유:
- 컨테이너의 PID 1 프로세스로 정상 동작
- 종료 시그널(SIGTERM)을 올바르게 처리
- 로그가 stdout으로 출력되어 `docker logs` 명령으로 확인 가능
- 컨테이너가 종료될 때 프로세스도 정상 종료

---

## 7. docker-compose.yml 작성

### 환경변수 및 설정 관리

```yaml
version: '3.8'

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: node-app
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - NODE_ENV=production
      - DB_HOST=${DB_HOST}
      - DB_PORT=${DB_PORT}
      - DB_USER=${DB_USER}
      - DB_PASS=${DB_PASS}
    volumes:
      - ./logs:/app/logs
      - ./config:/app/config:ro
```

**volumes 설명:**
- `./logs:/app/logs`: 로그 파일을 호스트에 저장 (읽기/쓰기)
- `./config:/app/config:ro`: config 디렉토리는 읽기 전용(ro)으로 마운트하여 컨테이너 내부에서 설정 파일이 변경되지 않도록 제한

### .env 파일

```bash
# .env
DB_HOST=10.10.10.100
DB_PORT=3306
DB_USER=app_user
DB_PASS=secretpassword
```

---

## 8. Docker 이미지 관리 방식

### 사내 정책상 제약

**사용 불가:**
- Docker Hub
- 사설 Registry 운영

**대안:**
> 자체 관리되는 바이너리 형태의 Docker 이미지 파일 활용

### 이미지 저장 및 배포

**1. 이미지 빌드:**

```bash
$ docker build -t node-app:1.0.0 .
```

**2. 이미지 저장:**

```bash
$ docker save node-app:1.0.0 -o node-app-1.0.0.tar
```

**3. 이미지 전송:**

```bash
$ scp node-app-1.0.0.tar new-server:/tmp/
```

**4. 이미지 로드:**

```bash
$ ssh new-server
$ docker load -i /tmp/node-app-1.0.0.tar
```

**5. 컨테이너 실행:**

```bash
$ docker-compose up -d
```

### 장점

- 외부 네트워크 의존성 제거
- 이미지 파일을 내부 저장소에서 관리
- 버전별 이미지 보관 가능

---

## 9. 서버 이전 방식 변화

### Before Docker

**절차:**

```bash
1. 신규 서버 접속
2. Node 버전 확인 및 설치
3. npm 버전 확인 및 조정
4. pm2 글로벌 설치
5. 소스 코드 복사
6. 환경변수 설정
7. 설정 파일 복사
8. npm install
9. 권한 설정
10. pm2로 서비스 기동
11. 에러 발생
12. 구글링
13. 재시도
14. 반복...
```

**소요 시간: 약 4~5시간** (시행착오 포함)

### After Docker

**절차:**

```bash
1. 신규 서버에 Docker 설치
2. 이미지 파일 전송 및 로드
3. docker-compose up -d
4. 끝
```

**소요 시간: 약 10분**

### 비교 결과

| 항목 | Before | After |
|------|--------|-------|
| 소요 시간 | 4~5시간 | 10분 |
| 시행착오 | 많음 | 거의 없음 |
| 재현성 | 낮음 | 100% |
| 문서 의존도 | 높음 | 없음 |
| 숙련도 필요 | Node 전문 지식 | Docker 기본 지식 |

---

## 10. Dockerfile의 의미 변화

### 기존: 문서 기반

**문서의 한계:**

```markdown
문서 작성 → 시간 경과 → Outdated → 불신
          ↓
      실제 환경과 불일치
```

**문제:**
- 문서가 어디 있는지 모름
- 최신인지 확신 못 함
- 실제 동작 검증 안 됨

### Docker: 코드 기반

**Dockerfile의 의미:**

```
Dockerfile = 서비스 설치 & 실행의 단일 진실 소스
```

**장점:**
- 소스 코드와 함께 버전 관리
- 실행 가능 = 검증 완료
- 문서를 찾을 필요 없음
- 항상 최신 상태 유지

---

## 11. 실전 적용 사례

### Case 1: 긴급 DR 전환

**상황:**
- 메인 서버 장애
- DR 서버로 긴급 전환 필요

**Before Docker:**

```
예상 소요 시간: 2~3시간
문제 발생 가능성: 높음
```

**After Docker:**

```bash
# DR 서버에서
$ docker load -i node-app-1.0.0.tar
$ docker-compose up -d

소요 시간: 5분
문제 발생: 없음
```

### Case 2: 서버 증설

**상황:**
- 트래픽 증가로 서버 추가 필요

**Before Docker:**

```
동일한 환경 구축: 4~5시간
설정 불일치 위험: 높음
```

**After Docker:**

```bash
# 새 서버에서
$ docker load -i node-app-1.0.0.tar
$ docker-compose up -d

소요 시간: 10분
환경 일치: 100% 보장
```

### Case 3: 담당자 교체

**상황:**
- Node 서비스 담당자 변경

**Before Docker:**

```
인수인계 기간: 1주일
문서 학습 및 환경 파악
실제 동작 이해
```

**After Docker:**

```bash
# Dockerfile 확인
$ cat Dockerfile

# 로컬에서 실행
$ docker-compose up

소요 시간: 30분
이해도: 명확
```

---

## 12. Docker 도입 안 했으면 어땠을까?

### 시나리오 1: 다음 EOL

**3년 후 또 다시 서버 EOL 발생**

**Docker 없이:**

```
1. 또 다시 버전 확인
2. 또 다시 설치 방법 찾기
3. 또 다시 시행착오
4. 또 다시 4~5시간 소요
```

**Docker 있으면:**

```
1. docker load
2. docker-compose up
3. 10분 완료
```

### 시나리오 2: 신규 서버 증설

**트래픽 증가로 긴급 증설 필요**

**Docker 없이:**

```
위험 요소:
- 설정 불일치 가능성
- 버전 차이 발생
- 테스트 시간 필요
- 서비스 투입 지연
```

**Docker 있으면:**

```
장점:
- 100% 동일 환경 보장
- 즉시 운영 투입 가능
- 테스트 최소화
```

### 시나리오 3: 담당자 교체

**Node 서비스 담당자 퇴사**

**Docker 없이:**

```
리스크:
- 지식 유실
- 긴 인수인계 기간
- 문제 발생 시 대응 어려움
- 다시 학습 곡선
```

**Docker 있으면:**

```
안정성:
- Dockerfile이 모든 걸 설명
- 로컬에서 즉시 테스트 가능
- 빠른 이해 가능
- 지식 유실 최소화
```

---

## 13. 팀 관점에서의 효과

### 운영 리스크 감소

**Before:**

```
Node 비전문 팀
  ↓
서비스 이전 두려움
  ↓
특정 인력 의존
  ↓
퇴사 시 리스크 폭증
```

**After:**

```
Docker 도입
  ↓
재현 가능한 환경
  ↓
팀 전체가 대응 가능
  ↓
인력 의존도 제거
```

### 심리적 안정감

**개발자 관점:**

> "다음 EOL도 무섭지 않다"

**팀 리더 관점:**

> "담당자 퇴사해도 괜찮다"

**운영자 관점:**

> "긴급 상황에도 빠르게 대응 가능"

---

## 14. 이 경험에서 얻은 교훈

### 1. "잘 돌아가는 서비스"는 안전하지 않다

**착각:**
> "3년간 문제없이 잘 돌아갔으니 괜찮다"

**현실:**
> "재설치할 수 없는 서비스는 언제든 장애가 될 수 있다"

### 2. 문서보다 중요한 것

**문서의 한계:**
- 작성 시점에만 정확
- 실행 검증 불가
- 찾기 어려움

**코드의 힘:**
- 실행 가능 = 검증 완료
- 버전 관리 가능
- 항상 최신 상태

### 3. Docker는 선택이 아니라 필수

**Docker의 본질:**
> 편의를 위한 도구가 아니라
> 미래의 나와 팀원을 위한 보험

---

## 15. 실무 적용 가이드

### Docker 도입 체크리스트

**준비 단계:**

```
□ Docker 설치 환경 확인
□ 기존 서비스 분석
  - 런타임 버전 (Node, Python, Java 등)
  - 의존성 목록
  - 환경변수
  - 설정 파일
□ 외부 의존성 파악
  - DB 연결
  - 외부 API
  - 파일 시스템
```

**Dockerfile 작성:**

```
□ Base Image 선택
□ 런타임 버전 고정
□ 의존성 설치 명시
□ 소스 코드 복사
□ 환경변수 설정
□ 실행 명령 정의
```

**테스트:**

```
□ 로컬 환경에서 빌드
□ 로컬 환경에서 실행
□ 기능 동작 확인
□ 성능 확인
```

**배포:**

```
□ 이미지 저장 방식 결정
□ 배포 프로세스 정의
□ 롤백 절차 수립
```

---

## 16. 주의사항

### Docker가 만능은 아니다

**고려해야 할 사항:**

**1. 성능 오버헤드**
- 컨테이너 오버헤드 존재 (매우 작음)
- 대부분의 경우 무시 가능한 수준

**2. 학습 곡선**
- Docker 기본 지식 필요
- 하지만 Node/Python/Java 전문 지식보다 쉬움

**3. 로그 관리**
- 컨테이너 로그 전략 필요
- Volume mount 또는 로그 드라이버 활용

**4. 데이터 영속성**
- Volume 설정 필수
- 백업 전략 수립

### 하지만 이런 단점보다

> 서버 이전 시 4~5시간 삽질하는 것보다
> Docker 배우는 게 훨씬 낫다

---

## 17. 마무리

### 핵심 메시지

**1. 서버 EOL은 피할 수 없다**
- 언젠가 반드시 찾아온다
- 준비 없이 맞이하면 재앙

**2. 재현 가능한 환경이 핵심**
- 문서 < 실행 가능한 코드
- Dockerfile = 살아있는 문서

**3. Docker는 보험이다**
- 당장 편하려고 쓰는 게 아니다
- 미래의 나와 팀을 위한 투자

### 최종 질문

**다시 물어보자:**

> "이 서비스를 다시 이전해야 한다면,
> 우리는 또 같은 삽질을 할까?"

**Docker 도입 후 답:**

**NO**

---

## Reference

- [Docker Documentation](https://docs.docker.com/)
- [Node.js Docker Best Practices](https://github.com/nodejs/docker-node/blob/main/docs/BestPractices.md)
- [pm2 Docker Integration](https://pm2.keymetrics.io/docs/usage/docker-pm2-nodejs/)

