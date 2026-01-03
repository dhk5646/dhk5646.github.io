---
title: "클린 코드로 배운 개발 철학"
categories: java
tags: [clean-code, refactoring, best-practice, code-quality]
excerpt: "if문과 for문만으로 코드를 짜던 개발자가 클린 코드를 만나 코드 작성의 기준을 세워가는 과정"
---

## 들어가며

NHN 입사하기 전, 부끄럽지만 **if문과 for문 위주로만 코드를 만들어 왔었다.**

그러다 NHN 입사 후 **코드 리뷰 활동과 개발 문화를 직접 경험**하면서 내가 많이 부족하다는 사실을 깨닫게 되었다.

다행히도 좋은 동료를 만났고, 동료의 추천으로 **"클린 코드"**라는 책을 읽게 되었다.

이후 동료와 함께 **퇴근 후 스터디**를 진행했고, 이 시간 덕분에 **코드를 어떻게 만들어 가야 하는지에 대한 나만의 철학(기준)**이 생겨나기 시작했다.

이 글에서는 클린 코드의 주요 방법론 중 실무에 적용하며 깨달은 내용을 정리한다.

---

## 1장. 깨끗한 코드

### 코드는 항상 존재한다

> 기계가 실행할 정도로 상세하게 요구사항을 명시하는 작업, 바로 이것이 프로그래밍이다.

앞으로 프로그래밍 언어의 추상화 수준은 점차 높아질 것이다.

하지만 **코드는 요구사항을 표현하는 언어**이며, 코드는 항상 존재할 것이다.

### 나쁜 코드의 대가

출시에 바빠 코드를 마구 짜다 보면, 어느 순간 **기능을 추가할수록 코드는 엉망**이 되어간다.

나쁜 코드는 다음과 같은 문제를 일으킨다:
- 개발 속도 저하
- 코드 수정 시 엉뚱한 곳에서 문제 발생
- 생산성이 0에 근접
- 신규 인력 투입해도 더 나쁜 코드 양산

우리는 전문가다. **나쁜 코드의 위험을 이해하지 못하는 관리자 말을 그대로 따르는 행동은 전문가답지 못하다.**

### 깨끗한 코드란?

**비야네 스트롭스트룹 (C++ 창시자):**
> 나는 우아하고 효율적인 코드를 좋아한다. 논리가 간단해야 버그가 숨어들지 못한다. 깨끗한 코드는 한 가지를 제대로 한다.

**그래디 부치:**
> 깨끗한 코드는 단순하고 직접적이다. 깨끗한 코드는 잘 쓴 문장처럼 읽힌다.

**마이클 페더스:**
> 깨끗한 코드는 언제나 누군가 주의 깊게 짰다는 느낌을 준다. 고치려고 살펴봐도 딱히 손 댈 곳이 없다.

**워드 커닝햄 (위키 창시자):**
> 코드를 읽으면서 짐작했던 기능을 각 루틴이 그대로 수행한다면 깨끗한 코드라 불러도 되겠다.

**정리:**
- 가독성이 좋아야 한다 (읽기 좋은 코드)
- 다른 사람이 고치기 쉬워야 한다
- 한 가지에 집중해야 한다
- 중복을 피해야 한다
- 테스트 케이스가 있어야 한다

### 보이스카우트 원칙

> 캠프장은 처음 왔을 때보다 더 깨끗하게 해놓고 떠나라.

코드도 마찬가지다. 시간이 지나도 언제나 깨끗하게 유지해야 한다.

---

## 2장. 의미 있는 이름

### 의도를 분명히 밝혀라

변수나 함수, 클래스 이름은 다음 질문에 모두 답해야 한다:
- 존재 이유는?
- 수행 기능은?
- 사용 방법은?

**따로 주석이 필요하다면 의도를 분명히 드러내지 못했다는 뜻이다.**

**나쁜 예:**
```java
public List<int[]> getThem() {
    List<int[]> list1 = new ArrayList<>();
    for (int[] x : theList)
        if (x[0] == 4)
            list1.add(x);
    return list1;
}
```

**좋은 예:**
```java
public List<Cell> getFlaggedCells() {
    List<Cell> flaggedCells = new ArrayList<>();
    for (Cell cell : gameBoard)
        if (cell.isFlagged())
            flaggedCells.add(cell);
    return flaggedCells;
}
```

### 그릇된 정보를 피하라

- 널리 쓰이는 의미가 있는 단어를 다른 의미로 사용하지 말라
- 서로 흡사한 이름을 사용하지 말라
- 유사한 개념은 유사한 표기법을 사용하라

