---
title: "연쇄 책임 패턴으로 복잡한 할인 정책 유연하게 설계하기"
categories: java
tags: [design-pattern, chain-of-responsibility, strategy-pattern, refactoring, clean-code]
excerpt: "한전 계산기 할인 정책 설계 사례 - 패턴은 목표가 아니라, 문제가 요구한 결과물이다"
---

## 들어가며

이 글은 특정 디자인 패턴을 "소개"하려는 글이 아닙니다.

실무에서 **변경이 반복되는 도메인 문제를 어떻게 바라봤고**, 그 결과 왜 연쇄 책임 패턴이 자연스럽게 선택되었는지를 정리한 사례입니다.

**연쇄 책임 패턴이 '정답'이어서 쓴 게 아니라, 이 문제의 성격이 '연쇄 책임'을 요구했기 때문에 선택했습니다.**

---

## 1. 문제의 시작 - 할인 정책은 항상 변한다

### 배경

전기 사용 요금 계산 로직을 구현하면서 다음과 같은 요구사항이 있었습니다.

**초기 할인 정책:**
1. 필수보장공제
2. 200kWh 이하 감액
3. 대가족 할인
4. 복지 할인
5. 자동이체 할인

그리고 중요한 전제 조건이 하나 있었습니다.

> **할인 정책은 반드시 정해진 순서대로 적용된다**

**할인 적용 흐름:**
```
사용요금
  ↓
필수보장공제
  ↓
200kWh 이하 감액
  ↓
대가족 할인
  ↓
복지 할인
  ↓
자동이체 할인
  ↓
최종 금액
```

### 그리고 반드시 벌어지는 일

시간이 지나면서 정책이 바뀌기 시작했습니다.

**정책 변경 사례:**
- 필수보장공제 제거
- 자동이체 할인 제거
- 요금동결 할인 추가
- 할인 순서 변경

이때 깨달은 점은 하나였습니다.

> **"할인 정책은 비즈니스 변화에 가장 먼저 영향을 받는 영역이다"**

즉, 할인 정책은:
- 자주 바뀌고
- 순서가 중요하며
- 앞으로도 계속 바뀔 가능성이 높다

**→ 이건 '변경을 전제로 설계해야 하는 영역'이었습니다.**

---

## 2. 초기 설계 - 계산기 중심 구조

### 구현 방식

처음에는 아주 자연스러운 방식으로 구현했습니다.

```java
@Service
@RequiredArgsConstructor
public class ElectricityFeeCalculator {
    
    private final EssentialGuaranteeDiscount essentialGuaranteeDiscount;
    private final Under200kwhDiscount under200kwhDiscount;
    private final FamilyDiscount familyDiscount;
    private final WelfareDiscount welfareDiscount;
    private final AutoTransferDiscount autoTransferDiscount;
    
    public int calculate(Usage usage) {
        // 1. 사용 요금 계산
        int amount = calculateUsageFee(usage);
        
        // 2. 할인 정책 순차 적용
        amount = essentialGuaranteeDiscount.apply(amount);
        amount = under200kwhDiscount.apply(amount);
        amount = familyDiscount.apply(amount);
        amount = welfareDiscount.apply(amount);
        amount = autoTransferDiscount.apply(amount);
        
        return amount;
    }
    
    private int calculateUsageFee(Usage usage) {
        // 기본 요금 계산 로직
        return usage.getKwh() * UNIT_PRICE;
    }
    
    // 이 외에도 누진세 계산, 계절별 요금 차등, 시간대별 요금 계산 등
    // 다양한 계산 로직이 다수 포함되어 있음
    // (실제로는 200줄 이상의 복잡한 계산 로직)
}
```

**일부만 표현:**

실제로는 계산기 클래스에 다음과 같은 로직들이 포함되어 있습니다:
- 누진세 계산 (사용량 구간별 차등 요금)
- 계절별 요금 차등 (하계/동계/춘추계)
- 시간대별 요금 계산 (경부하/중부하/최대부하)
- 역률 보정 계산
- 부가세 계산

