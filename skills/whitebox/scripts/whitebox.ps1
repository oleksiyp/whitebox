# whitebox: turn a project (markdown + source code) into one overseeable, editable tree.  PowerShell port of whitebox.mjs.
# Deterministic steps live here; a cheap model (haiku agents) only writes titles/paths.  Usage and messages are identical to the Node reference:
#   whitebox.ps1 split <dir|file...> --work W | window G N | check G N | merge-input | apply-merge | describe-input G | check-desc G | build
#                status | check-all | groups-args | reshape-count | reshape-list | reshape-input N | check-reshape N | apply-reshape | estimate
# Works on Windows PowerShell 5.1 and PowerShell 7; no modules, no Add-Type. The arguments are parsed from $args by hand ("--work" is not a PowerShell parameter).
. (Join-Path $PSScriptRoot 'lib/wb-common.ps1')
$script:Argv = [string[]]@($args)
$script:SelfPath = $PSCommandPath
$script:Launch = $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell -NoProfile -ExecutionPolicy Bypass -File' } else { 'pwsh -NoProfile -File' })
$script:Cmd = $(if ($script:Argv.Length -gt 0) { $script:Argv[0] } else { $null })
$script:VAL = @('--work', '--out', '--window', '--groups', '--max-kb', '--include', '--exclude')
function Opt([string]$n, $d) {
  $i = [Array]::IndexOf($script:Argv, $n)
  if ($i -lt 0) { return $d }
  if ($i + 1 -lt $script:Argv.Length) { return $script:Argv[$i + 1] }
  return $null
}
function HasFlag([string]$n) { return ([Array]::IndexOf($script:Argv, $n) -ge 0) }
$script:Pos = New-Object 'System.Collections.Generic.List[string]'
for ($i = 1; $i -lt $script:Argv.Length; $i++) {
  $a = $script:Argv[$i]
  if (-not $a.StartsWith('--', [StringComparison]::Ordinal) -and ($script:VAL -cnotcontains $script:Argv[$i - 1])) { $script:Pos.Add($a) }
}
function PosNum([int]$k) { if ($k -lt $script:Pos.Count) { return (WbToNumber $script:Pos[$k]) } return [double]::NaN }
$workOpt = Opt '--work' $null
$script:WORK = $null
if ($null -ne $workOpt) { $script:WORK = WbResolve $workOpt }   # no implicit work directory
$script:WIN = WbToNumber (Opt '--window' 220)
$script:MAX = 80
function Wp { $parts = New-Object 'System.Collections.Generic.List[string]'; $parts.Add($script:WORK); foreach ($a in $args) { $parts.Add([string]$a) }; return [System.IO.Path]::Combine($parts.ToArray()) }
function WbFwd([string]$x) { if ([System.IO.Path]::DirectorySeparatorChar -eq [char]92) { return $x.Replace([string][char]92, '/') } return $x }
function WbQ([string]$x) {
  # paths shown to agents use "/" on every OS (see whitebox.mjs q()); quote with JSON-style double quotes only when needed
  $x = WbFwd $x
  if ([regex]::IsMatch($x, '[ \t"''\\$&;()<>|*?\[\]{}!~#`]')) { return (WbJStr $x) }
  return $x
}
$script:SELF = WbQ (WbResolve $script:SelfPath)
function ReadJ([string]$p) { return ,(WbJsonParse (WbReadText $p)) }

