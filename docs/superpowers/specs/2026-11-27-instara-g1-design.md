# Instara G1 (Perlanova) pasif dinleme — Tasarım

Tarih: 2026-11-27
Durum: Taslak (onay bekliyor)

## 1. Amaç ve neden

xDrip4iOS'a (GlucoEcoSystem fork'u) Teljane Instara-1 / Instara-G1 sensörü için bir CGM tipi eklenecek. Sensör Türkiye'de **Perlanova** adıyla satılıyor. Üreticinin kendi sitesine göre Instara-1, Ekim 2026'dan itibaren bazı pazarlarda Instara-G1 ambalajına geçiyor; protokol aynı kabul ediliyor. Ayrı bir model olan Instara-L1 kapsam dışı.

Bu tip, Sibionics GS1'deki gibi, **resmi Instara iOS uygulamasının açtığı Bluetooth bağlantısını pasif dinler**. iOS aynı fiziksel bağlantıyı birden çok uygulamaya paylaştırır. xDrip aynı bildirim karakteristiğine abone olur ve sensörün resmi uygulamaya gönderdiği paketleri çözer. Sensöre **hiçbir komut yazılmaz**. Kimlik doğrulama (8 karakterli kod), yanıtlar (ACK) ve buluttan gelen ayarlar (`0x04` komutu) resmi uygulamada kalır.

Sibionics'ten temel fark: Instara **glikozu sensörde hesaplar**. Bluetooth'tan fabrika kalibrasyonlu glikoz (mmol/L × 10) gelir. Parmak ucu kalibrasyonu gerekmez ve bu değerler ileride Loop'a verilebilir.

Ama protokol yalnızca resmi Android uygulamasının (`com.teljane.instara` 1.0.2) statik incelemesinden biliniyor ve **gerçek bir sensörde hiç doğrulanmadı**. Kaynak: JugglucoNG issue #1009, PR #1011 (açık, birleştirilmemiş, GPL-3). Bu yüzden değerler, kullanıcı resmi uygulamayla karşılaştırıp açıkça onaylayana kadar dışarı gitmez (Bölüm 6.5).

Sensörü kullanacak kişi ekipte değil. Doğrulama TestFlight, trace log'u ve resmi uygulamanın ekran görüntüleriyle yapılacak.

## 2. Hedefler, hedef olmayanlar, anti-hedefler

**Hedefler**
- Resmi uygulama bağlıyken Instara trafiğini almak ve çözmek: anlık glikoz (`0x10`, `0x01`), geçmiş (`0x03`, `0x30`), pil (`0x20`, `0x02`), el sıkışma (`0xF0`).
- Glikozu kalibrasyonsuz olarak xDrip'te göstermek. Resmi uygulamanın boşluk sonrası indirdiği geçmişi de geriye dönük doldurmak.
- Kullanıcı doğrulayıp anahtarı açınca Loop, Nightscout, Apple Health, Dexcom Share ve glikoz alarmlarını açmak.
- Bütün trafiği, özellikle bilinmeyen ve beklenmeyen paketleri, sonradan analiz edilebilecek biçimde log'a yazmak.

**Hedef olmayanlar**
- Resmi uygulama olmadan bağımsız bağlantı: kimlik doğrulama, 8 karakterli kod, `0x04` parametreleri. Aktif sürücü ayrı bir aşamadır.
- Resmi uygulamanın göstermeden önce yaptığı son işlemi (buluttan ayarlanan "analyzer") taklit etmek.
- Sibionics kodunu yeniden düzenlemek ya da ortak bir pasif dinleme temeli çıkarmak. Bu, iki sensör de cihazda doğrulandıktan sonra ayrı bir iş olacak.
- Instara-L1 ve el okuyucusu.

