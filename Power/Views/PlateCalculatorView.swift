import SwiftUI

struct PlateCalculatorView: View {
    @AppStorage(WeightUnit.storageKey) private var unit: WeightUnit = .kg
    @State private var target: Double = 100
    @State private var barWeight: Double = 20

    var body: some View {
        let result = PlateMath.plates(target: target, bar: barWeight, available: unit.standardPlates)

        Form {
            Section {
                HStack {
                    Text("Target weight")
                    Spacer()
                    TextField("0", value: $target, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                    Text(unit.rawValue)
                        .foregroundStyle(.secondary)
                }
                Picker("Bar", selection: $barWeight) {
                    ForEach(unit.barOptions, id: \.self) { weight in
                        Text("\(weight.formatted()) \(unit.rawValue)").tag(weight)
                    }
                }
            }

            Section("Load on each side") {
                if result.perSide.isEmpty {
                    Text(target <= barWeight ? "Just the bar." : "No plates fit.")
                        .foregroundStyle(.secondary)
                } else {
                    PlateStackView(plates: result.perSide, unit: unit)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    ForEach(Self.grouped(result.perSide), id: \.weight) { group in
                        LabeledContent("\(group.weight.formatted()) \(unit.rawValue)", value: "× \(group.count)")
                    }
                }
                if result.remainder > 0.001 {
                    Text("\(result.remainder.formatted(.number.precision(.fractionLength(0...2)))) \(unit.rawValue) can't be made with standard plates.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Plate Calculator")
        .onAppear {
            if !unit.barOptions.contains(barWeight) {
                barWeight = unit.barOptions[0]
                target = unit == .kg ? 100 : 225
            }
        }
        .onChange(of: unit) { _, newUnit in
            barWeight = newUnit.barOptions[0]
            target = newUnit == .kg ? 100 : 225
        }
    }

    static func grouped(_ plates: [Double]) -> [(weight: Double, count: Int)] {
        var groups: [(weight: Double, count: Int)] = []
        for plate in plates {
            if let last = groups.last, last.weight == plate {
                groups[groups.count - 1].count += 1
            } else {
                groups.append((weight: plate, count: 1))
            }
        }
        return groups
    }
}

/// A side view of the plates on one end of the bar, largest nearest the collar.
struct PlateStackView: View {
    let plates: [Double]
    let unit: WeightUnit

    var body: some View {
        let largest = unit.standardPlates.first ?? 1
        HStack(spacing: 3) {
            Rectangle()
                .fill(Color.gray)
                .frame(width: 24, height: 10)
            ForEach(Array(plates.enumerated()), id: \.offset) { _, plate in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color(for: plate))
                    .frame(width: 14, height: 40 + 80 * CGFloat(plate / largest))
            }
            Rectangle()
                .fill(Color.gray)
                .frame(width: 40, height: 10)
        }
        .frame(height: 124)
        .accessibilityLabel(plates.map { $0.formatted() }.joined(separator: ", "))
    }

    private func color(for plate: Double) -> Color {
        let index = unit.standardPlates.firstIndex(of: plate) ?? 0
        let palette: [Color] = [.red, .blue, .yellow, .green, .gray, .purple, .orange]
        return palette[index % palette.count]
    }
}
