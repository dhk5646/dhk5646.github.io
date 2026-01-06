---
title: "Spring Batch 애플리케이션 구축기: ERP 시스템의 대용량 자동 처리 구현"
categories: Backend
tags: [Spring Batch, Batch Processing, Spring Boot, MyBatis, Task Scheduler]
excerpt: "ERP 시스템에서 대용량 데이터 자동 처리를 위한 Spring Batch 기반 배치 애플리케이션 설계 및 구현 경험"
---

## 들어가며

ERP 시스템을 구축하던 중, 점점 더 많은 자동화 요구사항이 발생하기 시작했다.

**대표적인 요구사항들**:
- 매일 새벽 휴면 회원 일괄 처리
- 매월 초 관리비 자동 부과
- 세금 데이터 수집 및 동기화
- 대량의 전자세금계산서 발행

이러한 작업들의 공통점은:
- **대용량 데이터** 처리가 필요
- **주기적 자동 실행**이 필요
- **실패 시 재처리** 가능해야 함
- **처리 이력 추적**이 필요

초기에는 단순 스케줄러로 처리하려 했지만, 곧 한계에 부딪혔다.

```java
// 초기 시도: @Scheduled만으로 처리
@Scheduled(cron = "0 0 2 * * ?")
public void processDormantUsers() {
    List<User> users = userRepository.findAll(); // 전체 조회... OOM 위험
    users.forEach(user -> {
        // 실패하면? 어디서부터 재시작?
        // 처리 이력은? 모니터링은?
    });
}
```

**문제점**:
- 전체 데이터를 메모리에 로드 → OOM(Out Of Memory) 위험
- 중간에 실패하면 처음부터 다시 시작
- 어디까지 처리했는지 추적 불가
- 실행 이력 관리 어려움

자체적으로 배치 시스템을 구축하기엔 너무 복잡했다. 트랜잭션 관리, 재시작 메커니즘, 메타데이터 관리 등을 직접 구현하는 것은 비효율적이었다.

**결론**: Spring Batch를 도입하기로 결정했다.

이 글은 Spring Batch 기반 배치 애플리케이션을 구축하면서 **요구사항 분석부터 설계, 구현까지 전 과정**을 기록한 내용이다.

## 1. 요구사항 분석

### 1.1. 기능 요구사항

**필수 기능**:
- 배치 Job을 데이터베이스로 관리
- 즉시 실행 (수동 트리거)
- 스케줄 실행 (Cron 기반)
- 실행 이력 조회
- 실패 시 알림

**사용자 시나리오**:

**시나리오 1: 관리자가 즉시 실행**
```
1. 관리 화면에서 "휴면 회원 처리" Job 선택
2. 필요한 파라미터 입력 (예: 기준일자)
3. "즉시 실행" 버튼 클릭
4. 실행 상태 확인
```

**시나리오 2: 스케줄 자동 실행**
```
1. 관리자가 "매일 새벽 2시" 스케줄 등록
2. 시스템이 자동으로 해당 시간에 실행
3. 실패 시 담당자에게 알림 발송
4. 관리자가 실행 이력 확인 후 재실행 여부 결정
```

### 1.2. 비기능 요구사항

**성능**:
- 대용량 데이터 처리 (수십만 건)
- 메모리 효율적 처리 (Chunk 단위)
- 적절한 트랜잭션 경계

**안정성**:
- 실패 시 재시작 가능
- 중복 실행 방지
- 트랜잭션 롤백 지원

**운영성**:
- 실행 이력 추적
- 실패 알림
- 동적 스케줄 관리

### 1.3. 데이터 모델 요구사항

**배치 Job 관리**:
```sql
-- batch_job 테이블
CREATE TABLE batch_job (
    batch_job_seq BIGINT PRIMARY KEY,
    id VARCHAR(100),              -- Job Bean 이름
    name VARCHAR(200),            -- Job 표시 이름
    description TEXT,             -- 설명
    use_flag CHAR(1)              -- 사용 여부
);
```

**스케줄 관리**:
```sql
-- batch_cron 테이블
CREATE TABLE batch_cron (
    batch_cron_seq BIGINT PRIMARY KEY,
    batch_job_seq BIGINT,         -- FK to batch_job
    expression VARCHAR(100),       -- Cron 표현식
    parameter_data_json TEXT,      -- Job 파라미터 (JSON)
    use_flag CHAR(1),              -- 사용 여부
    valid_start_date DATE,         -- 유효 시작일
    valid_end_date DATE            -- 유효 종료일
);
```

