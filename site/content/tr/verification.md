# Doğrulama

```bash
bash .claude/eval/smoke-test.sh      # yapı, frontmatter, kapı bütünlüğü
bash .claude/eval/routing-eval.sh    # örnek bir istek doğru ajana ya da skill'e ulaşıyor mu
bash .claude/eval/doctor.sh          # bu kurulum sağlıklı mı, proje hazır mı
bash .claude/eval/preflight.sh       # bu makinede hangi araçlar var, olmayanlar neyi zayıflatıyor
```

`preflight.sh` ayrıca `start.sh`, `adopt.sh` ve `doctor.sh` içinden de koşar. Crewforth ne `jq` ne `python` ister: her JSON okuma ve yazma, her hook ve her kurulum adımı tek bir bash/awk yolundan geçer; macOS, Linux ve sıfır bir Windows Git Bash aynı kodu koşar, aynı sonucu alır. Hâlâ isteğe bağlı olan bir araç eksikse Crewforth kırılmaz, kabiliyet düşürerek devam eder: `sha256sum` yoksa `cksum`'a iner. Doğru tasarım bu, ama aynı zamanda bir eksiğin kendini hiç duyurmamasının da sebebi. Preflight eksiği ve bedelini adıyla söyler. Yalnızca rapor eder; makinenize hiçbir şey kurmaz ve hiçbir çalıştırmayı engellemez.

## Gerçekten bir şey değiştiriyor mu?

Aynı istek hem Crewforth kurulu hem de çıplak bir projede koşturuluyor ve her birinin diskte bıraktığına göre puanlanıyor. Bir sonucun sağlaması gereken kural koşudan önce yazılıyor. Her ölçüm gerekçesiyle [`evals/README.md`](../../../evals/README.md) içinde yayımlanıyor; o kuralın tutmadığı ölçümler de dahil.

## Crew map

```bash
bash .claude/eval/lib/crew-map/crew-map.sh            # tara, .crewforth/crew-map.json'u yaz
bash .claude/eval/lib/crew-map/crew-map.sh --stdout   # tara, haritayı bas, hiçbir şey yazma
bash .claude/eval/lib/crew-map/crew-map.sh --check    # dosya şimdiki taramanın yazacağıyla aynıysa 0, değilse 1
```

Plugin edisyonunda aynı dosyalar `<plugin-root>/eval/lib/crew-map/` altında. Tarayıcı projenin modüllerini, dokunduğu dış kaynakları, sunduğu ve çağırdığı endpoint'leri ve aralarındaki boşlukları okur: Node ve TypeScript, Python, Go, .NET, Java ya da Kotlin (Maven, Gradle) ve Dart (bir Flutter uygulaması tek modüldür, `android/` ve `ios/` klasörleri onun platformlarıdır). Her modül için neyle yapıldığını (Hono, Cloudflare Workers, Flutter, Riverpod: manifestin bildirdiği bir paket ya da kökündeki bir dosya, `rules/tech.json`'dan) ve içinde ne olduğunu (klasörleri ve her birindeki kaynak dosya sayısı, testler ayrı) da söyler. Kendi dağıtım dosyasının adını verdiği bir host'ta yayın yapan modülü (wrangler route'ları, `fly.toml`), o host'u tırnak içinde ya da bir URL'nin host'u olarak yazan her modül çağırır; bu çağrı dış API olarak değil modülden modüle çizilir. Buradaki hiçbir okuyucunun bilmediği bir dildeki kaynak, Swift gibi, ölçülmedi diye listelenir. Projenin hiçbir kodunu çalıştırmaz ve Node 18 ya da üstünü ister; yoksa 3 ile çıkar ve hiçbir şey taramaz, bu bir geçiş değildir.

Her modül, her çizgi ve her bulgu okunduğu `file:line`'ı gösterir. Aynı ağaç aynı baytları verir; yani harita commit'lenebilir ve `--check` CI'da tutulabilir. Yapılandırma değerleri yalnız türlerini adlandırmak için okunur: bir host tutulur, kimlik bilgisi kesilir. Tarayıcının okuyamadığı şey kısmen okunmak yerine sebebiyle birlikte ölçülmedi diye listelenir. Studio'nun **Map** görünümü bu dosyayı çizer, kendisi hiçbir şey taramaz.

`/crew-map` taramayı koşar, ardından modele onu tarif ettirir: her modüle ne için var olduğunu söyleyen en fazla iki cümle, projeye de kısa bir genel bakış; her biri taramanın kendisinin o düğüm için okuduğu `file:line` satırlarına atıf yapar. `crew-map.sh --validate` başka bir yere ya da hiçbir yere atıf yapan, iki cümleyi aşan ya da elle değiştirilmiş bir tarayıcı alanıyla gelen tarifi reddeder. Yeniden tarama, satırlarına hâlâ atıf yaptığı tarifleri korur, satırları kaymış olanları atar ve kaç tane olduğunu söyler; `--check` tarifleri karşılaştırmaya katmaz. Komut hiçbir zaman commit etmez.

On tür boşluk arar. Beşini gösterdiği satırlar kanıtlar: modüller arasında bir döngü, farklı sürümlerle bildirilmiş aynı bağımlılık, bildirilmiş bağımlılığı olmayan bir import, okunan ama hiçbir yapılandırma dosyasında tanımlı olmayan bir anahtar, ve çağrılan ama depoda hiçbir yerde sunulmayan bir endpoint. Diğer beşi depoda bir şeyin yokluğundan çıkarılır (hiçbir şeyin kullanmadığı bir modül, hiçbir şeyin import etmediği bir bağımlılık, kimsenin çağırmadığı bir endpoint, hiçbir şeyin okumadığı bir ayar, hiçbir modülün sahiplenmediği bir dış kaynak) ve deponun dışındaki bir çağıran bunların herhangi birini yanlış çıkarabilir. Bunlar, yanlış pozitif oranları ölçülene kadar varsayılan olarak gizli ve sayılıyor.

