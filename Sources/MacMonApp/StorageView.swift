import AppKit
import MacMonCore
import SwiftUI

/// 스토리지 스캔·정리 상태. 패널 요약과 상세 창이 공유.
@MainActor
final class StorageModel: ObservableObject {
    static let shared = StorageModel()

    @Published var entries: [String: ScanEntry] = [:]
    @Published var scanning = false
    @Published var cleaning: String?            // 정리 중인 target id
    @Published var lastScan: Date?
    @Published var lastResult: String?
    // 확인 대화상자 상태 (CLT 에는 @State 매크로 플러그인이 없어 여기에 둠)
    @Published var panelConfirm = false
    @Published var windowConfirm = false
    @Published var single: CleanTarget?
    @Published var selected: Set<String> {
        didSet { UserDefaults.standard.set(Array(selected), forKey: "storage.selected") }
    }
    /// 자동 정리 주기(일). 0 = 끔
    @Published var autoDays: Int {
        didSet { UserDefaults.standard.set(autoDays, forKey: "storage.autoDays") }
    }
    var lastAutoClean: Date? {
        get { UserDefaults.standard.object(forKey: "storage.lastAutoClean") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "storage.lastAutoClean") }
    }

    private let cleaner = StorageCleaner()
    private let q = DispatchQueue(label: "macmon.storage")
    private var timer: Timer?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "storage.selected")
        selected = Set(saved ?? cleanTargets.filter { $0.risk == .safe }.map(\.id))   // 기본: safe 만
        autoDays = UserDefaults.standard.integer(forKey: "storage.autoDays")
        // 첫 스캔(수 초간 CPU 사용)은 로그인 직후 부하를 피해 60초 뒤
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.periodic() }
        // 30분마다 재스캔 + 자동 정리 시점 확인
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodic() }
        }
    }

    var busy: Bool { scanning || cleaning != nil }

    func bytes(_ id: String) -> Int64 { entries[id]?.bytes ?? 0 }
    var selectedTargets: [CleanTarget] { cleanTargets.filter { selected.contains($0.id) && (entries[$0.id]?.available ?? false) } }
    var selectedBytes: Int64 { selectedTargets.map { bytes($0.id) }.reduce(0, +) }
    var selectedCaution: [CleanTarget] { selectedTargets.filter { $0.risk == .caution } }
    var devCacheBytes: Int64 { cleanTargets.filter { $0.dockerType == nil && $0.id != "trash" }.map { bytes($0.id) }.reduce(0, +) }
    var dockerBytes: Int64 { cleanTargets.filter { $0.dockerType != nil }.map { bytes($0.id) }.reduce(0, +) }

    func scan() {
        guard !busy else { return }
        scanning = true
        let c = cleaner
        q.async {
            let r = c.scan()
            Task { @MainActor in
                self.entries = Dictionary(uniqueKeysWithValues: r.map { ($0.id, $0) })
                self.lastScan = Date(); self.scanning = false
            }
        }
    }

    func clean(_ targets: [CleanTarget], auto: Bool = false) {
        guard !busy, !targets.isEmpty else { return }
        let c = cleaner
        cleaning = targets.first?.id
        q.async {
            var total: Int64 = 0
            var errors: [String] = []
            for t in targets {
                Task { @MainActor in self.cleaning = t.id }
                let o = c.clean(t)
                total += o.freed
                if let e = o.error { errors.append("\(t.name): \(e)") }
            }
            let r = c.scan()
            Task { @MainActor in
                self.entries = Dictionary(uniqueKeysWithValues: r.map { ($0.id, $0) })
                self.lastScan = Date(); self.cleaning = nil
                if auto { self.lastAutoClean = Date() }
                let head = "\(auto ? "자동 정리" : "정리") 완료 — \(formatBytes(Double(total))) 확보"
                self.lastResult = errors.isEmpty ? head : head + "\n" + errors.prefix(3).joined(separator: "\n")
            }
        }
    }

    func periodic() {
        if autoDays > 0, Date().timeIntervalSince(lastAutoClean ?? .distantPast) > Double(autoDays) * 86400 {
            // 자동 정리는 caution 항목을 절대 포함하지 않음
            clean(selectedTargets.filter { $0.risk == .safe }, auto: true)
        } else {
            scan()
        }
    }
}

/// LSUIElement 앱이라 SwiftUI Window scene 대신 직접 NSWindow 관리
@MainActor
enum StorageWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "스토리지 정리"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: StorageView().environmentObject(StorageModel.shared))
            w.center()
            // 닫으면 뷰 트리 해제 (스캔 결과는 StorageModel 에 남아 패널 요약에 계속 사용)
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                Task { @MainActor in
                    if let o = closeObserver { NotificationCenter.default.removeObserver(o) }
                    closeObserver = nil; window = nil
                }
            }
            window = w
        }
        StorageModel.shared.scan()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 정리 확인 문구