# ---------- regex / constants (JS semantics: ASCII whitespace and word characters) ----------
function Rx([string]$p, [bool]$ic = $false) {
  $o = [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
  if ($ic) { $o = $o -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
  return New-Object System.Text.RegularExpressions.Regex($p, $o)
}
$WS = '[ \t\r\n\f\v]'
$NL = '[^\n\r\u2028\u2029]'   # what "." means in JS
$script:reHeading = Rx '^ {0,3}#{1,6}[ \t\r\n\f\v]+[^ \t\r\n\f\v]'
$script:reFence = Rx '^ {0,3}(`{3,}|~{3,})'
$script:reList = Rx '^( {0,3})([-*+]|[0-9]{1,3}[.)])[ \t\r\n\f\v]+'
$script:reHeadSplit = Rx ('^ {0,3}(#{1,6})[ \t\r\n\f\v]+(' + $NL + '*?)[ \t\r\n\f\v]*#*[ \t\r\n\f\v]*\z')
$script:reTable = Rx '^[ \t\r\n\f\v]*\|'
$script:reIndent2 = Rx '^( {2,}|\t)[^ \t\r\n\f\v]'
$script:reSp2 = Rx '^ {2,}'
$script:reStartWs = Rx '^[ \t\r\n\f\v]'
$script:reClean1 = Rx '[`*_]|\[([^\]]*)\]\([^)]*\)'
$script:reWsRun = Rx '[ \t\r\n\f\v]+'
$script:reUpper = Rx '[A-Z]'
$script:evLower = [System.Text.RegularExpressions.MatchEvaluator] { param($m) [string][char]([int][char]$m.Value + 32) }
$script:reDecl = Rx '^(func|type|class|def|fn|pub|impl|struct|enum|trait|interface|const|var|let|export|import|package|module|use|async|public|private|protected|static|abstract|final|namespace|template|extern|mod|object|data|sealed|open)(?![A-Za-z0-9_])'
$script:reLead = Rx '^(//|/\*|#(?!include|define|if|endif|pragma|!)|--|@[A-Za-z_(])'
$script:reCloser = Rx '^[})\]]'
$script:rePyCloser = Rx '^(else|elif|except|finally)(?![A-Za-z0-9_])'
$script:reBlockInline = Rx ('/\*' + $NL + '*?\*/')
$script:reStr = Rx ('"(\\' + $NL + '|[^"\\])*"|''(\\' + $NL + '|[^''\\])*''|`[^`]*`')
$script:rePyCom = Rx ('#' + $NL + '*\z')
$script:reSlCom = Rx ('//' + $NL + '*\z')
$script:QCH = [char[]]@([char]34, [char]39, [char]96)
$script:BRK = [char[]]'{}()[]'
$script:CODE_EXT = New-Object 'System.Collections.Generic.Dictionary[string,string]'
foreach ($kv in @('go=go', 'ts=ts', 'tsx=tsx', 'js=js', 'jsx=jsx', 'mjs=js', 'cjs=js', 'py=py', 'rs=rust', 'java=java', 'kt=kotlin', 'c=c', 'h=c', 'cc=cpp', 'cpp=cpp', 'hpp=cpp', 'cs=csharp', 'rb=ruby', 'php=php', 'swift=swift', 'sh=sh', 'bash=sh', 'sql=sql', 'proto=proto', 'star=starlark', 'lua=lua', 'scala=scala', 'ex=elixir', 'exs=elixir', 'dart=dart')) { $p = $kv.Split('='); $script:CODE_EXT[$p[0]] = $p[1] }
$script:CFG_EXT = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($x in 'yaml', 'yml', 'json', 'toml', 'ini', 'tf', 'tpl', 'cfg', 'conf', 'xml') { [void]$script:CFG_EXT.Add($x) }
$script:SKIP_DIRS = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($x in 'node_modules', 'vendor', 'dist', 'build', 'out', 'target', 'coverage', '__pycache__', 'venv', 'site-packages', 'bower_components', 'testdata', 'fixtures', '__snapshots__', 'golden', 'third_party', 'generated') { [void]$script:SKIP_DIRS.Add($x) }
$script:LOCKS = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($x in 'go.sum', 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'cargo.lock', 'poetry.lock', 'gemfile.lock', 'composer.lock', 'bun.lockb') { [void]$script:LOCKS.Add($x) }
$script:reTest = Rx '(_test\.go\z|\.test\.[a-z]+\z|\.spec\.[a-z]+\z|(^|/)(tests?|__tests__|e2e)/|(^|/)test_[^/]*\.py\z|_test\.py\z|Test\.java\z|Tests?\.cs\z)'
$script:reSecret = Rx '(^|/)(\.env[^/]*|[^/]*\.(pem|key|p12|pfx|jks|keystore|kdbx|crt|cer|asc)|id_(rsa|dsa|ecdsa|ed25519)[^/]*|[^/]*(secret|credential|password|passwd|token)s?[^/]*\.(json|ya?ml|toml|ini|txt|env|conf|cfg)|\.?netrc|\.npmrc|\.pypirc|[^/]*\.tfstate(\.backup)?|[^/]*\.tfvars)\z' $true
$script:reGen = Rx '(Code generated|DO NOT EDIT|@generated|autogenerated|auto-generated|<auto-generated|GENERATED FILE)' $true
$script:reMinMap = Rx '\.min\.|\.map\z'
$script:reFam = Rx '-[0-9]+(\.([mM][dD]|[mM][aA][rR][kK][dD][oO][wW][nN]))\z'

function WbLower([string]$s) { if ($script:reUpper.IsMatch($s)) { return $script:reUpper.Replace($s, $script:evLower) } return $s }
function WbW([string]$s) { return $s.Split($script:WSC, [System.StringSplitOptions]::RemoveEmptyEntries).Length }
function WbClean([string]$s) {
  $t = $script:reClean1.Replace($s, '$1')
  $t = $script:reWsRun.Replace($t, ' ')
  return $t.Trim($script:WSC)
}
function WbSnip([string]$s, [int]$n) {
  $w = (WbClean $s).Split([char]32)
  $k = [Math]::Min($n, $w.Length)
  $r = [string]::Join(' ', $w, 0, $k)
  if ($w.Length -gt $n) { $r += ' ' + $script:Ellipsis }
  return $r
}
function WbTpl([string]$text, $map) {
  $t = $text.Replace("`r`n", "`n")
  return [regex]::Replace($t, '@@([A-Z0-9_]+)@@', [System.Text.RegularExpressions.MatchEvaluator] { param($m) [string]$map[$m.Groups[1].Value] })
}

# ---------------- segmenter (deterministic) ----------------
function WbMdParse([string[]]$L0) {
  $L = $L0
  if ($L.Length -gt 0 -and $L[0].Length -gt 0 -and [int]$L[0][0] -eq 0xFEFF) { $L = $L0.Clone(); $L[0] = $L[0].Substring(1) }
  $n = $L.Length; $ev = New-Object 'System.Collections.Generic.List[object]'; $i = 0
  $wsc = $script:WSC; $reFence = $script:reFence; $reHeading = $script:reHeading; $reTable = $script:reTable; $reList = $script:reList
  while ($i -lt $n) {
    $ln = $L[$i]
    if ($ln.Trim($wsc).Length -eq 0) { $i++; continue }
    $m = $reFence.Match($ln)
    if ($m.Success) {
      $f3 = $m.Groups[1].Value.Substring(0, 3)
      $j = $i + 1
      while ($j -lt $n -and -not $L[$j].Trim($wsc).StartsWith($f3, [StringComparison]::Ordinal)) { $j++ }
      $ev.Add(@('u', ($i + 1), ([Math]::Min($j, $n - 1) + 1)))
      $i = $j + 1; continue
    }
    if ($reHeading.IsMatch($ln)) {
      $h = $script:reHeadSplit.Match($ln)
      if (-not $h.Success) { throw 'TypeError: Cannot read properties of null (reading 1)' }
      $ev.Add(@('h', $h.Groups[1].Value.Length, (WbClean $h.Groups[2].Value)))
      $i++; continue
    }
    if ($reTable.IsMatch($ln)) {
      $j = $i
      while ($j + 1 -lt $n -and $reTable.IsMatch($L[$j + 1])) { $j++ }
      $ev.Add(@('u', ($i + 1), ($j + 1))); $i = $j + 1; continue
    }
    if ($reList.IsMatch($ln)) {
      $j = $i
      while ($j + 1 -lt $n) {
        $nx = $L[$j + 1]
        if ($nx.Trim($wsc).Length -eq 0) {
          $k = $j + 1
          while ($k -lt $n -and $L[$k].Trim($wsc).Length -eq 0) { $k++ }
          if ($k -lt $n -and $script:reIndent2.IsMatch($L[$k]) -and -not $reHeading.IsMatch($L[$k])) { $j = $k; continue }
          break
        }
        if ($reHeading.IsMatch($nx) -or ($reFence.IsMatch($nx) -and -not $script:reStartWs.IsMatch($nx)) -or ($reList.IsMatch($nx) -and -not $script:reSp2.IsMatch($nx)) -or $nx[0] -eq [char]124) { break }
        $j++
      }
      $ev.Add(@('u', ($i + 1), ($j + 1))); $i = $j + 1; continue
    }
    $j = $i
    while ($j + 1 -lt $n) {
      $nx = $L[$j + 1]
      if ($nx.Trim($wsc).Length -eq 0 -or $reHeading.IsMatch($nx) -or $reFence.IsMatch($nx) -or $reList.IsMatch($nx) -or $reTable.IsMatch($nx)) { break }
      $j++
    }
    $ev.Add(@('u', ($i + 1), ($j + 1))); $i = $j + 1
  }
  $root = @{ raw = ''; level = 0; kids = (New-Object 'System.Collections.Generic.List[object]') }
  $stack = New-Object 'System.Collections.Generic.List[object]'; $stack.Add($root)
  foreach ($e in $ev) {
    if ($e[0] -ceq 'h') {
      while ($stack[$stack.Count - 1]['level'] -ge $e[1]) { $stack.RemoveAt($stack.Count - 1) }
      $h = @{ raw = $e[2]; level = $e[1]; kids = (New-Object 'System.Collections.Generic.List[object]') }
      $stack[$stack.Count - 1]['kids'].Add($h); $stack.Add($h)
    } else { $stack[$stack.Count - 1]['kids'].Add(@{ s = $e[1]; e = $e[2] }) }
  }
  return ,$root
}
function WbSplitUnit([string[]]$L, $u, [int]$max, [bool]$code) {
  $wsc = $script:WSC
  $out = New-Object 'System.Collections.Generic.List[object]'
  $w0 = WbW ([string]::Join("`n", $L, $u['s'] - 1, $u['e'] - $u['s'] + 1))
  if ($w0 -le $max) { $out.Add(@{ s = $u['s']; e = $u['e']; w = $w0 }); return ,$out }
  $cs = $u['s']; $acc = 0; $lastBlank = 0; $ue = $u['e']
  for ($i = $u['s']; $i -le $ue; $i++) {
    $line = $L[$i - 1]
    $lw = $line.Split($wsc, [System.StringSplitOptions]::RemoveEmptyEntries).Length
    $blank = ($line.Trim($wsc).Length -eq 0)
    if ($code -and $blank -and $acc -ge $max / 3) { $lastBlank = $i }
    if ($acc -gt 0 -and $acc + $lw -gt $max -and -not $blank) {
      $brk = $i
      if ($code -and $lastBlank -ne 0 -and $lastBlank -gt $cs) { $brk = $lastBlank + 1 }
      $e = $brk - 1
      while ($L[$e - 1].Trim($wsc).Length -eq 0) { $e-- }
      $out.Add(@{ s = $cs; e = $e; w = -1 }); $cs = $brk; $lastBlank = 0
      $acc = 0
      for ($k = $cs; $k -le $i; $k++) { $acc += $L[$k - 1].Split($wsc, [System.StringSplitOptions]::RemoveEmptyEntries).Length }
      continue
    }
    $acc += $lw
  }
  $e = $ue
  while ($L[$e - 1].Trim($wsc).Length -eq 0) { $e-- }
  $out.Add(@{ s = $cs; e = $e; w = -1 })
  return ,$out
}
function WbPack([string[]]$L, $units, [int]$max, [int]$small, [bool]$code) {
  $out = New-Object 'System.Collections.Generic.List[object]'; $cur = $null
  foreach ($u0 in $units) {
    foreach ($u in (WbSplitUnit $L $u0 $max $code)) {
      $w = $u['w']
      if ($w -lt 0) { $w = WbW ([string]::Join("`n", $L, $u['s'] - 1, $u['e'] - $u['s'] + 1)) }
      if ($null -ne $cur -and ($cur['w'] -lt $small -or $w -lt $small) -and $cur['w'] + $w -le $max) { $cur['e'] = $u['e']; $cur['w'] = $cur['w'] + $w }
      else { if ($null -ne $cur) { $out.Add($cur) }; $cur = @{ s = $u['s']; e = $u['e']; w = $w } }
    }
  }
  if ($null -ne $cur) { $out.Add($cur) }
  return ,$out
}
function WbMdWalk([string[]]$L, $h, [string[]]$hp, $out) {
  $run = New-Object 'System.Collections.Generic.List[object]'
  foreach ($k in $h['kids']) {
    if ($k.ContainsKey('raw')) {
      if ($run.Count -gt 0) { foreach ($p in (WbPack $L $run $script:MAX 20 $false)) { $p['hp'] = [string]::Join(' > ', $hp); $out.Add($p) }; $run = New-Object 'System.Collections.Generic.List[object]' }
      WbMdWalk $L $k ([string[]]($hp + @([string]$k['raw']))) $out
    } else { $run.Add($k) }
  }
  if ($run.Count -gt 0) { foreach ($p in (WbPack $L $run $script:MAX 20 $false)) { $p['hp'] = [string]::Join(' > ', $hp); $out.Add($p) } }
}
function WbMdPieces([string[]]$L) {
  $out = New-Object 'System.Collections.Generic.List[object]'
  WbMdWalk $L (WbMdParse $L) ([string[]]@()) $out
  return ,$out
}

# ---------------- code segmenter (top-level declarations) ----------------
function WbCodeUnits([string[]]$L0, [string]$lang) {
  $L = $L0
  if ($L.Length -gt 0 -and $L[0].Length -gt 0 -and [int]$L[0][0] -eq 0xFEFF) { $L = $L0.Clone(); $L[0] = $L[0].Substring(1) }
  $n = $L.Length; $units = New-Object 'System.Collections.Generic.List[object]'
  $depth = 0; $inBlock = $false; $cur = $null; $chain = $false; $blankSince = $false
  $py = ($lang -ceq 'py' -or $lang -ceq 'sh' -or $lang -ceq 'ruby')
  $wsc = $script:WSC; $reStartWs = $script:reStartWs; $reDecl = $script:reDecl; $reLead = $script:reLead; $reCloser = $script:reCloser
  $qch = $script:QCH; $brk = $script:BRK; $ord = [StringComparison]::Ordinal
  for ($i = 0; $i -lt $n; $i++) {
    $ln = $L[$i]
    if ($ln.Trim($wsc).Length -eq 0) { $blankSince = $true; continue }
    $col0 = -not $reStartWs.IsMatch($ln)
    if ($col0 -and -not $inBlock) {
      if ($reDecl.IsMatch($ln)) { $depth = 0 }
      $lead = $reLead.IsMatch($ln)
      $closer = ($reCloser.IsMatch($ln) -or ($lang -ceq 'py' -and $script:rePyCloser.IsMatch($ln)))
      if ($depth -le 0 -and -not $closer -and -not ($chain -and -not $blankSince)) {
        if ($null -ne $cur) { $units.Add($cur) }
        $cur = @{ s = ($i + 1); e = ($i + 1) }
      }
      $chain = $lead
    } elseif (-not $col0) { $chain = $false }
    # bracket balance of the line, strings and comments stripped
    $b = 0; $doBal = $true; $s = $ln
    if ($inBlock) {
      $k = $s.IndexOf('*/', $ord)
      if ($k -lt 0) { $doBal = $false } else { $s = $s.Substring($k + 2); $inBlock = $false }
    }
    if ($doBal) {
      if (-not $py -and $s.IndexOf('/*', $ord) -ge 0) {
        $s = $script:reBlockInline.Replace($s, '')
        $k = $s.IndexOf('/*', $ord)
        if ($k -ge 0) { $inBlock = $true; $s = $s.Substring(0, $k) }
      }
      if ($s.IndexOfAny($qch) -ge 0) { $s = $script:reStr.Replace($s, '') }
      if ($py) { if ($s.IndexOf([char]35) -ge 0) { $s = $script:rePyCom.Replace($s, '', 1) } }
      elseif ($s.IndexOf('//', $ord) -ge 0) { $s = $script:reSlCom.Replace($s, '', 1) }
      if ($s.IndexOfAny($brk) -ge 0) {
        $b = ($s.Length - $s.Replace('{', '').Length) + ($s.Length - $s.Replace('(', '').Length) + ($s.Length - $s.Replace('[', '').Length) - ($s.Length - $s.Replace('}', '').Length) - ($s.Length - $s.Replace(')', '').Length) - ($s.Length - $s.Replace(']', '').Length)
      }
    }
    $depth += $b; if ($depth -lt 0) { $depth = 0 }
    if ($null -eq $cur) { $cur = @{ s = ($i + 1); e = ($i + 1) } }
    $cur['e'] = $i + 1; $blankSince = $false
  }
  if ($null -ne $cur) { $units.Add($cur) }
  return ,$units
}
function WbCodeSnippet([string[]]$L, [int]$s, [int]$e) {
  $parts = New-Object 'System.Collections.Generic.List[string]'
  for ($i = $s - 1; $i -lt $e -and $parts.Count -lt 10; $i++) {
    $t = $L[$i].Trim($script:WSC)
    if ($t.Length -gt 0) { if ($t.Length -gt 100) { $t = $t.Substring(0, 100) }; $parts.Add($t) }
  }
  return [string]::Join(' ' + [char]0x23CE + ' ', $parts)
}

# ---------------- project file selection ----------------
function WbGlobRe([string]$g) {
  $t = $g.Trim($script:WSC)
  $t = [regex]::Replace($t, '[.+^${}()|\[\]\\]', '\$&')
  $t = $t.Replace('**', [string][char]1).Replace('*', '[^/]*').Replace([string][char]1, '[^\n\r\u2028\u2029]*').Replace('?', '[^/]')
  return New-Object System.Text.RegularExpressions.Regex(('^' + $t + '\z'))
}
function WbArg([string]$a) {
  if ($a.Length -gt 0 -and -not [regex]::IsMatch($a, '[\s"]')) { return $a }
  $s = [regex]::Replace($a, '(\\*)"', '$1$1\"')
  $s = [regex]::Replace($s, '(\\+)\z', '$1$1')
  return '"' + $s + '"'
}
function WbGitList([string]$dir) {
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = '-C ' + (WbArg $dir) + ' ls-files -co --exclude-standard -z'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $errTask = $p.StandardError.ReadToEndAsync()
    $ms = New-Object System.IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { return $null }
    $txt = $script:Utf8.GetString($ms.ToArray())
    $res = New-Object 'System.Collections.Generic.List[string]'
    foreach ($x in $txt.Split([char]0)) { if ($x.Length -gt 0) { $res.Add($x) } }
    return ,$res
  } catch { return $null }
}
function WbWalk([string]$d, [string]$prefix, $out) {
  $sep = [System.IO.Path]::DirectorySeparatorChar
  foreach ($e in [System.IO.Directory]::GetFileSystemEntries($d)) {
    $name = [System.IO.Path]::GetFileName($e)
    if ($name.StartsWith('.', [StringComparison]::Ordinal) -or $name -ceq 'node_modules') { continue }
    $rel = $prefix + $name
    $isDir = [System.IO.Directory]::Exists($e)
    if ($isDir) { try { $isDir = -not (([System.IO.File]::GetAttributes($e) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) } catch { } }
    if ($isDir) { WbWalk $e ($rel + '/') $out } else { $out.Add($rel) }
  }
}
function WbCollect([string]$dir) {
  $maxKb = WbToNumber (Opt '--max-kb' 300)
  $incl = New-Object 'System.Collections.Generic.List[object]'; $excl = New-Object 'System.Collections.Generic.List[object]'
  foreach ($x in ([string](Opt '--include' '')).Split(',')) { if ($x.Length -gt 0) { $incl.Add((WbGlobRe $x)) } }
  foreach ($x in ([string](Opt '--exclude' '')).Split(',')) { if ($x.Length -gt 0) { $excl.Add((WbGlobRe $x)) } }
  $withTests = HasFlag '--tests'; $withCfg = HasFlag '--config'
  $mode = 'git'
  $rels = WbGitList $dir
  if ($null -eq $rels) { $mode = 'walk'; $rels = New-Object 'System.Collections.Generic.List[string]'; WbWalk $dir '' $rels }
  $reasons = WbNewMap; $samples = WbNewMap; $included = New-Object 'System.Collections.Generic.List[object]'
  $why = ''
  foreach ($rel in $rels) {
    $abs = [System.IO.Path]::Combine($dir, $rel)
    $parts = $rel.Split('/'); $name = $parts[$parts.Length - 1]
    $ext = ''; if ($name.Contains('.')) { $ext = WbLower ($name.Split('.')[-1]) }
    if (-not [System.IO.File]::Exists($abs)) { continue }
    $forced = $false
    foreach ($r in $incl) { if ($r.IsMatch($rel)) { $forced = $true; break } }
    $skipWhy = $null
    foreach ($r in $excl) { if ($r.IsMatch($rel)) { $skipWhy = 'excluded by --exclude'; break } }
    if ($null -eq $skipWhy -and -not $forced) {
      $hidden = $false; foreach ($x in $parts) { if ($x.StartsWith('.', [StringComparison]::Ordinal)) { $hidden = $true; break } }
      $inSkipDir = $false; for ($pi = 0; $pi -lt $parts.Length - 1; $pi++) { if ($script:SKIP_DIRS.Contains($parts[$pi])) { $inSkipDir = $true; break } }
      $kind = $null
      if ($ext -ceq 'md' -or $ext -ceq 'markdown') { $kind = 'doc' } elseif ($script:CODE_EXT.ContainsKey($ext)) { $kind = 'code' } elseif ($script:CFG_EXT.Contains($ext)) { $kind = 'config' }
      if ($hidden) { $skipWhy = 'hidden file or directory' }
      elseif ($inSkipDir) { $skipWhy = 'generated / vendored / fixture directory' }
      elseif ($script:reSecret.IsMatch($rel)) { $skipWhy = 'looks like a secret or key file (never sent to a model; use --include to override)' }
      elseif ($script:LOCKS.Contains((WbLower $name))) { $skipWhy = 'lockfile' }
      elseif ($script:reMinMap.IsMatch($name)) { $skipWhy = 'minified / sourcemap' }
      elseif ($null -eq $kind) { $skipWhy = 'other file type (binary, media, text data)' }
      elseif ($kind -ceq 'config' -and -not $withCfg) { $skipWhy = 'config file (add --config to include)' }
      elseif ($kind -ceq 'code' -and -not $withTests -and $script:reTest.IsMatch($rel)) { $skipWhy = 'test file (add --tests to include)' }
      else {
        $size = (New-Object System.IO.FileInfo($abs)).Length
        if ($kind -cne 'doc' -and $size -gt $maxKb * 1024) { $skipWhy = 'source file larger than ' + (WbNum $maxKb) + ' KB (add --max-kb or --include)' }
        elseif ($kind -ceq 'doc' -and $size -gt 8 * 1024 * 1024) { $skipWhy = 'markdown larger than 8 MB' }
      }
    }
    if ($null -eq $skipWhy) {
      $buf = [System.IO.File]::ReadAllBytes($abs)
      if ([Array]::IndexOf($buf, [byte]0, 0, [Math]::Min(4096, $buf.Length)) -ge 0) { $skipWhy = 'binary' }
      elseif (-not $forced) {
        $head = $script:Utf8.GetString($buf, 0, [Math]::Min(600, $buf.Length)).Split([char]10)
        $head = [string]::Join("`n", $head, 0, [Math]::Min(6, $head.Length))
        if ($script:reGen.IsMatch($head)) { $skipWhy = 'generated code header' }
      }
    }
    if ($null -ne $skipWhy) {
      if ($reasons.Contains($skipWhy)) { $reasons[$skipWhy] = [int]$reasons[$skipWhy] + 1 } else { $reasons[$skipWhy] = 1; $samples[$skipWhy] = (WbNewList) }
      if ($samples[$skipWhy].Count -lt 3) { $samples[$skipWhy].Add($rel) }
      continue
    }
    $included.Add(@{ abs = $abs; rel = $rel })
  }
  return @{ files = $included; mode = $mode; reasons = $reasons; samples = $samples; total = $rels.Count }
}

# ---------------- split ----------------
function CmdSplit {
  if ($script:Pos.Count -eq 0) { WbDie 'usage: split <dir|file...> --work W [--tests] [--config] [--max-kb 300] [--include globs] [--exclude globs]' }
  $report = $null; $files = $null; $ROOT = $null
  if ($script:Pos.Count -eq 1 -and [System.IO.Directory]::Exists($script:Pos[0])) {
    $ROOT = WbResolve $script:Pos[0]; $report = WbCollect $ROOT; $files = $report['files']
  } else {
    foreach ($f in $script:Pos) { if (-not [System.IO.File]::Exists($f) -and -not [System.IO.Directory]::Exists($f)) { WbDie ("Error: ENOENT: no such file or directory, stat '" + $f + "'") } }
    $files = New-Object 'System.Collections.Generic.List[object]'
    $abss = @($script:Pos | ForEach-Object { WbResolve $_ })
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    $ROOT = WbDirName $abss[0]
    while ($true) {
      $okAll = $true; foreach ($a in $abss) { if (-not $a.StartsWith($ROOT + $sep, [StringComparison]::Ordinal)) { $okAll = $false; break } }
      if ($okAll) { break }
      $par = WbDirName $ROOT
      if ($par -ceq $ROOT) { break }
      $ROOT = $par
    }
    foreach ($a in $abss) { $files.Add(@{ abs = $a; rel = $a.Substring($ROOT.Length + 1).Replace($sep, '/') }) }
  }
  $keys = New-Object 'string[]' $files.Count
  for ($i = 0; $i -lt $files.Count; $i++) { $keys[$i] = WbLower $files[$i]['rel'] }
  $files = [object[]](WbSortByKey ([object[]]$files.ToArray()) $keys)
  $sbP = New-Object System.Text.StringBuilder; $sbF = New-Object System.Text.StringBuilder
  $fl = New-Object 'System.Collections.Generic.List[object]'
  $nPieces = 0; $nCode = 0; $wsc = $script:WSC
  for ($fi = 0; $fi -lt $files.Length; $fi++) {
    $rel = $files[$fi]['rel']
    $bytes = [System.IO.File]::ReadAllBytes($files[$fi]['abs']); $raw = $script:Utf8.GetString($bytes)
    $L = WbSplitLines $raw
    if ($L[$L.Length - 1].Length -eq 0) { $L2 = New-Object 'string[]' ($L.Length - 1); [Array]::Copy($L, $L2, $L.Length - 1); $L = $L2 }
    $ext = WbLower ($rel.Split('.')[-1])
    $lang = $null; if ($script:CODE_EXT.ContainsKey($ext)) { $lang = $script:CODE_EXT[$ext] }
    $first = $nPieces + 1
    if ($null -ne $lang) {
      foreach ($u in (WbPack $L (WbCodeUnits $L $lang) 200 40 $true)) {
        $nPieces++; $nCode++
        if ($sbP.Length -gt 0) { [void]$sbP.Append(",`n") }
        [void]$sbP.Append('{"i":').Append($nPieces).Append(',"f":').Append($fi).Append(',"s":').Append($u['s']).Append(',"e":').Append($u['e']).Append(',"w":').Append($u['w']).Append(',"hp":"","k":"c","lang":').Append((WbJStr $lang)).Append(',"sn":').Append((WbJStr (WbCodeSnippet $L $u['s'] $u['e']))).Append('}')
      }
    } else {
      foreach ($p in (WbMdPieces $L)) {
        $nPieces++
        if ($sbP.Length -gt 0) { [void]$sbP.Append(",`n") }
        $sn = WbSnip ([string]::Join("`n", $L, $p['s'] - 1, $p['e'] - $p['s'] + 1)) 18
        [void]$sbP.Append('{"i":').Append($nPieces).Append(',"f":').Append($fi).Append(',"s":').Append($p['s']).Append(',"e":').Append($p['e']).Append(',"w":').Append($p['w']).Append(',"hp":').Append((WbJStr $p['hp'])).Append(',"sn":').Append((WbJStr $sn)).Append('}')
      }
    }
    $langOut = $(if ($null -ne $lang) { $lang } else { 'md' })
    $rec = @{ rel = $rel; bytes = $script:Utf8.GetByteCount($raw); first = $first; last = $nPieces; lang = $langOut; h = (WbSha1 $bytes) }
    $fl.Add($rec)
    if ($sbF.Length -gt 0) { [void]$sbF.Append(",`n") }
    [void]$sbF.Append('{"rel":').Append((WbJStr $rel)).Append(',"bytes":').Append($rec['bytes']).Append(',"first":').Append($first).Append(',"last":').Append($nPieces).Append(',"lang":').Append((WbJStr $langOut)).Append(',"h":"').Append($rec['h']).Append('"}')
  }
  if ($null -ne $report) {
    $by = WbNewMap
    foreach ($f in $fl) { $k = $f['lang']; if ($by.Contains($k)) { $by[$k] = [int]$by[$k] + 1 } else { $by[$k] = 1 } }
    $modeTxt = $(if ($report['mode'] -ceq 'git') { 'git: tracked + untracked, honouring .gitignore' } else { 'directory walk' })
    WbOut ("selection ($modeTxt): $($files.Length) of $($report['total']) files included")
    WbOut ('  included: ' + (($by.Keys | ForEach-Object { "$($by[$_]) $_" }) -join ', '))
    $reasons = $report['reasons']
    $rk = [object[]]@($reasons.Keys)
    $rn = New-Object 'double[]' $rk.Length
    for ($i = 0; $i -lt $rk.Length; $i++) { $rn[$i] = [double]$reasons[$rk[$i]] }
    foreach ($why in (WbSortByNum $rk $rn $true)) { WbOut ('  skipped ' + ([string]$reasons[$why]).PadLeft(4) + '  ' + $why + '   e.g. ' + ($report['samples'][$why] -join ', ')) }
    [void][System.IO.Directory]::CreateDirectory($script:WORK)
    $sel = [ordered]@{ included = (WbNewList); reasons = $reasons; samples = $report['samples'] }
    foreach ($f in $fl) { $sel['included'].Add($f['rel']) }
    WbWriteText (Wp 'selection.json') (WbToJson $sel $true)
  }
  if ($nPieces -eq 0) { WbDie 'ERROR: nothing to analyse: no pieces were found in the selected files (see the skipped counts above; try --tests, --config or --include)' }
  # families (name-2, name-3 stay together), contiguous balanced groups by bytes
  $fam = New-Object 'System.Collections.Generic.List[object]'
  foreach ($f in $fl) {
    $k = $script:reFam.Replace($f['rel'], '$1')
    if ($fam.Count -gt 0 -and $fam[$fam.Count - 1]['k'] -ceq $k) { $fam[$fam.Count - 1]['files'].Add($f) } else { $fl2 = New-Object 'System.Collections.Generic.List[object]'; $fl2.Add($f); $fam.Add(@{ k = $k; files = $fl2; bytes = 0 }) }
  }
  $total = [double]0
  foreach ($x in $fam) { $b = 0; foreach ($f in $x['files']) { $b += $f['bytes'] }; $x['bytes'] = $b; $total += $b }
  $M = [Math]::Max(1, [Math]::Min($fam.Count, [Math]::Floor([Math]::Sqrt($files.Length))))
  $groups = New-Object 'System.Collections.Generic.List[object]'; $cur = New-Object 'System.Collections.Generic.List[object]'; $cum = [double]0
  for ($idx = 0; $idx -lt $fam.Count; $idx++) {
    $cur.Add($fam[$idx]); $cum += $fam[$idx]['bytes']
    $left = $fam.Count - $idx - 1; $need = $M - $groups.get_Count() - 1
    if ($groups.get_Count() -lt $M - 1 -and ($cum -ge $total * ($groups.get_Count() + 1) / $M -or $left -le $need)) { $groups.Add($cur); $cur = New-Object 'System.Collections.Generic.List[object]' }
  }
  if ($cur.Count -gt 0) { $groups.Add($cur) }
  $GL = New-Object 'System.Collections.Generic.List[object]'
  $WIN = $script:WIN
  for ($gi = 0; $gi -lt $groups.get_Count(); $gi++) {
    $gfiles = New-Object 'System.Collections.Generic.List[object]'; $gbytes = 0
    foreach ($x in $groups[$gi]) { foreach ($f in $x['files']) { $gfiles.Add($f) }; $gbytes += $x['bytes'] }
    $from = $gfiles[0]['first']; $to = $gfiles[$gfiles.Count - 1]['last']
    $windows = New-Object 'System.Collections.Generic.List[object]'; $ws = $from
    while ($ws -le $to) {
      $we = [Math]::Min($to, $ws + $WIN - 1)
      if ($we -lt $to) {
        $best = $null
        foreach ($f in $gfiles) {
          if ($f['last'] -ge $ws + $WIN * 0.7 -and $f['last'] -le [Math]::Min($to, $ws + $WIN * 1.3)) {
            if ($null -eq $best -or [Math]::Abs($f['last'] - ($ws + $WIN - 1)) -lt [Math]::Abs($best - ($ws + $WIN - 1))) { $best = $f['last'] }
          }
        }
        if ($null -ne $best) { $we = $best }
      }
      $windows.Add([ordered]@{ w = ($windows.Count + 1); from = $ws; to = $we }); $ws = $we + 1
    }
    $names = WbNewList; foreach ($f in $gfiles) { $names.Add($f['rel']) }
    $GL.Add([ordered]@{ g = ($gi + 1); files = $names; bytes = $gbytes; from = $from; to = $to; windows = $windows })
  }
  [void][System.IO.Directory]::CreateDirectory((Wp 'out')); [void][System.IO.Directory]::CreateDirectory((Wp 'desc'))
  $rootJ = WbJStr $ROOT
  WbWriteText (Wp 'pieces.json') ('{"root":' + $rootJ + ',"files":[' + "`n" + $sbF.ToString() + "`n" + '],"pieces":[' + "`n" + $sbP.ToString() + "`n" + ']}' + "`n")
  WbWriteText (Wp 'groups.json') (WbToJson $GL $true)
  WbOut "$($files.Length) files, $nPieces pieces -> $($GL.Count) groups"
  $nw = 0; $longest = [double]::NegativeInfinity
  foreach ($x in $GL) { $c = $x['windows'].Count; $nw += $c; if ($c -gt $longest) { $longest = $c } }
  $agents = [Math]::Floor($nw * 1.2 + $GL.Count + $nPieces / 150 + 6 + 0.5)
  $minutes = [Math]::Floor($longest * 3.2 + 6 + [Math]::Min(10, $nPieces / 1500) + 0.5)
  $est = [ordered]@{ pieces = $nPieces; docPieces = ($nPieces - $nCode); codePieces = $nCode; windows = $nw; groups = $GL.Count; agents = $agents; tokensM = ([Math]::Floor(($agents * 6 + 5) / 10) / 10); minutes = $minutes }
  WbWriteText (Wp 'estimate.json') (WbToJson $est $false)
  PrintEstimate $est
  foreach ($x in $GL) { WbOut ("  group $($x['g']): $($x['files'].Count) files, $([Math]::Floor($x['bytes'] / 1024)) KB, $($x['to'] - $x['from'] + 1) pieces, $($x['windows'].Count) windows") }
}

# ---------------- cost estimate ----------------
function EstNum($e, [string]$k) {
  if ($e.Contains($k)) { $v = $e[$k]; if ($null -eq $v) { return 'null' } return (WbNum $v) }
  return 'undefined'
}
function PrintEstimate($e) {
  WbOut ("estimate: ~$(EstNum $e 'agents') haiku agents, ~$(EstNum $e 'tokensM')M tokens, ~$(EstNum $e 'minutes') min wall-clock ($(EstNum $e 'docPieces') doc + $(EstNum $e 'codePieces') code pieces, $(EstNum $e 'windows') windows). Rough: real runs landed within 0.5x-2x.")
}
function CmdEstimate { PrintEstimate (ReadJ (Wp 'estimate.json')) }

# ---------------- shared readers ----------------
$script:reKV = New-Object System.Text.RegularExpressions.Regex('"([A-Za-z]+)":(?:"([^"\\]*(?:\\[\s\S][^"\\]*)*)"|(-?[0-9]+))')
function ReadFlat([string]$line) {
  if ($line.Length -lt 2 -or $line[0] -ne [char]123 -or $line[$line.Length - 1] -ne [char]125) { return $null }
  $o = @{}
  foreach ($m in $script:reKV.Matches($line)) {
    if ($m.Groups[2].Success) { $o[$m.Groups[1].Value] = $(if ($m.Groups[2].Value.IndexOf([char]92) -ge 0) { WbJUnesc ('"' + $m.Groups[2].Value + '"') } else { $m.Groups[2].Value }) }
    else { $o[$m.Groups[1].Value] = [long]$m.Groups[3].Value }
  }
  return $o
}
function ReadPieces([string]$path) {
  $text = WbReadText $path
  $lines = $text.Split([char]10)
  $ip = [Array]::IndexOf($lines, '],"pieces":[')
  $ok = ($ip -gt 0 -and $lines.Length -ge $ip + 3 -and $lines[$lines.Length - 1].Length -eq 0 -and $lines[$lines.Length - 2] -ceq ']}')
  if ($ok) {
    $m = [regex]::Match($lines[0], '^\{"root":("[^"\\]*(?:\\[\s\S][^"\\]*)*"),"files":\[\z')
    if (-not $m.Success) { $ok = $false }
  }
  if ($ok) {
    $files = WbNewList; $pieces = WbNewList
    for ($i = 1; $i -lt $ip -and $ok; $i++) { $l = $lines[$i]; if ($l.EndsWith(',')) { $l = $l.Substring(0, $l.Length - 1) }; $o = ReadFlat $l; if ($null -eq $o) { $ok = $false } else { $files.Add($o) } }
    for ($i = $ip + 1; $i -lt $lines.Length - 2 -and $ok; $i++) {
      $l = $lines[$i]; if ($l.Length -eq 0) { continue }
      if ($l[$l.Length - 1] -eq [char]44) { $l = $l.Substring(0, $l.Length - 1) }
      $o = ReadFlat $l; if ($null -eq $o) { $ok = $false } else { $pieces.Add($o) }
    }
    if ($ok) { return @{ root = (WbJUnesc $m.Groups[1].Value); files = $files; pieces = $pieces } }
  }
  $o = WbJsonParse $text
  return @{ root = $o['root']; files = $o['files']; pieces = $o['pieces'] }
}
$script:Pc = $null; $script:Gc = $null
function P { if ($null -eq $script:Pc) { $script:Pc = ReadPieces (Wp 'pieces.json') }; return ,$script:Pc }
function GR { if ($null -eq $script:Gc) { $script:Gc = ReadJ (Wp 'groups.json') }; return ,$script:Gc }
function OutPath($g, $w) { return (Wp 'out' ('g' + (WbNum $g) + '-w' + (WbNum $w) + '.txt')) }
function SumPath($g, $w) { return (Wp 'out' ('g' + (WbNum $g) + '-w' + (WbNum $w) + '.sum')) }
function FindG($g) { foreach ($x in (GR)) { if ([double]$x['g'] -eq $g) { return ,$x } }; return $null }
function FindW($G, $w) { foreach ($x in $G['windows']) { if ([double]$x['w'] -eq $w) { return ,$x } }; return $null }
function ReadOut($g, $w) {
  $f = OutPath $g $w
  if (-not [System.IO.File]::Exists($f)) { return $null }
  $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($l0 in (WbReadText $f).Split([char]10)) {
    $l = $l0.Trim($script:WSC)
    if ($l.Length -eq 0) { continue }
    $k = $l.IndexOf(';'); $rest = WbSub $l ($k + 1) $null; $k2 = $rest.IndexOf(';')
    if ($k2 -lt 0) { $path = $rest } else { $path = $rest.Substring(0, $k2) }
    $rows.Add(@{ id = (WbToNumber (WbSub $l 0 $k)); path = $path.Trim($script:WSC); desc = $(if ($k2 -lt 0) { '' } else { $rest.Substring($k2 + 1).Trim($script:WSC) }) })
  }
  return ,$rows
}
function SegsOk([string]$s) {
  $w = $s.Trim($script:WSC).Split($script:WSC, [System.StringSplitOptions]::RemoveEmptyEntries).Length
  return ($w -ge 2 -and $w -le 4 -and $s.IndexOf(';') -lt 0)
}
function PieceAt($id) {
  $P = P
  $d = [double]$id
  if ([double]::IsNaN($d) -or $d -lt 1 -or $d -gt $P['pieces'].Count -or $d -ne [Math]::Floor($d)) { return $null }
  return ,$P['pieces'][[int]$d - 1]
}
function RelOf($f) { return [string](P)['files'][[int]$f]['rel'] }

# ---------------- window ----------------
$script:TplWindow = @'
TASK  (group @@G@@, window @@W@@/@@NW@@: pieces @@FROM@@-@@TO@@)
You are building one branch of an outline of a project (documentation and/or source code). Below are NUMBERED PIECES (short excerpts, in document order).
Place every piece in a tree by writing ONE LINE per piece:

    <id>;<Theme>/<Sub Theme>/.../<Piece Title>@@CODEFMT@@

RULES
- Every id from @@FROM@@ to @@TO@@ exactly once, ascending. Nothing else in the file (no comments, no blank explanations).
- Each path segment is 2-4 words, Title Case, no ";" "/" quotes or trailing punctuation. The LAST segment names that piece's single idea; the segments before it are branches.
- Depth 3 to 5 segments. Aim for 2-9 children per branch: split a bigger one by adding a sub-branch level; do not make single-child branches.
- Group by MEANING, not blindly by heading or file: consecutive pieces of one section usually share a branch, but a heading is only a hint.
- Reuse branches from EXISTING BRANCHES below (exact spelling) when a piece belongs there; add new branches only when needed.
- Full paths must be unique, and one piece's path must never equal a prefix of another's.
- Never use a bare requirement id as a segment ("R-012" alone); "R-012 Black Keys" is fine.
@@CODERULES@@
DO THIS
1. Write the lines to  @@OUT@@  with the Write tool.
2. Write a summary (max 60 words, plain text) to  @@SUM@@  saying what this group covers so far (build on the previous summary).
3. Run:  @@LAUNCH@@ @@SELF@@ check @@G@@ @@W@@ --work @@WORKQ@@   and fix the files until it prints OK.
Reply with just "done".

PREVIOUS SUMMARY: @@PREV@@

EXISTING BRANCHES (path (pieces so far)):
@@VOCAB@@

PIECES
'@
$script:TplCodeRules = @'

CODE PIECES (marked [code <lang>]) - INVERT THE CODE INTO SPECIFICATION
- For every [code] piece write ONE EXTRA FIELD, the description:  <id>;<path>;<description>   (required for code pieces, never for documentation pieces).
- The description states WHAT the system does or guarantees at that point, as a requirement a reader could re-implement from: behaviour, inputs/outputs, rules, invariants, error handling, side effects. Plain present-tense English, 1-2 sentences, at most 40 words, no ";" and no code. Do not narrate the code ("loops over...", "calls..."); name public identifiers only when the behaviour depends on them.
- Path segments name CAPABILITIES and behaviours ("Retry Failed Deployments", "Reject Expired Tokens"), never files, packages, functions or types. Group by capability across files, not by directory layout.
- Imports, boilerplate and trivial glue still get a piece line (path ending like "Module Setup") with a few-word description.

'@
function CmdWindow {
  $g = PosNum 0; $w = PosNum 1; $grp = FindG $g
  if ($null -eq $grp) { WbDie 'no such group' }
  $win = FindW $grp $w
  if ($null -eq $win) { WbDie 'no such window' }
  $PD = P; $pcs = $PD['pieces']
  $prevSum = ''
  if ($w -gt 1 -and [System.IO.File]::Exists((SumPath $g ($w - 1)))) { $prevSum = (WbReadText (SumPath $g ($w - 1))).Trim($script:WSC) }
  $vocab = WbNewMap
  for ($k = 1; $k -lt $w; $k++) {
    $rows = ReadOut $g $k
    if ($null -eq $rows) { continue }
    foreach ($r in $rows) {
      $s = $r['path'].Split('/'); $nn = $s.Length - 1
      for ($d = 1; $d -le [Math]::Min(3, $nn); $d++) { $p = [string]::Join('/', $s, 0, $d); if ($vocab.Contains($p)) { $vocab[$p] = [int]$vocab[$p] + 1 } else { $vocab[$p] = 1 } }
    }
  }
  $vk = [string[]]@($vocab.Keys); $vl = [object[]](WbSortByKey ([object[]]$vk) $vk)
  if ($vl.Length -gt 160) { $vl = [object[]]@($vl | Where-Object { $_.Split('/').Length -le 2 }) }
  $out = WbQ (WbResolve (OutPath $g $w)); $sum = WbQ (WbResolve (SumPath $g $w))
  $from = [long]$win['from']; $to = [long]$win['to']
  $hasCode = $false
  for ($i = $from; $i -le $to; $i++) { if ($pcs[[int]$i - 1]['k'] -ceq 'c') { $hasCode = $true; break } }
  $vtxt = $(if ($vl.Length -gt 0) { [string]::Join("`n", @($vl | ForEach-Object { "$_ ($($vocab[$_]))" })) } else { '(none yet)' })
  $map = @{ G = (WbNum $g); W = (WbNum $w); NW = $grp['windows'].Count; FROM = $from; TO = $to; CODEFMT = $(if ($hasCode) { '[;<description> for code pieces]' } else { '' }); CODERULES = $(if ($hasCode) { $script:TplCodeRules.Replace("`r`n", "`n").TrimEnd("`n") + "`n" } else { '' }); OUT = $out; SUM = $sum; LAUNCH = $script:Launch; SELF = $script:SELF; WORKQ = (WbQ $script:WORK); PREV = $(if ($prevSum.Length -gt 0) { $prevSum } else { '(first window)' }); VOCAB = $vtxt }
  WbOut (WbTpl $script:TplWindow $map)
  $lastF = -1; $lastHp = $null
  for ($i = $from; $i -le $to; $i++) {
    $p = $pcs[[int]$i - 1]
    if ($p['f'] -ne $lastF) { WbOut ("`n## FILE " + (RelOf $p['f'])); $lastF = $p['f']; $lastHp = $null }
    if ($p['k'] -ceq 'c') { WbOut ("$($p['i']) [code $($p['lang'])] $($p['sn'])"); continue }
    if ($null -eq $lastHp -or $p['hp'] -cne $lastHp) { $hh = $p['hp']; if ($hh.Length -eq 0) { $hh = '(no heading)' }; WbOut ("# $hh"); $lastHp = $p['hp'] }
    WbOut ("$($p['i']) $($p['sn'])")
  }
}

# ---------------- check ----------------
function CheckWindow($g, $w) {
  $grp = FindG $g; $win = FindW $grp $w
  $errs = New-Object 'System.Collections.Generic.List[string]'
  $rows = ReadOut $g $w
  if ($null -eq $rows) { $errs.Add((OutPath $g $w) + ' not found'); return ,$errs }
  $wfrom = [double]$win['from']; $wto = [double]$win['to']
  $seen = New-Object 'System.Collections.Generic.HashSet[double]'; $paths = WbNewMap
  $n = 0
  foreach ($r in $rows) {
    $n++
    $id = $r['id']
    if (-not (WbIsInt $id) -or $id -lt $wfrom -or $id -gt $wto) { $errs.Add("line ${n}: bad id `"$(WbNum $id)`" (need $(WbNum $wfrom)-$(WbNum $wto), format id;path)"); continue }
    if (-not $seen.Add([double]$id)) { $errs.Add("id $(WbNum $id) appears twice") }
    $s = $r['path'].Split('/')
    if ($s.Length -lt 2 -or $s.Length -gt 6) { $errs.Add("id $(WbNum $id): depth $($s.Length) (need 3-5 segments, minimum 2)") }
    foreach ($x in $s) { if (-not (SegsOk $x)) { $errs.Add("id $(WbNum $id): segment `"$x`" must be 2-4 words") } }
    $pc = PieceAt $id
    if ($null -ne $pc -and $pc['k'] -ceq 'c') {
      $dw = WbW $r['desc']
      if ($r['desc'].Length -eq 0) { $errs.Add("id $(WbNum $id): code piece needs a description (id;path;description)") }
      elseif ($dw -gt 45) { $errs.Add("id $(WbNum $id): description has $dw words (max 40)") }
    }
    if ($paths.Contains($r['path'])) { $errs.Add("id $(WbNum $id): path duplicates id $(WbNum $paths[$r['path']]) (`"$($r['path'])`")") }
    $paths[$r['path']] = $id
  }
  # first path (in insertion order) that has a row's path as a proper prefix, via a prefix table
  $pf = New-Object 'System.Collections.Generic.Dictionary[string,object]'
  foreach ($p in $paths.Keys) {
    $at = $p.IndexOf('/')
    while ($at -ge 0) { $pre = $p.Substring(0, $at); if (-not $pf.ContainsKey($pre)) { $pf[$pre] = $paths[$p] }; $at = $p.IndexOf('/', $at + 1) }
  }
  foreach ($r in $rows) { if ($pf.ContainsKey($r['path'])) { $errs.Add("id $(WbNum $r['id']): path `"$($r['path'])`" is also a prefix of id $(WbNum $pf[$r['path']])'s path") } }
  $miss = New-Object 'System.Collections.Generic.List[string]'
  for ($i = $wfrom; $i -le $wto; $i++) { if (-not $seen.Contains([double]$i)) { $miss.Add((WbNum $i)) } }
  if ($miss.Count -gt 0) { $errs.Add("$($miss.Count) ids missing: $([string]::Join(',', $miss.GetRange(0, [Math]::Min(20, $miss.Count))))$(if ($miss.Count -gt 20) { $script:Ellipsis } else { '' })") }
  $sf = SumPath $g $w
  if (-not [System.IO.File]::Exists($sf)) { $errs.Add("summary file $sf missing") }
  elseif ((WbW (WbReadText $sf)) -gt 120) { $errs.Add('summary longer than 120 words') }
  return ,$errs
}
function PrintErrs($errs, [int]$cap, [bool]$more) {
  $lines = New-Object 'System.Collections.Generic.List[string]'
  for ($i = 0; $i -lt [Math]::Min($cap, $errs.Count); $i++) { $lines.Add('ERROR: ' + $errs[$i]) }
  $t = [string]::Join("`n", $lines)
  if ($more -and $errs.Count -gt $cap) { $t += "`n" + $script:Ellipsis + ' ' + ($errs.Count - $cap) + ' more' }
  WbOut $t
}
function CmdCheck {
  $g = PosNum 0; $w = PosNum 1
  $grp = FindG $g; if ($null -eq $grp -or $null -eq (FindW $grp $w)) { WbDie "TypeError: Cannot read properties of undefined (no such group or window)" }
  $errs = CheckWindow $g $w
  if ($errs.Count -gt 0) { PrintErrs $errs 40 $true; WbExit 1 }
  WbOut 'OK'
}
function CmdCheckAll {
  $bad = New-Object 'System.Collections.Generic.List[object]'
  foreach ($G in (GR)) { foreach ($w in $G['windows']) { $e = CheckWindow $G['g'] $w['w']; if ($e.Count -gt 0) { $bad.Add(@{ g = $G['g']; w = $w['w']; first = $e[0] }) } } }
  $failing = WbNewList; $detail = WbNewList
  foreach ($b in $bad) { $failing.Add([ordered]@{ g = $b['g']; w = $b['w'] }) }
  for ($i = 0; $i -lt [Math]::Min(10, $bad.Count); $i++) { $detail.Add([ordered]@{ g = $bad[$i]['g']; w = $bad[$i]['w']; first = $bad[$i]['first'] }) }
  WbOut (WbToJson ([ordered]@{ failing = $failing; detail = $detail }) $false)
}

# ---------------- group trees / merge ----------------
function GroupRows($g) {
  $grp = FindG $g; $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($w in $grp['windows']) { $r = ReadOut $g $w['w']; if ($null -ne $r) { $rows.AddRange($r) } }
  return ,$rows
}
function CmdStatus {
  $done = 0; $tot = 0; $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($G in (GR)) {
    $d = 0
    foreach ($w in $G['windows']) {
      $tot++; $r = ReadOut $G['g'] $w['w']
      if ($null -ne $r -and $r.Count -eq [double]$w['to'] - [double]$w['from'] + 1 -and [System.IO.File]::Exists((SumPath $G['g'] $w['w']))) { $d++; $done++ }
    }
    $lines.Add("group $(WbNum $G['g']): $d/$($G['windows'].Count) windows")
  }
  WbOut ([string]::Join("`n", $lines) + "`n$done/$tot windows done")
}
$script:TplMerge = @'
TASK
Several agents each outlined a part ("group") of one big specification. Merge their outlines into ONE coherent tree.
Each line under GROUPS is a top-level branch of one group:  <group>;<Top Segment>  [pieces]  children...
Decide where every such branch is mounted in the final tree by writing ONE LINE per (group, top segment):

    <group>;<Top Segment exactly as shown>;<New/Path/Prefix>

The pieces below  <Top Segment>  are re-mounted under  <New/Path/Prefix>  (the top segment is replaced by the prefix).
RULES
- Every (group, top segment) listed exactly once; copy the group number and segment text exactly.
- The final tree must have 3 to 8 top-level branches (first segments of New Path Prefix), each 2-4 words, Title Case.
- Different groups/segments covering the same theme MUST be given the same prefix so they merge into one branch (e.g. several "Screens ..." segments from groups 4-6 all go under "Frontend/Screens And Navigation").
- Prefix has 1 or 2 segments (each 2-4 words, Title Case, no ";" or quotes). Use 2 when a theme needs a parent so that no branch ends up with more than ~9 children. Keep the original document order of themes where possible.
- Don't invent content; do not drop any branch.
Write the lines to @@MERGE@@ with the Write tool, then run:  @@LAUNCH@@ @@SELF@@ apply-merge --work @@WORKQ@@   and fix the file until it prints OK. Reply with just "done".

GROUPS@@LINES@@
'@
function CmdMergeInput {
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($G in (GR)) {
    $rows = GroupRows $G['g']
    if ($rows.Count -eq 0) { WbDie "group $(WbNum $G['g']) has no output yet" }
    $last = $null
    foreach ($w in $G['windows']) { if ([System.IO.File]::Exists((SumPath $G['g'] $w['w']))) { $last = $w['w'] } }
    $sum = ''; if ($null -ne $last) { $sum = (WbReadText (SumPath $G['g'] $last)).Trim($script:WSC) }
    $top = WbNewMap
    foreach ($r in $rows) {
      $s = $r['path'].Split('/'); $t = $s[0]
      if (-not $top.Contains($t)) { $top[$t] = @{ n = 0; sub = (WbNewMap) } }
      $o = $top[$t]; $o['n'] = $o['n'] + 1
      if ($s.Length -gt 2) { if ($o['sub'].Contains($s[1])) { $o['sub'][$s[1]] = [int]$o['sub'][$s[1]] + 1 } else { $o['sub'][$s[1]] = 1 } }
    }
    $fl = $G['files']; $first3 = [string]::Join(', ', $fl.GetRange(0, [Math]::Min(3, $fl.Count)))
    $lines.Add("`n### GROUP $(WbNum $G['g'])  ($($fl.Count) files: $first3$(if ($fl.Count -gt 3) { ', ' + $script:Ellipsis } else { '' }); $($rows.Count) pieces)`nSummary: $sum")
    foreach ($t in $top.Keys) {
      $o = $top[$t]; $sk = @($o['sub'].Keys); $ch = @(); for ($i = 0; $i -lt [Math]::Min(8, $sk.Count); $i++) { $ch += "$($sk[$i]) ($($o['sub'][$sk[$i]]))" }
      $lines.Add("$(WbNum $G['g']);$t   [$($o['n']) pieces]  children: $([string]::Join(', ', $ch))")
    }
  }
  WbOut (WbTpl $script:TplMerge @{ MERGE = (WbQ (Wp 'merge.txt')); LAUNCH = $script:Launch; SELF = $script:SELF; WORKQ = (WbQ $script:WORK); LINES = [string]::Join("`n", $lines) })
}
function ReadMerge {
  $f = Wp 'merge.txt'
  if (-not [System.IO.File]::Exists($f)) { WbDie 'ERROR: merge.txt not found' }
  $res = New-Object 'System.Collections.Generic.List[object]'
  foreach ($l0 in (WbReadText $f).Split([char]10)) {
    $l = $l0.Trim($script:WSC); if ($l.Length -eq 0) { continue }
    $a = $l.Split(';')
    $top = ''; if ($a.Length -gt 1) { $top = $a[1].Trim($script:WSC) }
    $pre = ''; if ($a.Length -gt 2) { $pre = ([string]::Join(';', $a, 2, $a.Length - 2)).Trim($script:WSC) }
    $res.Add(@{ g = (WbToNumber $a[0]); top = $top; prefix = $pre })
  }
  return ,$res
}
function CmdApplyMerge {
  if ([System.IO.File]::Exists((Wp 'reshape.applied')) -and -not (HasFlag '--force')) { WbDie ('ERROR: reshape results were already applied to tree.paths; re-running apply-merge would discard them. Pass --force only if you want to start the reshape phase over (and delete ' + (Wp 'reshape.applied') + ').') }
  $MM = ReadMerge; $errs = New-Object 'System.Collections.Generic.List[string]'; $map = WbNewMap
  foreach ($m in $MM) {
    $k = (WbNum $m['g']) + ';' + $m['top']
    if ($map.Contains($k)) { $errs.Add("duplicate mapping for $k") }
    $map[$k] = $m['prefix']
    $s = $m['prefix'].Split('/'); $allOk = $true; foreach ($x in $s) { if (-not (SegsOk $x)) { $allOk = $false } }
    if ($m['prefix'].Length -eq 0 -or $s.Length -gt 2 -or -not $allOk) { $errs.Add("bad prefix `"$($m['prefix'])`" for $k (1-2 segments of 2-4 words)") }
  }
  $rowsAll = New-Object 'System.Collections.Generic.List[object]'
  foreach ($G in (GR)) {
    $rows = GroupRows $G['g']; $tops = WbNewMap
    foreach ($r in $rows) { $tops[$r['path'].Split('/')[0]] = 1 }
    foreach ($t in $tops.Keys) { if (-not $map.Contains((WbNum $G['g']) + ';' + $t)) { $errs.Add("missing mapping for $(WbNum $G['g']);$t") } }
    foreach ($r in $rows) {
      $s = $r['path'].Split('/'); $key = (WbNum $G['g']) + ';' + $s[0]
      if ($map.Contains($key)) { $pre = $map[$key]; if ($pre.Length -gt 0) { $rest = ''; if ($s.Length -gt 1) { $rest = [string]::Join('/', $s, 1, $s.Length - 1) }; $rowsAll.Add(@{ g = $G['g']; id = $r['id']; path = ($pre + '/' + $rest); desc = $r['desc'] }) } }
    }
  }
  $tops = WbNewMap; foreach ($v in $map.Values) { $tops[([string]$v).Split('/')[0]] = 1 }
  if ($tops.get_Count() -lt 3 -or $tops.get_Count() -gt 8) { $errs.Add("final tree has $($tops.get_Count()) top-level branches (need 3-8): $([string]::Join(' | ', @($tops.Keys)))") }
  if ($errs.Count -gt 0) { PrintErrs $errs 30 $false; WbExit 1 }
  $ra = [object[]]$rowsAll.ToArray(); $rk = New-Object 'double[]' $ra.Length
  for ($i = 0; $i -lt $ra.Length; $i++) { $rk[$i] = [double]$ra[$i]['id'] }
  $ra = [object[]](WbSortByNum $ra $rk $false)
  $used = New-Object 'System.Collections.Generic.HashSet[string]'; $prefixes = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($r in $ra) { $p = $r['path']; $at = $p.IndexOf('/'); while ($at -ge 0) { [void]$prefixes.Add($p.Substring(0, $at)); $at = $p.IndexOf('/', $at + 1) } }
  $fixes = 0
  foreach ($r in $ra) {
    $p = $r['path']; $n = 1
    while ($used.Contains($p) -or $prefixes.Contains($p)) {
      $n++; $s = $r['path'].Split('/'); $lastSeg = $s[$s.Length - 1]; $lw = $lastSeg.Split(' ')
      if ($lw.Length -ge 4) { $lastSeg = [string]::Join(' ', $lw, 0, 3) }
      $head = ''; if ($s.Length -gt 1) { $head = [string]::Join('/', $s, 0, $s.Length - 1) + '/' }
      $p = $head + $lastSeg + ' ' + $n
    }
    if ($p -cne $r['path']) { $fixes++; $r['path'] = $p }
    [void]$used.Add($p)
  }
  $PD = P; $sbT = New-Object System.Text.StringBuilder; $ld = WbNewMap
  foreach ($r in $ra) {
    $pc = PieceAt $r['id']; if ($null -eq $pc) { throw 'TypeError: piece not found' }
    $rg = (RelOf $pc['f']) + ':' + $pc['s'] + '-' + $pc['e']
    [void]$sbT.Append((WbNum $r['g'])).Append(';').Append($r['path']).Append(';').Append($rg).Append("`n")
    if ($pc['k'] -ceq 'c' -and $r['desc'].Length -gt 0) { $ld[$rg] = $r['desc'] }
  }
  if ($ra.Length -eq 0) { [void]$sbT.Append("`n") }
  WbWriteText (Wp 'tree.paths') $sbT.ToString()
  WbWriteText (Wp 'leafdesc.json') (WbToJson $ld $false)
  $kids = WbNewMap
  foreach ($r in $ra) {
    $s = $r['path'].Split('/')
    for ($d = 0; $d -lt $s.Length; $d++) {
      $par = ''; if ($d -gt 0) { $par = [string]::Join('/', $s, 0, $d) }
      if (-not $kids.Contains($par)) { $kids[$par] = New-Object 'System.Collections.Generic.HashSet[string]' }
      [void]$kids[$par].Add($s[$d])
    }
  }
  $wk = New-Object 'System.Collections.Generic.List[object]'
  foreach ($par in $kids.Keys) { if ($kids[$par].get_Count() -gt 9) { $wk.Add(@{ p = $par; n = $kids[$par].get_Count() }) } }
  $wa = [object[]]$wk.ToArray(); $wn = New-Object 'double[]' $wa.Length; for ($i = 0; $i -lt $wa.Length; $i++) { $wn[$i] = $wa[$i]['n'] }
  $wa = [object[]](WbSortByNum $wa $wn $true)
  WbOut ("OK  $($ra.Length) pieces, $($tops.get_Count()) top-level branches$(if ($fixes -gt 0) { ", $fixes path collisions auto-renamed" } else { '' })")
  if ($wa.Length -gt 0) {
    $worst = @(); for ($i = 0; $i -lt [Math]::Min(8, $wa.Length); $i++) { $pp = $wa[$i]['p']; if ($pp.Length -eq 0) { $pp = '(root)' }; $worst += "${pp}: $($wa[$i]['n'])" }
    WbOut ("$($wa.Length) branches have >9 children (worst: $([string]::Join('; ', $worst)))")
  }
}

# ---------------- describe ----------------
function TreeRows {
  $f = Wp 'tree.paths'
  if (-not [System.IO.File]::Exists($f)) { WbDie 'run apply-merge first' }
  $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($l in (WbReadText $f).Split([char]10)) { if ($l.Length -eq 0) { continue }; $a = $l.Split(';'); $rows.Add(@{ g = (WbToNumber $a[0]); path = $a[1]; range = $a[2] }) }
  return ,$rows
}
$script:TplDescribe = @'
TASK
Write a one-sentence description (max 20 words, plain text, no quotes or ";") for each BRANCH below, saying what that part of the specification covers. Use the child titles as evidence.
Output ONE LINE per branch, exactly:   <Branch/Path exactly as shown>;<description>
Write the lines to @@DESC@@ with the Write tool (every branch exactly once), then run:
  @@LAUNCH@@ @@SELF@@ check-desc @@G@@ --work @@WORKQ@@   and fix until it prints OK. Reply with just "done".

BRANCHES (@@N@@)
@@LIST@@
'@
function CmdDescribeInput {
  $g = PosNum 0; $br = WbNewMap
  foreach ($r in (TreeRows)) {
    if ([double]$r['g'] -ne $g) { continue }
    $s = $r['path'].Split('/')
    for ($d = 1; $d -lt $s.Length -and $d -le 3; $d++) {
      $p = [string]::Join('/', $s, 0, $d)
      if (-not $br.Contains($p)) { $br[$p] = @{ n = 0; ch = (WbNewMap) } }
      $o = $br[$p]; $o['n'] = $o['n'] + 1; $o['ch'][$s[$d]] = 1
    }
  }
  $bk = [string[]]@($br.Keys); $list = [object[]](WbSortByKey ([object[]]$bk) $bk)
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in $list) { $o = $br[$p]; $ck = @($o['ch'].Keys); $lines.Add("$p   [$($o['n']) pieces]  children: $([string]::Join(', ', [string[]]$ck[0..([Math]::Min(8, $ck.Count) - 1)]))") }
  WbOut (WbTpl $script:TplDescribe @{ DESC = (WbQ (Wp 'desc' ('g' + (WbNum $g) + '.txt'))); LAUNCH = $script:Launch; SELF = $script:SELF; G = (WbNum $g); WORKQ = (WbQ $script:WORK); N = $list.Length; LIST = [string]::Join("`n", $lines) })
}
function CmdCheckDesc {
  $g = PosNum 0; $f = Wp 'desc' ('g' + (WbNum $g) + '.txt')
  if (-not [System.IO.File]::Exists($f)) { WbDie "ERROR: $f not found" }
  $need = WbNewMap
  foreach ($r in (TreeRows)) {
    if ([double]$r['g'] -ne $g) { continue }
    $s = $r['path'].Split('/'); for ($d = 1; $d -lt $s.Length -and $d -le 3; $d++) { $need[[string]::Join('/', $s, 0, $d)] = 1 }
  }
  $got = WbNewMap
  foreach ($l in (WbReadText $f).Split([char]10)) {
    if ($l.Trim($script:WSC).Length -eq 0) { continue }
    $k = $l.IndexOf(';'); $got[(WbSub $l 0 $k).Trim($script:WSC)] = (WbSub $l ($k + 1) $null).Trim($script:WSC)
  }
  $errs = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in $need.Keys) { if (-not ($got.Contains($p) -and $got[$p].Length -gt 0)) { $errs.Add("missing description for `"$p`"") } }
  foreach ($p in $got.Keys) { if (-not $need.Contains($p)) { $errs.Add("unknown branch `"$p`"") } elseif ((WbW $got[$p]) -gt 30) { $errs.Add("description too long for `"$p`"") } }
  if ($errs.Count -gt 0) { PrintErrs $errs 30 $false; WbExit 1 }
  WbOut 'OK'
}

# ---------------- reshape wide branches ----------------
function LoadDesc {
  $all = Wp 'desc' '_all.txt'; $m = WbNewMap; $files = New-Object 'System.Collections.Generic.List[string]'
  if ([System.IO.File]::Exists($all)) { $files.Add($all) }
  elseif ([System.IO.Directory]::Exists((Wp 'desc'))) {
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in [System.IO.Directory]::GetFileSystemEntries((Wp 'desc'))) { $n = [System.IO.Path]::GetFileName($e); if ([regex]::IsMatch($n, '^g[0-9]+\.txt\z')) { $names.Add($n) } }
    $na = [string[]]$names.ToArray(); [Array]::Sort($na, [System.StringComparer]::Ordinal)
    foreach ($n in $na) { $files.Add((Wp 'desc' $n)) }
  }
  foreach ($f in $files) {
    foreach ($l in (WbReadText $f).Split([char]10)) {
      if ($l.Trim($script:WSC).Length -eq 0) { continue }
      $k = $l.IndexOf(';'); $key = (WbSub $l 0 $k).Trim($script:WSC)
      if (-not $m.Contains($key)) { $m[$key] = (WbSub $l ($k + 1) $null).Trim($script:WSC) }
    }
  }
  return ,$m
}
function SaveDesc($m) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($k in $m.Keys) { [void]$sb.Append($k).Append(';').Append($m[$k]).Append("`n") }
  if ($m.get_Count() -eq 0) { [void]$sb.Append("`n") }
  WbWriteText (Wp 'desc' '_all.txt') $sb.ToString()
}
# parent path -> (child -> {n, leaf}); ordered
function Widths($rows) {
  $kids = WbNewMap
  foreach ($r in $rows) {
    $s = $r['path'].Split('/')
    for ($d = 1; $d -lt $s.Length; $d++) {
      $par = [string]::Join('/', $s, 0, $d)
      if (-not $kids.Contains($par)) { $kids[$par] = WbNewMap }
      $m = $kids[$par]
      if (-not $m.Contains($s[$d])) { $m[$s[$d]] = @{ n = 0; leaf = $false } }
      $o = $m[$s[$d]]; $o['n'] = $o['n'] + 1; $o['leaf'] = ($d -eq $s.Length - 1)
    }
  }
  return ,$kids
}
function WideList($kids) {
  $res = New-Object 'System.Collections.Generic.List[object]'
  foreach ($p in $kids.Keys) { if ($kids[$p].get_Count() -gt 9) { $res.Add(@{ path = $p; n = $kids[$p].get_Count() }) } }
  return ,$res
}
function CmdReshapeList {
  $kids = Widths (TreeRows); $wl = WideList $kids
  $wa = [object[]]$wl.ToArray(); $keys = New-Object 'string[]' $wa.Length; for ($i = 0; $i -lt $wa.Length; $i++) { $keys[$i] = $wa[$i]['path'] }
  $wa = [object[]](WbSortByKey $wa $keys)
  $rd = Wp 'reshape'
  if ([System.IO.Directory]::Exists($rd) -and [System.IO.Directory]::GetFileSystemEntries($rd).Length -gt 0) { [System.IO.Directory]::Move($rd, (Wp ('reshape-archive-' + [long][Math]::Floor(([DateTime]::UtcNow - (New-Object DateTime 1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc))).TotalMilliseconds)))) }
  [void][System.IO.Directory]::CreateDirectory($rd)
  $wide = WbNewList; foreach ($x in $wa) { $wide.Add([ordered]@{ path = $x['path']; n = $x['n'] }) }
  WbWriteText (Wp 'wide.json') (WbToJson $wide $false)
  $nn = New-Object 'double[]' $wa.Length; for ($i = 0; $i -lt $wa.Length; $i++) { $nn[$i] = $wa[$i]['n'] }
  $srt = [object[]](WbSortByNum $wa $nn $true); $worst = WbNewList
  for ($i = 0; $i -lt [Math]::Min(5, $srt.Length); $i++) { $worst.Add([ordered]@{ path = $srt[$i]['path']; n = $srt[$i]['n'] }) }
  WbOut (WbToJson ([ordered]@{ count = $wa.Length; worst = $worst }) $false)
}
function Wide { return ,(ReadJ (Wp 'wide.json')) }
function CmdReshapeCount {
  $kids = Widths (TreeRows)
  WbOut (WbToJson ([ordered]@{ count = (WideList $kids).Count; readOnly = $true }) $false)
}
function WideAt($n) {
  $w = Wide; $d = [double]$n
  if ([double]::IsNaN($d) -or $d -lt 1 -or $d -gt $w.Count -or $d -ne [Math]::Floor($d)) { return $null }
  return ,$w[[int]$d - 1]
}
$script:TplReshape = @'
TASK
The branch "@@PATH@@" of a specification outline has @@NC@@ children, too many to survey. Group them into 3 to 7 themed groups.
Write ONE LINE per child, exactly:    <Child Title exactly as shown>;<Group Title>;<description>
- Every child exactly once. All children of one group get the identical Group Title and description.
- Group Title: 2-4 words, Title Case, no ";" or "/" or quotes, different from every child title.
- description: one sentence, max 20 words, saying what the group covers.
- Each group should end up with 2-9 children; keep children of a group close in the original order where the theme allows.
Write the lines to @@FILE@@ with the Write tool, then run:
  @@LAUNCH@@ @@SELF@@ check-reshape @@N@@ --work @@WORKQ@@   and fix the file until it prints OK. Reply with just "done".

CHILDREN of "@@PATH@@"
@@LIST@@
'@
function CmdReshapeInput {
  $n = PosNum 0; $w = WideAt $n
  if ($null -eq $w) { WbDie 'no such wide branch' }
  $rows = TreeRows; $PD = P
  $byStart = New-Object 'System.Collections.Generic.Dictionary[string,object]'
  foreach ($p in $PD['pieces']) { $byStart[(RelOf $p['f']) + ':' + $p['s']] = $p }
  $ld = $null; if ([System.IO.File]::Exists((Wp 'leafdesc.json'))) { $ld = ReadJ (Wp 'leafdesc.json') } else { $ld = WbNewMap }
  $ch = WbNewMap; $wp = [string]$w['path'] + '/'
  foreach ($r in $rows) {
    if (-not $r['path'].StartsWith($wp, [StringComparison]::Ordinal)) { continue }
    $s = $r['path'].Substring($wp.Length).Split('/'); $c = $s[0]
    if (-not $ch.Contains($c)) { $ch[$c] = @{ n = 0; sub = (New-Object 'System.Collections.Generic.List[string]'); leaf = ($s.Length -eq 1); sn = '' } }
    $o = $ch[$c]; $o['n'] = $o['n'] + 1
    if ($s.Length -gt 1) { $o['leaf'] = $false; if ($o['sub'].Count -lt 3 -and -not $o['sub'].Contains($s[1])) { $o['sub'].Add($s[1]) } }
    else {
      $rg = $r['range']; $key = $rg.Substring(0, $rg.LastIndexOf('-')); $pc = $null
      if ($byStart.ContainsKey($key)) { $pc = $byStart[$key] }
      $sn = ''
      if ($ld.Contains($rg) -and ([string]$ld[$rg]).Length -gt 0) { $sn = [string]$ld[$rg] }
      elseif ($null -ne $pc -and $pc['k'] -cne 'c') { $sw = ([string]$pc['sn']).Split(' '); $sn = [string]::Join(' ', $sw, 0, [Math]::Min(14, $sw.Length)) }
      $o['sn'] = $sn
    }
  }
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($c in $ch.Keys) { $o = $ch[$c]; if ($o['leaf']) { $lines.Add("$c   [piece] $($o['sn'])") } else { $lines.Add("$c   [branch, $($o['n']) pieces] $([string]::Join(', ', $o['sub']))") } }
  WbOut (WbTpl $script:TplReshape @{ PATH = $w['path']; NC = $ch.get_Count(); FILE = (WbQ (Wp 'reshape' ('r' + (WbNum $n) + '.txt'))); LAUNCH = $script:Launch; SELF = $script:SELF; N = (WbNum $n); WORKQ = (WbQ $script:WORK); LIST = [string]::Join("`n", $lines) })
}
function ReadReshape($n) {
  $f = Wp 'reshape' ('r' + (WbNum $n) + '.txt')
  if (-not [System.IO.File]::Exists($f)) { return $null }
  $res = New-Object 'System.Collections.Generic.List[object]'
  foreach ($l0 in (WbReadText $f).Split([char]10)) {
    $l = $l0.Trim($script:WSC); if ($l.Length -eq 0) { continue }
    $a = $l.Split(';')
    $grp = ''; if ($a.Length -gt 1) { $grp = $a[1].Trim($script:WSC) }
    $dsc = ''; if ($a.Length -gt 2) { $dsc = ([string]::Join(';', $a, 2, $a.Length - 2)).Trim($script:WSC) }
    $res.Add(@{ child = $a[0].Trim($script:WSC); group = $grp; desc = $dsc })
  }
  return ,$res
}
function CmdCheckReshape {
  $n = PosNum 0; $w = WideAt $n; $rows = $null
  if ($null -ne $w) { $rows = ReadReshape $n }
  if ($null -eq $rows) { WbDie "ERROR: reshape file r$(WbNum $n).txt not found" }
  $kids = (Widths (TreeRows))[[string]$w['path']]
  $errs = New-Object 'System.Collections.Generic.List[string]'; $seen = New-Object 'System.Collections.Generic.HashSet[string]'; $groups = WbNewMap
  foreach ($r in $rows) {
    if (-not $kids.Contains($r['child'])) { $errs.Add("unknown child `"$($r['child'])`""); continue }
    if (-not $seen.Add($r['child'])) { $errs.Add("child `"$($r['child'])`" appears twice") }
    if (-not (SegsOk $r['group']) -or $r['group'].Contains('/')) { $errs.Add("group title `"$($r['group'])`" must be 2-4 words without ; or /") }
    if ($kids.Contains($r['group'])) { $errs.Add("group title `"$($r['group'])`" equals an existing child title") }
    if ($groups.Contains($r['group'])) { $groups[$r['group']] = [int]$groups[$r['group']] + 1 } else { $groups[$r['group']] = 1 }
  }
  foreach ($c in $kids.Keys) { if (-not $seen.Contains($c)) { $errs.Add("child `"$c`" missing") } }
  if ($groups.get_Count() -lt 2) { $errs.Add('need at least 2 groups') }
  if ($groups.get_Count() -gt 9) { $errs.Add('at most 9 groups') }
  if ($errs.Count -gt 0) { PrintErrs $errs 30 $false; WbExit 1 }
  WbOut 'OK'
}
function CmdApplyReshape {
  $rows = TreeRows; $wide = Wide; $desc = LoadDesc; $applied = 0; $skipped = 0
  $items = New-Object 'System.Collections.Generic.List[object]'
  for ($i = 0; $i -lt $wide.Count; $i++) { $items.Add(@{ path = [string]$wide[$i]['path']; n = ($i + 1) }) }
  $ia = [object[]]$items.ToArray(); $dk = New-Object 'double[]' $ia.Length; for ($i = 0; $i -lt $ia.Length; $i++) { $dk[$i] = $ia[$i]['path'].Split('/').Length }
  $order = [object[]](WbSortByNum $ia $dk $true)
  foreach ($w in $order) {
    $rr = ReadReshape $w['n']
    if ($null -eq $rr) { $skipped++; continue }
    $map = WbNewMap; foreach ($r in $rr) { $map[$r['child']] = $r['group'] }
    $pre = $w['path'] + '/'
    foreach ($r in $rows) {
      if ($r['path'].StartsWith($pre, [StringComparison]::Ordinal)) {
        $s = $r['path'].Substring($pre.Length).Split('/')
        if ($map.Contains($s[0]) -and ([string]$map[$s[0]]).Length -gt 0) { $r['path'] = $w['path'] + '/' + $map[$s[0]] + '/' + [string]::Join('/', $s) }
      }
    }
    $nd = WbNewMap
    foreach ($k in @($desc.Keys)) {
      $v = $desc[$k]
      if ($k.StartsWith($pre, [StringComparison]::Ordinal)) {
        $s = $k.Substring($pre.Length).Split('/')
        if ($map.Contains($s[0]) -and ([string]$map[$s[0]]).Length -gt 0) { $nd[$w['path'] + '/' + $map[$s[0]] + '/' + [string]::Join('/', $s)] = $v } else { $nd[$k] = $v }
      } else { $nd[$k] = $v }
    }
    $desc.Clear(); foreach ($k in @($nd.Keys)) { $desc[$k] = $nd[$k] }
    foreach ($r in $rr) { if ($r['desc'].Length -gt 0 -and -not $desc.Contains($w['path'] + '/' + $r['group'])) { $desc[$w['path'] + '/' + $r['group']] = $r['desc'] } }
    $applied++
  }
  $sb = New-Object System.Text.StringBuilder
  foreach ($r in $rows) { [void]$sb.Append((WbNum $r['g'])).Append(';').Append($r['path']).Append(';').Append($r['range']).Append("`n") }
  if ($rows.Count -eq 0) { [void]$sb.Append("`n") }
  WbWriteText (Wp 'tree.paths') $sb.ToString(); SaveDesc $desc
  if ($applied -gt 0) { WbWriteText (Wp 'reshape.applied') '1' }
  $still = (WideList (Widths $rows)).Count
  WbOut ("OK  reshaped $applied branches$(if ($skipped -gt 0) { ", $skipped had no result" } else { '' }); $still branches still wider than 9")
}
function CmdGroupsArgs {
  $gs = WbNewList; foreach ($G in (GR)) { $gs.Add([ordered]@{ g = $G['g']; windows = $G['windows'].Count }) }
  WbOut (WbToJson ([ordered]@{ work = (WbFwd $script:WORK); cli = (WbFwd (WbResolve $script:SelfPath)); run = ($script:Launch + ' ' + $script:SELF); groups = $gs }) $false)
}

# ---------------- build ----------------
function CmdBuild {
  $rows = TreeRows; $desc = LoadDesc; $PD = P
  $ld = $null; if ([System.IO.File]::Exists((Wp 'leafdesc.json'))) { $ld = ReadJ (Wp 'leafdesc.json') } else { $ld = WbNewMap }
  $byRange = New-Object 'System.Collections.Generic.Dictionary[string,object]'
  foreach ($p in $PD['pieces']) { $byRange[(RelOf $p['f']) + ':' + $p['s'] + '-' + $p['e']] = $p }
  $rootPath = [string]$PD['root']
  $base = $rootPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar); $base = [System.IO.Path]::GetFileName($base)
  $title = [regex]::Replace($base, '[-_]+', ' ')
  $title = [regex]::Replace($title, '(?<![A-Za-z0-9_])[A-Za-z0-9_]', [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Value.ToUpperInvariant() })
  $root = WbNewMap; $root['title'] = $title; $root['children'] = (WbNewList)
  $branchIdx = New-Object 'System.Collections.Generic.Dictionary[object,object]'
  $gOf = WbNewMap
  foreach ($r in $rows) {
    $gOf[$r['path']] = $r['g']
    $s = $r['path'].Split('/'); $n = $root; $acc = New-Object 'System.Collections.Generic.List[string]'
    for ($d = 0; $d -lt $s.Length; $d++) {
      $seg = $s[$d]; $acc.Add($seg)
      if ($d -lt $s.Length - 1) {
        if (-not $branchIdx.ContainsKey($n)) { $branchIdx[$n] = New-Object 'System.Collections.Generic.Dictionary[string,object]' }
        $bi = $branchIdx[$n]
        if ($bi.ContainsKey($seg)) { $c = $bi[$seg] }
        else {
          $c = WbNewMap; $c['title'] = $seg; $c['children'] = (WbNewList)
          $k = [string]::Join('/', $acc); if ($desc.Contains($k) -and ([string]$desc[$k]).Length -gt 0) { $c['description'] = $desc[$k] }
          $n['children'].Add($c); $bi[$seg] = $c
        }
        $n = $c
      } else {
        $rg = $r['range']; $cp = $rg.LastIndexOf(':'); $file = $rg.Substring(0, $cp); $se = $rg.Substring($cp + 1).Split('-')
        $leaf = WbNewMap; $leaf['title'] = $seg; $leaf['file'] = $file; $leaf['start'] = (WbToNumber $se[0]); $leaf['end'] = (WbToNumber $se[1])
        $pc = $null; if ($byRange.ContainsKey($rg)) { $pc = $byRange[$rg] }
        if ($null -ne $pc -and $pc['k'] -ceq 'c') { $leaf['kind'] = 'code'; $leaf['lang'] = $pc['lang']; $dd = ''; if ($ld.Contains($rg) -and ([string]$ld[$rg]).Length -gt 0) { $dd = [string]$ld[$rg] }; $leaf['description'] = $dd }
        $n['children'].Add($leaf)
      }
    }
  }
  $cache = New-Object 'System.Collections.Generic.Dictionary[string,object]'
  $fileHash = New-Object 'System.Collections.Generic.Dictionary[string,object]'; foreach ($f in $PD['files']) { $fileHash[[string]$f['rel']] = $f['h'] }
  $fresh = New-Object 'System.Collections.Generic.Dictionary[string,bool]'
  $script:BStale = 0; $script:BStaleFiles = New-Object 'System.Collections.Generic.List[string]'; $script:BId = 0
  $stack = New-Object 'System.Collections.Generic.Stack[object]'; $stack.Push($root)
  while ($stack.Count -gt 0) {
    $n = $stack.Pop(); $n['id'] = 'n' + $script:BId; $script:BId++
    if ($n.Contains('children') -and $null -ne $n['children'] -and -not $n.Contains('file')) {
      $ch = $n['children']; for ($i = $ch.Count - 1; $i -ge 0; $i--) { $stack.Push($ch[$i]) }
    } else {
      $f = [string]$n['file']
      if (-not $cache.ContainsKey($f)) { $cache[$f] = (WbSplitLines (WbReadText ([System.IO.Path]::Combine($rootPath, $f)))) }
      $n['text'] = WbSliceJoin $cache[$f] ($n['start'] - 1) $n['end']
      if (-not $fresh.ContainsKey($f)) { $want = $fileHash[$f]; $fresh[$f] = ($null -eq $want -or ([string]$want).Length -eq 0 -or (WbSha1 ([System.IO.File]::ReadAllBytes([System.IO.Path]::Combine($rootPath, $f)))) -ceq $want) }
      if (-not $fresh[$f]) { $script:BStale++; if (-not $script:BStaleFiles.Contains($f)) { $script:BStaleFiles.Add($f) } }
    }
  }
  if ($script:BStale -gt 0 -and -not (HasFlag '--allow-stale')) {
    $sf = $script:BStaleFiles; $five = [string]::Join(', ', $sf.GetRange(0, [Math]::Min(5, $sf.Count)))
    WbDie "ERROR: $($script:BStale) piece(s) in $($sf.Count) file(s) changed since the split ($five$(if ($sf.Count -gt 5) { ', ...' } else { '' })). The titles and descriptions were written for the old text. Re-run split (and the agents) on the current files, or pass --allow-stale to build anyway."
  }
  $outOpt = Opt '--out' ([System.IO.Path]::Combine($script:WORK, 'whitebox.json'))
  $out = WbResolve $outOpt
  WbWriteText $out (WbToJson ([ordered]@{ version = 1; root = $rootPath; title = $title; tree = $root }) $false)
  $flat = New-Object 'System.Collections.Generic.List[string]'
  $wst = New-Object 'System.Collections.Generic.Stack[object]'; $wst.Push(@($root, ''))
  while ($wst.Count -gt 0) {
    $it = $wst.Pop(); $nd = $it[0]; $pp = $it[1]
    if (-not [object]::ReferenceEquals($nd, $root)) {
      $pp = $(if ($pp.Length -gt 0) { $pp + '/' + $nd['title'] } else { [string]$nd['title'] })
      $isBranch = $nd.Contains('children')
      $gv = ''; if (-not $isBranch -and $gOf.Contains($pp)) { $gv = WbNum $gOf[$pp] }
      $rgv = ''; if (-not $isBranch) { $rgv = [string]$nd['file'] + ':' + (WbNum $nd['start']) + '-' + (WbNum $nd['end']) }
      $dv = ''; if ($nd.Contains('description') -and $null -ne $nd['description']) { $dv = [string]$nd['description'] }
      $flat.Add("$gv;$pp;$rgv;$dv")
    }
    if ($nd.Contains('children')) { $ch = $nd['children']; for ($i = $ch.Count - 1; $i -ge 0; $i--) { $wst.Push(@($ch[$i], $pp)) } }
  }
  $po = [regex]::Replace($out, '\.json\z', '') + '.paths'
  WbWriteText $po ([string]::Join("`n", $flat) + "`n")
  WbOut "wrote $out (+ .paths): $($script:BId) nodes, $($desc.get_Count()) descriptions"
}

# ---------------- main ----------------
function Main {
  $known = @('split', 'window', 'check', 'check-all', 'status', 'merge-input', 'apply-merge', 'describe-input', 'check-desc', 'reshape-count', 'reshape-list', 'reshape-input', 'check-reshape', 'apply-reshape', 'groups-args', 'estimate', 'build')
  if (($known -ccontains $script:Cmd) -and ($null -eq $script:WORK)) { WbDie 'ERROR: --work DIR is required: put work files in a scratch directory outside the project (for example the scratchpad)' }
  switch -CaseSensitive ($script:Cmd) {
    'split' { CmdSplit }
    'window' { CmdWindow }
    'check' { CmdCheck }
    'merge-input' { CmdMergeInput }
    'apply-merge' { CmdApplyMerge }
    'describe-input' { CmdDescribeInput }
    'check-desc' { CmdCheckDesc }
    'build' { CmdBuild }
    'status' { CmdStatus }
    'check-all' { CmdCheckAll }
    'groups-args' { CmdGroupsArgs }
    'reshape-list' { CmdReshapeList }
    'reshape-count' { CmdReshapeCount }
    'estimate' { CmdEstimate }
    'reshape-input' { CmdReshapeInput }
    'check-reshape' { CmdCheckReshape }
    'apply-reshape' { CmdApplyReshape }
    default { $c = $script:Cmd; if ($null -eq $c) { $c = 'undefined' }; WbDie "unknown command $c" }
  }
}
try { $null = Main; WbExit 0 } catch { WbErr ([string]$_.Exception.Message); WbErr ([string]$_.ScriptStackTrace); WbExit 1 }
