---
title: "NPM 가이드: install vs ci, package.json vs package-lock.json"
categories: javascript
tags: [npm, nodejs, package-management, ci-cd, devops]
excerpt: "npm install과 npm ci의 차이, package.json과 package-lock.json의 역할을 이해하고, 상황에 맞는 올바른 의존성 관리 방법"
---

## 들어가며

팀 내에서 Node.js 프로젝트를 진행하던 중, 의존성 관리와 관련하여 혼란스러운 상황이 반복되었다.

**문제 상황:**

```
개발자 A: npm install 사용 (npm 8.19.4)
개발자 B: npm ci 사용 (npm 9.5.0)
개발자 C: npm install 사용 (npm 10.2.0)

결과: package.json, package-lock.json이 자주 변경됨
      Git 커밋마다 lock 파일 충돌 발생
      "왜 내 컴퓨터에서만 안 되지?" 반복
```

특히 다음과 같은 혼란이 있었다:

- 어떤 팀원은 `npm install`을, 어떤 팀원은 `npm ci`를 사용
- **개발자마다 npm 버전이 달라서** `npm install`만 해도 lock 파일이 대폭 변경됨
- lock 파일이 변경될 때마다 Git에서 충돌 발생
- "왜 package-lock.json이 자꾸 바뀌는 거지?"
- "이 파일 커밋해야 하나, 말아야 하나?"

**가장 큰 문제는 npm 버전 차이였다:**

```
개발자 A: npm 8.19.2 사용
개발자 B: npm 9.5.0 사용
개발자 C: npm 10.2.0 사용

→ npm install 실행만 해도 lockfileVersion이 변경됨
→ package-lock.json 전체가 재작성됨
→ Git diff에서 수백 줄이 변경되어 보임
```

**이 문제를 해결하기 위해:**

- `npm install`과 `npm ci`는 각각 언제 사용해야 하는가?
- `package.json`과 `package-lock.json`은 어떤 역할을 하는가?
- **npm 버전을 어떻게 통일할 수 있는가?**
- 팀 전체가 일관되게 사용할 수 있는 가이드는 무엇인가?

**최종 결정:**
- Node.js: **v16.20.2**
- npm: **8.19.4**

결정의 이유는 다음과 같다:
- **LTS 버전 안정성**: Node.js v16은 장기 지원(LTS) 버전으로, 안정적인 운영 환경 제공
- 사용중인 라이브러리 호환성: 주요 라이브러리들이 Node.js v16과 호환됨

이 글에서는 이러한 혼란을 해소하고, **팀 전체가 일관된 의존성 관리 방식을 사용**할 수 있도록 하기위해 `package.json`, `package-lock.json`, `npm install`, `npm ci`의 역할과 차이점을 정리한다.

---

## package.json

### 역할

**프로젝트의 메타 정보와 의존성 정의를 포함하는 핵심 파일**

- 프로젝트 이름, 버전, 설명
- 의존성 목록 (버전 범위 포함)
- 스크립트 명령어
- 저장소 정보

### 생성 방법

**1. 자동 생성:**

```bash
npm init
```

대화형으로 프로젝트 정보 입력:

```
package name: (my-app) 
version: (1.0.0) 
description: My awesome application
entry point: (index.js) 
test command: jest
git repository: https://github.com/user/repo
keywords: node, express
author: 홍길동
license: (ISC) MIT
```

**2. 기본값으로 빠르게 생성:**

```bash
npm init -y
```

### 주요 구조

```json
{
  "name": "my-app",
  "version": "1.0.0",
  "description": "My awesome Node.js application",
  "main": "index.js",
  "scripts": {
    "start": "node index.js",
    "dev": "nodemon index.js",
    "test": "jest",
    "build": "webpack --mode production"
  },
  "dependencies": {
    "express": "^4.18.2",
    "lodash": "^4.17.21"
  },
  "devDependencies": {
    "jest": "^29.0.0",
    "nodemon": "^2.0.20"
  },
  "engines": {
    "node": ">=16.0.0",
    "npm": ">=8.0.0"
  },
  "repository": {
    "type": "git",
    "url": "https://github.com/user/my-app"
  },
  "keywords": ["node", "express", "api"],
  "author": "홍길동 <hong@example.com>",
  "license": "MIT"
}
```

### 필드 설명

**기본 정보:**

