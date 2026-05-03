# Security

ChatGPT Optimized is a local runtime patch for the official ChatGPT Windows desktop app. It launches the app with a local Chromium DevTools port and injects a local `fetch` wrapper into the ChatGPT page.

## Important properties

- It does not modify the installed ChatGPT app files.
- It does not delete or edit server-side conversation history.
- It does not send conversation content to this project, the author, or any third party.
- The local DevTools port can expose the active ChatGPT page to local processes while the optimized app session is running.

## Reporting issues

Please open a GitHub issue for bugs. Do not include private conversation text, tokens, cookies, account identifiers, or other sensitive data in reports.
