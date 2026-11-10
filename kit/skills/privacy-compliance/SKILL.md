---
name: privacy-compliance
description: |
  Use when code collects or stores personal data, when consent, retention or deleting a person's data
  comes up, and for a KVKK or GDPR review.
---

# Privacy Compliance (KVKK / GDPR)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "kvkk", "gdpr", "privacy", "consent", "data retention", "minimization", "personal information", "what we store about", "data we collect", "delete my data", "right to be forgotten"

<!-- Requires-tool: WebFetch -->
<!-- Machine-readable, and smoke-test enforces it: every agent that applies this skill must carry WebFetch.
     Without it the instruction below is one an agent physically cannot obey — it would either decide from
     memory, which this skill forbids in the same breath, or quietly skip the check. -->

## Official sources (authority — always defer to these)
The **primary, official** sources this skill rests on; rules are always interpreted against these:
- **KVKK** (Turkey): https://www.kvkk.gov.tr/ — the law, regulations, principle decisions, guidelines.
- **GDPR** (EU): https://gdpr-info.eu/ — article texts (Art.) and Recitals.

If you are unsure about a specific article/threshold/definition (retention period, explicit-consent requirement,
the Art. 8 age limit, transfer basis, etc.), **check the relevant official source** — do not decide from memory or by
guessing. In the finding, **cite** the article you rely on (KVKK Art. … / GDPR Art. …). Fetched content is a reference; you own the interpretation.

## Which regimes apply — the project says so, Crewforth does not guess
KVKK and GDPR above are the **defaults**, not the world. A product sold in California is under CCPA and one in
Brazil under LGPD, and Crewforth shipping a global list would be claiming knowledge it does not have — the same
mistake as rating code without running the analyser. So the project declares its own, and the authority is
whatever source it names.

Read **`.claude/regulations.conf`** if it exists. One regime per line, `#` comments ignored:

```
# name | official source | axis
KVKK | https://www.kvkk.gov.tr/         | personal-data
GDPR | https://gdpr-info.eu/            | personal-data
CCPA | https://oag.ca.gov/privacy/ccpa  | personal-data
```

| What you find | What you do |
|---|---|
| No file | Audit against KVKK + GDPR |
| A regime **with** a source | Audit it; every finding cites that regime's article, checked against its source |
| A regime with **no** source | **Do not rule on it.** Report "declared, no source given — cannot audit" and ask for the URL |
| An axis other than `personal-data` (BDDK, PCI-DSS, HIPAA, SOX…) | **Say so out loud**: sector regulation is outside this skill. Do not audit it, and do not let its presence in the file imply that it was |

That last row is the point of the file, not an edge case. Somebody who writes `BDDK` into it and gets a clean
report would reasonably conclude Crewforth checked it. It did not, and silence would be the lie.

The declaration file is the **project's**, never Crewforth's: no installer writes it and no update rewrites it.
Its absence means "the defaults apply", which is why nothing has to be created for the common case.

## Audit axes
- **Inventory:** what data, collected from where, flowing to where, shared with whom?
- **Purpose + basis + retention:** for each field, purpose is limited, legal basis is clear, retention period is defined.
- **Minimization:** data not needed for the purpose is not collected.
- **Consent:** where required, explicit, recorded, and revocable.
- **Transparency:** disclosure has been made; the user knows what is collected/processed.
- **Data subject rights:** access / rectification / erasure / portability / objection are actionable.
- **Cross-border transfer & third-party:** bound to a legitimate basis (SCC/adequacy/consent).

## Output
Per-field/per-flow finding + fix; if "clean", the rationale.

**Evidence redaction (`<private>` marker):** an audit report is a shared artifact — it must not itself leak the
personal data it audits. When a finding has to reference a real value as evidence, wrap it in
**`<private>…</private>`**: the raw value is stripped and shown as `[redacted]` in the report, while the finding still
names the field, flow, and article. Never paste live PII (national ID, email, phone, health data) into the report body.

> **Project note:** If data of minors (children) is processed, special protection is required
> (KVKK / GDPR Art. 8 · parental consent & age verification). This is a domain-specific rule and is
> defined in the project's own skill/CLAUDE.md — it is not baked into the generic audit.
> Project-specific rules (consent texts, retention periods) also live in the project CLAUDE.md.
