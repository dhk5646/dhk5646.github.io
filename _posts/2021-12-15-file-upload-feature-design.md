---
title: "실무에서 배운 파일 업로드 기능 설계"
categories: java
tags: [file-upload, design, architecture, transaction, consistency]
excerpt: "파일 업로드는 단순 기능이 아니라, 정합성과 운영 비용을 함께 설계해야 하는 영역이다"
---

## 들어가며

파일 업로드 기능을 처음 구현할 때는 간단하다고 생각했다.

"파일을 받아서 저장하면 되지 않나?"

하지만 실무에서 파일 업로드를 구현하면서, 단순히 파일을 저장하는 것 이상의 고민이 필요하다는 것을 깨달았다.

이 글에서는 **공지사항 첨부파일 기능을 설계하고 구현하며 고민했던 내용**을 정리한다.

---

## 1. 파일 업로드 설계 개요

### 전체 흐름 (공지사항 예시)

**시나리오: 첨부파일이 포함된 공지사항 작성**

```
[사용자가 첨부파일 버튼 클릭]
  ↓
파일 다이얼로그에서 파일 선택
  ↓
━━━━━━━━━━━━━━━━━━━━━━━
1단계: 파일 임시 저장 API
━━━━━━━━━━━━━━━━━━━━━━━
파일 검증
  ↓
스토리지 업로드
  ↓
DB에 TEMP 상태로 저장
  ↓
fileGroupId 응답
━━━━━━━━━━━━━━━━━━━━━━━
  ↓
[사용자가 공지사항 내용 작성]
  ↓
[공지사항 등록 버튼 클릭]
  ↓
━━━━━━━━━━━━━━━━━━━━━━━
2단계: 공지사항 저장 API
━━━━━━━━━━━━━━━━━━━━━━━
@Transactional 시작
  ↓
공지사항 엔티티 저장
  ↓
파일 상태 TEMP → SUCCESS
  ↓
트랜잭션 커밋
━━━━━━━━━━━━━━━━━━━━━━━
```

### 핵심: 임시저장 → 확정 2단계 분리

**1단계: 파일 임시 저장 (TEMP)**
- 스토리지 업로드 (외부 시스템)
- DB에 TEMP 저장 (별도 트랜잭션)
- 실패 시 즉시 피드백

**2단계: 글 저장 시 확정 (SUCCESS)**
- 공지사항 저장 + 파일 상태 변경
- **단일 DB 트랜잭션**으로 처리

**영속성 경계:**
- 1단계: 스토리지와 DB가 각각 독립
- 2단계: DB 작업만 하나의 트랜잭션으로 묶음

---

## 2. 트랜잭션과 정합성 문제

### 문제 인식

파일 업로드의 가장 큰 문제는 **스토리지 업로드와 DB 저장이 서로 다른 영속성 영역**이라는 점이다.

만약 공지사항 저장 시 파일을 함께 업로드한다면:
- 파일 업로드 성공 → 공지사항 저장 실패 → 고아 파일 발생
- 대용량 파일을 다시 업로드해야 함 (UX 저하)
- DB 커넥션을 오래 잡고 있어 리소스 낭비

### 하나의 트랜잭션으로 묶으려 할 때의 난관

**1. 트랜잭션 생명 주기 문제**
- 파일 업로드는 네트워크 상태에 따라 시간이 오래 걸림
- DB 커넥션을 파일 업로드 동안 잡고 있으면 리소스 고갈

**2. 원자성 확보의 어려움**
- 이기종 시스템(스토리지 + DB) 간 완전한 트랜잭션(2PC) 구현은 복잡하고 비용이 큼

**3. 브라우저 메모리 부하**
- 대용량 파일을 메모리에 보유하면 브라우저 성능 저하

### 해결 방향: 임시저장 → 확정 방식

나의 상황에서는 하나의 트랜잭션으로 묶는 것보다 분리하는 것이 **성능과 가용성** 면에서 훨씬 유리하다고 판단했다.

