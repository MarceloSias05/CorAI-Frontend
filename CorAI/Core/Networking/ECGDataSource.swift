import Foundation

protocol ECGDataSource: Sendable {
    func generateStream(complexes: Int, samplesPerComplex: Int) -> [Double]
    func generateComplex(sampleCount: Int) -> [Double]
}
