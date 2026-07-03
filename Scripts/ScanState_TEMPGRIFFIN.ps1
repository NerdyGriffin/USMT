# $OldUserNameList = 'TEMPGRIFFIN\Administrator', 'TEMPGRIFFIN\admin', 'TEMPGRIFFIN\christian.kunis'

# foreach ($OldUserName in $OldUserNameList)
# {
#     Write-Host Backing up user: $OldUserName
#     . (Join-Path "$PSScriptRoot" 'ScanState_Win10.ps1') "$OldUserName"
# }

$OldUserName = "TEMPGRIFFIN\christian.kunis"

. (Join-Path "$PSScriptRoot" 'ScanState_Win10.ps1') "$OldUserName"