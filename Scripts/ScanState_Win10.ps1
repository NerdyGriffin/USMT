$LocalUserName = $args[0]

. (Join-Path "$PSScriptRoot" 'CloneUSMT.ps1')

$ProgFilePath = (Join-Path "$MigPath" ("prog_" + (Split-Path -Path "$LocalUserName" -Leaf) + ".log"))
$LogFilePath = (Join-Path "$MigPath" ("scan_" + (Split-Path -Path "$LocalUserName" -Leaf) + ".log"))

Set-Location "$LocalExecutablePath"
.\scanstate.exe "$MigPath" /i:MigUser.xml /i:MigApp.xml /i:MigAppData.xml /v:13 /progress:"$ProgFilePath" /l:"$LogFilePath" /o /localonly /c /uel:100 #/ue:*\* /ui:"$LocalUserName"
