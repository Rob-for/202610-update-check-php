@echo off
setlocal
REM push-naar-github.bat - zet alle wijzigingen in deze map op GitHub.
REM Dubbelklikken is genoeg. De eerste keer vraagt Git je om in te loggen bij GitHub.

cd /d "%~dp0"
set "REPO=https://github.com/Rob-for/202610-update-check-php.git"

where git >nul 2>&1
if errorlevel 1 (
  echo Git is niet geinstalleerd. Download het via https://git-scm.com/download/win
  pause
  exit /b 1
)

if exist ".git" goto gekoppeld
echo Eerste keer: map koppelen aan GitHub...
git init -b main || goto fout
git remote add origin "%REPO%" || goto fout
git fetch origin || goto fout
git reset origin/main || goto fout
:gekoppeld

REM Naam en e-mail voor commits (alleen als die nog niet ingesteld zijn)
git config user.name  >nul 2>&1 || git config user.name "Rob-for"
git config user.email >nul 2>&1 || git config user.email "Rob-for@users.noreply.github.com"

echo.
echo Wijzigingen:
git status --short
git add -A
git diff --cached --quiet && goto geenwijziging

set "MSG="
set /p "MSG=Wat heb je veranderd? (Enter = Update): "
if not defined MSG set "MSG=Update"
git commit -m "%MSG%" || goto fout
goto versturen

:geenwijziging
echo Geen nieuwe wijzigingen.

:versturen
git pull --rebase origin main || goto fout
git push -u origin main || goto fout

echo.
echo Klaar, alles staat op GitHub.
echo Let op: de raw-link kan tot 5 minuten de oude versie geven.
pause
exit /b 0

:fout
echo.
echo Er ging iets mis, zie de melding hierboven.
pause
exit /b 1
