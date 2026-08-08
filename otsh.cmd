@echo off
setlocal EnableDelayedExpansion
rem otsh — Windows entry point.
rem
rem The sibling `otsh` is a POSIX /bin/sh script, which on Windows means Git
rem Bash. That is fine when you have it and useless when you do not, so this
rem file is the native one: `.\otsh doctor` works from cmd.exe and from
rem PowerShell, with no shell of any kind installed.
rem
rem It does what the sh bootstrap does — find the Odin compiler, build
rem cmd\otsh once into bin\, then exec that binary and get out of the way. The
rem binary is named for its platform because a checkout can be shared between
rem machines, and the name matches the release artifact, so an otsh-windows-
rem amd64.exe downloaded from a release drops into bin\ and is used as-is
rem without ever compiling.

set "OTSH=%~dp0"
if "%OTSH:~-1%"=="\" set "OTSH=%OTSH:~0,-1%"
set "TOOL=%OTSH%\bin\otsh-windows-amd64.exe"

rem An OTSH_ROOT override, for a binary kept somewhere else entirely.
if defined OTSH_ROOT if exist "%OTSH_ROOT%\bin\otsh-windows-amd64.exe" (
	set "TOOL=%OTSH_ROOT%\bin\otsh-windows-amd64.exe"
)

if exist "%TOOL%" goto :run

rem --- resolve the compiler, same order as the sh bootstrap -----------------
rem   %ODIN%, then .odin-path in the checkout, then the user config written by
rem   `otsh use-odin`, then PATH. Each is taken only if it actually runs.
set "ODIN_BIN="
if defined ODIN if exist "%ODIN%" set "ODIN_BIN=%ODIN%"

if not defined ODIN_BIN if exist "%OTSH%\.odin-path" (
	set /p CANDIDATE=<"%OTSH%\.odin-path"
	if exist "!CANDIDATE!" set "ODIN_BIN=!CANDIDATE!"
)

if not defined ODIN_BIN (
	set "CONF=%LOCALAPPDATA%\otsh\odin-path"
	if defined XDG_CONFIG_HOME set "CONF=%XDG_CONFIG_HOME%\otsh\odin-path"
	if exist "!CONF!" (
		set /p CANDIDATE=<"!CONF!"
		if exist "!CANDIDATE!" set "ODIN_BIN=!CANDIDATE!"
	)
)

if not defined ODIN_BIN (
	for %%I in (odin.exe) do set "ODIN_BIN=%%~$PATH:I"
)

if not defined ODIN_BIN (
	rem No compiler. Answer what can be answered without one, and give the
	rem same diagnosis as every other platform for the rest.
	if /i "%~1"=="doctor"  goto :nocompiler_doctor
	if /i "%~1"=="version" goto :nocompiler_doctor
	if /i "%~1"=="help"    goto :nocompiler_doctor
	if /i "%~1"=="--help"  goto :nocompiler_doctor
	if "%~1"==""           goto :nocompiler_doctor
	echo otsh: odin compiler not found ^(tried 'odin'^). 1>&2
	echo   Install it from https://odin-lang.org, or if you have it somewhere 1>&2
	echo   custom, record that once for every project: 1>&2
	echo       otsh use-odin C:\path\to\odin.exe 1>&2
	exit /b 1
)

rem --- build the tool once --------------------------------------------------
echo otsh: building the otsh tool ^(cmd\otsh -^> bin\otsh-windows-amd64.exe^)... 1>&2
if not exist "%OTSH%\bin" mkdir "%OTSH%\bin"
"%ODIN_BIN%" build "%OTSH%\cmd\otsh" -out:"%TOOL%" -o:speed
if errorlevel 1 (
	echo otsh: could not build the otsh tool. 1>&2
	exit /b 1
)

:run
"%TOOL%" %*
exit /b %errorlevel%

:nocompiler_doctor
rem Mirrors the sh bootstrap's compiler-less doctor: say what is missing
rem rather than failing with a build error the reader cannot act on.
echo otsh doctor — %OTSH%
echo.
echo   FAIL  odin      not found ^(tried 'odin'^)
echo                   install from https://odin-lang.org, or if it lives somewhere
echo                   custom: otsh use-odin C:\path\to\odin.exe
echo.
echo Install the Odin compiler, then run this again for the full check
echo ^(libssh via vcpkg, and the otsh packages themselves^).
exit /b 1
