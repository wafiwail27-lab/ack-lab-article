# 从 Obsidian 同步文章到本仓库：复制正文与配图，并把 Obsidian 的 wikilink 转成标准 Markdown
$src  = 'C:\Users\23914\Documents\Obsidian Vault\阿里云'
$name = '阿里云 ACK 托管集群实战 架构规划与 CI-CD 全流程交付.md'
$dst  = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force -Path (Join-Path $dst 'images') | Out-Null
$md = Get-Content -LiteralPath (Join-Path $src $name) -Raw -Encoding UTF8
$md = [regex]::Replace($md, '!\[\[([^\]]+\.png)\]\]', '![$1](images/$1)')
foreach ($m in [regex]::Matches($md, '\(images/([^)]+\.png)\)')) {
  $png = Join-Path $src $m.Groups[1].Value
  if (Test-Path $png) { Copy-Item -LiteralPath $png -Destination (Join-Path $dst 'images') -Force }
}
$sec = Join-Path $dst 'docs\repo-section.md'
if (Test-Path $sec) {
  $s = Get-Content -LiteralPath $sec -Raw -Encoding UTF8
  $anchor = '## 1. 项目背景与目标'
  $i = $md.IndexOf($anchor)
  if ($i -ge 0) { $md = $md.Substring(0, $i) + $s.TrimEnd() + "`r`n`r`n---`r`n`r`n" + $md.Substring($i) }
}
[IO.File]::WriteAllText((Join-Path $dst 'README.md'), $md, (New-Object Text.UTF8Encoding($false)))
Write-Host "已同步 README.md 与 images/，接下来 git add . / commit / push 即可。"