그래서 **임시저장 → 확정 방식으로 설계**하였다.

**선택 이유:**

데이터 무결성과 사용자 경험(UX) 측면에서 이점이 있다고 생각했다.

**이 설계의 장점:**

| 구분 | 설명 |
|------|------|
| **사용자 경험** | 게시글을 쓰는 동안 백그라운드에서 파일이 올라가므로, 등록 버튼 클릭 시 대기 시간 최소화 |
| **안정성** | 대용량 파일 업로드 중 오류가 나도 게시글 본문 데이터는 안전함 |
| **확장성** | 파일 서버와 API 서버를 분리하기 쉬움 (브라우저 → S3 직접 업로드) |
| **리소스 효율** | DB 트랜잭션은 짧게 유지되어 커넥션 풀 고갈 방지 |

---

## 3. FileStorage 인터페이스 설계

### 목적

**확장성:**
- 스토리지 교체 용이 (Local → S3 → NAS)
- 테스트 환경 분리

### 인터페이스

```java
public interface FileStorage {
    
    /**
     * 파일 업로드
     */
    void upload(InputStream input, String directory, String fileName) 
        throws IOException;
    
    /**
     * 파일 삭제
     */
    void delete(String directory, String fileName) 
        throws IOException;
    
    /**
     * 파일 URL 생성
     */
    String resolveUrl(String directory, String fileName);
    
    /**
     * 파일 다운로드 스트림
     */
    InputStream download(String directory, String fileName) 
        throws IOException;
}
```

### 구현체 예시

**LocalFileStorage:**
```java
@Component
@Profile("local")
public class LocalFileStorage implements FileStorage {
    
    @Value("${file.upload.path}")
    private String basePath;
    
    @Override
    public void upload(InputStream input, String directory, String fileName) 
            throws IOException {
        Path path = Paths.get(basePath, directory, fileName);
        Files.createDirectories(path.getParent());
        Files.copy(input, path, StandardCopyOption.REPLACE_EXISTING);
    }
    
    @Override
    public void delete(String directory, String fileName) throws IOException {
        Path path = Paths.get(basePath, directory, fileName);
        Files.deleteIfExists(path);
    }
    
    @Override
    public String resolveUrl(String directory, String fileName) {
        return "/files/" + directory + "/" + fileName;
    }
    
    @Override
    public InputStream download(String directory, String fileName) 
            throws IOException {
        Path path = Paths.get(basePath, directory, fileName);
        return Files.newInputStream(path);
    }
}
```

**S3FileStorage:**
```java
@Component
@Profile("prod")
public class S3FileStorage implements FileStorage {
    
    private final AmazonS3 s3Client;
    private final String bucketName;
    
    @Override
    public void upload(InputStream input, String directory, String fileName) 
            throws IOException {
        String key = directory + "/" + fileName;
        ObjectMetadata metadata = new ObjectMetadata();
        s3Client.putObject(bucketName, key, input, metadata);
    }
    
    @Override
    public String resolveUrl(String directory, String fileName) {
        String key = directory + "/" + fileName;
        // Presigned URL 생성 (1시간 유효)
        Date expiration = new Date(System.currentTimeMillis() + 3600000);
        return s3Client.generatePresignedUrl(bucketName, key, expiration).toString();
    }
    
    // ...
}
```

---

## 4. FileValidator 인터페이스 설계

### 설계 의도

도메인마다 요구하는 파일 정책이 다르다 (사이즈, 형식, 개수 등).
Strategy 패턴으로 검증 로직을 독립적으로 관리하도록 설계했다.

### 인터페이스

```java
public interface FileValidator {
    
    /**
     * 파일 업로드 상태 검증
     */
    UploadState validateUploadState(MultipartFile file);
}
```

### UploadState Enum