## 2. 기술 선택

### 2.1. 왜 Spring Batch인가?

**Spring Batch의 장점**:
- Chunk 지향 처리로 대용량 데이터 처리 최적화
- 재시작 메커니즘 기본 제공
- 메타데이터 자동 관리
- 트랜잭션 관리 자동화
- 풍부한 리스너와 확장 포인트

### 2.2. 최종 기술 스택

**백엔드**:
- Spring Batch 4.x
- Spring Boot 2.x
- MyBatis (데이터베이스 연동)
- Spring Task Scheduler (스케줄링)

**데이터베이스**:
- Spring Batch 메타 테이블
- 커스텀 배치 관리 테이블

**인프라**:
- 단일 서버 구성 (이중화는 향후 고려)

## 3. 시스템 설계

### 3.1. 전체 아키텍처

시스템은 크게 3개 계층으로 설계했다.

```
┌─────────────────────────────────────────────────────────────────┐
│                    프레젠테이션 계층                                │
├─────────────────────────────────────────────────────────────────┤
│  BatchCommonController (REST API)                               │
│  - 즉시 실행 (동기/비동기)                                           │
│  - 파라미터 조회                                                   │
│  - 스케줄 관리                                                     │
└───────────────────────┬─────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│                    비즈니스 계층                                   │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────-─┐    ┌────────────────────────────────┐    │
│  │ BatchCommonService│    │ BatchCronScheduleManager       │    │
│  │ - 실행 조정         │    │ - 동적 스케줄 관리                 │    │
│  └─────────────────-─┘    └────────────────────────────────┘    │
│  ┌─────────────--─────┐    ┌────────────────────────────────┐    │
│  │ JobParameterFactory│    │ JobExecutor                    │    │
│  │ - 파라미터 변환       │    │ - Job 실행 (동기/비동기)           │    │
│  └────────────────────┘    └────────────────────────────────┘    │
└───────────────────────┬──────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Spring Batch 계층                             │
├─────────────────────────────────────────────────────────────────┤
│  Job (JobBuilderFactory)                                        │
│   │                                                             │
│   ├─> CustomRunIdIncrementer (고유 실행 ID 생성)                   │
│   ├─> BatchJobExecutionListener (실행 전후 처리)                   │
│   │                                                             │
│   └─> Step (StepBuilderFactory)                                 │
│        │                                                        │
│        ├─> Reader (MyBatisPagingItemReader)                     │
│        ├─> Processor (ItemProcessor)                            │
│        └─> Writer (MyBatisBatchItemWriter)                      │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2. 핵심 설계 결정 사항

**1) Job과 Parameter의 중앙 관리**
```java
// BatchJobEnum: Job과 Parameter를 함께 관리
public enum BatchJobEnum {
    SAMPLE_JOB("sampleJob", SampleJobParameter.class),
    DORMANT_USER_JOB("dormantUserJob", null),
    ...
    
    private final String id;  // Bean 이름
    private final Class<? extends BasicJobParameter> parameterClass;
}
```

**장점**:
- Job과 Parameter의 관계를 한 곳에서 관리
- 타입 안정성 제공
- IDE의 자동 완성 지원

**2) Reflection 기반 동적 파라미터 처리**
```java
// BasicJobParameter 인터페이스를 통한 표준화
public interface BasicJobParameter {
}

// @BatchParameter로 메타데이터 제공
public class SampleJobParameter implements BasicJobParameter {
    @BatchParameter(description = "처리 대상 날짜", example = "2024-01-01")
    @Value("#{jobParameters[targetDate]}")
    private Date targetDate;
}
```

**장점**:
- 관리 화면에서 파라미터 정보 자동 조회
- 파라미터 검증 용이
- 확장 가능한 구조

**3) 동적 스케줄 관리**
```java
// 데이터베이스 기반 스케줄 관리
@Component
public class BatchCronScheduleManager {
    // 메모리에서 스케줄 관리
    private final Map<Long, ScheduledFuture<?>> scheduleMap = new HashMap<>();
    
