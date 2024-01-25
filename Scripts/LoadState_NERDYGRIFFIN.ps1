$OldUserNameList = 'TEMPGRIFFIN\admin', 'TEMPGRIFFIN\christian.kunis'
$NewUserNameList = 'NERDYGRIFFIN\admin', 'NERDYGRIFFIN\christian.kunis'

foreach ($OldUserName in $OldUserNameList)
{
    $UserNameIndex = $OldUserNameList.IndexOf($OldUserName)
    $NewUserName = $NewUserNameList[$UserNameIndex]
    Write-Host $OldUserName -> $NewUserName
    . (Join-Path "$PSScriptRoot" 'LoadState_Helper.ps1') "$OldUserName" "$NewUserName"
}

# . (Join-Path "$PSScriptRoot" 'LoadState_Move_Domain.ps1') "TEMPGRIFFIN" "NERDYGRIFFIN"
