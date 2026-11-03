# MacPurge 0.3.0 ve macos-sysdata 1.11.1

3 Kasım 2026. Referans olarak projeye indirilen 1.11.1 sürümünün kodunu inceledim. MacPurge tarafında imzalı 0.3.0 uygulamasını çalıştırdım. Karşılaştırma özellik kapsamını gösterir. İki uygulamanın tarama hızını aynı koşullarda karşılaştırmadım. [Referans sürüm](https://github.com/Jarvis322/macos-sysdata/tree/ebb7a5f7ad4287b46f247898de47078ec4f283a5)

| Alan | macos-sysdata 1.11.1 | MacPurge 0.3.0 |
| --- | --- | --- |
| Envanter | 23 uzman tarayıcı ve son aşamada genel büyük klasör araması. | 19 kaynak ailesi, hızlı ve ayrıntılı tarama. Genel büyük klasör araması belirli araç konumlarıyla sınırlı. Her özel araç konumu bire bir eşleşmiyor. |
| Kategori görünümü | Boyut ve risk dağılımı, son ölçüme göre değişim ve satırda eğilim çizgisi. | Genel Bakış’ta hizalı sayı rozetleri ve boyut, Depolama’da Güvenli/İncele alan çubukları. Geçmiş karşılaştırması ve disk grafiği var. Her satırda eğilim çizgisi yok. |
| Risk ve seçim | Safe, Review ve Manual. Görünür güvenli öğeleri toplu seçme, kalemleri gizleme, tekil ve toplu işlem. | Güvenli ve İncele, ölçülemeyenler için ayrı filtre. Depolama’dan seçim veya alan hedefine göre öneri. Yalnız tam ölçülmüş ve desteklenen kullanıcı önbellekleri işlem görebilir. |
| Silme ve sonuç | Safe öğelerde doğrudan silme veya tercihe göre Çöp. Review için Çöp ve öğeye göre araç komutları. Yönetici onayı isteyen işlemler de var. | Açık yol listesi ve onaydan sonra yalnızca Çöp’e taşıma. Taşınan, atlanan ve diskteki gözlenen boş alan değişimi ayrı görünür. Önizlemeden sonra değişen hedef atlanır. |
| Geri alma | Çöp’e giden öğeler için geri alma penceresi. | Uygulama yeniden açıldıktan sonra da Alan planı’ndan geri alma. Özgün konum doluysa üzerine yazılmaz. Öğe hâlâ Çöp’te olmalıdır. |
| Paket ve uygulama önbellekleri | Paket yöneticisine ve uygulamaya özel daha çok hedef, budama ve araç komutları. | npm ve Go önbellekleri; Slack, Discord, VS Code ve Cursor’ın GPU/kod önbellekleri için kapalı uygulama ve okunabilir hedef şartı. Korumalı konumlarda macOS erişimi belirler. |
| Simülatör | Önbellek temizleme, cihaz sıfırlama, kullanılamayan cihazları ve runtime’ları kaldırma. | Cihaz verisi ve önbellek ayrı ölçülür. Durumu Shutdown olarak doğrulanan cihazda yalnız tanımlı cache/tmp klasörleri taşınabilir. Cihaz sıfırlama ve runtime kaldırma yok. |
| Xcode ve projeler | Arşivler, DerivedData, atıl projeler ve proje çıktılarına yönelik işlemler. Harici proje arama ve anonim kart. | Seçilen proje kökleri, çıktı klasörleri ve ilişkilendirilebilen DerivedData ölçülür. Harici kök seçimi ve anonim kart var. Proje kökü, tüm DerivedData ve arşivler İncele grubunda. |
| Docker, modeller, VM, Android ve sistem | Öğeye göre Docker prune, model kaldırma, snapshot ve sistem komutları. | Yerel envanter, araçların bildirdiği boyutlar ve sahiplik bilgileri gösterilir. Bu gruplara yönelik silme veya yönetici komutu yok. |
| Geçmiş ve entegrasyonlar | Yerel geçmiş, haftalık büyüme, düşük alan bildirimleri, menü çubuğu, widget, JSON ve Kestirmeler. CLI ve Kestirmeler üzerinden temizlik de var. | Yerel ölçüm geçmişi, büyüme ve boş alan grafiği, bildirimler, menü çubuğu, widget, CLI/JSON ve Kestirmeler. Bu girişlerden ölçüm veya plan alınabilir. Silme, masaüstündeki onay ekranından yapılır. |
| Otomasyon ve ileri işlemler | İsteğe bağlı haftalık temizlik, sıkıştırma, kimlik doğrulama ve kapanışta simülatörleri durdurma. | İsteğe bağlı zamanlanmış tarama var. Otomatik silme, yerinde sıkıştırma, Touch ID ile işlem yetkilendirme ve kapanış müdahalesi yok. |
| Dağıtım | İmzalı dağıtım, Homebrew ve isteğe bağlı çevrimiçi güncelleme. | İmzalı yerel uygulama ve doğrulanmış kontrol DMG’si. Kamuya açık yayın, noter onayı ve çevrimiçi güncelleme yapılmadı. |

Referans davranışlarının kaynakları: [tarayıcı kaydı](https://github.com/Jarvis322/macos-sysdata/blob/ebb7a5f7ad4287b46f247898de47078ec4f283a5/Sources/SysDataMenu/Services/JSONInventory.swift), [işlem uygulayıcısı](https://github.com/Jarvis322/macos-sysdata/blob/ebb7a5f7ad4287b46f247898de47078ec4f283a5/Sources/SysDataMenu/Services/Reclaimer.swift), [ürün ve dağıtım açıklaması](https://github.com/Jarvis322/macos-sysdata/blob/ebb7a5f7ad4287b46f247898de47078ec4f283a5/README.md).

## Bu Mac’te doğrulananlar

| Örnek | MacPurge | Bağımsız ölçüm |
| --- | ---: | ---: |
| Xcode DerivedData | 2.784.821.248 bayt | 2.784.821.248 bayt |
| npm | 186.052.608 bayt | 186.052.608 bayt |
| Go | 148.746.240 bayt | 148.746.240 bayt |
| Seçili proje örneği, MacPurge Sources | 237.568 bayt | 237.568 bayt |

Bağımsız ölçüm, normal dosyaların ayrılmış bloklarını dosya kimliğine göre bir kez saydı. Aynı npm kökünü seçili proje olarak da ölçünce iki görünümde aynı 186.052.608 bayt çıktı. Bu rakamlar birbirine eklenmez. 13 simülatörde bağımsız sayımdan önce ve sonra MacPurge ölçümü alındı. 12 cihazın iki bölümü de üç ölçümde eşleşti. Bir cihazın veri boyutu ikinci geçişte değişti; bağımsız sayım ilk geçişle eşleşti. Bağımsız toplamda 13.804.703.744 bayt cihaz verisi ve 1.137.356.800 bayt önbellek görüldü.

İmzalı uygulama, izole test kullanıcı klasöründeki tek npm önbelleği için önce tam yolu gösterdi. Onayla 12 kB’lık klasör macOS’un gerçek Çöp’üne taşındı. O anda diskte gözlenen boş alan değişimi 0 bayttı. Uygulama kapatılıp yeniden açıldıktan sonra **Geri al**, aynı dosyayı aynı konuma getirdi. Hem dosya kimliği hem SHA-256 özeti eşleşti. Ayrı bir denemede macOS’un okumaya izin vermediği uygulama destek klasörü seçime girmedi. Kullanıcının mevcut önbellekleri bu denemelerde taşınmadı.

Test koşusunda 23 test geçti. İsteğe bağlı büyük performans deneyi atlandı. Çöp kullanılamadığında kaynağın yerinde kalması, değişen hedef, dış bağlantı, kısmi başarı, çalışan simülatör ve geri almada ad çakışması ayrıca sınandı.
