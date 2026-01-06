---
title: "왜 퇴근길에 서버를 끄지 않았을까? EC2 스케줄링을 통한 60% 비용 절감기"
categories: DevOps
tags: [AWS, EC2, Cost-Optimization, FinOps, Cloud, Automation]
excerpt: "단순히 개발 서버를 업무 시간에만 가동하는 것만으로 AWS 비용을 63% 절감한 실전 사례와 자동화 전략을 공유합니다."
---

## 들어가며

그동안 팀에서 코드 리팩토링, 배포 프로세스 자동화 등 다양한 개선 활동을 진행해 왔다.

어느덧 눈에 보이는 큰 비효율은 대부분 제거되었고, "이제 더 이상 개선할 게 있을까?"라는 고민에 빠졌을 때쯤 우리 팀이 사용 중인 **AWS 클라우드**가 눈에 들어왔다.

---

## 클라우드의 핵심: "사용한 만큼만 낸다"

클라우드 전환 후 우리가 놓치고 있던 중요한 사실이 있었다. 바로 **개발 서버는 24시간 깨어 있을 필요가 없다**는 점이었다.

- **업무 시간**: 08:00 ~ 20:00 (하루 12시간)
- **비업무 시간**: 퇴근 후 야간 + 주말 (하루 12시간 + 토/일 48시간)

우리가 잠든 시간에도, 사무실 불이 꺼진 주말에도 개발 서버의 미터기는 쉼 없이 돌아가고 있었다.

> "퇴근할 때 서버를 중지한다면 얼마나 아낄 수 있을까?"

이 질문이 실제 계산으로 이어졌다.

## 실제 사례를 통한 비용 절감 시뮬레이션

가장 대중적으로 사용되는 **t3.medium 인스턴스**(서울 리전 기준) 1대를 운영한다고 가정하고 비교했다.

### A. 기존 방식 (24시간/7일 가동)

```
시간당 비용: $0.0416 (t3.medium 기준, 2020년 8월)
월 가동 시간: 24시간 × 30일 = 720시간
월간 총 비용: $0.0416 × 720시간 = $29.95 (약 3.6만 원)
```

### B. 개선 방식 (업무 시간만 가동)

```
평일 가동 시간: 08:00 ~ 20:00 (12시간) × 22일 = 264시간
주말/야간: 중지
월간 총 비용: $0.0416 × 264시간 = $10.98 (약 1.3만 원)
```

### 결과

**약 63%의 비용 절감 달성!**

단지 서버를 끄는 것만으로도:
- 매달 약 2.3만 원 절감
- 연간 약 28만 원 이상의 고정비 감소

만약 개발 서버 10대를 운영한다면:
- 매달 약 23만 원 절감
- 연간 약 280만 원 이상 절감

> **참고:** 본 금액은 2020년 8월 기준의 예시이며, 실제 비용은 AWS 요금 정책 및 리전, 환율에 따라 달라질 수 있다.


## 어떻게 자동화할 것인가?

매번 사람이 수동으로 서버를 제어할 수는 없다. 실제로 적용한 자동화 방법은 **CloudWatch Events + Lambda**를 활용한 방식이다.

### 전체 작업 순서

1. Lambda 함수에 대한 IAM 정책 및 실행 역할 생성
2. EC2 인스턴스를 중지 및 시작하는 Lambda 함수 생성
3. Lambda 함수를 트리거하는 CloudWatch Events 규칙 생성
4. Lambda 함수를 CloudWatch Events에 적용

### 1. Lambda 함수에 대한 IAM 정책 및 실행 역할 생성

Lambda 함수가 EC2 인스턴스를 제어할 수 있도록 적절한 권한을 부여해야 한다.

**IAM 역할 생성:**

1. IAM 콘솔에서 **역할 만들기** 선택
2. 신뢰할 수 있는 엔터티 유형: **AWS 서비스** → **Lambda** 선택
3. 다음 정책을 연결:
   - `AWSLambdaBasicExecutionRole` (CloudWatch Logs 기록용)
4. **인라인 정책 추가**로 EC2 제어 권한 부여:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:StartInstances",
        "ec2:StopInstances"
      ],
      "Resource": "*"
    }
  ]
}
```

5. 역할 이름: `Lambda-EC2-Scheduler-Role`로 지정

### 2. EC2 인스턴스를 중지 및 시작하는 Lambda 함수 생성

**인스턴스 중지 함수 (stop_instances.py):**

```python
import boto3
import os

region = 'ap-northeast-2'
ec2 = boto3.client('ec2', region_name=region)

