# whitebox build-editor (port of build-editor.mjs). Environment: WB_SRC WB_OUT WB_TEMPLATE WB_APPLYCMD
# The tree is re-serialised like JSON.stringify(JSON.parse(...)) (compact) with "<" escaped, and embedded into the page.

BEGIN {
  initcommon()
  src = ENVIRON["WB_SRC"]; JOUT = ENVIRON["WB_OUT"]
  t = slurp(ENVIRON["WB_TEMPLATE"])
  if (!SL_OK) { print "Error: ENOENT: no such file or directory, open '" ENVIRON["WB_TEMPLATE"] "'" > "/dev/stderr"; exit 1 }
  i = index(t, "__APPLY_CMD__")
  if (i > 0) t = substr(t, 1, i - 1) ENVIRON["WB_APPLYCMD"] substr(t, i + 13)
  i = index(t, "__TREE__")
  if (i > 0) { pre = substr(t, 1, i - 1); post = substr(t, i + 8) } else { pre = t; post = "" }
  printf "%s", pre > JOUT
  JMODE = "min"
  if (!jstream(src)) { print "Error: ENOENT: no such file or directory, open '" src "'" > "/dev/stderr"; close(JOUT); exit 1 }
  printf "%s", post > JOUT
  close(JOUT)
  exit 0
}
