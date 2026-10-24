Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"
!include "WinVer.nsh"
!include "x64.nsh"
!include "nsDialogs.nsh"

!ifndef PAYLOAD
  !error "PAYLOAD must be the published app directory"
!endif
!ifndef OUTPUT
  !error "OUTPUT must be the setup executable path"
!endif
!ifndef DELETE_MANIFEST
  !error "DELETE_MANIFEST is required for safe uninstall"
!endif
!ifndef BOOTSTRAPPER
  !error "BOOTSTRAPPER must be the Microsoft WebView2 bootstrapper path"
!endif
!ifndef RUNTIME
  !define RUNTIME "win-x64"
!endif
!ifndef VERSION
  !define VERSION "2.1.9"
!endif
!ifndef SIZE_KB
  !define SIZE_KB 0
!endif

!define APP_KEY "Software\CampusConnect.Windows"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\CampusConnect.Windows"
!define WEBVIEW_KEY "Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

Name "校园Wi-Fi小助手"
OutFile "${OUTPUT}"
; Trailing slash disables NSIS adding the default folder name after Browse.
InstallDir "$LOCALAPPDATA\Programs\CampusConnect\"
; Let NSIS apply the previous directory only when /D did not select a new one.
InstallDirRegKey HKCU "${APP_KEY}" "InstallDir"
RequestExecutionLevel user
; Non-solid zlib prioritizes extraction speed over the smallest download.
SetCompressor /FINAL zlib
ShowInstDetails show
ShowUninstDetails show
BrandingText "By Ye · 禁止商用，商用须经作者授权"
VIProductVersion "2.1.9.0"
!define MUI_ICON "../source/AppIcon.ico"
!define MUI_UNICON "../source/AppIcon.ico"
VIAddVersionKey /LANG=2052 "ProductName" "校园Wi-Fi小助手安装程序"
VIAddVersionKey /LANG=2052 "FileDescription" "校园Wi-Fi小助手 Windows 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "CampusConnect contributors"

Var OldDir
Var ChosenDir
Var RemoveData
Var RemoveDataCheckbox
Var SkipWebView
Var StartupCommand

!define MUI_ABORTWARNING
!define MUI_WELCOMEPAGE_TITLE "欢迎安装校园Wi-Fi小助手"
!define MUI_WELCOMEPAGE_TEXT "本向导将安装 CampusConnect ${VERSION}。$\r$\n$\r$\n您可以选择安装目录、创建桌面快捷方式，并在安装完成后立即运行。$\r$\n$\r$\n程序安装到当前用户，已包含 .NET 与验证码模型。缺少组件时，将从微软下载 WebView2 或 Visual C++ 运行库（需要联网，可能提示管理员授权）。"
!insertmacro MUI_PAGE_WELCOME
!define MUI_DIRECTORYPAGE_VARIABLE $ChosenDir
!define MUI_DIRECTORYPAGE_TEXT_TOP "程序将安装到下方完整路径，不会额外添加子文件夹。请选一个有写入权限的独立文件夹。"
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE ValidateDirectory
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\CampusConnect.exe"
!define MUI_FINISHPAGE_RUN_TEXT "立即运行校园Wi-Fi小助手"
!define MUI_FINISHPAGE_TEXT "校园Wi-Fi小助手已安装。$\r$\n$\r$\n安装目录：$INSTDIR$\r$\n$\r$\n首次使用请在设置中填写自己的校园账号密码。自动连接默认关闭。关闭主窗口后，程序保留在系统托盘。"
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
UninstPage custom un.DataPage un.DataPageLeave
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_UNPAGE_FINISH
!insertmacro MUI_LANGUAGE "SimpChinese"

!macro CheckRunningFunction PREFIX
Function ${PREFIX}CheckRunning
  retry:
  System::Call 'kernel32::OpenMutexW(i 0x00100000, i 0, w "Local\CampusConnect.Windows") p.r0'
  ${If} $0 != 0
    System::Call 'kernel32::CloseHandle(p r0)'
    IfSilent silent_abort
    MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "校园Wi-Fi小助手正在运行。请右键系统托盘图标选择退出，然后点击重试。" IDRETRY retry
    Quit
    silent_abort:
    SetErrorLevel 2
    Quit
  ${EndIf}
FunctionEnd
!macroend
!insertmacro CheckRunningFunction ""
!insertmacro CheckRunningFunction "un."

