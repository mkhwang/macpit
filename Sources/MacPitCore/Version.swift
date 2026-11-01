import Foundation

/// 앱·데몬·CLI 공통 버전. 앱이 데몬 버전과 비교해 업데이트 필요 여부를 판단한다.
public let macpitVersion = "0.3.0"
/// 데몬(macpitd + 설치 스크립트) 버전. 데몬 쪽 코드가 바뀐 릴리스에서만 올린다.
/// 앱은 이 값과 다를 때만 "데몬 업데이트"(관리자 암호)를 요구한다 — 암호 입력 습관화 방지.
public let macpitDaemonVersion = "0.3.0"

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
