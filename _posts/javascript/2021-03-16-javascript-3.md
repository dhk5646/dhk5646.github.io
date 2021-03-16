---
title: "daum API 라이브러리를 활용한 우편번호 팝업 개발"
categories: JavaScript
tags: JavaScript
toc: true
---

## Intro 
운영업무를 하면서 주소정보를 년 단위로 구매하여 DB에 엎어 치는형식으로 관리하고 있었습니다. <br> 
이를 개선하고자 Daum 우편 API 를 적용하게 되었습니다. <br>
단, Daum 우편 api 서비스 점검 등의 이슈가 발생할 경우를 대비하여 기존 방식도 함께 사용하였음을 참고 바랍니다.


## 소스 코드 

- 사용전 daum api js를 includ 해야 합니다.

```javascript
<script src="//t1.daumcdn.net/mapjsapi/bundle/postcode/prod/postcode.v2.js"></script>
```

```javascript
function fn_getDaumAPost(type,zonecodeObj,addressObj,themeObj,callback) {
	
	if(type == "C"){
		if(zonecodeObj.value == ""){
			if(addressObj != null)
				addressObj.value = "";
			return;
		}
	}
	
	//가운데 정렬을 위함
	var width = 500; //팝업의 너비
	var height = 600; //팝업의 높이
	
	
	//아래 코드처럼 테마 객체를 생성합니다.(color값은 #F00, #FF0000 형식으로 입력하세요.)
	//변경되지 않는 색상의 경우 주석 또는 제거하시거나 값을 공백으로 하시면 됩니다.
	var theme = {
			   //bgColor: "#36C3C6" //바탕 배경색
			   //searchBgColor: "", //검색창 배경색
			   //contentBgColor: "", //본문 배경색(검색결과,결과없음,첫화면,검색서제스트)
			   //pageBgColor: "", //페이지 배경색
			   //textColor: "", //기본 글자색
			   //queryTextColor: "", //검색창 글자색
			   //postcodeTextColor: "", //우편번호 글자색
			   //emphTextColor: "", //강조 글자색
			   //outlineColor: "", //테두리
		};
	
	if(themeObj != null){
		theme =  themeObj;
	}
	
	
	new daum.Postcode({
		width: width, //생성자에 크기 값을 명시적으로 지정해야 합니다.
	    height: height,
	    oncomplete: function(data) { // 팝업에서 검색결과 항목을 클릭했을때 실행할 코드를 작성하는 부분.
            
            // 각 주소의 노출 규칙에 따라 주소를 조합한다.
            // 내려오는 변수가 값이 없는 경우엔 공백('')값을 가지므로, 이를 참고하여 분기 한다.
            var fullAddr = ''; // 최종 주소 변수
            var extraAddr = ''; // 조합형 주소 변수

            // 사용자가 선택한 주소 타입에 따라 해당 주소 값을 가져온다.
            if (data.userSelectedType === 'R') { // 사용자가 도로명 주소를 선택했을 경우
                fullAddr = data.roadAddress;

            } else { // 사용자가 지번 주소를 선택했을 경우(J)
                fullAddr = data.jibunAddress;
            }

            // 우편번호와 주소 정보를 해당 필드에 넣는다.
            zonecodeObj.value = data.zonecode; //5자리 새우편번호 사용
            
            if(addressObj != null)
            	addressObj.value = fullAddr;

            if(callback != null) {
	            var jsonString = JSON.stringify(data);
	
	            eval(callback+"("+jsonString+")");
            }
        }
    }).open({
				left: (window.screen.width / 2) - (width / 2)
				,top: (window.screen.height / 2) - (height / 2)
				,popupName: 'postcodePopup' // 다중 팝업 오픈 방지를 위함
				,theme:theme // 색상을 원하는 값으로 설정 하기위함
    	   });
}
```

### Reference
- [Daum 우편 API](https://postcode.map.daum.net/guide "Daum 우편 API")