Function .onInit
  SetShellVarContext current
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_OK|MB_ICONSTOP "此版本需要 Windows 10 或 Windows 11。"
    Quit
  ${EndIf}
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "此版本需要 64 位 Windows。"
    Quit
  ${EndIf}
  !if "${RUNTIME}" == "win-arm64"
    ${IfNot} ${IsNativeARM64}
      MessageBox MB_OK|MB_ICONSTOP "请在 ARM64 Windows 电脑使用此安装包；普通电脑请选择 x64 安装包。"
      Quit
    ${EndIf}
  !endif
  SetRegView 64
  ReadRegStr $StartupCommand HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "CampusConnect.Windows"
  ReadRegStr $OldDir HKCU "${APP_KEY}" "InstallDir"
  ; /D is already applied by NSIS. The directory page edits its own variable.
  StrCpy $ChosenDir $INSTDIR
  StrCpy $RemoveData 0
  ${GetParameters} $0
  ClearErrors
  ${GetOptions} $0 "/SKIPWEBVIEW2" $1
  ${IfNot} ${Errors}
    StrCpy $SkipWebView 1
  ${EndIf}
  Call CheckRunning
FunctionEnd

Function ValidateDirectory
  ClearErrors
  ; Normalize without requiring parent directories to exist yet.
  ; NSIS GetFullPathName can empty a valid path when its parents are new.
  StrCpy $0 $ChosenDir
  System::Call 'kernel32::GetFullPathNameW(w r0, i ${NSIS_MAX_STRLEN}, w .r1, p 0) i .r2'
  StrCpy $INSTDIR $1
  ${If} $2 <= 0
  ${OrIf} $2 >= ${NSIS_MAX_STRLEN}
  ${OrIf} $INSTDIR == ""
    MessageBox MB_OK|MB_ICONEXCLAMATION "无法识别这个安装路径，请重新选择目录。" /SD IDOK
    SetErrorLevel 3
    Abort
  ${EndIf}
  ${GetRoot} "$INSTDIR" $0
  GetFullPathName $0 "$0\"
  ${If} $INSTDIR == $0
  ${OrIf} $INSTDIR == $WINDIR
  ${OrIf} $INSTDIR == $SYSDIR
  ${OrIf} $INSTDIR == $PROFILE
  ${OrIf} $INSTDIR == $LOCALAPPDATA
  ${OrIf} $INSTDIR == $APPDATA
  ${OrIf} $INSTDIR == $DESKTOP
  ${OrIf} $INSTDIR == $DOCUMENTS
  ${OrIf} $INSTDIR == $SMPROGRAMS
  ${OrIf} $INSTDIR == $PROGRAMFILES
  ${OrIf} $INSTDIR == $PROGRAMFILES64
  ${OrIf} $INSTDIR == "$LOCALAPPDATA\CampusConnect"
    MessageBox MB_OK|MB_ICONEXCLAMATION "请为程序选择独立文件夹，例如 D:\Apps\CampusConnect。"
    Abort
  ${EndIf}
  ClearErrors
  CreateDirectory "$INSTDIR"
  GetTempFileName $0 "$INSTDIR"
  ${If} ${Errors}
    MessageBox MB_OK|MB_ICONEXCLAMATION "无法写入这个目录。请选当前用户有写入权限的文件夹，例如 D:\Apps\CampusConnect。"
    Abort
  ${EndIf}
  Delete "$0"
  StrCpy $ChosenDir $INSTDIR
FunctionEnd

Function DetectWebView
  SetRegView 32
  ReadRegStr $0 HKLM "${WEBVIEW_KEY}" "pv"
  ReadRegStr $1 HKCU "${WEBVIEW_KEY}" "pv"
  SetRegView 64
  StrCpy $2 0
  ${If} $0 != ""
  ${AndIf} $0 != "0.0.0.0"
    StrCpy $2 1
  ${EndIf}
  ${If} $1 != ""
  ${AndIf} $1 != "0.0.0.0"
    StrCpy $2 1
  ${EndIf}
FunctionEnd

