\## Git 工作流规范

\- \*\*自动提交\*\*: 在完成每个逻辑任务、功能点或 Bug 修复后，必须自动执行 Git commit。

\- \*\*提交信息\*\*: Commit message 需严格遵循 Conventional Commits 规范（例如 `feat:`, `fix:`, `docs:`, `refactor:`）。

\- \*\*同步远端\*\*: 

&#x20; 1. 在提交前，先执行 `git pull --rebase` 以确保本地代码是最新的。

&#x20; 2. Commit 完成后，立即执行 `git push` 将改动同步到 GitHub。

