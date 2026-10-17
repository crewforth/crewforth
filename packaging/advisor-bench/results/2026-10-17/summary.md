| | Sonnet + Opus advisor | Opus alone |
|:--|--:|--:|
| runs (not run) | 12 (0) | 12 (0) |
| defects caught | 6/6 | 5/6 |
| precision | 15/31 (48.4%) | 9/26 (34.6%) |
| false alarms | 16 | 17 |
| task done | 2/2 | 2/2 |
| errors | 0 | 0 |
| time, all runs | 515 s | 569 s |
| cost, all runs | $1.06 | $2.23 |
|   of it Opus | $0.00 | $2.23 |
| advisor calls | 0 | 0 |
| output tokens | 38103 | 43889 |

Sonnet + Opus advisor:
  clean-board-refusals caught=null claims=4 fa=4 $0.162 176s adv=0
  pattern-clean caught=null claims=3 fa=3 $0.059 24s adv=0
  printf-option-key caught=true claims=4 fa=0 $0.099 37s adv=0
  regex-not-import caught=true claims=1 fa=0 $0.069 30s adv=0
  sigpipe-grep-q caught=true claims=3 fa=0 $0.078 33s adv=0
  parse-duration done=true $0.077 20s adv=0
  clean-board-refusals caught=null claims=4 fa=4 $0.126 43s adv=0
  pattern-clean caught=null claims=4 fa=4 $0.058 24s adv=0
  printf-option-key caught=true claims=3 fa=1 $0.087 40s adv=0
  regex-not-import caught=true claims=2 fa=0 $0.084 34s adv=0
  sigpipe-grep-q caught=true claims=3 fa=0 $0.089 37s adv=0
  parse-duration done=true $0.070 18s adv=0

Opus alone:
  clean-board-refusals caught=null claims=2 fa=2 $0.246 58s adv=0
  pattern-clean caught=null claims=4 fa=4 $0.131 43s adv=0
  printf-option-key caught=true claims=3 fa=1 $0.179 58s adv=0
  regex-not-import caught=false claims=1 fa=1 $0.136 47s adv=0
  sigpipe-grep-q caught=true claims=2 fa=0 $0.201 61s adv=0
  parse-duration done=true $0.314 27s adv=0
  clean-board-refusals caught=null claims=4 fa=4 $0.286 73s adv=0
  pattern-clean caught=null claims=5 fa=5 $0.120 37s adv=0
  printf-option-key caught=true claims=2 fa=0 $0.157 46s adv=0
  regex-not-import caught=true claims=1 fa=0 $0.187 47s adv=0
  sigpipe-grep-q caught=true claims=2 fa=0 $0.164 46s adv=0
  parse-duration done=true $0.114 25s adv=0
