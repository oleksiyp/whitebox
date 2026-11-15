# Shared helpers for the whitebox PowerShell port (dot-sourced by whitebox.ps1, apply-edits.ps1, validate.ps1, build-editor.ps1).
# Must stay valid for Windows PowerShell 5.1 and PowerShell 7, and ASCII-only (5.1 reads BOM-less files as ANSI).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1
try { [Environment]::CurrentDirectory = (Get-Location -PSProvider FileSystem).ProviderPath } catch { }

$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:OutSb = New-Object System.Text.StringBuilder
$script:ErrSb = New-Object System.Text.StringBuilder
$script:Ellipsis = [string][char]0x2026
# ASCII whitespace as used by the reference: space \t \r \n \f \v
$script:WSC = [char[]](32, 9, 13, 10, 12, 11)
# JavaScript's own whitespace set (what native trim() and \s mean) - only validate.mjs uses it
$script:JSWS = [char[]](9, 10, 11, 12, 13, 32, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF)

function WbOut([string]$s) { [void]$script:OutSb.Append($s).Append("`n") }
function WbErr([string]$s) { [void]$script:ErrSb.Append($s).Append("`n") }
function WbFlush {
  foreach ($pair in @(@($script:OutSb, [Console]::OpenStandardOutput()), @($script:ErrSb, [Console]::OpenStandardError()))) {
    $sb = $pair[0]; $st = $pair[1]
    if ($sb.Length -gt 0) {
      $b = $script:Utf8.GetBytes($sb.ToString())
      try { $st.Write($b, 0, $b.Length); $st.Flush() } catch { }
      [void]$sb.Clear()
    }
  }
}
function WbExit([int]$code) { WbFlush; [Environment]::Exit($code) }
function WbDie([string]$m) { WbErr $m; WbExit 1 }

# ---------- JavaScript-compatible number handling ----------
function WbNum($v) {
  if ($v -is [double] -or $v -is [single] -or $v -is [decimal]) {
    $d = [double]$v
    if ([double]::IsNaN($d)) { return 'NaN' }
    if ([double]::IsPositiveInfinity($d)) { return 'Infinity' }
    if ([double]::IsNegativeInfinity($d)) { return '-Infinity' }
    if ($d -eq [Math]::Floor($d)) {
      if ([Math]::Abs($d) -lt 9e15) { return ([long]$d).ToString($script:Inv) }
      return $d.ToString('F0', $script:Inv)
    }
    return $d.ToString('R', $script:Inv)
  }
  if ($null -eq $v) { return 'undefined' }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if ($v -is [long] -or $v -is [int]) { return $v.ToString($script:Inv) }
  return [string]$v
}
# JS Number(string)
function WbToNumber($s) {
  if ($null -eq $s) { return [double]::NaN }
  $t = ([string]$s).Trim($script:JSWS)
  if ($t.Length -eq 0) { return [double]0 }
  if ([regex]::IsMatch($t, '^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$')) { return [double]::Parse($t, [System.Globalization.NumberStyles]::Float, $script:Inv) }
  if ([regex]::IsMatch($t, '^0[xX][0-9a-fA-F]{1,13}$')) { return [double][Convert]::ToInt64($t.Substring(2), 16) }
  if ($t -ceq 'Infinity' -or $t -ceq '+Infinity') { return [double]::PositiveInfinity }
  if ($t -ceq '-Infinity') { return [double]::NegativeInfinity }
  return [double]::NaN
}
function WbIsInt($v) {
  if ($v -is [long] -or $v -is [int]) { return $true }
  if ($v -is [double]) { return (-not [double]::IsNaN($v)) -and (-not [double]::IsInfinity($v)) -and ($v -eq [Math]::Floor($v)) }
  return $false
}
# JS String.prototype.slice / Array slice-join helpers
function WbIdx($i, [int]$len) {
  $d = [double]$i
  if ([double]::IsNaN($d)) { $d = 0 }
  if ($d -lt 0) { $d = $len + $d; if ($d -lt 0) { $d = 0 } } elseif ($d -gt $len) { $d = $len }
  return [int][Math]::Floor($d)
}
function WbSub([string]$s, $a, $b) {
  $n = $s.Length; $x = WbIdx $a $n
  if ($null -eq $b) { $y = $n } else { $y = WbIdx $b $n }
  if ($y -le $x) { return '' }
  return $s.Substring($x, $y - $x)
}
# lines.slice(a, b).join("\n")
function WbSliceJoin([string[]]$L, $a, $b) {
  $n = $L.Length; $x = WbIdx $a $n; $y = WbIdx $b $n
  if ($y -le $x) { return '' }
  return [string]::Join("`n", $L, $x, $y - $x)
}