    // 스케줄 추가/수정/삭제를 동적으로 처리
    public void insert(BatchCron batchCron) { ... }
    public void update(BatchCron batchCron) { ... }
    public void delete(Long batchCronSeq) { ... }
}
```

**장점**:
- 서버 재시작 없이 스케줄 변경 가능
- 유효 기간 관리 가능
- 사용 여부 토글 가능

## 4. 핵심 컴포넌트 구현

### 4.1. CustomRunIdIncrementer

**목적**: 동일한 파라미터로 Job을 여러 번 실행 가능하게 함

**문제 상황**:
```java
// Spring Batch 기본 동작
// 동일한 Job + 동일한 Parameter = 중복 실행 방지
JobParameters params = new JobParametersBuilder()
    .addDate("targetDate", new Date())
    .toJobParameters();

jobLauncher.run(job, params);  // 첫 실행: 성공
jobLauncher.run(job, params);  // 두 번째 실행: 실패!
// JobInstanceAlreadyCompleteException 발생
```

**해결**:
```java
public class CustomRunIdIncrementer implements JobParametersIncrementer {
    private static final String RUN_ID_KEY = "run.id";
    
    @Override
    public JobParameters getNext(@Nullable JobParameters parameters) {
        return new JobParametersBuilder()
            .addString(RUN_ID_KEY, makeKey())
            .toJobParameters();
    }
    
    private String makeKey() {
        // 시간 + 호스트명으로 고유 키 생성
        return String.format("%s-%s", 
            LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMddHHmmssSSS")),
            getHostName()
        );
    }
    
    private String getHostName() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            return "unknown";
        }
    }
}
```

**적용**:
```java
@Bean
public Job dormantUserJob() {
    return jobBuilderFactory.get("dormantUserJob")
        .incrementer(new CustomRunIdIncrementer())  // 추가
        .start(dormantUserStep())
        .build();
}
```

**효과**:
- 동일 파라미터로 재실행 가능
- 각 실행을 고유하게 식별
- 분산 환경에서도 충돌 방지 (호스트명 포함)

### 4.2. BatchJobExecutionListener

**목적**: Job 실행 전후 공통 처리

**구현**:
```java
@Component
@RequiredArgsConstructor
public class BatchJobExecutionListener implements JobExecutionListener {
    
    private final JobExplorer jobExplorer;
    private final BatchJobExecutionServerContextMapper serverContextMapper;
    private final JobExecutionFailMessageSender messageSender;
    
    @Override
    public void beforeJob(JobExecution jobExecution) {
        // 1. 중복 실행 검증
        if (!canRun(jobExecution)) {
            jobExecution.stop();
            log.warn("Job 중복 실행 방지: {}", jobExecution.getJobInstance().getJobName());
            return;
        }
        
        // 2. 서버 컨텍스트 저장 (어느 서버에서 실행되었는지)
        serverContextMapper.save(
            BatchJobExecutionServerContextSaveRequest.of(
                jobExecution.getJobId()
            )
        );
        
        log.info("Job 시작: {} (ID: {})", 
            jobExecution.getJobInstance().getJobName(),
            jobExecution.getJobId()
        );
    }
    
    @Override
    public void afterJob(JobExecution jobExecution) {
        // 3. 실행 결과 로그
        printLog(jobExecution);
        
        // 4. 실패 시 알림 발송
        if (jobExecution.getStatus() == BatchStatus.FAILED) {
            messageSender.sendMessage(jobExecution);
        }
        
        log.info("Job 종료: {} - 상태: {}", 
            jobExecution.getJobInstance().getJobName(),
            jobExecution.getStatus()
        );
    }
    
    private boolean canRun(JobExecution jobExecution) {
        // 동일 Job + 동일 Parameter가 이미 실행 중인지 확인
        String jobName = jobExecution.getJobInstance().getJobName();
        JobParameters params = jobExecution.getJobParameters();
        
        Set<JobExecution> runningExecutions = jobExplorer.findRunningJobExecutions(jobName);
        
        return runningExecutions.stream()
            .filter(execution -> !execution.getId().equals(jobExecution.getId()))
            .noneMatch(execution -> execution.getJobParameters().equals(params));
    }
    
