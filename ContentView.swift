import SwiftUI
import Combine
import CoreLocation

// نموذج بلاغ. هذه النسخة تحفظ سجلًا محليًا فقط؛ لا ترسل بلاغًا ولا تدّعي التشفير.
struct IncidentReport: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let latitude: Double?
    let longitude: Double?
    let status: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        latitude: Double?,
        longitude: Double?,
        status: String = "محفوظ محليًا — غير مُرسل"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.status = status
    }
}

@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var latestLocation: CLLocation?
    @Published var authorizationDenied = false
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            authorizationDenied = true
        @unknown default:
            authorizationDenied = true
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways ||
            manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        } else if manager.authorizationStatus == .denied ||
                    manager.authorizationStatus == .restricted {
            authorizationDenied = true
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latestLocation = locations.last
        authorizationDenied = false
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // لا نعرض إحداثيات افتراضية عند فشل تحديد الموقع.
        latestLocation = nil
    }
}

@MainActor
final class EmergencyViewModel: ObservableObject {
    @Published var reports: [IncidentReport] = []
    @Published var message = ""
    @Published var showMessage = false
    @Published var isGettingLocation = false
    @Published var latestLocation: CLLocation?
    @Published var locationDenied = false

    private let locationService = LocationService()
    private let storageKey = "incidentReports.v1"

    init() {
        loadReports()
        locationService.$latestLocation
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                self?.latestLocation = location
                self?.isGettingLocation = false
            }
            .store(in: &cancellables)
        locationService.$authorizationDenied
            .receive(on: RunLoop.main)
            .sink { [weak self] denied in
                self?.locationDenied = denied
                if denied { self?.isGettingLocation = false }
            }
            .store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    func refreshLocation() {
        isGettingLocation = true
        locationService.requestLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.isGettingLocation else { return }
            self.isGettingLocation = false
            self.message = "تعذّر الحصول على الموقع الآن. يمكنك السماح بالوصول للموقع من إعدادات الآيفون."
            self.showMessage = true
        }
    }

    func saveLocalDraft() {
        let location = latestLocation
        let report = IncidentReport(
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude
        )
        reports.insert(report, at: 0)
        persistReports()
        message = location == nil
            ? "حُفظ سجل تجريبي على هذا الجهاز فقط، دون موقع. لم يُرسل البلاغ ولم تُشفّر البيانات."
            : "حُفظ السجل على هذا الجهاز مع إحداثيات الموقع. لم يُرسل البلاغ ولم تُشفّر البيانات."
        showMessage = true
    }

    private func loadReports() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([IncidentReport].self, from: data) else {
            reports = []
            return
        }
        reports = decoded
    }

    private func persistReports() {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    func deleteReports(at offsets: IndexSet) {
        reports.remove(atOffsets: offsets)
        persistReports()
    }
}

struct ContentView: View {
    @StateObject private var viewModel = EmergencyViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 42))
                                .foregroundStyle(.blue)
                            Text("نظام الطوارئ")
                                .font(.title.bold())
                            Text("نسخة أولية للاختبار المحلي")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

                        VStack(spacing: 10) {
                            Label("تنبيه مهم", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text("هذا النموذج لا يتصل بخدمات الطوارئ أو الأقمار الصناعية. الحفظ محلي وغير مشفّر في هذه النسخة. لا تستخدمه كبديل لطلب المساعدة الفعلية.")
                                .font(.subheadline)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

                        VStack(spacing: 12) {
                            Button {
                                viewModel.refreshLocation()
                            } label: {
                                Label(
                                    viewModel.isGettingLocation ? "جارٍ تحديد الموقع…" : "تحديد موقعي الحالي",
                                    systemImage: "location.fill"
                                )
                                .frame(maxWidth: .infinity)
                                .padding()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isGettingLocation)

                            if let location = viewModel.latestLocation {
                                Text("الموقع: \(location.coordinate.latitude, specifier: "%.5f"), \(location.coordinate.longitude, specifier: "%.5f")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            } else if viewModel.locationDenied {
                                Text("إذن الموقع مرفوض. يمكنك تغييره من إعدادات الآيفون.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("لم يتم تحديد الموقع بعد.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Button(role: .destructive) {
                                viewModel.saveLocalDraft()
                            } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 38))
                                    Text("حفظ سجل استغاثة تجريبي")
                                        .font(.headline)
                                }
                                .foregroundStyle(.white)
                                .frame(width: 210, height: 170)
                                .background(.red, in: Circle())
                                .shadow(color: .red.opacity(0.25), radius: 12, y: 5)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)

                            Text("الزر أعلاه يحفظ سجلًا تجريبيًا فقط؛ لا يرسل استغاثة.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(.background, in: RoundedRectangle(cornerRadius: 20))

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("السجلات الأخيرة")
                                    .font(.headline)
                                Spacer()
                                Text("\(viewModel.reports.count)")
                                    .foregroundStyle(.secondary)
                            }

                            if viewModel.reports.isEmpty {
                                ContentUnavailableView(
                                    "لا توجد سجلات",
                                    systemImage: "tray",
                                    description: Text("يمكنك حفظ سجل تجريبي لاختبار الواجهة.")
                                )
                                .frame(minHeight: 140)
                            } else {
                                ForEach(viewModel.reports) { report in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label(report.status, systemImage: "doc.text")
                                            .font(.subheadline.bold())
                                        if let lat = report.latitude, let lon = report.longitude {
                                            Text("الموقع: \(lat, specifier: "%.5f"), \(lon, specifier: "%.5f")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("لم يُرفق موقع")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(report.timestamp, format: .dateTime.year().month().day().hour().minute())
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .onDelete(perform: viewModel.deleteReports)
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("الطوارئ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                EditButton()
            }
            .alert("تنبيه النظام", isPresented: $viewModel.showMessage) {
                Button("موافق", role: .cancel) { }
            } message: {
                Text(viewModel.message)
            }
            .environment(\.layoutDirection, .rightToLeft)
        }
    }
}

@main
struct EmergencyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
