import SwiftUI
import UIKit

/// The picture shown for an exercise, in order of preference: the user's own picture
/// (photo or generated drawing), the built-in illustration for the profile's body type,
/// the drawing of the exercise's body part, and finally an SF Symbol.
enum ExerciseArtwork {
    enum Kind {
        case custom(UIImage)
        case illustration(UIImage)
        case bodyPart(UIImage)
        case symbol(String)
    }

    static func kind(for exercise: Exercise, bodyType: BodyType) -> Kind {
        if let data = exercise.imageData, let image = UIImage(data: data) {
            return .custom(image)
        }
        if let image = UIImage(named: ExerciseGuide.imageName(for: exercise, bodyType: bodyType)) {
            return .illustration(image)
        }
        if let name = exercise.muscleGroup.assetName, let image = UIImage(named: name) {
            return .bodyPart(image)
        }
        return .symbol(ExerciseGuide.symbolName(for: exercise))
    }
}

/// Illustration of the profile's body type doing the exercise, worked muscles in red.
/// Custom exercises show their own picture, or the drawing of their body part.
struct ExerciseGraphicView: View {
    let exercise: Exercise

    @AppStorage(BodyType.storageKey) private var bodyType: BodyType = .man
    @State private var animating = false

    var body: some View {
        switch ExerciseArtwork.kind(for: exercise, bodyType: bodyType) {
        case .custom(let image), .illustration(let image), .bodyPart(let image):
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: 300)
                .accessibilityLabel(accessibilityText)
        case .symbol(let name):
            // Gently "rep" the figure up and down as a simple movement animation.
            Image(systemName: name)
                .font(.system(size: 88))
                .foregroundStyle(.tint)
                .scaleEffect(animating ? 1.08 : 0.92)
                .offset(y: animating ? -6 : 6)
                .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: animating)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .onAppear { animating = true }
                .accessibilityHidden(true)
        }
    }

    private var accessibilityText: String {
        switch ExerciseArtwork.kind(for: exercise, bodyType: bodyType) {
        case .custom:
            return String(localized: "Picture of \(exercise.name)")
        case .bodyPart:
            return String(localized: "\(exercise.muscleGroup.title) muscles highlighted")
        default:
            let muscles = ExerciseGuide.guide(for: exercise)?.primary ?? [exercise.muscleGroup.title]
            return String(localized: "\(bodyType.title) doing \(exercise.name), with \(muscles.formatted(.list(type: .and))) highlighted",
                          comment: "VoiceOver label for an exercise illustration: body type, exercise name, highlighted muscles")
        }
    }
}

/// Small square version of the illustration for list rows.
struct ExerciseThumbnail: View {
    let exercise: Exercise

    @AppStorage(BodyType.storageKey) private var bodyType: BodyType = .man

    var body: some View {
        Group {
            switch ExerciseArtwork.kind(for: exercise, bodyType: bodyType) {
            case .custom(let image), .illustration(let image), .bodyPart(let image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .background(Color.white)
            case .symbol(let name):
                Image(systemName: name)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

extension UIImage {
    /// JPEG scaled so its longest side is at most `maxSide` points, for storing pictures.
    func downscaledJPEG(maxSide: CGFloat = 900, quality: CGFloat = 0.8) -> Data? {
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