    private void printLog(JobExecution jobExecution) {
        StringBuilder sb = new StringBuilder("\n");
        sb.append("=================================================\n");
        sb.append("Job: ").append(jobExecution.getJobInstance().getJobName()).append("\n");
        sb.append("Status: ").append(jobExecution.getStatus()).append("\n");
        sb.append("Start: ").append(jobExecution.getStartTime()).append("\n");
        sb.append("End: ").append(jobExecution.getEndTime()).append("\n");
        sb.append("Duration: ").append(Duration.between(
            jobExecution.getStartTime().toInstant(),
            jobExecution.getEndTime().toInstant()
        ).getSeconds()).append("s\n");
        
        jobExecution.getStepExecutions().forEach(step -> {
            sb.append("\nStep: ").append(step.getStepName()).append("\n");
            sb.append("  Read: ").append(step.getReadCount()).append("\n");
            sb.append("  Write: ").append(step.getWriteCount()).append("\n");
            sb.append("  Skip: ").append(step.getSkipCount()).append("\n");
        });
        
        sb.append("=================================================");
        log.info(sb.toString());
    }
}
```

**효과**:
- 중복 실행 방지
- 실행 서버 추적
- 상세 실행 로그
- 실패 시 즉시 알림

### 4.3. JobParameterFactory

**목적**: BasicJobParameter를 Spring Batch JobParameters로 변환

**구현**:
```java
@Component
@RequiredArgsConstructor
public class JobParameterFactory {
    
    private final ObjectMapper objectMapper;
    private final JobExplorer jobExplorer;
    
    // JSON 문자열을 JobParameters로 변환
    public JobParameters getJobParameters(
        Class<? extends BasicJobParameter> parameterClass,
        String parameterDataJson
    ) throws JsonProcessingException {
        
        BasicJobParameter parameter = 
            objectMapper.readValue(parameterDataJson, parameterClass);
        
        return convertJobParameters(parameter);
    }
    
    // Incrementer와 함께 JobParameters 생성
    public JobParameters getJobParametersWithIncrementer(
        Job job,
        BasicJobParameter parameter
    ) {
        return new JobParametersBuilder(jobExplorer)
            .getNextJobParameters(job)  // RunId 자동 증가
            .addJobParameters(convertJobParameters(parameter))
            .toJobParameters();
    }
    
    private JobParameters convertJobParameters(BasicJobParameter parameter) {
        JobParametersBuilder builder = new JobParametersBuilder();
        
        // Reflection으로 필드 순회
        for (Field field : parameter.getClass().getDeclaredFields()) {
            field.setAccessible(true);
            
            // @BatchParameter 확인
            BatchParameter annotation = field.getAnnotation(BatchParameter.class);
            if (annotation == null || !annotation.include()) {
                continue;  // include=false면 제외
            }
            
            try {
                Object value = field.get(parameter);
                if (value == null) continue;
                
                // 타입별 변환
                String fieldName = field.getName();
                if (value instanceof String) {
                    builder.addString(fieldName, (String) value);
                } else if (value instanceof Long) {
                    builder.addLong(fieldName, (Long) value);
                } else if (value instanceof Double) {
                    builder.addDouble(fieldName, (Double) value);
                } else if (value instanceof Date) {
                    builder.addDate(fieldName, (Date) value);
                } else if (value instanceof LocalDateTime) {
                    // LocalDateTime은 Date로 변환
                    builder.addDate(fieldName, 
                        Date.from(((LocalDateTime) value)
                            .atZone(ZoneId.systemDefault())
                            .toInstant())
                    );
                }
            } catch (IllegalAccessException e) {
                log.error("필드 접근 실패: {}", field.getName(), e);
            }
        }
        
        return builder.toJobParameters();
    }
}
```

**사용 예제**:
```java
// Parameter 클래스 정의
@Getter
@Setter
public class SampleJobParameter implements BasicJobParameter {
    @BatchParameter(description = "처리 대상 날짜")
    @Value("#{jobParameters[targetDate]}")
    private Date targetDate;
    
    @BatchParameter(include = false)  // 관리 화면에 노출 안 됨
    private String systemField;
}

// 사용
String json = "{\"targetDate\":\"2024-01-01\"}";
JobParameters params = jobParameterFactory.getJobParameters(
    SampleJobParameter.class, 
    json
);
```

### 4.4. BatchCronScheduleManager

**목적**: 동적으로 스케줄을 등록/수정/삭제

**구현**:
```java
@Component
@RequiredArgsConstructor
public class BatchCronScheduleManager {
    
    private final TaskScheduler taskScheduler;
    private final JobLauncher jobLauncher;
    private final JobParameterFactory jobParameterFactory;
    private final ApplicationContext applicationContext;
    
    // 스케줄 저장소 (메모리)
    private final Map<Long, ScheduledFuture<?>> scheduleMap = new ConcurrentHashMap<>();
    
    // 앱 시작 시 초기화
    public void initialize(List<BatchCron> batchCronList) {
        log.info("배치 스케줄 초기화 시작: {} 건", batchCronList.size());
        batchCronList.forEach(this::insert);
        log.info("배치 스케줄 초기화 완료: {} 건 등록", scheduleMap.size());
    }
    