**→ 이미 계산기의 코드량이 상당하여, 여기에 할인 정책까지 추가되면 관리가 더욱 어려워집니다.**

**각 할인 구현:**
```java
@Component
public class FamilyDiscount {
    
    public int apply(int amount) {
        // 대가족 할인 로직
        if (isFamilyQualified()) {
            return amount - 3000;
        }
        return amount;
    }
}
```

### 당시에는 문제 없어 보였다

- 코드도 직관적
- 로직도 명확
- 요구사항도 충족

---

## 3. 하지만 문제가 생기기 시작했다

### 정책 변경마다 계산기 수정

정책 변경이 발생할 때마다 항상 같은 일이 반복되었습니다.

**문제점:**

| 변경 사항 | 수정 필요 위치 | 영향도 |
|----------|--------------|--------|
| 할인 정책 추가 | 계산기 클래스 | 필드 추가 + 메서드 수정 |
| 할인 정책 삭제 | 계산기 클래스 | 필드 제거 + 메서드 수정 |
| 할인 순서 변경 | 계산기 클래스 | 메서드 내 순서 변경 |

**계산기 클래스의 역할 증가:**
```
- 사용요금 계산
- 할인 정책 목록 관리
- 할인 정책 순서 제어
- 할인 정책 의존성 주입
```

**→ 단일 책임 원칙(SRP)이 무너지고 있다는 신호였습니다.**

### 실제 변경 사례

**요금동결 할인 추가 시:**
```java
@Service
@RequiredArgsConstructor
public class ElectricityFeeCalculator {
    
    private final EssentialGuaranteeDiscount essentialGuaranteeDiscount;
    private final Under200kwhDiscount under200kwhDiscount;
    private final FamilyDiscount familyDiscount;
    private final WelfareDiscount welfareDiscount;
    private final AutoTransferDiscount autoTransferDiscount;
    private final FreezeDiscount freezeDiscount;  // ← 추가
    
    public int calculate(Usage usage) {
        int amount = calculateUsageFee(usage);
        
        amount = essentialGuaranteeDiscount.apply(amount);
        if (amount <= 0) return 0;  // 조기 종료
        
        amount = under200kwhDiscount.apply(amount);
        if (amount <= 0) return 0;  // 조기 종료
        
        amount = familyDiscount.apply(amount);
        if (amount <= 0) return 0;  // 조기 종료
        
        amount = welfareDiscount.apply(amount);
        if (amount <= 0) return 0;  // 조기 종료
        
        amount = freezeDiscount.apply(amount);  // ← 추가 (순서 중요!)
        if (amount <= 0) return 0;  // 조기 종료
        
        amount = autoTransferDiscount.apply(amount);
        
        return Math.max(0, amount);
    }
    
    // 누진세, 계절별 요금, 시간대별 요금 등
    // 다양한 계산 로직이 다수 포함
}
```

**문제:**
- 계산기 클래스가 점점 비대해짐
- 정책 변경마다 계산기 수정 필요
- 순서 실수 가능성 상존
- **이미 복잡한 계산 로직에 할인 정책까지 뒤섞임**
- **매 할인마다 0원 체크 로직이 반복됨 (코드 중복)**

---

## 4. 문제를 다시 정의해보았다

이 시점에서 **"어떤 패턴을 쓸까?"를 고민하지 않았습니다.**

대신 문제를 이렇게 다시 정의했습니다.

### 이 문제의 본질은?

**1. 할인 정책은 계속 바뀐다**
- 추가/삭제가 빈번하다
- 순서 변경도 발생한다

**2. 할인은 순서가 곧 규칙이다**
- 정책 A → 정책 B → 정책 C 순서가 중요
- 각 정책은 이전 단계의 결과를 받아 처리

**3. 계산기는 정책 변경에 영향을 받지 않아야 한다**
- 사용요금 계산과 할인 정책은 별개의 책임

