import SwiftUI
import UIKit

/// Illustration of the profile's body type doing the exercise, worked muscles in red.
/// Falls back to an animated SF Symbol when there's no illustration (e.g. custom exercises).
struct ExerciseGraphicView: View {
    let exercise: Exercise

    @AppStorage(BodyType.storageKey) private var bodyType: BodyType = .man
    @State private var animating = false

    var body: some View {
        if let image = UIImage(named: ExerciseGuide.imageName(for: exercise, bodyType: bodyType)) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: 300)
                .accessibilityLabel(accessibilityText)
        } else {
            // Gently "rep" the figure up and down as a simple movement animation.
            Image(systemName: ExerciseGuide.symbolName(for: exercise))
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
        let muscles = ExerciseGuide.guide(for: exercise)?.primary ?? [exercise.muscleGroup.title]
        return "\(bodyType.title) doing \(exercise.name), with \(muscles.formatted(.list(type: .and))) highlighted"
    }
}

/// Small square version of the illustration for list rows.
struct ExerciseThumbnail: View {
    let exercise: Exercise

    @AppStorage(BodyType.storageKey) private var bodyType: BodyType = .man

    var body: some View {
        Group {
            if let image = UIImage(named: ExerciseGuide.imageName(for: exercise, bodyType: bodyType)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .background(Color.white)
            } else {
                Image(systemName: ExerciseGuide.symbolName(for: exercise))
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
