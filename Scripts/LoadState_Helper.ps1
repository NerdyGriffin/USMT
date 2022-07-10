$LocalUserName = $args[0]
$DomainUserName = $args[1]

. (Join-Path "$PSScriptRoot" 'CloneUSMT.ps1')

$ProgFilePath = (Join-Path "$MigPath" ("prog_" + (Split-Path -Path "$LocalUserName" -Leaf) + ".log"))
$LogFilePath = (Join-Path "$MigPath" ("load_" + (Split-Path -Path "$LocalUserName" -Leaf) + ".log"))

Set-Location "$LocalExecutablePath"
.\loadstate.exe "$MigPath" /i:MigUser.xml /i:MigApp.xml /i:MigAppData.xml /v:13 /lac /lae /progress:"$ProgFilePath" /l:"$LogFilePath" /c /MU:"$LocalUserName":"$DomainUserName" /ue:*\* /ui:"$LocalUserName"
