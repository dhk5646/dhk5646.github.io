---
title: "MySQL 후행 공백 처리 이슈 (Collation & Pad_attribute)"
categories: mysql
tags: [mysql, database, collation, troubleshooting]
excerpt: "MySQL에서 후행 공백으로 인한 Unique Key 중복 오류와 Collation의 Pad_attribute 설정 해결 방법"
---

## 들어가며

실무에서 가장 까다로운 버그는 **코드상으로는 아무 문제가 없어 보이는데, 데이터베이스에서만 오류가 발생하는 경우**다.

이번 글에서는 MySQL 8.x 환경에서 **후행 공백(trailing space)** 처리 방식으로 인해 **Unique Key 중복 오류가 발생했던 사례**를 정리한다.

---

## 문제 상황

데이터 저장 과정에서 다음과 같은 오류가 발생했다.

```
Duplicate entry '홍길동 -20' for key 'Users.uk_n_a'
```

- **환경**: MySQL 8.0.34
- **테이블**: Users
- **Unique Key**: `(name, age)`

### 상황 분석

Users 테이블의 Unique Key는 `name`과 `age` 조합으로 구성되어 있었다.

Java 애플리케이션에서 `Map<String, Object>`를 활용하여 중복을 제거하는 로직을 구현했음에도 불구하고, MySQL에서 Duplicate entry 오류가 발생했다.

데이터를 확인해보니 다음과 같은 상황이었다:

| 이름 | 나이 |
|------|------|
| `'홍길동'` | 20 |
| `'홍길동 '` (후행 공백 포함) | 20 |

**문제의 핵심:**
- Java Map에서는 `'홍길동'`과 `'홍길동 '`을 **서로 다른 키**로 인식
- MySQL에서는 두 값을 **동일한 값**으로 인식하여 Unique Key 제약 위반

---

## 원인 분석

### 왜 '홍길동'과 '홍길동 '을 동일하게 인식했을까?

MySQL에서 문자열 비교 방식은 해당 컬럼의 **Collation(콜레이션)**과 **Pad_attribute** 설정에 따라 달라진다.

---

## Collation이란?

**Collation**은 데이터베이스에서 **문자열의 정렬 및 비교 규칙**을 정의하는 설정이다.

쉽게 말하면, "문자열을 어떤 기준으로 정렬하고 비교할지"를 결정한다.

### Collation이 결정하는 것들

1. **대소문자 구분 여부**
   - `'A'`와 `'a'`를 동일하게 볼지, 다르게 볼지

2. **후행 공백 처리**
   - `'ABC'`와 `'ABC '`를 동일하게 볼지, 다르게 볼지

3. **문자 정렬 순서**
   - 언어별 정렬 규칙 (한글, 영어, 일본어 등)

### MySQL Collation 네이밍 규칙

```
utf8mb4_general_ci
  ↑       ↑      ↑
  │       │      └─ ci (case insensitive: 대소문자 구분 안함)
  │       └──────── general (일반적인 정렬 규칙)
  └──────────────── utf8mb4 (문자 집합)
```

**주요 Collation 접미사:**
- `_ci` (case insensitive): 대소문자 구분 안함
- `_cs` (case sensitive): 대소문자 구분
- `_bin` (binary): 바이너리 비교 (바이트 단위로 정확히 비교)

---

## Pad_attribute란?

MySQL 8.0부터 Collation에는 **후행 공백 처리 방식**을 결정하는 `Pad_attribute`가 추가되었다.

이 속성은 문자열 비교에서 **후행 공백을 무시할지, 포함할지**를 설정한다.

### Pad_attribute의 두 가지 값

#### 1. PAD SPACE

후행 공백을 **무시**하고 비교한다.

```sql
-- PAD SPACE Collation 사용 시
SELECT 'ABC' = 'ABC ' AS result;
-- 결과: 1 (같음)

SELECT 'ABC' = 'ABC  ' AS result;
-- 결과: 1 (같음)
```

