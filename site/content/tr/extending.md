# Genişletme

Tasarımı üç kural ayakta tutuyor.

1. **Ajan ince bir tetikleyicidir.** *Kim* ve *ne zaman* der, fazlasını demez. Kısa kalır, çünkü tarifi her oturuma yükleniyor.
2. **Yöntemin tek kaynağı skill'dir.** İşin nasıl yapılacağı orada bir kez yazılır ve hiçbir ajanın içine kopyalanmaz.
3. **Önemli olan kural kapıya dönüşür.** Uygulama araç seviyesinde durur: bir hook, bir izin, bir test vakası. Modelden hatırlaması istenmez.

Bir ajan ya da skill eklerken `AGENT_TEMPLATE.md` sözleşmesine uyun: frontmatter (ad · tarif · en az yetkiyle araçlar · model seviyesi), gövdedeki `Trigger phrases:` satırı ve gövde bölümleri (Ne zaman → Uzmanlık duruşu → Nasıl → Koordinasyon → Definition of Done → Çıktı → Eskalasyon → Örnek → Kısıtlar). `smoke-test.sh`, hiçbir yönlendirmenin ulaşmadığı bir bileşeni geri çevirir; böylece hiçbir şey uyur hâlde yayımlanmaz. `/crew-skill` sizi adım adım götürür ve kapılarla biter.

Tam kurulum yerine tek bir bileşen almak için `npx crewforth add <ad>`, bir ajanı ya da skill'i (ve bir ajanın kullandığı skill'leri) `./.claude` içine kopyalar; `npx crewforth add --list` kataloğu gösterir.

## Kurum preset'i

Tek bir JSON dosyası bir kurumun ayarlarını her projeye taşır: `npx crewforth --preset strict` (ya da `start.sh --preset`, `adopt.sh --preset`) onu kurulumda uygular, sonradan `bash .claude/eval/lib/preset.sh --apply <ad|dosya.json>`. Üçü Crewforth ile gelir: `default` (boş, her anahtarı belgeler), `strict` (altyapı, deploy ve CI yolları kritik; review, test yazımı ve denetimler Opus'ta) ve `solo` (yaygın test komutları verify komutu olarak izinli).

Bir preset yalnız kapıların zaten okuduğu şeyi tutar: `critical.add` / `critical.remove` (yollar), `floors` (`[agent, change, risk, model]`, bir iş sınıfının en az modeli), `verify` (model kapısının koşabileceği komutlar) ve `lang`. `.claude/crew-model-rules` dosyasının başına işaretli tek bir blok olarak yazılır, projenin kendi satırları altında kalır: projenin `- glob`'u preset'in `+ glob`'unu geri alır, taban ise yalnız yükselir; yani preset, projenin yükseltebileceği ama düşüremeyeceği bir alt sınır koyar. Geçersiz bir preset, hiçbir şey kurulmadan reddedilir. `doctor` yürürlükteki preset'i adıyla söyler.