**Anti-hedefler** (teknik olarak çalışsa bile başarısızlık sayılır)
- Doğrulanmamış bir değerin, kullanıcı anahtarı açmadan Loop'a, Nightscout'a, Health'e ya da Dexcom Share'e gitmesi.
- Anahtar açılınca, kapalıyken biriken eski değerlerin topluca dışarı gönderilmesi.
- xDrip'in sensöre bir şey yazması ve resmi uygulamanın bağlantısını ya da sensör oturumunu bozması.
- Sibionics GS1'in davranışının değişmesi.

## 3. Kısıtlar

- iOS: arka planda bağlantı yalnızca `retrieveConnectedPeripherals(withServices:)` ve bekleyen `central.connect` ile yakalanabilir. Sibionics'teki model aynen geçerli.
- Loop için internet yok; her şey telefonda yerel çalışmalı.
- Protokol kaynağı (JugglucoNG PR #1011) GPL-3, xDrip4iOS da GPL-3. Kod kopyalanmayacak; protokol bilgileri (UUID'ler, paket düzeni, CRC) Swift'te bağımsız yazılacak. Kaynak belgede belirtilecek.
- Ölçüm aralığı 2.0–26.0 mmol/L (36–468 mg/dL). Okuma aralığı 5 dakika, sensör ömrü 21 gün, ısınma 15 dakika (üretici sitesi).
- Mevcut proje: Core Data modeli şu an v38 (Sibionics'i ekleyen sürüm). Instara v39 ile gelir. Upstream (JohanDegraeve/xdripswift) şu an v37'de. Fork v38 ile zaten ayrıştı; upstream ileride kendi v38/v39'unu çıkarırsa, upstream birleştirmesinde model sürümleri elle uzlaştırılmalı. Bu Instara'ya özgü değil, upstream izleme issue'sunda dikkat edilecek bir nokta.

## 4. Yaklaşımlar

1. **Ayrı yeni sensör tipi, Sibionics'i model alarak (seçildi).** `CGMInstaraG1Transmitter`, Sibionics'in pasif bağlantı mantığını kendi dosyasında yeniden kurar. Sibionics dosyalarına dokunulmaz. Kapılara yalnızca Instara için anahtara bakan bir cevap eklenir. Bedeli: Bluetooth bağlantı kodunun bir kısmı iki yerde benzer biçimde bulunur.
2. **Ortak pasif dinleme temeli.** Sibionics'in bağlantı yakalama mantığı ortak bir sınıfa taşınır, iki sensör onun üzerine kurulur. Daha temiz, ama cihazda hiç denenmemiş Sibionics sürümünü yeniden düzenleme riski taşıyor. Reddedildi; ileride ayrı iş.
3. **Aktif sürücü (JugglucoNG PR'ı gibi).** xDrip sensöre kendisi bağlanır ve 8 karakterli kodla doğrulama yapar. Resmi uygulama gerekmez, ama buluttan gelen `0x04` parametrelerini gönderemez; sensörün hesabı onlara bağlıysa değerler yanlış olur. PR ayrıca sensöre 21 değil 14 günlük kullanım süresi yazıyor. Reddedildi.

Yayın politikası için üç seçenek konuşuldu: (A) önce yalnızca gözlem, sonraki sürümde kodda açmak; (B) baştan tam açık; (C) gözlemle başlayıp kullanıcının bir anahtarla açması. **Kullanıcı C'yi seçti.**

## 5. Kaynaklar

- JugglucoNG issue #1009 ve PR #1011 (`feat/instara-g1-driver-updated`, commit e633ddf9), özellikle `docs/superpowers/specs/2026-11-23-instara-g1-driver-design.md` ve `InstaraProtocol.kt`.
- AndroidAPS `plugins/source/.../instara/InstaraPlugin.kt`: resmi Android uygulamasının yayınladığı değer, trend ve `sensorStartTime` alanları. Üreticinin açık kaynakla iş birliği yaptığının göstergesi.
- teljane-instara.com: ürün özellikleri.
- Bu repodaki Sibionics GS1 tasarımı ve kodu (`xDrip/BluetoothTransmitter/CGM/Sibionics/GS1/`). Pasif bağlantı, arka plan, güvenlik kapıları ve log için şablon.

## 6. Tasarım

### 6.1 Yeni ve değişen dosyalar

**Yeni**
- `xDrip/BluetoothTransmitter/CGM/Instara/G1/InstaraG1Protocol.swift`: UUID'ler, paket ayrıştırma, CRC-8/MAXIM, tipli paket sonuçları. Saf ve test edilebilir.
- `InstaraG1Session.swift`: sıra numarası takibi, zaman damgası üretimi, yeni sensör tespiti, tekrar ayıklama. Saf.
- `CGMInstaraG1Transmitter.swift`: pasif bağlantı. Sibionics'in yapısını izler.
- `xDrip/BluetoothPeripheral/CGM/Instara/G1/InstaraG1+BluetoothPeripheral.swift`, Core Data `InstaraG1` sınıfları ve model v39, `ConstantsInstaraG1.swift`.
- Testler: Protocol, Session, Transmitter ve kapı testleri (Sibionics'teki test sınıflarına paralel).

**Değişen:** `CGMTransmitterType` (`.instaraG1 = "Instara G1"`, raw değer kalıcı), `BluetoothPeripheralType`, `CGMSensorType`, `BluetoothPeripheralManager`, `RootApplicationCoordinator` (`NoCalibrator`), `UserDefaults` (anahtar ve kayıt noktası), `LoopManager`, `NightscoutSyncManager`, `HealthKitManager`, `DexcomShareUploadManager`, `AlertManager`, `BgPostProcessingManager`, `BackupService`, metinler ve tr çevirileri, cihaz ayrıntı ekranı (DetailState/ViewModel), `OnlineHelp`, `TroubleshootingLog`, `Trace`, `project.pbxproj`.

Bunların her biri Sibionics'i ekleyen commit'lerde değişen yerlerle aynı. Builder, Sibionics'in her `case .sibionicsGS1` dalını Instara için gözden geçirmelidir.

### 6.2 Bağlantı (pasif)

- Servis `8653000A-43E6-47B7-9CB0-5FC21D4AE340`, bildirim `8653000B-…`, yazma `8653000C-…` (yalnızca tanınır, hiç kullanılmaz).
- Sibionics'teki model aynen: `retrieveConnectedPeripheral(withServiceUUIDs: [8653000A])` ve geri çekilmeli tekrar, bilinen cihaz için tek bir bekleyen bağlantı isteği, 10 dakikalık bastırma, durumu geri yükleme, gözetleyici (veri gelmezse yeniden abone olma, sonra bağlantıyı kesme).
- Bütün `writeDataToPeripheral` çağrıları engellenir ve log'a yazılır. Yalnızca bildirime abone olunur (CCCD; Sibionics'te de böyle).
- Bağlantının sahibini log'lamak (LINK-OWNER: resmi uygulama mı, xDrip'in bekleyen bağlantısı mı) ve servise bağlı bütün cihazları listelemek Sibionics'teki gibi yapılır.
- Bilinmeyen: resmi iOS uygulamasının bağlantıyı sürekli mi açık tuttuğu, yoksa periyodik bağlanıp mı kopardığı. Tasarım ikisinde de çalışır; log'lar hangisi olduğunu gösterecek.

### 6.3 Paket işleme

- Paket: `55 AA | cmd | len | payload[len] | crc8`. CRC-8/MAXIM (init 0, yansıtılmış polinom 0x8C), CRC'den önceki bütün baytlar üzerinden.
- Başlık ya da CRC hatalı olan ya da `len` uzunluğuyla uyuşmayan paket atılır ve log'a yazılır (CRC-FAIL, LAYOUT-MISMATCH). Bir bildirimin birden çok paket taşıması ya da bir paketin iki bildirime bölünmesi ihtimaline karşı, Protocol bir bildirimi baştan sona tarar. Birden çok paketi sırayla çözer; tamamlanmamış bir paketin kalanını bir sonraki bildirimle birleştirmeyi dener. İki saniye içinde tamamlanmayan parça atılır.
- `0x10` / `0x01` anlık glikoz: payload[0..1] sıra numarası (u16 BE), payload[2..3] glikoz (u16 BE) ÷ 10 = mmol/L.
- `0x03` geçmiş başlığı: kaç tane `0x30` çerçevesi geleceği. PR'da `0x03` aslında uygulamanın yazdığı bir komut, sensörden geldiği belirsiz. Hiç görülmeyebilir; `0x30` çerçeveleri bu başlık olmadan da işlenir.
- `0x0A` okuma aralığı (u16, dakika): Bölüm 6.4.
- `0x30` geçmiş çerçevesi: başlangıç sıra numarası, aralık (dakika) ve ardışık u16 ÷ 10 değerleri. Kesin düzen PR'daki `HistoryPayload` alanlarına göre yazılır. Düzen tutmazsa çerçeve atılır ve LAYOUT-MISMATCH log'a yazılır.
- `0x20` / `0x02` pil yüzdesi: cihaz ekranında gösterilir.
- `0xF0` el sıkışma (donanım/yazılım sürümü): log'a ve ekrana yazılır.
- Bütün diğer komutlar (`0x07`, `0x06`/`0x60`, `0x08`/`0x70`, `0x40`, `0x50`, `0xFF` ve listede olmayanlar) çözülmeden ham hex olarak log'a yazılır (UNLISTED-CMD). Resmi uygulamanın sensöre yazdığı komutlar xDrip'e bildirim olarak gelmez; görülmesi beklenmez.

### 6.4 Glikoz kayıtları

- **Birim:** mmol/L × `ConstantsBloodGlucose.mmollToMgdl` = mg/dL (genel proje sabiti; Sibionics'in kendi 18.0182 sabiti kullanılmaz).
- **Aralık dışı değerler** (tasarımcının kararı, güvenli yön): 0 (ısınma) atılır. 0 < değer < 2.0 mmol/L ise 36 mg/dL'ye kırpılır, böylece düşük ekranda görünür ve anahtar açıkken `verylow` alarmı çalar. 26.0 < değer ≤ 40.0 mmol/L ise 468 mg/dL'ye kırpılır. 40.0 mmol/L üstü paket düzeni hatası sayılır ve atılır. Her kırpma ve atma OUT-OF-RANGE olarak ham değeriyle log'a yazılır. Ciddi bir düşük asla "veri yok" olarak kaybolmamalı.
- **Kalibrasyon yok:** `RootApplicationCoordinator.getCalibrator` Instara için `NoCalibrator` döndürür (Medtrum gibi). Instara için kalibrasyon isteği ve hatırlatması gösterilmez.
- **Okuma aralığı** (tasarımcının kararı): resmi uygulama aralığı sensöre `0x09` ile yazıyor; xDrip bunu göremez. Aralık şu sırayla belirlenir:
  1. Sensörün `0x0A` yanıtı görülürse ve 1–15 dakika arasındaysa, o değer.
  2. Yoksa ardışık anlık okumalardan ölçülür: `Δt / Δseq`, son 6 çiftin medyanı, en yakın tam dakikaya yuvarlanır.
  3. İkisi de yoksa 5 dakika.

  Üç kaynak birbiriyle çelişirse (ör. `0x0A` 5 dakika, ölçüm 1 dakika) ölçülen değer kullanılır ve INTERVAL-MISMATCH log'a yazılır. `0x0A` artık "listede olmayan" değil, çözülen bir komuttur. `0x30` çerçevesindeki `duration` alanı yalnızca log'lanır, zaman hesabında kullanılmaz (PR'da da kullanılmıyor).
- **Zaman damgası:** anlık okuma alındığı an damgalanır. Geçmişteki okuma, en son anlık okumanın zamanı ve sıra numarası referans alınarak `t = tRef − (seqRef − seq) × aralık` ile hesaplanır. Gelecekteki ya da şu anki okumadan yeni zamanlar kırpılmaz, atılır.
- **Tekrar ayıklama:** sıra numarasına ve oturuma göre. Var olan bir okuma tekrar yazılmaz.
- **Sensör başlangıcı ve ömrü:** başlangıç ≈ `tRef − seqRef × aralık`. Ömür 21 gün.
  - *Uygulama kararı:* ilk anlık okumada başlangıç varsayılan 5 dakikalık aralıkla hesaplanır. Aralık **ilk kez ölçüldüğünde** (en az 2 örnek) başlangıç bir kez yeniden hesaplanır; sonraki aralık değişimleri başlangıcı değiştirmez, yalnızca INTERVAL-CHANGE log'lanır. Bir SEQ-REANCHOR'dan sonra (aşağıda) başlangıç kilitlenir ve artık yeniden hesaplanmaz.
  - *Uygulama kararı:* bu tek seferlik yeniden hesaplama başlangıcı 30 dakikadan (`ConstantsInstaraG1.sensorStartTolerance`, 1800 sn) fazla kaydırırsa SENSOR-START-CORRECTED log'lanır ve yeni başlangıç, yeni sensör gibi bildirilir: xDrip'teki aktif sensör yeni başlangıçla değişir ve doğrulama anahtarı kapanır (oturumun ilk dakikalarında, zararsız). Aynı 30 dakikalık tolerans, doğrulamanın oturum başlangıcına ve xDrip'in aktif sensörüne bağlılık kontrolünde de kullanılır.
- **Yeni sensör tespiti** (tasarımcının kararı; Sibionics'ten bilerek farklı): Sibionics, sıra numarasındaki herhangi bir düşüşte ya da türetilen başlangıcın 30 dakikadan fazla kaymasında hemen yeni oturum başlatıyor. Instara'da yeni oturum anahtarı kapattığı için tek bir paket yetmez.

  *Uygulama kararı (yürütme sırasında değişti; ilk taslaktaki "türetilen başlangıç 30 dakikadan fazla kayarsa" kuralı ve 10 dakikalık onay penceresi kaldırıldı):* referans, son anlık okumanın sıra numarası ve zamanıdır. Yeni bir anlık okumanın referansa göre adımı `Δt / Δseq` ile hesaplanır.
  - **Aday (SESSION-SUSPECT):** sıra numarası son sıra numarasından 12'den fazla düşükse (`newSensorSeqDrop`) ya da ileri adım akla yatkın olamayacak kadar yavaşsa (adım > 1800 sn/sıra, `maxPlausibleStepSeconds`; 15 dakikalık aralıkta 15 dakika gecikmeye kadar tolerans).
  - **Onay (SESSION-NEW):** adaydan sonraki anlık okumanın sıra numarası adayınkinden büyük olmalı ve aday ile bu paket arasındaki adım akla yatkın olmalı (30–1800 sn/sıra). Yeni oturum bu iki paketten kurulur, iki okuma da yazılır; sensörün bildirdiği aralık korunur. Onaylanmayan aday atılır (SESSION-SUSPECT-CLEARED).
  - **Fazla hızlı ileri adım** (adım < 30 sn/sıra, `minPlausibleStepSeconds`) **asla yeni sensör sayılmaz** (yeni sensör saatin önüne geçemez): paket SEQ-JUMP olarak bekletilir, okuma yazılmaz, referans değişmez. Sonraki paket de referansa göre fazla hızlıysa ama bekletilen pakete göre adımı akla yatkınsa, sıra numarası gerçekten atlamıştır: referans yeni numaralandırmaya taşınır (SEQ-REANCHOR), yeni oturum açılmaz, iki okuma da yazılır ve başlangıç kilitlenir. Aksi halde bekletilen paket atılır (SEQ-JUMP-CLEARED).
  - Akla yatkın adımlı ileri bir sıra numarası (ör. telefon bir saat kapsama dışındaydı) normal okumadır; aralık değişimi olabilir.
  - Bilinen sınır: 1 saatten genç bir sensörün hızlı değiştirilmesi yavaş adım kuralıyla yakalanmayabilir; sıra numarası düşüşü kuralı geri kalanını yakalar. Elle ileri alınan saat yanlış bir yeni oturumu onaylayabilir (güvenli yön: anahtar kapanır).

  Yeni oturum xDrip'te aktif sensörü değiştirir ve doğrulama anahtarını kapatır (Bölüm 6.5).
- **Bilinen sınır, sensör değişimi** (*uygulama kararı*): verici yalnızca saklanan cihaz tanımlayıcısını (ilk eklenen sensörü) kabul eder. Yeni bir fiziksel sensör kendiliğinden alınmaz. Kullanıcı yeni sensörü resmi uygulamada eşleştirdikten sonra Instara cihazını xDrip'te (Cihazlar) silip yeniden eklemelidir; silmek doğrulama anahtarını da kapatır. Test talimatında yazılıdır.
- **Açık konu, geç gelen anlık okuma:** aralık ölçüldükten sonra geç gelen bir anlık okumayı alındığı an yerine sıra numarasına göre beklenen zamana damgalamak önerildi (final inceleme F4). Önerilen biçimi, aralık ölçüldükten sonraki bir aralık değişiminde (ör. 1 → 15 dk) her paketi "geç" sayıp referansı geriye kaydırıyor ve yanlış yeni oturum açtırıyor; bu yüzden henüz uygulanmadı. Şu an anlık okuma her zaman alındığı an damgalanır.
- **Trend:** xDrip'in kendi hesabı kullanılır. Sensörün bir trend alanı belgelenmemiş.

### 6.5 Doğrulama anahtarı ve güvenlik kapıları

**Davranış**
- Instara cihaz ekranında bir anahtar bulunur: "Değerleri doğruladım — Loop ve paylaşımı aç". Varsayılan değeri kapalıdır.
- **Kapalıyken** (Sibionics ile aynı): Loop / OS-AID paylaşımı engelli, Nightscout BG yüklemesi, HealthKit ve Dexcom Share kapalı. Değere dayalı alarmlar (`verylow`, `low`, `high`, `veryhigh`, `fastdrop`, `fastrise`) kapalı. Veri gelmiyor, sensör süresi ve Loop durdu alarmları açık.
- **Açarken:** onay penceresi çıkar. Metin: "Bu sensörün değerlerini resmi Instara uygulamasıyla karşılaştırdım ve tutarlı buldum. Değerler Loop'ta insülin dozlamasında kullanılacak. Yeni sensörde bu onay sıfırlanır." Onaylanmazsa anahtar kapalı kalır.
- **Açıkken:** Instara bütün kapılarda normal bir kaynak gibi davranır.
- **Kendiliğinden kapanma:** Session yeni bir sensör tespit ettiğinde ve kullanıcı Instara cihazını silip yeniden eklediğinde.

**Uygulama**
- `UserDefaults.instaraG1ExportVerified: Bool`. Builder, anahtarın hangi sensöre ait olduğunu da saklamalı (ör. türetilmiş başlangıç zamanı ya da oturum kimliği). Böylece uygulama yeniden başladığında başka bir sensöre ait onay geçerli sayılmaz.
- Şu an tipe bağlı sabit değer döndüren üç özellik Instara için anahtarı okur:
  - `CGMTransmitterType.allowsGlucoseExport`
  - `allowsGlucoseAlarms`
  - `osAidSharingPolicy` (`.blocked` / `.allowed`)

  `activeSourceAllowsGlucoseExport`, `activeSourceAllowsGlucoseAlarms` ve `activeOSAidSharingPolicy` bunları zaten kullandığı için Loop, Nightscout, HealthKit, Dexcom Share ve alarm kapıları otomatik olarak takip eder. Builder, bu değerleri önbelleğe alan ya da yalnızca tip değişince yeniden okuyan bir yer olup olmadığını kontrol etmelidir.
- **Biriken değerler:** anahtar kapalıdan açığa geçtiği an `advanceGlucoseExportCursors(to: Date())` çağrılır. Kapalıyken saklanan okumalar hiçbir zaman dışarı gitmez. Açıktan kapalıya geçişte ek bir işlem gerekmez, çünkü kapılar sonraki okumaları zaten durdurur. Kaynak değişiminde Sibionics'teki `advanceGlucoseExportCursorsIfLeavingBlockedSource` Instara için de çalışır; anahtar kapalıyken Instara "engelli kaynak" sayılır.
- **BG ayarı ve kalibrasyon farkı:** Sibionics'te BG ayarı kalibrasyonla üst üste bindiği için kapatılmıştı. Instara'da kalibrasyon olmadığı için normal kaynaklardaki davranış geçerli. Builder, `BgPostProcessingManager`'daki Sibionics istisnasının Instara'ya yayılmadığından emin olmalıdır.
- **Ekranların yenilenmesi:** ayar ekranları (ör. OS-AID satırının görünürlüğü, `canConfigureOSAidSharing`) yalnızca `cgmTransmitterTypeAsString` değişimini KVO ile izliyor. Anahtar değişince bu gözlemciler tetiklenmez. Builder, anahtarı KVO ile gözlenebilir bir UserDefaults anahtarı yapmalı ve aynı gözlemcilere eklemeli (ya da açık bir bildirim göndermeli). Böylece ayar ekranları ve LoopManager anında güncellenir.
- **Yedekleme:** anahtar ve bağlı olduğu sensör kimliği `BackupService`'in yedeğe alınmayan anahtarları listesine eklenir. Yedekten geri yükleme eski bir onayı taşımamalı.
- **Loop beklenen aralığı:** `LoopManager.directExpectedInterval` Sibionics için 60 sn. Instara için ölçülen okuma aralığı (varsayılan 300 sn) kullanılır; yoksa yanlış "Loop durdu" ya da eski veri uyarıları çıkar.
- Anahtarın her değişimi trace'e yazılır: `INSTARA-VERIFY on/off`, neden (kullanıcı / yeni sensör / cihaz silindi) ve sensör kimliği.
- Cihaz eklenirken Sibionics'teki gibi tek seferlik bir "deneysel" uyarısı gösterilir.

### 6.6 Tanılama ve log

- Her pakette komut, uzunluk, CRC sonucu ve çözülen alanlar log'a yazılır. Bilinmeyen paketlerde ham hex yazılır.
- Her anlık okumada sıra numarası, ham değer, mmol/L ve mg/dL değerleri, zaman damgası ve doğrulama anahtarının durumu yazılır.
- LINK-OWNER, servise bağlı cihaz listesi, gözetleyici ve bekleyen bağlantı olayları Sibionics'teki gibi yazılır.
- CLOCK-MISMATCH: geçmiş okumasından hesaplanan zaman, var olan bir okumayla 2 dakikadan fazla çelişirse yazılır.
- Sorun raporu paylaşımı (Ayarlar → Gelişmiş Ayarlar → Sorun Raporunu Paylaş) Instara kategorisini içerir.

### 6.7 Test

- **Protocol:** CRC test vektörleri; her komutun ayrıştırılması; bozuk başlık, CRC ve uzunluk; bir bildirimde birden çok paket; iki bildirime bölünmüş paket; atılan parça.
- **Session:** zaman damgası hesabı; okuma aralığının belirlenmesi (`0x0A`, ölçüm, varsayılan, çelişki); tekrar ayıklama; aralık dışı değerlerin kırpılması ve atılması; iki paketle onaylanan yeni sensör tespiti (sıra numarası düşüşü ve yavaş ileri adım); fazla hızlı ileri adımın yeni oturum değil SEQ-JUMP / SEQ-REANCHOR olması; başlangıcın yalnızca aralık ilk ölçüldüğünde yeniden hesaplanması ve SENSOR-START-CORRECTED; tek bir hatalı paketin yeni oturum başlatmaması; eski sürümün kaydettiği oturum durumunun çözülebilmesi.
- **Diğer:** anahtar değişince KVO gözlemcilerinin tetiklenmesi; anahtarın yedeğe alınmaması; Loop beklenen aralığının 300 sn olması.
- **Kapılar:** anahtar kapalı ve açıkken her dış çıkış kapısı ve her alarm türü; açılma anında kayıt noktasının ilerlemesi ve biriken değerlerin gitmemesi; yeni sensörde anahtarın kapanması; başka bir sensöre ait onayın yeniden başlatmada geçersiz sayılması; Instara'dan başka kaynağa geçiş.
- **Transmitter:** yazmaların engellenmesi; geri çekilme ve bekleyen bağlantı mantığı (Sibionics testlerine paralel).
- **Sibionics'in bozulmaması:** mevcut Sibionics testleri değişmeden geçmeli.

## 7. Kullanıcının verdiği kararlar

- Instara-1 / Perlanova eklenecek. Kaynak JugglucoNG PR #1011'deki protokol.
- Yöntem pasif dinleme. xDrip sensöre yazmaz.
- Yayın politikası C: gözlemle başla, kullanıcı anahtarla açsın.
- Anahtar davranışı önerildiği gibi kabul edildi: onay penceresi, yeni sensörde sıfırlanma, log'a yazılma, açılınca biriken değerlerin gönderilmemesi.
- Kurulum yolu 1: ayrı tip, Sibionics'e dokunulmaz.

Tasarımcının kararları (kullanıcı onayına sunuldu): okuma aralığının belirlenme sırası; iki paketle onaylanan yeni sensör tespiti; aralık dışı değerlerin kırpılması; anahtarın yedeğe alınmaması; Loop beklenen aralığı; metinlerin Sibionics düzeninde kalması.

## 8. Builder'a bırakılanlar

- `0x30` çerçevesinin bayt düzeninin PR'daki `HistoryPayload` alanlarından birebir çıkarılması.
- Parçalanmış paketleri birleştirmenin ayrıntıları (tampon sınırı, zaman aşımı).
- Anahtarın hangi sensöre ait olduğunu belirleyen kimlik (türetilmiş başlangıç zamanı ya da oturum sayacı).
- Cihaz ekranında pil, donanım/yazılım sürümü ve son ham değer satırları.
- Metinler: Sibionics'teki düzen izlenir. Kod içindeki varsayılan (`value:`) metinler Türkçe, tr.lproj'a da eklenir. `en.lproj` mevcut, ama Sibionics oraya giriş eklemedi; Instara da eklemez. İngilizce, iki sensör için birlikte ayrı bir iş.

## 9. Bu aşamanın çıktısı ve sonraki adımlar

İlk TestFlight sürümünden beklenenler:
- pasif dinlemenin iOS'ta Instara ile çalıştığı;
- birim ve paket düzeninin doğru olduğu;
- xDrip değerlerinin resmi uygulamayla ne kadar örtüştüğü (son işlem farkı).

Değerler tutarsa kullanıcı anahtarı açar ve Instara Loop'ta kullanılır. Tutmazsa log'lardaki ham paketlerle düzeltilir.

Sonraki olası işler: Sibionics ve Instara için ortak pasif dinleme temeli; JugglucoNG PR'ına 21/14 gün hatasının bildirilmesi; aktif sürücü.

## 10. Kullanıcıdan / müşteriden alınacak bilgiler

- Sensörün tam modeli (ambalajda Instara-1 / G1 / Perlanova yazısı) ve resmi uygulamanın sürümü.
- Test edecek kişinin iPhone modeli ve iOS sürümü.
- Resmi uygulamanın Apple Health'e glikoz yazıp yazmadığı. Karşılaştırma için kullanışlı, ama şart değil.
- Karşılaştırma sırasında resmi uygulamadan ekran görüntüleri ve aynı zamanların xDrip sorun raporu.
