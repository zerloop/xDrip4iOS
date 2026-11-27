# Sibionics GS1 Test Talimatı (xDrip4iOS, TestFlight)

Merhaba, test için teşekkürler. Bu talimat adım adım ilerler. Takıldığınız yerde bize yazmanız yeterli.

## ÖNEMLİ UYARI

- Bu özellik **deneysel**. xDrip'te göreceğiniz değerler resmi uygulamadan farklı olabilir.
- **İnsülin, yemek veya diğer tedavi kararlarınızı her zaman resmi Sibionics uygulamasına göre verin.**
- xDrip'in düşük/yüksek gibi şeker alarmları bu sensörde **kapalıdır**. Alarmlar için resmi uygulamaya güvenin.
- xDrip sensöre hiçbir şey göndermez, sadece resmi uygulamanın aldığı bilgiyi dinler. Sensörünüze zarar vermez.

## 1. Kurulum

1. iPhone'unuzda **TestFlight** uygulamasını açın.
2. xDrip4iOS test sürümünü yükleyin (veya güncelleyin) ve açın.
3. Bluetooth ve bildirim izinleri sorulursa **İzin Ver** deyin.

## 2. Resmi Sibionics uygulaması

1. Resmi Sibionics uygulamasını açın. Sensörünüze **bağlı** olduğundan ve değer gösterdiğinden emin olun.
2. Test boyunca resmi uygulamayı **kapatmayın** (ekranda açık kalması şart değil, ama uygulamayı yukarı kaydırıp kapatmayın) ve telefonun Bluetooth'unu açık tutun.
3. xDrip, resmi uygulamanın sensörle kurduğu bağlantıyı dinler. Resmi uygulama bağlı değilse xDrip de veri alamaz.

## 3. xDrip'te sensörü ekleme

1. Alttaki menüden **Cihazlar** sekmesine girin.
2. Sağ üstteki **+** düğmesine dokunun.
3. Kategori olarak **CGM** seçin.
4. Listeden **Sibionics GS1 (Deneysel, resmi uygulamayla)** seçin.
5. Bir uyarı çıkacak (bir kereye mahsus). Okuyup onaylayın.
6. Ekranda **"Resmi Sibionics uygulamasını açın…"** yazısı görünebilir. Resmi uygulama açık ve bağlıysa bir süre içinde xDrip bağlantıyı kendisi bulur. Yazı sırasıyla **"Resmi uygulamanın bağlantısı bulundu, bağlanılıyor…"**, **"Bağlandı, glikoz verisi bekleniyor."** ve **"Glikoz verisi alınıyor."** olarak değişir. Birkaç dakika sürebilir, bekleyin.

## 4. İlk değer ve kalibrasyon

1. Sensör ilk takıldığında **60 dakika ısınma** süresi vardır.
2. Isınma bitene kadar xDrip'te değer görünmez. Bu normaldir.
3. Isınmadan sonra **bir parmak ucu ölçümü** yapın ve değeri girin: **Ana Ekran**'da alttaki araç çubuğunda sensör simgesine (**Sensör**) dokunun, açılan ekranda **Kalibre Et**'e dokunun. (Sensör simgesine biraz uzun basarsanız kalibrasyon ekranı doğrudan açılır.)
4. xDrip ilk kalibrasyondan **sonra** değer göstermeye başlar. Bundan sonra "kalibrasyon gerekli" uyarısı gelirse yeniden parmak ucu ölçümü girin. Bu uyarılar açıktır.
5. Değerler resmi uygulamadan bir miktar farklı olabilir. Bu beklenen bir durumdur, farkı bize bildirin.

## 5. Bu testte kapalı olanlar

Bu sensörde şunlar **çalışmaz** (bilerek kapatıldı):

- xDrip'in düşük, yüksek, hızlı düşüş ve hızlı yükseliş alarmları
- Nightscout, Apple Sağlık, Dexcom Share ve Loop/otomatik insülin paylaşımı

Açık kalan uyarılar:

- Kalibrasyon isteği uyarısı
- **Veri kaybı (eksik okuma) uyarısı**: Bu uyarı gelirse resmi uygulamanın bağlantısı kopmuş demektir. Resmi uygulamayı açıp sensöre bağlı olduğunu kontrol edin.

Not: Bu sensör için xDrip'te **sensör batarya alarmı yoktur**. Sensör bataryasını resmi uygulamadan takip edin.

