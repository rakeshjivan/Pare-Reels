# Pare Reels

A simple Mac app for downloading videos and webinars. Paste one or more links, pick a quality, and click **Download**.

## Get it

**Easiest:** download `Pare-Reels-mac.zip` from this repo's **Releases** page. Unzip it and drag **Pare Reels** into Applications.
The app isn't signed by Apple, so the first time you open it macOS blocks it. Go to **System Settings › Privacy & Security** and click **Open Anyway**.

**Or build it yourself** (no Gatekeeper warning): in Terminal, run `bash build.sh` in this folder. If Apple's Command Line Tools aren't installed, the script prompts you to install them.

## Crop a video
Open the **Crop** tab, then drop in a video or click **Open Video…**. Drag the handles or the box, or pick a shape (16:9, 1:1, 9:16, 4:5, 4:3). Use the slider to check the crop works for the whole video.
- **Save — Instant** leaves the picture data untouched, so there's no quality loss and an hour-long video saves in seconds. It works with H.264 and HEVC videos (almost all MP4/MOV files). A few older editing apps may ignore the crop.
- **Save — Fast** re-encodes with your Mac's video hardware. It works everywhere and makes a smaller file, and takes a few minutes for an hour of 1080p.

The cropped copy is saved next to the original as "… (cropped)".

## Updates
Pare Reels checks for a newer version each time it opens. It downloads the update in the background and installs it when you quit. Click **Restart Now** in the banner to update straight away. Copies you build yourself with `build.sh` don't auto-update.

## Publish a new version
Every change pushed to `main` builds the app and publishes it as the latest release automatically.

## First launch
Pare Reels downloads its helper tools into `~/Library/Application Support/Pare Reels/bin`:
- **yt-dlp**, the download engine. It updates itself each time the app opens.
- **Deno**, which YouTube now requires.
- **ffmpeg**, which joins video and audio for HD and converts to MP3.

## Use
- Put one link per line. Playlist links download the whole playlist. A video link with `&list=` in it downloads only that video.
- Quality: Best, 4K, 1440p, 1080p, 720p, 480p, or Audio only (MP3). At 1080p and below the app prefers H.264, so files play in QuickTime. YouTube only offers 1440p and 4K as VP9 or AV1, which may need IINA or VLC to play.
- Works with YouTube, Vimeo, ON24, Zoom recordings (`zoom.us/rec/…`), Instagram, TikTok, Facebook and many other sites. Pages the downloader can't read, such as GoToWebinar, use the video finder described below.
- For Instagram, and for Facebook private groups, set **Use login from** to the browser you're logged in with.

## Recorded webinars on other sites (GoTo and similar)
Paste the link as normal. If the downloader can't read the page, Pare Reels opens it in a small window, starts the video muted and finds the actual video file. The window then closes by itself and the app saves **one MP4 with sound**. If the page keeps the sound in a separate file, the app downloads both and joins them.
- If the page asks you to log in, register or click Play, do that in the window. Your login is remembered for next time.
- This works for recorded webinars only. Live streams have no file to save.

## Webinars behind a login
- **Use login from** is set to **Automatic**. Each download is tried without a login first. If the site asks for one, the app tries again using your usual browser's login (your default browser, otherwise Chrome, otherwise Safari). You can still pick a specific browser, or **Don't use**.
  - Chrome, Edge and Brave ask for your Mac password once. Click **Always Allow**.
  - Safari needs Full Disk Access. The app shows a button that opens the right Settings page.
- If a video still needs access, its row shows **Unlock…**. Click it to enter a video password (Vimeo), or a site username and password, then try again. Passwords are never saved.

## If something fails
Open the **Log** at the bottom of the window. The last `ERROR:` line says what went wrong. For YouTube problems, quit and reopen the app to update yt-dlp.
