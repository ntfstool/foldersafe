import Foundation
import ServiceManagement

/// 开机自动启动（SMAppService，macOS 13+）。状态以系统为准，不另存。
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