Section "程序文件与开始菜单快捷方式（必需）" SEC_APP
  SectionIn RO
  SetDetailsView show
  SetDetailsPrint both
  DetailPrint "[1/5] 检查安装目录与正在运行的程序"
  Call ValidateDirectory
  Call CheckRunning
  ${If} $OldDir != ""
    IfFileExists "$OldDir\Uninstall.exe" 0 old_missing
    DetailPrint "移除旧版本的程序文件（保留账号配置）…"
    ClearErrors
    ExecWait '"$OldDir\Uninstall.exe" /S _?=$OldDir' $0
    IfErrors old_launch_failed
    ${If} $0 != 0
      MessageBox MB_OK|MB_ICONSTOP "旧版本卸载失败。请先从 Windows 设置卸载旧版本，再安装到新目录。"
      SetErrorLevel 3
      Abort
    ${EndIf}
    Delete "$OldDir\Uninstall.exe"
    RMDir "$OldDir"
    Goto old_complete
    old_missing:
    ; A missing uninstaller must not prevent restoring it in the original directory.
    ${If} $OldDir == $INSTDIR
      DetailPrint "旧卸载程序缺失，正在修复原目录的程序和卸载入口…"
      Goto old_complete
    ${EndIf}
    MessageBox MB_OK|MB_ICONSTOP "旧卸载程序缺失。请先重新运行本安装包，选择原安装目录 $OldDir 修复，再更换目录。"
    SetErrorLevel 3
    Abort
    old_launch_failed:
    MessageBox MB_OK|MB_ICONSTOP "无法启动旧卸载程序。请确认安装目录可访问，且卸载程序未被安全软件隔离，然后重新运行安装包。"
    SetErrorLevel 3
    Abort
    old_complete:
  ${EndIf}
  ; The user selection is the single source for files, shortcuts and uninstall registration.
  StrCpy $INSTDIR $ChosenDir
  DetailPrint "[2/5] 释放程序文件 · ${RUNTIME}"
  DetailPrint "目标目录：$INSTDIR"
  DetailPrint "CampusConnect.exe 包含主程序、.NET 运行环境与 WebView2 接口。"
  SetOutPath "$INSTDIR"
  ClearErrors
  !include "${INSTALL_MANIFEST}"
  IfErrors install_files_failed
  ClearErrors
  DetailPrint "[3/5] 生成卸载文件：$INSTDIR\Uninstall.exe"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  IfErrors install_uninstaller_failed
  IfFileExists "$INSTDIR\Uninstall.exe" 0 install_uninstaller_failed
  ; Register the Windows Settings entry only after its target exists.
  ClearErrors
  DetailPrint "[4/5] 注册应用与卸载入口（当前用户）"
  WriteRegStr HKCU "${APP_KEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "校园Wi-Fi小助手"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "CampusConnect 项目"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\CampusConnect.exe,0"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" ${SIZE_KB}
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  IfErrors install_registration_failed
  ${If} $StartupCommand != ""
    DetailPrint "更新已有开机启动项：$INSTDIR\CampusConnect.exe --startup"
    ClearErrors
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "CampusConnect.Windows" '$\"$INSTDIR\CampusConnect.exe$\" --startup'
    IfErrors install_registration_failed
  ${EndIf}
  DetailPrint "[5/5] 创建开始菜单快捷方式"
  ; Remove only known old shortcuts when upgrading to the new display name.
  Delete "$DESKTOP\校园 Wi-Fi 助手.lnk"
  Delete "$SMPROGRAMS\校园 Wi-Fi 助手\校园 Wi-Fi 助手.lnk"
  Delete "$SMPROGRAMS\校园 Wi-Fi 助手\卸载校园 Wi-Fi 助手.lnk"
  RMDir "$SMPROGRAMS\校园 Wi-Fi 助手"
  DetailPrint "$SMPROGRAMS\校园Wi-Fi小助手\校园Wi-Fi小助手.lnk"
  ; Apply the selected desktop option on upgrades too.
  Delete "$DESKTOP\校园Wi-Fi小助手.lnk"
  CreateDirectory "$SMPROGRAMS\校园Wi-Fi小助手"
  CreateShortcut "$SMPROGRAMS\校园Wi-Fi小助手\校园Wi-Fi小助手.lnk" "$INSTDIR\CampusConnect.exe" "" "$INSTDIR\CampusConnect.exe" 0
  CreateShortcut "$SMPROGRAMS\校园Wi-Fi小助手\卸载校园Wi-Fi小助手.lnk" "$INSTDIR\Uninstall.exe"
  Goto install_complete
  install_files_failed:
    MessageBox MB_OK|MB_ICONSTOP "程序文件写入失败。请检查安装目录权限和安全软件提示，再重新运行安装包。"
    SetErrorLevel 3
    Abort
  install_uninstaller_failed:
    MessageBox MB_OK|MB_ICONSTOP "无法生成卸载程序。请检查安装目录权限和安全软件提示，再重新运行安装包修复。"
    SetErrorLevel 3
    Abort
  install_registration_failed:
    MessageBox MB_OK|MB_ICONSTOP "无法写入 Windows 卸载入口。请重新运行安装包修复。"
    SetErrorLevel 3
    Abort
  install_complete:
SectionEnd

Section "创建桌面快捷方式" SEC_DESKTOP
  DetailPrint "创建桌面快捷方式：$DESKTOP\校园Wi-Fi小助手.lnk"
  CreateShortcut "$DESKTOP\校园Wi-Fi小助手.lnk" "$INSTDIR\CampusConnect.exe" "" "$INSTDIR\CampusConnect.exe" 0
SectionEnd

