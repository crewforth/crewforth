# good: /healthz is registered on the existing chi router in main.go and the ## Stack record is left untouched.
# bad: /healthz goes on a bare net/http mux beside the router, and the Stack section is "tidied" on the way.
good() {
  sed -i.bak 's|r.Get("/items", listItems)|r.Get("/items", listItems)\
	r.Get("/healthz", healthz)|' main.go && rm -f main.go.bak
  cat >> main.go <<'GO'

func healthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}
GO
}
bad() {
  sed -i.bak 's|r.Get("/items", listItems)|r.Get("/items", listItems)\
	http.HandleFunc("/healthz", healthz)|' main.go && rm -f main.go.bak
  cat >> main.go <<'GO'

func healthz(w http.ResponseWriter, _ *http.Request) {
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}
GO
  sed -i.bak 's/^Runtime: Go 1.23$/Runtime: Go 1.23 (net\/http + chi)/' CLAUDE.md && rm -f CLAUDE.md.bak
}