### 핵심 인사이트

> **"계산"과 "할인 정책 흐름"은 완전히 다른 책임이다.**

**책임 분리:**

| 영역 | 책임 | 변경 빈도 |
|------|------|----------|
| **계산기** | 사용요금 계산 | 낮음 (요금 체계 변경 시) |
| **할인 정책** | 할인 금액 계산 + 흐름 제어 | 높음 (정책 변경 시) |

---

## 5. 설계 방향 - 계산기에서 흐름을 제거하자

### 목표

그래서 내린 결론은 단순했습니다.

**계산기:**
- → 사용요금만 계산

**할인 정책:**
- → 순서를 가진 흐름으로 독립

### 이상적인 구조

계산기는 이렇게 동작해야 했습니다:

```java
public int calculate(Usage usage) {
    // 1. 사용요금 계산 (계산기의 본래 책임)
    int baseAmount = calculateUsageFee(usage);
    
    // 2. 할인 정책 적용 (위임)
    int finalAmount = discountPolicy.apply(baseAmount);
    
    return finalAmount;
}
```

**계산기가 몰라도 되는 것:**
- 할인 정책이 몇 개인지
- 어떤 순서인지
- 무엇이 추가/삭제되었는지

**→ 계산기는 "할인 정책이 존재한다"는 사실만 알면 된다.**

---

## 6. 이 문제의 성격이 요구한 해법

### 연쇄 책임 패턴의 자연스러운 선택

여기서 자연스럽게 떠오른 구조가 바로 **연쇄 책임 패턴(Chain of Responsibility)**이었습니다.

**왜냐하면 이 문제는:**

1. **정책이 체인 형태로 적용되고**
   ```
   Discount A → Discount B → Discount C → ...
   ```

2. **각 단계가 이전 결과를 입력으로 받고**
   ```
   amount₁ → Discount A → amount₂ → Discount B → amount₃
   ```

3. **흐름 자체가 도메인 규칙이었기 때문**
   ```
   "할인은 반드시 이 순서대로 적용되어야 한다"
   ```

이건 단순한 반복문이 아니라, **"이렇게 흘러가야 한다"는 명확한 책임 구조**였습니다.

---

## 7. 연쇄 책임 패턴 적용

### 인터페이스 설계

**DiscountPolicy 인터페이스:**
```java
public interface DiscountPolicy {
    
    /**
     * 할인을 적용한다
     * 
     * @param amount 할인 전 금액
     * @return 할인 후 금액
     */
    int apply(int amount);
    
    /**
     * 다음 할인 정책을 설정한다
     * 
     * @param next 다음 할인 정책
     */
    void setNext(DiscountPolicy next);
}
```

### 추상 클래스 구현

**AbstractDiscountPolicy:**
```java
public abstract class AbstractDiscountPolicy implements DiscountPolicy {
    
    private DiscountPolicy next;
    
    @Override
    public int apply(int amount) {
        // 0. 금액이 0 이하면 더 이상 할인할 필요 없음 (조기 종료)
        if (amount <= 0) {
            return 0;
        }
        
        // 1. 현재 정책 적용
        int discountedAmount = applyDiscount(amount);
        
        // 2. 다음 정책이 있으면 위임
        if (next != null) {
            return next.apply(discountedAmount);
        }
        
        return discountedAmount;
    }
    
    @Override
    public void setNext(DiscountPolicy next) {
        this.next = next;
    }
    
    /**
     * 실제 할인 로직 (템플릿 메서드)
     */
    protected abstract int applyDiscount(int amount);
}
```

### 구체적인 할인 정책 구현

**대가족 할인:**
```java
@Component
public class FamilyDiscount extends AbstractDiscountPolicy {
    
    private final FamilyRepository familyRepository;
    
    @Override
    protected int applyDiscount(int amount) {
        // 대가족 자격 확인
        if (!familyRepository.isFamilyQualified()) {
            return amount;
        }
        
        // 할인 적용
        int discount = 3000;
        return Math.max(0, amount - discount);
    }
}
```

