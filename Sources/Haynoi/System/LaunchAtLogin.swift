import ServiceManagement

enum LaunchAtLogin {
    static func set(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                NSLog("[Haynoi] Launch at login enabled")
            } else {
                try SMAppService.mainApp.unregister()
                NSLog("[Haynoi] Launch at login disabled")
            }
        } catch {
            NSLog("[Haynoi] Launch at login error: %@", error.localizedDescription)
        }
    }
}