| 필드 | 설명 | 예시 |
|------|------|------|
| **name** | 패키지 이름 | "my-app" |
| **version** | 버전 (Semantic Versioning) | "1.0.0" |
| **description** | 프로젝트 설명 | "My awesome app" |
| **main** | 진입점 파일 | "index.js" |

**스크립트:**

```json
"scripts": {
  "start": "node index.js",
  "dev": "nodemon index.js",
  "test": "jest",
  "build": "webpack"
}
```

**실행:**
```bash
npm start
npm run dev
npm test
npm run build
```

**의존성:**

| 필드 | 설명 | 사용 시점 |
|------|------|----------|
| **dependencies** | 런타임에 필요한 패키지 | 프로덕션 환경에서도 필요 |
| **devDependencies** | 개발 환경에서만 필요한 패키지 | 개발, 테스트, 빌드 시에만 필요 |

**예시:**

```json
{
  "dependencies": {
    "express": "^4.18.2",      // 웹 서버 (프로덕션 필요)
    "lodash": "^4.17.21",      // 유틸리티 (프로덕션 필요)
    "mongoose": "^7.0.0"       // DB 연결 (프로덕션 필요)
  },
  "devDependencies": {
    "jest": "^29.0.0",         // 테스트 도구
    "nodemon": "^2.0.20",      // 개발 서버 자동 재시작
    "eslint": "^8.0.0",        // 코드 린팅
    "webpack": "^5.0.0"        // 빌드 도구
  }
}
```

### 버전 범위 표기법

**Semantic Versioning (SemVer):**

```
Major.Minor.Patch
  │     │     │
  │     │     └─ 버그 수정
  │     └─ 기능 추가 (하위 호환)
  └─ 호환성 깨지는 변경

예: 4.18.2
```

**버전 범위 기호:**

| 표기 | 의미 | 예시 | 허용 범위 |
|------|------|------|----------|
| **^** (캐럿) | Minor, Patch 업데이트 허용 | ^4.18.2 | 4.18.2 ≤ version < 5.0.0 |
| **~** (틸드) | Patch 업데이트만 허용 | ~4.18.2 | 4.18.2 ≤ version < 4.19.0 |
| **\*** (와일드카드) | 모든 버전 허용 | 4.*.* | 4.0.0 ≤ version < 5.0.0 |
| **(없음)** | 정확한 버전 고정 | 4.18.2 | 4.18.2만 허용 |
| **>=** | 이상 | >=4.18.2 | 4.18.2 이상 모든 버전 |

**실전 예시:**

```json
{
  "dependencies": {
    "express": "^4.18.2",    // 4.18.2 이상 ~ 5.0.0 미만
    "lodash": "~4.17.21",    // 4.17.21 이상 ~ 4.18.0 미만
    "react": "18.2.0",       // 정확히 18.2.0만
    "axios": "*"             // 모든 버전 (위험, 비권장)
  }
}
```

**권장 사항:**

```
일반적인 경우: ^ (캐럿) 사용
안정성 중요: ~ (틸드) 또는 정확한 버전
실험적 프로젝트: ^ (캐럿)
프로덕션: package-lock.json과 함께 관리
```

---

## package-lock.json

### 역할

**의존성 트리를 고정(lock)하여 정확한 버전 재현을 가능하게 함**

- 모든 의존성의 정확한 버전 기록
- 다운로드 URL 고정
- 무결성 체크섬 포함
- 협업 및 배포 시 일관성 보장

### 생성 시점

**자동 생성:**

```bash
npm install
```

실행 시 자동으로 생성되거나 업데이트됨.

**절대 직접 수정하지 않음!**

### 구조

**package.json:**

```json
{
  "dependencies": {
    "lodash": "^4.17.21"
  }
}
```

**package-lock.json:**

```json
{
  "name": "my-app",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": {
      "name": "my-app",
      "version": "1.0.0",
      "dependencies": {
        "lodash": "^4.17.21"
      }
    },
    "node_modules/lodash": {
      "version": "4.17.21",
      "resolved": "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz",
      "integrity": "sha512-v2kDEe57lecTulaDIuNTPy3Ry4gLGJ6Z1O3vE1krgXZNrsQ+LFTGHVxVjcXPs17LhbZVGedAJv8XZ1tvj5FvSg=="
    }
  },
  "dependencies": {
    "lodash": {
      "version": "4.17.21",
      "resolved": "https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz",
      "integrity": "sha512-v2kDEe57lecTulaDIuNTPy3Ry4gLGJ6Z1O3vE1krgXZNrsQ+LFTGHVxVjcXPs17LhbZVGedAJv8XZ1tvj5FvSg=="
    }
  }
}
```

