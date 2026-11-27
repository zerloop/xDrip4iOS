# Instara G1 (Perlanova) Pasif Dinleme — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resmi Instara uygulamasının Bluetooth bağlantısını pasif dinleyen, sensörün fabrika kalibrasyonlu glikozunu gösteren ve kullanıcı bir anahtarla doğrulayana kadar Loop, Nightscout, Health, Dexcom Share ve değer alarmlarını kapalı tutan bir CGM tipi eklemek.

**Architecture:** Saf protokol katmanı (`InstaraG1Protocol`: çerçeve, CRC-8/MAXIM, parça birleştirme) ve oturum katmanı (`InstaraG1Session`: aralık, zaman, tekrar ayıklama, kırpma, iki paketle yeni sensör). Bunların üzerine Sibionics GS1'in pasif bağlantı mantığını kendi dosyasında yeniden kuran bir transmitter (`CGMInstaraG1Transmitter`). `CGMTransmitterType.instaraG1`'in üç politika özelliği (`allowsGlucoseExport`, `allowsGlucoseAlarms`, `osAidSharingPolicy`) sabit değil, `UserDefaults.instaraG1ExportVerified` anahtarını okur.

**Tech Stack:** Swift 5, CoreBluetooth, Core Data (model v39), XCTest (`xdripTests`), `xdrip.xcworkspace`, scheme `xdrip`.

**Spec:** `docs/superpowers/specs/2026-11-27-instara-g1-design.md`

## Global Constraints

