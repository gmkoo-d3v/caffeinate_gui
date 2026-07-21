#!/bin/zsh
# CaffeinateGUI 로컬 빌드·설치 스크립트.
# 산출물: /Applications/CaffeinateGUI.app (admin 사용자면 sudo 불필요)
# r01 리뷰 반영: 명시적 deployment target(13.0)+검증, 실행 중 앱의 확실한 종료
# 확인 후 교체, 서명 검증.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$APP_DIR/build"
BUNDLE="$BUILD_DIR/CaffeinateGUI.app"
# 표준 위치(/Applications) — Finder '응용 프로그램'·Launchpad·Spotlight에서 보임.
# 개인 맥에서 admin 사용자는 sudo 없이 쓰기 가능.
INSTALL_DIR="/Applications"
INSTALLED="$INSTALL_DIR/CaffeinateGUI.app"
INSTALLED_BIN="$INSTALLED/Contents/MacOS/CaffeinateGUI"
APP_PROC_NAME="CaffeinateGUI"
TARGET_ARCH="$(uname -m)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc -O -parse-as-library \
    -target "${TARGET_ARCH}-apple-macosx13.0" \
    "$APP_DIR/main.swift" \
    -o "$BUNDLE/Contents/MacOS/CaffeinateGUI" \
    -framework AppKit -framework ServiceManagement

# Info.plist(LSMinimumSystemVersion 13.0)와 바이너리 minos 일치 검증
MINOS="$(otool -l "$BUNDLE/Contents/MacOS/CaffeinateGUI" | awk '/LC_BUILD_VERSION/{f=1} f && /minos/{print $2; exit}')"
if [[ "$MINOS" != "13.0" ]]; then
    echo "ERROR: binary minos=$MINOS != 13.0 (Info.plist mismatch)" >&2
    exit 1
fi

cp "$APP_DIR/Info.plist" "$BUNDLE/Contents/Info.plist"

# 앱 아이콘 (make_icon.swift로 생성한 AppIcon.icns를 번들에 포함)
if [[ -f "$APP_DIR/AppIcon.icns" ]]; then
    cp "$APP_DIR/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# 로컬 앱의 SMAppService(로그인 항목) 등록에는 서명이 필요 — ad-hoc 서명.
# (재빌드 시 cdhash가 바뀌는 한계는 앱의 기동-시 재조정 로직이 복구한다)
codesign --force --sign - "$BUNDLE"
codesign --verify --strict "$BUNDLE"

# 실행 중이면 확실히 종료 확인 후 교체 (osascript 의존 제거 — TCC/무응답에 취약).
# 프로세스 '이름' 정확 일치(-x)를 쓰는 이유 두 가지 (r02 P2/P3):
#  1) 구 설치 경로(~/Applications 등)에서 돌던 인스턴스도 잡는다 — 안 잡으면 그
#     인스턴스가 flock을 쥔 채 남아 새 바이너리가 실행되지 못한다.
#  2) `pkill -f <경로>`는 부분/정규식 일치라 그 경로를 argv에 담은 무관한
#     프로세스(예: lldb <경로>)까지 죽일 수 있다.
if pgrep -x "$APP_PROC_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_PROC_NAME" || true
    for _ in {1..25}; do
        pgrep -x "$APP_PROC_NAME" >/dev/null 2>&1 || break
        sleep 0.2
    done
    if pgrep -x "$APP_PROC_NAME" >/dev/null 2>&1; then
        echo "ERROR: running app did not exit; aborting install" >&2
        exit 1
    fi
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED"
cp -R "$BUNDLE" "$INSTALLED"
codesign --verify --strict "$INSTALLED"

# 같은 번들ID 사본이 두 곳이면 LaunchServices가 혼동해 SMAppService.status가
# .notFound가 될 수 있다 — build 사본과 구버전 홈-폴더 설치본을 제거하고
# 설치본을 LS에 강제 등록한다.
rm -rf "$BUILD_DIR"
rm -rf "$HOME/Applications/CaffeinateGUI.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$INSTALLED" || true

echo "installed: $INSTALLED (minos $MINOS)"
echo "launching..."
open "$INSTALLED"

# 실행된 인스턴스가 정말 방금 설치한 사본인지 확인한다 (r02 P2): LaunchServices가
# 구 인스턴스를 activate만 하고 끝나면 스크립트는 성공처럼 보여도 새 바이너리는
# 돌지 않는다.
RUN_PID=""
for _ in {1..25}; do
    RUN_PID="$(pgrep -x "$APP_PROC_NAME" | head -1)"
    [[ -n "$RUN_PID" ]] && break
    sleep 0.2
done
RUN_PATH="$(ps -p "${RUN_PID:-0}" -o comm= 2>/dev/null || true)"
if [[ "$RUN_PATH" != "$INSTALLED_BIN" ]]; then
    echo "ERROR: running instance is not the installed copy: ${RUN_PATH:-<none>}" >&2
    exit 1
fi
echo "verified running: $RUN_PATH (pid $RUN_PID)"
