import Foundation

/// Szerokość zakresu i krok próbki dla zbieracza — dobrane do archiwów RRA ze skryptu
/// `mnas-historia` (1 min ×1440, 30 min ×336, 2 h ×372, 1 dzień ×366).
extension OknoRRD {
    nonisolated var sekundy: Int {
        switch self {
        case .hour:  return 3_600
        case .day:   return 86_400
        case .week:  return 604_800
        case .month: return 2_678_400
        case .year:  return 31_622_400
        }
    }

    nonisolated var krokZbieracza: Int {
        switch self {
        case .hour, .day: return 60
        case .week:       return 1_800
        case .month:      return 7_200
        case .year:       return 86_400
        }
    }
}
