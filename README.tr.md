<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo.svg">
  <source media="(prefers-color-scheme: light)" srcset="assets/logo-light.svg">
  <img src="assets/logo.svg" alt="Crewforth" width="420">
</picture>

![Sürüm](https://img.shields.io/badge/version-3.1.0-6D28D9?style=flat-square)
![Lisans](https://img.shields.io/badge/license-MIT-5c6472?style=flat-square)

[🇬🇧 English](README.md) · 🇹🇷 Türkçe

**Crewforth, Claude Code için mühendislik ekibinizdir.**

Claude Code'a subagent'lar, skill'ler, komutlar ve hook'lar ekler: her biri bir alanın sahibi olan 12 uzman ajan,<br>
yöntemi taşıyan 40 skill, `/crew-…` ile başlattığınız 10 komut ve önemli kuralları uygulayan hook'lar.

https://github.com/user-attachments/assets/ce17e971-c447-4147-8b33-6f4bda419821

[crewforth.com](https://crewforth.com/#overview)'da da izleyebilirsiniz

</div>

## Neden Crewforth

- **İş, sahibi olan uzmana gider.** Belirsiz bir istek kod yazılmadan önce planlanır, sunucu işi `crew-backend-expert`'e gider, riskli bir değişiklik de `crew-security-expert` incelemeden kapanmaz. Bir yönlendirme hook'u, isteğinizin yanına işin sahibini yazar.
- **Önemli kurallar akılda tutulmaz, kapılarla uygulanır.** Yıkıcı bir komut çalışmadan reddedilir, commit onayınızı bekler, sızmış bir anahtar geçmişe girmez.
- **Her sonuç ölçülür ve yayımlanır; tutmayanlar da.** Aynı istek Crewforth ile ve onsuz koşturulur, ikisi de diskte bıraktığına göre puanlanır. [Nasıl ölçüyoruz](#nasıl-ölçüyoruz) bölümüne bakın.

## Hızlı başlangıç

```bash
npx crewforth init              # yeni proje kurar
npx crewforth add <agent|skill> # yalnız bir ajan ya da skill ekler
npx crewforth studio            # Studio panelini açar
```

Hiçbir şey yazılmadan önce bir özeti onaylarsınız; `add` tam kurulum yapmadan `./.claude` içine kopyalar. Hâlihazırda çalışılan bir depoda `npx crewforth adopt` her şeyi ayrı bir dala, staged ve commit'lenmemiş olarak getirir; `main` dalına dokunulmaz. Ardından Claude Code'da `/crew-doctor` çalıştırıp kurulumu doğrulayın.

## Bir oturum nasıl akar

<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/flow-tr-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="assets/flow-tr-light.svg">
    <img src="assets/flow-tr-light.svg" alt="Komut akışı: /crew-plan, uzmanlar, /crew-review, senin onayınla /crew-ship, /crew-handoff" width="880">
  </picture>
</div>

| Adım | Komut | Ne olur |
|:--|:--|:--|
| Planla | `/crew-plan` | `crew-planner` isteği kabul kriterli görevlere böler |
| Yap | (yönlendirilir) | işin sahibi ajan değişikliği yazar ve skill'lerini uygular |
| İncele | `/crew-review` | güvenlik, gizlilik, performans ve test denetimleri paralel koşar |
| Teslim et | `/crew-ship` | `crew-review-agent` temiz incelemeyi kaydeder; `crew-commit-agent` commit'i önerir ve onayınızı bekler |
| Devret | `/crew-handoff` | `handoff` durumu bir sonraki oturum için yazar |

Toplam **12 komut**, her biri kendi `/crew-…` adıyla başlatılır: `/crew-plan`, `/crew-review`, `/crew-ship`, `/crew-handoff`, `/crew-brainstorm`, `/crew-update`, `/crew-doctor`, `/crew-gates`, `/crew-skill`, `/crew-studio`, `/crew-approve`, `/crew-loosen`.

## Ajanlar

**12 uzman ajan** var; her biri işin kime ait olduğunu ve ne zaman devreye girdiğini söyler. Yöntem skill'lerde durur: [crewforth.com/tr/skills](https://crewforth.com/tr/skills).

| Ajan | Sahip olduğu alan |
|:--|:--|
| `crew-planner` | istek belirsizken kapsam ve kabul kriterleri |
| `crew-backend-expert` | sunucu, API ve iş mantığı; yığın fark etmez |
| `crew-database-expert` | şema, migration, indeks ve önbellek |
| `crew-frontend-expert` | web ve mobilde arayüz, bileşen ve istemci işi |
| `crew-devops-expert` | dağıtım, CI hattı ve olay müdahalesi |
| `crew-security-expert` | auth, injection ve sırlar; güvenlik açısından kritik değişikliklerde zorunlu |
| `crew-privacy-agent` | KVKK, GDPR ve projenin bildirdiği rejimler altında kişisel veri |
| `crew-test-expert` | test, kapsam ve regresyon |
| `crew-performance-expert` | sıcak yol, sorgu, render ve payload |
| `crew-review-agent` | bir commit'in ihtiyaç duyduğu kod sağlığı incelemesi |
| `crew-commit-agent` | onayınızı bekleyen commit önerisi |
| `crew-session-manager` | oturum doluluğu ve devir |

## Kapılar

| Kural | Neyle uygulanır |
|:--|:--|
| Commit ve push her izin modunda onayınızı ister; `auto` ve `dontAsk` modunda onay sizin yazdığınız bir komuttur: `/crew-approve commit`. Kapı onay yolunun kapalı olduğunu söylerse (kayıt hook'u bağlı değil; örneğin eski bir Crewforth taşıyan worktree) Shift+Tab'a basın ya da kendi terminalinizden commit edin | `guard-bash.sh` ve `prompt-approval.sh` |
| Bir commit, tam olarak kendi diff'i için temiz bir inceleme ister | `guard-bash.sh` ve `crew-review-agent`'ın yazdığı kayıt |
| Yıkıcı komutlar (`reset --hard`, force push, `rm -rf`, `--no-verify`) reddedilir | `guard-bash.sh` |
| Bir `crew-*` ajanı bir iş kartıyla (dosyalar, değişiklik türü, verify komutu) ve kartın riskine uyan modelle çağrılır: kritik iş (auth, ödeme, migration, güvenlik…) `opus`'ta, hiçbir komutun doğrulayamadığı iş en az `sonnet`'te, `haiku` yalnız bir komutun denetlediği işte. `opus`'ta olmayan ajan kritik yola yazamaz. `CREW_MODEL_ROUTING=off` bunu kapatır | `guard-agent-model.sh`, `guard-write.sh` |
| Ajanın işi durduğunda doğrulanır: ilk kırmızıda ajan düzeltir; ikincide iş bir üst modelle tekrarlanır ve aynı model reddedilir; orada da kırmızıysa size sorulur | `agent-outcome.sh` ve `guard-agent-model.sh` |
| Yapay zekâ imzası commit'e girmez | `pre-commit` ve `commit-msg` git hook'ları |
| API anahtarı, token ya da özel anahtar commit'e girmez | `pre-commit` sır taraması |
| Bir kapıyı kapatmak için kapı dosyası düzenlenemez ya da silinemez | `guard-write.sh` |

Bütün hook'lar ve kurallar: [crewforth.com/tr/gates](https://crewforth.com/tr/gates). Kapılar kazaları durdurur, kararlı denemeleri değil; kesin bir sınır için devcontainer ya da sanal makine kullanın.

## Studio

Studio, delegasyonu olurken çizen yerel bir panel; üç görünümü var: kimin kimi başlattığını gösteren bir grafik, aynı ajanları saate karşı gösteren bir zaman çizelgesi ve size ihtiyacı olana göre sıralı bir liste. Bir ajanı seçince ne yaptığı, ne harcadığı ve ne bildirdiği açılır. Her oturum süresini, token'ını ve bunların API liste fiyatıyla tahmini maliyetini gösterir; her ajan hangi modelle çalıştığını söyler. Panelden başlatılan oturum her araç çağrısından önce onay dock'unda sorar; cevaplanmayan istek reddedilir. Terminalde başlatılan oturum cevabını orada alır; panel hangi çağrı için beklediğini söyler. Makinedeki bütün Claude Code oturumlarını okur, `/crew-studio` ya da `npx crewforth studio` ile açılır ve yalnızca `127.0.0.1`'e bağlanır. Ayrıntılar: [crewforth.com/tr/studio](https://crewforth.com/tr/studio).

## Kurulum ve güncelleme

| Kanal | Komut |
|:--|:--|
| npx | yeni proje için `npx crewforth init`, mevcut proje için `npx crewforth adopt` |
| Claude Code plugin | `/plugin marketplace add Crewforth/crewforth`, ardından `/plugin install crewforth@crewforth` |
| Node yoksa | GitHub release arşivi, bkz. [crewforth.com/tr/install](https://crewforth.com/tr/install) |

**Gereksinimler:** Claude Code 2.1.214 veya sonrası (2.1.282 ile test edildi) ve `npx` için Node.js 20 veya sonrası (22 ya da 24 önerilir).

**2.x plugin'inden mi geliyorsunuz?** Plugin'in ve marketplace'in adı değişti, bu yüzden 2.x kurulumu 3.0'a kendiliğinden güncellenmez. Bir kez geçin:

```
/plugin uninstall claude-starter-kit
/plugin marketplace add Crewforth/crewforth
/plugin install crewforth@crewforth
```

Yeni bir sürüm yayımlandığında Claude, oturumun başında bir kez şimdi mi, sonra mı güncelleneceğini ya da o sürümün atlanıp atlanmayacağını sorar; kendiliğinden asla güncellemez. `/crew-update` güncellemeyi çalıştırır ve neyin değiştiğini söyler; `./CLAUDE.md` dosyanıza dokunulmaz. Eski bir sürümün kurduğu ve Crewforth'un artık dağıtmadığı bileşenler değişmemişse `.claude/.legacy-backup/` altına taşınır ve tek satırlık bir geri alma komutu basılır; değiştirdikleriniz yerinde kalır ve adıyla bildirilir. `.claude/` altında Crewforth'a ait üç dosya (`DISCIPLINE.md`, `AGENT_TEMPLATE.md`, `README.md`) her güncellemede yenilenir; düzenlediğiniz bir kopya önce `.claude/.legacy-backup/` altında saklanır ve adıyla bildirilir. Windows'ta Git Bash kullanın; kapılar yalnız Claude Code onu bulduğunda çalışır. Bulamadığında yazan ve komut çalıştıran araçlar durdurulur; mesaj ve `/crew-doctor` ayarlanacak yolu söyler. Bütün seçenekler: [crewforth.com/tr/install](https://crewforth.com/tr/install).

## Nasıl ölçüyoruz

Aynı isteği Crewforth kurulu bir projede ve çıplak bir projede koşturuyor, ikisini de diskte bıraktığına göre puanlıyoruz. Bir sonucun sağlaması gereken kural koşudan önce yazılıyor. Her sonuç gerekçesiyle yayımlanıyor, o kuralın tutmadığı sonuçlar da: [`evals/README.md`](evals/README.md).

## Katkı, lisans ve bağlantılar

Issue ve pull request'ler [github.com/Crewforth/crewforth](https://github.com/Crewforth/crewforth) adresinde. Yeni bir ajan ya da skill `kit/AGENT_TEMPLATE.md` sözleşmesine uyar ve `bash packaging/verify.sh` geçmelidir.

MIT, [LICENSE](LICENSE) dosyasına bakın.

- **Belgeler:** [crewforth.com/tr](https://crewforth.com/tr)
- **Oturum ve maliyet:** [crewforth.com/tr/sessions-and-cost](https://crewforth.com/tr/sessions-and-cost)
- **Doğrulama:** [crewforth.com/tr/verification](https://crewforth.com/tr/verification)
- **Genişletme:** [crewforth.com/tr/extending](https://crewforth.com/tr/extending)
