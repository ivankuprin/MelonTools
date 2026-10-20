; Melon Tools — Windows installer (NSIS 3 / MUI2).
;
; Build from the Windows directory:
;   makensis -DVERSION=2.0.0 -DSOURCE_EXE=dist/MelonTools-2.0.0-win-x64.exe installer/MelonTools.nsi
;
; SOURCE_EXE is relative to the Windows directory (no spaces needed in the
; define). VERSION is passed by build-windows.sh from app/src-tauri/Cargo.toml.
; The installer is per-user: RequestExecutionLevel user, HKCU registry only.

Unicode true

!include "MUI2.nsh"

!ifndef VERSION
  !error "VERSION is required: pass /DVERSION=<x.y.z>"
!endif

!ifndef SOURCE_EXE
  !define SOURCE_EXE "dist/MelonTools-${VERSION}-win-x64.exe"
!endif
!define SOURCE_EXE_FULL "../${SOURCE_EXE}"

!define PRODUCT_NAME "Melon Tools"
!define PRODUCT_PUBLISHER "Melon Tools"
!define PRODUCT_URL "https://github.com/ivankuprin/MelonTools"
!define APP_REG_KEY "Software\Melon Tools"
!define UNINSTALL_REG_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\MelonTools"

Name "${PRODUCT_NAME} ${VERSION}"
Caption "${PRODUCT_NAME} ${VERSION} Setup"
BrandingText "${PRODUCT_NAME}"
OutFile "../dist/MelonTools-${VERSION}-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\MelonTools"
InstallDirRegKey HKCU "${APP_REG_KEY}" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 64

; Explorer properties / Add or remove programs metadata.
VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=1033 "ProductName" "${PRODUCT_NAME}"
VIAddVersionKey /LANG=1033 "CompanyName" "${PRODUCT_PUBLISHER}"
VIAddVersionKey /LANG=1033 "FileDescription" "${PRODUCT_NAME} Setup"
VIAddVersionKey /LANG=1033 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1033 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1033 "LegalCopyright" "Copyright (c) 2026 Melon Tools"

; Wizard appearance. The generated icon is optional; remove MUI_ICON/MUI_UNICON
; if Windows/installer/MelonTools.ico is absent.
!define MUI_ABORTWARNING
!define MUI_ICON "MelonTools.ico"
!define MUI_UNICON "MelonTools.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "../../LICENSE"
!define MUI_DIRECTORYPAGE_VERIFYONLEAVE
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES

; Finish page: launch the app, and let the user opt into a desktop shortcut.
!define MUI_FINISHPAGE_RUN "$INSTDIR\MelonTools.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Launch Melon Tools"
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\MelonTools.exe"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Create a desktop shortcut"
!define MUI_FINISHPAGE_SHOWREADME_NOTCHECKED
!define MUI_FINISHPAGE_SHOWREADME_FUNCTION "CreateDesktopShortcut"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_LANGUAGE "English"

Function .onInit
  SetShellVarContext current
FunctionEnd

Function un.onInit
  SetShellVarContext current
FunctionEnd

; Directory page verification: accept any path the current user can write to.
Function .onVerifyInstDir
  ClearErrors
  CreateDirectory "$INSTDIR"
  IfErrors verify_create_failed

  ClearErrors
  FileOpen $0 "$INSTDIR\.melon-write-test" w
  IfErrors verify_write_failed
  FileClose $0
  Delete "$INSTDIR\.melon-write-test"
  Return

verify_create_failed:
  MessageBox MB_ICONSTOP|MB_OK \
    "Melon Tools cannot create this folder:$\r$\n$INSTDIR$\r$\n$\r$\nChoose a folder where you have write access."
  Abort

verify_write_failed:
  MessageBox MB_ICONSTOP|MB_OK \
    "Melon Tools cannot write to this folder:$\r$\n$INSTDIR$\r$\n$\r$\nChoose a writable folder."
  Abort
FunctionEnd

Function CreateDesktopShortcut
  SetShellVarContext current
  CreateShortcut "$DESKTOP\Melon Tools.lnk" "$INSTDIR\MelonTools.exe" "" "$INSTDIR\MelonTools.exe" 0
FunctionEnd

Section "Melon Tools" SEC_APP
  SectionIn RO
  SetOutPath "$INSTDIR"
  File "/oname=MelonTools.exe" "${SOURCE_EXE_FULL}"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; Start Menu group (current user).
  CreateDirectory "$SMPROGRAMS\Melon Tools"
  CreateShortcut "$SMPROGRAMS\Melon Tools\Melon Tools.lnk" "$INSTDIR\MelonTools.exe" "" "$INSTDIR\MelonTools.exe" 0
  CreateShortcut "$SMPROGRAMS\Melon Tools\Uninstall Melon Tools.lnk" "$INSTDIR\Uninstall.exe"

  ; Remember the chosen path for upgrades and the directory page.
  WriteRegStr HKCU "${APP_REG_KEY}" "InstallDir" "$INSTDIR"

  ; Add or remove programs entry (current user, no elevation).
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "DisplayName" "${PRODUCT_NAME}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "DisplayIcon" "$INSTDIR\MelonTools.exe,0"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "URLInfoAbout" "${PRODUCT_URL}"
  WriteRegStr HKCU "${UNINSTALL_REG_KEY}" "HelpLink" "${PRODUCT_URL}"
  WriteRegDWORD HKCU "${UNINSTALL_REG_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_REG_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current

  Delete "$INSTDIR\MelonTools.exe"
  Delete "$INSTDIR\Uninstall.exe"

  Delete "$SMPROGRAMS\Melon Tools\Melon Tools.lnk"
  Delete "$SMPROGRAMS\Melon Tools\Uninstall Melon Tools.lnk"
  RMDir "$SMPROGRAMS\Melon Tools"

  Delete "$DESKTOP\Melon Tools.lnk"

  DeleteRegKey HKCU "${UNINSTALL_REG_KEY}"
  DeleteRegKey HKCU "${APP_REG_KEY}"

  ; User data lives in %APPDATA%\MelonTools and is intentionally kept:
  ; accounts.json, settings.json, scheduler.json and gateway data survive.
  RMDir "$INSTDIR"
SectionEnd
