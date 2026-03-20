@echo off
set /p ANTHROPIC_API_KEY= YOUR_API_KEY_HERE
if exist forex-ai-ea (
    cd forex-ai-ea
    git pull
) else (
    git clone https://github.com/shmitka590-star/forex-ai-ea.git
    cd forex-ai-ea
)
C:\Users\Family\AppData\Local\Programs\Python\Python314\python.exe -m pip install -r requirements.txt
echo.
echo ForexAI starting on http://localhost:5000
C:\Users\Family\AppData\Local\Programs\Python\Python314\python.exe main.py
if %errorlevel% neq 0 (
    echo Flask failed to start. Press any key to see why.
    pause
)
