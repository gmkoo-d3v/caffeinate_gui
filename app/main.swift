// CaffeinateGUI — AC-전원 중에만 시스템 잠자기를 막는 메뉴바 앱.
// 메커니즘: /usr/bin/caffeinate -s -w <자기 pid> 자식 프로세스 관리.
//   -s  : PreventSystemSleep assertion (Apple 구현 자체가 AC 전원에서만 유효)
//   -w  : 이 앱이 죽으면(크래시 포함) caffeinate도 즉시 종료 — 고아 assertion 방지
// 디스플레이 잠자기/잠금화면은 건드리지 않는다 (잠금화면 ≠ 시스템 잠자기).
//
// r01 적대 리뷰(gpt-5.6-sol xhigh + fable-5 xhigh) 반영 사항:
//  - 프로세스 상태기계(current/retiring): OFF→ON 연타에도 이중 assertion 불가
//  - respawnGaveUp 상태에서 토글 = 재시도 (끄기가 아님)
//  - SMAppService 상태 전체 분기(.requiresApproval → 시스템 설정 열기)
//  - 최초 실행 시 로그인 항목 자동 등록 + 재빌드(cdhash 변경) 후 기동 시 재조정
//  - flock 기반 단일 인스턴스 (상호살상 경합 제거)
//  - 설치본(/Applications) 밖에서는 로그인 항목 등록 금지
//  - menuWillOpen마다 상태 재조회 (외부 변경 반영)