```java
public enum UploadState {
    SUCCESS("성공"),
    TEMP("임시 업로드"),
    INVALID_TYPE("지원하지 않는 파일 형식"),
    SIZE_EXCEEDED("파일 크기 초과"),
    INVALID_NAME("잘못된 파일명"),
    EMPTY_FILE("빈 파일"),
    DELETED("삭제됨");
    
    private final String message;
    
    UploadState(String message) {
        this.message = message;
    }
    
    public boolean isSuccess() {
        return this == SUCCESS;
    }
    
    public String getMessage() {
        return message;
    }
}
```

### 도메인별 검증 구현

**공지사항 검증:**
```java
@Component
public class NoticeFileValidator implements FileValidator {
    
    private static final long MAX_SIZE = 2L * 1024 * 1024; // 2MB
    private static final Set<String> ALLOWED_TYPES = Set.of(
        "image/jpeg", "image/png"
    );
    
    @Override
    public UploadState validateUploadState(MultipartFile file) {
        if (file.isEmpty()) {
            return UploadState.EMPTY_FILE;
        }
        
        String contentType = file.getContentType();
        if (contentType == null || !ALLOWED_TYPES.contains(contentType)) {
            return UploadState.INVALID_TYPE;
        }
        
        if (file.getSize() > MAX_SIZE) {
            return UploadState.SIZE_EXCEEDED;
        }
        
        return UploadState.SUCCESS;
    }
}
```

**프로필 검증:**
```java
@Component
public class ProfileFileValidator implements FileValidator {
    
    private static final long MAX_SIZE = 5L * 1024 * 1024; // 5MB
    private static final Set<String> ALLOWED_TYPES = Set.of(
        "image/jpeg", "image/png", "image/gif", "image/webp"
    );
    
    @Override
    public UploadState validateUploadState(MultipartFile file) {
        if (file.isEmpty()) {
            return UploadState.EMPTY_FILE;
        }
        
        String contentType = file.getContentType();
        if (contentType == null || !ALLOWED_TYPES.contains(contentType)) {
            return UploadState.INVALID_TYPE;
        }
        
        if (file.getSize() > MAX_SIZE) {
            return UploadState.SIZE_EXCEEDED;
        }
        
        return UploadState.SUCCESS;
    }
}
```

---

## 5. 상세 구현

### 1단계: 파일 임시 저장

```java
@Service
@RequiredArgsConstructor
public class FileUploadService {
    
    private final FileStorage fileStorage;
    private final UploadFileRepository uploadFileRepository;
    private final FileValidator fileValidator;
    
    /**
     * 파일 선택 시 즉시 업로드 (임시 상태)
     */
    @Transactional
    public FileUploadResponse uploadTemp(
            String refTable,
            List<MultipartFile> files) {
        
        String fileGroupId = FileGroupIdUtil.generate();
        List<UploadFile> uploadedFiles = new ArrayList<>();
        
        for (MultipartFile file : files) {
            // 1. 파일 검증
            UploadState state = fileValidator.validateUploadState(file);
            if (!state.isSuccess()) {
                throw new InvalidFileException(state.getMessage());
            }
            
            // 2. 스토리지 업로드
            String saveFileName = generateSaveFileName(file);
            String directory = buildDirectory(refTable, fileGroupId);
            
            try {
                fileStorage.upload(
                    file.getInputStream(), 
                    directory, 
                    saveFileName
                );
            } catch (IOException e) {
                throw new FileUploadException("파일 업로드 실패", e);
            }
            
            // 3. DB에 TEMP 상태로 저장
            UploadFile uploadFile = UploadFile.of(
                refTable,
                fileGroupId,
                directory,
                file.getOriginalFilename(),
                saveFileName,
                file.getSize(),
                file.getContentType()
            );
            uploadFile.setUploadState(UploadState.TEMP);
            
            uploadFileRepository.save(uploadFile);
            uploadedFiles.add(uploadFile);
        }
        
        return FileUploadResponse.of(fileGroupId, uploadedFiles);
    }
    
    private String generateSaveFileName(MultipartFile file) {
        String extension = getExtension(file.getOriginalFilename());
        return System.currentTimeMillis() + "_" + 
               UUID.randomUUID().toString() + extension;
    }
    
    private String buildDirectory(String refTable, String fileGroupId) {
        LocalDate now = LocalDate.now();
        return String.format("%s/%d/%02d/%02d/%s",
            refTable,
            now.getYear(),
            now.getMonthValue(),
            now.getDayOfMonth(),
            fileGroupId
        );
    }
}
```

