$OldUserName = $args[0]

. (Join-Path "$PSScriptRoot" 'CloneUSMT.ps1')

$LogLabel = $OldUserName -replace '\\', '_'

$ListFilePath = (Join-Path "$MigStorePath" ("list_${LogLabel}.log"))
$ProgFilePath = (Join-Path "$MigStorePath" ("prog_${LogLabel}.log"))
$LogFilePath = (Join-Path "$MigStorePath" ("scan_${LogLabel}.log"))

Set-Location "$LocalExecutablePath"
.\scanstate.exe "$MigStorePath" /o /vsc /i:MigDocs.xml /i:MigApp.xml /i:MigAppData.xml /v:13 /localonly /listfiles:"$ListFilePath" /l:"$LogFilePath" /progress:"$ProgFilePath" /c /uel:100 /targetWindows7
