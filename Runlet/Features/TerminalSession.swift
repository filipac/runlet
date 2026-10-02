import AppKit
import Darwin
import Observation
import RunletCore
@preconcurrency import SwiftTerm

/// One terminal tab: a process in a pseudo-terminal (the user's login shell, or a direct
/// executable such as `docker exec -it …`) and the SwiftTerm view that renders it. The
/// session outlives its view's place in the hierarchy, so hiding the panel or switching tabs
/// never stops the process. Sessions live only while Runlet runs; nothing is persisted.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case starting
        case running
        /// Exit code (128 + signal when killed by a signal; nil when unknown).
        case exited(Int32?)
        case failed(String)
    }

    let id: UUID
    let request: TerminalRequest
    private(set) var state: State = .starting
    /// Title the program set (OSC 0/2), e.g. from the user's prompt theme.
    private(set) var programTitle: String?

    var title: String {
        if let programTitle, !programTitle.trimmingCharacters(in: .whitespaces).isEmpty { return programTitle }
        return request.title
    }

    var isRunning: Bool { state == .running || state == .starting }
    var isContainerShell: Bool { request.executable != nil }

    /// Called once when the process ends by itself (exit code as in `State.exited`).
    @ObservationIgnored var onExit: ((TerminalSession, Int32?) -> Void)?

    @ObservationIgnored let view: RunletTerminalView
    @ObservationIgnored private let launch: TerminalLaunch?
    @ObservationIgnored private var pendingInput: String?
    @ObservationIgnored private var inputWork: DispatchWorkItem?
    @ObservationIgnored private var appliedTheme: TerminalTheme?
    @ObservationIgnored private var appliedFontSize: Double?
    @ObservationIgnored private var exitWatch: Timer?
    @ObservationIgnored private var pid: pid_t = 0

    init(request: TerminalRequest, launch: Result<TerminalLaunch, Error>) {
        id = request.id
        self.request = request
        view = RunletTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        view.getTerminal().changeHistorySize(10_000)
        switch launch {
        case .success(let value):
            self.launch = value
            pendingInput = value.pendingInput
        case .failure(let error):
            self.launch = nil
            state = .failed("\(error)")
        }
        view.processDelegate = self
        view.onOutput = { [weak self] bytes in self?.outputArrived(bytes) }
        view.setAccessibilityIdentifier("terminal-view")
        if case .failed(let message) = state {
            view.feed(text: "\u{1b}[31m\(message)\u{1b}[0m\r\n")
        } else {
            // Normally the panel starts the process once the view has its real size; this
            // covers a session that is never laid out (e.g. its window is minimized).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.startIfNeeded() }
        }
    }

    /// Starts the process (once). Called after the view got its size, so the shell's first
    /// prompt is drawn for the right number of columns.
    func startIfNeeded() {
        guard state == .starting, let launch else { return }
        view.startProcess(executable: launch.executable, args: launch.arguments, environment: launch.environment, execName: launch.argv0, currentDirectory: launch.workingDirectory)
        guard view.process.running else {
            state = .failed("Could not start \(launch.executable).")
            view.feed(text: "\u{1b}[31mCould not start \(launch.executable).\u{1b}[0m\r\n")
            return
        }
        state = .running
        pid = view.process.shellPid
        watchForExit()
        if pendingInput != nil {
            lastOutputAt = Date()
            scheduleInputCheck(after: 0.3)
        }
    }

    /// SwiftTerm 1.11 misses the exit when the pty's end-of-file is read before the exit event
    /// (or when the child exits before its monitor is armed) and then never reaps the child;
    /// polling `waitpid` closes that gap. Whichever side reaps first reports the exit.
    private func watchForExit() {
        exitWatch?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollExit() }
        }
        // Common modes: keep watching during menu tracking, live resize, and modal alerts.
        RunLoop.main.add(timer, forMode: .common)
        exitWatch = timer
    }

    private func pollExit() {
        guard state == .running, pid > 0 else {
            stopWatchingForExit()
            return
        }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { processEnded(waitStatus: status) }
    }

    private func stopWatchingForExit() {
        exitWatch?.invalidate()
        exitWatch = nil
    }

    func apply(theme: TerminalTheme, fontSize: Double, optionAsMeta: Bool) {
        if appliedFontSize != fontSize {
            appliedFontSize = fontSize
            view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        }
        if appliedTheme != theme {
            appliedTheme = theme
            theme.apply(to: view)
        }
        if view.optionAsMetaKey != optionAsMeta { view.optionAsMetaKey = optionAsMeta }
    }

    // MARK: Typing a command once the shell is ready

    /// Set when the shell's line editor started reading a command: it enabled bracketed paste
    /// (`ESC[?2004h`: zsh, bash 5.1+, fish) or keypad mode (`ESC[?1h`: oh-my-zsh) while the
    /// tty was in raw mode, and the tty is still raw once output has settled. A prompt drawn
    /// while rc files still load (canonical mode, e.g. Powerlevel10k's instant prompt) or a
    /// question an rc file asks (`read -k`: raw, but no such marker) does not count, so the
    /// command is not typed into rc-file startup.
    @ObservationIgnored private var lineEditorStarted = false
    @ObservationIgnored private var lastOutputAt = Date()

    private static let lineEditorMarkers: [[UInt8]] = [Array("\u{1b}[?2004h".utf8), Array("\u{1b}[?1h".utf8)]

    private func outputArrived(_ bytes: ArraySlice<UInt8>) {
        guard pendingInput != nil else { return }
        lastOutputAt = Date()
        if isCanonicalMode {
            lineEditorStarted = false
        } else if Self.lineEditorMarkers.contains(where: { bytes.contains(sequence: $0) }) {
            lineEditorStarted = true
        }
        scheduleInputCheck(after: 0.3)
    }

    /// Without that signal (sh, bash 3.2) the command is typed once startup output has been
    /// quiet for a while; zsh and fish always announce their editor, so they get a long grace
    /// period in which an rc file's question can be answered first.
    private var quietFallback: TimeInterval {
        let name = (launch?.executable as NSString?)?.lastPathComponent ?? ""
        return launch?.isLoginShell == true && (name == "zsh" || name == "fish") ? 10 : 1.5
    }

    private func scheduleInputCheck(after delay: TimeInterval) {
        inputWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkPendingInput() }
        inputWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func checkPendingInput() {
        guard pendingInput != nil, state == .running else { return }
        if lineEditorStarted, isCanonicalMode { lineEditorStarted = false }
        let quiet = Date().timeIntervalSince(lastOutputAt)
        let needed = lineEditorStarted ? 0.3 : quietFallback
        guard quiet >= needed else {
            scheduleInputCheck(after: needed - quiet)
            return
        }
        flushPendingInput()
    }

    private func flushPendingInput() {
        guard let input = pendingInput, state == .running else { return }
        pendingInput = nil
        inputWork = nil
        view.send(txt: input)
    }

    /// Whether the pty is in canonical (line-buffered) mode, i.e. no line editor is reading.
    private var isCanonicalMode: Bool {
        let fd = view.process.childfd
        guard view.process.running, fd >= 0 else { return true }
        var attributes = termios()
        guard tcgetattr(fd, &attributes) == 0 else { return true }
        return attributes.c_lflag & tcflag_t(ICANON) != 0
    }

    // MARK: Foreground job and termination

    /// Name of the program running in the foreground when it is not the session's own
    /// process (the shell), e.g. "vim" or "php"; nil when the shell is idle at its prompt.
    var foregroundJobName: String? {
        guard state == .running, view.process.running else { return nil }
        let fd = view.process.childfd
        guard fd >= 0, pid > 0 else { return nil }
        let group = tcgetpgrp(fd)
        guard group > 0, group != pid else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(group, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "a command" }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// Ends the session like closing a Terminal window: SIGHUP to the foreground job and the
    /// shell (which forwards it to its jobs), then the pty is closed. A process that ignores
    /// the hang-up is killed after a few seconds and reaped.
    func terminate() {
        inputWork?.cancel()
        pendingInput = nil
        onExit = nil
        stopWatchingForExit()
        let wasRunning = state == .running
        if state == .starting || wasRunning { state = .exited(128 + SIGHUP) }
        // Only a child nobody has reaped yet is signalled (its pid cannot have been reused).
        guard wasRunning, pid > 0 else { return }
        hangUpProcesses()
        // Closes the pty master and stops SwiftTerm's exit monitor, so reap the child here.
        if view.process.running { view.terminate() }
        reapChild(pid)
    }

    /// Quit path: hang up without waiting (launchd reaps whatever outlives Runlet).
    func hangUp() {
        guard state == .running, pid > 0 else { return }
        hangUpProcesses()
    }

    private func hangUpProcesses() {
        let fd = view.process.running ? view.process.childfd : -1
        if fd >= 0 {
            let group = tcgetpgrp(fd)
            if group > 0, group != pid { killpg(group, SIGHUP) }
        }
        kill(pid, SIGHUP)
    }

    fileprivate func processEnded(waitStatus: Int32?) {
        guard state == .running else { return }
        inputWork?.cancel()
        pendingInput = nil
        stopWatchingForExit()
        let code = waitStatus.map(TerminalLaunch.exitCode(fromWaitStatus:))
        state = .exited(code)
        view.feed(text: "\r\n\u{1b}[2m[Process exited" + (code.map { " with code \($0)" } ?? "") + "]\u{1b}[0m\r\n")
        let handler = onExit
        onExit = nil
        handler?(self, code)
    }

    fileprivate func titleChanged(_ title: String) {
        if programTitle != title { programTitle = title }
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    // SwiftTerm delivers these on the main queue.
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        MainActor.assumeIsolated { titleChanged(title) }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated { processEnded(waitStatus: exitCode) }
    }
}

