# Embed a whitebox.json tree into the self-contained editor page.  PowerShell port of build-editor.mjs.
#   build-editor.ps1 [whitebox.json] [out.html]
. (Join-Path $PSScriptRoot 'lib/wb-common.ps1')
function Main {
  $a = [string[]]@($script:AllArgs)
  $src = 'whitebox.json'; $out = 'whitebox.html'
  if ($a.Length -gt 0) { $src = $a[0] }
  if ($a.Length -gt 1) { $out = $a[1] }
  $json = (WbToJson (WbJsonParse (WbReadText $src)) $false).Replace('<', '<')
  $apply = [System.IO.Path]::Combine($PSScriptRoot, 'apply-edits.ps1')
  $rel = WbRelative ([Environment]::CurrentDirectory) $apply
  if ($rel.IndexOfAny([char[]]' ') -ge 0) { $rel = '"' + $rel + '"' }
  $launch = $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell -NoProfile -ExecutionPolicy Bypass -File' } else { 'pwsh -NoProfile -File' })
  $html = WbReadText ([System.IO.Path]::Combine($PSScriptRoot, 'editor.template.html'))
  $i = $html.IndexOf('__APPLY_CMD__', [StringComparison]::Ordinal)
  if ($i -ge 0) { $html = $html.Substring(0, $i) + "$launch $rel" + $html.Substring($i + 13) }
  $i = $html.IndexOf('__TREE__', [StringComparison]::Ordinal)
  if ($i -ge 0) { $html = $html.Substring(0, $i) + $json + $html.Substring($i + 8) }
  WbWriteText ([System.IO.Path]::Combine([Environment]::CurrentDirectory, $out)) $html
  WbOut "wrote $out"
}
$script:AllArgs = $args
try { $null = Main; WbExit 0 } catch { WbErr ([string]$_.Exception.Message); WbErr ([string]$_.ScriptStackTrace); WbExit 1 }
