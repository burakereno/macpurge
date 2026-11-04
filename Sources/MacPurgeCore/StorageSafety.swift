package enum SafetyLevel: String, CaseIterable, Sendable {
  case safe = "Güvenli"
  case review = "İncele"
}

package struct SafetyAssessment: Equatable, Sendable {
  package let level: SafetyLevel
  package let reason: String
}

/// Catalog rules describe the whole measured root, including mixed-use folders.
/// A path selected by the user does not inherit a tool's rule based on its name.
package enum StorageProfile: String, Codable, Sendable {
  case npmCache, goBuildCache, xcodeWorkspace, packageDownloads, sharedDependencies, uvCache,
    project, projectOutput, projectCache, projectBuild, projectGradleCache, gradleCache, unknown
  case simulatorCache, simulatorData, xcodeIntermediate, verifiedDownloads, unrecognizedDownloads
  case logs, personal, systemManaged, renderCache

  package static let gradleCacheReason =
    "Gradle önbelleği. Silince sonraki derlemede yeniden oluşur. Gerekli bağımlılıklar tekrar indirilir."

  package var isProjectOutput: Bool {
    self == .projectOutput || self == .projectCache || self == .projectBuild || self == .projectGradleCache
  }

  package func assessment(for state: ReadState?) -> SafetyAssessment? {
    switch state {
    case .partial:
      return .init(
        level: .review,
        reason: "Klasörün bir kısmı okunamadı. İçeriğinin tamamı hakkında karar verilemiyor.")
    case .complete: break
    case .absent, .unavailable, nil: return nil
    }

    switch self {
    case .verifiedDownloads:
      return .init(
        level: .safe,
        reason:
          "Araç bu indirmeleri yeniden alabilir. Çevrimdışı kurulum için önbelleğe ihtiyaç duyabilirsin."
      )
    case .unrecognizedDownloads:
      return .init(
        level: .review, reason: "Yarım indirme veya tanınmayan içerik var. Bu klasör taşınamaz.")
    case .npmCache:
      return .init(
        level: .safe,
        reason:
          "npm, erişilebilir paketleri gerektiğinde yeniden indirir. Çevrimdışı kurulum için bu önbellek gerekebilir."
      )
    case .goBuildCache:
      return .init(
        level: .safe,
        reason: "Go bu çıktıları sonraki derlemede yeniden üretir. İlk derleme daha uzun sürebilir."
      )
    case .xcodeIntermediate:
      return .init(
        level: .safe,
        reason: "Xcode ara çıktıları yeniden üretir. Sonraki derleme daha uzun sürebilir.")
    case .xcodeWorkspace:
      return .init(
        level: .review,
        reason:
          "DerivedData, derleme çıktılarının yanında test sonuçları, günlükler ve paket çalışma kopyaları da içerebilir."
      )
    case .packageDownloads:
      return .init(
        level: .review,
        reason:
          "Bu depoda indirilmiş veya yerel olarak oluşturulmuş paketler bulunabilir. Yeniden edinilebilirliklerini kontrol et."
      )
    case .sharedDependencies:
      return .init(
        level: .review,
        reason:
          "Birden fazla proje bu depoyu kullanabilir. Çevrimdışı paketleri ve kullanan projeleri kontrol et."
      )
    case .uvCache:
      return .init(
        level: .review,
        reason:
          "uv ortamları önbellekteki dosyalara bağlantı verebilir. Kaldırmak bu ortamları etkileyebilir."
      )
    case .gradleCache, .projectGradleCache:
      return .init(level: .safe, reason: Self.gradleCacheReason)
    case .projectCache:
      return .init(level: .safe,
        reason: "Proje önbelleği. Silince yeniden oluşur. İlk açılış veya derleme daha uzun sürebilir.")
    case .projectBuild:
      return .init(level: .safe,
        reason: "Derleme ara çıktıları. Sonraki derlemede yeniden oluşur. Kaynak kodu korunur.")
    case .projectOutput:
      return .init(level: .review, reason: "Temizlemeden önce projeyi kullanan araçları kapat ve klasörü incele.")
    case .project:
      return .init(
        level: .review,
        reason:
          "Seçilen klasör kaynak kodu ve kişisel dosyalar içerebilir. Bunları derleme çıktılarından ayrı değerlendir."
      )
    case .simulatorCache:
      return .init(
        level: .safe,
        reason:
          "Simülatör ve uygulamalar bu önbellekleri yeniden oluşturabilir. Çalışan cihaz geçici dosyalarını kullanıyor olabilir."
      )
    case .simulatorData:
      return .init(
        level: .review,
        reason:
          "Yüklü uygulamalar, ayarlar ve uygulama belgeleri burada saklanır. Cihazı sıfırlamak bu verileri kaybettirir."
      )
    case .renderCache:
      return .init(
        level: .safe,
        reason:
          "Bu uygulama grafik veya kod önbelleğini yeniden oluşturur. İlk açılış daha uzun sürebilir."
      )
    case .unknown:
      return .init(
        level: .review, reason: "Bu konumdaki dosyaların yeniden oluşturulabileceği bilinmiyor.")
    case .logs:
      return .init(
        level: .review,
        reason: "Günlükler tanılama geçmişini içerir. Eski kayıtlar tekrar üretilemeyebilir.")
    case .personal:
      return .init(
        level: .review,
        reason:
          "Kişisel veri veya projelerin kullandığı dosyalar içerebilir. Sahibinin uygulamasından incele."
      )
    case .systemManaged:
      return .init(
        level: .review,
        reason:
          "Bu konumu macOS veya sahibi olan araç yönetir. Alanı ilgili aracın ayarlarından incele.")
    }
  }
}
