# Neutral prompt for the website screenshots (used through ZDOTDIR; never the user's own rc files).
PROMPT='%F{blue}%1~%f %F{green}❯%f '
RPROMPT=''
unset HISTFILE
# Plain tool output (no AI-agent detection, e.g. laravel/pao's JSON test summary).
unset CLAUDECODE CLAUDE_CODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SSE_PORT AI_AGENT CODEX_SANDBOX CODEX_CI CODEX_THREAD_ID CURSOR_AGENT GEMINI_CLI
export PAO_DISABLE=1