### 주요 필드

| 필드 | 설명 |
|------|------|
| **version** | 설치된 정확한 버전 (4.17.21) |
| **resolved** | 다운로드 URL (고정) |
| **integrity** | SHA-512 해시 (변조 방지) |

### 왜 필요한가?

**문제 상황:**

```
개발자 A (2023.01):
npm install → lodash ^4.17.21 → 4.17.21 설치

개발자 B (2023.06):
npm install → lodash ^4.17.21 → 4.18.0 설치 (새 버전 출시)

결과: 같은 package.json인데 다른 버전!
```

**해결:**

```
package-lock.json 존재:
→ 모든 개발자가 정확히 4.17.21 설치
→ 버전 차이로 인한 버그 방지
```

### 실전 사례

**시나리오: 협업 중 버전 불일치**

**Before (package-lock.json 없음):**

```
개발자 A 환경:
- express 4.18.2
- 정상 동작

개발자 B 환경:
- express 4.19.0 (새 버전 자동 설치)
- 특정 API 변경으로 에러 발생

개발자 A: "제 컴퓨터에서는 잘 돼요?"
개발자 B: "저는 에러가 나는데요?"
```

**After (package-lock.json 사용):**

```
모든 개발자:
- express 4.18.2 (고정)
- 동일한 환경 보장
```

---

## npm install vs npm ci

### 비교표

| 항목 | npm install | npm ci |
|------|-------------|--------|
| **목적** | 개발 환경에서 유연한 설치 | CI/CD 환경에서 고정 설치 |
| **package-lock.json 필요** | 없어도 가능 | **반드시 필요** |
| **node_modules 처리** | 기존 유지 | **삭제 후 재설치** |
| **의존성 추가/변경** | 가능 (package.json 기준) | **불가능** (lock 파일과 다르면 에러) |
| **속도** | 상대적으로 느림 | **더 빠름** (10-50% 빠름) |
| **일관성** | 낮음 (버전 범위 허용) | **높음** (정확한 버전 보장) |
| **package-lock.json 수정** | 수정 가능 | **수정 안 함** |

### npm install 상세

**동작 방식:**

```
1. package.json 읽기
2. 버전 범위(^, ~) 확인
3. 레지스트리에서 최신 호환 버전 찾기
4. node_modules에 설치 (기존 파일 유지)
5. package-lock.json 생성/업데이트
```

**사용 케이스:**

**1) 신규 패키지 추가:**

```bash
npm install express
npm install --save-dev jest
```

**2) 로컬 개발 환경 셋업:**

```bash
git clone https://github.com/user/repo
cd repo
npm install
```

**3) 특정 패키지 업데이트:**

```bash
npm install lodash@latest
```

**특징:**

- 유연함: 버전 범위 내에서 최신 버전 설치
- 편리함: 기존 node_modules 유지
- 위험: 환경마다 다른 버전 설치 가능

### npm ci 상세

**동작 방식:**

```
1. package-lock.json 읽기
2. package.json과 일치 여부 확인
   └─ 불일치 시 오류 발생
3. node_modules 디렉토리 삭제
4. lock 파일의 정확한 버전으로 설치
5. package-lock.json 수정 안 함
```

**사용 케이스:**

**1) CI/CD 파이프라인 (Jenkins):**

```groovy
// Jenkinsfile
stage('Install dependencies') {
    steps {
        sh 'npm ci'
    }
}
```

**2) 배포 전 테스트 환경:**

```bash
npm ci
npm test
```

**3) 프로덕션 배포:**

```bash
npm ci --only=production
```

**특징:**

- 빠름: 10-50% 빠른 설치
- 안정적: 정확한 버전 보장
- 엄격함: lock 파일과 package.json 불일치 시 에러

### 속도 비교

**테스트 환경:**
- 의존성 개수: 100개
- 측정 횟수: 10회

**결과:**

```
npm install (첫 설치):     45초
npm install (캐시 있음):   15초
npm ci (첫 설치):          30초
npm ci (캐시 있음):        8초

npm ci가 약 50% 빠름!
```

**왜 빠른가?**

1. node_modules 삭제로 기존 파일 체크 불필요
2. 버전 계산 불필요 (lock 파일에 명시)
3. 최적화된 설치 알고리즘

---

