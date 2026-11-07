---
name: i18n-integrity
description: |
  Translation integrity: every key present in every language, no hardcoded strings, consistent placeholders
  and plurals. Runs when user-facing text changes.
---

# Translation Integrity (i18n)

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "i18n", "translation", "language file", "missing translation", "localization", "translate", "untranslated", "hardcoded string", "multi language", "multiple languages", "still in english", "locale"

Goal: no missing/broken text in any language. Languages: the set the project declares (e.g. in `CLAUDE.md` or the locale directory).

## Audit dimensions
- **Key parity:** every key has a counterpart in ALL languages; a missing/extra key = a finding.
- **No hardcoded strings:** user-facing text is not embedded in code, it comes from the language file.
- **Placeholder consistency:** `{name}`, `%s`, ICU `{count, plural, ...}` are identical in every language.
- **Plural rules:** language-specific plural forms (especially RU) are correct.
- **Assembled sentences:** a sentence built by concatenating pieces around a variable (`t('hello') + name + t('welcome')`),
  or a plural chosen by hand (`n === 1 ? … : …`), is a finding: word order and plural forms differ by language, so
  the whole sentence is one message with a placeholder (ICU / `Intl.PluralRules`).
- **Empty/identical value:** an untranslated (identical to the source) placeholder value is flagged.

## Check (key-set comparison)
```bash
# Example: compare the key sets of JSON language files
for f in locales/*.json; do echo "== $f =="; jq -r 'keys[]' "$f" | sort > "/tmp/$(basename $f).keys"; done
diff /tmp/tr.json.keys /tmp/en.json.keys   # differences = missing/extra keys
```

## DoD
- Key sets are equal across all languages; no hardcoded user text; placeholders are consistent.
- **Missing translation = red** (no deferral).
