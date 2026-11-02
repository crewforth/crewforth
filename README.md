# stats

Append-only ledger of this project's distribution reach, one JSON object per line in `stats.jsonl`,
written weekly by `.github/workflows/stats.yml`.

It exists because GitHub's traffic API keeps only a **fourteen day** window: clone and view counts
older than that are deleted and cannot be recovered. npm and release-asset totals are permanent and
are recorded alongside so the numbers can be read against each other.

Reading the rows:

- `npm.by_version` — most of every version's weekly downloads are **mirror traffic**, a similar
  baseline on versions nobody installs. The signal is the spike on the current version above it.
- `npm.current_version_downloads` lags a release by a few days: npm's window closes before a
  just-published version has been out a full week.
- `github.traffic` is `null` when the run had no `Administration: read` token. Null means *not
  measured* — it is deliberately not written as zero.
- `installs.by_day_version` is the install-count Worker's whole map (`"day|version": count`), one
  count per project that ran `npx crewforth init`. `installs.last_week` sums the last seven days
  without the `0.0.0-*` deploy checks. It is a lower bound, and `null` means not measured.
- Runs overlap (weekly capture, fourteen-day window), so `daily` arrays repeat days. Deduplicate by
  date when aggregating.

This branch has its own root history and shares no commits with `main`.
