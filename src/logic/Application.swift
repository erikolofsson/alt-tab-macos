import Cocoa
import ApplicationServices.HIServices.AXNotificationConstants

class Application: NSObject {
    // kvObservers should be listed first, so it gets deinit'ed first; otherwise it can crash
    var kvObservers: [NSKeyValueObservation]?
    var runningApplication: NSRunningApplication
    var axUiElement: AXUIElement?
    var axObserver: AXObserver?
    var isReallyFinishedLaunching = false
    var isHidden: Bool!
    var hasBeenActiveOnce: Bool!
    var icon: NSImage?
    var dockLabel: String?
    var pid: pid_t!
    var focusedWindow: Window? = nil
    var alreadyRequestedToQuit = false
    var isCurrent: Bool!

    init(_ runningApplication: NSRunningApplication, isCurrent: Bool) {
        self.runningApplication = runningApplication
        pid = runningApplication.processIdentifier
        self.isCurrent = isCurrent
        super.init()
        isHidden = runningApplication.isHidden
        hasBeenActiveOnce = runningApplication.isActive
        icon = runningApplication.icon
        observeEventsIfEligible()
        kvObservers = [
            runningApplication.observe(\.isFinishedLaunching, options: [.new]) { [weak self] _, _ in
                guard let self = self else { return }
                self.observeEventsIfEligible()
            },
            runningApplication.observe(\.activationPolicy, options: [.new]) { [weak self] _, _ in
                guard let self = self else { return }
                if self.runningApplication.activationPolicy != .regular {
                    self.removeWindowslessAppWindow()
                }
                self.observeEventsIfEligible()
            },
        ]
    }

    deinit {
        debugPrint("Deinit app", runningApplication.bundleIdentifier ?? runningApplication.bundleURL ?? "nil")
    }

    func removeWindowslessAppWindow() {
        if let windowlessAppWindow = (Windows.list.firstIndex { $0.isWindowlessApp == true && $0.application.pid == pid }) {
            Windows.list.remove(at: windowlessAppWindow)
            App.app.refreshOpenUi()
        }
    }

    func observeEventsIfEligible() {
        if runningApplication.activationPolicy != .prohibited && axUiElement == nil {
            axUiElement = AXUIElementCreateApplication(pid)
            AXObserverCreate(pid, axObserverCallback, &axObserver)
            debugPrint("Adding app", pid ?? "nil", runningApplication.bundleIdentifier ?? "nil")
            observeEvents()
        }
    }

    func manuallyUpdateWindows(_ group: DispatchGroup? = nil) {
        // TODO: this method manually checks windows, but will not find windows on other Spaces
        retryAxCallUntilTimeout(group, 5) { [weak self] in
            guard let self = self else { return }
            if let axWindows_ = try self.axUiElement!.windows(), axWindows_.count > 0 {
                // bug in macOS: sometimes the OS returns multiple duplicate windows (e.g. Mail.app starting at login)
                let axWindows = try Array(Set(axWindows_)).compactMap {
                    if let wid = try $0.cgWindowId() {
                        let title = try $0.title()
                        let subrole = try $0.subrole()
                        let role = try $0.role()
                        let size = try $0.size()
                        let level = try wid.level()
                        if AXUIElement.isActualWindow(self.runningApplication, wid, level, title, subrole, role, size) {
                            return ($0, wid, title, try $0.isFullscreen(), try $0.isMinimized(), try $0.position(), size)
                        }
                    }
                    return nil
                } as [(AXUIElement, CGWindowID, String?, Bool, Bool, CGPoint?, CGSize?)]
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    var windows = self.addWindows(axWindows)
                    if let window = self.addWindowslessAppsIfNeeded() {
                        windows.append(contentsOf: window)
                    }
                    App.app.refreshOpenUi(windows)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let window = self.addWindowslessAppsIfNeeded()
                    App.app.refreshOpenUi(window)
                }
                // workaround: some apps launch but take a while to create their window(s)
                // initial windows don't trigger a windowCreated notification, so we won't get notified
                // it's very unlikely an app would launch with no initial window
                // so we retry until timeout, in those rare cases (e.g. Bear.app)
                // we only do this for active app, to avoid wasting CPU, with the trade-off of maybe missing some windows
                if self.runningApplication.isActive {
                    throw AxError.runtimeError
                }
            }
        }
    }

    func addWindowslessAppsIfNeeded() -> [Window]? {
        if !Preferences.hideWindowlessApps &&
               runningApplication.activationPolicy == .regular &&
               !runningApplication.isTerminated &&
               (Windows.list.firstIndex { $0.application.pid == pid }) == nil {
            let window = Window(self)
            Windows.appendAndUpdateFocus(window)
            return [window]
        }
        return nil
    }

    func hideOrShow() {
        if runningApplication.isHidden {
            runningApplication.unhide()
        } else {
            runningApplication.hide()
        }
    }

    func quit() {
        // only let power users quit Finder if they opt-in
        if runningApplication.bundleIdentifier == "com.apple.finder" && !Preferences.finderShowsQuitMenuItem { return }
        if alreadyRequestedToQuit {
            runningApplication.forceTerminate()
        } else {
            runningApplication.terminate()
            alreadyRequestedToQuit = true
        }
    }

    private func addWindows(_ axWindows: [(AXUIElement, CGWindowID, String?, Bool, Bool, CGPoint?, CGSize?)]) -> [Window] {
        let windows: [Window] = axWindows.compactMap { (axUiElement, wid, axTitle, isFullscreen, isMinimized, position, size) in
            if (Windows.list.firstIndex { $0.isEqualRobust(axUiElement, wid) }) == nil {
                let window = Window(axUiElement, self, wid, axTitle, isFullscreen, isMinimized, position, size)
                Windows.appendAndUpdateFocus(window)
                return window
            }
            return nil
        }
        if App.app.appIsBeingUsed {
            Windows.cycleFocusedWindowIndex(windows.count)
        }
        return windows
    }

    private func observeEvents() {
        guard let axObserver = axObserver else { return }
        for notification in [
            kAXApplicationActivatedNotification,
            kAXMainWindowChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowCreatedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification,
        ] {
            if (!isCurrent) {
                retryAxCallUntilTimeout { [weak self] in
                    guard let self = self else { return }
                    try self.subscribe(notification)
                }
            } else {
                do {
                    try subscribe(notification)
                } catch let error {
                    debugPrint("Error adding AltTab \(error)")
                }
            }
        }
        CFRunLoopAddSource(BackgroundWork.accessibilityEventsThread.runLoop, AXObserverGetRunLoopSource(axObserver), .defaultMode)
    }

    private func subscribe(_ notification: String) throws {
        try axUiElement!.subscribeToNotification(axObserver!, notification, {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // some apps have `isFinishedLaunching == true` but are actually not finished, and will return .cannotComplete
                // we consider them ready when the first subscription succeeds
                // windows opened before that point won't send a notification, so check those windows manually here
                if !self.isReallyFinishedLaunching {
                    self.isReallyFinishedLaunching = true
                    self.manuallyUpdateWindows()
                }
            }
        }, isCurrent ? NSRunningApplication.current : runningApplication)
    }
}
