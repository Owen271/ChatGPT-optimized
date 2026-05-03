# Changelog

## 0.1.0

- Added optimized Windows launcher for the ChatGPT desktop app.
- Added fetch-level conversation trimming before ChatGPT renders long threads.
- Added progressive read-only older-message rendering when scrolling to the top of the trimmed window.
- Improved older-message formatting for headings, emphasis, code fences, links, quotes, tables, and internal ChatGPT entity markers.
- Kept a hidden helper alive while ChatGPT is open so trimming survives navigation between chats.
- Added Start Menu/Desktop shortcut installer and uninstaller.
- Added hidden launcher to avoid leaving a terminal window open.
- Added launcher logs for debugging.
