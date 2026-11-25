import AVFoundation
import PhotosUI
import SwiftData
import SwiftUI
import VisionKit

/// Scan a product barcode, look it up (on-device copy, Open Food Facts, USDA) and log it.
/// When no database knows the product, the nutrition table can be photographed and is
/// read on the phone.
@MainActor
struct BarcodeFoodView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    private enum Phase {
        case scanning
        case lookingUp(ProductBarcode)
        case product(ProductInfo, isOfflineCopy: Bool)
        case notFound(ProductBarcode, partial: ProductInfo?, errorMessage: String?)
        case readingLabel
        case editing(ProductInfo, note: ProductNutritionForm.Note, saveAs: ProductDataSource)
    }

    private enum CameraState {
        case checking, ready, denied, unsupported
    }

    @State private var phase: Phase = .scanning
    @State private var cameraState: CameraState = .checking
    @State private var showingBarcodeEntry = false
    @State private var typedBarcode = ""
    @State private var showingInvalidBarcode = false
    @State private var labelTarget: ProductInfo?
    @State private var showingLabelCamera = false
    @State private var labelPhoto: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
        .task { await prepareCamera() }
        .alert("Enter barcode", isPresented: $showingBarcodeEntry) {
            TextField("Barcode number", text: $typedBarcode)
                .keyboardType(.numberPad)
            Button("Look up") { lookUpTypedBarcode() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Type the digits printed under the barcode.")
        }
        .alert("Invalid barcode", isPresented: $showingInvalidBarcode) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This barcode number is not valid. Check the digits and try again.")
        }
        .fullScreenCover(isPresented: $showingLabelCamera) {
            CameraPicker(
                onImage: { image in
                    showingLabelCamera = false
                    readLabel(image)
                },
                onCancel: { showingLabelCamera = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: labelPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    readLabel(image)
                }
                labelPhoto = nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            scanner
                .navigationTitle("Scan Barcode")

        case .lookingUp(let barcode):
            VStack(spacing: 12) {
                ProgressView()
                Text("Looking up product…")
                    .font(.headline)
                Text(verbatim: barcode.code)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Scan Barcode")

        case .product(let product, let isOfflineCopy):
            ProductEntryView(
                product: product,
                isOfflineCopy: isOfflineCopy,
                onLogged: { dismiss() },
                onEdit: { phase = .editing(product, note: .manual, saveAs: .user) },
                onScanAnother: { phase = .scanning }
            )
            .navigationTitle("Add Food")

        case .notFound(let barcode, let partial, let errorMessage):
            notFound(barcode: barcode, partial: partial, errorMessage: errorMessage)
                .navigationTitle("Product Not Found")

        case .readingLabel:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading nutrition table…")
                    .font(.headline)
                Text("Text is recognized on your iPhone. The photo is not uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Nutrition Table")

        case .editing(let product, let note, let saveAs):
            ProductNutritionForm(
                product: product,
                note: note,
                onSave: { edited in
                    var saved = edited
                    saved.source = saveAs
                    ProductCache.save(saved, in: context)
                    phase = .product(saved, isOfflineCopy: false)
                },
                onRetakePhoto: note == .manual ? nil : {
                    labelTarget = product
                    showingLabelCamera = true
                }
            )
            .navigationTitle("Nutrition Values")
        }
    }

    // MARK: - Scanner

    private var scanner: some View {
        ZStack(alignment: .bottom) {
            switch cameraState {
            case .ready:
                BarcodeCameraView { barcode in
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    lookUp(barcode)
                }
                .ignoresSafeArea()
            case .checking:
                Color.black.ignoresSafeArea()
            case .denied:
                ContentUnavailableView {
                    Label("Camera access needed", systemImage: "camera.fill")
                } description: {
                    Text("Allow camera access in Settings to scan barcodes, or type the barcode number.")
                } actions: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: url)
                    }
                }
            case .unsupported:
                ContentUnavailableView(
                    "Scanning not available",
                    systemImage: "barcode.viewfinder",
                    description: Text("This device can't scan barcodes with the camera. You can type the barcode number instead.")
                )
            }

            VStack(spacing: 12) {
                if cameraState == .ready {
                    Text("Point the camera at the barcode or GS1 QR code")
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Button {
                    typedBarcode = ""
                    showingBarcodeEntry = true
                } label: {
                    Label("Type barcode", systemImage: "keyboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
    }

    private func prepareCamera() async {
        guard DataScannerViewController.isSupported else {
            cameraState = .unsupported
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                cameraState = .denied
                return
            }
        default:
            cameraState = .denied
            return
        }
        cameraState = DataScannerViewController.isAvailable ? .ready : .denied
    }

    private func lookUpTypedBarcode() {
        guard let barcode = ProductBarcode(payload: typedBarcode) else {
            showingInvalidBarcode = true
            return
        }
        lookUp(barcode)
    }

    // MARK: - Lookup

    private func lookUp(_ barcode: ProductBarcode) {
        phase = .lookingUp(barcode)

        let cached = ProductCache.product(for: barcode.code, in: context)
        if let cached, cached.caloriesPer100Grams > 0, !ProductCache.needsRefresh(cached) {
            cached.lastUsedAt = Date()
            phase = .product(cached.info, isOfflineCopy: false)
            return
        }
        let cachedInfo = cached.flatMap { $0.caloriesPer100Grams > 0 ? $0.info : nil }

        Task {
            let result: Phase
            do {
                let product = try await ProductLookup.lookup(barcode)
                if let product, product.hasNutrition {
                    ProductCache.save(product, in: context)
                    result = .product(product, isOfflineCopy: false)
                } else if let cachedInfo {
                    result = .product(cachedInfo, isOfflineCopy: false)
                } else {
                    result = .notFound(barcode, partial: product, errorMessage: nil)
                }
            } catch {
                if let cachedInfo {
                    result = .product(cachedInfo, isOfflineCopy: true)
                } else {
                    result = .notFound(barcode, partial: nil, errorMessage: error.localizedDescription)
                }
            }
            // Ignore a late answer when the user already moved on.
            if case .lookingUp(let current) = phase, current == barcode {
                phase = result
            }
        }
    }

    // MARK: - Not found

    private func notFound(barcode: ProductBarcode, partial: ProductInfo?, errorMessage: String?) -> some View {
        let base = partial ?? ProductInfo(barcode: barcode.code, name: "", source: .user)
        return List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: errorMessage == nil ? "barcode" : "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    if let partial, !partial.name.isEmpty {
                        Text(partial.displayName)
                            .font(.headline)
                        Text("This product has no nutrition values online yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("This product is not in Open Food Facts or USDA FoodData Central yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Text(verbatim: barcode.code)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Button {
                    labelTarget = base
                    showingLabelCamera = true
                } label: {
                    Label("Photograph nutrition table", systemImage: "camera.viewfinder")
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                PhotosPicker(selection: Binding(
                    get: { labelPhoto },
                    set: { item in
                        labelTarget = base
                        labelPhoto = item
                    }
                ), matching: .images) {
                    Label("Choose photo of nutrition table", systemImage: "photo.on.rectangle")
                }

                Button {
                    phase = .editing(base, note: .manual, saveAs: .user)
                } label: {
                    Label("Enter values manually", systemImage: "square.and.pencil")
                }
            } footer: {
                Text("Power reads the table on your iPhone and saves the product here, so the next scan works offline.")
            }

            Section {
                if errorMessage != nil {
                    Button("Try again") { lookUp(barcode) }
                }
                Button("Scan another product") { phase = .scanning }
            }
        }
    }

    // MARK: - Nutrition table photo

    private func readLabel(_ image: UIImage) {
        guard let target = labelTarget else { return }
        phase = .readingLabel

        Task {
            let values = (try? await NutritionLabelReader.read(image)) ?? NutritionLabelValues()
            var product = target
            product.caloriesPer100Grams = values.calories ?? product.caloriesPer100Grams
            product.proteinPer100Grams = values.protein ?? product.proteinPer100Grams
            product.carbohydratePer100Grams = values.carbohydrates ?? product.carbohydratePer100Grams
            product.fatPer100Grams = values.fat ?? product.fatPer100Grams
            if let serving = values.servingGrams { product.servingGrams = serving }

            let note: ProductNutritionForm.Note
            if !values.foundAnything {
                note = .nothingFound
            } else if values.isPerServingOnly {
                note = .perServing
            } else if values.looksInconsistent || values.calories == nil {
                note = .checkValues
            } else {
                note = .readFromLabel
            }
            phase = .editing(product, note: note, saveAs: .nutritionLabel)
        }
    }
}

// MARK: - Camera scanner

/// VisionKit live scanner for retail barcodes (EAN-13, EAN-8, UPC-A, UPC-E), GS1 DataBar
/// and GS1 Digital Link QR / DataMatrix codes. Runs entirely on the device.
private struct BarcodeCameraView: UIViewControllerRepresentable {
    let onBarcode: (ProductBarcode) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBarcode: onBarcode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.ean13, .ean8, .upce, .qr, .dataMatrix, .gs1DataBar, .gs1DataBarExpanded]),
            ],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning, !context.coordinator.hasReported {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onBarcode: (ProductBarcode) -> Void
        var hasReported = false

        init(onBarcode: @escaping (ProductBarcode) -> Void) {
            self.onBarcode = onBarcode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            report(addedItems, from: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            report([item], from: dataScanner)
        }

        private func report(_ items: [RecognizedItem], from scanner: DataScannerViewController) {
            guard !hasReported else { return }
            for item in items {
                guard case .barcode(let code) = item, let payload = code.payloadStringValue else { continue }
                // QR codes that are not GS1 Digital Links (websites, menus) are ignored.
                guard let barcode = ProductBarcode(payload: payload, isUPCE: code.observation.symbology == .upce) else { continue }
                hasReported = true
                scanner.stopScanning()
                onBarcode(barcode)
                return
            }
        }
    }
}
