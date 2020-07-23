---
title: "세션(Session)"
categories: dev
tags: servlet_jsp
toc: true
---

## 세션(Session) 이란?
- 서버 측의 컨테이너에서 관리되는 정보
- 세션의 정보는 컨테이너에 접속해서 종료되기까지(브라우저를 종료할 때 까지) 유지된다.
- 접속시간에 제한을 두어(타임아웃설정) 일정 시간 응답이 없다면 세션을 삭제할 수 있다
- 보안이 필요한 정보를 공유하기 위해서는 서버 측에서 관리될 수 있는 세션을 이용하는 것이 좋다.  


## 세션 관련 서블릿 주요 메소드
- setAttribute(String name, Object value) : 세션 객체에 속성을 저장한다.
- removeAttribute(String name) : 저장된 속성을 제거한다.
- getAttribute(String name) : 저장된 속성을 반환한다.
- getId() : 클라이언트의 세션 ID 값을 반환한다.
- setMaxInactiveInterval(int seconds) : 세션의 유지 시간을 설정한다.
- getMaxInactiveInterval() : 세션의 유지 시간을 반환한다.
- invalidate() : 현재 세션 정보를 삭제한다.




## 세션 타임아웃 설정 우선순위

1. 자바 함수 - (setMaxInactiveInterval)
2. 서블릿 컨테이너(WEB-INF/web.xml)
3. 톰캣 WAS (conf/web.xml)

※ 세션타임아웃 설정을 하지 않을 경우 WAS default 타임아웃 설정을 따른다 (30분)

## (예제) 자바 함수(setMaxInactiveInterval)
~~~j
HttpSession session = se.getSession();
session.setMaxInactiveInterval(3600); //초 단위
~~~

## (예제) 서블릿 컨테이너(WEB-INF/web.xml)
~~~j
<session-config>
    <session-timeout>30</session-timeout> //분 단위
</session-config>
~~~

## (예제) 톰캣 WAS(conf/web.xml)
~~~j
<session-config>
    <session-timeout>30</session-timeout> //분 단위
</session-config>
~~~


## (예제) 세션리스너
~~~j
public class SessionListenerImpl implements HttpSessionListener {

	@Override
	public void sessionCreated(HttpSessionEvent se) {
		/* 세션이 생성될 때 호출되는 함수*/
	}
	
	@Override
	public void sessionDestroyed(HttpSessionEvent se) {
		/* 세션이 제거될 때 호출되는 함수*/	
	}
	
~~~