**예시: utf8mb4_general_ci**
```sql
SELECT 'ABC' COLLATE utf8mb4_general_ci = 'ABC ' AS result;
-- 결과: 1 (같음)
```

#### 2. NO PAD

후행 공백을 **포함**하여 비교한다.

```sql
-- NO PAD Collation 사용 시
SELECT 'ABC' = 'ABC ' AS result;
-- 결과: 0 (다름)

SELECT 'ABC' = 'ABC  ' AS result;
-- 결과: 0 (다름)
```

**예시: utf8mb4_0900_bin**
```sql
SELECT 'ABC' COLLATE utf8mb4_0900_bin = 'ABC ' AS result;
-- 결과: 0 (다름)
```

---

## 문제 재현

문제가 발생한 `name` 컬럼은 **PAD SPACE** 속성을 가진 Collation을 사용하고 있어서, 후행 공백을 무시하고 비교했다.

따라서 `'홍길동'`과 `'홍길동 '`를 **동일한 값**으로 취급한 것이다.

### 재현 쿼리

나이가 다른 홍길동이 여러 명 존재한다고 가정하고 쿼리를 실행해보자:

```sql
SELECT * 
FROM Users
WHERE name = '홍길동       '; -- 후행 공백 포함
```

**결과:**
```
+----+----------+-----+
| id | name     | age |
+----+----------+-----+
|  1 | 홍길동   |  20 |
|  2 | 홍길동   |  25 |  -- 실제로는 '홍길동 ' (후행 공백 포함)
|  3 | 홍길동   |  30 |
+----+----------+-----+
```

위 쿼리에서 `name`이 `'홍길동'`과 `'홍길동 '` (후행 공백 포함) 모두 조회되는 것을 확인할 수 있다.

### Collation 확인

현재 테이블의 Collation 설정을 확인할 수 있다:

```sql
-- 테이블의 기본 Collation 확인
SHOW TABLE STATUS WHERE Name = 'Users';

-- 특정 컬럼의 Collation 확인
SHOW FULL COLUMNS FROM Users WHERE Field = 'name';
```

**결과 예시:**
```
+-----------+--------------+--------------------+------+
| Field     | Type         | Collation          | Null |
+-----------+--------------+--------------------+------+
| name      | varchar(255) | utf8mb4_general_ci | NO   |
+-----------+--------------+--------------------+------+
```

### Collation의 Pad_attribute 확인

```sql
SELECT COLLATION_NAME, PAD_ATTRIBUTE
FROM INFORMATION_SCHEMA.COLLATIONS
WHERE COLLATION_NAME = 'utf8mb4_general_ci';
```

**결과:**
```
+--------------------+---------------+
| COLLATION_NAME     | PAD_ATTRIBUTE |
+--------------------+---------------+
| utf8mb4_general_ci | PAD SPACE     |
+--------------------+---------------+
```

---

## 해결 방법

후행 공백을 **포함하여 비교**하도록 설정하려면, **NO PAD** 속성을 가진 Collation으로 변경해야 한다.

### 1. 컬럼의 Collation 변경

```sql
ALTER TABLE Users 
MODIFY name VARCHAR(255) COLLATE utf8mb4_0900_bin;
```

### 2. 주요 NO PAD Collation 목록

| Collation | 특징 |
|-----------|------|
| `utf8mb4_0900_bin` | 바이너리 비교, 대소문자 구분, NO PAD |
| `utf8mb4_0900_as_cs` | Accent Sensitive, Case Sensitive, NO PAD |
| `utf8mb4_bin` | 바이너리 비교 (MySQL 5.x 호환) |

### 3. 변경 후 확인

```sql
-- Collation 변경 확인
SHOW FULL COLUMNS FROM Users WHERE Field = 'name';

-- 후행 공백 비교 테스트
SELECT 'ABC' COLLATE utf8mb4_0900_bin = 'ABC ' AS result;
-- 결과: 0 (다름)
```

### 4. 데이터 정리

