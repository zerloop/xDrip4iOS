# Sibionics GS1 pasif dinleme (birlikte çalışma) — Tasarım

Tarih: 2026-11-26
Durum: Taslak (onay bekliyor)

## 1. Amaç ve neden

xDrip4iOS'a (GlucoEcoSystem fork'u) Sibionics GS1 sensörü için bir CGM tipi eklenecek. Bu tip, **resmi Sibionics iOS uygulamasının açtığı Bluetooth bağlantısını pasif olarak dinler**: iOS aynı fiziksel bağlantıyı birden çok uygulamaya paylaştırır, xDrip aynı bildirim karakteristiğine abone olur ve sensörün resmi uygulamaya gönderdiği paketleri alıp çözer. Sensöre **hiçbir şey yazılmaz**. Projedeki Medtrum TouchCare Nano entegrasyonu aynı yöntemle çalışıyor ve şablondur.

Nihai hedef, müşterinin Sibionics GS1'i bir yama pompa ile Loop'ta kullanmasıdır. Ama:
- Sibionics glikozu sensörde değil, **resmi uygulamanın içindeki kapalı algoritmada** hesaplar. Bluetooth'tan yalnızca ham akım değeri gelir. Dexcom'dan temel farkı budur.
- Kapalı algoritmanın açık kaynak portları (JugglucoNG / GumimiCGM) Ghidra çıktısının mekanik çevirisidir: telif ve tıbbi mevzuat riski taşır ve resmi uygulamayla eşitliği yalnızca ilk ~2 saat için kanıtlanmıştır.
- Gerçek algoritma olmadan sapmanın hızlı yükselişlerde ±30 mg/dL'yi aştığı bildiriliyor (chalimov/sibionics_cgm_ha yazarı).

Bu yüzden bu aşamanın amacı **Loop'a veri vermek değil, kanıt toplamaktır**: pasif dinleme iOS'ta çalışıyor mu, sensör trafiğinde hesaplanmış bir glikoz alanı var mı, ham değer + parmak ucu kalibrasyonu resmi uygulamadan ne kadar sapıyor. Loop kararı bu kanıtla ayrı bir aşamada verilecek.

Sensör geliştirici ekipte yok, bir müşteride. Doğrulama TestFlight + müşterinin gönderdiği trace log'u ve ekran görüntüleriyle yapılacak.

## 2. Hedefler, hedef olmayanlar, anti-hedefler

**Hedefler**
- Resmi uygulama bağlıyken GS1 trafiğini almak ve çözmek (RC4, sabit anahtar).
- Glikoz kayıtlarındaki ham değeri xDrip kalibrasyonuyla (parmak ucu) glikoza çevirip ekranda **deneysel** olarak göstermek.
- Trafiğin tamamını, özellikle henüz anlamı bilinmeyen paket tiplerini, sonradan analiz edilebilecek biçimde log'a yazmak.
- Müşterinin resmi uygulama ile xDrip'i aynı telefonda yan yana kullanarak karşılaştırma verisi üretebilmesi.

**Hedef olmayanlar**
- Loop/AID'e glikoz paylaşımı (bu aşamada her zaman kapalı).
- Resmi uygulama olmadan bağımsız bağlantı: kimlik doğrulama, aktivasyon, MAC adresi (önceki tasarımın konusuydu, ertelendi; bkz. Bölüm 9).
- Sibionics'in kapalı algoritmasını ya da onun türev portlarını kullanmak.
- Bulut takipçisi (internetsiz çalışmaz, Loop için uygun değil).
- GS3 (farklı protokol).

