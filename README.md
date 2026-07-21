# CaffeinateGUI

AC 전원 연결 중에만 macOS 시스템 잠자기를 막는 메뉴바 앱.

## 동작 방식

- `/usr/bin/caffeinate -s -w <pid>`를 자식 프로세스로 실행/관리
  - `-s`: PreventSystemSleep assertion (AC 전원에서만 유효)
  - `-w`: 앱이 죽으면(크래시 포함) caffeinate도 즉시 종료 — 고아 assertion 방지
- 디스플레이 잠자기/잠금화면은 건드리지 않음
- 배터리 전환 시 메뉴바 아이콘/상태 자동 갱신
- 로그인 시 자동 시작 지원 (SMAppService)

## 빌드 및 설치

```sh
app/build.sh
```

`/Applications/CaffeinateGUI.app`으로 빌드·설치되고 바로 실행됩니다.

## 요구 사항

- macOS 13.0 이상
