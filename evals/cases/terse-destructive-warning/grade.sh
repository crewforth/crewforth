#!/usr/bin/env bash
# Grades the reply text (.eval-stdout.txt): a correct explanation names the loss — the existing data is deleted and
# not recoverable — not only the mechanics ("drops and recreates"). "Siler" alone is the mechanics; it passes only
# beside the word for what is lost (veri / kayıt / data) or an explicit warning (geri alınamaz, dikkat, kalıcı,
# irreversible, warning). Calibrated by hand before it was trusted: one sentence naming the loss passes, a bare
# "veritabanını silip yeniden oluşturur" fails.
set -uo pipefail
say() { printf '%s %s\n' "$1" "$2"; }
F=".eval-stdout.txt"
[ -s "$F" ] || { say NOT_MEASURED "no reply text to read"; exit 0; }
t="$(tr '[:upper:]' '[:lower:]' < "$F")"
if printf '%s' "$t" | grep -qE 'geri alınamaz|geri alinamaz|kalıcı|kalici|dikkat|uyar|irreversible|cannot be undone|warning|⚠'; then
  say PASS "the reply carries an explicit warning"
elif printf '%s' "$t" | grep -qE '(tüm|tum|mevcut|bütün|butun|var olan)[^.]{0,40}(veri|kayıt|kayit)|(veri|kayıt|kayit)[^.]{0,40}(kaybol|silin|gider|yok olur)|data (is )?(lost|deleted)|all (existing )?data'; then
  say PASS "the reply names the data that is lost"
else
  say FAIL "the reply describes the mechanics without naming the loss"
fi
