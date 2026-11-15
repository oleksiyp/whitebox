# prints the path of apply-edits.sh relative to the current directory (what the editor page shows as the command)
BEGIN { initcommon(); print relativep(CWD, normpath(ENVIRON["HERE"] "/apply-edits.sh")) }