## 6. Bizden istenenler

**Günde 2 veya 3 kez:**
Resmi Sibionics uygulamasının ana ekranının **ekran görüntüsünü** alın. Saatin görünmesi önemli. Aynı anda xDrip'in **Ana Ekran**'ının da ekran görüntüsünü alın (kayıt dosyası xDrip'in değerlerini de içerir, ama ekranda ne gördüğünüzü karşılaştırmak için ekran görüntüsüne de ihtiyacımız var). Görüntüleri bize gönderin.

**Günde bir kez:**
xDrip'te **Cihazlar** sekmesinde **Sibionics GS1** sensörüne dokunun. Açılan ekranda şu satırlar var: Bağlantı durumu, Firmware, Batarya, Son indeks, Son ham değer (kalibre edilmemiş), Son paket zamanı, Bilinmeyen paket sayısı. Bu ekranın **ekran görüntüsünü** gönderin.

**Her gün, beklemeden (bir şey ters gitmese bile):**
Kayıt dosyasını bize gönderin:

1. Alttaki menüden **Ayarlar** sekmesine girin.
2. En alta inip **Gelişmiş Ayarlar** bölümüne gelin.
3. **Gelişmiş ayarları göster** anahtarını açın.
4. **Sorun Raporunu Paylaş**'a dokunun.
5. Açılan **Sorun Raporu** ekranında **Raporu Paylaş**'a dokunun.
6. Ekibimizin size bildirdiği kanaldan (ör. e-posta) bize gönderin.

Dikkat:
- **Gelişmiş ayarları göster** anahtarı yaklaşık 2 dakika sonra ve Ayarlar'ı her yeniden açtığınızda kendiliğinden kapanır. Her seferinde yeniden açın.
- **Hata Ayıklama Düzeyini Kullan** anahtarına **dokunmayın**.
- Dosyayı **her gün** gönderin, ertesi güne bırakmayın. Kayıt dosyaları kendini yeniler (toplam yaklaşık 9 MB); birkaç gün sonra eski veriler silinir ve kaybolur.
- Rapor sağlık verisi içerir. Sadece test ekibine gönderin, başkasıyla paylaşmayın.

**Notlar:**
Test sırasında yaptığınız şeyleri kısaca not edin. Örneğin: telefonu yeniden başlattım, resmi uygulamayı kapattım, sensörü değiştirdim, Bluetooth'u kapatıp açtım. Saat bilgisi de ekleyin.
Yeni sensör taktığınızda saatini not edin.

**Sensör değiştirdiğinizde (önemli):**
xDrip yalnızca ilk eklediğiniz sensörü dinler; yeni sensörü kendiliğinden bulmaz. Yeni sensörü taktıktan ve resmi uygulamada eşleştirdikten sonra:

1. xDrip'te **Cihazlar** sekmesinde Sibionics GS1 sensörüne dokunun ve cihazı **silin** (çöp kutusu simgesi).
2. Yukarıdaki **3. xDrip'te sensörü ekleme** adımlarıyla cihazı yeniden ekleyin.

## 7. Sorun olursa

- **"Resmi Sibionics uygulamasını açın..." yazısı kalıyor:** Resmi uygulamayı açın, sensöre bağlı olduğunu kontrol edin, birkaç dakika bekleyin.
- **Hâlâ değer yok:** Isınma (60 dk) ve ilk parmak ucu kalibrasyonunun yapıldığını kontrol edin.
- **Sensörü değiştirdim, xDrip'te değer gelmiyor:** Cihazı Cihazlar sekmesinden silip yeniden ekleyin (6. bölümdeki "Sensör değiştirdiğinizde" adımları).
- **Uzun süredir veri gelmediyse:** xDrip kendiliğinden bağlantıyı yeniler. Düzelmezse Sorun Raporu dosyasını (yukarıdaki adımlar) ve Cihazlar'daki sensör ekranının görüntüsünü bize gönderin.
- Değerlerden şüpheleniyorsanız her zaman resmi uygulamaya ve parmak ucu ölçümüne güvenin.

## 8. Bize bildirin

Lütfen şu iki bilgiyi bir kereye mahsus yazın:

1. Kullandığınız resmi Sibionics uygulamasının **App Store'daki tam adı**.
2. Sensörünüz **tek parça mı** (sensör ve verici bir arada), yoksa **ayrı, tekrar kullanılan bir verici** mi var?
