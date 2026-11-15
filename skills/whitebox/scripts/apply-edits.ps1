# Write edits made in the whitebox editor back to the markdown files.  PowerShell port of apply-edits.mjs.
#   apply-edits.ps1 edits.json [--root DIR] [--drop-excluded] [--dry-run]
# Every change is verified: the lines on disk must still equal the leaf's original text,
# otherwise that file is left untouched and reported as a conflict.
. (Join-Path $PSScriptRoot 'lib/wb-common.ps1')
function Main {
  $a = [string[]]@($script:AllArgs)
  function Flag([string]$n) { return ([Array]::IndexOf($a, $n) -ge 0) }
  function Opt([string]$n) { $i = [Array]::IndexOf($a, $n); if ($i -ge 0 -and $i + 1 -lt $a.Length) { return $a[$i + 1] } return $null }
  $rootOpt = Opt '--root'
  $jf = $null
  foreach ($x in $a) { if (-not $x.StartsWith('--', [StringComparison]::Ordinal) -and ($null -eq $rootOpt -or $x -cne $rootOpt)) { $jf = $x; break } }
  if ($null -eq $jf) { WbErr 'usage: apply-edits.mjs edits.json [--root DIR] [--drop-excluded] [--dry-run]'; WbExit 2 }
  $Ed = WbJsonParse (WbReadText $jf)
  $rootStr = $rootOpt; if ([string]::IsNullOrEmpty($rootStr)) { $rootStr = $Ed['root'] }; if ([string]::IsNullOrEmpty($rootStr)) { $rootStr = '.' }
  $root = WbResolve ([string]$rootStr)
  $excluded = $Ed['excluded']; if ($null -eq $excluded) { $excluded = WbNewList }
  $codeEx = 0; foreach ($e in $excluded) { if ($e['kind'] -ceq 'code') { $codeEx++ } }
  $intents = 0; if ($null -ne $Ed['intents']) { $intents = $Ed['intents'].Count }
  if ($null -eq $Ed['edits']) { throw "TypeError: Cannot read properties of undefined (reading 'map')" }
  $ops = New-Object 'System.Collections.Generic.List[object]'
  foreach ($e in $Ed['edits']) { $ops.Add(@{ file = $e['file']; start = $e['start']; end = $e['end']; before = $e['before']; after = $e['after']; path = $e['path']; kind = 'edit' }) }
  if (Flag '--drop-excluded') { foreach ($e in $excluded) { if ($e['kind'] -cne 'code') { $ops.Add(@{ file = $e['file']; start = $e['start']; end = $e['end']; before = $e['before']; after = $e['after']; path = $e['path']; kind = 'drop' }) } } }
  $byFile = WbNewMap
  foreach ($o in $ops) { $k = WbNum $o['file']; if (-not $byFile.Contains($k)) { $byFile[$k] = (WbNewList) }; $byFile[$k].Add($o) }
  $changed = 0; $conflicts = 0; $dry = Flag '--dry-run'
  foreach ($file in @($byFile.Keys)) {
    $p = WbResolve ([System.IO.Path]::Combine($root, $file))
    $raw = WbReadText $p; $crlf = $raw.Contains("`r`n")
    $arr = WbSplitLines $raw
    $lst = [object[]]$byFile[$file].ToArray(); $keys = New-Object 'double[]' $lst.Length
    for ($i = 0; $i -lt $lst.Length; $i++) { $keys[$i] = WbToNumber $lst[$i]['start'] }
    $lst = [object[]](WbSortByNum $lst $keys $true)
    $bad = $false
    foreach ($o in $lst) {
      $real = WbSliceJoin $arr ($o['start'] - 1) $o['end']
      if ($null -eq $o['before'] -or $real -cne [string]$o['before']) { WbOut "CONFLICT ${file}:$(WbNum $o['start'])-$(WbNum $o['end']) no longer matches the original; skipping file"; $bad = $true; $conflicts++ }
    }
    for ($i = 1; $i -lt $lst.Length; $i++) { if ([double]$lst[$i]['end'] -ge [double]$lst[$i - 1]['start']) { WbOut "CONFLICT ${file}: overlapping ranges at $(WbNum $lst[$i - 1]['start'])"; $bad = $true; $conflicts++ } }
    if ($bad) { continue }
    $L = New-Object 'System.Collections.Generic.List[string]' -ArgumentList (, [string[]]$arr)
    foreach ($o in $lst) {
      $n = [double]$o['end'] - [double]$o['start'] + 1
      $si = WbIdx ($o['start'] - 1) $L.Count
      $dc = [int][Math]::Max(0, [Math]::Min($n, $L.Count - $si))
      if ($o['kind'] -ceq 'edit') {
        if ($null -eq $o['after']) { throw "TypeError: Cannot read properties of undefined (reading 'split')" }
        $L.RemoveRange($si, $dc); $L.InsertRange($si, [string[]]([string]$o['after']).Split([char]10))
        WbOut "edit  ${file}:$(WbNum $o['start'])-$(WbNum $o['end'])"
      } else {
        $L.RemoveRange($si, $dc)
        $pt = ''; if ($null -ne $o['path'] -and ([string]$o['path']).Length -gt 0) { $pt = [string]$o['path'] }
        WbOut "drop  ${file}:$(WbNum $o['start'])-$(WbNum $o['end'])  $pt"
      }
      $changed++
    }
    $out = [string]::Join("`n", $L)
    $anyDrop = $false; foreach ($o in $lst) { if ($o['kind'] -ceq 'drop') { $anyDrop = $true } }
    if ($anyDrop) { $out = [regex]::Replace($out, '\n{3,}', "`n`n") }
    if ($crlf) { $out = $out.Replace("`n", "`r`n") }
    if (-not $dry) { WbWriteText $p $out }
  }
  if ($intents -gt 0 -or $codeEx -gt 0) { WbOut "note: source code is never rewritten or deleted by this tool: $intents behaviour change note(s) and $codeEx excluded code piece(s) were ignored (hand the intents to an implementer)." }
  $pre = ''; if ($dry) { $pre = '[dry run] ' }
  WbOut "${pre}$changed change(s) applied, $conflicts conflict(s)"
  if ($conflicts -gt 0) { WbExit 1 } else { WbExit 0 }
}
$script:AllArgs = $args
try { $null = Main } catch { WbErr ([string]$_.Exception.Message); WbErr ([string]$_.ScriptStackTrace); WbExit 1 }
