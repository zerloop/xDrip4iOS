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
6. Ekranda **"Resmi Sibionics uygulamasını açın…"** yazısı görünebilir. Resmi uygulama açık ve bağlıysa bir süre içinde xDrip bağlantıyı kendisi bulur ve yazı **"Bağlandı"** ve ardından **"Glikoz verisi alınıyor."** olarak değişir. Birkaç dakika sürebilir, bekleyin.

## 4. İlk değer ve kalibrasyon

1. Sensör ilk takıldığında **60 dakika ısınma** süresi vardır.
2. Isınma bitene kadar xDrip'te değer görünmez. Bu normaldir.
3. Isınmadan sonra **bir parmak ucu ölçümü** yapın ve **Ana Ekran**'daki **Kalibre Et** seçeneğiyle değeri girin.
4. xDrip ilk kalibrasyondan **sonra** değer göstermeye başlar. Bundan sonra "kalibrasyon gerekli" uyarısı gelirse yeniden parmak ucu ölçümü girin. Bu uyarılar açıktır.
5. Değerler resmi uygulamadan bir miktar farklı olabilir. Bu beklenen bir durumdur, farkı bize bildirin.

## 5. Bu testte kapalı olanlar

Bu sensörde şunlar **çalışmaz** (bilerek kapatıldı):

- xDrip'in düşük, yüksek, hızlı düşüş ve hızlı yükseliş alarmları
- Nightscout, Apple Sağlık, Dexcom Share ve Loop/otomatik insülin paylaşımı

Açık kalan uyarılar:

- Kalibrasyon isteği uyarısı
- **Veri kaybı (eksik okuma) uyarısı**: Bu uyarı gelirse resmi uygulamanın bağlantısı kopmuş demektir. Resmi uygulamayı açıp sensöre bağlı olduğunu kontrol edin.

## 6. Bizden istenenler

**Günde 2 veya 3 kez:**
Resmi Sibionics uygulamasının ana ekranının **ekran görüntüsünü** alın. Saatin görünmesi önemli. xDrip'in ana ekranından da aynı anda bir ekran görüntüsü alabilirseniz çok iyi olur. Görüntüleri bize gönderin.

**Günde bir kez:**
xDrip'te **Cihazlar** sekmesinde **Sibionics GS1** sensörüne dokunun. Açılan ekranda şu satırlar var: Bağlantı durumu, Firmware, Batarya, Son indeks, Son ham değer, Son paket zamanı, Bilinmeyen paket sayısı. Bu ekranın **ekran görüntüsünü** gönderin.

**Her gün sonunda (veya bir şey ters gittiğinde):**
Kayıt dosyasını bize gönderin:

1. Alttaki menüden **Ayarlar** sekmesine girin.
2. **Sorun Giderme**'ye, sonra **Etkinlik Günlüğü**'ne dokunun.
3. Sağ üstteki **Paylaş** simgesine (yukarı oku olan kare) dokunun.
4. Mesajlaşma veya e-posta ile bize gönderin.

**Notlar:**
Test sırasında yaptığınız şeyleri kısaca not edin. Örneğin: telefonu yeniden başlattım, resmi uygulamayı kapattım, sensörü değiştirdim, Bluetooth'u kapatıp açtım. Saat bilgisi de ekleyin.

## 7. Sorun olursa

- **"Resmi Sibionics uygulamasını açın..." yazısı kalıyor:** Resmi uygulamayı açın, sensöre bağlı olduğunu kontrol edin, birkaç dakika bekleyin.
- **Hâlâ değer yok:** Isınma (60 dk) ve ilk parmak ucu kalibrasyonunun yapıldığını kontrol edin.
- **Uzun süredir veri gelmediyse:** xDrip kendiliğinden bağlantıyı yeniler. Düzelmezse Etkinlik Günlüğü'nü ve Cihazlar'daki sensör ekranının görüntüsünü bize gönderin.
- Değerlerden şüpheleniyorsanız her zaman resmi uygulamaya ve parmak ucu ölçümüne güvenin.
