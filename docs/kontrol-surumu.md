# MacPurge 0.2.13 kontrol sürümü

3 Kasım 2026. Kullanıcının son kapsam kararı doğrultusunda bu sürüm salt okunur. Tarama ve plan motorları ölçülen konumlarda yalnızca metadata ve izin verilen araç kayıtlarını okur. Kullanıcı tercihleri, geçmiş ve widget özeti MacPurge’ün kendi depolamasında tutulur.

## Mac’te deneme

1. [MacPurge uygulamasını](../dist/MacPurge.app) aç. Genel bakış son tamamlanmış taramayı, gerçek boş alanı ve en büyük üç öğeyi gösterir. Yeni tarama ilerledikçe kategori ölçümleri gelir. Bir kategorinin veya alt öğenin satırına tıklayarak ayrıntılarını açıp kapatabilirsin. Odaklanan satırda sağ ok ayrıntıları açar, sol ok kapatır.
2. **Depolama** açılışta kategorileri ölçülen boyuta göre sıralar. Çubukların yeşil kısmı Güvenli, turuncu kısmı İncele olarak ölçülen alanı gösterir; iki boyut da altında yazılıdır. Çubuklar en büyük kategoriyle aynı ölçektedir. Kategoriye tıklayarak öğelerini veya **Tüm öğeler** ile düz listeyi aç. İsim, kategori veya yol ara. Güvenli ve İncele filtrelerini dene. Bir öğeyi çift tıklayarak yolu, ölçüm kaynağını, tarihi ve sınıflandırma gerekçesini gör. Sağ tuşla bir öğeyi önerilerden gizleyebilirsin.
3. **Alan planı** ekranında bir hedef belirleyip **Adayları öner** düğmesine bas. Yalnızca tam ölçülmüş, Güvenli etiketli ve ev klasörüyle aynı diskteki adaylar seçilir. Paylaşılan dosyalar için ölçüm muhafazakârdır. Planı değiştirmek boş disk alanını değiştirmez.
4. Açılışta ayrıntılı tarama başlar. **Tarama kapsamı → Hızlı tarama** ile daha dar bir tarama yapabilirsin. Docker yalnızca bir yerel soket mevcutsa sorgulanır. Araç kapalıysa veya boyut bildirmiyorsa durum açıklanır. Korumalı konumlar Ayarlar’dan ayrıca etkinleştirilir.
5. **Proje klasörleri** ekranında seçtiğin kökün toplamını, bilinen çıktı dizinlerini, son kaynak ve derleme tarihlerini incele. Xcode çalışma alanı metadatası eşleşirse proje dışında kalan DerivedData gösterilir. Harici disk önerileri önce listelenir, tarama için klasörü kendin eklersin.
6. **Etkinlik** tamamlanmış yerel SQLite kayıtlarını karşılaştırır. Aynı kapsamda yeterli geçmiş olduğunda büyüme gösterilir. Geçmişi kapatmak kayıtları temizler. Menü çubuğu, bildirimler ve günlük hızlı tarama isteğe bağlıdır.

## Teslim kapsamı

| Bölüm | Bu paketteki davranış |
| --- | --- |
| Salt okunur çekirdek | SwiftPM üzerinden ayrı MacPurgeCore kütüphanesi, dosya kimliğiyle tekilleştirme, kök ve hacim sınırı, iptal ve erişim durumları. APFS geçerli özyinelemeli nesil sayısı sağlıyorsa değişmeyen tam ölçüm yeniden kullanılır. Diğer durumlarda klasör yeniden ölçülür. |
| Hızlı tarama | DerivedData, simülatör cihazlarının veri/önbellek ayrımı, paket depoları, kullanıcı günlükleri ve seçilmiş proje klasörleri. |
| Ayrıntılı tarama | Envanterin 19 kaynak ailesi için kaynak kuralları. Runtime ve SDK eşleşmeleri, model katmanları, Android, uygulama ve medya verileri, VM’ler, Docker, snapshot bilgisi, paylaşılan alanlar ve büyük cache klasörleri. Bir aracın özel konumlarını kapsama düzeyi araçtan araca değişir. |
| Karar ve geçmiş | Filtre, boyut veya tarihe göre sıralama, ayrıntılar, Finder bağlantısı, seçim listesi, hedef açığı, büyüme karşılaştırması, menü çubuğu ve yerel bildirimler. |
| Diğer girişler | Aynı çekirdekle canlı JSON ve CLI planı. Kestirmeler son kayıtlı ölçümü ve hedef önizlemesini kullanır. Widget uygulamanın paylaştığı tarihli özetle çalışır. |
| Dil | Türkçe ve İngilizce ana iş akışları. Almanca, Fransızca, İspanyolca, Japonca, Basitleştirilmiş Çince, Korece ve Rusça için gezinme, etiketler, risk açıklamaları ve temel akış metinleri yerelleştirildi. Bazı ikincil açıklamalar ve araçların bildirdiği adlar ortak dilde kalabilir. |
| Yerel dağıtım | Xcode projesi, imzalı app, imzalı widget uzantısı ve yerel kurulum DMG’si. Paket denetimi, uygulama kimliğini, geliştirici takımını, Developer ID imzasını ve içeriğin bütünlüğünü doğrular. |