**실패 시:**
- 사용자에게 즉시 에러 응답
- 사용자는 파일을 다시 선택하여 재시도

### 2단계: 공지사항 저장 + 파일 상태 확정

```java
@Service
@RequiredArgsConstructor
public class NoticeService {
    
    private final NoticeRepository noticeRepository;
    private final UploadFileRepository uploadFileRepository;
    
    /**
     * 공지사항 저장 + 파일 상태 확정
     */
    @Transactional
    public void saveNotice(NoticeRequest request) {
        // 1. 공지사항 저장
        Notice notice = Notice.of(request.getTitle(), request.getContent());
        noticeRepository.save(notice);
        
        // 2. 파일 상태를 TEMP → SUCCESS로 변경
        if (request.getFileGroupId() != null) {
            uploadFileRepository.updateStateByFileGroupId(
                request.getFileGroupId(),
                UploadState.TEMP,
                UploadState.SUCCESS
            );
        }
    }
}
```

**Repository 메서드:**

```java
@Repository
public interface UploadFileRepository extends JpaRepository<UploadFile, Long> {
    
    @Modifying
    @Query("UPDATE UploadFile f " +
           "SET f.uploadState = :newState, f.updatedAt = CURRENT_TIMESTAMP " +
           "WHERE f.fileGroupId = :fileGroupId AND f.uploadState = :oldState")
    int updateStateByFileGroupId(
        @Param("fileGroupId") String fileGroupId,
        @Param("oldState") UploadState oldState,
        @Param("newState") UploadState newState
    );
    
    List<UploadFile> findByUploadStateAndCreatedAtBefore(
        UploadState uploadState, 
        LocalDateTime createdAt
    );
}
```

**핵심:**
- 1단계 실패: 파일만 다시 업로드
- 2단계 실패: 공지사항만 재시도 (파일은 이미 업로드됨)

### 이 방식을 선택한 이유

**데이터 무결성과 사용자 경험(UX) 측면에서 이점이 있다고 생각했다.**

**UX 관점:**
- 대용량 파일 업로드 후 글 저장 실패 시, 파일은 이미 업로드되어 있어 글만 재시도하면 됨

**트랜잭션 경계 분리:**
- 파일 업로드: 스토리지 작업 (통제 불가능)
- 공지사항 저장: DB 작업만 (통제 가능)

**실패 확률 최소화:**
- 글 저장 시점에는 DB 작업만 수행 (빠르고 안정적)

### TEMP/DELETED 파일 정리 전략

**상황 1: 파일만 첨부하고 글을 저장하지 않은 경우 (TEMP)**

**상황 2: 사용자가 게시글 수정 중 첨부파일을 삭제한 경우 (DELETED)**

**상황 3: 원본 글(공지사항)을 삭제한 경우 (연결된 파일 정리)**

이 모든 상황에서 스토리지에는 파일이 남아있지만, 실제로는 사용되지 않는 파일이다.