## 언제 무엇을 사용해야 할까?

### 상황별 가이드

**로컬 개발 환경:**

| 상황 | 명령어 | 이유 |
|------|--------|------|
| 저장소 클론 후 첫 설치 | `npm install` | package-lock.json 기반 설치 |
| 신규 패키지 추가 | `npm install <package>` | package.json 업데이트 필요 |
| 패키지 업데이트 | `npm install` | 버전 범위 내 업데이트 |
| 정확한 버전으로 재설치 | `npm ci` | 환경 완전 초기화 |

**CI/CD 환경:**

| 환경 | 명령어 | 이유 |
|------|--------|------|
| Jenkins | `npm ci` | 재현 가능한 빌드, 빠르고 정확한 설치 |

**기타 상황:**

| 상황 | 명령어 | 이유 |
|------|--------|------|
| 배포 전 테스트 | `npm ci && npm test` | 정확한 환경 재현 |
| 문제 해결 (node_modules 오류) | `rm -rf node_modules && npm ci` | 완전 초기화 |
| 프로덕션 의존성만 설치 | `npm ci --only=production` | 용량 절약 |

### 의사결정 플로우차트

```
의존성 설치가 필요한가?
    ↓
로컬 개발 환경인가?
    ↓ Yes
패키지를 추가/변경하는가?
    ↓ Yes
    npm install <package>
    
    ↓ No
환경을 완전히 초기화하고 싶은가?
    ↓ Yes
    npm ci
    
    ↓ No
    npm install

로컬 개발 환경인가?
    ↓ No (CI/CD, 프로덕션)
    npm ci
```

---


## npm 버전 통일하기

### 문제: npm 버전 차이로 인한 lock 파일 변경

**상황:**

팀원들이 서로 다른 npm 버전을 사용하면, `npm install`만 실행해도 `package-lock.json`이 대폭 변경된다.

```bash
# 개발자 A (npm 8.x)
npm install
→ package-lock.json의 lockfileVersion: 2

# 개발자 B (npm 9.x)
npm install
→ package-lock.json의 lockfileVersion: 3
→ 전체 파일 구조 재작성
→ Git diff에서 수백~수천 줄 변경
```

**lockfileVersion 차이:**

| npm 버전 | lockfileVersion | 호환성 |
|----------|----------------|--------|
| npm 5.x - 6.x | 1 | npm 5+ |
| npm 7.x - 8.x | 2 | npm 7+ |
| npm 9.x+ | 3 | npm 9+ |

**문제 발생:**

```bash
# 개발자 A (npm 8.19.4) - 팀 표준
$ npm install
$ git diff package-lock.json
# 변경 없음 ✓

# 개발자 B (npm 10.2.0) - 최신 버전 사용
$ npm install
$ git diff package-lock.json
# 800줄 변경됨 ✗
```

### 해결 방법: .nvmrc로 Node.js 버전 통일

**.nvmrc 파일 생성:**

```bash
# 프로젝트 루트에 .nvmrc 파일 생성
echo "16.20.2" > .nvmrc
```

**Node.js 설치:**

```bash
# nvm으로 정확한 버전 설치
nvm install 16.20.2

# 해당 버전 사용
nvm use 16.20.2

# 또는 .nvmrc 기반 자동 전환
nvm use
```

**사용 방법:**

```bash
# 프로젝트 디렉토리로 이동
cd my-project

# .nvmrc 파일 확인
cat .nvmrc
# 16.20.2

# nvm으로 해당 버전 사용
nvm use

# 출력:
# Found '/path/to/project/.nvmrc' with version <16.20.2>
# Now using node v16.20.2 (npm v8.19.4)

# 버전 확인
node --version
# v16.20.2

npm --version
# 8.19.4
```

**팀원들에게 공유:**

```bash
# README.md에 추가
## 개발 환경 설정

1. nvm 설치: https://github.com/nvm-sh/nvm
2. Node.js 버전 설치 및 사용:
    nvm install 16.20.2
    nvm use 16.20.2
    # 또는
    nvm use
```

### 버전 통일 효과

**Before:**

```bash
$ git log --oneline package-lock.json
a1b2c3d Update package-lock.json (개발자 A, npm 8.x)
d4e5f6g Update package-lock.json (개발자 B, npm 9.x)
g7h8i9j Update package-lock.json (개발자 C, npm 10.x)
# 매 커밋마다 lock 파일 변경
```

**After:**