@MainActor func cleanConfirmMessage(_ s: StorageModel) -> String {
    var msg = "\(s.selectedTargets.count)개 항목, 약 \(formatBytes(Double(s.selectedBytes))) 삭제. 되돌릴 수 없습니다."
    if !s.selectedCaution.isEmpty {
        msg += "\n\n⚠︎ 주의 항목 포함: " + s.selectedCaution.map(\.name).joined(separator: ", ")
    }
    return msg
}

// MARK: 패널 요약

struct StorageSummarySection: View {
    @EnvironmentObject var m: Monitor
    @ObservedObject var s = StorageModel.shared

    var body: some View {
        Section(title: "스토리지", icon: "internaldrive") {
            HStack {
                Text("디스크 \(formatBytes(Double(m.sys.diskFree))) 남음").font(.callout)
                Spacer()
                if s.busy { ProgressView().controlSize(.small) }
            }
            Text("개발 캐시 \(formatBytes(Double(s.devCacheBytes))) · Docker 회수 가능 \(formatBytes(Double(s.dockerBytes)))")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("원클릭 정리 (\(formatBytes(Double(s.selectedBytes))))") { s.panelConfirm = true }
                    .disabled(s.busy || s.selectedTargets.isEmpty)
                Spacer()
                Button("자세히…") { StorageWindow.show() }
            }
            .controlSize(.small)
            if let r = s.lastResult { Text(r).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
        }
        .alert("선택한 캐시를 정리할까요?", isPresented: $s.panelConfirm) {
            Button("정리", role: .destructive) { s.clean(s.selectedTargets) }
            Button("취소", role: .cancel) {}
        } message: { Text(cleanConfirmMessage(s)) }
    }
}

// MARK: 상세 창

struct StorageView: View {
    @ObservedObject var s = StorageModel.shared

    private var groups: [String] {
        var seen: [String] = []
        for t in cleanTargets where !seen.contains(t.group) { seen.append(t.group) }
        return seen
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(12)
            Divider()
            List {
                ForEach(groups, id: \.self) { g in
                    let items = cleanTargets.filter { $0.group == g }
                    SwiftUI.Section {
                        ForEach(items) { t in row(t) }
                    } header: {
                        HStack {
                            Text(g)
                            Spacer()
                            Text(formatBytes(Double(items.map { s.bytes($0.id) }.reduce(0, +)))).monospacedDigit()
                        }
                    }
                }
            }
            Divider()
            footer.padding(12)
        }
        .frame(minWidth: 520, minHeight: 520)
        .alert("선택한 캐시를 정리할까요?", isPresented: $s.windowConfirm) {
            Button("정리", role: .destructive) { s.clean(s.selectedTargets) }
            Button("취소", role: .cancel) {}
        } message: { Text(cleanConfirmMessage(s)) }
        .alert(item: $s.single) { t in
            Alert(title: Text("\(t.name) 정리"),
                  message: Text("약 \(formatBytes(Double(s.bytes(t.id)))) 삭제.\n\(t.detail)"),
                  primaryButton: .destructive(Text("정리")) { s.clean([t]) },
                  secondaryButton: .cancel(Text("취소")))
        }
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("선택 \(formatBytes(Double(s.selectedBytes)))").font(.title2.weight(.semibold)).monospacedDigit()
                Text("개발 캐시 \(formatBytes(Double(s.devCacheBytes))) · Docker 회수 가능 \(formatBytes(Double(s.dockerBytes)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if s.scanning { ProgressView().controlSize(.small); Text("스캔 중").font(.caption) }
            if let c = s.cleaning { ProgressView().controlSize(.small); Text("정리 중: \(c)").font(.caption) }
            Button { s.scan() } label: { Image(systemName: "arrow.clockwise") }.disabled(s.busy)
        }
    }

    func row(_ t: CleanTarget) -> some View {
        let e = s.entries[t.id]
        let available = e?.available ?? false
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { s.selected.contains(t.id) },
                                     set: { if $0 { s.selected.insert(t.id) } else { s.selected.remove(t.id) } }))
                .labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(t.name)
                    if t.risk == .caution {
                        Text("주의").font(.caption2.weight(.semibold)).padding(.horizontal, 4)
                            .background(Capsule().fill(Color.orange.opacity(0.3)))
                    }
                }
                Text(e?.note.map { "\($0) · \(t.detail)" } ?? t.detail)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Text(available ? formatBytes(Double(e?.bytes ?? 0)) : "없음")
                .monospacedDigit().foregroundStyle(available ? .primary : .secondary)
                .frame(width: 70, alignment: .trailing)
            Button("정리") { s.single = t }
                .controlSize(.small)
                .disabled(!available || (e?.bytes ?? 0) == 0 || s.busy)
        }
        .opacity(available ? 1 : 0.55)
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("자동 정리", selection: $s.autoDays) {
                    Text("끔").tag(0); Text("매주").tag(7); Text("매월").tag(30)
                }
                .pickerStyle(.segmented).frame(width: 240)
                Text("체크된 safe 항목만 (주의 항목 제외)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                if let r = s.lastResult { Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                Spacer()
                Button("선택 항목 정리") { s.windowConfirm = true }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(s.busy || s.selectedTargets.isEmpty)
            }
        }
    }
}