- Sensöre **hiçbir yazma** yapılmaz. Üç `writeDataToPeripheral` overload'u engellenir, `false` döner ve "BLOCKED WRITE" log'lanır. Yalnızca bildirime abone olunur.
- Servis `8653000A-43E6-47B7-9CB0-5FC21D4AE340`, bildirim `8653000B-43E6-47B7-9CB0-5FC21D4AE340`, yazma (tanınır, kullanılmaz) `8653000C-43E6-47B7-9CB0-5FC21D4AE340`.
- Çerçeve `55 AA | cmd | len | payload[len] | crc8`. CRC-8/MAXIM: init 0, yansıtılmış polinom 0x8C, CRC'den önceki tüm baytlar. Kontrol değeri: `"123456789"` → `0xA1`.
- Glikoz: u16 BE ÷ 10 = mmol/L; mg/dL = mmol × `ConstantsBloodGlucose.mmollToMgdl`.
- Aralık dışı: 0 → at; 0 < x < 2.0 mmol → 36 mg/dL; 26.0 < x ≤ 40.0 → 468 mg/dL; x > 40.0 → at. Her biri OUT-OF-RANGE log'lanır.
- Okuma aralığı: `0x0A` (1–15 dk) > ölçülen (son 6 çiftin `Δt/Δseq` medyanı, tam dakikaya yuvarlanmış) > 5 dk. Ölçülen ile `0x0A` çelişirse ölçülen kullanılır ve INTERVAL-MISMATCH log'lanır.
- Kalibratör `NoCalibrator`. `BgPostProcessingManager`'daki Sibionics istisnası Instara'ya uygulanmaz.
- Anahtar kapalıyken: `osAidSharingPolicy == .blocked`, `allowsGlucoseExport == false`, `allowsGlucoseAlarms == false` (değer alarmları: `verylow, low, high, veryhigh, fastdrop, fastrise`). Açıkken üçü de normal (`.allowed`, `true`, `true`).
- Anahtar kapalıdan açığa geçince `UserDefaults.standard.advanceGlucoseExportCursors(to: Date())` çağrılır.
- Sensör ömrü 21 gün, ısınma 15 dk, Loop beklenen aralığı = ölçülen okuma aralığı (varsayılan 300 sn).
- **Plan kararı (spec'te sayı yok):** gözetleyici süreleri 900 sn (aboneliği yenile) ve 1800 sn (bağlantıyı bırak). Bunlar 5 dakikalık aralık için Sibionics'in 300/900 değerlerinin üç ve iki katı; üç okuma kaçırılmadan müdahale edilmez.
- Raw değerler (kalıcı): `BluetoothPeripheralType.InstaraG1Type = "Instara G1"`, `CGMTransmitterType.instaraG1 = "Instara G1"`, `CGMSensorType.Instara = "Instara"`. Peripheral başlığı: `Instara-1 / Perlanova (Deneysel, resmi uygulamayla)`. LoopManager tanımlayıcısı `"instara_g1"`.
- Log kategorisi `ConstantsLog.categoryCGMInstaraG1 = "CGMInstaraG1"`.
- UserDefaults anahtar öneki `instaraG1.` (oturum durumu). Bu önek ve `instaraG1ExportVerified`, `instaraG1VerifiedSensorStart`, `instaraG1ExperimentalWarningAcknowledged` yedeğe alınmaz (BackupService'te Sibionics'in yanına).
- Kaynak atfı (Swift dosyalarının başında, kod kopyalanmaz): `Protocol facts from JugglucoNG PR #1011 (https://github.com/ctqvva/JugglucoNG/pull/1011), GPL-3.0. Independent Swift implementation.`
- Sibionics GS1 dosyalarına ve davranışına dokunulmaz. Mevcut `Sibionics*` testleri değişmeden geçmeli.
- Metinler Türkçe, `tr.lproj`'a da eklenir. `en.lproj`'a eklenmez.
- Test komutu (tek sınıf): `xcodebuild test -workspace xdrip.xcworkspace -scheme xdrip -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:xdripTests/<TestClass>`. Beklenen çıktı: `** TEST SUCCEEDED **`.
- Derleme komutu: `xcodebuild build -workspace xdrip.xcworkspace -scheme xdrip -destination 'platform=iOS Simulator,name=iPhone 18 Pro'`. Beklenen çıktı: `** BUILD SUCCEEDED **`.
- Bilinen, Sibionics'ten önce de başarısız olan testler (değerlendirmede yok sayılır): BatteryHistory ×2, CareLink ×2, DexcomG6SensorLabel ×4, DexcomG7Calibration, FollowerSettings, GlucoseAdjustment.testRepeatedApply, GlucoseRangeDistribution ×2, TroubleshootingLog.

## Review Focus

1. **Uygulama yeniden başladıktan sonra başka bir sensörün onayı geçerli sayılmamalı.** Onay, sensör başlangıcına bağlıdır; uyuşmazsa anahtar kapanır. Test: Task 6 `testVerificationForOtherSensorIsRevokedOnRestore`.
2. **Anahtar açılınca kapalıyken biriken okumalar dışarı gitmemeli.** Test: Task 6 `testEnablingAdvancesExportCursorsSoBacklogIsNotExported`.
3. **Ciddi bir düşük kaybolmamalı.** 1.9 mmol/L 36 mg/dL olarak görünür; anahtar açıkken `verylow` izinlidir. Test: Task 3 `testLowBelowRangeIsClampedTo36`; Task 6 `testVeryLowAllowedWhenVerified`.
4. **Tek bir hatalı paket yeni oturum açıp anahtarı kapatmamalı.** Test: Task 3 `testSingleLowerSequenceDoesNotStartNewSession`.
5. **Resmi uygulama yokken sıkı bir bağlan-kop döngüsü olmamalı, ekranda açık bir durum mesajı görünmeli.** Test: Task 4 `testNoConnectedPeripheralSchedulesBackoffNotTightLoop`.

---

### Task 1: Protokol katmanı

**Files:**
- Create: `xDrip/BluetoothTransmitter/CGM/Instara/G1/InstaraG1Protocol.swift`
- Create: `xDrip/Constants/ConstantsInstaraG1.swift`
- Test: `xDrip Tests/InstaraG1ProtocolTests.swift`
- Modify: `xdrip.xcodeproj/project.pbxproj` (dosyalar `xdrip` ve `xdripTests` hedeflerine)

**Interfaces:**
- Produces:
  - `enum ConstantsInstaraG1`: `serviceUUID`, `notifyCharacteristicUUID`, `writeCharacteristicUUID`, `minValidMmol = 2.0`, `maxValidMmol = 26.0`, `maxPlausibleMmol = 40.0`, `clampLowMgDl = 36.0`, `clampHighMgDl = 468.0`, `defaultIntervalMinutes = 5`, `validIntervalRange = 1...15`, `intervalSampleCount = 6`, `sensorLifeDays = 21.0`, `warmupMinutes = 15.0`, `newSensorSeqDrop = 12`, `minPlausibleStepSeconds: TimeInterval = 30`, `maxPlausibleStepSeconds: TimeInterval = 1800`, `sensorStartTolerance: TimeInterval = 1800`, `fragmentTimeout: TimeInterval = 2`, `resubscribeAfterSeconds = 900`, `releaseAfterSeconds = 1800`, `reconnectDelays: [TimeInterval] = [5, 10, 15]`. Watchdog süreleri, 5 dakikalık aralık için Sibionics'in 300/900 değerlerinin üç ve iki katı.
  - *Yürütme sırasında değişti:* ilk listedeki `newSensorStartShift` (1800) ve `newSensorConfirmWindow` (600) kaldırıldı (başlangıç kayması kuralı yerine adım kuralı, Task 3). `minPlausibleStepSeconds`, `maxPlausibleStepSeconds` (Task 3) ve tek ortak 30 dakikalık tolerans `sensorStartTolerance` (oturum başlangıcı düzeltmesi, transmitter'daki sensör uyuşmazlığı ve doğrulamanın aktif sensöre bağlılığı; final inceleme) eklendi.
  - `enum InstaraG1Packet: Equatable`:
    - `case realtime(seq: Int, mmol: Double)`
    - `case historyHeader(frameCount: Int)`
    - `case history(startSeq: Int, durationField: Int, mmolValues: [Double])`
    - `case battery(percent: Int)`
    - `case handshake(hardware: Int, software: Int)`
    - `case interval(minutes: Int)`
    - `case unlisted(cmd: UInt8, payload: Data)`
    - `case invalid(reason: String, raw: Data)`; `reason` şu değerlerden biridir: `"HEADER"`, `"CRC-FAIL"`, `"LAYOUT-MISMATCH"` (uzunluk ya da komut başına en az payload tutmuyor), `"FRAGMENT-TIMEOUT"`.
  - `struct InstaraG1FrameAssembler` with `mutating func feed(_ data: Data, now: Date) -> [InstaraG1Packet]`. Bir bildirimdeki birden çok çerçeveyi, iki bildirime bölünmüş çerçeveyi ve `fragmentTimeout` sonrası atılan parçayı ele alır.
  - `enum InstaraG1Protocol`:
    - `static func crc8(_ bytes: Data) -> UInt8`
    - `static func parse(frame: Data) -> InstaraG1Packet` (tam ve tek çerçeve)
    - `static func logLine(_ packet: InstaraG1Packet) -> String` (`INSTARA-PKT;cmd=…;…` biçimi; `invalid` ve `unlisted` için ham hex)

- [ ] **Step 1: Testleri yaz**

```swift
final class InstaraG1ProtocolTests: XCTestCase {
    func hex(_ s: String) -> Data { /* hex → Data yardımcı */ }
    let t0 = Date(timeIntervalSince1970: 1_795_100_000)

    func testCrc8MaximCheckValue() { XCTAssertEqual(InstaraG1Protocol.crc8(Data("123456789".utf8)), 0xA1) }
    func testRealtime0x10() { XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa10040120004863")), .realtime(seq: 288, mmol: 7.2)) }
    func testRealtime0x01() { XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa01040121004b46")), .realtime(seq: 289, mmol: 7.5)) }
    func testHistoryFrame() {
        XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa3008011e00050046004734")), .history(startSeq: 286, durationField: 5, mmolValues: [7.0, 7.1]))
    }
    func testBatteryHandshakeInterval() {
        XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa20015541")), .battery(percent: 85))
        XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aaf0021234d7")), .handshake(hardware: 0x12, software: 0x34))
        XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa0a02000520")), .interval(minutes: 5))
    }
    func testUnlistedKeepsPayload() { XCTAssertEqual(InstaraG1Protocol.parse(frame: hex("55aa600101ca")), .unlisted(cmd: 0x60, payload: hex("01"))) }
    func testBadCrcHeaderAndLengthAreInvalid() {
        for f in ["55aa10040120004800", "56aa10040120004863", "55aa100501200048", "55aa"] {
            guard case .invalid = InstaraG1Protocol.parse(frame: hex(f)) else { return XCTFail(f) }
        }
    }
    func testHistoryWithOddValueBytesIsInvalid() {
        guard case .invalid = InstaraG1Protocol.parse(frame: hex("55aa3007011e000500460074")) else { return XCTFail() }
    }
    func testAssemblerTwoFramesInOneNotification() {
        var a = InstaraG1FrameAssembler()
        XCTAssertEqual(a.feed(hex("55aa10040120004863" + "55aa20015541"), now: t0), [.realtime(seq: 288, mmol: 7.2), .battery(percent: 85)])
    }
    func testAssemblerFrameSplitAcrossNotifications() {
        var a = InstaraG1FrameAssembler()
        XCTAssertEqual(a.feed(hex("55aa100401"), now: t0), [])
        XCTAssertEqual(a.feed(hex("20004863"), now: t0.addingTimeInterval(0.5)), [.realtime(seq: 288, mmol: 7.2)])
    }
    func testAssemblerDropsStaleFragment() {
        var a = InstaraG1FrameAssembler()
        _ = a.feed(hex("55aa100401"), now: t0)
        XCTAssertEqual(a.feed(hex("55aa20015541"), now: t0.addingTimeInterval(3)), [.battery(percent: 85)])
    }
    func testAssemblerSkipsGarbageBeforeHeader() {
        var a = InstaraG1FrameAssembler()
        XCTAssertEqual(a.feed(hex("0102" + "55aa20015541"), now: t0), [.battery(percent: 85)])
    }
}
```

- [ ] **Step 2: FAIL gör.** `<TestClass>` = `InstaraG1ProtocolTests`; derleme hatası beklenir.
- [ ] **Step 3: Uygula.** `parse` önce başlığı, `len == count − 5` eşitliğini ve CRC'yi doğrular. Sonra her komut için en az payload uzunluğunu kontrol eder: realtime 4, history 6 ve değer baytları çift, battery 1, handshake 2, interval 2, `0x03` 1. Eksikse `.invalid` döner. `0x02`/`0x20` → battery; `0x01`/`0x10` → realtime; `0x0A` → interval. Diğer her şey `.unlisted`. Assembler `55 AA` arar, öncesindeki baytları atar, `len` gelene kadar bekler. `fragmentTimeout`'tan eski bir tampon, yeni veri gelince atılır. Hiçbir indeksleme sınır kontrolü olmadan yapılmaz.
- [ ] **Step 4: PASS gör.**
- [ ] **Step 5: Commit.** `feat(instara): add G1 frame decoder and assembler`

---

### Task 2: Tip, dinamik politika, veri modeli v39

**Files:**
- Modify: `xDrip/BluetoothTransmitter/CGM/Generic/CGMTransmitter.swift` (`CGMTransmitterType.instaraG1` ve bütün switch'ler; `allowsGlucoseExport`, `allowsGlucoseAlarms`, `osAidSharingPolicy` anahtarı okur)
- Modify: `xDrip/BluetoothTransmitter/CGM/Generic/CGMSensorType.swift`, `xDrip/BluetoothPeripheral/Generic/BluetoothPeripheralType.swift`
- Create: `xDrip/Core Data/xdrip.xcdatamodeld/xdrip v39.xcdatamodel/contents` (v38'in kopyası, artı `InstaraG1` entity'si ve `BLEPeripheral.instaraG1` ilişkisi); `.xccurrentversion` → v39
- Create: `xDrip/Core Data/classes/InstaraG1+CoreDataClass.swift`, `InstaraG1+CoreDataProperties.swift`; Modify: `BLEPeripheral+CoreDataProperties.swift`
- Create: `xDrip/BluetoothPeripheral/CGM/Instara/G1/InstaraG1+BluetoothPeripheral.swift`
- Modify: `xDrip/Extensions/UserDefaults.swift`
- Modify: `xDrip/Utilities/Backup/BackupService.swift` (`excludedSettingKeys` ve önek kontrolü)
- Test: `xDrip Tests/InstaraG1TypePolicyTests.swift`

**Interfaces:**
- Produces:
  - `CGMTransmitterType.instaraG1`:
    - `sensorType() == .Instara`
    - `canDetectNewSensor() == true`
    - `allowManualSensorStart() == false`
    - `detailedDescription() == "Instara G1 (experimental, passive)"`
  - `UserDefaults.instaraG1ExportVerified: Bool`
    - `@objc dynamic`, KVO ile gözlenebilir.
    - Anahtar `Key.instaraG1ExportVerified = "instaraG1ExportVerified"`.
  - `UserDefaults.instaraG1VerifiedSensorStart: Date?` (anahtar `instaraG1VerifiedSensorStart`).
  - `UserDefaults.instaraG1ExperimentalWarningAcknowledged: Bool`.
  - `UserDefaults.setInstaraG1Verified(_ on: Bool, sensorStart: Date?, reason: String)`:
    - Tek giriş noktası.
    - Kapalıdan açığa geçişte `advanceGlucoseExportCursors(to: Date())` çağırır.
    - Her değişimi `INSTARA-VERIFY on|off reason=… sensorStart=…` olarak trace'e yazar.
    - Kapatırken `instaraG1VerifiedSensorStart`'ı `nil` yapar.
  - `BluetoothPeripheralType.InstaraG1Type`:
    - `category() == .CGM`
    - `needsTransmitterId() == false`
    - `canWebOOP() == false`
    - `canUseNonFixedSlope() == false`
    - `needsNFCScanToConnect() == false`
    - `usesIntermittentConnection == false`
    - başlık: Global Constraints'teki gibi
  - `class InstaraG1: NSManagedObject`:
    - `init(address:name:alias:nsManagedObjectContext:)`
    - `blePeripheral: BLEPeripheral`
    - `firmware: String?` (handshake hw/sw)
    - `BLEPeripheral.instaraG1: InstaraG1?`

- [ ] **Step 1: Testleri yaz.** `setUp` ve `tearDown`'da ilgili anahtarlar saklanıp geri yüklenir.
  - `testUnverifiedIsBlocked`: anahtar `false` iken `.instaraG1` için `osAidSharingPolicy == .blocked`, `allowsGlucoseExport == false`, `allowsGlucoseAlarms == false`.
  - `testVerifiedIsAllowed`: `true` iken `.allowed`, `true`, `true`.
  - `testSibionicsUnaffectedByInstaraToggle`: anahtar `true` iken `.sibionicsGS1` hâlâ `.blocked`, `false`, `false`.
  - `testEnablingAdvancesExportCursors`: Nightscout, HealthKit, Dexcom Share ve Loop imleçleri ile `glucoseExportFloorTimeStamp` `Date.distantPast` iken `setInstaraG1Verified(true, …)` çağrılır. Hepsi `≥` çağrı anı olmalı. Açık → açık tekrar çağrısı imleçleri ilerletmez (anlar sabit bir tarihle karşılaştırılır).
  - `testDisablingClearsSensorBinding`
  - `testInstaraKeysExcludedFromBackup`: BackupService'in yedeklenecek anahtar listesi `instaraG1ExportVerified`, `instaraG1VerifiedSensorStart` ve `instaraG1.` önekli bir anahtar içermez.
  - `testRawValuesAreStable`
  - `testPeripheralTypeFlags`
- [ ] **Step 2: FAIL gör** (`InstaraG1TypePolicyTests`).
- [ ] **Step 3: Uygula.** Derleyicinin gösterdiği her eksik switch dalı Sibionics karşılığına bakarak doldurulur. Farklar yalnızca Interfaces'te. Model v39 hafif migration ile gelir.
- [ ] **Step 4: Testi ve tam derlemeyi çalıştır.**
- [ ] **Step 5: Commit.** `feat(instara): add G1 type, verification-driven policy and data model v39`

---

### Task 3: Oturum katmanı

**Files:**
- Create: `xDrip/BluetoothTransmitter/CGM/Instara/G1/InstaraG1Session.swift`
- Test: `xDrip Tests/InstaraG1SessionTests.swift`

**Interfaces:**
- Consumes: `InstaraG1Packet`, `ConstantsInstaraG1` (Task 1).
- Produces:
  - `struct InstaraG1Reading: Equatable { let seq: Int; let timeStamp: Date; let rawMmol: Double; let mgDl: Double; let clamped: Bool }`
  - `struct InstaraG1SessionState: Codable, Equatable`:
    - `var lastSeq: Int?` / `var refSeq: Int?` / `var refDate: Date?`
    - `var sensorStart: Date?`
    - `var intervalFromSensor: Int?`
    - `var intervalSamples: [Double]`
    - `var seenSeqs: [Int: Date]` (seq → üretilen zaman; son 21 güne sınırlı)
    - `var suspect: InstaraG1Suspect?`
  - `struct InstaraG1Suspect: Codable, Equatable { let seq: Int; let at: Date; let derivedStart: Date? }`
  - `struct InstaraG1SessionResult { let readings: [InstaraG1Reading]; let newSensorStart: Date?; let log: [String] }`
  - `enum InstaraG1Session`:
    - `static func process(_ packet: InstaraG1Packet, state: inout InstaraG1SessionState, receivedAt: Date) -> InstaraG1SessionResult`
    - `static func intervalMinutes(_ state: InstaraG1SessionState) -> Int`

**Kurallar (spec 6.4):**
- **Değerler:** 0 atılır; 0 < x < 2.0 → 36, clamped; 26 < x ≤ 40 → 468, clamped; x > 40 atılır. Atılanlar ve kırpılanlar `log`'a girer.
- **Realtime:** `timeStamp = receivedAt`. `refSeq`/`refDate` güncellenir. Ardışık iki realtime `Δt/Δseq` örneği ekler (yalnızca `Δseq > 0` ve `Δt > 0` iken). Örnek sayısı en çok `intervalSampleCount`.
- **Aralık:**
  - `interval` paketi geçerliyse `intervalFromSensor` olur.
  - `intervalMinutes` sırası: ölçülen medyan (en az 2 örnek) > `intervalFromSensor` > 5.
  - İkisi de varsa ve farklıysa `log`'a `INTERVAL-MISMATCH` yazılır.
- **History:** `seq = startSeq + i`, `t = refDate − (refSeq − seq) × interval`. `t > receivedAt` ise atılır. Ref yoksa (anlık okuma görülmemişse) history ertelenmez, atılır ve `HISTORY-NO-REF` log'lanır.
- **Tekrar:** `seenSeqs` içindeki seq tekrar üretilmez. Yeni hesaplanan zaman saklanandan 120 sn'den fazla farklıysa `log`'a `CLOCK-MISMATCH` yazılır; saklanan zaman değişmez.
- **Başlangıç:** `sensorStart = refDate − refSeq × interval`; ilk realtime'da (varsayılan 5 dk ile) set edilir.
  - *Yürütme sırasında değişti:* aralık **ilk kez ölçüldüğünde** bir kez yeniden hesaplanır; sonraki aralık değişimleri yalnızca `INTERVAL-CHANGE` log'lar. Bu yeniden hesaplama başlangıcı `sensorStartTolerance`'tan (30 dk) fazla kaydırırsa `newSensorStart` set edilir ve `SENSOR-START-CORRECTED` log'lanır. `SEQ-REANCHOR`'dan sonra `sensorStartLocked` ile kilitlenir.
- **Yeni sensör** (*yürütme sırasında değişti*: ilk taslaktaki başlangıç kayması kuralı ve 10 dk'lık onay penceresi kaldırıldı). Adım = referanstan `Δt / Δseq`.
  - Aday: `seq < lastSeq − 12` ya da ileri adım > `maxPlausibleStepSeconds` (1800 sn/sıra).
  - İlk aday `suspect` olarak saklanır, okuma üretilmez ve `SESSION-SUSPECT` log'lanır.
  - Onay: sonraki realtime da aday, `seq > suspect.seq` ve suspect ile arasındaki adım akla yatkın (30–1800 sn/sıra) ise yeni oturum açılır. `state` sıfırlanır (`intervalFromSensor` korunur), `newSensorStart` set edilir ve iki okuma da üretilir.
  - Sağlamıyorsa `suspect` temizlenir (`SESSION-SUSPECT-CLEARED`) ve paket normal işlenir.
  - İleri adım < `minPlausibleStepSeconds` (30 sn/sıra) asla aday değildir: `jumpCandidate` olarak bekletilir (`SEQ-JUMP`). Sonraki paket referansa göre yine fazla hızlı ama `jumpCandidate`'e göre adımı akla yatkınsa referans yeni numaralandırmaya taşınır (`SEQ-REANCHOR`, yeni oturum yok, iki okuma üretilir); aksi halde `jumpCandidate` atılır (`SEQ-JUMP-CLEARED`).
- **Durumun çözülmesi** (*final inceleme*): `InstaraG1SessionState` hoşgörülü çözülür; eksik ya da okunamayan alanlar yeni bir durumun varsayılanını alır, böylece eski sürümün kaydettiği durum kaybolmaz.

- [ ] **Step 1: Testleri yaz**
  - `testFirstRealtimeSetsStartWithDefaultInterval`: seq 288, t0 → `sensorStart == t0 − 288×300`.
  - `testMeasuredIntervalWinsOverSensorField`: realtime seq 10 @t0, 11 @t0+60, 12 @t0+120 ve `.interval(minutes: 5)` → `intervalMinutes == 1`, log'da `INTERVAL-MISMATCH`.
  - `testSensorIntervalUsedWhenNotMeasured`: yalnızca `.interval(minutes: 3)` → 3.
  - `testHistoryTimestampsFromReference`: realtime seq 288 @t0, ardından history start 286 [7.0, 7.1] → okumalar seq 286 @t0−600, seq 287 @t0−300, mgDl = 7.0×`mmollToMgdl`.
  - `testHistoryWithoutReferenceIsDropped`
  - `testDuplicateSeqIsNotEmittedTwice`: aynı history iki kez gelir.
  - `testClockMismatchIsLoggedNotApplied`: seq 287 @tA üretildikten sonra, referansı 10 dk kaymış bir history aynı seq'i getirir → okuma yok, log'da `CLOCK-MISMATCH`.
  - `testLowBelowRangeIsClampedTo36`: 1.9 → mgDl 36, `clamped == true`.
  - `testHighAboveRangeIsClampedTo468`: 27.0 → 468.
  - `testZeroAndAbsurdAreDropped`: 0 ve 50.1 → okuma yok, log'da `OUT-OF-RANGE`.
  - `testSingleLowerSequenceDoesNotStartNewSession`: lastSeq 500; seq 3 gelir → okuma yok, `newSensorStart == nil`; ardından seq 501 → normal okuma, suspect temiz.
  - `testTwoConsistentLowerSequencesStartNewSession`: lastSeq 500; seq 3 @t, seq 4 @t+300 → ikincide `newSensorStart` set, iki okuma üretilir.
  - `testStartShiftNeedsMeasuredInterval`: aralık ölçülmemişken başlangıç kayması aday üretmez. (*Yürütme sırasında değişti:* kural kaldırıldığı için yerine adım kuralı testleri geldi, ör. `testImplausibleForwardJumpIsSuspect`, `testBurstOfFastPacketsDoesNotStartNewSession`, `testRealSeqJumpReanchorsWithoutNewSession`.)
- [ ] **Step 2: FAIL gör** (`InstaraG1SessionTests`).
- [ ] **Step 3: `InstaraG1Session` uygula.**
- [ ] **Step 4: PASS gör.**
- [ ] **Step 5: Commit.** `feat(instara): add G1 session timing, clamping and confirmed new-sensor detection`

---

### Task 4: Pasif transmitter

**Files:**
- Create: `xDrip/BluetoothTransmitter/CGM/Instara/G1/CGMInstaraG1Transmitter.swift`
- Modify: `xDrip/Constants/ConstantsLog.swift` (`categoryCGMInstaraG1`)
- Test: `xDrip Tests/CGMInstaraG1TransmitterTests.swift`

**Interfaces:**
- Consumes: Task 1, 2 ve 3.
- Produces: `class CGMInstaraG1Transmitter: BluetoothTransmitter, CGMTransmitter`.
  - Kurucu: `init(address: String?, name: String?, bluetoothTransmitterDelegate:, cGMTransmitterDelegate:)`.
  - Sabit cevaplar: `cgmTransmitterType() == .instaraG1`, `maxSensorAgeInDays() == 21`, `sensorWarmupDurationInMinutes() == 15`; UUID'ler Global Constraints'teki gibi.
  - `private(set) var diagnostics: InstaraG1Diagnostics` alanları: `firmware: String?`, `batteryPercent: Int?`, `lastSeq: Int?`, `lastRawMmol: Double?`, `lastPacketDate: Date?`, `intervalMinutes: Int`, `unlistedPacketCount: Int`, `invalidPacketCount: Int`, `statusMessage: String`.
  - Test seam'leri: `func handleNotification(_ data: Data, now: Date)`, `var retrieveConnectedAttemptCount: Int`.
  - `UserDefaults.instaraG1IntervalMinutes: Int` (anahtar `instaraG1.intervalMinutes`, varsayılan 5). `InstaraG1Session.intervalMinutes` değişince transmitter tarafından yazılır.

**Davranış:** Sibionics transmitter'ı (`CGMSibionicsGS1Transmitter.swift`) satır satır model alınır, ama kod kopyalanmaz, kendi tipleriyle yeniden yazılır. Kapsanacaklar:
- Back-off politika yardımcısı (Instara'ya özgü bir adla) ve `retrieveConnectedPeripheral(withServiceUUIDs: [8653000A])`.
- Tek bekleyen bağlantı, 10 dakikalık bastırma, durum geri yükleme.
- Gözetleyici: `resubscribeAfterSeconds` → `setNotifyValue(false/true)`, `releaseAfterSeconds` → `disconnect()`.
- LINK-OWNER log'u ve servise bağlı cihaz listesi.
- Yazma engeli.

Bildirim akışı:
- `didUpdateValueFor` → `handleNotification` → `InstaraG1FrameAssembler.feed` → her paket `InstaraG1Protocol.logLine` ile trace'e → `InstaraG1Session.process` (durum `instaraG1.sessionState` anahtarında JSON olarak) → okumalar en yeni önce `GlucoseData(timeStamp:glucoseLevelRaw: mgDl)` ile `cgmTransmitterInfoReceived`'a.
- `newSensorStart` gelirse:
  - `cgmTransmitterDelegate?.newSensorDetected(sensorStartDate:)` çağrılır;
  - `UserDefaults.standard.setInstaraG1Verified(false, sensorStart: nil, reason: "new-sensor")` çağrılır.
- **Anahtar ile sensörün uyuşması:** her okuma teslim edilmeden önce kontrol edilir. Anahtar açık, `instaraG1VerifiedSensorStart` dolu ve güncel `sensorStart` ondan 30 dakikadan fazla farklıysa anahtar `reason: "sensor-mismatch"` ile kapatılır.
- Her okuma için trace satırı: `INSTARA-RDG;seq;rawMmol;mgDl;clamped;verified`.

- [ ] **Step 1: Testleri yaz** (UserDefaults anahtarları `setUp`/`tearDown`'da temizlenir)
  - `testWriteIsBlocked`
  - `testTypeAndLimits`
  - `testNoConnectedPeripheralSchedulesBackoffNotTightLoop`: `startScanning()` sonrası `statusMessage` resmi uygulamayı açmayı söyler; 1 sn içinde ikinci deneme yapılmaz.
  - `testRealtimeIsDeliveredOnce`: `55aa10040120004863` iki kez verilir → sahte delegeye 1 `GlucoseData`, `glucoseLevelRaw == 7.2 × mmollToMgdl`.
  - `testNewSensorRevokesVerification`: anahtar açık; lastSeq 500 durumundan seq 3 ve 4 verilir → `newSensorDetected` çağrılır, anahtar `false`.
  - `testSensorMismatchRevokesVerification`: anahtar açık, `instaraG1VerifiedSensorStart` = t0 − 10 gün; seq 288 @t0 gelir (start ≈ t0 − 1 gün) → anahtar `false`.
- [ ] **Step 2: FAIL gör** (`CGMInstaraG1TransmitterTests`).
- [ ] **Step 3: Uygula.**
- [ ] **Step 4: PASS gör.** Ayrıca `SibionicsGS1*` ve `CGMSibionicsGS1TransmitterTests` sınıflarını çalıştırıp hepsinin geçtiğini gör.
- [ ] **Step 5: Commit.** `feat(instara): add passive G1 co-listener transmitter`

---

### Task 5: Uygulama geneline bağlama

**Files:** Sibionics'in dokunduğu her yer. Derleyici eksikleri gösterir; `git log --stat 4d27c96a..3bff1f6b` rehberdir.
- Modify: `xDrip/Managers/BluetoothPeripheral/BluetoothPeripheralManager.swift` ve `+BluetoothTransmitterDelegate.swift` (oluşturma, tip eşleme, `getBluetoothTransmitter`, Core Data getirme; cihaz silinince `setInstaraG1Verified(false, …, reason: "device-removed")`)
- Modify: `RootApplicationCoordinator.swift` `getCalibrator` (`case .instaraG1: calibrator = NoCalibrator()`)
- Modify: `xDrip/Managers/Loop/LoopManager.swift`:
  - tanımlayıcı `"instara_g1"`;
  - `directExpectedInterval(.instaraG1)` = `UserDefaults.standard.instaraG1IntervalMinutes × 60`. Bu değeri transmitter (Task 4) her aralık değişiminde `instaraG1.intervalMinutes` anahtarına yazar; varsayılan 5, yani 300 sn.
- Modify: `AlertKind.swift` (Sibionics'in batarya grubuna; Instara pil yüzdesini yalnızca ekranda gösterir)
- Modify: `TroubleshootingLog.swift`, `Trace.swift`, `OnlineHelp.swift`, `SensorManagementView.swift`, `BluetoothPeripheralsViewModel.swift`, `BluetoothPeripheralDetailState.swift` (diagnostics satırları: Bağlantı durumu, Firmware, Pil, Son sıra no, Son ham değer (mmol/L), Okuma aralığı, Son paket zamanı, Bilinmeyen/geçersiz paket)
- Modify: `TextsBluetoothPeripheralView.swift` ve `tr.lproj/BluetoothPeripheralView.strings`; ilk eklemede tek seferlik uyarı `instaraG1ExperimentalWarning`. Uyarı metni: "Instara-1 desteği deneyseldir. xDrip resmi Instara uygulamasının bağlantısını dinler; resmi uygulama açık ve sensöre bağlı kalmalıdır. Değerleri resmi uygulamayla karşılaştırıp doğrulayana kadar Loop, paylaşım ve glikoz alarmları kapalıdır."
- Test: `BluetoothPeripheralDisplayStatusTests.swift`, `OnlineHelpTests.swift`

- [ ] **Step 1: Testleri ekle.**
  - `XCTAssertFalse(BluetoothPeripheralType.InstaraG1Type.usesIntermittentConnection)`.
  - Instara için yardım anahtarı boş değil.
  - `LoopManager`: `instaraG1.intervalMinutes` yokken `directExpectedInterval(.instaraG1) == 300`; 1 olunca 60. Yöntem `private` ise Sibionics testindeki erişim yolu izlenir.
- [ ] **Step 2: FAIL gör.**
- [ ] **Step 3: Uygula.**
- [ ] **Step 4: Tam test paketini çalıştır.** Yalnızca Global Constraints'teki bilinen başarısızlıklar kalmalı.
- [ ] **Step 5: Commit.** `feat(instara): wire G1 into peripherals, Loop interval and UI`

---

### Task 6: Doğrulama anahtarı arayüzü ve güvenlik kapıları

**Files:**
- Modify: `BluetoothPeripheralDetailState.swift`, `BluetoothPeripheralsViewModel.swift` (Instara cihaz ekranında anahtar satırı ve onay penceresi)
- Modify: `xDrip/Managers/Application/RootApplicationCoordinator.swift` (KVO gözlemci listesine `instaraG1ExportVerified`; değişince `cgmTransmitterTypeAsString` değişimiyle aynı yenileme yapılır). Ayrıca uygulama açılışında doğrulama: anahtar açık ama `instaraG1VerifiedSensorStart`, aktif sensörün başlangıcından 30 dakikadan fazla farklıysa, `reason: "restore-mismatch"` ile kapatılır.
- Modify: ayar ekranının OS-AID görünürlüğü (`canConfigureOSAidSharing` kullanan view model'ler), anahtar değişiminde yenilenmeli
- Modify: metinler (tr): satır `"Değerleri doğruladım — Loop ve paylaşımı aç"`; onay penceresi başlığı `"Değerleri doğruladınız mı?"`; metin: spec 6.5'teki cümle aynen; düğmeler `"Onaylıyorum"` / `"Vazgeç"`.
- Test: `xDrip Tests/InstaraG1SafetyGateTests.swift`

**Interfaces:**
- Consumes: `setInstaraG1Verified` (Task 2), `UserDefaults.activeSourceAllowsGlucoseExport`, `activeSourceAllowsGlucoseAlarms`, `activeOSAidSharingPolicy`, `AlertManager.alertIsPermitted(_:sourceAllowsAlarms:)`.
- Produces: `static func RootApplicationCoordinator.instaraVerificationIsValid(verifiedStart: Date?, activeSensorStart: Date?) -> Bool` (saf, test edilebilir; 30 dk tolerans).

- [ ] **Step 1: Testleri yaz** (master modu, tip `.instaraG1`; UserDefaults `setUp`/`tearDown`'da saklanıp geri yüklenir)
  - `testExportAndAidBlockedWhenUnverified`: `activeSourceAllowsGlucoseExport == false`, `activeOSAidSharingPolicy == .blocked`.
  - `testExportAndAidAllowedWhenVerified`.
  - `testValueAlarmsBlockedWhenUnverifiedButMissedReadingAllowed`: her `AlertKind` için `alertIsPermitted(kind, sourceAllowsAlarms: activeSourceAllowsGlucoseAlarms) == !glucoseValueAlertKinds.contains(kind)`.
  - `testVeryLowAllowedWhenVerified`.
  - `testEnablingAdvancesExportCursorsSoBacklogIsNotExported`: anahtar kapalıyken saklanan bir okumanın zamanı, açıldıktan sonra Nightscout ve HealthKit imleçlerinden eski olmalı.
  - `testLeavingUnverifiedInstaraForOtherSourceAdvancesCursors`: tip `.dexcomG7`'ye değişince imleçler ilerler.
  - `testLeavingVerifiedInstaraDoesNotAdvanceCursors`.
  - `testVerificationForOtherSensorIsRevokedOnRestore`: `instaraVerificationIsValid(verifiedStart: t, activeSensorStart: t + 2 saat) == false`, `(t, t + 10 dk) == true`, `(nil, t) == false`.
  - `testToggleChangeNotifiesKVO`: `instaraG1ExportVerified` için bir KVO gözlemcisi kurulur, değer değişince tetiklenir.
- [ ] **Step 2: FAIL gör** (`InstaraG1SafetyGateTests`).
- [ ] **Step 3: Uygula.** Onaysız açma mümkün olmamalı: anahtar onay penceresinden geçmeden `true` olmaz. `setInstaraG1Verified(true, sensorStart: aktifSensör.startDate, reason: "user")` çağrılır. Aktif sensör yoksa anahtar devre dışıdır ve altında "Önce sensör verisi gelmeli" yazar.
- [ ] **Step 4: PASS gör ve tam paketi çalıştır.**
- [ ] **Step 5: Commit.** `feat(instara): add verification toggle and gate tests`

---

### Task 7: Müşteri test talimatı

**Files:**
- Create: `docs/superpowers/specs/2026-11-27-instara-g1-test-talimati.md`

- [ ] **Step 1: Talimatı yaz.** Türkçe ve sade dil; yapısı `2026-11-26-sibionics-gs1-test-talimati.md` ile aynı.
  - **Bölümler:**
    - TestFlight kurulumu;
    - resmi Instara uygulamasının açık ve sensöre bağlı kalması;
    - xDrip'te Ayarlar → Bluetooth → Ekle → "Instara-1 / Perlanova (Deneysel, resmi uygulamayla)";
    - kalibrasyon yok;
    - en az 24 saat boyunca günde 3–4 kez resmi uygulamanın ve xDrip'in aynı dakikada ekran görüntüsü;
    - sorun raporu paylaşımı (Ayarlar → Gelişmiş Ayarlar → "Gelişmiş ayarları göster" → "Sorun Raporunu Paylaş" → "Raporu Paylaş").
  - **Anahtar:** biz onay vermeden açılmamalı.
  - **Sensör başlatma:** xDrip'te sensör elle başlatılmamalı.
  - **Sorulacaklar:** sensörün ambalajdaki tam modeli; resmi uygulamanın sürümü; iPhone ve iOS sürümü; resmi uygulamanın Apple Health'e glikoz yazıp yazmadığı.
- [ ] **Step 2: Tam derleme ve tam test paketi.**
- [ ] **Step 3: Commit.** `docs(instara): add customer test instructions`

TestFlight yüklemesi bu planın dışındadır ve kullanıcı onayıyla yapılır.
