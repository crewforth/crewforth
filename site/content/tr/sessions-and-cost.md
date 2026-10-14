# Oturum ve maliyet

Oturumun ne kadar dolduğu **ölçülür, tahmin edilmez**: her turda okunan gerçek token sayısı, `/context`'in verdiği değerin aynısı. **%{{FILL_WARN}}**'te bir uyarı, **%{{FILL_ALERT}}**'da bir tane daha; ikisi de turunuzu kesmez.

Sabit maliyet gizlenmiyor, yazıyor. Disiplin ile birlikte her ajan ve skill tarifi her oturuma yüklenir: `smoke-test.sh`'in ölçtüğü **{{ALWAYS_ON_BYTES}} bayt**. Aynı malzemenin 21.804 baytının 9.198 token ettiği gerçek bir `claude -p` turu oranı veriyor; bu oranla yaklaşık **{{ALWAYS_ON_TOKENS}} token**. Süitin kapı olarak tuttuğu sayı bayt rakamı. Eklediğiniz her skill, her oturuma **~100 token**'lık kalıcı bir vergi bindirir; bu yüzden bileşen başına bayt bütçesi bir kapı olarak uygulanır. Bütçeyi yükseltmek testte açık bir düzenleme ister.

**Neden daha az bileşen kurulmuyor?** Çünkü kazancı yok denecek kadar az. Bütün ajan ve skill tarifleri toplam {{DESC_BYTES}} bayt, aynı oranla yaklaşık **{{DESC_TOKENS}} token** tutar; dört UI skill'i ile frontend ajanını dışarıda bırakmak bunun {{UI_BYTES}} baytını, kabaca **{{UI_TOKENS}} token**'ı kazandırır. Bunu proje başına değil, bayt bütçesinin yaptığı gibi bileşen başına denetlemek anlamlı olan.

## İşi hangi model yapıyor

Bir oturumun maliyetinin çoğu, her işi koşan modeldir; bu yüzden model oturum başına değil iş başına seçilir. Bir `crew-*` ajanı bir kartla çağrılır (dosyalar, değişiklik türü, işi kanıtlayan komut) ve kararı kart verir: bir komutun denetlediği işte `haiku`, sıradan işte ve hiçbir şeyin doğrulayamadığı işte `sonnet`, kritik işte (migration, güvenlik, mimari, nedeni bilinmeyen hata ya da auth, ödeme, migration gibi yollardaki dosya) `opus`. Ajan durduğunda verify komutu koşar; iki kez düşen iş bir kez, bir üst modelle tekrarlanır. Yani küçük kalan bir model fazladan bir çalıştırmaya mal olur ve pahalı model ona ihtiyacı olan işe saklanır.

Bunun neye mal olduğu, çağrı başına bir satırla `.claude/state/model-outcomes.tsv` dosyasına yazılır ve projenizde kalır. Studio bunu okur (Studio sayfasına bakın): **Models** görünümü her iş türü için modeli, ilk denemenin ne sıklıkta geçtiğini, ne sıklıkta bir üst modelle tekrarlandığını ve API liste fiyatıyla tahmini maliyeti gösterir. İlk denemesi çok sık düşen bir sınıf o andan sonra bir üst modelde tutulur; karar verdiğinizde `/crew-loosen` onu yeniden indirir.

İki sınır. Bu yalnız `crew-*` ajanlarında uygulanır: Explore, general-purpose ve projenin kendi ajanları çağrılarının istediği modelde, istemediyse ana oturumun modelinde koşar ve kayda düşmez. Ve kapı taban zorlar, tavan zorlamaz: kart için küçük kalan modeli reddeder, işin gerektirdiğinden büyük olanı değil.

## Advisor

Claude Code'un advisor aracı, modelin iş ortasında ikinci ve genellikle daha güçlü bir modele danışmasını sağlar. Crewforth onu hiçbir zaman açmaz; `/crew-doctor` açık olup olmadığını, hangi modelde olduğunu ve hangi ayar dosyasından geldiğini söyler.

Maliyeti kendine ait. Her çağrı bütün konuşmayı advisor modelinin fiyatıyla ve önbelleksiz okur: ölçülen bir oturumda Sonnet'in iki cümlelik cevabı $0,06, arkasındaki tek advisor çağrısı $0,15 tuttu. API bu token'ları yanıtın üst düzey kullanımına katmaz. Claude Code onları `/usage`'da sayar; Studio'nun oturum maliyeti de ekler ve çağrı sayısı ile maliyetiyle bir **Advisor** satırı gösterir. Hiç çağrı olmayan oturumda bu satır yoktur.

Kartı izlemez. Danışacağı modelin altında kalan bir advisor hiç eklenmez; yani Sonnet advisor varken Opus'taki bir ajan (kritik iş) tavsiye almaz. Advisor `model-outcomes.tsv`'de yer almaz.

`/advisor off` ile, kalıcı olarak da `CLAUDE_CODE_DISABLE_ADVISOR_TOOL=1` ile kapatılır. Anthropic API ister; Amazon Bedrock, Google Cloud Agent Platform ya da Microsoft Foundry'de yoktur.