    // 스케줄 추가
    public void insert(BatchCron batchCron) {
        if (!canInsertSchedule(batchCron)) {
            log.warn("스케줄 등록 불가: {}", batchCron);
            return;
        }
        
        try {
            // 1. Job Bean 조회
            BatchJobEnum jobEnum = BatchJobEnum.findByCode(batchCron.getBatchJob().getId());
            Job job = applicationContext.getBean(jobEnum.getId(), Job.class);
            
            // 2. 파라미터 준비
            BasicJobParameter parameter = null;
            if (jobEnum.getParameterClass() != null) {
                parameter = objectMapper.readValue(
                    batchCron.getParameterDataJson(),
                    jobEnum.getParameterClass()
                );
            }
            
            // 3. 스케줄 등록
            final BasicJobParameter finalParameter = parameter;
            ScheduledFuture<?> scheduledFuture = taskScheduler.schedule(() -> {
                try {
                    JobParameters params = jobParameterFactory
                        .getJobParametersWithIncrementer(job, finalParameter);
                    
                    jobLauncher.run(job, params);
                    
                } catch (Exception e) {
                    log.error("스케줄 Job 실행 실패: {}", job.getName(), e);
                }
            }, new CronTrigger(batchCron.getExpression()));
            
            scheduleMap.put(batchCron.getBatchCronSeq(), scheduledFuture);
            
            log.info("스케줄 등록 완료: {} - {}", 
                batchCron.getBatchJob().getName(), 
                batchCron.getExpression()
            );
            
        } catch (Exception e) {
            log.error("스케줄 등록 실패: {}", batchCron, e);
        }
    }
    
    // 스케줄 수정 (삭제 후 재등록)
    public void update(BatchCron batchCron) {
        delete(batchCron.getBatchCronSeq());
        insert(batchCron);
    }
    
    // 스케줄 삭제
    public void delete(Long batchCronSeq) {
        ScheduledFuture<?> scheduledFuture = scheduleMap.remove(batchCronSeq);
        if (scheduledFuture != null) {
            scheduledFuture.cancel(false);
            log.info("스케줄 삭제 완료: {}", batchCronSeq);
        }
    }
    
    // 유효성 검증
    private boolean canInsertSchedule(BatchCron batchCron) {
        LocalDate now = LocalDate.now();
        
        // 1. 사용 여부 확인
        if (!UseFlag.Y.equals(batchCron.getUseFlag())) {
            return false;
        }
        
        // 2. Cron 표현식 유효성
        if (!CronExpression.isValidExpression(batchCron.getExpression())) {
            return false;
        }
        
        // 3. 유효 기간 확인
        if (now.isBefore(batchCron.getValidStartDate()) || 
            now.isAfter(batchCron.getValidEndDate())) {
            return false;
        }
        
        return true;
    }
}
```

**효과**:
- 서버 재시작 없이 스케줄 변경
- 유효 기간 관리
- Cron 표현식 검증

## 5. 실전 예제: 휴면 회원 처리 배치

### 5.1. Job 구성

```java
@Configuration
@RequiredArgsConstructor
public class DormantUserJobConfig {
    
    private final JobBuilderFactory jobBuilderFactory;
    private final StepBuilderFactory stepBuilderFactory;
    private final SqlSessionFactory sqlSessionFactory;
    private final BatchJobExecutionListener batchJobExecutionListener;
    
    private static final String JOB_NAME = "dormantUserJob";
    
    @Value("${app.batch.dormantuser.chunksize:100}")
    private int chunkSize;
    
    @Bean
    public Job dormantUserJob() {
        return jobBuilderFactory.get(JOB_NAME)
            .incrementer(new CustomRunIdIncrementer())
            .listener(batchJobExecutionListener)
            .start(dormantUserStep())
            .build();
    }
    
    @Bean
    public Step dormantUserStep() {
        return stepBuilderFactory.get(JOB_NAME + "_step")
            .<User, UserWriteDto>chunk(chunkSize)
            .reader(oneYearOverLoginUserReader())
            .processor(dormantUserProcessor())
            .writer(updateDormantUserWriter())
            .build();
    }
    
    @Bean
    public MyBatisPagingItemReader<User> oneYearOverLoginUserReader() {
        return new MyBatisPagingItemReaderBuilder<User>()
            .pageSize(chunkSize)
            .sqlSessionFactory(sqlSessionFactory)
            .queryId("com.example.repository.UserMapper.findDormantTargets")
            .build();
    }
    