### 발음하기 쉬운 이름을 사용하라

```java
// Bad
class DtaRcrd102 {
    private Date genymdhms;
    private Date modymdhms;
}

// Good
class Customer {
    private Date generationTimestamp;
    private Date modificationTimestamp;
}
```

### 클래스 이름

클래스 이름은 **명사나 명사구**가 적합하다.

- 좋은 예: `Customer`, `WikiPage`, `Account`, `AddressParser`
- 나쁜 예: `Manager`, `Processor`, `Data`, `Info`

### 메서드 이름

메서드 이름은 **동사나 동사구**가 적합하다.

- 좋은 예: `postPayment`, `deletePage`, `save`

생성자를 중복정의할 때는 **정적 팩토리 메서드**를 사용한다:

```java
// Bad
Complex fulcrumPoint = new Complex(23.0);

// Good
Complex fulcrumPoint = Complex.FromRealNumber(23.0);
```

### 한 개념에 한 단어를 사용하라

추상적인 개념 하나에 단어 하나를 선택해 이를 고수한다.

예: `fetch`, `retrieve`, `get`을 혼용하지 말고 하나로 통일

---

## 3장. 함수

### 작게 만들어라

함수를 만드는 첫 번째 규칙은 **'작게!'** 이다.

함수를 만드는 두 번째 규칙은 **'더 작게!'** 이다.

**블록과 들여쓰기:**
- if/else문, while문 블록은 한 줄이어야 한다
- 함수 들여쓰기 수준은 1~2단을 넘으면 안 된다

### 한 가지만 해라

> 함수는 한 가지를 해야 한다. 그 한 가지를 잘 해야 한다. 그 한 가지만을 해야 한다.

함수가 '한 가지'만 하는지 판단하는 방법:
- 기존 함수에서 의미 있는 이름으로 다른 함수를 추출할 수 있다면, 그 함수는 여러 작업을 하는 것이다.

### 함수 당 추상화 수준은 하나로

함수 내 모든 문장의 추상화 수준이 동일해야 한다.

코드는 **위에서 아래로 이야기처럼 읽혀야** 좋다.

### Switch 문

Switch 문은 작게 만들기 어렵고, N가지 일을 처리한다.

**다형성과 추상 팩토리**를 사용하여 개선할 수 있다.

**리팩터링 전:**
```java
public Money calculatePay(Employee e) throws InvalidEmployeeType {
    switch (e.type) {
        case COMMISSIONED:
            return calculateCommissionedPay(e);
        case HOURLY:
            return calculateHourlyPay(e);
        case SALARIED:
            return calculateSalariedPay(e);
        default:
            throw new InvalidEmployeeType(e.type);
    }
}
```

**문제점:**
- 함수가 길다
- '한 가지' 작업만 수행하지 않는다
- SRP 위반
- OCP 위반

**리팩터링 후:**
```java
public abstract class Employee {
    public abstract Money calculatePay();
}

public class CommissionedEmployee extends Employee {
    public Money calculatePay() { /* ... */ }
}

public class HourlyEmployee extends Employee {
    public Money calculatePay() { /* ... */ }
}

public interface EmployeeFactory {
    Employee makeEmployee(EmployeeRecord r) throws InvalidEmployeeType;
}

public class EmployeeFactoryImpl implements EmployeeFactory {
    public Employee makeEmployee(EmployeeRecord r) throws InvalidEmployeeType {
        switch(r.type) {
            case COMMISSIONED:
                return new CommissionedEmployee(r);
            case HOURLY:
                return new HourlyEmployee(r);
            case SALARIED:
                return new SalariedEmployee(r);
            default:
                throw new InvalidEmployeeType(r.type);
        }
    }
}
```

### 서술적인 이름을 사용하라

함수가 작고 단순할수록 서술적인 이름을 짓기 쉬워진다.

예: `isTestable`, `includeSetupAndTeardownPages`

### 함수 인수

이상적인 인수 개수는 **0개**다. 최대 2개까지가 좋다.

**플래그 인수는 추하다.** 함수가 한꺼번에 여러 가지를 처리한다고 대놓고 공표하는 것이기 때문이다.

### 부수 효과를 일으키지 마라

함수명에서 예상할 수 없는 동작을 하지 말아야 한다.

### 명령과 조회를 분리하라

함수는 뭔가를 수행하거나 뭔가에 답하거나 **둘 중 하나만** 해야 한다.

