@echo off
rem Builds "CH Scene Switcher.exe" from chss.asm with the Visual Studio x64 tools.
setlocal enabledelayedexpansion
cd /d "%~dp0"
rem delayed expansion, because the ")" in "Program Files (x86)" would end the for's brackets
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`"!VSWHERE!" -latest -products * -property installationPath`) do set "VS=%%i"
if not exist "%VS%\VC\Auxiliary\Build\vcvars64.bat" (echo Visual Studio C++ build tools not found & exit /b 1)
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>nul

ml64 /nologo /c /Fo chss.obj chss.asm || exit /b 1
rc /nologo /fo chss.res chss.rc || exit /b 1
rem Standard layout on purpose: separate read-only code and writable data
rem sections, ASLR, and an embedded manifest. Merging sections or dropping
rem these makes the exe a few KB smaller but trips antivirus heuristics.
link /nologo chss.obj chss.res kernel32.lib winhttp.lib bcrypt.lib crypt32.lib ^
  /OUT:"CH Scene Switcher.exe" /SUBSYSTEM:CONSOLE /ENTRY:main /NODEFAULTLIB ^
  /DYNAMICBASE /NXCOMPAT /DEBUG:NONE /OPT:REF ^
  /MANIFEST:EMBED /MANIFESTUAC:"level='asInvoker' uiAccess='false'" || exit /b 1
del chss.obj chss.res