```java
@Component
@RequiredArgsConstructor
public class FileCleanupScheduler {
    
    private final UploadFileRepository uploadFileRepository;
    private final FileStorage fileStorage;
    
    /**
     * 불필요한 파일 일괄 정리
     */
    @Scheduled(cron = "0 0 3 * * *") // 매일 새벽 3시
    public void cleanupOrphanFiles() {
        LocalDateTime threshold = LocalDateTime.now().minusHours(24);
        
        // 1. TEMP 파일 정리 (24시간 이상 확정되지 않은 파일)
        List<UploadFile> tempFiles = uploadFileRepository
            .findByUploadStateAndCreatedAtBefore(UploadState.TEMP, threshold);
        cleanupFiles(tempFiles, "TEMP");
        
        // 2. DELETED 파일 정리 (24시간 이상 지난 삭제 파일)
        List<UploadFile> deletedFiles = uploadFileRepository
            .findByUploadStateAndUpdatedAtBefore(UploadState.DELETED, threshold);
        cleanupFiles(deletedFiles, "DELETED");
        
        // 3. 원본 글이 삭제된 경우의 파일 정리
        cleanupFilesWithDeletedNotice();
    }
    
    /**
     * 공통 파일 정리 로직
     */
    private void cleanupFiles(List<UploadFile> files, String type) {
        for (UploadFile file : files) {
            try {
                // 스토리지에서 삭제
                fileStorage.delete(file.getDirectory(), file.getSaveFileName());
                
                // DB에서 물리 삭제
                uploadFileRepository.delete(file);
                
                log.info("{} 파일 정리 완료: id={}, fileName={}", 
                    type, file.getId(), file.getSaveFileName());
                    
            } catch (Exception e) {
                log.error("{} 파일 정리 실패: id={}, fileName={}", 
                    type, file.getId(), file.getSaveFileName(), e);
            }
        }
        
        log.info("{} 파일 정리 작업 완료: {}개 처리", type, files.size());
    }
    
    /**
     * 원본 글이 삭제된 경우의 파일 정리
     * (notice 테이블에 존재하지 않는 공지사항의 파일들)
     */
    private void cleanupFilesWithDeletedNotice() {
        // SUCCESS 상태이지만 원본 공지사항이 없는 파일 조회
        List<UploadFile> orphanFiles = uploadFileRepository
            .findOrphanFilesByRefTable("notice");
        
        for (UploadFile file : orphanFiles) {
            try {
                // 스토리지에서 삭제
                fileStorage.delete(file.getDirectory(), file.getSaveFileName());
                
                // DB에서 물리 삭제
                uploadFileRepository.delete(file);
                
                log.info("원본 글 삭제된 파일 정리 완료: id={}, fileName={}", 
                    file.getId(), file.getSaveFileName());
                    
            } catch (Exception e) {
                log.error("원본 글 삭제된 파일 정리 실패: id={}, fileName={}", 
                    file.getId(), file.getSaveFileName(), e);
            }
        }
        
        log.info("원본 글 삭제된 파일 정리 작업 완료: {}개 처리", orphanFiles.size());
    }
}
```

**Repository 메서드 추가:**

```java
@Repository
public interface UploadFileRepository extends JpaRepository<UploadFile, Long> {
    
    // ...existing code...
    
    /**
     * TEMP 파일 조회 (생성 시간 기준)
     */
    List<UploadFile> findByUploadStateAndCreatedAtBefore(
        UploadState uploadState, 
        LocalDateTime createdAt
    );
    
    /**
     * DELETED 파일 조회 (수정 시간 기준)
     */
    List<UploadFile> findByUploadStateAndUpdatedAtBefore(
        UploadState uploadState, 
        LocalDateTime updatedAt
    );
    
    /**
     * 원본 글이 삭제된 고아 파일 조회
     * (notice 테이블에 존재하지 않는 파일)
     */
    @Query("SELECT f FROM UploadFile f " +
           "WHERE f.refTable = :refTable " +
           "AND f.uploadState = 'SUCCESS' " +
           "AND NOT EXISTS (" +
           "    SELECT 1 FROM Notice n WHERE n.fileGroupId = f.fileGroupId" +
           ")")
    List<UploadFile> findOrphanFilesByRefTable(@Param("refTable") String refTable);
}
```

**정리 정책:**

| 상태 | 기준 시간 | 정리 대상 | 조건 |
|------|-----------|-----------|------|
| TEMP | created_at | 파일만 업로드되고 글 저장 안 됨 | 24시간 이상 |
| DELETED | updated_at | 사용자가 첨부파일 삭제 | 24시간 이상 |
| SUCCESS | - | 원본 글(공지사항)이 삭제됨 | 원본 미존재 |

