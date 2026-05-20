@echo off
setlocal

set "PROJECT_DIR=c:\Users\Ryan\Documents\Projects\PERSONAL_PROJECTS\AnymeXExtensionRuntimeBridge\RuntimeBridges\Desktop"
set "DEST_DIR=%USERPROFILE%\Documents\AnymeX\Tools"
set "DEST_FILE=anymex_desktop_runtime.jar"

echo [BUILD] Building Desktop Bridge...
cd /d "%PROJECT_DIR%"
call gradlew shadowJar

if %ERRORLEVEL% equ 0 (
    echo [BUILD] Build successful!
    echo [COPY] Copying to %DEST_DIR%\%DEST_FILE%...
    if not exist "%DEST_DIR%" mkdir "%DEST_DIR%"
    copy /y "build\libs\desktop_bridge.jar" "%DEST_DIR%\%DEST_FILE%"
    if %ERRORLEVEL% equ 0 (
        echo [DONE] Build and copy completed successfully!
    ) else (
        echo [ERROR] Copy failed!
    )
) else (
    echo [ERROR] Build failed!
)

pause
