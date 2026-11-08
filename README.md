# Pare Reels

A simple Mac app for downloading videos and webinars. Paste one or more links, pick a quality, and click **Download**.

## Get it

**Easiest:** download `Pare-Reels-mac.zip` from this repo's **Releases** page. Unzip it and drag **Pare Reels** into Applications.
The app isn't signed by Apple, so the first time you open it macOS blocks it. Go to **System Settings › Privacy & Security** and click **Open Anyway**.

**Or build it yourself** (no Gatekeeper warning): in Terminal, run `bash build.sh` in this folder. If Apple's Command Line Tools aren't installed, the script prompts you to install them.

## Publish a new version
Click **Actions › Build Pare Reels › Run workflow** to get a test build, or push a tag like `v1.1` to publish a release.

## First launch
Pare Reels downloads its helper tools into `~/Library/Application Support/Pare Reels/bin`:
- **yt-dlp**, the download engine. It updates itself each time the app opens.
- **Deno**, which YouTube now requires.
- **ffmpeg**, which joins video and audio for HD and converts to MP3.

## Use
- Put one link per line. Playlist links download the whole playlist. A video link with `&list=` in it downloads only that video.
- Quality: Best, 4K, 1440p, 1080p, 720p, 480p, or Audio only (MP3). At 1080p and below the app prefers H.264, so files play in QuickTime. YouTube only offers 1440p and 4K as VP9 or AV1, which may need IINA or VLC to play.
- Works with YouTube, Vimeo, ON24 and many other sites. GoToWebinar has no dedicated support, so whether a link works varies.

## Webinars behind a login
- **Use login from:** log in to the site once in Safari, Chrome, Firefox, Edge or Brave, then pick that browser here.
  - Chrome, Edge and Brave ask for your Mac password once. Click **Always Allow**.
  - Safari needs Full Disk Access. The app shows a button that opens the right Settings page.
- If a video still needs access, its row shows **Unlock…**. Click it to enter a video password (Vimeo), or a site username and password, then try again. Passwords are never saved.

## If something fails
Open the **Log** at the bottom of the window. The last `ERROR:` line says what went wrong. For YouTube problems, quit and reopen the app to update yt-dlp.
