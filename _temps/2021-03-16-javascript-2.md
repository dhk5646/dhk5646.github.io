---
title: "ajax의 jsonp 를 활용한 크로스도메인 우회하여 통신하기"
categories: JavaScript
tags: JavaScript
toc: true
---

## Intro 
도메인이 같은 다른 시스템의 데이터를 받아서 처리하는 개발건이 발생하였고 프론트단에서 ajax를 활용하여 처리 하려고 하였으나 크로스 도메인 오류가 발생하였습니다. <br> 
(크로스 도메인에 대해서는 나중에 정리하도록 하겠습니다.) <br> 
간단하게 말하면 브라우저에서는 다른 시스템 간의 통신을 차단한다고 합니다. <br>
아무튼, **ajax의 dataType : jsonp** 를 이용하여 처리한 소스 내용을 기록합니다. 

## 소스 코드 
~~~javascript
/* 소스내용 */
function fn_Search(){
	
	//비동기 통신을 하여 json타입으로 호출한다. JSONP 타입을 통해 브라우저 웹보안을 우회한다. 
	$.ajax({   url: "http://woorimtech.aks.com/getData?no=1"
				 , type : "GET"
				 , dataType : 'jsonp'  //핵심!!
	});
}

/* 요청 url 정보가 callback 함수가 됩니다. */ 
function getData(data){
	 
	 if(data != null){
	  
	  	// data가 존재한다면 로직 작성 하면 됩니다.
	  	
	 }
}
~~~


