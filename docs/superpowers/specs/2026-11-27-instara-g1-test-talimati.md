# Instara-1 / Perlanova Test Talimatı (xDrip4iOS, TestFlight)

Merhaba, test için teşekkürler. Bu talimat adım adım ilerler. Takıldığınız yerde bize yazmanız yeterli.

## ÖNEMLİ UYARI

- Bu özellik **deneysel**. xDrip'te göreceğiniz değerler resmi uygulamadan farklı olabilir.
- **İnsülin, yemek veya diğer tedavi kararlarınızı test boyunca her zaman resmi Instara uygulamasına göre verin.**
- Biz onay verene kadar xDrip'te **Loop, Nightscout, Apple Sağlık, Dexcom Share paylaşımı ve düşük/yüksek/hızlı düşüş/hızlı yükseliş şeker alarmları kapalıdır**. Şeker alarmları için resmi uygulamaya güvenin.
- xDrip sensöre hiçbir şey göndermez, sadece resmi uygulamanın aldığı bilgiyi dinler. Sensörünüze zarar vermez.

## 1. Kurulum

1. iPhone'unuzda **TestFlight** uygulamasını açın.
2. xDrip4iOS test sürümünü yükleyin (veya güncelleyin) ve açın.
3. Bluetooth ve bildirim izinleri sorulursa **İzin Ver** deyin.

## 2. Resmi Instara uygulaması

1. Resmi Instara uygulamasını açın. Sensörünüze **bağlı** olduğundan ve değer gösterdiğinden emin olun.
2. Test boyunca resmi uygulamayı **kapatmayın** (ekranda açık kalması şart değil, ama uygulamayı yukarı kaydırıp kapatmayın) ve telefonun Bluetooth'unu açık tutun.
3. xDrip, resmi uygulamanın sensörle kurduğu bağlantıyı dinler. Resmi uygulama bağlı değilse xDrip de veri alamaz.

## 3. xDrip'te sensörü ekleme

1. Alttaki menüden **Cihazlar** (Bluetooth cihazları) sekmesine girin.
2. Sağ üstteki **+** (Ekle) düğmesine dokunun.
3. Kategori olarak **CGM** seçin.
4. Listeden **Instara-1 / Perlanova (Deneysel, resmi uygulamayla)** seçin.
5. **"Instara-1 (Deneysel)"** başlıklı bir uyarı çıkacak (bir kereye mahsus). Okuyup onaylayın.
6. Resmi uygulama açık ve bağlıysa xDrip bağlantıyı kendisi bulur. Ekrandaki durum yazısı sırasıyla **"Resmi uygulamanın bağlantısı bulundu, bağlanılıyor…"**, **"Bağlandı, glikoz verisi bekleniyor."** ve **"Glikoz verisi alınıyor."** olarak değişir. Birkaç dakika sürebilir, bekleyin.

**Sensörü xDrip'te elle başlatmayın veya düzeltmeyin.** Sensörün başlangıç zamanını xDrip kendisi bulur. Sensörü sadece resmi uygulamadan başlatın.

## 4. Kalibrasyon yok

Bu sensör fabrikada kalibre edilmiştir. xDrip'te **kalibrasyon yapmanız gerekmez** ve parmak ucu değeri girmeyin. Değerler birkaç dakika içinde, ısınma bittiğinde görünmeye başlar.

## 5. Bu testte kapalı olanlar ve anahtar

Biz onay verene kadar şunlar **çalışmaz** (bilerek kapatıldı):

- xDrip'in düşük, yüksek, hızlı düşüş ve hızlı yükseliş alarmları
- Nightscout, Apple Sağlık, Dexcom Share ve Loop/otomatik insülin paylaşımı

Açık kalan uyarılar:

- **Kaçırılan Okumalar** uyarısı (veri kaybı): Bu uyarı gelirse resmi uygulamanın bağlantısı kopmuş demektir. Resmi uygulamayı açıp sensöre bağlı olduğunu kontrol edin.
- Sensör ömrü (süre dolumu) uyarısı
- Loop durdu uyarısı

**Doğrulama anahtarı:** Instara cihaz ekranında **"Değerleri doğruladım — Loop ve paylaşımı aç"** anahtarı vardır. **Biz (geliştirici ekip) karşılaştırmanın iyi olduğunu size bildirmeden bu anahtarı AÇMAYIN.** Açmak Loop'u ve paylaşımı devreye sokar. Anahtar ancak xDrip sensörden veri almaya başladıktan sonra kullanılabilir hâle gelir; öncesinde altında **"Önce sensör verisi gelmeli"** yazar. Yeni bir sensör taktığınızda anahtar kendiliğinden kapanır; yine bizden onay beklemeden açmayın.

