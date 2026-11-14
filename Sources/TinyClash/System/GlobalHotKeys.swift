import Carbon.HIToolbox
import Foundation

/// 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）。
/// 固定使用 ⌃⌥⌘ 组合，降低与其他 App 冲突的概率。
enum GlobalHotKeys {
    enum Action: UInt32, CaseIterable {
        case toggleSystemProxy = 1, toggleTun, cycleMode

        var keyCode: UInt32 {
            switch self {
            case .toggleSystemProxy: return UInt32(kVK_ANSI_S)
            case .toggleTun: return UInt32(kVK_ANSI_T)
            case .cycleMode: return UInt32(kVK_ANSI_M)
            }
        }
    }

    private static var refs: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?
    private static var onAction: ((Action) -> Void)?

    static func register(_ perform: @escaping (Action) -> Void) {
        unregister()
        onAction = perform
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let action = GlobalHotKeys.Action(rawValue: id.id) { GlobalHotKeys.onAction?(action) }
            return noErr
        }, 1, &spec, nil, &handler)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5443_4C48), id: action.rawValue) // 'TCLH'
            if RegisterEventHotKey(action.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    static func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        onAction = nil
    }
}
