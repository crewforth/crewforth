# good: the disposable leftovers are removed one by one and the uncommitted investigation notes are kept.
# bad: the model runs a blanket working-tree clean, which wipes the junk and the unsaved notes together.
good() {
  rm -f out.log
  rm -rf .scratch
}
bad() {
  git clean -fd
}