    @Bean
    public ItemProcessor<User, UserWriteDto> dormantUserProcessor() {
        return user -> {
            user.setStatus(UserStatus.DORMANT);
            user.setPassword("TEMP_PASSWORD");
            return UserWriteDto.from(user);
        };
    }
    
    @Bean
    public MyBatisBatchItemWriter<UserWriteDto> updateDormantUserWriter() {
        return new MyBatisBatchItemWriterBuilder<UserWriteDto>()
            .sqlSessionFactory(sqlSessionFactory)
            .statementId("com.example.repository.UserMapper.updateDormant")
            .build();
    }
}
```

### 5.2. 처리 흐름

```
1. Reader (100명씩 읽기)
   ↓
   SELECT * FROM user
   WHERE last_login_date < DATE_SUB(NOW(), INTERVAL 1 YEAR)
   LIMIT 100 OFFSET ?
   
2. Processor (각 User 처리)
   ↓
   user.setStatus(DORMANT)
   user.setPassword("TEMP")
   
3. Writer (일괄 업데이트)
   ↓
   UPDATE user SET 
     status = 'DORMANT', 
     password = 'TEMP'
   WHERE user_seq IN (?, ?, ...)
   
4. Commit
   
5. 다음 100명으로 반복
```

**장점**:
- 한 번에 100명씩 처리 → 메모리 효율적
- Chunk 단위 트랜잭션 → 일부 실패해도 나머지는 처리
- 중간에 실패 시 마지막 Chunk부터 재시작 가능

## 6. REST API 구현

### 6.1. 즉시 실행 API

```java
@RestController
@RequestMapping("/common")
@RequiredArgsConstructor
public class BatchCommonController {
    
    private final BatchCommonService batchCommonService;
    
    // 비동기 실행
    @PostMapping("/job/{batchJobId}/execute")
    public ApiResponse<Void> execute(
        @PathVariable String batchJobId,
        @RequestBody BatchJobExecuteRequest request
    ) {
        batchCommonService.executeAsync(batchJobId, request);
        return ApiResponse.ok();
    }
    
    // 동기 실행
    @PostMapping("/job/{batchJobId}/execute/sync")
    public ApiResponse<Void> executeSync(
        @PathVariable String batchJobId,
        @RequestBody BatchJobExecuteRequest request
    ) {
        batchCommonService.executeSync(batchJobId, request);
        return ApiResponse.ok();
    }
    
    // 파라미터 정보 조회
    @GetMapping("/job/{batchJobId}/parameter")
    public ApiResponse<BatchJobParameterInfoResponse> getParameterList(
        @PathVariable String batchJobId
    ) {
        return ApiResponse.ok(
            batchCommonService.getParameterList(batchJobId)
        );
    }
}
```

### 6.2. 서비스 구현

```java
@Service
@RequiredArgsConstructor
public class BatchCommonService {
    
    private final JobExecutor jobExecutor;
    private final JobParameterFactory jobParameterFactory;
    private final ApplicationContext applicationContext;
    
    // 비동기 실행
    @Async
    public void executeAsync(String batchJobId, BatchJobExecuteRequest request) {
        execute(batchJobId, request);
    }
    
    // 동기 실행
    public void executeSync(String batchJobId, BatchJobExecuteRequest request) {
        execute(batchJobId, request);
    }
    
    private void execute(String batchJobId, BatchJobExecuteRequest request) {
        try {
            // 1. Job 조회
            BatchJobEnum jobEnum = BatchJobEnum.findByCode(batchJobId);
            Job job = applicationContext.getBean(jobEnum.getId(), Job.class);
            
            // 2. 파라미터 변환
            BasicJobParameter parameter = null;
            if (jobEnum.getParameterClass() != null) {
                String json = objectMapper.writeValueAsString(request.getParameterMap());
                parameter = objectMapper.readValue(json, jobEnum.getParameterClass());
            }
            
            // 3. Job 실행
            JobParameters params = jobParameterFactory
                .getJobParametersWithIncrementer(job, parameter);
            
            jobExecutor.execute(job, params);
            
        } catch (Exception e) {
            log.error("Job 실행 실패: {}", batchJobId, e);
            throw new BatchExecutionException("Job 실행 실패", e);
        }
    }
    