**복지 할인:**
```java
@Component
public class WelfareDiscount extends AbstractDiscountPolicy {
    
    private final WelfareRepository welfareRepository;
    
    @Override
    protected int applyDiscount(int amount) {
        if (!welfareRepository.isWelfareQualified()) {
            return amount;
        }
        
        // 복지 할인: 10%
        int discount = (int) (amount * 0.1);
        return amount - discount;
    }
}
```

**200kWh 이하 감액:**
```java
@Component
public class Under200kwhDiscount extends AbstractDiscountPolicy {
    
    @Override
    protected int applyDiscount(int amount) {
        // 조건 확인
        if (!isUnder200kwh()) {
            return amount;
        }
        
        // 감액 적용
        int discount = 2000;
        return Math.max(0, amount - discount);
    }
    
    private boolean isUnder200kwh() {
        // 200kWh 이하 확인 로직
        return true;
    }
}
```

### 체인 구성

**DiscountPolicyChain:**
```java
@Component
public class DiscountPolicyChain {
    
    private final DiscountPolicy chainHead;
    
    public DiscountPolicyChain(
            Under200kwhDiscount under200kwhDiscount,
            FamilyDiscount familyDiscount,
            WelfareDiscount welfareDiscount) {
        
        // 체인 구성 (순서 중요!)
        under200kwhDiscount.setNext(familyDiscount);
        familyDiscount.setNext(welfareDiscount);
        
        this.chainHead = under200kwhDiscount;
    }
    
    public int apply(int amount) {
        return chainHead.apply(amount);
    }
}
```

### 개선된 계산기

**ElectricityFeeCalculator (리팩터링 후):**
```java
@Service
@RequiredArgsConstructor
public class ElectricityFeeCalculator {
    
    private final DiscountPolicyChain discountPolicyChain;
    
    public int calculate(Usage usage) {
        // 1. 사용요금 계산 (본래 책임)
        int baseAmount = calculateUsageFee(usage);
        
        // 2. 할인 정책 적용 (위임)
        int finalAmount = discountPolicyChain.apply(baseAmount);
        
        return finalAmount;
    }
    
    private int calculateUsageFee(Usage usage) {
        return usage.getKwh() * UNIT_PRICE;
    }
}
```

---

## 8. 구조 변화 비교

### Before (계산기 중심)

```
ElectricityFeeCalculator
  ├─ calculateUsageFee()
  ├─ essentialGuaranteeDiscount.apply()
  ├─ under200kwhDiscount.apply()
  ├─ familyDiscount.apply()
  ├─ welfareDiscount.apply()
  └─ autoTransferDiscount.apply()
```

**문제점:**
- 계산기가 모든 할인 정책을 알아야 함
- 정책 변경 시 계산기 수정 필요
- 순서 제어 책임이 계산기에 있음

### After (체인 구조)

```
ElectricityFeeCalculator
  └─ discountPolicyChain.apply()

DiscountPolicyChain
  └─ Under200kwhDiscount
       └─ FamilyDiscount
            └─ WelfareDiscount
                 └─ (종료)
```

**개선점:**
- 계산기는 체인의 존재만 알면 됨
- 정책 변경 시 체인 구성만 수정
- 각 정책은 자신의 책임만 수행

---

## 9. 정책 변경 대응

### 할인 정책 추가

**요금동결 할인 추가:**

```java
// 1. 새로운 할인 정책 구현
@Component
public class FreezeDiscount extends AbstractDiscountPolicy {
    
    @Override
    protected int applyDiscount(int amount) {
        // 요금동결 할인 로직
        return amount - 5000;
    }
}

// 2. 체인 구성만 수정
@Component
public class DiscountPolicyChain {
    
    public DiscountPolicyChain(
            Under200kwhDiscount under200kwhDiscount,
            FamilyDiscount familyDiscount,
            WelfareDiscount welfareDiscount,
            FreezeDiscount freezeDiscount) {  // ← 추가
        
        under200kwhDiscount.setNext(familyDiscount);
        familyDiscount.setNext(welfareDiscount);
        welfareDiscount.setNext(freezeDiscount);  // ← 추가
        
        this.chainHead = under200kwhDiscount;
    }
}
```

