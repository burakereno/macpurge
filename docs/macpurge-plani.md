# MacPurge — ürün, tasarım ve geliştirme planı

3 Kasım 2026 · 0.2.13 salt okunur kontrol noktası yerel Git geçmişinde korunur. 0.3.0, Alan planı üzerinden onaylı Çöp’e taşıma ve geri alma ekler. [Kontrol kapsamı ve doğrulama kaydı](kontrol-surumu.md) · [Özellik envanteri](ozellik-envanteri.md) · [İlk teknik inceleme](referans-analizi.md)

**Ürün vaadi:** “Diskimde ne büyüdü, kime ait, neyi kaldırırsam ne kaybederim?” MacPurge bunu açıklayacak, önerilen işlemi önceden gösterecek ve sonucunu ölçecek. Geliştirici Mac’leri güçlü bir ilk kullanım alanı; teknik olmayan bir kullanıcı da komut bilmeden karar verebilmeli.

## 1. Yeni tasarım

Ana yüzey yeniden boyutlandırılabilen bir Mac penceresi. Görsel dil: Finder kadar sakin bir dosya listesi, okunaklı sistem tipografisi, hizalanmış boyutlar ve yalnızca seçim, uyarı ve işlem sonucunda kullanılan renk. Koyu/açık temada sistem renkleri; riskin adı ve simgesi her zaman görünür. Referansın ikonları, metinleri, halka grafiği ve kart düzeni kullanılmayacak.

| Yüzey | Kullanıcının işi | İlk tasarım kararı |
| --- | --- | --- |
| Genel bakış | “Neden diskim doluyor?” | Gerçek boş alan ve son ölçüm zamanı; altında en çok yer tutan veya büyüyen üç **neden**. Eksik tarama ayrı bir durum. Boş bir Mac’te de işe yarayan, eylem gerektirmeyen sonuç ekranı. |
| Depolama | “Bu alanın içi ne?” | Kategori, sahip, boyut ve değişim sütunları. Klavyeyle arama, filtre ve çoklu seçim. Denetçi bölmesinde konum, dosya dökümü, ölçümün güvenilirliği, sonraki kullanım maliyeti ve Finder bağlantısı. |
| Projeler | “Bu eski projenin maliyeti nedir?” | Kaynak konumu ile farklı yerlerdeki derleme çıktıları ilişkilendirilir. Son kaynak değişikliği, son derleme ve paylaşılan veri ayrı. Kaynak dosyalar planın parçası olamaz. |
| İşlem planı ve sonuç | “Tam olarak ne olacak?” | Seçilmiş ama filtreyle gizlenmiş öğeler dahil tam liste; geri alınabilir ve kalıcı işlemler ayrı. Sonuçta taşınan, kalan/atlanmış ve boş alandaki değişim ayrı yazılır. |
| Etkinlik | “Geçen hafta sildiğim şey niye geri geldi?” | İşlem geçmişi, büyüyen sahipler ve geri gelen öğeler. Geçmişi kapatma ve silme görünür. |
| Menü çubuğu ve ayarlar | “Şu anda durum ne?” | Menü çubuğu isteğe bağlı kısa özet ve pencere kısayolu. İzinler, kapsam, bildirimler ve otomasyon ayarlarda; ana pencerenin küçük kopyası yapılmaz. |

**İlk prototip senaryosu:** Örnek veride 8 GB Xcode çıktısı, 30 GB sanal makine ve erişilemeyen bir konum olsun. En büyük kalem sanal makine olsa da temizlik önerisi Xcode çıktısına gider. Kullanıcı bunun hangi projeye ait olduğunu, kaynak kodun kalacağını ve ilk derlemenin uzayabileceğini görür. Çöp’e taşıdıktan sonra “Taşınan: 8 GB” ve “Şimdi açılan: 0 GB” beraber görünür. Bunlar tasarım örneğidir, gerçek Mac ölçümü değildir. İkinci akışta “20 GB gerekiyor” hedefi güvenli adaylarla sağlanamıyorsa eksik miktar gösterilir; VM plana sessizce eklenmez.

## 2. Motorun sınırları