**왜 24시간인가?**
- 사용자가 글을 작성하다가 중단한 경우를 고려
- 다음 날 이어서 작성할 가능성 제공
- 24시간 후에는 작성 의도가 없다고 판단

**원본 글 삭제 시 즉시 처리 vs 배치 처리:**

나는 배치 처리 방식을 선택했다.

- **즉시 처리**: 원본 글 삭제 시 파일도 함께 삭제 (트랜잭션 묶음)
- **배치 처리**: 원본 글 삭제는 빠르게 처리, 파일은 스케줄러가 정리

**배치 처리를 선택한 이유:**
- 공지사항 삭제 트랜잭션에 스토리지 삭제 작업을 포함하지 않음
- 스토리지 장애 시에도 공지사항 삭제는 성공
- 스케줄러가 일괄 처리하여 효율적

**상황 4: 사용자가 첨부파일을 직접 삭제**

```java
@Service
@RequiredArgsConstructor
public class FileDeleteService {
    
    private final UploadFileRepository uploadFileRepository;
    private final FileStorage fileStorage;
    
    @Transactional
    public void deleteFile(Long fileId) {
        UploadFile file = uploadFileRepository.findById(fileId)
            .orElseThrow(() -> new FileNotFoundException("파일을 찾을 수 없습니다"));
        
        // 스토리지에서 삭제 시도
        try {
            fileStorage.delete(file.getDirectory(), file.getSaveFileName());
        } catch (Exception e) {
            log.warn("스토리지 파일 삭제 실패 (배치에서 재시도): {}", file.getId());
        }
        
        // DB 상태를 DELETED로 변경 (논리 삭제)
        file.setUploadState(UploadState.DELETED);
        uploadFileRepository.save(file);
    }
}
```

**핵심:**
- 스토리지 삭제 실패해도 DB는 DELETED로 변경
- 스케줄러가 24시간 후 재시도하여 정합성 확보

### 이 방식의 장단점

**장점:**
- 재시도에 강함 (파일은 이미 업로드되어 있음)
- 사용자 경험 우수 (대용량 파일도 한 번만 업로드)
- 장애 영향 범위 최소화 (트랜잭션 경계가 명확)
- 정합성 확보 (TEMP/DELETED/원본 삭제된 파일 모두 배치로 정리)
- 스토리지 장애 시에도 DB 작업은 성공

**단점:**
- 상태 관리 필요 (TEMP, SUCCESS, DELETED)
- 배치 작업 필요 (고아 파일 정리)
- 일시적으로 고아 파일 존재 가능 (최종 일관성)

---

## 6. 테이블 구조 설계

### DDL

```sql
CREATE TABLE upload_file (
    id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    ref_table VARCHAR(64) NOT NULL COMMENT '참조 테이블명 (notice, user_profile, board 등)',
    file_group_id VARCHAR(64) NOT NULL COMMENT '파일 그룹 ID',
    directory VARCHAR(512) COMMENT '디렉토리',
    original_file_name VARCHAR(255) COMMENT '원본 파일명',
    save_file_name VARCHAR(255) NOT NULL COMMENT '저장 파일명',
    upload_state VARCHAR(32) COMMENT '업로드 상태',
    size BIGINT COMMENT '파일 크기(byte)',
    content_type VARCHAR(128) COMMENT 'Content-Type',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_upload_file_file_group_id 
    ON upload_file(file_group_id);

CREATE INDEX idx_upload_file_ref_table 
    ON upload_file(ref_table);

CREATE INDEX idx_upload_file_state_created 
    ON upload_file(upload_state, created_at);
```

**핵심 필드:**
- `ref_table`: 어떤 테이블에서 사용 중인 파일인지 구분
- `file_group_id`: 여러 파일을 논리적으로 묶음
- `directory`: 전체 디렉토리 경로 저장
- `upload_state`: 업로드 상태 추적 (TEMP, SUCCESS, DELETED)