### 오류 코드보다 예외를 사용하라

```java
// Bad
if (deletePage(page) == E_OK) {
    // ...
}

// Good
try {
    deletePage(page);
} catch (Exception e) {
    logger.log(e.getMessage());
}
```

### 반복하지 마라 (DRY)

> 중복은 소프트웨어에서 모든 악의 근원이다.

---

## 4장. 주석

코드는 변화하고 진화한다. 하지만 주석은 함께 변화하지 못하는 경우가 많다.

주석은 부정확한 정보를 제공하는 경우가 많다.

### 주석은 나쁜 코드를 보완하지 못한다

코드에 주석을 추가하는 일반적인 이유는 **코드 품질이 나쁘기 때문**이다.

### 코드로 의도를 표현하라

```java
// Bad
// 직원에게 복지 혜택을 받을 자격이 있는지 검사한다.
if ((employee.flags & HOURLY_FLAG) && (employee.age > 65))

// Good
if (employee.isEligibleForFullBenefits())
```

### 좋은 주석

1. **법적인 주석**: 저작권 정보
2. **정보를 제공하는 주석**: 정규표현식 설명
3. **의도를 설명하는 주석**
4. **TODO 주석**
5. **중요성을 강조하는 주석**

### 나쁜 주석

1. 주절거리는 주석
2. 같은 이야기를 중복하는 주석
3. 오해할 여지가 있는 주석
4. 의무적으로 다는 주석
5. 이력을 기록하는 주석
6. 있으나 마나 한 주석
7. 주석으로 처리한 코드

---

## 5장. 형식 맞추기

### 적절한 행 길이를 유지하라

대표적인 프로젝트(JUnit, FitNesse 등)를 조사한 결과:
- 대부분 200줄 정도의 파일로도 커다란 시스템 구축 가능
- 일반적으로 큰 파일보다 작은 파일이 이해하기 쉬움

### 신문 기사처럼 작성하라

- 이름은 간단하면서도 설명 가능하게
- 소스 파일 첫 부분은 고차원 개념과 알고리즘 설명
- 아래로 내려갈수록 의도를 세세하게 묘사
- 마지막에는 가장 저차원 함수와 세부 내역

### 개념은 빈 행으로 분리하라

```java
package fitnesse.wikitext.widgets;

import java.util.regex.*;

public class BoldWidget extends ParentWidget {
    public static final String REGEXP = "'''.+?'''";
    private static final Pattern pattern = Pattern.compile("'''(.+?)'''");
    
    public BoldWidget(ParentWidget parent, String text) throws Exception {
        super(parent);
        Matcher match = pattern.matcher(text);
        match.find();
        addChildWidgets(match.group(1));
    }
}
```

### 세로 밀집도

서로 밀접한 개념은 세로로 가까이 둬야 한다.

**변수 선언:**
- 지역 변수: 함수 맨 처음에 선언
- 인스턴스 변수: 클래스 맨 처음에 선언

**종속 함수:**
- 한 함수가 다른 함수를 호출한다면 두 함수는 세로로 가까이 배치
- 호출하는 함수를 호출되는 함수보다 먼저 배치

### 들여쓰기

간단한 if문, 짧은 while문에서도 들여쓰기 규칙을 무시하지 말라.

```java
// Bad
public class CommentWidget extends TextWidget {
    public CommentWidget(ParentWidget parent, String text) {super(parent, text);}
    public String render() throws Exception {return "";}
}

// Good
public class CommentWidget extends TextWidget {
    
    public CommentWidget(ParentWidget parent, String text) {
        super(parent, text);
    }
    
    public String render() throws Exception {
        return "";
    }
}
```

---

## 6장. 객체와 자료 구조

### 자료 추상화

변수를 비공개로 정의하는 이유는 **남들이 변수에 의존하지 않게 만들고 싶어서**다.

그런데 많은 프로그래머가 getter, setter를 당연하게 공개해 비공개 변수를 외부에 노출한다.

**추상 인터페이스를 제공해 사용자가 구현을 모른 채 자료의 핵심을 조작할 수 있어야 진정한 의미의 클래스다.**

### 디미터 법칙

> 모듈은 자신이 조작하는 객체의 속사정을 몰라야 한다.

객체는 자료를 숨기고 함수를 공개한다. 즉, 객체는 조회 함수로 내부 구조를 공개하면 안 된다.