- **Tarama ve işlem ayrı:** Tarayıcı hiçbir şeyi değiştiremez. Bulgu; sahip/proje, disk ve dosya kimliği, ölçüm kaynağı (ölçülen/tahmini/bilinmiyor), boyut, tarih ve kapsam taşır. Risk, tekrar oluşturma maliyeti ve geri alınabilirlik farklı alanlardır.
- **Hız:** Son bilinen sonuç tarihli olarak açılır. Bilinen yerlerin hızlı taraması önce gelir; derin arama kullanıcı seçerse yapılır. Disk başına sınırlı eşzamanlılık, iptal, araç çağrılarına zaman aşımı, sonuçların aralıklı yayımlanması. Değişiklik takibi kaçırılırsa ilgili kök yeniden ölçülür; yalnız üst klasörün tarihine güvenilmez.
- **Doğru toplam:** Aynı dosyaya giden bağlantıları disk+dosya kimliğiyle ve iç içe adayları sahiplikle tekilleştir. Seçim dışında hard link kalıyorsa tüm boyutu kazanç sayma. APFS klonları, snapshot’lar, seyrek disk imajları ve araçların tahminleri için kesin boşalma vaat etme. Ayrı disklerin kazanımlarını toplayıp başlangıç diskine yazma.
- **İzinler ve mahremiyet:** Tam Disk Erişimi olmadan ilk açılış kullanılabilir. Önce kullanıcı seçtiği proje kökünü yetkilendirebilir. Korunan konum erişilemiyorsa “taranamadı”; kişisel içerik ve bulut sağlayıcısı kökleri genel aramanın dışında. Envanter yerel; tanı dışa aktarımı kullanıcı başlatır, yollar varsayılan olarak maskelenir.
- **İşlem sözleşmesi:** Hedefin kimliği, kökü, hacmi ve sembolik bağlantı durumu uygulamadan hemen önce tekrar kontrol edilir. Değişmiş, kullanımda veya şüpheli hedef atlanır. Çöp başarısızsa kalıcı silmeye veya yönetici yetkisine düşülmez. Kalıcı araç işlemi ayrı, adlı ve görünürdür. Kesinti sonrası kayıt, hangi öğenin işlenip hangisinin kalmış olduğunu gösterir.

## 3. Uygulama sırası

| Faz | Teslim | Çıkış ölçütü |
| --- | --- | --- |
| **F0 · Tasarım prototipi** | Bağımsız görsel yön; Genel Bakış → Proje → İşlem → Sonuç akışı, dar/geniş pencere, açık/koyu görünüm, boş ve kısıtlı durum. Tamamen örnek veri. | Fare ve yalnız klavye ile iki örnek akış tamamlanır. Test eden kişi neyin korunacağını ve Çöp’e taşımanın neden henüz alan açmadığını doğru anlatabilir. |
| **F1 · Salt okunur çekirdek** | Native SwiftUI pencere; Swift çekirdek paketi; hızlı tarama, dış araç bağdaştırıcıları için sözleşme, ilk envanter: DerivedData, bilinen paket önbellekleri, kullanıcı günlükleri, seçilmiş proje çıktıları. | Gerçek kullanıcı verisine yazma yok. Geçici veri setinde hard link, seyrek dosya, erişim reddi, iptal, çevrimdışı disk ve değişmeyen ikinci tarama doğrulanır. |
| **F2 · İlk kullanılabilir sürüm** | Depolama ve Projeler; filtre, denetçi, seçim planı; kullanıcıya ait doğrulanmış çıktıları Çöp’e taşıma; yerel işlem kaydı, sonuç ve TR/EN. | Değişen hedef, sembolik bağlantıyla kök dışına çıkan hedef ve Çöp hatası kalıcı silmeye neden olamaz. İptal edilen toplu işlem, tamamlanan ve kalan öğeleri doğru gösterir. |
| **F3 · Kapsam ve geçmiş** | Envanterdeki diğer kaynak ailelerini salt okunur tamamla; derin tarama, harici proje kökü, ölçüm geçmişi, alan hedefi, büyüme/geri dönüş açıklaması; az alan uyarısı, menü çubuğu. | Her kaynağın örnek girdisi, sahiplik kuralı, izin/araç yokluğu ve çift sayım testi vardır. Güvenli hedef yetersizse plan eksikliği açıklar. |
| **F4 · Denetimli ileri işlemler** | Simülatör, paket ve Docker gibi araçların kendi işlemleri; kimlik doğrulama, bildirim tercihleri, CLI/JSON, Shortcuts, widget, ek diller. Otomasyonda önce önizleme; açıkça seçilmiş kurallarla sınırlı çalışma. | Pencere, CLI ve Shortcuts aynı işlem kurallarını kullanır. Aktif proje durdurulmaz, volume/VM/yedek genel temizliğe hiç girmez. Widget disk taramaz. |
| **F5 · Ayrı doğrulama ve dağıtım** | Yerinde sıkıştırma ve özel sistem işlemleri için izole laboratuvar; eşdeğerini sunmayacağımız özellikler envanterde gerekçeli. Dağıtım için kendi bundle kimliği, imzalı/noter onaylı paket, doğrulanmış güncelleme, temiz kurulum ve güncelleme provası. | Kesinti, yetersiz alan ve paylaşılan blok senaryolarında özgün dosyalar/metadata korunmadan sıkıştırma yayınlanmaz. Yayın kararından önce geri dönüş ve imza kontrolleri geçer. |

