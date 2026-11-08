#!/usr/bin/env python3
"""Writes Localizable.xcstrings (English source + Persian) into both app targets.

The string keys are exactly what the Swift code uses (SwiftUI turns "\\(n) songs" into "%lld songs").
Edit translations here, then run: python3 tools/gen_strings.py
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# key: persian
PLAIN = {
    # sidebar and sections
    "Home": "خانه", "Library": "کتابخانه", "Songs": "آهنگ‌ها","Playlists": "پلی‌لیست‌ها",
    "Rename…": "تغییر نام…", "Delete": "حذف", "New Playlist": "پلی‌لیست جدید", "New Playlist…": "پلی‌لیست جدید…","Repair Center": "مرکز تعمیر", "Automatic": "خودکار", "Watched Folders": "پوشه‌های تحت نظر",
    "Sync": "همگام‌سازی", "Devices": "دستگاه‌ها", "Create": "ساخت", "Cancel": "انصراف", "Rename Playlist": "تغییر نام پلی‌لیست",
    "Rename": "تغییر نام", "Name": "نام", "Playlist": "پلی‌لیست",
    # built-in collections
    "Favorites": "علاقه‌مندی‌ها",
    # songs table, editor, inspector
    "Title": "عنوان", "Artist": "خواننده", "Album": "آلبوم", "Album Artist": "خوانندهٔ آلبوم", "Genre": "سبک", "Time": "مدت",
    "Format": "قالب", "Search Songs": "جست‌وجوی آهنگ‌ها", "Search": "جست‌وجو", "Info": "اطلاعات",
    "Show or hide song info": "نمایش یا پنهان‌کردن اطلاعات آهنگ", "Remove from Musicam?": "از Musicam حذف شود؟",
    "Your audio files are not deleted; they just disappear from this library.": "فایل‌های صوتی شما پاک نمی‌شوند؛ فقط از این کتابخانه برداشته می‌شوند.",
    "No Selection": "چیزی انتخاب نشده", "Select a song to see and edit its details.": "یک آهنگ را انتخاب کنید تا جزئیاتش را ببینید و ویرایش کنید.",
    "Rating": "امتیاز", "File": "فایل", "Size": "اندازه", "Stored": "ذخیره‌شده", "On this device": "روی این دستگاه",
    "Only on your other device": "فقط روی دستگاه دیگر شما", "Added": "تاریخ افزودن",
    # context menu and playback
    "Play": "پخش", "Play Next": "پخش بعدی", "Add to Queue": "افزودن به صف", "Add to Playlist": "افزودن به پلی‌لیست",
    "Remove from Playlist": "حذف از پلی‌لیست", "Remove from Favorites": "حذف از علاقه‌مندی‌ها", "Add to Favorites": "افزودن به علاقه‌مندی‌ها",
    "Remove from Library…": "حذف از کتابخانه…", "Shuffle": "تصادفی", "Previous": "قبلی", "Pause": "توقف", "Next": "بعدی", "Repeat": "تکرار",
    "Volume": "صدا", "Playback position": "موقعیت پخش", "Now playing": "در حال پخش", "Now Playing": "در حال پخش",
    "Nothing Playing": "چیزی پخش نمی‌شود", "Not Playing": "پخش نمی‌شود", "Double-click a song to play it.": "برای پخش، روی یک آهنگ دو بار کلیک کنید.",
    "Opens Now Playing": "صفحهٔ در حال پخش را باز می‌کند", "Opens the player": "پخش‌کننده را باز می‌کند", "Plays this song": "این آهنگ را پخش می‌کند",
    "Up Next": "بعدی", "Nothing queued after this song.": "بعد از این آهنگ چیزی در صف نیست.",
    "Getting the song from your other device…": "در حال گرفتن آهنگ از دستگاه دیگر…", "Not on this device yet": "هنوز روی این دستگاه نیست",
    # home, import
    "Recently added": "تازه‌ها", "Add Music": "افزودن موسیقی", "Add Music…": "افزودن موسیقی…", "Add songs or folders (⌘O)": "افزودن آهنگ یا پوشه (⌘O)",
    "Add your music": "موسیقی خود را اضافه کنید",
    "Choose files or a folder, or drop them anywhere in this window. Songs stay where they are; Musicam remembers where.": "فایل‌ها یا یک پوشه را انتخاب کنید، یا همین‌جا در پنجره رها کنید. آهنگ‌ها سر جای خود می‌مانند و Musicam جایشان را به خاطر می‌سپارد.",
    "Dismiss": "بستن", "No audio files found.": "فایل صوتی پیدا نشد.", "Nothing to add.": "چیزی برای افزودن نبود.",
    "No songs yet": "هنوز آهنگی نیست", "Add songs from Files, or open the Devices tab to pair with your Mac and bring your library here.": "آهنگ‌ها را از Files اضافه کنید، یا در تب Devices با مک خود جفت شوید تا کتابخانه‌تان به اینجا بیاید.",
    "Unfavorite": "حذف از علاقه‌مندی", "Favorite": "علاقه‌مندی",
    # playlists screens
    "Empty Playlist": "پلی‌لیست خالی", "Nothing Here": "اینجا چیزی نیست",
    "Right-click songs in Songs and choose Add to Playlist.": "در بخش آهنگ‌ها روی آهنگ راست‌کلیک کنید و «افزودن به پلی‌لیست» را بزنید.",
    "Touch and hold a song in Library and choose Add to Playlist.": "در کتابخانه روی آهنگ نگه دارید و «افزودن به پلی‌لیست» را بزنید.",
    "No songs match yet.": "هنوز آهنگی با این شرط نمی‌خواند.",
    # watched folders
    "Watched folders": "پوشه‌های تحت نظر",
    "No folders yet. Songs that appear in a watched folder are added to your library by themselves.": "هنوز پوشه‌ای نیست. آهنگ‌هایی که در پوشهٔ تحت نظر ظاهر شوند خودکار به کتابخانه اضافه می‌شوند.",
    "Add Folder…": "افزودن پوشه…", "Tip": "نکته", "Not found": "پیدا نشد", "Stop watching": "توقف نظارت",
    "Telegram Desktop usually saves files in a folder called “Telegram Desktop” inside Downloads. Watch that folder and every audio file you receive shows up in Musicam, then on your iPhone.": "تلگرام دسکتاپ معمولاً فایل‌ها را در پوشه‌ای به نام «Telegram Desktop» داخل Downloads ذخیره می‌کند. آن پوشه را تحت نظر بگیرید تا هر فایل صوتی که دریافت می‌کنید در Musicam و بعد روی آیفون‌تان ظاهر شود.",
    # sync
    "Not paired": "جفت نشده", "Looking for your other device…": "در جست‌وجوی دستگاه دیگر…",
    "That code is not valid. It should be 64 letters and digits, shown in groups of 8.": "این کد معتبر نیست. باید ۶۴ حرف و رقم باشد که در گروه‌های ۸تایی نوشته می‌شود.",
    "Status": "وضعیت", "Copying a song from your other device": "در حال کپی یک آهنگ از دستگاه دیگر", "Pairing code": "کد جفت‌سازی",
    "Show code": "نمایش کد", "Share code": "اشتراک‌گذاری کد",
    "Treat this code like a password: anyone who has it can sync with your library while on your network.": "با این کد مثل رمز عبور رفتار کنید: هر کسی که آن را داشته باشد و در شبکهٔ شما باشد می‌تواند با کتابخانه‌تان همگام شود.",
    "Forget this pairing": "فراموش‌کردن این جفت‌سازی", "How it works": "چطور کار می‌کند",
    "Your devices talk directly to each other over your own Wi-Fi, with nothing stored in the cloud. Open Musicam on both devices while they are on the same network. Songs and changes appear on both; the audio file is copied to a device the first time you play the song there.": "دستگاه‌های شما مستقیم و از طریق Wi-Fi خودتان با هم حرف می‌زنند و هیچ چیز در ابر ذخیره نمی‌شود. Musicam را روی هر دو دستگاه و در یک شبکه باز کنید. آهنگ‌ها و تغییرات روی هر دو دیده می‌شوند؛ فایل صوتی اولین بار که آهنگ را روی یک دستگاه پخش کنید به آن دستگاه کپی می‌شود.",
    "Pair with another device": "جفت‌شدن با دستگاه دیگر",
    "Start on the first device: create a code. Then enter that code on the second device.": "روی دستگاه اول یک کد بسازید. بعد همان کد را روی دستگاه دوم وارد کنید.",
    "Create a pairing code": "ساخت کد جفت‌سازی", "I already have a code": "کد دارم", "Paste the code from your other device": "کد دستگاه دیگر را اینجا بچسبانید",
    "Join": "پیوستن",
    "Connected to %@": "متصل به %@", "Up to date with %@": "به‌روز با %@", "Could not start syncing: %@": "همگام‌سازی شروع نشد: %@",
    # offline
    "Offline": "آفلاین", "Keep songs on this device": "نگه‌داشتن آهنگ‌ها روی این دستگاه", "Space limit": "سقف فضا", "No limit": "بدون سقف",
    "Chosen songs are copied here whenever your other device is reachable, so they play without it. With a limit, songs copied from your other device that you did not choose are removed, oldest first. Songs you imported on this device are never removed.": "هر وقت دستگاه دیگر در دسترس باشد، آهنگ‌های انتخاب‌شده اینجا کپی می‌شوند تا بدون آن هم پخش شوند. اگر سقف بگذارید، آهنگ‌هایی که از دستگاه دیگر کپی شده و انتخابشان نکرده‌اید، قدیمی‌ترین‌ها اول، پاک می‌شوند. آهنگ‌هایی که خودتان روی همین دستگاه وارد کرده‌اید هرگز پاک نمی‌شوند.",
    "Off": "خاموش", "Everything chosen is on this device": "همهٔ آهنگ‌های انتخاب‌شده روی این دستگاه است", "Waiting for your other device": "در انتظار دستگاه دیگر",
    "Copying %lld of %lld…": "در حال کپی %1$lld از %2$lld…",
    # repair
    "Apply Selected": "اعمال انتخاب‌شده‌ها", "Apply All Safe": "اعمال همهٔ موارد مطمئن", "Apply": "اعمال", "Everything looks tidy.": "همه‌چیز مرتب است.",
    "Stop": "توقف", "Look Up Missing Details Online": "جست‌وجوی آنلاین اطلاعات ناقص",
    "Online lookup sends only a song’s title and artist to Deezer and Apple Music search, about one song every few seconds. Changes are saved in Musicam, not inside your files.": "جست‌وجوی آنلاین فقط عنوان و خوانندهٔ آهنگ را به جست‌وجوی Deezer و Apple Music می‌فرستد، تقریباً یک آهنگ در هر چند ثانیه. تغییرها در Musicam ذخیره می‌شوند، نه داخل فایل‌های شما.",
    "Online lookup sends only a song’s title and artist to Deezer and Apple Music search. Changes are saved in Musicam, not inside your files.": "جست‌وجوی آنلاین فقط عنوان و خوانندهٔ آهنگ را به جست‌وجوی Deezer و Apple Music می‌فرستد. تغییرها در Musicam ذخیره می‌شوند، نه داخل فایل‌های شما.",
    "Search the Web": "جست‌وجو در وب",
    "Opens a Google, YouTube or Spotify search in your browser so you can check the song, then edit it in Musicam.": "جست‌وجوی Google، YouTube یا Spotify را در مرورگر باز می‌کند تا آهنگ را بررسی کنید و بعد در Musicam ویرایشش کنید.",
    "Applied repairs": "تعمیرهای اعمال‌شده", "Safe": "مطمئن", "Check": "بررسی شود", "Skip": "رد کردن", "Remove": "حذف", "Keep": "نگه‌داشتن",
    "no file": "بدون فایل", "Remove Extra Copies": "حذف نسخه‌های اضافه", "cover added": "کاور افزوده شد", "cover": "کاور", "Cover": "کاور",
    "Undo": "بازگردانی", "Undone": "بازگردانده شد", "Repair": "تعمیر",
    "title": "عنوان", "artist": "خواننده", "album": "آلبوم", "albumArtist": "خوانندهٔ آلبوم",
    "Nothing is missing details.": "اطلاعات هیچ آهنگی ناقص نیست.",
    "Could not reach the online music catalogs. Check the connection and try again.": "به کاتالوگ‌های آنلاین موسیقی وصل نشد. اتصال را بررسی کنید و دوباره امتحان کنید.",
    "No artist": "بدون خواننده", "No album": "بدون آلبوم", "No title": "بدون عنوان", "Title is a file name": "عنوان همان نام فایل است",
    "Generic title": "عنوان کلی", "Site names or tags in text": "نام سایت یا برچسب در متن", "Garbled text": "متن خراب‌شده", "No cover": "بدون کاور", "Odd year": "سال نامعتبر",
    # menus and app level
    "Playback": "پخش", "Play / Pause": "پخش / توقف", "Next Song": "آهنگ بعدی", "Previous Song": "آهنگ قبلی",
    "Musicam could not open your library": "Musicam نتوانست کتابخانهٔ شما را باز کند", "by Meraj Mirbazel": "ساختهٔ Meraj Mirbazel",
    "Foundation build": "نسخهٔ پایه",
    # smart playlists
    # links and wishlist
    "Wishlist": "فهرست آرزوها", "Paste a link": "یک لینک بچسبانید", "Add": "افزودن", "Add from Link": "افزودن از لینک", "Add from Link…": "افزودن از لینک…",
    "Close": "بستن",
    "Spotify and YouTube links are added to your Wishlist by name only; Musicam does not take audio from them. When you get the song legitimately (a purchase, a file from a friend, a CD) and add it, it is ticked off. A direct link to an audio file you are allowed to download, such as one from the Internet Archive, is downloaded and added to your library.": "لینک‌های Spotify و YouTube فقط با نام آهنگ به فهرست آرزوها اضافه می‌شوند؛ Musicam از آنها صدا نمی‌گیرد. وقتی آهنگ را از راه مجاز به دست آورید (خرید، فایل از دوست، سی‌دی) و اضافه کنید، تیک می‌خورد. لینک مستقیم به فایل صوتی‌ای که اجازهٔ دانلودش را دارید، مثل Internet Archive، دانلود و به کتابخانه اضافه می‌شود.",
    "Added “%@” to your Wishlist.": "«%@» به فهرست آرزوها اضافه شد.", "That link is already on your Wishlist.": "این لینک از قبل در فهرست آرزوها هست.",
    "Downloaded “%@” and added it to your library.": "«%@» دانلود و به کتابخانه اضافه شد.",
    "Musicam cannot take audio from %@. Add the song to your Wishlist from its Spotify or YouTube link, then add the file when you have it.": "Musicam از %@ صدا نمی‌گیرد. آهنگ را با لینک Spotify یا YouTube به فهرست آرزوها اضافه کنید و وقتی فایلش را داشتید اضافه‌اش کنید.",
    "That does not look like a link to a song or an audio file.": "این شبیه لینک یک آهنگ یا فایل صوتی نیست.",
    "This link is not supported.": "این لینک پشتیبانی نمی‌شود.", "The page did not answer as expected.": "صفحه پاسخ مورد انتظار را نداد.",
    "That link is not a direct audio file.": "این لینک یک فایل صوتی مستقیم نیست.", "That file is too large.": "این فایل خیلی بزرگ است.",
    "Only https links can be downloaded.": "فقط لینک‌های https قابل دانلودند.", "The server answered with error %lld.": "سرور با خطای %lld پاسخ داد.",
    "Your Wishlist is empty": "فهرست آرزوهای شما خالی است", "Paste a Spotify or YouTube link to remember a song by name.": "لینک Spotify یا YouTube را بچسبانید تا آهنگ با نامش به خاطر سپرده شود.",
    "Open": "باز کردن", "In your library": "در کتابخانهٔ شما", "Remove from Wishlist": "حذف از فهرست آرزوها",
    # QR pairing
    "Pairing QR code": "کد QR جفت‌سازی", "Scan": "اسکن", "Scan QR Code": "اسکن کد QR",
    "Scan this with Musicam on your other device, or enter the code below.": "این را با Musicam روی دستگاه دیگر اسکن کنید، یا کد زیر را وارد کنید.",
    "Point the camera at the QR code on your other device.": "دوربین را روی کد QR دستگاه دیگر بگیرید.",
    "Camera access was denied. You can allow it in Settings, or type the code instead.": "دسترسی به دوربین رد شد. می‌توانید در Settings اجازه بدهید، یا به‌جای آن کد را تایپ کنید.",
    "No camera is available here. Type the code instead.": "اینجا دوربینی در دسترس نیست. به‌جای آن کد را تایپ کنید.",
    "That QR code is not a Musicam pairing code.": "این کد QR، کد جفت‌سازی Musicam نیست.",
    # redesign: home, library, lock, undo, sources
    "Good morning": "صبح بخیر", "Good afternoon": "ظهر بخیر", "Good evening": "عصر بخیر",
    "Your Playlists": "پلی‌لیست‌های شما", "New Playlist": "پلی‌لیست جدید", "Recently Downloaded": "دانلودهای اخیر", "Recently Played": "اخیراً پخش‌شده",
    "Most Played": "بیشترین پخش", "Least Played": "کمترین پخش", "See All": "همه",
    "Songs copied from your other device, downloaded from a link, or received from Telegram or another app show up here.": "آهنگ‌هایی که از دستگاه دیگر کپی شده، از لینک دانلود شده یا از تلگرام و برنامه‌های دیگر رسیده‌اند اینجا نشان داده می‌شوند.",
    "Songs you play show up here.": "آهنگ‌هایی که پخش می‌کنید اینجا نشان داده می‌شوند.",
    "Your most played songs show up here after you have listened for a while.": "بعد از مدتی گوش‌دادن، پرپخش‌ترین آهنگ‌های شما اینجا نشان داده می‌شوند.",
    "Songs you have played the least show up here.": "آهنگ‌هایی که کمتر از همه پخش کرده‌اید اینجا نشان داده می‌شوند.",
    "1 play": "۱ بار پخش", "%lld plays": "%lld بار پخش",
    "Search": "جست‌وجو", "Search your songs": "آهنگ‌هایتان را جست‌وجو کنید",
    "Type a song title in Persian or English. Search works without internet.": "عنوان آهنگ را فارسی یا انگلیسی بنویسید. جست‌وجو بدون اینترنت کار می‌کند.",
    "Song title, artist or album": "عنوان آهنگ، خواننده یا آلبوم", "More": "بیشتر", "Show": "نمایش", "Library": "کتابخانه",
    "Select": "انتخاب", "Done": "تمام", "Select All": "انتخاب همه", "Deselect All": "لغو انتخاب همه", "Favorite": "علاقه‌مندی", "Unfavorite": "حذف از علاقه‌مندی",
    "Remove": "حذف", "Remove from Library": "حذف از کتابخانه", "Remove from Playlist": "حذف از پلی‌لیست", "Add to Playlist": "افزودن به پلی‌لیست", "New Playlist…": "پلی‌لیست جدید…",
    "Unknown artist": "خوانندهٔ نامشخص", "No songs yet": "هنوز آهنگی نیست",
    "Add songs from Files or share them from Telegram, or open More and pair with your Mac to bring your library here.": "آهنگ‌ها را از Files اضافه کنید یا از تلگرام به اینجا بفرستید، یا در «بیشتر» با مک جفت شوید تا کتابخانه‌تان بیاید.",
    "No favorites yet": "هنوز علاقه‌مندی‌ای نیست", "Swipe a song to the right to add it.": "آهنگ را به راست بکشید تا اضافه شود.",
    "No playlists yet": "هنوز پلی‌لیستی نیست", "Playlists work like folders: make one, then add songs from the Songs list.": "پلی‌لیست‌ها مثل پوشه کار می‌کنند: یکی بسازید و آهنگ‌ها را از فهرست آهنگ‌ها اضافه کنید.",
    "Playlist not found": "پلی‌لیست پیدا نشد", "Remove from Library": "حذف از کتابخانه",
    "Imported": "واردشده", "Folder": "پوشه", "Watched folder": "پوشهٔ تحت نظر", "Telegram": "تلگرام", "Shared": "اشتراکی", "Source": "منبع", "Source: %@": "منبع: %@",
    "Settings": "تنظیمات", "Security": "امنیت", "Lock Musicam": "قفل Musicam", "Ask again": "پرسش دوباره", "Immediately": "فوراً", "After 1 minute": "بعد از ۱ دقیقه", "After 5 minutes": "بعد از ۵ دقیقه",
    "Musicam asks for Face ID, Touch ID or your passcode when it opens and when you come back to it. Music keeps playing while it is locked.": "Musicam هنگام باز شدن و بازگشت به برنامه، Face ID، Touch ID یا رمز دستگاه را می‌خواهد. موسیقی هنگام قفل‌بودن هم پخش می‌شود.",
    "Musicam is locked": "Musicam قفل است", "Unlock": "باز کردن قفل", "About": "درباره", "Language": "زبان", "Follow System": "مطابق سیستم", "Reopen Musicam to finish changing the language.": "برای اعمال زبان، Musicam را دوباره باز کنید.", "Quit Musicam": "خروج از Musicam",
    "To use the app lock, set a passcode on this device first.": "برای استفاده از قفل برنامه، اول روی این دستگاه رمز بگذارید.",
    "Could not confirm it is you, so nothing was changed.": "هویت شما تأیید نشد، پس چیزی تغییر نکرد.", "Could not unlock. Try again.": "قفل باز نشد. دوباره امتحان کنید.",
    "Turn on the Musicam lock": "روشن‌کردن قفل Musicam", "Turn off the Musicam lock": "خاموش‌کردن قفل Musicam", "Unlock Musicam": "باز کردن قفل Musicam",
    "This device cannot verify who you are.": "این دستگاه نمی‌تواند هویت شما را تأیید کند.",
    "Undo": "بازگردانی", "Dismiss": "بستن", "Removed “%@”": "«%@» حذف شد", "Deleted playlist “%@”": "پلی‌لیست «%@» حذف شد",
    "Removed 1 song from “%@”": "۱ آهنگ از «%@» حذف شد", "Applied 1 repair": "۱ تعمیر اعمال شد",
    "Select a song to see and edit its details.": "یک آهنگ را انتخاب کنید تا جزئیاتش را ببینید و ویرایش کنید.",
    "Add Telegram Folder…": "افزودن پوشهٔ تلگرام…", "Watch This Folder": "این پوشه را تحت نظر بگیر",
    "Choose the folder where Telegram Desktop saves your downloads.": "پوشه‌ای را که Telegram Desktop دانلودها را در آن ذخیره می‌کند انتخاب کنید.",
    "Open": "باز کردن", "Add Music": "افزودن موسیقی",
    # misc ui
    "Importing %lld of %lld": "در حال افزودن %1$lld از %2$lld",
    "Suggestions (%lld)": "پیشنهادها (%lld)", "Possible duplicates (%lld)": "تکراری‌های احتمالی (%lld)",
    "%lld already in your library": "%lld مورد از قبل در کتابخانه بود", "%lld unchanged": "%lld مورد بدون تغییر",
    "%lld in a format that cannot be played (Ogg)": "%lld مورد در قالبی که پخش نمی‌شود (Ogg)", "%lld could not be read": "%lld مورد خوانده نشد",
    "%@ hours": "%@ ساعت", "%lld minutes": "%lld دقیقه",
}

# key: (english one, english other, persian)
PLAIN.update({
    "Musicam does not know how to get that.": "Musicam نمی‌داند این را چگونه بگیرد.",
    "Cancelled.": "لغو شد.",
    "There is nothing to get.": "چیزی برای دریافت نیست.",
    "The downloaded file is missing.": "فایل دانلودشده پیدا نشد.",
    "The downloaded file is empty.": "فایل دانلودشده خالی است.",
    "The downloaded file is not an audio file.": "فایل دانلودشده صوتی نیست.",
    "The song could not be added to the library.": "آهنگ به کتابخانه اضافه نشد.",
    "Nothing was downloaded.": "چیزی دانلود نشد.",
    "A provider named “%@” is already registered.": "منبعی با نام «%@» از قبل ثبت شده است.",
    "Downloading…": "در حال دانلود…",
    "Looking at the item…": "در حال بررسی مورد…",
    "There is no link to download.": "لینکی برای دانلود نیست.",
    "That is not an Internet Archive link.": "این لینک Internet Archive نیست.",
    "Direct audio link": "لینک مستقیم فایل صوتی",
    "Same Wi-Fi": "همان وای‌فای",
    "Open Musicam on both devices while they are on the same network.": "Musicam را روی هر دو دستگاه باز کنید، وقتی به یک شبکه وصل‌اند.",
    "Private": "خصوصی",
    "Your devices talk directly to each other. Nothing is stored in the cloud.": "دستگاه‌ها مستقیم با هم حرف می‌زنند. چیزی در فضای ابری ذخیره نمی‌شود.",
    "Always the same library": "همیشه یک کتابخانه",
    "Songs and changes appear on both. A song's audio file is copied to a device the first time you play it there.": "آهنگ‌ها و تغییرها روی هر دو دیده می‌شوند. فایل صوتی یک آهنگ اولین بار که آن را روی یک دستگاه پخش کنید روی آن کپی می‌شود.",
    "Your Library": "کتابخانهٔ شما", "Total time": "مجموع زمان",
    "Search online for “%@”": "جست‌وجوی آنلاین «%@»",
    "Searching…": "در حال جست‌وجو…", "Online": "آنلاین", "Loading…": "در حال بارگیری…", "Download": "دانلود",
    "Searches the Internet Archive, a free library of public-domain and openly licensed music. Songs from streaming services are not available here.": "در Internet Archive جست‌وجو می‌کند؛ کتابخانه‌ای رایگان از موسیقی عمومی و دارای مجوز آزاد. آهنگ‌های سرویس‌های استریم اینجا در دسترس نیستند.",
    "No songs match “%@”.": "آهنگی با «%@» پیدا نشد.",
    "Nothing found online.": "چیزی آنلاین پیدا نشد.",
    "Could not search online. Check the connection and try again.": "جست‌وجوی آنلاین انجام نشد. اتصال را بررسی کنید و دوباره امتحان کنید.",
    "This item has no audio files to download.": "این مورد فایل صوتی قابل دانلود ندارد.",
    "Could not load this item. Check the connection and try again.": "این مورد بارگیری نشد. اتصال را بررسی کنید و دوباره امتحان کنید.",
    "That file could not be added.": "این فایل اضافه نشد.",
    "Select this song": "انتخاب این آهنگ",
    "Still missing details (%lld)": "آهنگ‌های بدون جزئیات (%lld)",
})

PLURAL = {
    "Added %lld songs": ("Added %lld song", "Added %lld songs", "%lld آهنگ افزوده شد"),
    "%lld songs": ("%lld song", "%lld songs", "%lld آهنگ"),
    "%lld stars": ("%lld star", "%lld stars", "%lld ستاره"),
    "%lld songs selected": ("%lld song selected", "%lld songs selected", "%lld آهنگ انتخاب شده"),
    "Remove %lld songs": ("Remove %lld song", "Remove %lld songs", "حذف %lld آهنگ"),
    "Removed %lld songs": ("Removed %lld song", "Removed %lld songs", "%lld آهنگ حذف شد"),
    "Removed %lld songs from “%@”": ("Removed %lld song from “%@”", "Removed %lld songs from “%@”", "%1$lld آهنگ از «%2$@» حذف شد"),
    "Applied %lld repairs": ("Applied %lld repair", "Applied %lld repairs", "%lld تعمیر اعمال شد"),
    "Found %lld suggestions.": ("Found %lld suggestion.", "Found %lld suggestions.", "%lld پیشنهاد پیدا شد."),
}


# Downloads screen (replaces the Wishlist screen; the Wishlist now lives inside it)
PLAIN.update({
    "Downloads": "دانلودها", "Clear Finished": "پاک‌کردن تمام‌شده‌ها", "No downloads yet": "هنوز دانلودی نیست",
    "Paste a Spotify link in Add from Link and the song is downloaded into your library.": "لینک Spotify را در «افزودن از لینک» بچسبانید تا آهنگ دانلود و به کتابخانه اضافه شود.",
    "Waiting…": "در انتظار…", "Adding to your library…": "در حال افزودن به کتابخانه…", "Songs added: %lld": "آهنگ‌های افزوده‌شده: %lld",
    "Cancelled": "لغو شد", "Try Again": "تلاش دوباره",
})

# Merajfy on this iPhone (Python + yt-dlp inside the app)
PLAIN.update({
    "Merajfy (on this iPhone)": "Merajfy (روی همین iPhone)", "Reading Spotify…": "در حال خواندن Spotify…",
    "That link has no songs.": "این لینک آهنگی ندارد.", "Could not get that song.": "این آهنگ دریافت نشد.",
    "The downloader inside this app is not available.": "دانلودر داخل این برنامه در دسترس نیست.",
    "Could not finish the audio file: %@": "ساخت فایل صوتی تمام نشد: %@",
    "No confident YouTube match for “%@”.": "برای «%@» نتیجهٔ مطمئنی در YouTube پیدا نشد.",
    "Only the first %lld songs were taken.": "فقط %lld آهنگ اول گرفته شد.",
    "On this iPhone": "روی همین iPhone", "On my Mac": "روی Mac من", "M4A (AAC)": "M4A (AAC)", "File format": "فرمت فایل",
    "Merajfy is ready on this iPhone.": "Merajfy روی همین iPhone آماده است.",
    "The downloader started but found nothing. Check the connection.": "دانلودر شروع شد ولی چیزی پیدا نکرد. اتصال را بررسی کنید.",
    "With this on, a Spotify track, album or playlist link in Add from Link is downloaded on this iPhone and added to your library. Nothing needs to run on your Mac. With it off, those links are only added to your Wishlist by name. The first song of a session takes a few seconds longer while the downloader starts.":
        "وقتی روشن باشد، لینک آهنگ، آلبوم یا پلی‌لیست Spotify در «افزودن از لینک» روی همین iPhone دانلود و به کتابخانه اضافه می‌شود. لازم نیست چیزی روی Mac اجرا شود. وقتی خاموش باشد، این لینک‌ها فقط با نام به فهرست آرزوها می‌روند. اولین آهنگ هر بار چند ثانیه بیشتر طول می‌کشد، چون دانلودر باید راه بیفتد.",
})

# Merajfy (Spotify downloads through the Merajfy helper)
PLAIN.update({
    "Merajfy": "Merajfy",
    "Spotify": "اسپاتیفای",
    "Spotify Downloads": "دانلود از اسپاتیفای",
    "Get Spotify songs with Merajfy": "دریافت آهنگ‌های اسپاتیفای با Merajfy",
    "Mac address": "نشانی مک",
    "Token": "توکن",
    "File format": "قالب فایل",
    "Test Connection": "آزمایش اتصال",
    "Open Merajfy": "باز کردن Merajfy",
    "Merajfy is ready.": "Merajfy آماده است.",
    "Merajfy is running but yt-dlp or ffmpeg is missing on the Mac.": "Merajfy روشن است ولی yt-dlp یا ffmpeg روی مک نیست.",
    "Type the address of the Mac, for example 192.168.1.20:8787.": "نشانی مک را بنویسید، مثلاً 192.168.1.20:8787.",
    "Musicam cannot reach Merajfy. Is it running on your Mac?": "Musicam به Merajfy دسترسی ندارد. آیا روی مک شما روشن است؟",
    "Merajfy sent an unreadable answer.": "Merajfy پاسخ نامفهومی فرستاد.",
    "Merajfy refused the token. Check it in Settings.": "Merajfy توکن را نپذیرفت. آن را در تنظیمات بررسی کنید.",
    "That address does not look like Merajfy.": "این نشانی شبیه Merajfy نیست.",
    "Merajfy could not hand over the file.": "Merajfy نتوانست فایل را تحویل دهد.",
    "Merajfy is not set up. Turn it on in Settings.": "Merajfy تنظیم نشده است. آن را در تنظیمات روشن کنید.",
    "Asking Merajfy…": "در حال درخواست از Merajfy…",
    "Merajfy could not get that song.": "Merajfy نتوانست این آهنگ را بگیرد.",
    "Merajfy answered with error %lld.": "Merajfy با خطای %lld پاسخ داد.",
    "Downloading %lld of %lld…": "در حال دانلود %1$lld از %2$lld…",
    "%lld song(s) could not be found.": "%lld آهنگ پیدا نشد.",
    "Merajfy is a separate program that runs on your Mac. With this on, a Spotify track, album or playlist link in Add from Link is downloaded and added to your library. With it off, those links are only added to your Wishlist by name. On the Mac the address is 127.0.0.1:8787; on the iPhone use your Mac's address and the token shown in Merajfy's settings.":
        "Merajfy برنامه‌ای جداست که روی مک شما اجرا می‌شود. وقتی روشن باشد، لینک آهنگ، آلبوم یا پلی‌لیست اسپاتیفای در «افزودن از لینک» دانلود و به کتابخانه اضافه می‌شود. وقتی خاموش باشد، این لینک‌ها فقط با نام به فهرست آرزوها می‌روند. روی مک نشانی 127.0.0.1:8787 است؛ روی آیفون نشانی مک و توکنی را که در تنظیمات Merajfy نمایش داده می‌شود بنویسید.",
    "Spotify and YouTube links are added to your Wishlist by name only. If Merajfy is turned on in Settings, a Spotify track, album or playlist link is downloaded and added to your library instead. A direct link to an audio file you are allowed to download, such as one from the Internet Archive, is downloaded and added to your library.":
        "لینک‌های اسپاتیفای و یوتیوب فقط با نام به فهرست آرزوها اضافه می‌شوند. اگر Merajfy در تنظیمات روشن باشد، لینک آهنگ، آلبوم یا پلی‌لیست اسپاتیفای به‌جای آن دانلود و به کتابخانه اضافه می‌شود. لینک مستقیم فایل صوتی که اجازهٔ دانلودش را دارید، مثل لینک‌های Internet Archive، دانلود و به کتابخانه اضافه می‌شود.",
})


def unit(v, state="translated"):
    return {"stringUnit": {"state": state, "value": v}}


strings = {}
for k, fa in sorted(PLAIN.items()):
    strings[k] = {"extractionState": "manual", "localizations": {"fa": unit(fa)}}
for k, (one, other, fa) in sorted(PLURAL.items()):
    strings[k] = {"extractionState": "manual", "localizations": {
        "en": {"variations": {"plural": {"one": unit(one), "other": unit(other)}}},
        "fa": {"variations": {"plural": {"other": unit(fa)}}},
    }}

catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
for target in ("App-macOS", "App-iOS"):
    path = os.path.join(ROOT, target, "Localizable.xcstrings")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print("wrote", path, len(strings), "strings")


# the share extension has its own small string table (it follows the system language)
share = {"sourceLanguage": "en", "version": "1.0", "strings": {
    "Opening Musicam…": {"localizations": {"fa": {"stringUnit": {"state": "translated", "value": "در حال باز کردن Musicam…"}}}},
    "There is no link here to add.": {"localizations": {"fa": {"stringUnit": {"state": "translated", "value": "اینجا لینکی برای افزودن نیست."}}}},
    "Link copied. Open Musicam and choose Add from Link.": {"localizations": {"fa": {"stringUnit": {"state": "translated", "value": "لینک کپی شد. Musicam را باز کنید و «افزودن از لینک» را بزنید."}}}},
}}
os.makedirs(os.path.join(ROOT, "App-iOS-Share"), exist_ok=True)
with open(os.path.join(ROOT, "App-iOS-Share", "Localizable.xcstrings"), "w") as f:
    json.dump(share, f, ensure_ascii=False, indent=2)
print("wrote share strings")
