$ErrorActionPreference = 'Stop'
$env:PYTHONIOENCODING = 'utf-8'
$project = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')
Set-Location -LiteralPath $project.Path
$python = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
& $python 'Source\OTHER\zuma_vdac2.py' --test catch-wrong-target --build-frames 2600 --max-frames 80 *> 'Source\OTHER\_catch_bg.out'
