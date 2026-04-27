import Foundation

struct BLEDataSource: ECGDataSource {
    private let bleManager: BLEManager

    init(bleManager: BLEManager = .shared) {
        self.bleManager = bleManager
    }

    func generateStream(complexes: Int, samplesPerComplex: Int) -> [Double] {
        let totalSamples = complexes * samplesPerComplex
        let samples = bleManager.recentSamples.suffix(totalSamples)
        return samples.map { Double($0.voltage) / 1000.0 }
    }

    func generateComplex(sampleCount: Int) -> [Double] {
        let samples = bleManager.recentSamples.suffix(sampleCount)
        return samples.map { Double($0.voltage) / 1000.0 }
    }
}