```java
// Bad - 기차 충돌
final String outputDir = ctxt.getOptions().getScratchDir().getAbsolutePath();

// Good
Options opts = ctxt.getOptions();
File scratchDir = opts.getScratchDir();
final String outputDir = scratchDir.getAbsolutePath();

// Better - 객체에게 뭔가를 시키자
BufferedOutputStream bos = ctxt.createScratchFileStream(classFileName);
```

### 자료 전달 객체 (DTO)

DTO는 **자료 구조**이다:
- 공개 변수만 있고 함수가 없는 클래스
- 데이터베이스와 통신하거나 소켓에서 받은 메시지를 파싱할 때 유용

**DTO는 간단한 탐색 함수는 제공하되, 비즈니스 규칙을 담아서는 안 된다.**

### 결론

- **객체**: 동작을 공개하고 자료를 숨긴다
  - 기존 동작을 변경하지 않으면서 새 객체 타입 추가는 쉬움
  - 기존 객체에 새 동작 추가는 어려움

- **자료 구조**: 별다른 동작 없이 자료를 노출한다
  - 기존 자료 구조에 새 동작 추가는 쉬움
  - 기존 함수에 새 자료 구조 추가는 어려움

---

## 7장. 오류 처리

### 오류 코드보다 예외를 사용하라

```java
// Bad
if (deletePage(page) == E_OK) {
    if (registry.deleteReference(page.name) == E_OK) {
        if (configKeys.deleteKey(page.name.makeKey()) == E_OK) {
            logger.log("page deleted");
        } else {
            logger.log("configKey not deleted");
        }
    } else {
        logger.log("deleteReference from registry failed");
    }
} else {
    logger.log("delete failed");
    return E_ERROR;
}

// Good
try {
    deletePage(page);
    registry.deleteReference(page.name);
    configKeys.deleteKey(page.name.makeKey());
} catch (Exception e) {
    logger.log(e.getMessage());
}
```

### Try-Catch-Finally 문부터 작성하라

try 블록은 **트랜잭션과 비슷**하다.

try 블록에서 무슨 일이 생기든지 catch 블록은 프로그램 상태를 일관성 있게 유지해야 한다.

### 미확인 예외를 사용하라

확인된 예외(Checked Exception)는 OCP를 위반한다.

하위 단계에서 코드를 변경하면 상위 단계 메서드 선언부를 전부 고쳐야 한다.

### 호출자를 고려해 예외 클래스를 정의하라

**리팩터링 전:**
```java
ACMEPort port = new ACMEPort(12);

try {
    port.open();
} catch (DeviceResponseException e) {
    reportPortError(e);
    logger.log("Device response exception", e);
} catch (ATM1212UnlockedException e) {
    reportPortError(e);
    logger.log("Unlock exception", e);
} catch (GMXError e) {
    reportPortError(e);
    logger.log("Device response exception");
} finally {
    // ...
}
```

**리팩터링 후:**
```java
LocalPort port = new LocalPort(12);

try {
    port.open();
} catch (PortDeviceFailure e) {
    reportError(e);
    logger.log(e.getMessage(), e);
} finally {
    // ...
}

// Wrapper 클래스
public class LocalPort {
    private ACMEPort innerPort;
    
    public LocalPort(int portNumber) {
        innerPort = new ACMEPort(portNumber);
    }
    
    public void open() {
        try {
            innerPort.open();
        } catch (DeviceResponseException e) {
            throw new PortDeviceFailure(e);
        } catch (ATM1212UnlockedException e) {
            throw new PortDeviceFailure(e);
        } catch (GMXError e) {
            throw new PortDeviceFailure(e);
        }
    }
}
```

**외부 API를 감싸는 장점:**
- 외부 라이브러리와 프로그램 사이의 의존성 감소
- 나중에 다른 라이브러리로 갈아타기 쉬움
- 테스트하기 쉬워짐
- 특정 업체가 API를 설계한 방식에 종속되지 않음

### null을 반환하지 마라

```java
// Bad
public void registerItem(Item item) {
    if (item != null) {
        ItemRegistry registry = peristentStore.getItemRegistry();
        if (registry != null) {
            Item existing = registry.getItem(item.getID());
            if (existing.getBillingPeriod().hasRetailOwner()) {
                existing.register(item);
            }
        }
    }
}

// Good
List<Employee> employees = getEmployees();
for (Employee e : employees) {
    totalPay += e.getPay();
}

public List<Employee> getEmployees() {
    if (직원이 없다면)
        return Collections.emptyList();
}
```

### null을 전달하지 마라

메서드로 null을 전달하는 방식은 더 나쁘다.