import AppKit
import Darwin
import IOKit.ps
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let defaults = UserDefaults.standard
    private let enabledKey = "preventSleepEnabled"
    // loginIntentKey의 "키 존재 여부" 자체가 최초-실행 sentinel이다. 별도
    // firstRun 키를 두면 (firstRun 기록 성공 + intent 기록 실패) 불일치 상태에서
    // 로그인 자동 시작이 영구 비무장될 수 있다 (r02 P2).
    private let loginIntentKey = "loginItemIntended"

    private var statusItem: NSStatusItem!
    private var stateLine: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    // 프로세스 상태기계: current = 활성, retiring = terminate 후 종료 대기.
    // 새 프로세스는 retiring이 완전히 죽은 뒤에만 시작된다(이중 assertion 방지).
    private var current: Process?
    private var retiring: Process?
    // 급속 재시작 루프 가드: 10초 창 안에서 3회 넘게 죽으면 자동 재시작 중단.
    private var respawnTimestamps: [Date] = []
    private var respawnGaveUp = false
    private var lockFD: Int32 = -1

    private var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }
    private var loginIntended: Bool {
        get { defaults.bool(forKey: loginIntentKey) }
        set { defaults.set(newValue, forKey: loginIntentKey) }
    }
    private var isInstalledCopy: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/CaffeinateGUI.app"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard acquireSingleInstanceLock() else {
            // 메뉴바 전용 앱이라 중복 실행이 조용히 죽으면 "실행이 안 된다"로
            // 보인다 — 명시적으로 알려주고 종료한다.
            let alert = NSAlert()
            alert.messageText = "CaffeinateGUI는 이미 실행 중입니다"
            alert.informativeText = "메뉴바(화면 오른쪽 위, 시계 근처)의 커피잔 아이콘으로 조작하세요. 아이콘이 안 보이면 메뉴바 공간 부족으로 가려졌을 수 있습니다."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        log("launch pid=\(ProcessInfo.processInfo.processIdentifier) installedCopy=\(isInstalledCopy)")
        buildMenu()
        reconcileLoginItem()
        registerPowerSourceObserver()
        if isEnabled { startCaffeinate() }
        refreshUI()
    }

    /// AC↔배터리 전환 시 아이콘/상태 표시를 즉시 갱신 (메뉴를 열지 않아도 반영).
    private func registerPowerSourceObserver() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { me.refreshUI() }
        }, context)?.takeRetainedValue() else { return }
        // commonModes: 메뉴가 열린 event-tracking 모드나 NSAlert 모달 중에도
        // 전원 변화가 반영되게 한다. defaultMode만 등록하면 메뉴를 열어둔 채
        // AC를 뽑았을 때 "작동 중" 표시가 stale하게 남는다 (r02 P3).
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    // MARK: - 파일 로그 (조용한 실패 진단용)

    private func log(_ message: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/CaffeinateGUI"
        let path = dir + "/app.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCaffeinate()
    }

    // MARK: - 단일 인스턴스 (flock — 원자적, 상호살상 경합 없음)

    private func acquireSingleInstanceLock() -> Bool {
        let dir = NSHomeDirectory() + "/Library/Application Support/CaffeinateGUI"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        lockFD = open(dir + "/instance.lock", O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else { return true } // lock 불가 환경이 실행을 막지는 않음
        return flock(lockFD, LOCK_EX | LOCK_NB) == 0
    }

    // MARK: - 로그인 항목 (SMAppService)

    /// 최초 실행: 자동 등록(설치 목적이 부팅 후 자동 보호이므로 기본 ON — 시스템
    /// 설정 > 로그인 항목에 표시되고 macOS가 추가 알림을 띄운다).
    /// 이후 실행: 사용자가 켜두길 원했는데(status가) 깨져 있으면(재빌드로 ad-hoc
    /// cdhash가 바뀐 경우 등) 재등록으로 복구한다. 사용자가 명시적으로 끈 상태는
    /// 절대 재등록하지 않는다.
    private func reconcileLoginItem() {
        guard isInstalledCopy else { return } // build/ 사본에서는 등록 금지
        let service = SMAppService.mainApp
        let isFirstRun = defaults.object(forKey: loginIntentKey) == nil
        log("reconcile: firstRun=\(isFirstRun) intended=\(loginIntended) status=\(service.status.rawValue)")
        // .notRegistered뿐 아니라 .notFound(LaunchServices가 앱을 못 찾는 상태 —
        // 재빌드 직후나 사본 혼동 시 관측됨)에서도 등록을 시도한다. register()가
        // 실패하면 그 오류가 로그에 남는다.
        let needsRegister = service.status != .enabled && service.status != .requiresApproval
        if isFirstRun {
            // 의도를 register 결과가 아니라 선-기록한다 (최종 게이트 N-1):
            // register 직후의 status 재판독은 경합성이 있어(실측: 등록 성공 후에도
            // stale 판독) false가 기록되면 자가치유가 비무장된다. 제품 의도는 기본
            // ON이며, 사용자가 메뉴에서 끄면 그때 false로 존중된다.
            // 이 쓰기가 곧 최초-실행 sentinel이므로, 쓰기 전에 프로세스가 죽으면
            // 다음 실행이 여전히 "최초 실행"으로 판정되어 재시도한다 (r02 P2).
            loginIntended = true
            if needsRegister {
                attemptRegister(service, context: "first-run")
            }
        } else if loginIntended, needsRegister {
            attemptRegister(service, context: "reconcile")
        }
        log("reconcile done: status=\(service.status.rawValue) intended=\(loginIntended)")
    }

    private func attemptRegister(_ service: SMAppService, context: String) {
        do {
            try service.register()
            log("register(\(context)) OK -> status=\(service.status.rawValue)")
        } catch {
            log("register(\(context)) FAILED: \(error)")
        }
    }

    @objc private func toggleLoginItem() {
        guard isInstalledCopy else { return }
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
                loginIntended = false
            case .requiresApproval:
                // 이미 등록됐으나 사용자 승인이 필요한 별도 상태 — 승인 화면으로 안내.
                SMAppService.openSystemSettingsLoginItems()
            default: // .notRegistered, .notFound
                try service.register()
                loginIntended = true
                log("menu register OK -> status=\(service.status.rawValue)")
            }
        } catch {
            log("menu login toggle FAILED: \(error)")
            let alert = NSAlert()
            alert.messageText = "로그인 항목 변경 실패"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshUI()
    }

    // MARK: - 메뉴

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        // 자동활성화를 끈다: 켜두면 target이 응답하는 항목(loginItem)이 우리가
        // isEnabled=false로 둔 경우에도 강제로 활성화돼, 비설치 사본에서 회색
        // 처리가 무효화된다(최종 게이트 P3). 활성 항목은 아래서 명시 지정.
        menu.autoenablesItems = false
        stateLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        stateLine.isEnabled = false
        menu.addItem(stateLine)

        let hint = NSMenuItem(title: "AC 전원 연결 중에만 작동 · 배터리면 자동 해제", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "", action: #selector(toggle), keyEquivalent: "t")
        toggleItem.target = self
        toggleItem.isEnabled = true
        menu.addItem(toggleItem)

        loginItem = NSMenuItem(title: "로그인 시 자동 시작", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem) // isEnabled는 refreshUI에서 설치 여부에 따라 지정
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.isEnabled = true
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshUI() // 시스템 설정에서 로그인 항목을 바꿨어도 열 때마다 실제 상태 반영
    }

    /// 현재 AC 전원인가. caffeinate -s는 AC에서만 유효하므로, 배터리면 설정이
    /// "켜짐"이어도 실제로는 잠자기를 막지 못한다(effective state).
    private func isOnACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return true } // 판정 불가 시 보수적으로 AC로 간주(과표시가 과소표시보다 안전)
        return type == kIOPSACPowerValue
    }

    private func refreshUI() {
        // 아이콘 채움 = "지금 실제로 잠자기를 막고 있음"(설정 켜짐 AND AC). 배터리면
        // 설정이 켜져 있어도 빈 잔으로 표시해 유효 상태를 정직하게 드러낸다.
        let onAC = isOnACPower()
        let symbol: String
        let stateText: String
        if respawnGaveUp {
            symbol = "exclamationmark.triangle"
            stateText = "오류: caffeinate가 반복 종료됨"
        } else if !isEnabled {
            symbol = "cup.and.saucer"
            stateText = "잠자기 방지: 꺼짐"
        } else if onAC {
            symbol = "cup.and.saucer.fill"
            stateText = "잠자기 방지: 작동 중 (AC 전원)"
        } else {
            symbol = "cup.and.saucer"
            stateText = "잠자기 방지: 켜짐 · 지금은 배터리라 대기 중 (잠자기 허용됨)"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: stateText)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = stateText
        stateLine.title = stateText
        if respawnGaveUp {
            toggleItem.title = "재시도 (caffeinate 재시작)"
        } else {
            toggleItem.title = isEnabled ? "끄기 (잠자기 허용)" : "켜기 (AC에서 잠자기 방지)"
        }

        if isInstalledCopy {
            loginItem.isEnabled = true
            switch SMAppService.mainApp.status {
            case .enabled:
                loginItem.title = "로그인 시 자동 시작"
                loginItem.state = .on
            case .requiresApproval:
                loginItem.title = "로그인 시 자동 시작 — 시스템 설정 승인 필요 (클릭)"
                loginItem.state = .mixed
            default:
                loginItem.title = "로그인 시 자동 시작"
                loginItem.state = .off
            }
        } else {
            loginItem.isEnabled = false
            loginItem.title = "로그인 시 자동 시작 (/Applications 설치본에서만 가능)"
            loginItem.state = .off
        }
    }

    // MARK: - 토글 동작

    @objc private func toggle() {
        if respawnGaveUp {
            // 오류 상태에서의 클릭 = 재시도 (끄기가 아님 — r01 P2 소견 반영)
            respawnGaveUp = false
            respawnTimestamps = []
            isEnabled = true
            startCaffeinate()
        } else if isEnabled {
            isEnabled = false
            stopCaffeinate()
        } else {
            isEnabled = true
            startCaffeinate() // retiring이 남아 있으면 그 종료 콜백에서 이어서 시작됨
        }
        refreshUI()
    }

    // MARK: - caffeinate 자식 프로세스 관리

    private func startCaffeinate() {
        guard current == nil, retiring == nil, !respawnGaveUp else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-s", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                self?.handleTermination(of: finished)
            }
        }
        do {
            try process.run()
            current = process
        } catch {
            current = nil
            respawnGaveUp = true
        }
    }

    private func handleTermination(of process: Process) {
        if process === retiring {
            // 의도된 중단 완료 — 이제야 새 프로세스 시작이 허용된다.
            retiring = nil
            if isEnabled, current == nil, !respawnGaveUp {
                startCaffeinate()
            }
            refreshUI()
            return
        }
        guard process === current else { return } // 이미 대체된 옛 프로세스의 늦은 콜백
        current = nil
        guard isEnabled else {
            refreshUI()
            return
        }
        respawnTimestamps.append(Date())
        respawnTimestamps.removeAll { $0.timeIntervalSinceNow < -10 }
        if respawnTimestamps.count > 3 {
            respawnGaveUp = true
        } else {
            startCaffeinate()
        }
        refreshUI()
    }

    private func stopCaffeinate() {
        guard let process = current else { return }
        current = nil
        retiring = process
        process.terminate()
        // SIGTERM이 무시되는 비정상 상황 대비: 2초 내 미종료 시 SIGKILL.
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.retiring === process, process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }
}

@main
@MainActor
struct CaffeinateGUIMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