/// Reaps a terminated child on a background thread, escalating to SIGKILL after ~3 s.
nonisolated func reapChild(_ pid: pid_t) {
    DispatchQueue.global(qos: .utility).async {
        var status: Int32 = 0
        for _ in 0..<30 {
            // pid: reaped; -1: no longer our child (already reaped elsewhere).
            if waitpid(pid, &status, WNOHANG) != 0 { return }
            usleep(100_000)
        }
        kill(pid, SIGKILL)
        waitpid(pid, &status, 0)
    }
}

/// SwiftTerm's local-process view, reporting output so the session can tell when the shell
/// has finished starting.
final class RunletTerminalView: LocalProcessTerminalView {
    var onOutput: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?(slice)
    }
}

extension ArraySlice where Element == UInt8 {
    func contains(sequence: [UInt8]) -> Bool {
        guard let first = sequence.first, count >= sequence.count else { return false }
        var index = startIndex
        while let start = self[index...].firstIndex(of: first) {
            guard endIndex - start >= sequence.count else { return false }
            if self[start..<(start + sequence.count)].elementsEqual(sequence) { return true }
            index = start + 1
        }
        return false
    }
}

/// Terminal colors for the app's light and dark appearance (readable 16-color ANSI palettes
/// on the editor's background).
struct TerminalTheme: Equatable {
    var isDark: Bool

