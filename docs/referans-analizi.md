# MacPurge: macos-sysdata incelemesi

3 Kasım 2026 · [İncelenen kaynak](https://github.com/Jarvis322/macos-sysdata/tree/ebb7a5f7ad4287b46f247898de47078ec4f283a5) · Repo sürümü: 1.11.1. Aşağıdaki gözlemler bu revizyona ait; kullanıcının kurduğu uygulamanın sürümü doğrulanmadı. Referans klasörü sonradan silinebilir; bağlantılar sabit GitHub revizyonuna gider.

## Ürünün mantığı

macOS’un “Sistem Verileri” başka bir kategoriye girmeyen dosyaların genel adıdır. Referans uygulama, Ayarlar’dan bu kategorinin dosya listesini almıyor. Dosya sistemindeki bilinen yerlerden ve araçların verdiği bilgilerden kendi envanterini çıkarıyor. Bu yüzden başlıktaki toplam ile macOS’un gösterdiği sayı birbirinden farklı olabilir. [Apple’ın açıklaması](https://support.apple.com/en-us/102624) · [Envanter motoru](https://github.com/Jarvis322/macos-sysdata/blob/ebb7a5f7ad4287b46f247898de47078ec4f283a5/Sources/SysDataMenu/Services/JSONInventory.swift)

| Aşama | Uygulamanın yaptığı | Bizim için anlamı |
| --- | --- | --- |
| Bul | Açılışta ve yaklaşık 24 saatte bir, 23 uzman tarayıcıyı paralel başlatıyor. Örneğin Xcode için bilinen dizinleri, simülatörler için simctl’yi, Docker için kendi depolama raporunu kullanıyor. Sonuçlar 19 kategoride toplanıyor. | Her kategori için ölçümün kaynağını bilmek gerekiyor; Docker’ın tahmini ile ölçülmüş bir klasörün boyutu aynı tür veri değil. |
| Ölç | Genel klasör ölçümü normal dosyaların diskte ayrılan boyutunu ve en son değişiklik tarihini topluyor. Bazı araçlar boyutu kendileri bildiriyor; snapshot boyutu bilinmiyorsa boş bırakılıyor. | “Ölçülen”, “tahmini” ve “bilinmiyor” ayrı kalmalı. Tarih de kullanım kanıtı değil, karara yardımcı bir işaret. |
| Eksikleri ara | Bilinen bulgular arasındaki bazı iç içe kayıtları ayıklıyor. Ardından belirli köklerde, kişisel belgeler ve bulut klasörleri gibi istisnalarla, henüz açıklanmamış yaklaşık 500 MiB ve üzerindeki klasörleri arıyor. | Pahalı genel aramayı hızlı taramadan ayırabiliriz. Tanınmayan klasörleri yalnızca inceleme için göstermek daha güvenli. |
| Karar ver | Bir öğenin boyutu, sahibi/kategorisi, riski ve yapılacak işlem ayrı tutuluyor. Hedef alan planı kullanıcı adına bir seçim öneriyor. | “Neden bu öneriyi görüyorum?” ve “Kaldırırsam ne olur?” sorularının cevabı her öneride görünmeli. |
| Uygula ve doğrula | Dosyayı Çöp’e taşıma, kalıcı silme, aracın kendi komutunu çağırma ve gerektiğinde yönetici istemi ayrı yollar. Uygulama boş alanı yeniden ölçüyor; yerel geçmişten tekrar büyüyen kalemleri gösterebiliyor. | Seçilen boyut, Çöp’e taşınan boyut ve diskteki boş alan değişimi ayrı raporlanmalı. |

Korunmaya değer fikirler: proje bazında farklı konumlardaki çıktıları ilişkilendirme, alan hedefinden bir plan çıkarma, işlemin etkisini önceden gösterme ve tekrar büyüyen veriyi açıklama. Bunların hiçbiri orijinal uygulamanın kodunu veya tasarımını kullanmayı gerektirmiyor.

## Doğruladığım iki sorun

1. **Çöp’e taşıma garantisi yok.** Kullanıcıya ait bir yol Çöp’e taşınamazsa kod aynı yol için kalıcı silmeyi deniyor. Docker gibi araç komutlarının da Çöp üzerinden geri alması yok. Bizim sözleşmemiz açık olmalı: “Çöp’e taşı” işlemi başarısızsa dosya yerinde kalır ve hata görünür. Kalıcı bir araç işlemi kendi adıyla ve etkisiyle onaylanır. [İşlem uygulayıcısı](https://github.com/Jarvis322/macos-sysdata/blob/ebb7a5f7ad4287b46f247898de47078ec4f283a5/Sources/SysDataMenu/Services/Reclaimer.swift#L122-L155)
2. **Aynı fiziksel veri birden fazla kez sayılabiliyor.** Referansın genel ölçüm fonksiyonunu geçici klasörde çalıştırdım. İki adla görünen tek bir 1 MiB dosyası (hard link) için ayrılan alan 1 MiB iken ölçüm 2 MiB döndürdü. Dolayısıyla klasör boyutunu “bu kadar alan açılır” diye kullanamayız. Hard link’lerde dosya kimliğini ve seçim dışında kalan bağlantıları hesaba katmalı; paylaşımını bilemediğimiz bloklarda tahmini belirtmeliyiz. [Klasör ölçümü](https://github.com/Jarvis322/macos-sysdata/blob/ebb7a5f7ad4287b46f247898de47078ec4f283a5/Sources/SysDataMenu/Services/DiskSize.swift#L35-L70)

## Hantallık: ölçüm ile gözlemi ayırmak

- **Dosya sayısı etkili.** Aynı genel ölçüm fonksiyonuna aynı 32 MiB veriyi verdim. Tek dosyada üç geçiş 2,92 / 0,15 / 0,10 ms; 32 dizine yayılmış 4.096 dosyada 23,56 / 17,05 / 14,73 ms sürdü. Geçici veriler testten hemen önce oluşturuldu. Bu küçük test gerçek disk taramasının süresini veya uygulamanın arayüz gecikmesini ölçmez; aynı boyut için dosya sayısının iş yükünü nasıl değiştirdiğini gösterir.
- **Açılışta yapılan işin kapsamı geniş.** Kategori taramaları zaten paralel ve bulgular geldikçe gösteriliyor. Buna rağmen her tam taramada uzman tarayıcıların arkasından genel arama geliyor. Bazı tarayıcılar her klasör için ayrı iş başlatıyor; bu düzeyde ortak bir eşzamanlılık sınırı yok. Aynı anda daha çok iş başlatmanın yararını varsaymak yerine süre, dosya sayısı ve kullanıcı etkileşimi birlikte ölçülmeli. [Akış](https://github.com/Jarvis322/macos-sysdata/blob/ebb7a5f7ad4287b46f247898de47078ec4f283a5/Sources/SysDataMenu/Model/ScanModel.swift#L539-L617) · [Klasör başına işler](https://github.com/Jarvis322/macos-sysdata/blob/ebb7a5f7ad4287b46f247898de47078ec4f283a5/Sources/SysDataMenu/Probes/StorageProbe.swift#L37-L53)
- **Ekranda karar vermenin de bir maliyeti var.** [Referans görüntüsünde](https://github.com/Jarvis322/macos-sysdata/blob/ebb7a5f7ad4287b46f247898de47078ec4f283a5/assets/screenshot.png) 460 × 640 puanlık panelde toplam, halka, beş kalemlik açıklama, trend, iki seçim eylemi ve görünüm değiştirici asıl listenin önünde. Pencere de aynı temel görünümü kullanıyor. Bilgi mevcut, fakat “ilk nereyi incelemeliyim?” sorusu ikinci planda kalıyor. Bu bir tasarım değerlendirmesi; gerçek arayüz profili alınmadı.

## MacPurge için önerilen ilk sürüm

Ana ürün genişleyebilen bir macOS penceresi olsun. Açılış ekranında mevcut boş alan, son ölçümün zamanı ve anlamlı birkaç öneri görünsün. Bir öneri seçildiğinde denetçi bölmesinde dosya yolu, hangi projeye/araca ait olduğu, kaldırmanın etkisi, geri alma olanağı ve Finder’da gösterme aynı yerde olsun. Menü çubuğu son durumu ve ana pencereyi açma kısayolunu taşısın.

Örnek: Bir projenin kaynakları Belgeler’de, derleme çıktısı başka bir klasörde yaşayabilir. Kullanıcı projeyi seçince ikisinin ilişkisini görür: “Bu çıktı kaldırılabilir; kaynakların kalır; sonraki derleme daha uzun sürebilir.” Kararı anlamak için ham komut okumak gerekmez; teknik ayrıntı isteyen için gerçek yol ve işlem açılabilir.

| Sıra | Kapsam | Bitmiş sayılma ölçütü |
| --- | --- | --- |
| 1. Salt okunur ilk sürüm | Xcode DerivedData, bilinen paket önbellekleri, kullanıcı günlükleri ve kullanıcının seçtiği proje kökleri. Açılışta son sonuç, sınırlı hızlı tarama; derin tarama isteğe bağlı. İzin yoksa ilgili alan “taranamadı” görünür. | İlk sonuç süresi, değişmeyen ikinci tarama, iptale yanıt ve tarama sırasında kaydırma ölçülür. Büyük/küçük dosya ağaçları ve paylaşılan dosya örnekleri ayrı kontrol edilir. Önbellekteki sonucun tarihi görünür; eski sonuç silme yetkisi vermez. |
| 2. Geri alınabilir temizlik | Yalnızca açıkça tanınan, kullanıcıya ait hedefler. İşlemden hemen önce yolun, dosya kimliğinin ve izin verilen kökün tekrar kontrolü. Çöp’e taşınamazsa durma. | Değişmiş hedef, symlink, izin eksikliği ve başarısız Çöp işlemi kişisel dosyalarda kalıcı silmeye neden olmamalı. Çöp’e taşınan ile boş alandaki değişim ayrı yazılır. |
| 3. İleri araçlar | Docker ve simülatörler için önce salt okunur envanter; sonra ayrı onayla araç düzeyinde işlemler. Geçmiş, alan hedefi ve yeniden büyüme takibi, ölçümler güvenilir olduktan sonra. | Bir kaynağa ait veriler çift sayılmamalı; Docker volume’ü, cihaz yedeği veya VM diski genel temizlik seçimine girmemeli. |

İlk kapsamın dışında: otomatik silme, yönetici yetkisiyle sistem temizliği, Time Machine snapshot silme, yerinde sıkıştırma ve widget. Bunlar ilk kullanıcı faydasını kanıtlamak için gerekli değil.

## Kaynak kullanımı

[Güncel lisans](https://github.com/Jarvis322/macos-sysdata/blob/ebb7a5f7ad4287b46f247898de47078ec4f283a5/LICENSE) okumaya ve kişisel kullanıma izin veriyor; mevcut kodun başka bir ürüne alınması için yazılı izin istiyor. Lisansın belirttiği eski MIT kapsamı v0.3.7 ve öncesine ait. Öneri: referans kopyasını analiz için ayrı tutmak; ürün kurallarını, uygulamayı, arayüz metinlerini, görselleri ve testleri kendi gereksinimlerimizden yazmak.
