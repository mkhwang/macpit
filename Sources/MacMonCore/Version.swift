import Foundation

/// 앱·데몬·CLI 공통 버전. 앱이 데몬 버전과 비교해 업데이트 필요 여부를 판단한다.
public let macmonVersion = "0.1.0"

/// 팬 제어를 실측 검증한 기종 (hw.model). 그 외 기종은 UI 에 "미검증" 표시.
public let fanControlTestedModels: Set<String> = ["MacBookPro18,1"]

/// 현재 기종 식별자 (예: MacBookPro18,1, Mac15,6)
public func hardwareModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "unknown" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buf, &size, nil, 0)
    return String(cString: buf)
}
