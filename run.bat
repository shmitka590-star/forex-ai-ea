@echo off
if "%ANTHROPIC_API_KEY%"=="" (
set /p ANTHROPIC_API_KEY="Enter your Anthropic API key: "
)
echo Installing dependencies...
pip install -r requirements.txt
echo.
echo Starting ForexAI v2 on http://localhost:5000
python main.py
pause