# ---------- sorting: bytewise on UTF-8 (== code point order), stable ----------
$script:reHi = New-Object System.Text.RegularExpressions.Regex('[\uD800-\uFFFF]')
$script:evHi = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $c = [int][char]$m.Value; if ($c -ge 0xE000) { [string][char]($c - 0x800) } else { [string][char]($c + 0x2000) } }
function WbOrdKey([string]$s) { if ($script:reHi.IsMatch($s)) { return $script:reHi.Replace($s, $script:evHi) } return $s }
# items sorted by the byte order of keys; equal keys keep their input order
function WbSortByKey([object[]]$items, [string[]]$keys) {
  $n = $items.Length
  if ($n -lt 2) { return ,$items }
  $k2 = New-Object 'string[]' $n; $idx = New-Object 'int[]' $n
  for ($i = 0; $i -lt $n; $i++) { $k2[$i] = (WbOrdKey $keys[$i]) + [char]0 + $i.ToString('D9'); $idx[$i] = $i }
  [Array]::Sort($k2, $idx, [System.StringComparer]::Ordinal)
  $res = New-Object 'object[]' $n
  for ($i = 0; $i -lt $n; $i++) { $res[$i] = $items[$idx[$i]] }
  return ,$res
}
# stable sort by a numeric key (ascending, or descending when $desc)
function WbSortByNum([object[]]$items, [double[]]$keys, [bool]$desc) {
  $n = $items.Length
  if ($n -lt 2) { return ,$items }
  $k2 = New-Object 'double[]' $n; $idx = New-Object 'int[]' $n
  for ($i = 0; $i -lt $n; $i++) { $k = $keys[$i]; if ($desc) { $k = -$k }; $k2[$i] = $k * 4194304 + $i; $idx[$i] = $i }
  [Array]::Sort($k2, $idx)
  $res = New-Object 'object[]' $n
  for ($i = 0; $i -lt $n; $i++) { $res[$i] = $items[$idx[$i]] }
  return ,$res
}

# ---------- files ----------
function WbReadText([string]$p) { return $script:Utf8.GetString([System.IO.File]::ReadAllBytes($p)) }
function WbWriteText([string]$p, [string]$s) { [System.IO.File]::WriteAllBytes($p, $script:Utf8.GetBytes($s)) }
function WbResolve([string]$p) {
  if ([string]::IsNullOrEmpty($p)) { $p = '.' }
  $f = [System.IO.Path]::GetFullPath($p)
  $t = $f.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  if ($t.Length -eq 0) { return $f }
  if ($t.Length -eq 2 -and $t[1] -eq ':') { return $f }
  return $t
}
function WbDirName([string]$p) {
  $d = [System.IO.Path]::GetDirectoryName($p)
  if ([string]::IsNullOrEmpty($d)) { if ([System.IO.Path]::IsPathRooted($p)) { return $p } return '.' }
  return $d
}
function WbSha1([byte[]]$b) {
  $h = [System.Security.Cryptography.SHA1]::Create()
  try { $r = $h.ComputeHash($b) } finally { $h.Dispose() }
  return ([System.BitConverter]::ToString($r)).Replace('-', '').ToLowerInvariant()
}
# lines of a file as JS reference does: normalise CRLF, split on \n
function WbSplitLines([string]$raw) { return ,($raw.Replace("`r`n", "`n").Split([char]10)) }