## 6. Bizden istenenler

**En az 24 saat boyunca, günde 3-4 kez:**
Resmi Instara uygulamasının ana ekranının **ekran görüntüsünü** alın, hemen ardından (aynı dakika içinde) xDrip **Ana Ekran**'ının da ekran görüntüsünü alın. İki görüntüde de **saatin görünmesi** önemli. Görüntüleri bize gönderin. Gün içinde farklı saatlerde alın (sabah, öğle, akşam, gece gibi).

**Günde bir kez:**
xDrip'te **Cihazlar** sekmesinde Instara sensörüne dokunun. Açılan ekranda şu satırlar var: Bağlantı durumu, Firmware, Pil, Son sıra no, Son ham değer (mmol/L), Okuma aralığı, Son paket zamanı, Bilinmeyen/geçersiz paket. Bu ekranın **ekran görüntüsünü** gönderin.

**Her gün, beklemeden (bir şey ters gitmese bile):**
Kayıt dosyasını bize gönderin:

1. Alttaki menüden **Ayarlar** sekmesine girin.
2. En alta inip **Gelişmiş Ayarlar** bölümüne gelin.
3. **Gelişmiş ayarları göster** anahtarını açın.
4. **Sorun Raporunu Paylaş**'a dokunun.
5. Açılan ekranda **Raporu Paylaş**'a dokunun.
6. Ekibimizin size bildirdiği kanaldan (ör. e-posta) bize gönderin.

Dikkat:
- **Gelişmiş ayarları göster** anahtarı yaklaşık 2 dakika sonra ve Ayarlar'ı her yeniden açtığınızda kendiliğinden kapanır. Her seferinde yeniden açın.
- **Hata Ayıklama Düzeyini Kullan** anahtarına **dokunmayın**.
- Dosyayı **her gün** gönderin, ertesi güne bırakmayın. Kayıt dosyaları kendini yeniler; birkaç gün sonra eski veriler silinir ve kaybolur.
- Rapor sağlık verisi içerir. Sadece test ekibine gönderin, başkasıyla paylaşmayın.

**Notlar:**
Test sırasında yaptığınız şeyleri kısaca not edin. Örneğin: telefonu yeniden başlattım, resmi uygulamayı kapattım, sensörü değiştirdim, Bluetooth'u kapatıp açtım. Saat bilgisi de ekleyin. Yeni sensör taktığınızda saatini not edin.

**Sensör değiştirdiğinizde (önemli):**
xDrip yalnızca ilk eklediğiniz sensörü dinler; yeni sensörü kendiliğinden bulmaz. Yeni sensörü taktıktan ve resmi uygulamada eşleştirdikten sonra:

1. xDrip'te **Cihazlar** sekmesinde Instara sensörüne dokunun ve cihazı **silin** (çöp kutusu simgesi).
2. Yukarıdaki **3. xDrip'te sensörü ekleme** adımlarıyla cihazı yeniden ekleyin.

Cihazı silmek doğrulama anahtarını da kapatır. Yeni sensör için anahtarı yine bizden onay gelmeden açmayın.

## 7. Sorun olursa

- **"Resmi Instara uygulamasını açın ve sensörün bağlı olduğundan emin olun." yazısı kalıyor:** Resmi uygulamayı açın, sensöre bağlı olduğunu kontrol edin, birkaç dakika bekleyin.
- **Hâlâ değer yok:** Sensörün ısınmasının bittiğini ve resmi uygulamanın değer gösterdiğini kontrol edin.
- **Sensörü değiştirdim, xDrip'te değer gelmiyor:** Cihazı Cihazlar sekmesinden silip yeniden ekleyin (6. bölümdeki "Sensör değiştirdiğinizde" adımları).
- **Uzun süredir veri gelmediyse:** xDrip kendiliğinden bağlantıyı yeniler. Düzelmezse Sorun Raporu dosyasını (yukarıdaki adımlar) ve Cihazlar'daki sensör ekranının görüntüsünü bize gönderin.
- Değerlerden şüpheleniyorsanız her zaman resmi uygulamaya güvenin.

## 8. Bize bildirin

Lütfen şu bilgileri bir kereye mahsus yazın:

1. Sensörünüzün **ambalajında yazan tam model adı** (Instara-1, G1, Perlanova veya başka bir ad).
2. Kullandığınız resmi Instara uygulamasının **sürümü**.
3. **iPhone modeliniz ve iOS sürümünüz**.
4. Resmi uygulamanın **Apple Sağlık'a glikoz değeri yazıp yazmadığı** (bilmiyorsanız "bilmiyorum" yazın).
