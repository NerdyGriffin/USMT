$OldDomain = $args[0]
$NewDomain = $args[1]

. (Join-Path "$PSScriptRoot" 'CloneUSMT.ps1')

$LogLabel = $OldDomain -replace '\\', '_'

$ProgFilePath = (Join-Path "$MigStorePath" ("prog_${LogLabel}.log"))
$LogFilePath = (Join-Path "$MigStorePath" ("load_${LogLabel}.log"))

Set-Location "$LocalExecutablePath"
.\loadstate.exe "$MigStorePath" /i:MigDocs.xml /i:MigApp.xml /i:MigAppData.xml /v:13 /lac /lae /progress:"$ProgFilePath" /l:"$LogFilePath" /c /md:"$OldDomain":"$NewDomain" #/ue:*\* /ui:"$OldDomain"\*
