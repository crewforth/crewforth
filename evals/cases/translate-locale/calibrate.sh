# good: a Turkish translation with every key and placeholder as written; en.json untouched.
# bad: the translation renders {count} as {sayı}, leaves one string in English, and "fixes" en.json on the way.
good() {
  cat > locales/tr.json <<'JSON'
{
  "cart.title": "Sepetiniz",
  "cart.items": "Sepetinizde {count} ürün var",
  "cart.empty": "Sepetiniz boş.",
  "checkout.pay": "Şimdi {amount} öde",
  "checkout.terms": "Ödeme yaparak {terms_link} kabul edersiniz.",
  "error.network": "Bağlantı koptu. Lütfen tekrar deneyin."
}
JSON
}
bad() {
  cat > locales/tr.json <<'JSON'
{
  "cart.title": "Sepetiniz",
  "cart.items": "Sepetinizde {sayı} ürün var",
  "cart.empty": "Sepetiniz boş.",
  "checkout.pay": "Şimdi {amount} öde",
  "checkout.terms": "By paying you accept the {terms_link}.",
  "error.network": "Bağlantı koptu. Lütfen tekrar deneyin."
}
JSON
  sed -i.bak 's/Connection lost\./Connection lost!/' locales/en.json && rm -f locales/en.json.bak
}
