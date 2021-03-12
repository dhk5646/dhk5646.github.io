---
title: "[PostgreSQL] 리오그 작업"
categories: PostgreSQL
tags: PostgreSQL
toc: true
---

## Intro
디스크 용량이 임계치를 넘어서면서 서비스 이슈가 발생할 수 있다고 연락을 받았고 어떤 테이블에서 데이터가 많이 쌓여 있는지 확인 후 데이터를 지웠지만 디스크 용량이 줄어들지 않았고 DBA 에게 문의를 해보았는데 **리오그**라는 작업이 필요하다는 것을 알게 되었고 처리 방법을 정리한 내용을 기록으로 남깁니다.  


## 테이블별 사이즈 확인 

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
  
## 2. 리오그 작업

```java
# 본 테이블을 복사한다.
CREATE TABLE LBSCDB.LWPRT_DEVICE_LC_HIST_2 (LIKE LBSCDB.LWPRT_DEVICE_LC_HIST INCLUDING ALL);

# 본 테이블 데이터를 복사한다. 
INSERT INTO LBSCDB.LWPRT_DEVICE_LC_HIST_2 ( SELECT * FROM LBSCDB.LWPRT_DEVICE_LC_HIST);

# 본 테이블을 삭제한다.
DROP TABLE LWPRT_DEVICE_LC_HIST

# 임시 테이블명을 본 테이블 명으로 변경한다.
ALTER TABLE LWPRT_DEVICE_LC_HIST_2 RENAME TO LWPRT_DEVICE_LC_HIST;
```