## Doğrulama kaydı

- 0.2.3’te kategori çubukları ham öğe toplamı yerine ölçüm sırasında tekilleştirilen boyutları kullanır. Hem Güvenli hem İncele öğesinde bulunan bir dosya aynı kategoride yalnızca İncele’ye yazılır. Kısmi ölçümde yalnızca okunabilen bölüm gösterilir; ölçülemeyen kategoriye sıfır boyut atanmaz.
- 0.2.2’de Depolama’da AI modelleri ve araçları, Android, uygulama verileri ve önbellekleri, geliştirici aracı verileri, simülatör cihazları, Xcode, simülatör runtime’ları, paket yöneticileri, diğer büyük klasörler, sistem, geçici dosyalar, günlükler ve tanılama ayrı ayrı görülebilir. Diğer mevcut kategoriler de listede kalır. Ölçüm tamamlandıkça kategori açılır; **≥** ölçülen alt sınırdır. Runtime boyutları CoreSimulator’ın bildirdiği imaj boyutlarıdır. Geçici dosyalar son kullanım yaşı ayrımı olmadan ölçülür. Ölçülen boyut boşaltılabilecek alan anlamına gelmez.
- Genel uygulama ve araç klasörleri, daha özel bir konuma ait dalları dışarıda bırakır. Uygulama kapsayıcıları ayrıca etkinleştirilir; bulut depoları ve kişisel belge klasörleri genel taramanın parçası değildir. Diğer büyük klasörler seçilmiş araç konumlarında 500 MiB sınırıyla aranır.
- Bu Mac’te 0.2.2 ile tamamlanan ayrıntılı taramada 477 öğe raporlandı ve görsellerdeki 12 kategorinin her biri ölçüm gösterdi. 3 Kasım 2026 saat 18:28 ölçümünde AI araçları 36,16 GB, Android 30,89 GB, runtime imajları 11,76 GB, geçici dosyalar en az 2,92 GB idi. Android ve simülatör satırlarından ayrı öğelere geçiş uygulamada doğrulandı.
- 0.2.1’de Depolama tablosunun yükseklik hesabı düzeltildi. 38 satırla normal ve çeyrek ekran boyutlarında kaydırma doğrulandı. Başlık, filtreler, kenar çubuğu ve alt işlemler görünür kalıyor.

- Gerçek Mac’te uygulama açıldı. Genel bakış, ayrıntılı tarama, risk filtresi, öğe denetçisi, alan hedefi ve geçmiş akışı incelendi. Bu makinede 13 simülatörün toplamı yaklaşık 14,94 GB göründü. Sonuçlar makinenin kullanımıyla değişebilir.
- Ayrıntılı CLI çıktısında yol maskeleme doğrulandı. 20 GB hedefli CLI önizlemesinde alan açığı ve işlemin uygulanmadığı görüldü. Widget uzantısı macOS kayıtlarında, iki App Intent de paket metadatasında doğrulandı.
- Geçici veri testleri hard link, seyrek dosya, sembolik bağlantı, izin reddi, iptal, önbellek geçerliliği, model paylaşımı, Compose image atfı, SQLite ve farklı hacimlerin plana girmemesini kapsar.
- Apple M4 Pro üzerinde Release ölçümü. Birer baytlık 100.000 dosyada 10 geçişin p95 süresi 178,87 ms, aynı mantıksal boyutu tek dosyada ölçmenin p95 süresi 0,24 ms oldu. İptal yanıtı p95 0,16 ms altında kaldı. Dosyalar testten hemen önce oluşturuldu, disk önbelleği zorla boşaltılmadı.
- Başlangıç profillemesi ayrı bir Release yapılandırmasında 10 gerçek uygulama açılışından alındı. Açma komutundan görünür pencereye p95 910,3 ms, ilk ölçülen gerçek konuma p95 1.472,4 ms. Bunlar bu Mac’in sonuçlarıdır.
- Yerel DMG salt okunur bağlandı ve içindeki uygulamanın iç içe imzaları doğrulandı. Kaynaklarından biri değiştirilmiş paket reddedildi.

Asıl yol haritasındaki canlı Çöp’e taşıma, kalıcı araç işlemleri, otomatik silme ve yerinde sıkıştırma kontrol sürümünün dışında tutuldu. Noter onayı, çevrimiçi güncelleme ve herkese açık dağıtım ayrı yayın adımlarıdır. Başlangıç diskindeki ölçülen alan APFS klonlarının veya snapshot’ların paylaşımı nedeniyle kesin boşalma tahmini değildir.

## Çalıştırma

`./script/build_and_run.sh --verify` Xcode Release uygulamasını üretip açar. `swift test` çekirdek ve ürün testlerini çalıştırır. Büyük veri deneyi isteğe bağlıdır:

```sh
MACPURGE_BENCHMARK=1 swift test -c release --filter syntheticStorageSweep
dist/MacPurge.app/Contents/MacOS/MacPurge --json
dist/MacPurge.app/Contents/MacOS/MacPurge --plan 20 --extended
./script/package_review.sh
```