**Teknik yerleşim önerisi:** Uygulama hedefi pencere ve izin akışlarını yönetir. Ayrı Swift paketinde ölçüm, kaynak tanımları, salt okunur tarama ve işlem planlama bağımsız test edilir. Durum ve işlem geçmişi yerel SQLite deposunda; bildirim, widget ve CLI aynı çekirdeğe bağlanır. macOS 14+ önerilen taban, sistem sürümüne özel görünüm ve API’ler koşullu. Kişisel dosyalar test girdisi olmaz.

**Performans kabulü:** İlk hedefler, ürün iddiası değil: aynı test Mac’inde Release derlemede son kayıtla kullanılabilir pencere ≤1 sn, hızlı taramada ilk kullanılabilir bulgu ≤2 sn, iptal sonrası yeni iş üretiminin durması ≤250 ms. 10 tekrarın p95’ini, cihazı, dosya sayısını, soğuk/sıcak koşulu ve ölçüm aralığını kaydet. 100 bin küçük dosya, aynı toplam boyutta az büyük dosya, değişmeyen tarama ve ulaşılamayan dış araç ayrı ölçülür. İkinci taramada dosya ziyaretleri azalmalı; iz kaybolduğunda tam doğruluk için tekrar tarama kabul edilir. Instruments ile tarama sürerken kaydırma ve ana iş parçacığında dosya I/O’su ayrıca kontrol edilir.

**İlk geliştirme teslimi:** F0’da gerçek dosya erişimi olmayan çalışan bir pencere prototipi. İlk karar noktası, bu ekranda bir öneriyi okuyup sonucunu doğru tahmin edebilmek. Referans koduna, metinlerine veya görsellerine ürün hedefinden bağımlılık eklenmez; referans klasörü silindiğinde plan ve yeni ürün tek başına kullanılabilir.

## 4. Projeye kurulan geliştirme skill’leri

Plan yazıldıktan sonra `find-skills` ile macOS tasarımı, SwiftUI erişilebilirliği ve Swift concurrency arandı. Aşağıdaki iki kaynak MIT lisanslı, arşivlenmemiş ve projeye özel kuruldu. Sayılar 3 Kasım 2026’daki CLI araması ve GitHub repo bilgisidir.

| Skill | Seçim nedeni | Kaynak ve tekrar kurulum (proje kökünde) |
| --- | --- | --- |
| macos-design-guidelines | F0–F2: yeniden boyutlandırma, klavye, araç çubuğu, menüler ve pencere davranışları. Topluluğun macOS tasarım rehberi; gerektiğinde Apple dokümanıyla karşılaştırılır. | [ehmo/platform-design-skills](https://skills.sh/ehmo/platform-design-skills/macos-design-guidelines) · 4,4 bin kurulum, 639 repo yıldızı · `npx skills add ehmo/platform-design-skills --skill macos-design-guidelines --agent codex --yes` |
| swift-concurrency | F1–F4: tarama işlerini UI’dan ayırma, yapılandırılmış görevler, iptal ve paylaşılan durum. | [AvdLee/Swift-Concurrency-Agent-Skill](https://skills.sh/avdlee/swift-concurrency-agent-skill/swift-concurrency) · 17,3 bin kurulum, 1.702 repo yıldızı · `npx skills add AvdLee/Swift-Concurrency-Agent-Skill --skill swift-concurrency --agent codex --yes` |

Kaynak ve içerik kayıtları [skills-lock.json](../skills-lock.json) içinde. Pencere yönetimi, SwiftUI/AppKit, test, paketleme ve imzalama için mevcut macOS skill’leri kullanılabilir. Görsel tasarımın başarısı için ölçüt skill sayısı değil, örnek kullanıcı akışının okunabilirliği ve klavyeyle çalışmasıdır.