## Bulgular ve çürütücü

Bir bulgu, crew map'ten ya da bir review'dan gelsin, dayandığı satırları gösteren bir JSON girdisidir. Bulgu çekirdeği her birini bu satırlara karşı tutar: dosya proje içinde var, satırlar var ve hâlâ okunan satırlar onlar.

```bash
bash .claude/eval/lib/findings/findings.sh validate FILE              # her alıntı kontrol edilir
bash .claude/eval/lib/findings/findings.sh write --verified NAME FILE # ve her bulgu doğrulanır, sonra yazılır
```

`--verified` ile bir `medium` bulgu bir, `high` ya da `critical` bir bulgu üç doğrulayıcı ister; her biri kendi merceğinde ayrı bir `crew-refuter` ajanı. Çürütücü bulguyu ve gösterilen satırları alır, onları üreten akıl yürütmeyi almaz, ve bulguyu yanlış çıkarmaya çalışır. Hükmü ancak `.claude/state/crew-refuter.tsv`'nin bir satırıysa sayılır; o dosyayı ajan durduğunda `refuter-ledger.sh` ajanın kendi görevinden ve cevabından yazar. Bir belge koşmamış bir doğrulayıcıyı adlandıramaz ve yalnız doğrulanmış bir bulgu önem derecesini korur. Hiçbir kontrolün kanıtlamadığı şey, gösterilen satırların iddiayı desteklediğidir: o bir yargı olarak kalır.

## Review ön geçişi

Review ajanı bir değişikliği okumadan önce, deterministik bir geçiş eklenen satırları okur ve bulduğunu aynı biçimde bulgu olarak yazar:

```bash
bash .claude/eval/lib/review-prepass/prepass.sh                  # staged değişiklik → .crewforth/review-prepass.json
bash .claude/eval/lib/review-prepass/prepass.sh --base origin/main  # bir dal, tabanına karşı
bash .claude/eval/lib/review-prepass/prepass.sh --stdout         # bas, hiçbir şey yazma
```

Dosyaya göre şunlara bakar: pre-commit kapısının gizli anahtar listesindeki bir desen (hash'iyle gösterilir, asla alıntılanmaz; `.secret-allowlist.txt` geçerlidir), JavaScript ya da TypeScript'te bırakılmış bir console çağrısı ya da debugger, Python'da bir breakpoint, Dart'ta `print(` (testlerde ve komut satırı betiklerinde değil), kodda eklenmiş bir yorumu açan TODO, FIXME, XXX ya da HACK (testlerde değil; bir dizedeki ya da desendeki sözcük işaret değildir), bir kabuk dosyasının eklenen satırlarındaki shellcheck bulguları, manifesti değişmeden değişen bir kilit dosyası ve tek dosyaya 500'den fazla satır eklenmesi. Staged olduktan sonra yeniden düzenlenmiş bir dosya, ikili bir dosya ve shellcheck olmayan makinedeki kabuk dosyaları ölçülmedi diye listelenir; hiçbir şey kurulmaz, Node yoksa 3 ile çıkar ve bu bir geçiş değildir.

Review ajanı bu dosyadan başlar ve kendi bulgularını yanına, `.crewforth/review.json`'a yazar; `critical` ya da `high` bir bulgu önce `crew-refuter`'dan geçer ve belge `--verified` ile yazılır. Geçişi koşturmak ve okumak review skill'inin disiplinidir: onu hiçbir hook koşturmaz.

## Review ne kadar isabetli

`review-bench`, review'u etiketli vakalarda koşturur ve sayar: kaç kusuru bulduğunu (recall), bulgularının kaçının bir kusurla ilgili olduğunu (precision) ve her yanlış alarmı adıyla.

```bash
bash .claude/eval/review-bench.sh --cases DIR                    # yalnız ön geçiş: model yok, maliyet yok
bash .claude/eval/review-bench.sh --cases DIR --arm agent --max-cost 5   # review ajanı; token harcar
```

Bir vaka bir dizindir: değişikliğin ne yaptığını söylediği, önceki ve sonraki dosyalar ve kusurun yeri. Crewforth'un kendi seti 27 vaka: geçmişinden bir düzeltme geri alınarak kurulmuş 16 kusur (düzeltmenin kendi açıklama yorumları çıkarılır, yani kusur koddan bulunmak zorundadır), sonradan hiçbir şeyin düzeltmek zorunda kalmadığı 6 değişiklik ve bir desenin görebileceği 5 yazılmış vaka; 8'i holdout. Ön geçişin bu vakalardaki tabanı bir CI kapısıdır: her desen vakası bulunur, yanlış alarm olmaz.

2026-10-16'da Sonnet ile, tek review geçişi, kullanıcının kendi ayarlarından yalıtılmış olarak ölçüldü: **20 kusurun 18'i bulundu** (holdout: 5'te 4) ve **49 bulgunun 34'ü kusurla ilgiliydi**; 27 vaka için 1,62 $. Eşleştirici konuma göre eşleştirir, bu yüzden 20'de 20 saydı: eşleşen iki bulgu doğru satırlara yorum yapıyordu ama kusuru adlandırmıyordu, ve elle kaçırılmış sayıldı. Yanlış alarmların çoğu temiz bir değişiklikte "bunu bir test kapsamıyor" idi. Her yanlış alarmıyla birlikte kayıt depoda `packaging/review-bench/results/2026-10-16-sonnet.json`.
