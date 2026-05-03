# ChatGPT Optimized for Windows

An experimental launcher for the official ChatGPT Windows desktop app that makes very long conversations usable again.

The ChatGPT Windows app can become slow in long chats because the app loads and renders a large conversation history. This launcher starts the official app with a local Chromium debugging port, installs a small local `fetch` wrapper, and trims the conversation object before the page renders it.

By default, long chats load with only the latest **40 messages** visible in the active app view. If you scroll upward to the top of the loaded window, the launcher progressively prepends older messages in read-only batches of 40.

## What This Does

- Launches the official ChatGPT Windows desktop app.
- Finds the current installed app package, so ChatGPT app updates should not break the launcher.
- Injects a local fetch trimmer into `chatgpt.com`.
- Keeps the latest N messages from a long conversation before render.
- Progressively shows older messages as read-only text when you scroll upward.
- Leaves your server-side ChatGPT conversation history untouched.
- Installs a Start Menu shortcut named `ChatGPT Optimized`.
- Uses a hidden helper so no terminal window stays open while the optimizer remains active.

## What This Does Not Do

- It does not modify the installed ChatGPT app.
- It does not delete, edit, or archive your conversations.
- It does not speed up model responses.
- It does not avoid downloading the conversation JSON; it reduces what the app renders.
- It is not affiliated with or endorsed by OpenAI.

## Requirements

- Windows 10 or Windows 11.
- Official ChatGPT Windows desktop app installed from OpenAI/Microsoft Store.
- PowerShell 5.1 or newer, included with Windows.

## Install

Clone or download this repo, then run PowerShell from the repo folder:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
```

Optional Desktop shortcut:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1 -Desktop
```

After install, launch from:

```text
Start Menu -> ChatGPT Optimized
```

## Manual Launch

You can also run the launcher directly:

```cmd
Launch ChatGPT Optimized.cmd
```

Use a different trim count:

```cmd
Launch ChatGPT Optimized.cmd -KeepMessages 80
```

Launch directly into a specific chat. For best reliability, use this with `-Restart`:

```cmd
Launch ChatGPT Optimized.cmd -Restart -ConversationUrl "https://chatgpt.com/c/..."
```

If ChatGPT is already running without the optimizer:

```cmd
Launch ChatGPT Optimized.cmd -Restart
```

## Uninstall

Remove shortcuts:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Then delete the repo folder if you no longer want it.

## Check Whether It Is Working

Open a long conversation, then check:

```powershell
Get-Content .\optimizer\launcher.log -Tail 40
```

For advanced debugging, in the ChatGPT page console:

```javascript
window.__chatgptFetchTrimmer.status()
```

Successful trimming looks like:

```javascript
{
  enabled: true,
  options: { keepMessages: 40 },
  trimCount: 1,
  last: {
    originalMessages: 514,
    keptMessages: 40,
    canExpand: true
  }
}
```

To manually load the next older page:

```javascript
window.__chatgptFetchTrimmer.expandOlderMessages()
```

To reset the current conversation back to the default window:

```javascript
window.__chatgptFetchTrimmer.resetProgress()
```

## Project Layout

```text
.
|-- Launch ChatGPT Optimized.cmd
|-- Launch ChatGPT Optimized Hidden.vbs
|-- install.ps1
|-- uninstall.ps1
|-- optimizer/
|   |-- Start-ChatGPTFetchTrimmed.cmd
|   |-- Start-ChatGPTFetchTrimmed.ps1
|   `-- chatgpt-fetch-trimmer.payload.js
`-- tools/
    `-- experimental diagnostics and older prototypes
```

## Risks And Limitations

- This uses Chromium DevTools Protocol on `127.0.0.1`.
- A hidden PowerShell helper remains running while ChatGPT is open so the injection survives chat navigation.
- Local processes could inspect the active ChatGPT page while the debug port/helper are active.
- ChatGPT web/app updates may break the trimmer.
- Older messages are hidden only in the loaded app view. Scrolling upward progressively prepends read-only reconstructions of older text, and reloading without this launcher restores the full native history.
- This is an experimental workaround, not a product-grade replacement for proper virtualized rendering in the app.

## License

MIT
