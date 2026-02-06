@echo off
set script=main
set binName=TinkerEdit.exe

if exist "%script%.exe" del /q "%script%.exe"
if exist "%binName%" del /q "%binName%"
rem if not exist "%~dp0SDL2.dll" copy "..\..\SDL2.dll" "%~dp0SDL2.dll"

rem We Don't use -r here because it stops the
rem batch execution, even if we use "start"
rem nim c --app:gui --threads:on --opt:size --forceBuild:on "%script%.nim"
nim c --app:console --threads:on --opt:size "%script%.nim"

rem nim 2.0 release candidate (does not work atm)
rem J:\nim\nim-1.9.1\bin\nim.exe c --app:console --threads:on --opt:size "%script%.nim"

if not exist "%script%.exe" goto error
ren "%script%.exe" "%binName%"

echo Executing app...
echo.
call %binName%
goto theend

:error
echo error!

pause

:theend