Collation을 변경하기 전에, 기존 데이터에서 후행 공백을 제거하는 것이 좋다:

```sql
-- 후행 공백이 있는 데이터 확인
SELECT id, name, LENGTH(name) AS len, CHAR_LENGTH(name) AS char_len
FROM Users
WHERE name != TRIM(name);

-- 후행 공백 제거
UPDATE Users
SET name = TRIM(name)
WHERE name != TRIM(name);
```

---

## 주의사항

### 1. 성능 영향

`utf8mb4_0900_bin`과 같은 바이너리 Collation은 **인덱스 활용도가 높아** 일부 쿼리에서 성능이 향상될 수 있다.

하지만 **대소문자를 구분**하므로, 기존 쿼리가 대소문자를 무시하고 검색하던 경우 동작이 달라질 수 있다.

### 2. 기존 데이터 영향

Collation을 변경하면 **기존 Unique Key 제약 조건**에 영향을 줄 수 있다.

예를 들어:
- 기존: `'ABC'`와 `'abc'`가 중복으로 처리됨 (case insensitive)
- 변경 후: `'ABC'`와 `'abc'`가 별개의 값으로 처리됨 (case sensitive)

따라서 변경 전에 **중복 데이터가 발생하지 않는지** 반드시 확인해야 한다:

```sql
-- 대소문자만 다른 중복 데이터 확인
SELECT name, age, COUNT(*)
FROM Users
GROUP BY BINARY name, age
HAVING COUNT(*) > 1;
```

### 3. 애플리케이션 영향

Java, Python 등 애플리케이션 코드에서 문자열 비교 로직도 함께 검토해야 한다.

데이터베이스와 애플리케이션의 **문자열 비교 방식이 일치**해야 예상치 못한 버그를 방지할 수 있다.

---

## MySQL 공식 문서

MySQL 8.0부터 Collation에 Pad_attribute가 추가되었으며, 공식 문서에서 다음과 같이 설명하고 있다:

> **PAD SPACE and NO PAD Collations**
> 
> Collation pad attributes determine treatment for comparison of trailing spaces at the end of strings.
> 
> - **PAD SPACE** collations treat spaces at the end of strings as insignificant for string comparisons.
> - **NO PAD** collations treat spaces at the end of strings as significant for string comparisons.

**참고 링크:**
- [MySQL 8.0 Collation Pad Attribute](https://dev.mysql.com/doc/refman/8.0/en/charset-collation-effect.html)
- [MySQL 8.0 Collations](https://dev.mysql.com/doc/refman/8.0/en/charset-collations.html)

---

## 마무리

### 교훈

1. **데이터베이스의 Collation 설정**은 단순히 정렬 규칙만 결정하는 것이 아니라, **데이터 무결성**에도 영향을 준다.

2. **후행 공백 처리 방식**은 Unique Key, 중복 검사, 문자열 비교 등 다양한 상황에 영향을 미친다.

3. MySQL 8.0부터 도입된 **Pad_attribute**를 이해하고, 프로젝트 요구사항에 맞는 Collation을 선택해야 한다.

### 권장 사항

- 새 프로젝트에서는 **NO PAD Collation** 사용을 권장한다.
- `utf8mb4_0900_bin` 또는 `utf8mb4_0900_as_cs`를 고려한다.
- 데이터 입력 시 **애플리케이션 단에서 TRIM 처리**를 추가하는 것도 좋은 방법이다.

```java
// Java 예시
String name = input.trim(); // 후행 공백 제거
```

---

## Reference

- [MySQL 8.0 Reference Manual - Collation Pad Attribute](https://dev.mysql.com/doc/refman/8.0/en/charset-collation-effect.html)
- [MySQL 8.0 Reference Manual - Collation Naming Conventions](https://dev.mysql.com/doc/refman/8.0/en/charset-collation-names.html)
- [Understanding MySQL Collations](https://stackoverflow.com/questions/367711/what-is-the-best-collation-to-use-for-mysql-with-php)