**ref_table 예시:**
- `notice`: 공지사항 첨부파일
- `user_profile`: 사용자 프로필 이미지
- `board`: 게시판 첨부파일
- `product`: 상품 이미지

---

## 7. 업로드 디렉터리 구조

### 경로 패턴

```
/{env}/{refTable}/{yyyy}/{MM}/{dd}/{fileGroupId}/{saveFileName}
```

**예시:**
```
/prod/notice/2023/06/15/a1b2c3d4-e5f6-7890/1686825600000_abc123.jpg
/prod/user_profile/2023/06/15/b2c3d4e5-f6a7-8901/1686825700000_def456.png
/prod/board/2023/06/16/c3d4e5f6-a7b8-9012/1686912000000_ghi789.pdf
```

### 장점

**1. 테이블별 파일 관리**
- 참조 테이블별로 파일 분리 저장
- 특정 테이블의 파일만 빠르게 조회/관리
- 파일과 엔티티의 명확한 연관 관계

**2. 날짜 기반 파티셔닝**
- 파일 시스템 부하 분산
- 특정 날짜 파일 빠른 접근

**3. 검색/정리 용이**
- 대량 파일에서도 효율적 관리
- 테이블별 정리 정책 차등 적용 가능

---

## 8. FileGroupId 설계

### 역할

- 여러 파일을 하나의 논리 단위로 묶음
- 클라이언트 재시도 시 멱등성 보장
- 파일 관리 및 삭제 단위

### FileGroupIdUtil 구현

```java
public final class FileGroupIdUtil {
    
    private static final Pattern ALLOWED = 
        Pattern.compile("^[A-Za-z0-9\\-_.]{1,64}$");
    
    private FileGroupIdUtil() {
        throw new AssertionError("유틸리티 클래스는 인스턴스화할 수 없습니다");
    }
    
    /**
     * fileGroupId 보장
     * - null이거나 비어있으면 새로 생성
     * - 유효하지 않은 형식이면 새로 생성
     * - 유효하면 그대로 사용
     */
    public static String ensure(String fileGroupId) {
        if (fileGroupId == null || fileGroupId.isBlank()) {
            return generate();
        }
        
        String trimmed = fileGroupId.trim();
        if (!ALLOWED.matcher(trimmed).matches()) {
            return generate();
        }
        
        return trimmed;
    }
    
    /**
     * 새 fileGroupId 생성
     */
    public static String generate() {
        return UUID.randomUUID().toString();
    }
}
```

---

## 9. 정리

### 핵심 요약

**구조는 단순:**
```
검증 → 임시저장 → 확정
```

**확장은 유연:**
- 검증: FileValidator 인터페이스
- 스토리지: FileStorage 인터페이스

**가장 중요했던 포인트:**
- **정합성**: 임시저장 → 확정 방식으로 스토리지와 DB 불일치 최소화
- **UX**: 파일 재업로드 방지
- **트랜잭션**: DB 작업만 트랜잭션으로 묶어 리소스 효율화

### 설계 과정에서 배운 것

1. **정합성 전략을 먼저 정했다**
   - 임시저장 → 확정 2단계 분리
   - TEMP 파일 정리 배치

2. **디렉터리 구조를 함께 설계했다**
   - 테이블별, 날짜별 파티셔닝
   - 접근 제어 단위 고려

3. **재시도를 고려한 API를 만들었다**
   - fileGroupId 기반 파일 그룹 관리
   - 타임스탬프 + UUID 파일명으로 충돌 방지

4. **운영을 함께 고민했다**
   - TEMP 파일 정리 스케줄러
   - 논리 삭제 vs 물리 삭제

### 마지막으로

> **파일 업로드는 단순 기능이 아니라, 운영 비용과 장애 포인트를 함께 설계해야 하는 영역이었다.**

"파일 저장"이라는 기능 하나에도:
- 영속성 경계
- 트랜잭션 정합성
- 사용자 경험
- 확장성

이 모든 것을 함께 고려해야 했다.

---
