import CoreML
import Foundation
import Vision

enum FoodImageClassifier {
    private static let foodConfidenceThreshold: VNConfidence = 0.18
    private static let generalConfidenceThreshold: VNConfidence = 0.20

    static func labels(in imageData: Data) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let foodLabels = (try? foodSpecificLabels(in: imageData)) ?? []
            let generalLabels = try generalClassificationLabels(in: imageData)

            var seen = Set<String>()
            return (foodLabels + generalLabels).filter {
                seen.insert($0.lowercased()).inserted
            }
        }.value
    }

    private static func foodSpecificLabels(in imageData: Data) throws -> [String] {
        guard let modelURL = Bundle.main.url(
            forResource: "Food101Classifier",
            withExtension: "mlmodelc"
        ) else {
            return []
        }

        let model = try MLModel(contentsOf: modelURL)
        let visionModel = try VNCoreMLModel(for: model)
        let request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .centerCrop

        let handler = VNImageRequestHandler(data: imageData)
        try handler.perform([request])

        return (request.results as? [VNClassificationObservation] ?? [])
            .filter { $0.confidence >= foodConfidenceThreshold }
            .prefix(5)
            .map(\.identifier)
    }

    private static func generalClassificationLabels(in imageData: Data) throws -> [String] {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(data: imageData)
        try handler.perform([request])

        return (request.results ?? [])
            .filter { $0.confidence >= generalConfidenceThreshold }
            .prefix(8)
            .map(\.identifier)
    }
}