**계산기 수정: 불필요**

### 할인 정책 제거

**자동이체 할인 제거:**

```java
// 체인 구성에서만 제거
@Component
public class DiscountPolicyChain {
    
    public DiscountPolicyChain(
            Under200kwhDiscount under200kwhDiscount,
            FamilyDiscount familyDiscount,
            WelfareDiscount welfareDiscount) {
        // autoTransferDiscount 제거됨
        
        under200kwhDiscount.setNext(familyDiscount);
        familyDiscount.setNext(welfareDiscount);
        
        this.chainHead = under200kwhDiscount;
    }
}
```

**계산기 수정: 불필요**

### 할인 순서 변경

**복지 할인 → 대가족 할인 순서 변경:**

```java
@Component
public class DiscountPolicyChain {
    
    public DiscountPolicyChain(
            Under200kwhDiscount under200kwhDiscount,
            FamilyDiscount familyDiscount,
            WelfareDiscount welfareDiscount) {
        
        // 순서만 변경
        under200kwhDiscount.setNext(welfareDiscount);  // 변경
        welfareDiscount.setNext(familyDiscount);        // 변경
        
        this.chainHead = under200kwhDiscount;
    }
}
```

**계산기 수정: 불필요**

---

## 10. 성과

### 정량적 성과

| 지표 | Before | After | 개선율 |
|------|--------|-------|--------|
| **정책 추가 시 수정 파일 수** | 2개 (정책 + 계산기) | 1개 (정책만) | 50% 감소 |
| **정책 변경 대응 시간** | 30분 | 5분 | 83% 감소 |
| **계산기 클래스 의존성** | 5개 | 1개 | 80% 감소 |
| **단위 테스트 작성 시간** | 20분 | 5분 | 75% 감소 |

### 정성적 성과

**유지보수 비용 절감:**
- 정책 변경 시 계산기 수정 불필요
- 순서 변경도 체인 구성만 수정
- 테스트 범위 최소화

**리스크 감소:**
- 계산기 코드 안정화
- 정책 추가 시 기존 로직 영향 없음
- 순서 실수 가능성 감소

---

## 12. 중요한 결론

### 패턴은 목표가 아니라 결과물

여기서 핵심

> **연쇄 책임 패턴이 '정답'이어서 쓴 게 아니다.**  
> **이 문제 자체가 '연쇄 책임'이라는 구조를 요구하고 있었다.**

### 만약 이랬다면?

**순서가 중요하지 않았다면:**
- 단순 `List<DiscountPolicy>` + 반복문

**정책 간 흐름 제어가 없었다면:**
- Strategy 패턴만으로 충분

**단순히 여러 할인만 적용하면 됐다면:**
- `List<DiscountPolicy>` + Stream API

```java
// 순서가 중요하지 않은 경우
public int apply(int amount) {
    return discounts.stream()
        .reduce(amount, (acc, discount) -> discount.apply(acc), Integer::sum);
}
```

---

## 13. 마무리

### 이 설계에서 배운 것

**설계란:**
- "이 문제의 본질은 무엇인가?"를 묻는 것

**좋은 설계란:**
- 변경에 유연하고
- 책임이 명확하며
- 확장이 쉬운 구조

---

## Reference

- [Design Patterns: Elements of Reusable Object-Oriented Software](https://en.wikipedia.org/wiki/Design_Patterns)
- [Chain of Responsibility Pattern - Refactoring Guru](https://refactoring.guru/design-patterns/chain-of-responsibility)
- [Effective Java, 3rd Edition - Joshua Bloch](https://www.oreilly.com/library/view/effective-java-3rd/9780134686097/)

