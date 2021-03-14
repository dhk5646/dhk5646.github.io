---
title: "postgresql query 모음"
categories: PostgreSQL
tags: PostgreSQL
toc: true
---

## Intro
postgresql DB를 서비스를 운영하면서 사용한 쿼리들을 나중에 필요할 수 있어 기록합니다.


## 쿼리 모음

- 프로그램 갯수 조회

```java
SELECT * 
FROM TB_SM_PGM TSP
WHERE USE_YN = 'Y'
ORDER BY PGM_ID
```

- 테이블 조회

```java
SELECT c.relname
FROM pg_catalog.pg_namespace n 
join pg_catalog.pg_class c on c.relnamespace=n.oid 
WHERE n.nspname IN ('gtts')
AND c.relkind = 'r' 
ORDER BY relname
```

- 펑션 조회

```java
SELECT p.proname
FROM pg_catalog.pg_namespace n
JOIN pg_catalog.pg_proc p ON p.pronamespace = n.oid
WHERE n.nspname = 'gtts'
AND p.proname LIKE 'fn\_%' OR p.proname LIKE 'sp\_%'
ORDER BY proname

SELECT p.proname, *
FROM pg_catalog.pg_namespace n
JOIN pg_catalog.pg_proc p ON p.pronamespace = n.oid
WHERE n.nspname = 'gtts'
AND prosrc LIKE '%tn_rail_excel_info%'
```

- 테이블 사이즈 확인

```java
SELECT nspname || '.' || relname AS "relation",
    pg_size_pretty(pg_total_relation_size(C.oid)) AS "total_size"
  FROM pg_tables A, pg_class C
  LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
  WHERE nspname NOT IN ('pg_catalog', 'information_schema')
    AND C.relkind <> 'i'
    AND A.tablename = C.relname
--    AND A.tableowner = 'tacs'
    AND nspname !~ '^pg_toast'
    AND relname = 'th_load_info_hist'
  ORDER BY pg_total_relation_size(C.oid) DESC
```

- 실행중인 쿼리 확인 및 종료

```java
# 실행중인 쿼리확인
SELECT *
FROM pg_stat_activity
WHERE state = 'active'
-- AND current_timestamp - query_start > '3 min'  시간확인
ORDER BY 1 DESC;


#실행중인 쿼리 종료
SELECT pg_cancel_backend(pid);
```


- 통계테이블을 통한 과부하쿼리 확인 <br> (PG_STAT_STATEMENTS 테이블 사용하기 위해서는 파라메터 설정 필요) 

```java
SELECT round(total_time*1000)/1000 AS total_time,query
FROM PG_STAT_STATEMENTS
ORDER BY total_time DESC limit 5;
```

- 인덱스 생성

```java
CREATE INDEX th_load_info_shp_ix
ON gtts.TH_LOAD_INFO (SHP_CONFIRM_DT, CORP_GRP_ID,CORP_ID,LOAD_ID);

CREATE INDEX tb_load_result_gtms_load_id
ON gtts.tb_load_result_gtms (LOAD_ID);
```


-- 전체 컬럼 확인

```java
# ex) timestamptz 타입 확인
SELECT 	TABLE_NAME
	, 	COLUMN_NAME
	, 	DATA_TYPE
	, 	CHARACTER_MAXIMUM_LENGTH
	,	IS_NULLABLE
FROM     	information_schema.columns 
WHERE 	1=1
AND data_type = 'timestamp with time zone'  --timestamptz 타입
ORDER BY     ordinal_position
```

- 테이블 특정 컬럼타입 확인

```java
SELECT pg_typeof(POD_LT::varchar::UNKNOWN) from TN_CARRIER_INFO TCI
```

- 쿼리 실행계획 확인 

```java
EXPLAIN ANALYZE
SELECT * FROM TH_LOAD_INFO
WHERE ... (생략)
```

- Merge문

```java
INSERT INTO GTTS.TB_SM_USER(
	CORP_GRP_ID
	, CORP_ID
	, LOAD_ID
	, WP_ID
	, RECEIVE_TYPE
	, REGIST_DT
	, REGISTER_ID
	, UPDT_DT
	, UPDUSR_ID
)VALUES(
	#{corpGrpId}
	, #{corpId}
	, #{loadId}
	, #{wpId}
	, #{receiveType}
	, now()
	,'MOBILEUSER'
	, now()
	,'MOBILEUSER'
)ON CONFLICT(  -- PK 가 있을 경우 Update 하겠다.
	CORP_GRP_ID
	, CORP_ID
	, LOAD_ID
	, WP_ID
	, RECEIVE_TYPE
)DO
UPDATE
SET	RECEIVE_IMAGE = #{receiveImage}
	, UPDT_DT = now()
	, UPDUSR_ID = 'MOBILEUSER'
```

-- 테이블별 코멘트 확인

```java
SELECT n.nspname, c.relname, obj_description(c.oid)  
FROM pg_catalog.pg_class c inner join pg_catalog.pg_namespace n on c.relnamespace=n.oid 
WHERE c.relkind = 'r'
ORDER BY RELNAME
```