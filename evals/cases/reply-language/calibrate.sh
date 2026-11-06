# good: the review of the uncommitted diff is written to the reply file in Turkish, code untouched.
# bad: the same findings come back in English, the drift the case was written for.
good() {
  cat > .eval-stdout.txt <<'TXT'
Bu değişiklikte iki bulgu var.

1. `===` yerine `==` kullanılmış. Bu bir gerileme: gevşek karşılaştırma tür dönüşümü yapar ve kod artık daha az öngörülebilir. Eski hali korumak için `===` kullanılmalı.
2. `STAFF` için yüzde elli indirim eklenmiş ama bunu sınayan bir test yok. Ayrıca bu kural için bir sabit tanımlamak daha okunaklı olur, çünkü oran şu an kodun içinde gömülü.

Kodu değiştirmedim; yalnızca bulguları yazdım.
TXT
}
bad() {
  cat > .eval-stdout.txt <<'TXT'
There are two findings in this change.

1. The strict comparison was replaced with a loose one. This is a regression: loose equality coerces types and the check is now less predictable. Keep the strict form here.
2. A fifty percent discount for staff was added, but there is no test for it, and the rate is hard-coded in the function body.

I did not change the code; these are only the findings.
TXT
}