Section "缺少时安装 Microsoft WebView2（需要联网）" SEC_WEBVIEW
  SectionIn RO
  ${If} $SkipWebView == 1
    Goto webview_done
  ${EndIf}
  DetailPrint "检查 Microsoft WebView2：已安装则跳过下载与安装。"
  Call DetectWebView
  ${If} $2 == 1
    DetailPrint "已安装 WebView2，跳过组件安装。"
    Goto webview_done
  ${EndIf}
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File /oname=MicrosoftEdgeWebview2Setup.exe "${BOOTSTRAPPER}"
  DetailPrint "正在安装 Microsoft WebView2，请保持联网…"
  ExecWait '$\"$PLUGINSDIR\MicrosoftEdgeWebview2Setup.exe$\" /silent /install' $0
  Call DetectWebView
  ${If} $2 != 1
    DetailPrint "WebView2 尚未安装，返回码：$0。"
    IfSilent webview_done
    MessageBox MB_OK|MB_ICONEXCLAMATION "主程序已安装，但 WebView2 安装未完成。程序界面需要此组件，请联网后重新运行安装程序，或按使用说明手动安装。"
  ${EndIf}
  webview_done:
  SetOutPath "$INSTDIR"
SectionEnd

Section "缺少时安装模型运行库（可能需联网与管理员授权）" SEC_MODEL_RUNTIME
  SectionIn RO
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File /oname=install-model-runtime.ps1 "install-model-runtime.ps1"
  StrCpy $1 "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  IfFileExists "$WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe" 0 +2
    StrCpy $1 "$WINDIR\SysNative\WindowsPowerShell\v1.0\powershell.exe"
  !if "${RUNTIME}" == "win-arm64"
    StrCpy $2 "arm64"
  !else
    StrCpy $2 "x64"
  !endif
  DetailPrint "检查验证码模型所需 Microsoft Visual C++ 运行库，已安装则跳过。"
  ClearErrors
  ExecWait '$\"$1$\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $\"$PLUGINSDIR\install-model-runtime.ps1$\" -RuntimeArch $2' $0
  ${If} ${Errors}
    StrCpy $0 1
  ${EndIf}
  ${If} $0 != 0
    DetailPrint "模型运行库尚未安装完成，仍可手动输入验证码。"
    IfSilent model_runtime_done
    MessageBox MB_OK|MB_ICONINFORMATION "主程序已安装。模型运行库尚未安装完成，仍可手动输入验证码；可联网后重新运行安装程序补全组件。"
  ${EndIf}
  model_runtime_done:
  SetOutPath "$INSTDIR"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_APP} "安装完整程序和运行环境，创建开始菜单入口，并在 Windows 设置中添加卸载项。"
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_DESKTOP} "在当前用户桌面添加快捷方式。默认勾选，可取消。"
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_WEBVIEW} "只在缺少组件时运行 Microsoft 官方安装程序。下载运行时需要互联网连接。"
  !insertmacro MUI_DESCRIPTION_TEXT ${SEC_MODEL_RUNTIME} "本地验证码模型使用 Microsoft Visual C++ 运行库。缺少时从微软下载并校验签名后安装，可能提示管理员授权。模型识别本身不联网。"
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Function un.onInit
  SetShellVarContext current
  SetRegView 64
  StrCpy $RemoveData 0
  Call un.CheckRunning
FunctionEnd
Function un.DataPage
  !insertmacro MUI_HEADER_TEXT "账号配置" "选择是否一并删除当前用户的数据"
  nsDialogs::Create 1018
  Pop $0
  ${If} $0 == error
    Abort
  ${EndIf}
  ${NSD_CreateLabel} 0 0 100% 40u "默认保留校园网设置和加密密码，重新安装后可继续使用。$\r$\n如不再使用本软件，可勾选下面的选项。"
  Pop $0
  ${NSD_CreateCheckbox} 0 55u 100% 25u "同时删除校园账号配置和浏览器缓存"
  Pop $RemoveDataCheckbox
  nsDialogs::Show
FunctionEnd
Function un.DataPageLeave
  ${NSD_GetState} $RemoveDataCheckbox $RemoveData
FunctionEnd
Section "Uninstall"
  Call un.CheckRunning
  ; Delete exact payload files, then remove empty directories. Never recursively remove a custom install directory.
  !include "${DELETE_MANIFEST}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$DESKTOP\校园Wi-Fi小助手.lnk"
  Delete "$SMPROGRAMS\校园Wi-Fi小助手\校园Wi-Fi小助手.lnk"
  Delete "$SMPROGRAMS\校园Wi-Fi小助手\卸载校园Wi-Fi小助手.lnk"
  RMDir "$SMPROGRAMS\校园Wi-Fi小助手"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "CampusConnect.Windows"
  DeleteRegKey HKCU "${APP_KEY}"
  ${If} $RemoveData == ${BST_CHECKED}
    Delete "$LOCALAPPDATA\CampusConnect\configuration.json"
    RMDir /r "$LOCALAPPDATA\CampusConnect\WebView2"
    RMDir "$LOCALAPPDATA\CampusConnect"
  ${EndIf}
  SetErrorLevel 0
SectionEnd
