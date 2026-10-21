# Ajanlar ve skill'ler

Beş aşamaya yayılmış **{{AGENT_COUNT}} uzman ajan** var. Kalite, hiçbir şey commit edilmeden önce basamak basamak yükseliyor.

<div align="center" class="cf-diagram">
  <img class="cf-only-dark" src="../../../assets/stages-tr-dark.svg" alt="Bir değişiklik nasıl ilerler: Anla, Üret, Denetle, senin onayınla Kapat, Devret" width="900">
  <img class="cf-only-light" src="../../../assets/stages-tr-light.svg" alt="Bir değişiklik nasıl ilerler: Anla, Üret, Denetle, senin onayınla Kapat, Devret" width="900">
</div>

| Ajan | Aşama | Ne zaman devreye girer |
|:--|:--|:--|
| `crew-planner` | Anla | kapsam belirsizse |
| `crew-backend-expert` | Üret | sunucu / API / iş mantığı |
| `crew-database-expert` | Üret | şema, migration, indeks, önbellek |
| `crew-frontend-expert` | Üret | arayüz, bileşen, istemci işi |
| `crew-devops-expert` | Üret | dağıtım, CI hattı, olay müdahalesi |
| `crew-docs-agent` | Üret | README, kılavuz, sürüm notları, yasal ve gizlilik metinleri, mağaza metinleri |
| `crew-security-expert` | Denetle | auth / IDOR / injection / sır · **güvenlik kritikse zorunlu** |
| `crew-privacy-agent` | Denetle | kişisel veri: KVKK/GDPR ve projenin beyan ettiği diğer rejimler |
| `crew-test-expert` | Denetle | test, kapsam, regresyon |
| `crew-performance-expert` | Denetle | sıcak yol, sorgu/döngü, render, payload |
| `crew-refuter` | Denetle | orta ve üstü bir bulgu, raporlanmadan önce: onu çürütmeye çalışır |
| `crew-review-agent` | Kapat | commit öncesi kod sağlığı incelemesi |
| `crew-commit-agent` | Kapat | commit'i önerir, onayı bekler |
| `crew-session-manager` | Devret | bağlam dolduğunda / aşama bittiğinde |

**Modeller sabitlenmiyor.** Her ajan, oturum için seçtiğiniz modelde koşuyor; böylece bir değişikliği onaylayan inceleme, o değişikliği yazandan hiçbir zaman zayıf olmuyor. İki istisna var: `crew-security-expert` fazladan titizliği `effort: high` ile alıyor, `crew-commit-agent` ise `haiku` kullanıyor, çünkü staged bir diff'i Conventional Commit'e çevirmek mekanik bir iş. Projeniz başka bir şey istiyorsa ajanın frontmatter'ından değiştirebilirsiniz.

## {{SKILL_COUNT}} skill'in tamamı

<div align="center" class="cf-diagram">
  <img class="cf-only-dark" src="../../../assets/network-tr-dark.svg" alt="Hangi ajan hangi skill'i uygular: aşamaya göre {{AGENT_COUNT}} ajan ve {{SKILL_COUNT}} skill" width="900">
  <img class="cf-only-light" src="../../../assets/network-tr-light.svg" alt="Hangi ajan hangi skill'i uygular: aşamaya göre {{AGENT_COUNT}} ajan ve {{SKILL_COUNT}} skill" width="900">
</div>

Aşağıdaki katalog, site derlenirken her skill'in kendi dosyasından üretilir; elle düzenlemeyin.

<!-- CATALOGUE -->
