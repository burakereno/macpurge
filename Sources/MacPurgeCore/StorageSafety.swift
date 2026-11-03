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
package enum StorageProfile: Sendable {
  case npmCache, goBuildCache, xcodeWorkspace, packageDownloads, sharedDependencies, uvCache,
    project, unknown
  case simulatorCache, simulatorData
  case logs, personal, systemManaged, renderCache

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
