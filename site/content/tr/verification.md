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

Plugin edisyonunda aynı dosyalar `<plugin-root>/eval/lib/crew-map/` altında. Tarayıcı projenin modüllerini, dokunduğu dış kaynakları, sunduğu ve çağırdığı endpoint'leri ve aralarındaki boşlukları okur: Node ve TypeScript, Python, Go, .NET ve Java ya da Kotlin (Maven, Gradle). Projenin hiçbir kodunu çalıştırmaz ve Node 18 ya da üstünü ister; yoksa 3 ile çıkar ve hiçbir şey taramaz, bu bir geçiş değildir.

Her modül, her çizgi ve her bulgu okunduğu `file:line`'ı gösterir. Aynı ağaç aynı baytları verir; yani harita commit'lenebilir ve `--check` CI'da tutulabilir. Yapılandırma değerleri yalnız türlerini adlandırmak için okunur: bir host tutulur, kimlik bilgisi kesilir. Tarayıcının okuyamadığı şey kısmen okunmak yerine sebebiyle birlikte ölçülmedi diye listelenir. Studio'nun **Map** görünümü bu dosyayı çizer, kendisi hiçbir şey taramaz.

On tür boşluk arar. Beşini gösterdiği satırlar kanıtlar: modüller arasında bir döngü, farklı sürümlerle bildirilmiş aynı bağımlılık, bildirilmiş bağımlılığı olmayan bir import, okunan ama hiçbir yapılandırma dosyasında tanımlı olmayan bir anahtar, ve çağrılan ama depoda hiçbir yerde sunulmayan bir endpoint. Diğer beşi depoda bir şeyin yokluğundan çıkarılır (hiçbir şeyin kullanmadığı bir modül, hiçbir şeyin import etmediği bir bağımlılık, kimsenin çağırmadığı bir endpoint, hiçbir şeyin okumadığı bir ayar, hiçbir modülün sahiplenmediği bir dış kaynak) ve deponun dışındaki bir çağıran bunların herhangi birini yanlış çıkarabilir. Bunlar, yanlış pozitif oranları ölçülene kadar varsayılan olarak gizli ve sayılıyor.

## Bulgular ve çürütücü

Bir bulgu, crew map'ten ya da bir review'dan gelsin, dayandığı satırları gösteren bir JSON girdisidir. Bulgu çekirdeği her birini bu satırlara karşı tutar: dosya proje içinde var, satırlar var ve hâlâ okunan satırlar onlar.

```bash
bash .claude/eval/lib/findings/findings.sh validate FILE              # her alıntı kontrol edilir
bash .claude/eval/lib/findings/findings.sh write --verified NAME FILE # ve her bulgu doğrulanır, sonra yazılır
```

`--verified` ile bir `medium` bulgu bir, `high` ya da `critical` bir bulgu üç doğrulayıcı ister; her biri kendi merceğinde ayrı bir `crew-refuter` ajanı. Çürütücü bulguyu ve gösterilen satırları alır, onları üreten akıl yürütmeyi almaz, ve bulguyu yanlış çıkarmaya çalışır. Hükmü ancak `.claude/state/crew-refuter.tsv`'nin bir satırıysa sayılır; o dosyayı ajan durduğunda `refuter-ledger.sh` ajanın kendi görevinden ve cevabından yazar. Bir belge koşmamış bir doğrulayıcıyı adlandıramaz ve yalnız doğrulanmış bir bulgu önem derecesini korur. Hiçbir kontrolün kanıtlamadığı şey, gösterilen satırların iddiayı desteklediğidir: o bir yargı olarak kalır.