**Anti-hedefler** (teknik olarak çalışsa bile başarısızlık sayılır)
- Sensöre ya da yazma karakteristiğine (`FF32`) tek bir bayt yazılması. Yanlış bir komut resmi uygulamanın oturumunu bozabilir.
- Resmi uygulamanın bağlantısının ya da alarmlarının aksaması (ör. xDrip'in bağlantıyı koparması, sürekli bağlan/kop döngüsü).
- Kalibre edilmemiş ham değerin glikoz gibi gösterilmesi, alarm tetiklemesi ya da Nightscout'a, Apple Health'e veya Loop'a gitmesi.

## 3. Kısıtlar

- **Resmi uygulama şart.** Veri yalnızca resmi Sibionics uygulaması sensöre bağlıyken akar. Uygulama kapatılırsa veya iOS onu askıya alıp bağlantı düşerse veri durur. Dexcom G7 birlikte çalışma modunda da durum aynıdır.
- **iOS paylaşımı varsayımı.** Medtrum entegrasyonu, iOS'un bir bildirim karakteristiğine abone olan birden çok uygulamaya aynı bildirimleri ilettiğini sahada göstermiştir. Sibionics için doğrulanmadı; ilk test turunun ana sorusudur.
- **Yazma yok, okuma serbest.** Standart GATT okumaları (`180A` Cihaz Bilgisi, `180F`/`2A19` batarya) sensörün durumunu değiştirmez ve yapılabilir.
- **Uzaktan test.** Tek geri bildirim kanalı mevcut trace paylaşımı (`Trace.swift`) ve müşterinin ekran görüntüleri.
- **TestFlight hattı** mevcut (`fastlane/Fastfile`, `.github/workflows/build_xdrip.yml`).

## 4. Yaklaşımlar

Kullanıcıyla bu sırayla değerlendirildi:

| Yaklaşım | Durum | Neden |
|---|---|---|
| Doğrudan Bluetooth (kimlik doğrulamalı) + ham değer kalibrasyonu | Ertelendi | MAC adresi gerekiyor (iOS vermiyor, müşteride Android yok); doğruluk Loop için yetersiz |
| Bulut takipçisi (`cgm-ce.sisensing.com`) | Elendi | İnternetsiz çalışmaz, gecikmeli; Loop için uygun değil |
| Kapalı algoritma portu (JugglucoNG/GumimiCGM) | Beklemede | Telif, mevzuat ve kanıt eksikliği; hukuki onay gerekir |
| Loop'ta desteklenen sensör (Dexcom G7, Libre 3) | Alternatif | Teknik olarak en güvenli; müşteri kararına bağlı |
| **Pasif dinleme + ham değer kalibrasyonu, Loop kapalı** | **Seçildi** | MAC yok, yazma yok, resmi uygulama çalışmaya devam eder, yan yana kıyas mümkün |

## 5. Kaynaklar

| Kaynak | Kullanım | Lisans |
|---|---|---|
| Juggluco (`j-kaltes/Juggluco`, branch `primary`): `cpp/sibionics/interpret_data.cpp`, `process.cpp`, `handleData.cpp` | RC4, paket biçimleri, ACK eşlemesi, glikoz kaydı yapısı | GPL-3.0: kod taşınabilir, atıf verilir |
| `georgevbm/GS1BridgePrototype` | Eski firmware (`AA 55`) çerçeve biçiminin bağımsız doğrulaması | GPL-3.0 |
| `chalimov/sibionics_cgm_ha` | EU paket biçimlerinin ve batarya karakteristiğinin bağımsız doğrulaması | **Lisans yok**: yalnızca bilgi olarak, kod kopyalanmaz |
| Medtrum TouchCare Nano (`CGMMedtrumTouchCareNanoTransmitter.swift`) | Pasif dinleyici iskeleti, yeniden bağlanma, watchdog | Proje içi |

JugglucoNG / GumimiCGM algoritma kodu ve Sibionics `.so` dosyaları **kullanılmaz**.

## 6. Tasarım

### 6.1 Yeni ve değişen dosyalar

Yeni:
- `xDrip/BluetoothTransmitter/CGM/Sibionics/GS1/SibionicsGS1Protocol.swift`: saf mantık: RC4, checksum doğrulama, paket sınıflandırma, glikoz kaydı ayrıştırma. CoreBluetooth'a bağımlı değil, birim testli.
- `xDrip/BluetoothTransmitter/CGM/Sibionics/GS1/CGMSibionicsGS1Transmitter.swift`: Medtrum iskeleti üzerine pasif dinleyici.
- `xDrip/BluetoothPeripheral/CGM/Sibionics/GS1/SibionicsGS1+BluetoothPeripheral.swift`
- `xDrip/Core Data/classes/SibionicsGS1+CoreDataClass.swift`, `+CoreDataProperties.swift`
- `xDrip/Constants/ConstantsSibionicsGS1.swift`
- `xDrip Tests/SibionicsGS1ProtocolTests.swift`

Değişen (Medtrum'un dokunduğu yerler): `BluetoothPeripheralType.swift`, `CGMSensorType.swift`, `CGMTransmitter.swift` (`CGMTransmitterType`, açıklama, `osAidSharingPolicy`, batarya), `BLEPeripheral+CoreDataProperties.swift`, yeni Core Data model sürümü (**v38**, v37'den hafif migration), `RootApplicationCoordinator.getCalibrator`, `BluetoothPeripheralManager`, `LoopManager`, `BgPostProcessingManager`, `AlertKind`, `ConstantsLog`, `Trace.swift`, `TroubleshootingLog.swift`, `OnlineHelp.swift`, `UserDefaults.swift`, `BackupModels.swift`, `SensorManagementView.swift`, `BluetoothPeripheralDetailState` / `BluetoothPeripheralsViewModel`, `Texts*`, `project.pbxproj`, ilgili testler.

### 6.2 Bağlantı (pasif)

- Servis `0000FF30-0000-1000-8000-00805F9B34FB`, bildirim karakteristiği `FF31`.
- Bağlanma: Medtrum'daki gibi `retrieveConnectedPeripheral(withServiceUUIDs: [FF30])`, yani resmi uygulamanın zaten bağlı olduğu cihaz alınır. Tarama ile bağlanmaya çalışılmaz: resmi uygulama bağlıyken sensör büyük olasılıkla reklam yapmaz, ve bağlı değilken bağlanmak bu aşamanın işi değildir. Taban sınıfın `startScanning()`'i (ekleme akışı ve `didDisconnect` geri dönüşü bunu çağırır) **override edilir**: tarama yerine `retrieveConnected` denemesi ve geri çekilmeli yeniden deneme yapar.
- Bağlı cihaz yoksa durum: "Resmi Sibionics uygulamasını açın ve sensörün bağlı olduğundan emin olun." Medtrum'daki geri çekilmeli yeniden deneme (5/10/15 sn) uygulanır.
- İlk başarılı bağlantıda peripheral `identifier`'ı ve adı kaydedilir; sonraki bağlantılarda yalnız bu cihaz kabul edilir. Birden çok `FF30` cihazı bağlıysa log'a yazılır ve kaydedilen ilk cihaz seçilir *(tasarım kararı)*.
- Keşif: taban sınıf yalnız `servicesCBUUIDs` listesini keşfettiği için liste `[FF30, 180A, 180F]` olarak verilir *(tasarım kararı; `nil` ile tüm servisleri keşfetmek gereksiz)*; bulunan tüm karakteristikler (UUID, özellikler) log'a yazılır. `FF31` için `setNotifyValue(true)`. `180A` karakteristikleri ve `2A19` batarya bir kez okunur.
- **Yazma yasağı:** Medtrum'daki gibi yazma UUID'si alım UUID'si ile aynı verilir ve `writeDataToPeripheral` hiç çağrılmaz. Ek güvence: transmitter'da `writeDataToPeripheral` override edilip log'a "BLOCKED WRITE" yazar ve hiçbir şey göndermez *(builder doğru override noktasını seçer)*.
- **Bağlantı kuralı:** iOS'ta `cancelPeripheralConnection` yalnız xDrip'in kendi bağlantı talebini bırakır; resmi uygulama bağlıyken fiziksel bağlantı düşmez. Bu yüzden taban sınıfın `disconnect()` çağrıları (watchdog, ayarlardan devre dışı bırakma/silme vb.) **serbesttir**; yasak olan, resmi uygulamanın oturumunu etkileyecek her türlü yazmadır. `prepareForRelease` ve `disconnect` öncesinde `FF31` aboneliği `setNotifyValue(false)` ile bırakılır (taban sınıfta yok, yeni kod).
- Watchdog (Medtrum'dan farklı, yeni kod): canlı kayıt dakikada bir gelir. **5 dakika** geçerli glikoz paketi gelmezse abonelik `setNotifyValue(false)` → `setNotifyValue(true)` ile yenilenir; **15 dakikada** xDrip kendi bağlantı talebini bırakır (`disconnect()`) ve geri çekilmeli `retrieveConnected` denemesine döner.

### 6.3 Paket işleme

Her bildirim için:
1. Ham hex log'a yazılır.
2. **Eski firmware denemesi:** `AA 55 09` ile başlıyor ve toplam-checksum tutuyorsa şifresiz eski format olarak işlenir (`process.cpp`): 14 baytlık kayıtlar, alanlar **big-endian**: index, sıcaklık×10, elektrik, değer×10, durum, alınmamış sayısı, eklenme süresi.
3. Değilse RC4 ile çözülür. Anahtar `01 38 0B 9A 00 5B 02 5D CD 9E C3 99 09 37 AA E8`, skip 0, her paket için anahtar akışı baştan başlar. İstisna: 5 baytlık `04 00 00 00 FC` şifresiz kabul edilir (`interpret_data.cpp`).
4. Çözülmüş paket doğrulanır: `[0]` uzunluk N, `[1]` cmd, `[2]` status, `[N]` checksum = −(bayt 0..N−1 toplamı) mod 256. 5 baytlık ACK paketleri ayrı doğrulanır.
5. Sınıflandırma (`interpret_data.cpp` cmd tablosu):
   - **cmd `0x08`, uzunluk > 4: glikoz kayıtları.** `status` = kayıt sayısı. Başlık `{uint16 index, uint32 itime}`, sonra kayıt başına `{uint16 temp, uint16 dump, uint16 current, uint16 extra}`, sonda `{uint16 reindex}`. Little-endian. Kayıtlar 60 sn arayla.
   - **ACK'lar** (uzunluk 4): hangi cmd'ye ait oldukları ve status log'a yazılır. Resmi uygulamanın hangi komutları gönderdiği bu yanıtlardan dolaylı olarak görülür.
   - **cmd `0x3E`, `0x40`, `0x41`, `0x42`, `0x66`, `0xF2`, `0x17`, `0x18`, `0xF0`:** anlamı tam bilinmeyen veri paketleri. Juggluco yorumlarına göre `0x3E` "three_glouse_info", `0x42` "glouse_ble_info" (kayıt başına 24 bayt), `0x66` "tang_glouse_info" (44 bayt): sensörün kendi hesapladığı bir glikoz alanı içerebilir. **Ayrıştırılmaz, çözülmüş hex'i tam olarak ve "UNKNOWN-DATA" etiketiyle log'a yazılır.** Analiz sonraki aşamada yapılır.
   - Çözülmüş paket doğrulanamazsa, Juggluco `processData2` gibi **şifresiz hâli de** aynı doğrulamadan geçirilir.
   - İkisi de tutmazsa: hem ham hem çözülmüş hex "INVALID" etiketiyle log'a yazılır.

### 6.4 Glikoz kayıtları ve kalibrasyon

- Ham değer: `current / 10` mmol/L → mg/dL (`× 18.0182`). Juggluco, GS1BridgePrototype ("sensor glucose figure × 10", ayrı bir "electrical raw value" alanından farklı) ve sibionics_cgm_ha bu alanı mmol/L ölçeğinde ham glikoz olarak ele alıyor; yani nA cinsinden bir akım değil. Geçerli aralık 1.8–30 mmol/L; dışındakiler xDrip'e verilmez ama **SIBCMP satırına yine yazılır** (kanıt kaybolmasın).
- `GlucoseData(timeStamp:, glucoseLevelRaw:)` üretilir, **`glucoseLevelRaw = mg/dL × 1000`** (tüm kalibratörlerde `rawValueDivider = 1000`).
- Kalibratör **Libre1Calibrator**; `getCalibrator`'daki yeni case her zaman bunu döndürür, WebOOP ayarına bakmaz. `canWebOOP() = false`, `canUseNonFixedSlope() = false`, `isWebOOPEnabled() = false`, `isNonFixedSlopeEnabled() = false` *(tasarım kararı: ölçek Libre ile aynı, eğim ≈ 1 bekleniyor; WebOOP yolu açılırsa ham değer `NoCalibrator` ile gösterilirdi)*.
- Kalibrasyondan önce `calculatedValue = 0` kalır; HealthKit, alarmlar ve ekran etiketleri bunu zaten atlar (kontrol edildi). İlk kalibrasyondan sonra `adjustRecentBgReadings` önceki okumaları geriye doğru doldurur; bu beklenen xDrip davranışıdır.
- **Yeni sensör:** indeks geriye gidip yeni oturum kabul edildiğinde `canDetectNewSensor() = true` ile `newSensorDetected` bildirilir. Bu, eski sensörü durdurur ve yeni kalibrasyon ister *(tasarım kararı: eski kalibrasyonun yeni sensöre taşınması sessizce yanlış değer üretir)*.
- Zaman: `itime` Unix saniyesi; gelecekteki zaman şimdiye kırpılır. Eski formatta zaman, alım anı + eklenme süresi − alınmamış × 60 ile hesaplanır (`process.cpp`).
- Tekilleştirme: son işlenen sensör indeksi Core Data'da (`lastReceivedIndex`) tutulur; delegate'e yalnız daha yüksek indeksli kayıtlar gider. Resmi uygulama geçmiş istediğinde gelen eski kayıtlar log'a yazılır ama tekrar işlenmez. İlk bağlantıda en fazla 6 saat geriye gidilir.
- İndeks geriye giderse (yeni sensör ya da sıfırlama): kayıt zamanı son okumadan yeniyse yeni oturum kabul edilir ve `lastReceivedIndex` sıfırlanır; değilse kayıt atlanır *(Juggluco `setSiAdd2Index` mantığının pasif karşılığı)*.
- Sensör başlangıcı: `itime − index × 60` (`makestarttime`). Maksimum yaş 14 gün. Isınma 60 dk varsayılan *(doğrulanmadı)*.
- Trend: xDrip'in kendi eğim hesabı.

### 6.5 Güvenlik kapıları

- Peripheral başlığı: **"Sibionics GS1 (Deneysel, resmi uygulamayla)"**.
- Kalibrasyon yapılana kadar okuma gösterilmez (ham-değer kalibratörlerinin mevcut davranışı; builder doğrular).
- `osAidSharingPolicy = .blocked` (Medtrum Nano gibi). Bu aşamada açık onayla bile açılmaz.
- **Nightscout yüklemesi ve Apple Health yazımı bu aşamada bu sensör tipi için tamamen kapalı** *(tasarım kararı)*. Bugün iki yöneticide de transmitter tipine göre bir kapı yok; `UserDefaults.cgmTransmitterType` üzerinden yeni bir kontrol eklenir. Gerekçe: deneysel değerlerin başka sistemlere (ör. Nightscout'u okuyan başka bir AID'e) sızmaması.
- **xDrip'in glikoz değerine dayalı alarmları bu sensör tipi için bu aşamada kapalı** *(tasarım kararı)*: güvenilirliği kanıtlanmamış değerlerle çalışmazlar, bu alarm görevi resmi uygulamada kalır. Kapalı olanlar: `verylow`, `low`, `high`, `veryhigh`, `fastdrop`, `fastrise`. Geri kalan her şey açık kalır, `notlooping`, `missedreading` (resmi uygulamanın bağlantısının düştüğünü fark ettirir) ve `calibration` (kalibrasyon isteği) dahil.
- Kaynak değişince birikmiş verinin sızmaması: bu tip etkinken (master) dışa aktarma imleçleri (OS-AID, Nightscout, HealthKit, Dexcom Share) dışa aktarmaya izin veren bir kaynağa (başka tip, tip yok, follower) geçişte ve her engellenen dışa aktarma denemesinde "şimdi"ye ilerletilir; OS-AID paylaşımının 30 dakikalık geri bakışı bu ana kadar inmez.
- İlk eklemede bir kerelik uyarı: "Bu deneysel bir özelliktir. Değerler parmak ucu ile kalibre edilir ve resmi uygulamadan sapabilir. Tedavi kararlarınızı resmi uygulamaya göre verin. Resmi Sibionics uygulamasını kapatmayın."

### 6.6 Tanılama ve log

- Yeni trace kategorisi `categoryCGMSibionicsGS1`. Kanıt (ham paketler, kayıtlar, `SIBCMP`/`SIBCAL` satırları, bağlantı olayları) **trace dosyasındadır**; müşterinin gördüğü `TroubleshootingLog` (Etkinlik Günlüğü) yalnız genel girdileri taşır (ör. CGM bağlandı/koptu, kabul edilen glikoz).
- Log'a yazılanlar: `retrieveConnected` sonuçları, servis ve karakteristik keşfi, `180A` ve batarya değerleri, her bildirimin ham ve çözülmüş hex'i, sınıflandırma sonucu, glikoz kayıtları (index, itime, temp, current, mmol/L, dump, extra, reindex), watchdog ve yeniden bağlanma olayları, engellenen yazma denemeleri.
- **Karşılaştırma için:** her işlenen kayıt için tek satırlık sabit biçimli bir log satırı (`SIBCMP;<unix ms>;<index>;<raw mmol>;<temp>;<calibrated mg/dL or ->`), böylece müşterinin resmi uygulamadan gönderdiği ekran görüntüleri veya dışa aktarmaları ile sonradan zamana göre eşleştirilebilir. Transmitter katmanında kalibre değer henüz yoktur (`-`); kalibratör okumayı oluşturduktan sonra ayrıca `SIBCAL;<unix ms>;<calculatedValue mg/dL>;<raw mg/dL>` yazılır, iki satır zaman damgasıyla eşleşir.
- Ek triage satırları: `LINK-OWNER official|xdrip` (bağlantıyı kim kurdu), her `retrieveConnected` denemesinde bağlı tüm `FF30` cihazlarının sayısı ve ad/kimlikleri, `LAYOUT-MISMATCH` (kayıt düzeninden sonra fazladan bayt), `UNLISTED-CMD` (geçerli çerçeve, bilinmeyen komut), `CLOCK-MISMATCH` (sensör saati ile telefon saati arasında 1 günden fazla fark).
- Peripheral detay ekranında salt okunur satırlar: Bağlantı durumu, Firmware tipi (Eski/V120), Batarya, Son indeks, Son ham değer (kalibre edilmemiş), Son paket zamanı, Bilinmeyen paket sayısı.

### 6.7 Test

- `SibionicsGS1ProtocolTests`: RC4 bilinen vektörle; checksum doğrulama; ACK doğrulama; sentetik glikoz kaydı → şifrele → ayrıştır; eski format paket ayrıştırma (big-endian); `04 00 00 00 FC` istisnası; bilinmeyen cmd'lerin "unknown" sınıflandırması; geçersiz uzunluk ve checksum'ların reddi.
- Yeni sensör tespiti testi (indeks geri gidip zaman ilerlediğinde `newSensorDetected`).
- Alarm, Nightscout ve HealthKit kapılarının bu tip için kapalı olduğunu doğrulayan testler.
- Yazma yasağı testi: transmitter'ın hiçbir akışta `FF32`'ye yazmadığını doğrulayan bir test *(builder uygun bir sahte/izleme noktası seçer)*.
- Gerçek cihaz testi TestFlight + müşteri. Builder, müşteriye gidecek kısa Türkçe test talimatı yazar (`docs/superpowers/specs/2026-11-26-sibionics-gs1-test-talimati.md`): kurulum; resmi uygulamanın açık kalması; xDrip'te sensör ekleme; ilk kalibrasyon; günde 2–3 kez resmi uygulama ekranının ekran görüntüsü; log gönderme.

## 7. Kullanıcının verdiği kararlar

- Önce yalnız Sibionics GS1; diğer Juggluco sensörleri sonra.
- Test TestFlight üzerinden müşteriyle; sensör ekipte yok.
- Müşteriden MAC adresi alınamıyor.
- Kullanım amacı yama pompa ile Loop; bu yüzden bulut takipçisi elendi.
- Kapalı algoritma portu hukuki değerlendirme olmadan kullanılmayacak.
- **Pasif dinleme yaklaşımı seçildi**, Loop bu aşamada kapalı.

## 8. Builder'a bırakılanlar

- Medtrum şablonundaki her dokunma noktasının Sibionics karşılığı ve isimlendirme.
- Zaman aşımı ve geri çekilme sürelerinin ince ayarı.
- UI metinlerinin yerelleştirme anahtarları (`Texts_*` düzeni).
- Juggluco atıf başlığı biçimi (GPL-3.0 uyumlu).

## 9. Bu aşamanın çıktısı ve sonraki karar

İlk test turundan sonra cevaplanacak sorular:
1. iOS'ta pasif dinleme çalışıyor mu (resmi uygulama bağlıyken `FF31` bildirimleri xDrip'e geliyor mu)?
2. Sensör hangi firmware'i kullanıyor (eski `AA 55` / V120)?
3. Bilinmeyen paket tiplerinden (`0x3E`, `0x42`, `0x66` vb.) gelen var mı, içlerinde resmi uygulamanın gösterdiği değerle örtüşen bir alan var mı?
4. Ham değer + kalibrasyonun resmi uygulamadan sapması ne kadar (sabit dönem ve yükselişler ayrı ayrı)?

Olası sonuçlar:
- Paketlerde hesaplanmış glikoz bulunursa: o alan kullanılır, kalibrasyon gerekmez; Loop paylaşımı açık onayla değerlendirilir.
- Bulunmazsa ve sapma kabul edilebilirse: açık onayla Loop paylaşımı ayrı bir tasarımla değerlendirilir.
- Bulunmazsa ve sapma yüksekse: algoritma portu (hukuki onayla) ya da Loop'ta desteklenen bir sensör.
- Pasif dinleme çalışmazsa: doğrudan Bluetooth tasarımına (MAC'li) geri dönülür.

## 10. Müşteriden alınacak bilgiler

- Kullandığı resmi Sibionics uygulamasının adı (App Store'daki tam adı). EU varyantı için beklenen: `SIBIONICS` (Android paket adı `com.sisensing.sijoy`).
- Sensörün tek parça mı, ayrı yeniden kullanılabilir vericili mi olduğu.
MAC adresi ve QR kodu bu aşamada **gerekmez**.
