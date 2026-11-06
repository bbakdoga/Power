import SwiftUI
import SwiftData

/// Multi-select list of exercises. Exercises are added in the order tapped.
struct ExercisePickerView: View {
    let onAdd: ([Exercise]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Exercise.name) private var exercises: [Exercise]
    @State private var search = ""
    @State private var selected: [Exercise] = []
    @State private var showingNew = false

    private var filtered: [Exercise] {
        search.isEmpty ? exercises : exercises.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { exercise in
                Button {
                    toggle(exercise)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name)
                                .foregroundStyle(.primary)
                            Text(exercise.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let index = selected.firstIndex(of: exercise) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(.tint))
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle("Add Exercises")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "Add" : "Add (\(selected.count))") {
                        onAdd(selected)
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New exercise", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNew) {
                ExerciseEditorView(exercise: nil)
            }
        }
    }

    private func toggle(_ exercise: Exercise) {
        if let index = selected.firstIndex(of: exercise) {
            selected.remove(at: index)
        } else {
            selected.append(exercise)
        }
    }
}