```bash
$ git log --oneline package-lock.json
a1b2c3d Add express dependency
d4e5f6g Add jest for testing
g7h8i9j Update lodash version
# 실제 의존성 변경 시에만 커밋
```

**측정 가능한 개선:**

```
Git 충돌 빈도: 주 5회 → 주 0회
PR 리뷰 시간: 평균 30분 → 10분 (lock 파일 diff 감소)
팀원 혼란: "왜 내 lock 파일이 달라요?" → 0건
```

---

## 주의 사항

### 1. npm ci 오류

**오류 메시지:**

```
npm ERR! The package-lock.json file was created with an old version of npm
npm ERR! npm ci can only install packages when your package.json and 
         package-lock.json or npm-shrinkwrap.json are in sync.
```

**원인:**
- package.json과 package-lock.json 불일치
- lock 파일이 오래됨

**해결:**

```bash
# 1. npm install로 동기화
npm install

# 2. lock 파일 커밋
git add package-lock.json
git commit -m "Sync package-lock.json"

# 3. 다시 npm ci 실행
npm ci
```

### 2. package-lock.json 수정 금지

**잘못된 방법:**

```bash
# 직접 수정 (절대 금지)
vi package-lock.json
```

**올바른 방법:**

```bash
# npm 명령어로만 수정
npm install
npm update
```

### 3. Git 커밋 규칙

**반드시 커밋:**

```bash
git add package.json package-lock.json
git commit -m "Add express dependency"
```

**커밋하지 않으면:**
- 팀원마다 다른 버전 설치
- CI/CD 실패
- 프로덕션 버그 위험

**.gitignore 설정:**

```
node_modules/       # 커밋 안 함
package.json        # 커밋함
package-lock.json   # 커밋함
```

### 4. CI/CD에서 npm install 사용 금지

**잘못된 예:**

```yaml
# Bad
- run: npm install
```

**문제:**
- package-lock.json 수정 가능
- 환경마다 다른 버전
- 느린 속도

**올바른 예:**

```yaml
# Good
- run: npm ci
```

### 5. 프로덕션 배포 시 devDependencies 제외

**개발 의존성 포함 (비효율):**

```bash
npm ci
```

**프로덕션 의존성만 (권장):**

```bash
npm ci --only=production
# 또는
npm ci --omit=dev
```

**효과:**

```
Before: 150MB (전체)
After: 50MB (프로덕션만)

용량 66% 절감!
```

---

## 요약

### 핵심 개념

| 개념 | 핵심 역할 |
|------|----------|
| **package.json** | 의존성 목록 정의 (버전 범위 포함) |
| **package-lock.json** | 정확한 버전, 위치, 해시 고정 |
| **npm install** | 유연하게 의존성 설치 (개발 환경) |
| **npm ci** | 빠르고 고정된 의존성 설치 (CI/CD 전용) |

### 빠른 참조

**명령어 치트시트:**

```bash
# 프로젝트 초기화
npm init
npm init -y

# 의존성 설치
npm install                          # package-lock.json 기반
npm install <package>                # 패키지 추가
npm install <package>@<version>      # 특정 버전 설치
npm install --save-dev <package>     # 개발 의존성 추가

# CI/CD 설치
npm ci                               # 정확한 버전 설치
npm ci --only=production             # 프로덕션만

# 업데이트
npm update                           # 버전 범위 내 업데이트
npm update <package>                 # 특정 패키지 업데이트
npm outdated                         # 오래된 패키지 확인

# 제거
npm uninstall <package>              # 패키지 제거

# 정리
npm cache clean --force              # 캐시 삭제
```

### 마지막으로

**의존성 관리의 핵심 원칙:**

1. **package-lock.json은 항상 Git에 커밋**
2. **로컬 개발은 npm install, CI/CD는 npm ci**
3. **프로덕션은 --only=production**
4. **package-lock.json 직접 수정 금지**
5. **팀 전체 npm 버전 통일 (.nvmrc + nvm 활용)**

올바른 의존성 관리는 **팀 협업의 생산성**과 **배포의 안정성**을 동시에 보장한다.

**"일관된 환경이 안정된 서비스를 만든다."**

---

## Reference

- [npm Documentation](https://docs.npmjs.com/)
- [npm ci - Official Docs](https://docs.npmjs.com/cli/v9/commands/npm-ci)
- [package.json Reference](https://docs.npmjs.com/cli/v9/configuring-npm/package-json)

