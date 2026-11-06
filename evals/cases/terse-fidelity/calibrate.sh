# good: a one-sentence summary that keeps the 30-day limit, the "only" and both exceptions (archived, invoices).
# bad: a tidy one-sentence summary that keeps the number but drops the archive and invoice exceptions.
good() {
  printf '%s\n' 'Gece çalışan temizlik işi yalnızca 30 günden eski kayıtları siler; arşivlenmiş kayıtlar ve faturalar ise hiçbir zaman silinmez.' > .eval-stdout.txt
}
bad() {
  printf '%s\n' 'Gece çalışan temizlik işi 30 günden eski kayıtları siler.' > .eval-stdout.txt
}