정상적인 인수로 null을 기대하는 API가 아니라면 메서드로 null을 전달하는 코드는 최대한 피한다.

---

## 9장. 단위 테스트

### TDD 법칙 세 가지

1. **실패하는 단위 테스트를 작성할 때까지** 실제 코드를 작성하지 않는다
2. **컴파일은 실패하지 않으면서 실행이 실패하는 정도로만** 단위 테스트를 작성한다
3. **현재 실패하는 테스트를 통과할 정도로만** 실제 코드를 작성한다

### 깨끗한 테스트 코드 유지하기

**테스트 코드는 실제 코드 못지않게 중요하다.**

테스트 코드를 깨끗하게 유지하지 않으면 결국은 잃어버린다.

**테스트는 유연성, 유지보수성, 재사용성을 제공한다:**
- 테스트 케이스가 있으면 변경이 두렵지 않다
- 테스트 케이스가 없으면 모든 변경이 잠정적인 버그다

### 깨끗한 테스트 코드

깨끗한 테스트 코드를 만들려면 세 가지가 필요하다:
- **가독성**
- **가독성**
- **가독성**

테스트 코드는 **최소의 표현으로 많은 것을 나타내야** 한다.

**좋은 예:**
```java
public void testGetPageHierarchyAsXml() throws Exception {
    makePages("PageOne", "PageOne.ChildOne", "PageTwo");
    
    submitRequest("root", "type:pages");
    
    assertResponseIsXML();
    assertResponseContains(
        "<name>PageOne</name>", 
        "<name>PageTwo</name>", 
        "<name>ChildOne</name>"
    );
}
```

### 테스트 당 assert 하나

JUnit으로 테스트 코드를 짤 때는 **함수마다 assert 문을 단 하나만** 사용하는 것을 권장한다.

하지만 때로는 함수 하나에 여러 assert 문을 넣기도 한다.

단지 **assert 문 개수는 최대한 줄여야 좋다.**

**테스트 함수 하나는 개념 하나만 테스트하라.**

### F.I.R.S.T.

깨끗한 테스트는 다음 다섯 가지 규칙을 따른다:

**Fast (빠르게):**
- 테스트는 빨라야 한다
- 느리면 자주 돌릴 엄두를 못 낸다

**Independent (독립적으로):**
- 각 테스트는 서로 의존하면 안 된다
- 한 테스트가 다음 테스트 환경을 준비해서는 안 된다

**Repeatable (반복가능하게):**
- 테스트는 어떤 환경에서도 반복 가능해야 한다
- 실제 환경, QA 환경, 네트워크 없는 환경에서도 실행 가능해야 한다

**Self-Validating (자가검증하는):**
- 테스트는 bool 값으로 결과를 내야 한다
- 성공 아니면 실패

**Timely (적시에):**
- 테스트는 적시에 작성해야 한다
- 단위 테스트는 테스트하려는 실제 코드를 구현하기 직전에 구현한다

---

## 10장. 클래스

### 클래스는 작아야 한다

클래스를 만들 때 첫 번째 규칙은 크기다. **클래스는 작아야 한다.**

클래스를 설계할 때도, 함수와 마찬가지로, **'작게'가 기본 규칙**이다.

### 단일 책임 원칙 (SRP)

**클래스나 모듈을 변경할 이유가 하나, 단 하나뿐이어야 한다.**

SRP는 '책임'이라는 개념을 정의하며 적절한 클래스 크기를 제시한다.

**큰 클래스 몇 개가 아니라 작은 클래스 여럿으로 이뤄진 시스템이 더 바람직하다.**

### 응집도 (Cohesion)

클래스는 인스턴스 변수 수가 작아야 한다.

일반적으로 메서드가 변수를 더 많이 사용할수록 메서드와 클래스는 **응집도가 더 높다.**

**'함수를 작게, 매개변수 목록을 짧게'** 전략을 따르다 보면 때때로 몇몇 메서드만이 사용하는 인스턴스 변수가 많아진다.

이는 **새로운 클래스로 쪼개야 한다는 신호**다.

### 변경하기 쉬운 클래스

**리팩터링 전:**
```java
public class Sql {
    public Sql(String table, Column[] columns)
    public String create()
    public String insert(Object[] fields)
    public String selectAll()
    public String findByKey(String keyColumn, String keyValue)
    public String select(Column column, String pattern)
    public String select(Criteria criteria)
    // ...
}
```