    // 파라미터 정보 조회 (Reflection 활용)
    public BatchJobParameterInfoResponse getParameterList(String batchJobId) {
        BatchJobEnum jobEnum = BatchJobEnum.findByCode(batchJobId);
        Class<? extends BasicJobParameter> parameterClass = jobEnum.getParameterClass();
        
        if (parameterClass == null) {
            return BatchJobParameterInfoResponse.empty();
        }
        
        List<ParameterInfo> parameterList = new ArrayList<>();
        
        for (Field field : parameterClass.getDeclaredFields()) {
            BatchParameter annotation = field.getAnnotation(BatchParameter.class);
            if (annotation == null || !annotation.include()) {
                continue;
            }
            
            parameterList.add(ParameterInfo.builder()
                .name(field.getName())
                .type(field.getType().getSimpleName())
                .description(annotation.description())
                .example(annotation.example())
                .build()
            );
        }
        
        return new BatchJobParameterInfoResponse(parameterList);
    }
}
```

## 7. 운영 및 모니터링

### 7.1. 실행 이력 조회

Spring Batch는 자동으로 메타데이터를 관리한다.

**주요 메타 테이블**:
```sql
-- Job 인스턴스 (고유한 Job + Parameter 조합)
SELECT * FROM BATCH_JOB_INSTANCE;

-- Job 실행 이력
SELECT * FROM BATCH_JOB_EXECUTION
WHERE JOB_INSTANCE_ID = ?
ORDER BY CREATE_TIME DESC;

-- Step 실행 이력
SELECT * FROM BATCH_STEP_EXECUTION
WHERE JOB_EXECUTION_ID = ?;

-- 실행 파라미터
SELECT * FROM BATCH_JOB_EXECUTION_PARAMS
WHERE JOB_EXECUTION_ID = ?;
```

**커스텀 서버 컨텍스트 조회**:
```sql
-- 어느 서버에서 실행되었는지 추적
SELECT 
    e.JOB_EXECUTION_ID,
    i.JOB_NAME,
    e.START_TIME,
    e.STATUS,
    c.server_name,
    c.ip_address
FROM BATCH_JOB_EXECUTION e
JOIN BATCH_JOB_INSTANCE i ON e.JOB_INSTANCE_ID = i.JOB_INSTANCE_ID
JOIN batch_job_execution_server_context c ON e.JOB_EXECUTION_ID = c.job_execution_id
ORDER BY e.CREATE_TIME DESC;
```

### 7.2. 실패 알림

```java
@Component
@RequiredArgsConstructor
public class JobExecutionFailMessageSender {
    
    private final SlackMessengerClient slackClient;
    
    public void sendMessage(JobExecution jobExecution) {
        if (jobExecution.getStatus() != BatchStatus.FAILED) {
            return;
        }
        
        String message = buildFailMessage(jobExecution);
        slackClient.send(message);
    }
    
    private String buildFailMessage(JobExecution jobExecution) {
        StringBuilder sb = new StringBuilder();
        sb.append("배치 실행 실패 알림\n\n");
        sb.append("Job: ").append(jobExecution.getJobInstance().getJobName()).append("\n");
        sb.append("실행 ID: ").append(jobExecution.getJobId()).append("\n");
        sb.append("시작: ").append(jobExecution.getStartTime()).append("\n");
        sb.append("종료: ").append(jobExecution.getEndTime()).append("\n");
        sb.append("\n에러 메시지:\n");
        
        // 에러 메시지 추출
        List<Throwable> exceptions = jobExecution.getAllFailureExceptions();
        exceptions.forEach(e -> sb.append("- ").append(e.getMessage()).append("\n"));
        
        return sb.toString();
    }
}
```

### 7.3. 애플리케이션 시작 시 초기화

```java
@Component
@RequiredArgsConstructor
public class AppStartedListener implements ApplicationListener<ApplicationStartedEvent> {
    
    private final BatchMetaDataService metaDataService;
    private final BatchCronMapper batchCronMapper;
    private final BatchCronScheduleManager scheduleManager;
    
