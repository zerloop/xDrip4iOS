# Sibionics GS1 Pasif Dinleme — Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resmi Sibionics uygulamasının Bluetooth bağlantısını pasif dinleyen, ham değeri xDrip kalibrasyonuyla deneysel olarak gösteren ve tüm trafiği kanıt olarak log'a yazan bir CGM tipi eklemek.

**Architecture:** Saf, test edilebilir bir protokol katmanı (`SibionicsGS1Protocol`) ve oturum katmanı (`SibionicsGS1Session`), Medtrum TouchCare Nano pasif dinleyici iskeleti üzerine kurulu bir transmitter (`CGMSibionicsGS1Transmitter`). Yeni `CGMTransmitterType.sibionicsGS1` tipinin politika özellikleri Loop, Nightscout, Apple Health, Dexcom Share ve alarmları kapatır.

**Tech Stack:** Swift 5, CoreBluetooth, Core Data (model v38), XCTest (`xdripTests`), Xcode workspace `xdrip.xcworkspace`, scheme `xdrip`.

**Spec:** `docs/superpowers/specs/2026-11-26-sibionics-gs1-design.md`

## Global Constraints

- Sensöre ve `FF32`'ye **hiçbir yazma** yapılmaz; `writeDataToPeripheral` override'ı yazmayı engeller, `false` döner ve "BLOCKED WRITE" log'lar.
- Servis `0000FF30-0000-1000-8000-00805F9B34FB`, bildirim `0000FF31-0000-1000-8000-00805F9B34FB`. Keşif listesi `[FF30, 180A, 180F]`.
- RC4 anahtarı `01380b9a005b025dcd9ec3990937aae8`, skip 0, her paket için anahtar akışı baştan başlar.
- Ham değer: `current / 10` mmol/L; mg/dL = mmol × 18.0182; `glucoseLevelRaw = mg/dL × 1000`; geçerli aralık 1.8–30 mmol/L.
- Kalibratör her zaman `Libre1Calibrator`; `canWebOOP`, `canUseNonFixedSlope`, `isWebOOPEnabled`, `isNonFixedSlopeEnabled` hepsi `false`.
- `osAidSharingPolicy = .blocked`; Nightscout BG yüklemesi, HealthKit, Dexcom Share ve `missedreading` dışındaki tüm alarmlar bu tip için kapalı.
- Watchdog: 5 dk geçerli glikoz paketi yoksa aboneliği yenile; 15 dk'da `disconnect()` + geri çekilmeli `retrieveConnected` (5/10/15 sn).
- İlk bağlantıda en fazla 6 saat geriye; sensör yaşı 14 gün; ısınma 60 dk.
- Peripheral başlığı: `Sibionics GS1 (Deneysel, resmi uygulamayla)`. Raw değerler (kalıcı): `BluetoothPeripheralType.SibionicsGS1Type = "Sibionics GS1"`, `CGMTransmitterType.sibionicsGS1 = "Sibionics GS1"`, `CGMSensorType.Sibionics = "Sibionics"`.
- Log kategorisi `ConstantsLog.categoryCGMSibionicsGS1 = "CGMSibionicsGS1"`.
- Juggluco'dan taşınan dosyalarda GPL-3.0 atıf başlığı: `Portions derived from Juggluco (https://github.com/j-kaltes/Juggluco), Copyright (C) 2021 Jaap Korthals Altes, GPL-3.0.` `chalimov/sibionics_cgm_ha` kodundan hiçbir şey kopyalanmaz.
- **Plan kararı (spec'ten sapma):** `lastReceivedIndex` ve oturum başlangıcı Core Data yerine Medtrum'daki gibi `UserDefaults`'ta (`sibionicsGS1.lastReceivedIndex`, `sibionicsGS1.sensorStartDate`) tutulur; transmitter'a managed object geçirmemek için. Core Data entity yalnız `firmware` taşır (Medtrum ile aynı).
- Test komutu (tek sınıf): `xcodebuild test -workspace xdrip.xcworkspace -scheme xdrip -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -only-testing:xdripTests/<TestClass>` — beklenen çıktı `** TEST SUCCEEDED **`.
- Derleme komutu: `xcodebuild build -workspace xdrip.xcworkspace -scheme xdrip -destination 'platform=iOS Simulator,name=iPhone 18 Pro'` — beklenen `** BUILD SUCCEEDED **`.

## Review Focus

1. Resmi uygulama kapalı / bağlı `FF30` cihazı yok → net durum mesajı, sıkı bağlan-kop döngüsü yok (Task 4: `testNoConnectedPeripheralSchedulesBackoffNotTightLoop`).
2. Resmi uygulamanın tekrar tekrar istediği geçmiş patlamaları → aynı indeks iki kez okunmaz (Task 3: `testDuplicateBatchIsIgnored`).
3. Oturum ortasında sensör değişimi (indeks geri gider, zaman ilerler) → yeni sensör, kalibrasyon sıfırlanır (Task 3: `testIndexResetWithNewerTimeStartsNewSession`).
4. Kısa/bozuk paket, kayıt sayısının uzunluğu aşması → çökme yok, `.invalid` (Task 1: `testRecordCountExceedingLengthIsInvalid`).
5. Sensör saati telefondan ileride → zaman şimdiye kırpılır (Task 3: `testFutureTimestampIsClampedToNow`).

---

### Task 1: Protokol katmanı

**Files:**
- Create: `xDrip/BluetoothTransmitter/CGM/Sibionics/GS1/SibionicsGS1Protocol.swift`
- Create: `xDrip/Constants/ConstantsSibionicsGS1.swift`
- Test: `xDrip Tests/SibionicsGS1ProtocolTests.swift`
- Modify: `xdrip.xcodeproj/project.pbxproj` (dosyaları `xdrip` ve `xdripTests` hedeflerine ekle)

**Interfaces:**
- Produces:
  - `enum ConstantsSibionicsGS1` — `serviceUUID`, `notifyCharacteristicUUID`, `deviceInformationServiceUUID = "180A"`, `batteryServiceUUID = "180F"`, `batteryLevelCharacteristicUUID = "2A19"`, `rc4Key: [UInt8]`, `mmolToMgDl = 18.0182`, `minValidMmol = 1.8`, `maxValidMmol = 30.0`, `maxBackfillSeconds: TimeInterval = 6*3600`, `sensorLifeDays = 14.0`, `warmupMinutes = 60.0`, `resubscribeAfterSeconds = 300`, `releaseAfterSeconds = 900`, `reconnectDelays: [TimeInterval] = [5,10,15]`.
  - `enum SibionicsGS1Protocol { static func rc4(key: [UInt8], data: Data) -> Data; static func classify(_ raw: Data, receivedAt: Date) -> SibionicsGS1Packet; static func comparisonLine(_ r: SibionicsGS1Record, calibratedMgDl: Double?) -> String }`
  - `struct SibionicsGS1Record: Equatable { let index: Int; let timeStamp: Date; let temperatureC: Double; let rawMmol: Double; let dump: Int; let extra: Int; var rawMgDl: Double { get }; var glucoseLevelRaw: Double { get }; var isInValidRange: Bool { get } }`
  - `enum SibionicsGS1Firmware { case legacy, v120 }`
  - `enum SibionicsGS1Packet: Equatable { case records(firmware: SibionicsGS1Firmware, records: [SibionicsGS1Record], reindex: Int?); case ack(cmd: UInt8, status: UInt8, aux: UInt8); case unknownData(cmd: UInt8, decrypted: Data); case invalid(raw: Data, decrypted: Data) }`

- [ ] **Step 1: Testleri yaz**

```swift
final class SibionicsGS1ProtocolTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_795_100_000)
    func hex(_ s: String) -> Data { /* hex → Data yardımcı */ }

    func testRC4StandardVector() {
        XCTAssertEqual(SibionicsGS1Protocol.rc4(key: Array("Key".utf8), data: Data("Plaintext".utf8)), hex("bbf316e8d940af0ad3"))
    }
    func testEncryptedV120GlucoseBatch() {
        let p = SibionicsGS1Protocol.classify(hex("3cff6dbd08b3de21d7ec87030fff068c82dde54c22cf61b67e0afaf3"), receivedAt: t0)
        guard case let .records(fw, recs, reindex) = p else { return XCTFail("\(p)") }
        XCTAssertEqual(fw, .v120); XCTAssertEqual(reindex, 0); XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs[0].index, 100); XCTAssertEqual(recs[0].timeStamp, Date(timeIntervalSince1970: 1_795_000_000))
        XCTAssertEqual(recs[0].rawMmol, 7.2, accuracy: 1e-9); XCTAssertEqual(recs[0].temperatureC, 36.5, accuracy: 1e-9)
        XCTAssertEqual(recs[1].index, 101); XCTAssertEqual(recs[1].timeStamp, Date(timeIntervalSince1970: 1_795_000_060))
        XCTAssertEqual(recs[1].rawMmol, 7.5, accuracy: 1e-9)
        XCTAssertEqual(recs[0].glucoseLevelRaw, 7.2 * 18.0182 * 1000, accuracy: 1e-6)
    }
    func testEncryptedAck() {
        XCTAssertEqual(SibionicsGS1Protocol.classify(hex("23f66ed9f2"), receivedAt: t0), .ack(cmd: 0x01, status: 1, aux: 0))
    }
    func testAuthTriggerDecryptsToBypassAck() {   // 23F76FD9F4 → 04 00 00 00 FC
        XCTAssertEqual(SibionicsGS1Protocol.classify(hex("23f76fd9f4"), receivedAt: t0), .ack(cmd: 0x00, status: 0, aux: 0))
    }
    func testPlainBypassPacketIsNotDecrypted() {
        XCTAssertEqual(SibionicsGS1Protocol.classify(hex("04000000fc"), receivedAt: t0), .ack(cmd: 0x00, status: 0, aux: 0))
    }
    func testLegacyPlainBigEndianRecord() {
        // index 50, temp 36.8, electric 1234, value 6.8, status 0, unreceived 2, addtime 0
        let p = SibionicsGS1Protocol.classify(hex("aa5509010032017004d2004400000002000038"), receivedAt: t0)
        guard case let .records(fw, recs, reindex) = p else { return XCTFail("\(p)") }
        XCTAssertEqual(fw, .legacy); XCTAssertNil(reindex)
        XCTAssertEqual(recs.first?.index, 50); XCTAssertEqual(recs.first!.rawMmol, 6.8, accuracy: 1e-9)
        XCTAssertEqual(recs.first!.temperatureC, 36.8, accuracy: 1e-9)
        XCTAssertEqual(recs.first?.timeStamp, t0.addingTimeInterval(-120))  // offtime = addtime − unreceived×60 = −120
    }
    func testLegacyFutureOffsetIsClampedToReceivedAt() {
        // aynı kayıt, unreceived 0, addtime 30 → offtime > 0 → zaman = receivedAt (process.cpp "infuture")
        let p = SibionicsGS1Protocol.classify(hex("aa5509010032017004d2004400000000001e1c"), receivedAt: t0)
        guard case let .records(_, recs, _) = p else { return XCTFail("\(p)") }
        XCTAssertEqual(recs.first?.timeStamp, t0)
    }
    func testUnknownDataCommandIsPreserved() {
        XCTAssertEqual(SibionicsGS1Protocol.classify(hex("21b56e72c59c08"), receivedAt: t0), .unknownData(cmd: 0x42, decrypted: hex("064201abcdef50")))
    }
    func testBadChecksumIsInvalid() {
        var d = hex("3cff6dbd08b3de21d7ec87030fff068c82dde54c22cf61b67e0afaf3"); d[d.count-1] ^= 0xFF
        guard case .invalid = SibionicsGS1Protocol.classify(d, receivedAt: t0) else { return XCTFail() }
    }
    func testRecordCountExceedingLengthIsInvalid() {
        // çözülmüş: len 0x1b, cmd 08, status 5 (5 kayıt beyan, 2 kayıtlık veri), checksum geçerli
        guard case .invalid = SibionicsGS1Protocol.classify(hex("3cff6abd08b3de21d7ec87030fff068c82dde54c22cf61b67e0afafe"), receivedAt: t0) else { return XCTFail() }
    }
    func testEmptyAndOneBytePacketsAreInvalid() {
        for d in [Data(), Data([0x01])] { guard case .invalid = SibionicsGS1Protocol.classify(d, receivedAt: t0) else { return XCTFail() } }
    }
    func testOutOfRangeRecordIsFlagged() {
        func r(_ v: Double) -> SibionicsGS1Record { SibionicsGS1Record(index: 1, timeStamp: t0, temperatureC: 36, rawMmol: v, dump: 0, extra: 0) }
        XCTAssertFalse(r(0.5).isInValidRange); XCTAssertFalse(r(31.0).isInValidRange)
        XCTAssertTrue(r(1.8).isInValidRange);  XCTAssertTrue(r(30.0).isInValidRange)
    }
    func testComparisonLineFormat() {
        let r = SibionicsGS1Record(index: 100, timeStamp: Date(timeIntervalSince1970: 1_795_000_000), temperatureC: 36.5, rawMmol: 7.2, dump: 0, extra: 0)
        XCTAssertEqual(SibionicsGS1Protocol.comparisonLine(r, calibratedMgDl: nil), "SIBCMP;1795000000000;100;7.2;36.5;-")
        XCTAssertEqual(SibionicsGS1Protocol.comparisonLine(r, calibratedMgDl: 131.4), "SIBCMP;1795000000000;100;7.2;36.5;131")
    }
}
```

- [ ] **Step 2: Çalıştır, derleme hatasıyla FAIL olduğunu gör** — komut: Global Constraints'teki test komutu, `<TestClass>` = `SibionicsGS1ProtocolTests`.

- [ ] **Step 3: `SibionicsGS1Protocol` ve `ConstantsSibionicsGS1`'i yaz**

Sınıflandırma sırası (spec 6.3): (1) uzunluk < 5 → `.invalid`; (2) `AA 55 09` + toplam-checksum → legacy (14 baytlık big-endian kayıtlar: index, temp×10, electric, value×10, status, unreceived, addtime; `offtime = addtime − unreceived×60`; `offtime > 0` ise zaman = `receivedAt`, değilse `receivedAt + offtime`); (3) tam olarak `04 00 00 00 FC` → şifresiz; değilse RC4 çöz; doğrulama tutmazsa şifresiz hâli aynı doğrulamadan geçir; (4) uzunluk alanı 4 → ACK (checksum `-(cmd+status+aux+4)`); (5) cmd `0x08` → kayıtlar (status = sayı; `6 + 8×n + 2 ≤ N−3` değilse `.invalid`); `status == 0` → `.records(..., records: [], ...)`; (6) cmd `0x0A,0x3E,0x40,0x41,0x42,0x66,0xF2,0x17,0x18,0xF0` → `.unknownData`; (7) diğer → `.invalid`. Hiçbir indeksleme sınır kontrolsüz yapılmaz. Juggluco atıf başlığı eklenir.

- [ ] **Step 4: Testi çalıştır** — beklenen `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "xDrip/BluetoothTransmitter/CGM/Sibionics/GS1/SibionicsGS1Protocol.swift" xDrip/Constants/ConstantsSibionicsGS1.swift "xDrip Tests/SibionicsGS1ProtocolTests.swift" xdrip.xcodeproj/project.pbxproj
git commit -m "feat(sibionics): add GS1 passive protocol decoder"
```

---

### Task 2: Tip, politika ve veri modeli

**Files:**
- Modify: `xDrip/BluetoothTransmitter/CGM/Generic/CGMTransmitter.swift` (`CGMTransmitterType` + tüm switch'ler)
- Modify: `xDrip/BluetoothTransmitter/CGM/Generic/CGMSensorType.swift`
- Modify: `xDrip/BluetoothPeripheral/Generic/BluetoothPeripheralType.swift`
- Create: `xDrip/Core Data/xdrip.xcdatamodeld/xdrip v38.xcdatamodel/contents` (v37 kopyası + `SibionicsGS1` entity + `BLEPeripheral.sibionicsGS1` ilişkisi), `.xccurrentversion` → v38
- Create: `xDrip/Core Data/classes/SibionicsGS1+CoreDataClass.swift`, `SibionicsGS1+CoreDataProperties.swift`
- Modify: `xDrip/Core Data/classes/BLEPeripheral+CoreDataProperties.swift`
- Create: `xDrip/BluetoothPeripheral/CGM/Sibionics/GS1/SibionicsGS1+BluetoothPeripheral.swift`
- Test: `xDrip Tests/SibionicsGS1TypePolicyTests.swift`

**Interfaces:**
- Consumes: yok.
- Produces:
  - `CGMTransmitterType.sibionicsGS1` — `sensorType() == .Sibionics`, `osAidSharingPolicy == .blocked`, `canDetectNewSensor() == true`, `allowManualSensorStart() == false`, `detailedDescription()` → `"Sibionics GS1 (experimental, passive)"`.
  - `CGMTransmitterType.allowsGlucoseExport: Bool` (yeni; `.sibionicsGS1` için `false`, diğerleri `true`) ve `CGMTransmitterType.allowsGlucoseAlarms: Bool` (aynı).
  - `BluetoothPeripheralType.SibionicsGS1Type` — `category() == .CGM`, `needsTransmitterId() == false`, `canWebOOP() == false`, `canUseNonFixedSlope() == false`, `needsNFCScanToConnect() == false`, `usesIntermittentConnection == false`, `bluetoothPeripheralDisplayTitle == "Sibionics GS1 (Deneysel, resmi uygulamayla)"`.
  - `class SibionicsGS1: NSManagedObject` — `init(address:name:alias:nsManagedObjectContext:)`, `@NSManaged var blePeripheral: BLEPeripheral`, `@NSManaged var firmware: String?`; `BLEPeripheral.sibionicsGS1: SibionicsGS1?`.

- [ ] **Step 1: Testleri yaz** — `testSibionicsTypeIsBlockedFromAid` (`XCTAssertEqual(CGMTransmitterType.sibionicsGS1.osAidSharingPolicy, .blocked)`), `testSibionicsDisallowsExportAndAlarms` (`allowsGlucoseExport` ve `allowsGlucoseAlarms` false; `.dexcomG7` için true), `testSibionicsDetectsNewSensor`, `testSibionicsPeripheralTypeFlags` (yukarıdaki tüm `BluetoothPeripheralType` değerleri), `testRawValuesAreStable` (üç raw değer Global Constraints'teki gibi).
- [ ] **Step 2: FAIL gör** (`<TestClass>` = `SibionicsGS1TypePolicyTests`).
- [ ] **Step 3: Uygula** — derleyicinin gösterdiği her eksik `switch` case'i Medtrum karşılığına bakarak doldur; Sibionics'e özel değerler yukarıdaki Interfaces'te. `createNewBluetoothPeripheral` benzeri fabrika (BluetoothPeripheralType.swift:85 civarı) `SibionicsGS1(...)` döndürür. Model v38 hafif migration (yeni opsiyonel entity ve ilişki).
- [ ] **Step 4: Testi ve tam derlemeyi çalıştır** — ikisi de başarılı.
- [ ] **Step 5: Commit** — `feat(sibionics): add GS1 transmitter type, policy and data model v38`.

---

### Task 3: Oturum katmanı (tekilleştirme, yeni sensör, zaman)

**Files:**
- Create: `xDrip/BluetoothTransmitter/CGM/Sibionics/GS1/SibionicsGS1Session.swift`
- Test: `xDrip Tests/SibionicsGS1SessionTests.swift`

**Interfaces:**
- Consumes: `SibionicsGS1Record` (Task 1), `ConstantsSibionicsGS1` (Task 1).
- Produces:
  - `struct SibionicsGS1SessionState: Equatable { var lastReceivedIndex: Int; var sensorStartDate: Date?; var lastReadingDate: Date? }` (`lastReceivedIndex == -1` başlangıç)
  - `struct SibionicsGS1SessionResult { let newRecords: [SibionicsGS1Record]; let newSensorStartDate: Date?; let skipped: [(record: SibionicsGS1Record, reason: String)] }`
  - `enum SibionicsGS1Session { static func process(_ records: [SibionicsGS1Record], state: inout SibionicsGS1SessionState, now: Date) -> SibionicsGS1SessionResult }`

Kurallar (spec 6.4): gelecekteki zaman `now`'a kırpılır; `index ≤ lastReceivedIndex` ise: kayıt zamanı `lastReadingDate`'ten yeniyse yeni oturum (`lastReceivedIndex = -1`, `sensorStartDate = timeStamp − index×60`, `newSensorStartDate` set edilir) ve kayıt işlenir, değilse "duplicate" ile atlanır; ilk oturumda `now − 6 saat`'ten eski kayıtlar "backfill-limit" ile atlanır; aralık dışı değerler "out-of-range" ile atlanır ama `lastReceivedIndex` ilerler; `sensorStartDate` nil ise ilk kayıttan hesaplanır.

- [ ] **Step 1: Testleri yaz** — `testFirstBatchSetsSensorStart` (index 100, t → start = t − 6000 sn), `testDuplicateBatchIsIgnored` (aynı batch iki kez → ikinci `newRecords` boş), `testIndexResetWithNewerTimeStartsNewSession` (son index 500; index 3, zaman ilerde → `newSensorStartDate == ts − 180`, kayıt `newRecords`'ta), `testIndexBackwardsWithOlderTimeIsSkipped`, `testFutureTimestampIsClampedToNow`, `testBackfillLimitSixHours` (7 saat önceki kayıt atlanır, 5 saat önceki alınır), `testOutOfRangeAdvancesIndexButIsNotEmitted`.
- [ ] **Step 2: FAIL gör** (`SibionicsGS1SessionTests`).
- [ ] **Step 3: `SibionicsGS1Session.process` uygula.**
- [ ] **Step 4: PASS gör.**
- [ ] **Step 5: Commit** — `feat(sibionics): add GS1 session dedupe and new-sensor detection`.

---

### Task 4: Pasif transmitter

**Files:**
- Create: `xDrip/BluetoothTransmitter/CGM/Sibionics/GS1/CGMSibionicsGS1Transmitter.swift`
- Modify: `xDrip/Constants/ConstantsLog.swift` (`categoryCGMSibionicsGS1`)
- Test: `xDrip Tests/CGMSibionicsGS1TransmitterTests.swift`

**Interfaces:**
- Consumes: Task 1, 2, 3.
- Produces: `class CGMSibionicsGS1Transmitter: BluetoothTransmitter, CGMTransmitter` — `init(address: String?, name: String?, bluetoothTransmitterDelegate: BluetoothTransmitterDelegate, cGMTransmitterDelegate: CGMTransmitterDelegate)`; `cgmTransmitterType() == .sibionicsGS1`; `maxSensorAgeInDays() == 14`; `sensorWarmupDurationInMinutes() == 60`; `getCBUUID_Service()`/`getCBUUID_Receive()` → FF30/FF31; `private(set) var diagnostics: SibionicsGS1Diagnostics` (`firmware: SibionicsGS1Firmware?`, `batteryPercent: Int?`, `lastIndex: Int?`, `lastRawMmol: Double?`, `lastPacketDate: Date?`, `unknownPacketCount: Int`, `statusMessage: String`).

Davranış (spec 6.2–6.6, Medtrum iskeleti `CGMMedtrumTouchCareNanoTransmitter.swift`'ten): taban `init`'e `servicesCBUUIDs: [FF30, 180A, 180F]`, alım ve yazma UUID'si ikisi de FF31; `startScanning()` override → `retrieveConnectedPeripheral(withServiceUUIDs: [FF30])`, yoksa `statusMessage = "Resmi Sibionics uygulamasını açın…"` ve geri çekilmeli yeniden deneme, `.alreadyScanning`/uygun sonuç döner, **gerçek tarama başlatmaz**; `writeDataToPeripheral` üç overload'u da override → trace "BLOCKED WRITE", `false`; keşifte tüm karakteristikler log'a, FF31 `setNotifyValue(true)`, `180A` karakteristikleri ve `2A19` bir kez `readValue`; `didUpdateValueFor` → `SibionicsGS1Protocol.classify` → `.records` ise `SibionicsGS1Session.process` (state UserDefaults'tan `sibionicsGS1.*` anahtarlarıyla okunur/yazılır), `newSensorStartDate` varsa `cgmTransmitterDelegate?.newSensorDetected(sensorStartDate:)`, `newRecords` → `GlucoseData(timeStamp:glucoseLevelRaw:)` en yeni önce sırayla `cgmTransmitterInfoReceived`; her kayıt (atlananlar dahil) için `comparisonLine` trace'e; `.unknownData` → "UNKNOWN-DATA" + hex; `.invalid` → "INVALID" + iki hex; watchdog 300 sn `setNotifyValue(false)`→`true`, 900 sn `disconnect()` + yeniden deneme; `prepareForRelease` ve `disconnect` öncesi FF31 aboneliği bırakılır. Juggluco atıf başlığı.

- [ ] **Step 1: Testleri yaz** — `testWriteIsBlocked` (transmitter'ı test delegeleriyle oluştur; `writeDataToPeripheral(data: Data([1]), type: .withoutResponse)` → `false`), `testTypeAndLimits` (`cgmTransmitterType`, 14 gün, 60 dk, UUID'ler), `testNoConnectedPeripheralSchedulesBackoffNotTightLoop` (simülatörde bağlı cihaz yok: `startScanning()` sonrası `diagnostics.statusMessage` resmi uygulama mesajı; 1 sn içinde ikinci `retrieveConnected` denemesi yapılmadığı, deneme sayacıyla), `testRecordsAreDeliveredOnceViaDelegate` (test seam: `func handleNotification(_ data: Data, now: Date)` internal metodu Task 1'deki şifreli glikoz paketiyle iki kez çağrılır → sahte delegeye toplam 2 `GlucoseData`, `glucoseLevelRaw` beklenen değer).
- [ ] **Step 2: FAIL gör** (`CGMSibionicsGS1TransmitterTests`).
- [ ] **Step 3: Uygula.** `handleNotification(_:now:)` `didUpdateValueFor`'un çağırdığı internal metottur; testler UserDefaults anahtarlarını `setUp`/`tearDown`'da temizler.
- [ ] **Step 4: PASS gör.**
- [ ] **Step 5: Commit** — `feat(sibionics): add passive GS1 co-listener transmitter`.

---

### Task 5: Uygulama geneline bağlama

**Files (Medtrum'un dokunduğu her yer; derleyici eksikleri gösterir):**
- Modify: `xDrip/Managers/BluetoothPeripheral/BluetoothPeripheralManager.swift` (≈177, 404, 498, 589, 1047, 1190: oluşturma, `getBluetoothTransmitter`, tip eşleme, `createNewTransmitter`, Core Data getirme)
- Modify: `xDrip/Managers/Application/RootApplicationCoordinator.swift:1980-2025` (`getCalibrator`: `case .sibionicsGS1: calibrator = Libre1Calibrator()`)
- Modify: `xDrip/Managers/Loop/LoopManager.swift` (≈296 `"sibionics_gs1"`, 316/342 aralık 60 sn grubuna)
- Modify: `xDrip/Managers/PostProcessing/BgPostProcessingManager.swift` (≈1369, 1408: `$0.sibionicsGS1 != nil`)
- Modify: `xDrip/Managers/Alerts/AlertKind.swift:98` (batarya yok grubuna)
- Modify: `xDrip/Utilities/TroubleshootingLog.swift`, `xDrip/Utilities/Trace.swift:761`, `xDrip/Utilities/OnlineHelp.swift:433`
- Modify: `xDrip/SwiftUIViews/BluetoothPeripherals/BluetoothPeripheralsViewModel.swift:593,608`, `BluetoothPeripheralDetailState.swift:677,2885,2971` (diagnostics satırları: Bağlantı durumu, Firmware, Batarya, Son indeks, Son ham değer, Son paket zamanı, Bilinmeyen paket sayısı)
- Modify: `xDrip/Extensions/UserDefaults.swift`, `BackupModels.swift`, `SensorManagementView.swift`, ilgili `xDrip/Texts/Texts*.swift` (yeni metin anahtarları)
- Test: `xDrip Tests/BluetoothPeripheralDisplayStatusTests.swift`, `xDrip Tests/OnlineHelpTests.swift` (Medtrum satırlarının Sibionics eşleri)

**Interfaces:**
- Consumes: Task 2 tipleri, Task 4 transmitter ve `diagnostics`.
- Produces: kullanıcı ayarlardan "Sibionics GS1 (Deneysel, resmi uygulamayla)" ekleyebilir; ilk eklemede tek seferlik uyarı (metin: spec 6.5'teki cümle, `Texts_BluetoothPeripheralView.sibionicsGS1ExperimentalWarning`).

- [ ] **Step 1: Testleri ekle** — `XCTAssertFalse(BluetoothPeripheralType.SibionicsGS1Type.usesIntermittentConnection)`; OnlineHelp'te Sibionics için yardım anahtarının boş olmadığı.
- [ ] **Step 2: FAIL gör** (ilgili iki test sınıfı).
- [ ] **Step 3: Uygula** — her case Medtrum'un karşılığını izler; farklar yalnız Interfaces'te ve Global Constraints'te.
- [ ] **Step 4: Tam test paketini çalıştır** — `xcodebuild test -workspace xdrip.xcworkspace -scheme xdrip -destination 'platform=iOS Simulator,name=iPhone 18 Pro'` → `** TEST SUCCEEDED **`.
- [ ] **Step 5: Commit** — `feat(sibionics): wire GS1 into peripherals, calibration and UI`.

---

### Task 6: Güvenlik kapıları (Nightscout, HealthKit, Dexcom Share, alarmlar)

**Files:**
- Modify: `xDrip/Managers/Nightscout/NightscoutSyncManager.swift:303` (`uploadLatestBgReadings` başına kapı)
- Modify: `xDrip/Managers/HealthKit/HealthKitManager.swift:116` (`storeBgReadings`)
- Modify: `xDrip/Managers/DexcomShare/DexcomShareUploadManager.swift:160` (`uploadLatestBgReadings`)
- Modify: `xDrip/Managers/Alerts/AlertManager.swift:866` (`checkAlertAndFire`: `alertKind != .missedreading` ve kapı kapalıysa `false` döner, trace'e neden yazar)
- Modify: `xDrip/Extensions/UserDefaults.swift` (yardımcılar)
- Test: `xDrip Tests/SibionicsGS1SafetyGateTests.swift`

**Interfaces:**
- Consumes: `CGMTransmitterType.allowsGlucoseExport`, `.allowsGlucoseAlarms` (Task 2).
- Produces: `UserDefaults.activeSourceAllowsGlucoseExport: Bool` ve `UserDefaults.activeSourceAllowsGlucoseAlarms: Bool` — `isMaster` ise `cgmTransmitterType?.allowsX ?? true`, follower modunda `true`. `AlertManager.static func alertIsPermitted(_ kind: AlertKind, sourceAllowsAlarms: Bool) -> Bool` (`missedreading` her zaman `true`).

- [ ] **Step 1: Testleri yaz** — `testExportBlockedForSibionicsMaster`, `testExportAllowedForFollower`, `testAlarmsBlockedExceptMissedReading` (her `AlertKind` için `alertIsPermitted(kind, sourceAllowsAlarms: false) == (kind == .missedreading)`), `testAlarmsAllowedForOtherSources`. Testler `UserDefaults.standard` değerlerini `setUp`'ta saklayıp `tearDown`'da geri yükler.
- [ ] **Step 2: FAIL gör** (`SibionicsGS1SafetyGateTests`).
- [ ] **Step 3: Uygula** — dört giriş noktasının başında kapı; engellendiğinde ilgili kategoride trace.
- [ ] **Step 4: PASS gör ve tam paketi çalıştır.**
- [ ] **Step 5: Commit** — `feat(sibionics): block export and alarms for experimental GS1 source`.

---

### Task 7: Müşteri test talimatı ve TestFlight hazırlığı

**Files:**
- Create: `docs/superpowers/specs/2026-11-26-sibionics-gs1-test-talimati.md`

- [ ] **Step 1: Talimatı yaz (Türkçe, sade dil)** — bölümler: TestFlight kurulumu; resmi Sibionics uygulamasının açık ve sensöre bağlı kalması; xDrip'te Ayarlar → Bluetooth → Ekle → "Sibionics GS1 (Deneysel, resmi uygulamayla)"; ilk değer için 60 dk ısınma ve ardından parmak ucu kalibrasyonu; günde 2–3 kez resmi uygulama ana ekranının ekran görüntüsü (saat görünür); Ayarlar → Trace dosyalarını paylaş ile log gönderme; uyarı: tedavi kararları resmi uygulamaya göre, xDrip alarmları bu sensörde kapalı.
- [ ] **Step 2: Tam derleme ve test** — Global Constraints'teki build ve test komutları başarılı.
- [ ] **Step 3: Commit** — `docs(sibionics): add customer test instructions`.

TestFlight'a yükleme (`fastlane` / GitHub workflow) bu planın dışında ve kullanıcı onayıyla yapılır.
