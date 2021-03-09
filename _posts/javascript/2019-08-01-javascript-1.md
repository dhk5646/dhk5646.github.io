---
title: "[JavaScript] Null 과 Undefined의 차이"
categories: JavaScript
tags: JavaScript
toc: true
---

## null 
변수를 선언 및 'null'이라는 빈 값을 초기 할당함 <br>

## undefined 
변수를 선언만 하고 값을 할당하지 않음. <br>



## 소스 코드 
~~~java
var nullValue = null;
console.log(nullValue); 
=> null

console.log(typeof nullValue); 
=> object


var undefinedValue;
console.log(undefinedValue); 
=> undefined

console.log(typeof undefinedValue); 
=> undefined
~~~

## 즉,
undefined는 자료형이 결정되지 않은 변수이고,
null은 자료형은 객체인데, 비어있는 변수이다.
