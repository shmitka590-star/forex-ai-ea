@echo off
set /p ANTHROPIC_API_KEY= YOUR_API_KEY_HERE
if exist %USERPROFILE%\Desktop\forex-ai-ea (
    cd %USERPROFILE%\Desktop\forex-ai-ea
    git pull
) else (
    git clone https://github.com/shmitka590-star/forex-ai-ea.git %USERPROFILE%\Desktop\forex-ai-ea
    cd %USERPROFILE%\Desktop\forex-ai-ea
)
py -m pip install -r requirements.txt
echo.
echo ForexAI starting on http://localhost:5000
py main.py
if %errorlevel% neq 0 (
    echo Flask failed to start. Press any key to see why.
    pause
)