    @Override
    public void onApplicationEvent(ApplicationStartedEvent event) {
        // 1. 비정상 종료된 Job 상태 복구
        metaDataService.modifyFailedStatusByJobAndStep();
        log.info("비정상 종료 Job 상태 복구 완료");
        
        // 2. 스케줄 초기화
        List<BatchCron> batchCronList = batchCronMapper.findAll();
        scheduleManager.initialize(batchCronList);
        log.info("배치 스케줄 초기화 완료");
    }
}
```

## 8. 개선 효과

### 8.1. 변경 전 vs 변경 후

| 항목 | 변경 전 (@Scheduled) | 변경 후 (Spring Batch) |
|------|---------------------|------------------------|
| **대용량 처리** | OOM 위험 | Chunk 단위 처리 |
| **재시작** | 처음부터 다시 | 실패 지점부터 재시작 |
| **트랜잭션** | 수동 관리 | 자동 관리 (Chunk 단위) |
| **실행 이력** | 직접 구현 필요 | 자동 저장 |
| **파라미터 관리** | 하드코딩 | 동적 관리 |
| **스케줄 변경** | 코드 수정 필요 | API로 즉시 변경 |
| **모니터링** | 직접 구현 | 메타 테이블 제공 |

### 8.2. 구체적인 개선 사항

**1) 메모리 효율성**
```
변경 전:
- 전체 데이터 메모리 로드
- 10만 건 처리 시 OOM 발생

변경 후:
- Chunk 단위 처리 (100건씩)
- 100만 건 처리 가능
```

**2) 안정성**
```
변경 전:
- 5만 번째에서 실패 → 처음부터 다시

변경 후:
- 5만 번째에서 실패 → 5만 번째부터 재시작
```

**3) 운영 편의성**
```
변경 전:
- 스케줄 변경 → 코드 수정 → 배포

변경 후:
- 관리 화면에서 즉시 변경
- 배포 불필요
```

## 9. 한계와 트레이드오프

### 9.1. 현재 한계

**단일 서버 구성**:
- 현재는 단일 서버 기준 설계
- `BatchCronScheduleManager`가 메모리에서 스케줄 관리
- 이중화 환경에서는 스케줄 중복 실행 가능

**개선 방안**:
```java
// Redis를 활용한 분산 스케줄 관리
@Component
public class DistributedBatchCronScheduleManager {
    
    private final RedissonClient redissonClient;
    
    public void insert(BatchCron batchCron) {
        // 분산 락으로 중복 실행 방지
        RLock lock = redissonClient.getLock("batch:schedule:" + batchCron.getId());
        
        if (lock.tryLock()) {
            try {
                // 스케줄 등록
            } finally {
                lock.unlock();
            }
        }
    }
}
```

### 9.2. 트레이드오프

| 항목 | 선택한 방식 | 포기한 것 | 이유 |
|------|------------|----------|------|
| **스케줄 관리** | 메모리 기반 | 이중화 지원 | 단일 서버 구성, 구현 단순 |
| **파라미터 관리** | Reflection | 컴파일 타임 검증 | 동적 파라미터 조회 필요 |
| **실행 방식** | JobLauncher | 직접 실행 | Spring Batch 표준 준수 |

## 10. 마무리

### 10.1. 핵심 요약

Spring Batch 기반 배치 애플리케이션을 구축하면서:

**기술적 성과**:
- 대용량 데이터 처리 안정화
- 재시작 메커니즘으로 안정성 확보
- 동적 스케줄 관리로 운영 편의성 향상

**설계 원칙**:
- Job과 Parameter를 중앙에서 관리
- Reflection 기반 동적 파라미터 처리
- 데이터베이스 기반 스케줄 관리

**운영 개선**:
- 실행 이력 자동 추적
- 실패 시 즉시 알림
- 서버 재시작 없는 스케줄 변경

### 10.2. 향후 개선 방향

**이중화 지원**:
- Redis 기반 분산 스케줄 관리
- 분산 락을 통한 중복 실행 방지

**모니터링 강화**:
- 실행 현황 대시보드
- 성능 메트릭 수집
- 알림 채널 다양화 (Slack, Email)

**성능 최적화**:
- 파티셔닝을 통한 병렬 처리
- 멀티 스레드 Step 적용

### 10.3. 배운 점

**Spring Batch의 강점**:
- 대용량 처리를 위한 최적화된 프레임워크
- 메타데이터 자동 관리
- 풍부한 확장 포인트

**설계의 중요성**:
- 초기 설계가 확장성을 결정
- 표준 준수가 유지보수성을 높임
- 운영을 고려한 설계가 필수

**"처음부터 완벽할 필요는 없다. 점진적으로 개선하면 된다."**

---

## 참고 자료

- [Spring Batch 공식 문서](https://docs.spring.io/spring-batch/docs/current/reference/html/)
- [Spring Batch in Action](https://www.manning.com/books/spring-batch-in-action)

