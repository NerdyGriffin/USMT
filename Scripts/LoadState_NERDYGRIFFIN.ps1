$OldUserNameList = 'TEMPGRIFFIN\admin', 'TEMPGRIFFIN\christian.kunis'
$NewUserNameList = 'NERDYGRIFFIN\admin', 'NERDYGRIFFIN\christian.kunis'

foreach ($OldUserName in $OldUserNameList)
{
    $UserNameIndex = $OldUserNameList.IndexOf($OldUserName)
    $NewUserName = $NewUserNameList[$UserNameIndex]
    Write-Host -Object "$OldUserName -> $NewUserName"
    . (Join-Path "$PSScriptRoot" 'LoadState_Helper.ps1') "$OldUserName" "$NewUserName"
}

# Alternative (manual use): remap the whole store by domain in a single pass
# instead of looping per user pair above.
# . (Join-Path "$PSScriptRoot" 'LoadState_Move_Domain.ps1') "TEMPGRIFFIN" "NERDYGRIFFIN"
