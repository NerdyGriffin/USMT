$OldUserName = "$env:COMPUTERNAME\WCOffice"
$NewUserName = "WHC\wcoffice"

. (Join-Path "$PSScriptRoot" 'ScanState_Win7.ps1') "$OldUserName"

. (Join-Path "$PSScriptRoot" 'LoadState_Helper.ps1') "$OldUserName" "$NewUserName"