    func apply(to view: TerminalView) {
        if isDark {
            view.nativeBackgroundColor = Self.color(0x1E1E1E)
            view.nativeForegroundColor = Self.color(0xD4D4D4)
            view.caretColor = Self.color(0xAEAFAD)
            view.selectedTextBackgroundColor = Self.color(0x264F78)
            view.installColors(Self.palette([
                0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
                0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF,
            ]))
        } else {
            view.nativeBackgroundColor = Self.color(0xFFFFFF)
            view.nativeForegroundColor = Self.color(0x1F1F1F)
            view.caretColor = Self.color(0x3A3A3A)
            view.selectedTextBackgroundColor = Self.color(0xADD6FF)
            // "White" entries are greys so text drawn in them stays legible on white.
            view.installColors(Self.palette([
                0x000000, 0xC72E2E, 0x107C10, 0x8A6F00, 0x0451A5, 0xA626A4, 0x0E7C8F, 0x6E6E6E,
                0x5A5A5A, 0xE03E3E, 0x169C16, 0xA88600, 0x2B6FD6, 0xBC05BC, 0x0598BC, 0x8C8C8C,
            ]))
        }
    }

    private static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func palette(_ values: [Int]) -> [SwiftTerm.Color] {
        // 16-bit components (0...65535): 8-bit value × 257.
        values.map { SwiftTerm.Color(red: UInt16(($0 >> 16) & 0xFF) * 257, green: UInt16(($0 >> 8) & 0xFF) * 257, blue: UInt16($0 & 0xFF) * 257) }
    }
}