**리팩터링 후:**
```java
abstract public class Sql {
    public Sql(String table, Column[] columns)
    abstract public String generate();
}

public class CreateSql extends Sql {
    public CreateSql(String table, Column[] columns)
    @Override public String generate()
}

public class SelectSql extends Sql {
    public SelectSql(String table, Column[] columns)
    @Override public String generate()
}

public class InsertSql extends Sql {
    public InsertSql(String table, Column[] columns, Object[] fields)
    @Override public String generate()
    private String valuesList(Object[] fields, final Column[] columns)
}
```

각 클래스는 극도로 단순하다. 

**SRP와 OCP를 모두 지원**한다.

---

## 12장. 창발성

### 창발적 설계로 깔끔한 코드를 구현하자

깔끔한 코드를 만드는 4가지 설계 규칙:
1. 모든 테스트를 실행한다
2. 중복을 없앤다
3. 프로그래머 의도를 표현한다
4. 클래스와 메서드 수를 최소로 줄인다

### 단순한 설계 규칙 1: 모든 테스트를 실행하라

테스트가 가능한 시스템을 만들려고 애쓰면 **설계 품질이 더불어 높아진다.**

- 크기가 작고 목적 하나만 수행하는 클래스가 나온다
- SRP를 준수하는 클래스는 테스트가 훨씬 더 쉽다
- 결합도가 높으면 테스트 케이스를 작성하기 어렵다

**"테스트 케이스를 만들고 계속 돌려라"**

이 간단한 규칙을 따르면 시스템은 낮은 결합도와 높은 응집력을 저절로 달성한다.

### 단순한 설계 규칙 2-4: 리팩터링

테스트 케이스를 모두 작성했다면 이제 **코드와 클래스를 정리**해도 괜찮다.

테스트 케이스가 있으니 코드를 정리하면서 시스템이 깨질까 걱정할 필요가 없다.

### 중복을 없애라

우수한 설계에서 **중복은 커다란 적**이다.

```java
// Before
int size() {}
boolean isEmpty() {}

// After
boolean isEmpty() {
    return 0 == size();
}
```

### 표현하라

코드는 개발자의 의도를 분명히 표현해야 한다:

1. **좋은 이름을 선택한다**
2. **함수와 클래스 크기를 가능한 줄인다**
3. **표준 명칭을 사용한다** (디자인 패턴)
4. **단위 테스트 케이스를 꼼꼼하게 작성한다**

**가장 중요한 방법은 노력이다.**

자신의 작품을 조금 더 자랑하기 위해 함수와 클래스에 조금 더 시간을 투자하자.

---

## 정리

### 클린 코드를 통해 배운 것

1. **작게 만들어라**
   - 함수도, 클래스도 작게
   - 한 가지만 하고, 그 한 가지를 잘하라

2. **의미 있는 이름**
   - 의도를 분명히
   - 발음하기 쉽고 검색하기 쉽게

3. **중복을 제거하라**
   - DRY (Don't Repeat Yourself)

4. **테스트 코드를 작성하라**
   - 테스트는 변경을 두렵지 않게 만든다

5. **깨끗하게 유지하라**
   - 보이스카우트 원칙
   - 코드 리뷰와 리팩터링

### 변화

클린 코드 스터디 전:
```java
// if문과 for문 위주
if (user != null) {
    if (user.getAge() > 18) {
        if (user.hasPermission()) {
            // 긴 로직...
        }
    }
}
```

클린 코드 스터디 후:
```java
// 의도가 명확한 메서드 분리
if (isAdultWithPermission(user)) {
    processUserRequest(user);
}

private boolean isAdultWithPermission(User user) {
    return user != null 
        && user.isAdult() 
        && user.hasPermission();
}

private void processUserRequest(User user) {
    // 명확한 책임을 가진 작은 메서드
}
```

### 마지막으로

클린 코드는 **단번에 만들어지지 않는다.**

- 일단 돌아가는 코드를 만든다
- 테스트 코드를 작성한다
- 리팩터링한다
- 코드 리뷰를 받는다
- 다시 개선한다

**좋은 동료와 함께 스터디하며 성장할 수 있었던 경험은 개발자로서 가장 큰 자산이 되었다.**

**"깨끗한 코드는 읽기 좋은 코드다. 읽기 좋은 코드는 변경하기 쉬운 코드다."**

---

## Reference

- 로버트 C. 마틴, 『클린 코드』, 인사이트(2013)
- [Clean Code 원서](https://www.amazon.com/Clean-Code-Handbook-Software-Craftsmanship/dp/0132350882)

