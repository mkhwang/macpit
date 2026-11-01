import AppKit
import MacPitCore
import SwiftUI

enum SettingsWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    @MainActor static func show(_ m: Monitor) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 460),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "MacPit 설정"
            w.isReleasedWhenClosed = false
            let v = NSHostingView(rootView: SettingsView().environmentObject(m))
            w.contentView = v
            w.setContentSize(v.fittingSize)
            w.center()
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                Task { @MainActor in
                    if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
                    closeObserver = nil; window = nil
                }
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("메뉴바 표시").font(.headline)
                Text("체크한 항목이 메뉴바에 표시됩니다. 행을 드래그해 순서를 바꾸세요.").font(.caption).foregroundStyle(.secondary)
            }
            List {
                ForEach(m.barOrder) { item in
                    HStack {
                        Toggle(item.label, isOn: Binding(get: { m.barItems.contains(item) }, set: { m.setBarItem(item, $0) }))
                        Spacer()
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in m.barOrder.move(fromOffsets: from, toOffset: to) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: CGFloat(m.barOrder.count) * 28 + 8)
            HStack {
                Text("미리보기").font(.caption).foregroundStyle(.secondary)
                Text(m.menuTitle.isEmpty ? "(아이콘만)" : m.menuTitle).font(.caption.monospacedDigit())
                Spacer()
                Button("기본값") { m.resetBarItems() }.controlSize(.small)
            }
            Divider()
            Toggle("로그인 시 실행", isOn: Binding(get: { m.loginEnabled }, set: { m.setLogin($0) }))
            if m.daemon != nil {
                Button("팬 제어 데몬 제거…") { m.setupDaemon(.uninstall) }.disabled(m.setupBusy || !DaemonSetup.available)
            }
            Link("GitHub · 문제 제보", destination: Links.repo).font(.caption)
        }
        .padding(16)
        .frame(width: 380)
    }
}