# ---------- JSON writer (compact or JSON.stringify(v, null, 1) layout) ----------
$script:reJsEsc = New-Object System.Text.RegularExpressions.Regex('[\x00-\x1f"\\\uD800-\uDFFF]')
$script:reCtl = New-Object System.Text.RegularExpressions.Regex('[\x00-\x1f]')
$script:reLone = New-Object System.Text.RegularExpressions.Regex('[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]')
$script:evHex = [System.Text.RegularExpressions.MatchEvaluator] { param($m) '\u' + ([int][char]$m.Value).ToString('x4') }
function WbJStr([string]$s) {
  if (-not $script:reJsEsc.IsMatch($s)) { return '"' + $s + '"' }
  $t = $s.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r').Replace("`t", '\t').Replace("`b", '\b').Replace("`f", '\f')
  if ($script:reCtl.IsMatch($t)) { $t = $script:reCtl.Replace($t, $script:evHex) }
  if ($script:reLone.IsMatch($t)) { $t = $script:reLone.Replace($t, $script:evHex) }
  return '"' + $t + '"'
}
function WbJsonW($v, [System.Text.StringBuilder]$sb, [bool]$pretty, [int]$depth) {
  if ($null -eq $v) { [void]$sb.Append('null'); return }
  if ($v -is [string]) { [void]$sb.Append((WbJStr $v)); return }
  if ($v -is [bool]) { if ($v) { [void]$sb.Append('true') } else { [void]$sb.Append('false') }; return }
  if ($v -is [System.Collections.IDictionary]) {
    if ($v.get_Count() -eq 0) { [void]$sb.Append('{}'); return }
    [void]$sb.Append('{')
    $first = $true
    foreach ($k in @($v.Keys)) {
      if (-not $first) { [void]$sb.Append(',') }
      $first = $false
      if ($pretty) { [void]$sb.Append("`n").Append(' ', $depth + 1) }
      [void]$sb.Append((WbJStr ([string]$k))).Append(':')
      if ($pretty) { [void]$sb.Append(' ') }
      WbJsonW $v[$k] $sb $pretty ($depth + 1)
    }
    if ($pretty) { [void]$sb.Append("`n").Append(' ', $depth) }
    [void]$sb.Append('}'); return
  }
  if ($v -is [System.Collections.IList]) {
    if ($v.Count -eq 0) { [void]$sb.Append('[]'); return }
    [void]$sb.Append('[')
    $first = $true
    foreach ($x in $v) {
      if (-not $first) { [void]$sb.Append(',') }
      $first = $false
      if ($pretty) { [void]$sb.Append("`n").Append(' ', $depth + 1) }
      WbJsonW $x $sb $pretty ($depth + 1)
    }
    if ($pretty) { [void]$sb.Append("`n").Append(' ', $depth) }
    [void]$sb.Append(']'); return
  }
  if ($v -is [double] -and ([double]::IsNaN($v) -or [double]::IsInfinity($v))) { [void]$sb.Append('null'); return }
  [void]$sb.Append((WbNum $v))
}
function WbToJson($v, [bool]$pretty) {
  $sb = New-Object System.Text.StringBuilder
  WbJsonW $v $sb $pretty 0
  return $sb.ToString()
}

