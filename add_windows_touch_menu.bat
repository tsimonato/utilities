@echo off
:: ============================================================================
:: Script Name   : add_windows_touch_context.bat
:: Author        : Thiago Cavalcante Simonato
:: Date Created  : 2025-05-25
:: Last Updated  : 2025-05-25
:: Description   : Adds a "Apply Windows Touch" option to the right-click
::                 context menu for files in Windows Explorer. This simulates
::                 the UNIX 'touch' command by updating the last modified
::                 timestamp of the selected file without altering its contents.
::
:: Compatibility : Windows 10/11 (all editions with CMD support)
:: Requirements  : No external dependencies (native Windows command)
::
:: Technical Notes:
:: - The command `copy /b "file"+,, "file"` triggers a file re-save in place,
::   which updates the last modified time.
:: - This method does not create the file if it does not already exist.
:: - Works for individual files only (not folders or multiple selections).
:: ============================================================================

REM Add context menu entry
reg add "HKCU\Software\Classes\*\shell\WinTouch" /ve /d "Apply Windows Touch" /f

REM Define the command to execute when the menu option is selected
reg add "HKCU\Software\Classes\*\shell\WinTouch\command" /ve /d "cmd.exe /c copy /b \"%%1\"+,, \"%%1\"" /f

echo.
echo [INFO] Context menu option 'Apply Windows Touch' added successfully.
pause
