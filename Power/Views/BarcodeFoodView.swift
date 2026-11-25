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
    /// A photo of a package to identify right away (from "Take food photo").
    var packageImage: UIImage? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    private enum Phase {
        case scanning
        case lookingUp(ProductBarcode)
        case product(ProductInfo, isOfflineCopy: Bool)
        case notFound(ProductBarcode, partial: ProductInfo?, errorMessage: String?)
        case readingLabel
        case editing(ProductInfo, note: ProductNutritionForm.Note, saveAs: ProductDataSource)
        case readingPackage
        /// Products found by the text on the package front. `barcode` is the scanned code
        /// when the search started from "Product Not Found".
        case packageMatches(PackageGuess, [ProductInfo], barcode: ProductBarcode?, errorMessage: String?)
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
    /// Barcode the package photo belongs to (nil when started from the scanner).
    @State private var packageBarcode: ProductBarcode?
    @State private var showingPackageCamera = false
    @State private var packagePhoto: PhotosPickerItem?
    @State private var searchText = ""
    /// A match without nutrition values; asks how to add them.
    @State private var needsValues: ProductInfo?

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
        .task {
            if let packageImage {
                readPackage(packageImage)
            }
            await prepareCamera()
        }
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
        .fullScreenCover(isPresented: $showingPackageCamera) {
            CameraPicker(
                onImage: { image in
                    showingPackageCamera = false
                    readPackage(image)
                },
                onCancel: { showingPackageCamera = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: packagePhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    readPackage(image)
                }
                packagePhoto = nil
            }
        }
        .confirmationDialog("Add nutrition values", isPresented: Binding(
            get: { needsValues != nil },
            set: { if !$0 { needsValues = nil } }
        ), titleVisibility: .visible, presenting: needsValues) { product in
            Button("Photograph nutrition table") {
                labelTarget = product
                showingLabelCamera = true
            }
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            Button("Enter values manually") {
                phase = .editing(product, note: .manual, saveAs: .user)
            }
            Button("Cancel", role: .cancel) {}
        } message: { product in
            Text("\(product.displayName) has no nutrition values online yet.")
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
                    // Products identified only by their package have no barcode to cache under.
                    if !saved.barcode.isEmpty {
                        ProductCache.save(saved, in: context)
                    }
                    phase = .product(saved, isOfflineCopy: false)
                },
                onRetakePhoto: note == .manual ? nil : {
                    labelTarget = product
                    showingLabelCamera = true
                }
            )
            .navigationTitle("Nutrition Values")

        case .readingPackage:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading package…")
                    .font(.headline)
                Text("Text is recognized on your iPhone. The photo is not uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Package")

        case .packageMatches(let guess, let matches, let barcode, let errorMessage):
            packageMatches(guess: guess, matches: matches, barcode: barcode, errorMessage: errorMessage)
                .navigationTitle("Find Product")
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
                Menu {
                    packagePhotoButtons(barcode: nil)
                } label: {
                    Label("No barcode? Photograph package", systemImage: "text.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .controlSize(.large)
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
        // Stored products always have values (possibly 0 kcal, e.g. a zero-sugar drink).
        let cachedInfo = cached?.info

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
                packagePhotoButtons(barcode: barcode)
            } header: {
                Text("Find it by its package")
            } footer: {
                Text("Power reads the brand and name on the front and searches for the product.")
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

    // MARK: - Package front

    @ViewBuilder
    private func packagePhotoButtons(barcode: ProductBarcode?) -> some View {
        Button {
            packageBarcode = barcode
            showingPackageCamera = true
        } label: {
            Label("Photograph package front", systemImage: "camera")
        }
        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
        PhotosPicker(selection: Binding(
            get: { packagePhoto },
            set: { item in
                packageBarcode = barcode
                packagePhoto = item
            }
        ), matching: .images) {
            Label("Choose photo of package", systemImage: "photo.on.rectangle")
        }
    }

    private func readPackage(_ image: UIImage) {
        let barcode = packageBarcode
        phase = .readingPackage
        Task {
            let guess = (try? await PackageReader.read(image)) ?? PackageGuess()
            searchText = guess.searchQuery
            await search(guess: guess, barcode: barcode)
        }
    }

    private func search(guess: PackageGuess, barcode: ProductBarcode?) async {
        guard !guess.isEmpty else {
            phase = .packageMatches(guess, [], barcode: barcode, errorMessage: nil)
            return
        }
        do {
            let matches = try await ProductLookup.search(name: guess.searchQuery)
            phase = .packageMatches(guess, matches, barcode: barcode, errorMessage: nil)
        } catch {
            phase = .packageMatches(guess, [], barcode: barcode, errorMessage: error.localizedDescription)
        }
    }

    private func packageMatches(guess: PackageGuess, matches: [ProductInfo], barcode: ProductBarcode?,
                                errorMessage: String?) -> some View {
        List {
            Section {
                if guess.isEmpty {
                    Label("No product name could be read. Try a sharper photo of the front, or type the name below.",
                          systemImage: "text.magnifyingglass")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(guess.title.isEmpty ? guess.searchQuery : guess.title)
                            .font(.headline)
                        if let quantity = guess.quantity {
                            Text(verbatim: "\(quantity.formatted(.number.precision(.fractionLength(0...1)))) \(guess.isLiquid ? "ml" : "g")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(guess.usedLanguageModel
                             ? "Identified with Apple Intelligence on your iPhone."
                             : "Read from the largest text on the package.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    TextField("Product name", text: $searchText)
                        .submitLabel(.search)
                        .onSubmit { searchAgain(guess: guess, barcode: barcode) }
                    Button("Search") { searchAgain(guess: guess, barcode: barcode) }
                        .disabled(searchText.trimmingCharacters(in: .whitespaces).count < 2)
                }
            } header: {
                Text("Read from package")
            }

            Section {
                if let errorMessage {
                    Label(errorMessage, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                } else if matches.isEmpty && !guess.isEmpty {
                    Text("No matching products found. Try editing the name above.")
                        .foregroundStyle(.secondary)
                }
                ForEach(matches, id: \.self) { match in
                    Button {
                        choose(match, barcode: barcode)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.displayName)
                                .foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                if !match.brand.isEmpty { Text(match.brand) }
                                if match.hasNutrition {
                                    Text("\(Int(match.caloriesPer100Grams.rounded())) kcal / 100 \(match.isLiquid ? "ml" : "g")")
                                } else {
                                    Text("No nutrition values yet")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                if !matches.isEmpty { Text("Matching products") }
            } footer: {
                if matches.contains(where: { $0.source == .openFoodFacts }) {
                    Text("Data: Open Food Facts, available under the Open Database License (ODbL).")
                }
            }

            Section {
                Button {
                    labelTarget = product(from: guess, barcode: barcode)
                    showingLabelCamera = true
                } label: {
                    Label("Photograph nutrition table", systemImage: "camera.viewfinder")
                }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button {
                    phase = .editing(product(from: guess, barcode: barcode), note: .manual, saveAs: .user)
                } label: {
                    Label("Enter values manually", systemImage: "square.and.pencil")
                }
            } header: {
                Text("Not in the list?")
            }

            Section {
                Button("Scan a barcode instead") { phase = .scanning }
            }
        }
    }

    private func searchAgain(guess: PackageGuess, barcode: ProductBarcode?) {
        var edited = guess
        edited.searchQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard edited.searchQuery.count >= 2 else { return }
        phase = .readingPackage
        Task { await search(guess: edited, barcode: barcode) }
    }

    /// Uses a found product. A scanned barcode takes over, so the next scan of this
    /// package finds it on the phone.
    private func choose(_ match: ProductInfo, barcode: ProductBarcode?) {
        var product = match
        if let barcode { product.barcode = barcode.code }
        guard product.hasNutrition else {
            needsValues = product
            return
        }
        if !product.barcode.isEmpty {
            ProductCache.save(product, in: context)
        }
        phase = .product(product, isOfflineCopy: false)
    }

    /// A new product from what was read on the package, for entering values.
    private func product(from guess: PackageGuess, barcode: ProductBarcode?) -> ProductInfo {
        let typed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var info = ProductInfo(barcode: barcode?.code ?? "",
                               name: guess.name.isEmpty ? typed : guess.name,
                               brand: guess.brand, source: .user)
        info.isLiquid = guess.isLiquid
        return info
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
