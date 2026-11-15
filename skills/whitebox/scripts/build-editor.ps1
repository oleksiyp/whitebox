# Embed a whitebox.json tree into the self-contained editor page.  PowerShell port of build-editor.mjs.
#   build-editor.ps1 <whitebox.json> <out.html> [--title NAME] [--artifact]
. (Join-Path $PSScriptRoot 'lib/wb-common.ps1')
function Main {
  $a = [string[]]@($script:AllArgs)
  $pos = New-Object 'System.Collections.Generic.List[string]'; $title = $null; $artifact = $false
  for ($k = 0; $k -lt $a.Length; $k++) {
    if ($a[$k] -ceq '--artifact') { $artifact = $true }
    elseif ($a[$k] -ceq '--title') { $k++; if ($k -lt $a.Length) { $title = $a[$k] } else { $title = '' } }
    elseif ($a[$k].StartsWith('--', [StringComparison]::Ordinal)) { }
    else { $pos.Add($a[$k]) }
  }
  if ($pos.Count -lt 2) { WbErr 'usage: build-editor <whitebox.json> <out.html> [--title "Name"] [--artifact]'; WbExit 2; return }
  $src = $pos[0]; $out = $pos[1]
  $json = (WbToJson (WbJsonParse (WbReadText $src)) $false).Replace('<', '\u003c')
  $apply = [System.IO.Path]::Combine($PSScriptRoot, 'apply-edits.ps1')
  $rel = WbRelative ([Environment]::CurrentDirectory) $apply
  if ($rel.IndexOfAny([char[]]' ') -ge 0) { $rel = '"' + $rel + '"' }
  $launch = $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell -NoProfile -ExecutionPolicy Bypass -File' } else { 'pwsh -NoProfile -File' })
  $html = WbReadText ([System.IO.Path]::Combine($PSScriptRoot, 'editor.template.html'))
  if ($null -ne $title -and $title.Length -gt 0) {
    $esc = $title.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
    $j = $html.IndexOf('<title>Whitebox</title>', [StringComparison]::Ordinal)
    if ($j -ge 0) { $html = $html.Substring(0, $j) + '<title>' + $esc + '</title>' + $html.Substring($j + 23) }
  }
  if ($artifact) {
    $wrap = @('<!doctype html>', '<html lang="en">', '<head>', '<meta charset="utf-8">', '<meta name="viewport" content="width=device-width, initial-scale=1">', '</head>', '<body>', '</body>', '</html>')
    $kept = New-Object 'System.Collections.Generic.List[string]'
    foreach ($ln in $html.Split([char]10)) { $skip = $false; foreach ($w in $wrap) { if ([string]::Equals($ln, $w, [StringComparison]::Ordinal)) { $skip = $true; break } }; if (-not $skip) { $kept.Add($ln) } }
    $html = [string]::Join("`n", $kept.ToArray())
  }
  $i = $html.IndexOf('__APPLY_CMD__', [StringComparison]::Ordinal)
  if ($i -ge 0) { $html = $html.Substring(0, $i) + "$launch $rel" + $html.Substring($i + 13) }
  $i = $html.IndexOf('__TREE__', [StringComparison]::Ordinal)
  if ($i -ge 0) { $html = $html.Substring(0, $i) + $json + $html.Substring($i + 8) }
  WbWriteText ([System.IO.Path]::Combine([Environment]::CurrentDirectory, $out)) $html
  WbOut "wrote $out"
}
$script:AllArgs = $args
try { $null = Main; WbExit 0 } catch { WbErr ([string]$_.Exception.Message); WbErr ([string]$_.ScriptStackTrace); WbExit 1 }
