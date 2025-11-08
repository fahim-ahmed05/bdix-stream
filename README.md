# BDIXStream

![Preview](.github/preview.png)

BDIXStream is a simple tool for PowerShell that helps you find and play media from online directories. It lets you search for videos, stream them with your favorite player, download files, and keep track of what you've watched. It's like a personal media browser for web folders.

## What You Need

- PowerShell 7 (pwsh) – it's free and needs to be installed.
- A few extra tools: fzf (for searching), aria2c (for downloading), jq (for handling data), and mpv (for streaming).

## How to Install

1. Open Command Prompt or PowerShell (search for "cmd" or "powershell" in Start menu).
2. Install PowerShell 7 and the other tools using this command:

   ```
   winget install --id Microsoft.PowerShell -e; winget install --id Microsoft.WindowsTerminal -e; winget install --id jqlang.jq -e; winget install --id aria2.aria2 -e; winget install --id junegunn.fzf -e; winget install --id MPV-Player.MPV -e
   ```

3. Download or copy the BDIXStream folder to your computer.

That's it! If something doesn't install, try restarting your computer.

## Getting Started

1. Open Windows Terminal (search for "wt" in Start menu).
2. Go to the BDIXStream folder (type `cd C:\path\to\bdix-stream` and press Enter).
3. Run the script by typing:

   ```
   pwsh -ExecutionPolicy Bypass -File .\main.ps1
   ```

The first time, it will create a settings file. You can change things like where downloads go or which player to use. Here's the default config:

```json
{
  "MediaPlayer": "mpv",
  "DownloadPath": "$PSScriptRoot\\downloads",
  "MaxCrawlDepth": 9,
  "HistoryMaxSize": 50,
  "DirBlockList": ["lost found", "software", "games", "e book"],
  "Tools": {
    "fzf": "",
    "aria2c": "",
    "jq": "",
    "edit": ""
  }
}
```

### Create a Shortcut

To make it easier, create a desktop shortcut:

1. Right-click on your desktop and choose **New > Shortcut**.
2. In the location box, type:

   ```
   wt.exe pwsh.exe -ExecutionPolicy Bypass -File "C:\path\to\bdix-stream\main.ps1"
   ```

   (Replace `C:\path\to\bdix-stream` with your actual folder path.)

3. Click Next, name it "BDIXStream", and Finish.

Double-click the shortcut to start the script anytime.

## Using the Script

The script has a simple menu. Use the number keys or letters to choose:

- **Stream Media**: Search and play videos online.
- **Resume Last**: Play the last thing you watched.
- **History**: See what you've watched before.
- **Manage Index**: Build a list of available media (do this first).
- **Download**: Save files to your computer.
- **Manage Sources**: Add or remove websites to search.
- **Backups**: Save or restore your data.

Type to search, press Enter to select, and 'b' to go back or 'q' to quit.

## Help

- If it says a tool is missing, make sure you installed everything from the install step.
- No videos showing? Go to "Manage Index" and build the index first.
- Slow? It might take time to scan websites.

## Support

If you run into any problems or have suggestions, please report them on the GitHub page.

If you like this tool, consider buying me a coffee.

<a href="https://www.buymeacoffee.com/fahim.ahmed" target="_blank">
  <img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" 
       alt="Buy Me A Coffee" 
       style="height: 41px !important;width: 174px !important;box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5); -webkit-box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5);" />
</a>

