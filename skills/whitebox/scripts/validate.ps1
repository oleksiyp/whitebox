# Validate a whitebox.json tree against the source files.  PowerShell port of validate.mjs.   validate.ps1 [whitebox.json]
# Whitespace is ASCII-only, as in whitebox.mjs.
. (Join-Path $PSScriptRoot 'lib/wb-common.ps1')
$script:AllArgs = [string[]]@($args)
$script:reJsHead = New-Object System.Text.RegularExpressions.Regex('^#{1,6}[ \t\r\n\f\v]')
function JsWords($s) {
  $t = ([string]$s).Trim($script:WSC)
  if ($t.Length -eq 0) { return 1 }
  return $t.Split($script:WSC, [System.StringSplitOptions]::RemoveEmptyEntries).Length
}
function JsStr($v) { if ($v -is [string]) { return $v } return (WbNum $v) }
function JsTruthy($v) { if ($null -eq $v) { return $false }; if ($v -is [string]) { return ($v.Length -gt 0) }; if ($v -is [bool]) { return $v }; if ($v -is [long] -or $v -is [double]) { return ($v -ne 0 -and -not ($v -is [double] -and [double]::IsNaN($v))) }; return $true }
function Lines([string]$file) {
  if (-not $script:Cache.ContainsKey($file)) { $script:Cache[$file] = (WbSplitLines (WbReadText (WbResolveIn $script:Base $file))) }
  return ,$script:Cache[$file]
}
function WbResolveIn([string]$base, [string]$rel) { return (WbResolve ([System.IO.Path]::Combine($base, $rel))) }
function Walk($n, [int]$d, [string]$path) {
  if ($d -gt $script:Depth) { $script:Depth = $d }
  $p = $path + '/' + (JsStr $n['title'])
  $id = $n['id']
  $idKey = $(if ($id -is [string]) { 's:' + $id } else { 'n:' + (WbNum $id) })
  if (-not (JsTruthy $id) -or $script:Ids.Contains($idKey)) { $script:Errs.Add("${p}: missing/duplicate id $(JsStr $id)") }
  [void]$script:Ids.Add($idKey)
  $title = $n['title']
  if ($d -gt 0) {
    $ok = $false
    if ($title -is [string]) { $w = JsWords $title; $ok = ($w -ge 2 -and $w -le 4) }
    if (-not $ok) { $script:Errs.Add("${p}: title must be 2-4 words") }
  }
  $ch = $n['children']
  if ($null -ne $ch) {
    if ($ch.Count -eq 0) { $script:Errs.Add("${p}: empty branch") }
    if ($d -eq 0 -and ($ch.Count -lt 3 -or $ch.Count -gt 8)) { $script:Warn.Add("root has $($ch.Count) top-level branches (want 3-8)") }
    if ($d -gt 8) { $script:Warn.Add("${p}: depth $d (>8)") }
    if ($ch.Count -lt 2 -and $d -gt 0) { $script:Warn.Add("${p}: single-child branch") }
    if ($ch.Count -gt 9) { $script:Warn.Add("${p}: $($ch.Count) children (>9)") }
    $ts = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($c in $ch) { [void]$ts.Add((JsStr $c['title'])) }
    if ($ts.Count -ne $ch.Count) { $script:Errs.Add("${p}: duplicate sibling titles") }
    $lastLine = New-Object 'System.Collections.Generic.Dictionary[string,double]'
    foreach ($c in $ch) {
      if ($null -ne $c['children']) { continue }
      $cf = $c['file']
      if (JsTruthy $cf) {
        $prev = [double]0; $key = JsStr $cf
        if ($lastLine.ContainsKey($key)) { $prev = $lastLine[$key] }
        if ([double]$c['start'] -le $prev) { $script:Warn.Add("${p}: `"$(JsStr $c['title'])`" out of source order") }
      }
      $lastLine[(JsStr $cf)] = [double]$c['start']
    }
    foreach ($c in $ch) { Walk $c ($d + 1) $p }
    return
  }
  $script:Leaves.Add($n)
  $f = $n['file']
  if (-not (JsTruthy $f) -or -not (WbIsInt $n['start']) -or -not (WbIsInt $n['end']) -or $n['end'] -lt $n['start']) { $script:Errs.Add("${p}: bad file/start/end"); return }
  try { $L = Lines ([string]$f) } catch { $script:Errs.Add("${p}: cannot read $f"); return }
  $real = WbSliceJoin $L ($n['start'] - 1) $n['end']
  if ($real -cne $n['text']) { $script:Errs.Add("${p}: text differs from ${f}:$(WbNum $n['start'])-$(WbNum $n['end'])") }
  $isCode = ($n['kind'] -ceq 'code')
  if ($isCode -and -not (JsTruthy $n['description'])) { $script:Warn.Add("${p}: code piece without description") }
  if (-not $isCode) { $w = JsWords $n['text'] } else { $w = 0 }
  if (-not $isCode -and $w -gt 250 -and $n['end'] -gt $n['start']) { $script:Errs.Add("${p}: leaf has $w words (max 250; spans $($n['end'] - $n['start'] + 1) lines, split it)") }
  elseif (-not $isCode -and $w -gt 120) { $script:Warn.Add("${p}: leaf has $w words (>120)") }
  $a = $L[[int]$n['start'] - 1]; $b = $L[[int]$n['end'] - 1]
  if ($null -eq $a -or $null -eq $b) { throw "TypeError: Cannot read properties of undefined (reading 'trim')" }
  if ($a.Trim($script:WSC).Length -eq 0 -or $b.Trim($script:WSC).Length -eq 0) { $script:Errs.Add("${p}: leaf starts or ends on a blank line") }
}
function Main {
  $f = 'whitebox.json'; if ($script:AllArgs.Length -gt 0 -and $script:AllArgs[0].Length -gt 0) { $f = $script:AllArgs[0] }
  $Tree = WbJsonParse (WbReadText $f)
  $rootStr = '.'; if (JsTruthy $Tree['root']) { $rootStr = [string]$Tree['root'] }
  $script:Base = WbResolve ([System.IO.Path]::Combine((WbResolve (WbDirName $f)), $rootStr))
  $script:Errs = New-Object 'System.Collections.Generic.List[string]'; $script:Warn = New-Object 'System.Collections.Generic.List[string]'
  $script:Ids = New-Object 'System.Collections.Generic.HashSet[string]'; $script:Leaves = New-Object 'System.Collections.Generic.List[object]'
  $script:Cache = New-Object 'System.Collections.Generic.Dictionary[string,object]'; $script:Depth = 0
  Walk $Tree['tree'] 0 ''
  $by = WbNewMap
  foreach ($l in $script:Leaves) { $k = JsStr $l['file']; if (-not $by.Contains($k)) { $by[$k] = (WbNewList) }; $by[$k].Add($l) }
  foreach ($file in @($by.Keys)) {
    $ls = [object[]]$by[$file].ToArray(); $keys = New-Object 'double[]' $ls.Length
    for ($i = 0; $i -lt $ls.Length; $i++) { $keys[$i] = [double]$ls[$i]['start'] }
    $ls = [object[]](WbSortByNum $ls $keys $false)
    for ($i = 1; $i -lt $ls.Length; $i++) { if ($ls[$i]['start'] -le $ls[$i - 1]['end']) { $script:Errs.Add("${file}: leaves overlap at line $(WbNum $ls[$i]['start']) (`"$(JsStr $ls[$i]['title'])`")") } }
    $covered = New-Object 'System.Collections.Generic.HashSet[long]'
    $isCode = $false
    foreach ($l in $ls) {
      if ($l['kind'] -ceq 'code') { $isCode = $true }
      for ($k = [long]$l['start']; $k -le [long]$l['end']; $k++) { [void]$covered.Add($k) }
    }
    $miss = New-Object 'System.Collections.Generic.List[string]'; $fence = $false
    $LL = Lines $file
    for ($i = 0; $i -lt $LL.Length; $i++) {
      $t = $LL[$i]
      if ($t.StartsWith('```', [StringComparison]::Ordinal)) { $fence = -not $fence }
      if ($t.Trim($script:WSC).Length -gt 0 -and ($isCode -or $fence -or -not $script:reJsHead.IsMatch($t)) -and -not $covered.Contains([long]($i + 1))) { $miss.Add([string]($i + 1)) }
    }
    if ($miss.Count -gt 0) { $script:Errs.Add("${file}: $($miss.Count) content lines not covered, e.g. $([string]::Join(',', $miss.GetRange(0, [Math]::Min(8, $miss.Count))))") }
  }
  WbOut "$($script:Leaves.Count) leaves, $($script:Ids.Count - $script:Leaves.Count) branches, depth $($script:Depth), files: $([string]::Join(', ', @($by.Keys)))"
  foreach ($w in $script:Warn) { WbOut "warn: $w" }
  foreach ($e in $script:Errs) { WbOut "ERROR: $e" }
  if ($script:Errs.Count -gt 0) { WbExit 1 } else { WbExit 0 }
}
try { $null = Main } catch { WbErr ([string]$_.Exception.Message); WbErr ([string]$_.ScriptStackTrace); WbExit 1 }