# ---------- JSON reader ----------
# objects -> case-sensitive OrderedDictionary, arrays -> List[object], integers -> long, other numbers -> double
$script:reTok = New-Object System.Text.RegularExpressions.Regex('"[^"\\]*(?:\\[\s\S][^"\\]*)*"|-?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null|[\[\]{}:,]|[^ \t\r\n]')
$script:reUnesc = New-Object System.Text.RegularExpressions.Regex('\\(u[0-9a-fA-F]{4}|[\s\S])')
$script:evUnesc = [System.Text.RegularExpressions.MatchEvaluator] {
  param($m)
  $g = $m.Groups[1].Value
  if ($g.Length -eq 5) { return [string][char][Convert]::ToInt32($g.Substring(1), 16) }
  switch -CaseSensitive ($g) { 'n' { return "`n" } 'r' { return "`r" } 't' { return "`t" } 'b' { return "`b" } 'f' { return "`f" } default { return $g } }
}
function WbNewMap { return New-Object System.Collections.Specialized.OrderedDictionary }
function WbNewList { return New-Object 'System.Collections.Generic.List[object]' }
function WbJUnesc([string]$t) {
  $s = $t.Substring(1, $t.Length - 2)
  if ($s.IndexOf([char]92) -ge 0) { $s = $script:reUnesc.Replace($s, $script:evUnesc) }
  return $s
}
function WbJsonParse([string]$text) {
  $stack = New-Object 'System.Collections.Generic.List[object]'
  $cur = $null; $isDict = $false; $key = $null; $root = $null; $have = $false
  foreach ($m in $script:reTok.Matches($text)) {
    $t = $m.Value; $c = [int]$t[0]
    if ($c -eq 44 -or $c -eq 58) { continue }
    $container = $false
    if ($c -eq 34) {
      $val = WbJUnesc $t
      if ($isDict -and $null -eq $key) { $key = $val; continue }
    } elseif ($c -eq 123) { $val = New-Object System.Collections.Specialized.OrderedDictionary; $container = $true
    } elseif ($c -eq 91) { $val = New-Object 'System.Collections.Generic.List[object]'; $container = $true
    } elseif ($c -eq 125 -or $c -eq 93) {
      if ($stack.Count -eq 0) { throw 'JSON syntax error' }
      $stack.RemoveAt($stack.Count - 1)
      if ($stack.Count -gt 0) { $cur = $stack[$stack.Count - 1]; $isDict = $cur -is [System.Collections.IDictionary] } else { $cur = $null; $isDict = $false }
      $key = $null
      continue
    } elseif ($c -eq 116 -and $t -ceq 'true') { $val = $true
    } elseif ($c -eq 102 -and $t -ceq 'false') { $val = $false
    } elseif ($c -eq 110 -and $t -ceq 'null') { $val = $null
    } elseif ($c -eq 45 -or ($c -ge 48 -and $c -le 57)) {
      if ($t.Length -lt 16 -and $t.IndexOfAny([char[]]'.eE') -lt 0) { $val = [long]::Parse($t, $script:Inv) }
      else { $val = [double]::Parse($t, [System.Globalization.NumberStyles]::Float, $script:Inv) }
    } else { throw "JSON syntax error near '$t'" }
    # attach to the open container (or make it the root)
    if ($null -eq $cur) { $root = $val; $have = $true }
    elseif ($isDict) { $cur[$key] = $val; $key = $null }
    else { $cur.Add($val) }
    if ($container) { $stack.Add($val); $cur = $val; $isDict = ($c -eq 123); $key = $null }
  }
  if (-not $have -or $stack.Count -gt 0) { throw 'JSON syntax error: empty or truncated input' }
  return ,$root
}

function WbRelative([string]$from, [string]$to) {
  $f = WbResolve $from; $t = WbResolve $to
  $sep = [System.IO.Path]::DirectorySeparatorChar
  $win = ($sep -eq [char]92)
  $fp = $f.Split([char[]]@($sep, [System.IO.Path]::AltDirectorySeparatorChar), [System.StringSplitOptions]::RemoveEmptyEntries)
  $tp = $t.Split([char[]]@($sep, [System.IO.Path]::AltDirectorySeparatorChar), [System.StringSplitOptions]::RemoveEmptyEntries)
  $c = 0
  while ($c -lt $fp.Length -and $c -lt $tp.Length) {
    if ($win) { if (-not [string]::Equals($fp[$c], $tp[$c], [StringComparison]::OrdinalIgnoreCase)) { break } }
    elseif ($fp[$c] -cne $tp[$c]) { break }
    $c++
  }
  if ($win -and $c -eq 0) { return $t }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  for ($i = $c; $i -lt $fp.Length; $i++) { $parts.Add('..') }
  for ($i = $c; $i -lt $tp.Length; $i++) { $parts.Add($tp[$i]) }
  return [string]::Join([string]$sep, $parts)
}