def lambda_handler(event, context):
    # 환경 변수 또는 태그로 대상 인스턴스 지정
    filters = [
        {
            'Name': 'tag:AutoSchedule',
            'Values': ['true']
        },
        {
            'Name': 'instance-state-name',
            'Values': ['running']
        }
    ]
    
    instances = ec2.describe_instances(Filters=filters)
    
    instance_ids = []
    for reservation in instances['Reservations']:
        for instance in reservation['Instances']:
            instance_ids.append(instance['InstanceId'])
    
    if instance_ids:
        ec2.stop_instances(InstanceIds=instance_ids)
        print(f'Successfully stopped instances: {instance_ids}')
        return {
            'statusCode': 200,
            'body': f'Stopped instances: {instance_ids}'
        }
    else:
        print('No running instances found with AutoSchedule tag')
        return {
            'statusCode': 200,
            'body': 'No instances to stop'
        }
```

**인스턴스 시작 함수 (start_instances.py):**

```python
import boto3
import os

region = 'ap-northeast-2'
ec2 = boto3.client('ec2', region_name=region)

def lambda_handler(event, context):
    filters = [
        {
            'Name': 'tag:AutoSchedule',
            'Values': ['true']
        },
        {
            'Name': 'instance-state-name',
            'Values': ['stopped']
        }
    ]
    
    instances = ec2.describe_instances(Filters=filters)
    
    instance_ids = []
    for reservation in instances['Reservations']:
        for instance in reservation['Instances']:
            instance_ids.append(instance['InstanceId'])
    
    if instance_ids:
        ec2.start_instances(InstanceIds=instance_ids)
        print(f'Successfully started instances: {instance_ids}')
        return {
            'statusCode': 200,
            'body': f'Started instances: {instance_ids}'
        }
    else:
        print('No stopped instances found with AutoSchedule tag')
        return {
            'statusCode': 200,
            'body': 'No instances to start'
        }
```

**Lambda 함수 생성 단계:**

1. Lambda 콘솔에서 **함수 생성**
2. 함수 이름: `EC2-Stop-Scheduler`, `EC2-Start-Scheduler`
3. 런타임: **Python 3.8**
4. 실행 역할: 앞서 생성한 `Lambda-EC2-Scheduler-Role` 선택
5. 코드 입력 후 **Deploy**

### 3. Lambda 함수를 트리거하는 CloudWatch Events 규칙 생성

**중지 규칙 (매일 20:00 KST):**

1. CloudWatch 콘솔 → **이벤트** → **규칙 생성**
2. 이벤트 소스: **일정**
3. Cron 표현식: `0 11 ? * MON-FRI *` (UTC 11:00 = KST 20:00, 월요일~금요일)
4. 대상: `EC2-Stop-Scheduler` Lambda 함수 선택
5. 규칙 이름: `EC2-Stop-Weekday-8PM`

**시작 규칙 (매일 08:00 KST):**

1. CloudWatch 콘솔 → **이벤트** → **규칙 생성**
2. 이벤트 소스: **일정**
3. Cron 표현식: `0 23 ? * SUN-THU *` (UTC 23:00 = KST 08:00, 일요일~목요일)
4. 대상: `EC2-Start-Scheduler` Lambda 함수 선택
5. 규칙 이름: `EC2-Start-Weekday-8AM`

> **참고:** AWS CloudWatch Events의 Cron은 UTC 기준이므로 KST(UTC+9) 시간에서 9시간을 빼서 설정해야 한다.

### 4. Lambda 함수를 CloudWatch Events에 적용

Lambda 함수 생성 시 자동으로 권한이 부여되지만, 수동으로 확인하려면:

1. Lambda 함수의 **구성** 탭
2. **트리거** 섹션에서 CloudWatch Events 규칙 확인
3. 필요 시 **트리거 추가**로 수동 연결 가능

### 적용 대상 EC2 인스턴스 태그 설정

자동 스케줄링을 원하는 EC2 인스턴스에 다음 태그를 추가한다:

```
Key: AutoSchedule
Value: true
```

**태그 추가 방법:**

1. EC2 콘솔에서 대상 인스턴스 선택
2. **작업** → **인스턴스 설정** → **태그 추가/편집**
3. `AutoSchedule: true` 태그 추가

### 테스트 및 모니터링

**Lambda 함수 테스트:**

1. Lambda 콘솔에서 **테스트** 탭
2. 빈 테스트 이벤트 생성 후 실행
3. CloudWatch Logs에서 실행 로그 확인

**CloudWatch Logs 확인:**

- `/aws/lambda/EC2-Stop-Scheduler`
- `/aws/lambda/EC2-Start-Scheduler`

로그 그룹에서 실행 내역과 중지/시작된 인스턴스 ID를 확인할 수 있다.

## 마치며

"더 이상 개선할 환경이 아니다"라고 생각했을 때, 기술적인 코드 너머의 **운영 비용**으로 관점을 돌리자 새로운 개선 포인트가 보였다.

이번 활동을 통해 단순히 비용을 아낀 것을 넘어, 팀의 클라우드 자원을 더 효율적으로 관리하는 **FinOps 마인드**를 갖게 된 것이 가장 큰 수확이었다.

**여러분의 개발 서버는 지금 이 순간에도 혹시 의미 없이 돌아가고 있지 않나요?**
