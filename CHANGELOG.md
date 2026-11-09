# Selway — Changelog

---

## 0.5.21

- **A new icon**: the river now rises in a gap in the mountains, with mist at its
  source, wave marks and sparkles on the water, and runs on past the bottom edge,
  so it reads as a river rather than a road or a plain S. The README and the
  website show it too.
- **Selway's source is public**, at
  [github.com/toddbartholow/selway](https://github.com/toddbartholow/selway), with a
  commit for each release. Bug reports and requests go to its issues.
- **Updates come from the public repository**: the update feed moved to
  `https://toddbartholow.github.io/selway/appcast.xml` and downloads to its releases
  page. Copies of 0.5.20 and earlier look for the old feed, so install 0.5.21 by
  hand once. The app's GitHub and issue links point there too.
- **A shorter README**, plus a security policy (`SECURITY.md`: how to report a
  vulnerability, and how updates are signed and checked before they install), a
  contributing guide (`CONTRIBUTING.md`: building and testing from source) and a
  translation guide for volunteers (`docs/TRANSLATING.md`).
- The Install & First Open note in the disk image points to Settings → General for
  the update setting.
- **A new About window**: Selway ▸ About Selway shows the icon, version and build,
  with buttons for the website, GitHub, the changelog and reporting a bug, and an
  Acknowledgments window that lists the open-source code inside Selway (FinderFlow,
  Sparkle, the Ace editor and the libraries inside Ace's build, among them
  Underscore.js, lodash, Browserify's Node.js shims and Visual Studio Code's diff
  algorithm) with each license in full. Acknowledgments opens beside About, both
  open over a full-screen window without switching Spaces, and the list takes the
  arrow keys as soon as it opens. Clicking the Dock icon with only these windows
  open brings back a minimized browser window, or else opens one. Escape or ⌘W closes either window. The copyright
  line now reads "© 2026 Todd Bartholow. MIT License."

## 0.5.20

- **Open folders in Selway is gone**: macOS 26 doesn't let any app, Finder
  included, change the app that opens folders, so turning it on only showed an
  error (OSStatus -50). Its other half, the system `NSFileViewer` preference, made
  other apps' "Show in Finder" open text files in Selway's editor. If an earlier
  version set either one, Settings → General offers **Restore Finder** to undo it
  (on macOS 26 only the `NSFileViewer` half: it refuses the folder handler too).
  To open a folder in Selway from Finder, choose **Open in Selway** from its
  shortcut menu.

## 0.5.19

- **A window opened with File > New Window never takes another one's place**:
  a tab or window still opening (Open in New Tab, Move Other Pane to New Tab)
  keeps its folder and its place, however quickly another window comes.

## 0.5.18

- **A Recent folder on a share that has gone no longer freezes the window**:
  Recent folders and their icons are checked in the background, each on its own.
  A folder on a drive that's ejected leaves Recent until the drive is back, in
  every window.
- **A custom new window folder under an automount folder is skipped**: new
  windows open Home instead of looking up a folder the automounter must not reach.

## 0.5.17

- **Combine tabs and panes**: the toolbar can show or hide the second pane, and
  Window can merge the next tab into that pane or move the inactive pane into a
  new tab beside the current one.

## 0.5.16

- **Selway in French, Japanese and Italian**, alongside German and Spanish.
- **Group by Name sorts Japanese names into kana rows**: あ, か, さ and so on,
  with kanji by their reading when Selway runs in Japanese.

## 0.5.15

- **Selway in German and Spanish**: it follows the Mac's language, or the language
  chosen for Selway alone in System Settings > General > Language & Region > Applications.

## 0.5.14

- **Kind reads like Finder's**: "Plain Text Document" and "Application" rather
  than "TXT File" and "APP File".
- **Group by Name gives other alphabets their own groups**: Cyrillic, Greek and
  letters such as Æ and Ø get a group each after Z, in alphabetical order, instead of
  all going under #.
- **VoiceOver names the Markdown reader's Read/Edit switch** ("Mode").

## 0.5.13

- Groundwork for translations, with no visible changes.

## 0.5.12

- **A disk image on a share that has gone no longer stops Locations updating**:
  each disk image is read on its own, so the other disks still appear and
  update, and one that doesn't answer stays listed, and can be ejected, meanwhile.
- **A pinned folder on a server that's away no longer freezes the window**: pinned
  folders and their icons are read in the background, each on its own, so one
  that doesn't answer keeps its last look and holds up none of the others.
  Neither pinned folders nor a new window's "last folder shown" look into an
  automount folder such as /net any more, which mounted it.
- **Reconnect at Launch tries again when the network comes up**: a saved server
  that couldn't be reached at login, because Wi-Fi hadn't joined yet, is mounted
  once the network is there (up to three more tries, in the first ten minutes).
- **Servers with non-ASCII names show their ASCII form too**, as in "gооgle.com
  (xn--ggle-55da.com)", so a lookalike of a familiar name stands out: in Connect
  to Server's recent servers, the sidebar's server tooltips and rows, and the
  connection messages.

## 0.5.11

- **Columns view keeps its columns at a Time Machine note**: selecting a backup
  that isn't available, or a disk Selway needs Full Disk Access to read, replaced
  the whole column browser with the note. The note now shows in that folder's
  column, and the other columns and the arrow keys keep working.

## 0.5.10

- **Time Machine disks list their backups**: opening a Time Machine backup disk
  showed an empty folder. It now lists one folder per backup, named as in Finder.
  A backup opens read-only, and the path bar shows it under its disk. macOS
  makes a backup available only once Finder or Time Machine has opened it, so
  for one that isn't, Selway offers to open the disk in Finder. macOS lets only
  apps with Full Disk Access read a Time Machine disk; without it, Selway says
  so and opens Privacy & Security. Showing hidden files lists the disk's own
  files, read-only too.
- **Disk overview List columns fit translated capacity and warning text**, and
  stack when the pane is too narrow to show them on one line.
- **A selected disk in an inactive pane uses the grey selection**, matching
  files and icons in that pane.

## 0.5.9

- **Free space on network shares and Time Machine disks**: the computer overview
  and the status bar showed "Zero KB free" (and "Low space") for SMB and NFS
  shares and Time Machine backup disks, which report no space for important
  use. They now show the volume's available space.

## 0.5.8

- **The computer in Locations shows disk space** for mounted drives and network
  shares, as tiles or, in List view, as rows. Double-click a volume to open it, or
  select it (the arrow keys work) and press ⌘↓ or ⌘O. Its context menu ejects it,
  gets its info or copies its path. Copy Path and Eject also act on a selected
  tile. The space shown refreshes while it is open.

## 0.5.7

- **Ready for translation**: the text Selway shows (windows, menus, toolbar,
  settings, alerts, error messages, VoiceOver labels, the Finder extension's menu
  and the permission prompts) is in String Catalogs, written as whole sentences
  with plural forms, so it can be translated. Settings saved by earlier versions
  still load. A Markdown page is marked with your language rather than always
  English.
- **A disk that's in use says who's using it**: when an eject fails because files
  on the disk (on any of its volumes) are open, the alert names the apps that have
  them open (“Preview”, or two of several), when Selway can see them.
- **An APFS and an HFS volume on one drive eject together.** Clicking the second
  one's eject button while the first is ejecting no longer starts another eject,
  which could fail with a busy alert.
- **Quick Look stays open** on the other items when a disk holding some of them is
  ejected. It closed whenever any of its items was on the disk.
- Ejecting a disk no longer reads links on network shares that Locations doesn't
  list (hidden mounts, /net, NFS home folders), where a server that has stopped
  answering could hold it up.

## 0.5.6

- **VoiceOver reads a file's tags** in List, Icons and Columns view, search results
  and the preview, tags without a colour included. They were only coloured dots.
  In Columns view VoiceOver also hears which rows are selected.

## 0.5.5

- **Dual pane**: View → Show Dual Pane (⌃⌘P) shows a second pane beside the
  first, on the same folder, with a divider you can drag (double-click it for half
  and half). View → Make Left Pane Wider, Make Right Pane Wider and Make Panes
  Equal Width move the divider from the keyboard, and VoiceOver can adjust it as a
  splitter ("Left pane 60 percent"). Each window and tab has one pane or two of
  its own, and new windows and tabs start the way you last chose. Beside each
  other, each pane shows its own path bar and status bar, and the preview panel is
  hidden. A click anywhere in a pane, keyboard focus moving into it, or selecting
  something in it (as VoiceOver does) makes it the active pane: a thick line under
  its path bar and its folder's name in bold mark it, and the sidebar, the search
  field, the toolbar, the menus and their shortcuts, and the window's title follow
  it. Go → Switch to Other Pane (⌃⌘O) makes the other pane active and gives its
  list the keyboard. A tag chosen in the sidebar filters the active pane, so the
  tag highlighted there changes when you switch panes. View → Hide Dual Pane keeps
  the active pane, and its list keeps the keyboard. Shown again, the hidden pane
  lists what changed meanwhile. If its folder was deleted or renamed it shows the
  nearest folder still there, and if its disk was ejected, your home folder.
  VoiceOver hears which pane is active as you switch, and when the second pane is
  shown or hidden. Files dragged
  from one pane to the other move or copy as a drag anywhere does.
- **Copy and Move to Other Pane (F5, F6)**, as in Commander One: File → Copy to
  Other Pane and Move to Other Pane put the active pane's selection into the folder
  the other pane shows, once you confirm, with progress and Edit → Undo, as a drop
  does. A name already taken there gets a new one ("alpha 2.txt"), and items
  inside a selected folder go with it rather than twice. With one pane both
  commands are disabled. Otherwise they beep and say why in a toast when nothing
  is selected ("Select items to copy first"), both panes show the same folder
  (however its path is spelled, through a symlink or in another case; search
  results from elsewhere can still go there), an item is
  already in the other pane's folder, or the other pane's folder is a selected
  folder or inside one ("“Photos” can’t be moved into itself"). In Columns view
  they take what ⌘C does: files selected in a column, not a folder selected there.
- **Copy Path's toast shows in its own window**: with several windows open,
  "Path copied" no longer appears in every one of them, only in the window you
  copied from. Copying with the path bar's button now also undims items you had
  cut at once, as the other Copy Path commands do (the copy replaces them on the
  clipboard).

## 0.5.4

- **Tabs, as in Finder**: File → New Tab (⌘T) opens a tab in the window on the
  folder new windows open (Settings → General), after the window's other tabs, and
  so does the **+** at the end of the tab bar. A folder's right-click menu has
  **Open in New Tab** beside Open in New Window, and a ⌘-double-click on a folder
  opens it in a new tab, in List, Icons and Columns views. They're macOS's own
  tabs: View → Show All Tabs, Window → Merge All Windows and Move Tab to New
  Window, ⌃⇥ to the next tab, and a tab dragged out becomes a window, each tab
  keeping its folder, history and selection. ⌘W closes the tab shown. Finder moves
  files dropped on a tab into its folder; Selway doesn't yet.
- **Open folders in new tabs**: Settings → General → Double-click a folder to open
  it in has a third choice, **A new tab**. Opening several folders at once (⌘O or
  a double-click on a selection) then opens each in a tab of the window, rather
  than a window each.
- **The code editor and the Markdown reader stay out of tabs**: with "Prefer tabs
  when opening documents" set to Always in System Settings, or after Window →
  Merge All Windows, they keep windows of their own instead of joining a browser
  window's tabs.

## 0.5.3

- **⌘O on non-Latin keyboard layouts**: with a Russian, Greek or other non-Latin
  input source, ⌘O now opens the selection in List, Icons and Columns views, taking
  the key in O's place on your Latin layout, as menu shortcuts do. That layout's
  letters typed without ⌘ still select items by name, as before.
- **File → Open (⌘O)**: the File menu has Open, as in Finder, enabled when something
  is selected. It opens the selection as ⌘O does in each view: List and Icons views
  open a folder in the window, and Columns view goes into it as the next column. ⌘O
  typed in a text field (a rename, the search field, the path editor) is still the
  field's.
- **⌘-dragging a selection moves all of it**: in Icons and Columns views, a ⌘-drag
  that starts on a selected item now carries every selected item, as in Finder. The
  press used to take that item out of the selection, so the drag carried it alone. A
  ⌘-click that doesn't drag still takes a selected item out, now when the button
  comes up.
- **Double-clicking a selection in Columns view opens all of it**: a double-click on
  one of several selected rows opens every selected item, as in Finder and Icons view,
  where it used to open only that row. Several files each open in their app; several
  folders each open in a window of their own, as with ⌘O. A click on one row of the
  selection now selects it alone a moment later (after the double-click interval), as
  in Icons view. The arrow keys and typing a name in that moment move on from the row
  clicked; Select All or a context menu then keeps the whole selection.
- **Column rows and search results follow files as they change**: a file written to
  or retagged while it's shown in a column or among search results shows its current
  tags there, and its current size and date in the search results and the status
  bar's total for a selection, without the folder being read again. The selection
  and scroll position stay where they were. Search results follow the files in the
  folders on screen (the one you're in, and each column's); results further down,
  from This Folder & Subfolders or a Spotlight scope, still show the values from when
  the search ran. VoiceOver reads a column row's tags.
- **Drops on a folder icon, as in Finder**: in Icons view a folder takes a drop only on
  its picture and name, and is highlighted around them rather than across its whole
  cell. A drop on the blank space beside a short name goes into the folder shown.
- **Drops from Mail, Photos and Safari**: a window or folder now takes a drag that
  carries file promises rather than files (a Mail attachment, a photo from Photos, an
  image from Safari), as a copy. Each file lands as its app finishes writing it, with a
  free name when its own is in use ("photo 2.jpg"), as a copy does, and the new files
  are selected. The progress strip shows the drop until the last file arrives and can
  cancel it, and Quit waits for it. A file its app couldn't write, or that hasn't
  arrived two minutes after the one before, is reported, and Edit → Undo moves the
  new files to the Trash.
- **Dragging files out moves them, as in Finder**: a drag to another app offers it a
  move, a link and a delete as well as a copy, and the app chooses. Dropped on a
  Finder folder on the same volume (or with ⌘ held) the files move rather than copy,
  and dropped on the Dock's Trash they go to the Trash; Mail still copies. The folder
  they left is refreshed, and a drag of icons or column rows to the Trash can be put
  back with Edit → Undo. A move to another folder can't be undone in Selway (Finder
  did it), and neither can anything dragged from List view or search results: a List
  row dropped on a Finder folder on the same volume now moves rather than copies, and
  Edit → Undo doesn't bring it back.

## 0.5.2

- **Settings tabs fit their options**: each tab is now as tall as its options, so
  none of them has to be scrolled to reach the last ones (all but Tags did). A tab
  still scrolls on a screen too short for it, and Tags scrolls once it lists more tags
  than fit.

## 0.5.1

- **Icon previews, as in Finder**: files show a preview of their contents in place of
  their type icon (a picture, a PDF's first page, a movie's frame, a document's first
  page) in Icons, List and Columns views, the preview panel and drags. The type icon
  shows first and the preview replaces it when Quick Look has made it; only the icons
  on screen get one. A file changed in place gets a new one, and so does a link when
  the file it leads to changes (once its folder is listed again). Folders, apps and
  links Selway didn't follow keep their icons, and nothing under /net, /home or
  /Network is previewed (that could mount a server); mounted shares are previewed like
  local disks. Settings → Browse → Icon previews turns them off.

## 0.5.0 — Renamed to Selway

Selway is now a standalone project. It began as a fork of
[FinderFlow](https://github.com/Gtarafdar/FinderFlow) by Gobinda Tarafdar (MIT);
the entries under "FinderFlow history" below are from that time.

- **New name and identity** — the app is **Selway** (`Selway.app`), with bundle ID
  `studio.irq.selway` (Finder extension: `studio.irq.selway.extension`). Releases are
  published on GitHub and release files are named `Selway-<version>.dmg`. A new app icon — a river
  winding out of the mountains in an S — replaces FinderFlow's.
- **Updates now use [Sparkle](https://sparkle-project.org)** — Sparkle 2 with its
  standard update windows replaces the custom updater and its update banner.
  Selway → Check for Updates… and the Settings toggle work as before. The feed
  (`appcast.xml` on GitHub Pages) and every download are Ed25519-signed with the
  Selway release key, and Sparkle checks each download before opening it. Installing
  still goes through the normal quit, so unsaved-changes prompts apply, and no check
  or install starts while a quit is waiting on them. Selway only updates itself where
  your account can replace it (no administrator prompts). Delta updates keep downloads
  small.
- **New URL scheme** — links use `selway://` instead of `finderflow://`. What a link may
  do, and when it asks first, is unchanged from FinderFlow 1.5.2.
- **Settings start fresh** — Selway keeps its preferences under its own bundle ID and
  doesn't import the old app's settings.
- **Installing over the old app** — the old app is a separate app with its own bundle
  ID and won't update itself to Selway: install Selway by hand. If you turned on
  **Open folders in FinderFlow**, turn it off in that app before deleting it.
- **Text size** — View → Make Text Bigger (⌘+ or ⌘=), Make Text Smaller (⌘−) and
  Actual Text Size (⌘0), or Settings → General, make browser windows' text, file
  and toolbar icons, the sidebar and rows 115%, 130%, 150%, 175% or 200% of their
  usual size. The toolbar keeps the system's size, so the status bar says how the
  list is sorted and grouped and how a search went. The Markdown window has its own
  text size and the code editor its own font size: the same commands change those
  while one of them is in front.
- **Toolbar in the title bar** — the path, search and action rows are gone: the
  actions, view, grouping and sort live in the window's own toolbar, as in Finder,
  which can be customized (View → Customize Toolbar…) and moves what doesn't fit
  into its » menu. The less used items (Preview, Hidden Files, New Text File, Move to
  Trash, Delete Permanently, Undo, Redo, Paste, Copy Path, Refresh) start in the customization
  palette and are all in the menu bar. The window is titled after the folder shown.
- **Locations in the sidebar** — as in Finder, between Favorites and Pinned: the
  startup disk, other internal disks, external drives, CDs, DVDs and disk images, and
  the servers you're connected to, updated as they're connected, ejected or renamed.
  Drives, disk images and servers have an eject button, an Eject item in their menu,
  and Selway → Eject (⌘E) ejects the one selected. Windows showing a folder on it go
  to your home folder first; if something is still using it, Selway says so. Settings
  → Sidebar chooses which of the four kinds show (all of them to start with).
- **A server that stops answering no longer holds up Locations**: drives, disk
  images and other servers still come and go in the sidebar while one server is
  slow to answer or has gone away. Until it answers, its share stays listed under
  its folder's name in /Volumes with a plain icon, standing in for its saved server,
  so it can still be ejected; Selway tries it again every so often.
- **Connect to Server** — Go → Connect to Server… (⌘K) mounts an SMB, AFP, NFS,
  WebDAV (http/https) or FTP share (FTP read-only, as macOS mounts it) and opens it;
  a plain `server/share` is taken as SMB. The sheet lists your recent servers (click
  to fill in, double-click to connect) and shows progress, which Cancel stops. Logins
  go through macOS's own prompt and keychain: Selway never sees or stores a password,
  and one typed in an address is dropped; the sheet warns that `http://` and `ftp://`
  aren't encrypted. Other kinds of address (`file:`, `vnc:`…) are refused, and
  `selway://` links and the Finder extension can't start a mount, nor open a path
  through an automount folder (`/net`, `/Network/Servers`, `/home`, or any autofs
  folder a link leads into).
- **Saved servers** — "+" in Connect to Server, Save Server in Sidebar on a share's
  row, or Save Server Folder in Sidebar on a folder on a share, lists it under
  Locations. While it isn't connected it's dimmed, and a click (or Return) connects it
  and opens it, while the arrow keys only move past it; once connected, the share's own row stands in for it. Its menu has Connect,
  Reconnect at Launch (off to start with; reconnects quietly, with no prompt, when
  Selway starts) and Remove from Sidebar; while connected, the share's row has the
  same settings.
- **Network in the sidebar** — a Network row under Locations, as in Finder: open it
  (its triangle, or → on it) and it lists the file servers on your network that share
  over SMB (not AFP, which macOS has deprecated; `afp://` addresses still work in
  Connect to Server), one row each, updated as they come and go, without this Mac.
  It lists at most 200 (the first to arrive, then says how many more there are), and
  a search that fails keeps trying again, within 30 seconds each time. A click (or Return) on a server opens
  Connect to Server, which looks the server up where it is now and shows the address
  it's at: a server you've connected to or saved before connects straight away, and
  the share opens once it's mounted; any other waits for you to check the address
  and click Connect. The arrow keys only move past a server. Its menu has Connect and
  Save Server in Sidebar, which shows the address the same way, to add with "+".
  Selway only looks for servers while the row is open, and it starts closed, so
  macOS's Local Network question comes up the first time you open it, not at launch;
  with access turned off, the row says where to allow it. Names from the network are
  shown with any invisible, control, direction-changing, blank-looking or private-use
  characters as "�". Two names that would look the same because of spacing, joiners
  or variation selectors, or a letter written composed or decomposed, are numbered
  in the order the servers arrived ("NAS", "NAS (2)"); look-alike letters from other
  scripts (a Cyrillic "о") aren't caught. What's connected to is the host the server resolves to (an ASCII
  `.local` name), shown in the sheet, whatever the server calls itself. To VoiceOver
  the Network row says how the search is going ("3 servers", "No servers found"…),
  and each time it's opened the outcome is announced once. Settings → Sidebar →
  Network hides the row.
- **Host names with emoji** — a host may now have the invisible characters some emoji
  are made of (`Alex's 👨‍💻 Mac._smb._tcp.local`), but only right after or between
  emoji: a zero-width joiner between two emoji shown as emoji (👨‍💻, 👨🏽‍💻, ❤️‍🔥),
  the emoji selector (VS16) right after a symbol otherwise shown as text (❤️, ©️, ™️)
  or in a keycap (1️⃣), and the text selector (VS15) right after an emoji that is
  shown as an emoji by default (Emoji_Presentation) and in the Basic Multilingual
  Plane (⌚︎). Anywhere else, including after a letter, a flag letter or a skin tone
  on its own, they're still refused.
- **Links into automount folders** — listing a folder no longer follows a link that
  leads into an automount folder (`/net`, `/Network/Servers`, `/home`, or any autofs
  folder), which used to mount that share just by showing the link. Such a link is
  listed as a link, with its own tags and no preview; opening it (or Quick Look)
  follows it, as in Finder, and when Open asks first about many items, it asks before
  following any. Tag changes skip these links and say how many they skipped.
- **Recent folders on automounted servers**: when a sidebar appears, it no longer
  looks for Recent folders under `/net`, `/Network/Servers` or `/home` (or reached
  through a link into an automount folder), which mounted them again, or waited on
  a server that had gone, every time Selway started. They're listed without being
  checked, with a plain folder icon.
- **Opening a link into an automount folder no longer freezes the window**:
  following it (mounting an NFS share, or waiting for a server that doesn't answer)
  happens in the background, while the status bar says "Opening" and the link's
  name. Going to another folder or view meanwhile, or selecting something else in
  that column in Columns view, cancels the open, and opening it again while it's on
  its way opens it once. When what it links to can't be reached (it's gone, or its
  server isn't answering), Selway says so instead of trying to open it.
- **Back and Forward** — Go → Back (⌘[), Forward (⌘]), Enclosing Folder (⌘↑) and
  Go to Folder… (⇧⌘G), and the toolbar's arrows. Each window keeps its own history;
  as in Finder, selecting folders in the column browser doesn't add steps.
- **Columns view with the keyboard** — as in Finder: ↑ and ↓ move within a column
  (⇧ to extend the selection), → goes into the selected folder and ← back out of it,
  typing a name selects it, Return renames, ⌘↓ or ⌘O opens, Space shows Quick Look
  and Edit → Select All (⌘A) selects the column you're in. Each column keeps its own
  selection, and a click replaces the selection rather than adding to it.
- **Icons view with the keyboard**: as in Finder, ← and → move through the icons in
  order, ↑ and ↓ to the icon above or below (⇧ to extend the selection), and the
  grid scrolls to keep the selected icon in view. With Group By on, that includes
  icons in a group further down that the grid hasn't shown yet, and the icon stops
  below the group's header rather than under it.
- **Return renames, as in Finder**: in List and Icons views and in Columns view's
  search results, Return starts renaming the selected item instead of opening it (in
  its row in List view, with a name prompt in Icons view and the search results, as
  in Columns view). Return again keeps the new name and Escape cancels it; with
  several items selected, Return does nothing. ⌘O or ⌘↓ opens the selection, as a
  double-click does. Every name prompt (Rename, New Folder, New Text File) takes what
  you type as soon as it opens, however it was opened (one opened with Return used
  to need a click in its field first).
- **Search in the toolbar** — Edit → Find… (⌘F) goes to the search field (showing
  the toolbar or putting the field back if needed), and the scopes (This Folder …
  Entire Mac) appear under it while you search. Return or ↓ moves to the results,
  Escape clears the search.
- **Menu bar** — View → as Icons / List / Columns (⌘1–⌘3, as in Finder), Group By,
  Sort By, Show / Hide Path Bar (⌥⌘P), Status Bar (⌘/), Preview (⇧⌘P) and Folder
  Tree; Selway → New Text File, Move to Trash (⌘⌫), Delete Permanently… (⌥⌘⌫), Copy
  Path (⌥⌘C), Show / Hide Hidden Files, Refresh (⌘R) and Open in Terminal or an IDE.
- **Settings in tabs, as in Finder** — General (where new windows open, opening
  folders in a new window, Launch at Login, Text Size, updates, Open folders in
  Selway), Browse (real pickers for the view, sort, order, grouping and folder order,
  plus Reset to Finder Defaults, hidden files, path bar, status bar, preview panel
  and folder tree), Sidebar (which Favorites show, among them Applications, Pictures,
  Music, Movies and iCloud Drive; how many Recent folders; Tags), Tags (hide tags from
  the sidebar), Integrations (terminal app, which IDE buttons show, and the text
  editor's options, which change an open editor at once) and Advanced (deleting, the
  extension warning, where a search starts, the "Open folders in Selway" notes, and
  Reset All Settings…). Every existing setting keeps its meaning, so nothing changes
  until you change it. The Sidebar tab fits the display Settings is on, also after
  it's moved to another display or the screen's resolution changes.
- **Move to Trash is the default delete** — ⌘⌫ moves the selection to the Trash, as
  in Finder, and Edit → Undo puts it back where it was (Redo trashes it again);
  Delete Permanently stays on ⌥⌘⌫ and asks first. Settings → Advanced can swap the
  two shortcuts, ask before trashing, or — after a warning — stop asking before
  deleting permanently. On a volume without a Trash, Selway says so and offers to
  delete permanently instead. The toolbar's Delete item now moves to the Trash; Delete
  Permanently is its own item. ⌘⌫ still deletes text while you type in a field.
  Return and Escape cancel every question about deleting, and VoiceOver announces
  what was trashed or deleted.
- **Choose your terminal app** — Settings → Integrations: Terminal, iTerm, Ghostty,
  Warp or any other app. Open in Terminal uses it, and the menu and toolbar name it;
  Claude Code and the Codex command-line tool open in it with Terminal, iTerm or
  Ghostty, and in Terminal otherwise (Settings says so). If the chosen app isn't
  installed, Selway uses Terminal and Settings says so.
- **Asks before changing a file's extension** in a rename, as Finder does (Settings →
  Advanced; "Don't ask again" in the question turns it off).
- **Drop files into Selway** — drag files from Finder, the Desktop, another app or
  another Selway window onto empty space in the list, icons or a column to put them in
  that folder, or onto a folder (a row, an icon, or a Favorite, Pinned or Recent folder
  in the sidebar) to put them in it; the folder is highlighted while it would take
  them. As in Finder, a drop on the same volume moves and one from another volume
  copies; hold ⌥ to copy or ⌘ to move, and the pointer shows a + while it copies. A
  folder can't be dropped into itself, moving items onto the folder they're already in
  (or onto a symlink to it) does nothing, and text and web links aren't taken. Drops run like Paste: progress
  with Cancel, free names instead of replacing anything, one error message, Edit →
  Undo, and the dropped items selected when they land in the folder shown. Search
  results take drops only on their folders. Dragging near the top or bottom of a list
  scrolls it.
- **Behaves more like Finder** — Copy Path (⌥⌘C, and the Finder extension's Copy Path)
  copies the selected items' paths, one per line, and the folder's only when nothing
  is selected (in Finder, a right-click on a sidebar item or a window's background
  copies that folder's path). New Folder and New Text File create the item in the folder you're
  viewing, beside a selected folder rather than inside it, and no longer take you
  anywhere. Open (a double-click, ⌘O or the context menu) opens every selected
  item: one folder in the window, several in a window each, and every file in its
  app; opening more than 10 at once asks first. The Share picker opens where you
  right-clicked instead of at the window's corner.
- **Sizes and dates follow files as they change**: a file written to while its folder
  is shown (a download, a log that keeps growing) shows its current size and
  modification date in List view, the preview (Columns view's too) and the status
  bar's total for a selection, as in Finder, instead of the ones from when the
  folder was read. Tags another app changes show up the same way in List and Icons
  views. Only the files that changed are read again, at most a few times a second,
  and the selection and scroll position stay where they were. Column rows and
  search results don't follow yet.
- **Remembers the icon size** — the icon view's size slider keeps its setting when you
  switch views or open a window (Reset All Settings puts it back to the default).
- **Go to Folder… leaves the path bar hidden** — with the path bar hidden, ⇧⌘G shows
  it just for typing the path and hides it again afterwards.
- **Tags keep their colours** — toggling a colour in the Tags menu no longer strips
  the colour from a file's other tags: a custom tag you coloured in Finder (or a
  colour tag you renamed, such as Red → Urgent) stays coloured, and a file that
  already had the colour isn't rewritten. The menu's colours carry your names for
  them, and toggling Red also finds a red tag you renamed. A file with only an old
  colour label keeps it as a tag when you add another colour.
- **A tag's items show once** — clicking a tag in the sidebar no longer lists an item
  twice when the folder you're in is reached through a symlink (such as a Downloads
  folder that links to another disk). Items in that folder keep the path you opened.
- **The sidebar lists your tags, as Finder does** — the seven colour tags always
  show, under your names for them, followed by the other tags used on your Mac,
  whatever folder is open. Selway finds those with Spotlight in the background and
  remembers them between launches. Hide in Sidebar and Show Tags work as before.
- **Tag dots in every tag's own colour** — the dots in the list, icon and column
  views, the preview, the sidebar and Settings → Tags use the colour stored with each
  tag, so a renamed colour tag or a custom tag you coloured in Finder no longer shows
  without its dot.
- **Dragged files keep their names** — a file dragged from Selway to the Desktop, a
  Finder window or another app arrives as itself, with its own name, dates and tags,
  instead of as a copy of its contents named after its type (a `.md` file became
  "Markdown Document.md"). Dragging one of several selected icons carries all of
  them, as dragging a selected row in the list does; it used to carry only the icon
  you dragged.
- **Quicker, sharper icon view** — a click selects an icon at once, instead of after
  the double-click interval. Double-clicking an icon that's part of a larger
  selection still opens all of it. Clicking empty space between or below the icons
  clears the selection, as in Finder. Icons are drawn at the size they're shown, so
  they're no longer blurry at the larger sizes on the slider.
- **Icon clicks no longer get lost** — about one click in three or four on an icon
  didn't select it, and the next click on empty space then seemed to need two. If
  the pointer moved even a point while the button was down, the click became a drag
  of the icon. Now, as in Finder, the pointer has to move a few points before a drag
  starts, and a click on empty space counts even if the pointer moves. ⌘-click adds
  an icon to the selection or removes it, and ⇧-click selects the icons from the last
  one clicked through the one you click.
- **A click on a folder icon no longer opens it** — clicking one icon and then,
  quickly, another (or empty space) opened the first one: macOS counted the two
  clicks as a double-click wherever they landed, and the second went to the icon
  clicked first. Clicking empty space and then an icon could also leave the icon
  unselected. Now, as in Finder, a double-click opens an icon only when both clicks
  are on that icon, and a quick click on another icon simply selects it.
- **Column clicks no longer turn into drags**: in Columns view, a click on a row
  whose pointer moved even a point while the button was down (easy on a trackpad)
  started a drag of the row instead of selecting it. Now, as in Finder and the icon
  view, the pointer has to move a few points before a drag starts. Dragging one of
  several selected rows carries all of them; it used to carry only the row you
  dragged. A click on one of several selected rows selects it alone when you let
  go, so a drag from there still carries the whole selection. A double-click opens a
  row only when both clicks land on it.
- **Drag to select icons** — in Icons view, dragging from empty space draws a selection
  rectangle, as in Finder, and selects every icon it touches as you drag. Hold ⌘ or ⇧
  as you start to add the icons it touches to the selection, or take out the ones
  already selected. Drag past the top or bottom of the window to scroll and keep
  selecting. A click on empty space still clears the selection. As in Finder, an icon
  is its picture and its name: the blank space beside a short name or around the
  picture, and the group headers, count as empty space, and the rectangle selects an
  icon when it touches its picture or name. (In earlier test builds the rectangle
  could start only in the narrow gaps between icons, and stopped selecting anything
  after you went to another folder and back, reloaded, or changed the grouping, until
  you switched views.)
- **VoiceOver in Icons view** — each icon is one element named for its item that says
  whether it's selected; VO-Space selects it and its Open action (in VO-⌘-Space's
  actions menu) opens it, as a click and a double-click do.
- **Finder's selection highlight in Icons view** — a selected icon's picture sits on
  a grey rounded box and its name on the accent colour, instead of the whole cell
  being filled with the accent colour.
- **For maintainers** — updates are configured with Sparkle's Info.plist keys
  (`SUFeedURL`, `SUPublicEDKey`, signed feeds required); the release scripts read
  `SELWAY_*` environment variables (`SELWAY_SIGN_IDENTITY`, `SELWAY_NOTARY_PROFILE`,
  `SELWAY_RELEASES_REPO`, …); the update-signing key lives in the Keychain item
  "Selway Update Signing" and reaches Sparkle's `generate_appcast` only through a pipe;
  and `release.sh` produces a signed `appcast.xml` (with delta updates) instead of an
  update manifest. See [docs/RELEASING.md](docs/RELEASING.md).

---

# FinderFlow history

A complete record of what FinderFlow did and how it was built, up to 1.5.2,
before the rename. Dates are relative to the 1.0 release.

---

## 1.5.2 — Faster folder & file open

- **Snappier navigation** — clear the stale listing immediately on folder
  change so double-click doesn't look frozen while the directory loads.
- **Faster directory loads** — browse metadata skips expensive Kind/tag
  lookups on every entry; Kind falls back to a cheap extension label.
- **Faster open path** — List/Icons/Columns use the already-loaded
  `FileItem` (no extra package stat); known text extensions skip the 8KB sniff.
- **Faster date groups** — single-pass bucketing instead of six full filters.
- **Faster Markdown read** — preview reuses the in-memory buffer (one disk read).

---

## 1.5.1 — Install migration fix for newest-first defaults

- **Broader one-time prefs migration** when upgrading from 1.2–1.5: Name A→Z
  (and missing / None / date-modified grouping) becomes **Date Modified,
  newest first, with date groups** — so Applications upgrades no longer keep
  the old flat Name list.
- Settings **Reset to Finder defaults** uses the same factory helper.

---

## 1.5 — Reliability, Markdown toolkit, clearer install

- **Markdown double-click fixed** — file identity is path-stable, so create →
  edit → double-click opens the reader again (no right-click required). Columns
  view opens `.md` / text the same way as List and Icons.
- **Error sheet** — long errors scroll in a compact dialog with **Copy** and
  **Contact Support** (opens GitHub Issues; diagnostics stay on your clipboard).
- **Newest-first defaults** — list + date-modified groups sorted newest first
  (folders on top). One-time migration for installs still on the old name A→Z
  factory combo; customized prefs are untouched.
- **Markdown writing toolkit** — Edit mode format bar with real Undo/Redo
  (AppKit undo stack), bold/italic/strike/code/headings/lists/quote/fences/link/HR.
  Split live preview while editing. Paste-friendly plain-text source editing.
- **Safer preview** — JavaScript disabled in the Markdown WebView; `javascript:` /
  unsafe link schemes blocked.
- **Install clarity** — styled drag-to-Applications DMG, **Install & First Open**
  instructions, **Fix Gatekeeper.command** helper, and a one-time first-run sheet
  explaining the safe Open Anyway step for unsigned builds.

---

## 1.4 — Finder-like defaults + in-app updates

- **Finder-like defaults on first launch** — list view, name sort, **date-modified
  groups** (Today, Yesterday, 7/30/90 days, Earlier), and folders on top. All
  browse preferences are **remembered** across launches; change anything via the
  toolbar and it sticks.
- **Reset to Finder defaults** in Settings restores those factory browse settings.
- **In-app updates** — FinderFlow checks GitHub Releases (about twice a day) and
  shows a banner when a newer version is available. **Update Now** downloads the
  DMG, **verifies SHA-256** against the published checksum, replaces the running
  app, and relaunches — no hunting the repo. **Check for Updates** is also in
  the FinderFlow menu and Settings.

---

## 1.3 — Launch apps + faster folder browsing

- **Double-click `.app` bundles now launch the app** instead of opening the
  package folder (Finder behaviour). Other opaque packages (.pages, .key, …)
  open with their default app too. **Show Package Contents** still works from
  the right-click menu when you need to browse inside.
- **Faster folder navigation** — directory listings use prefetched metadata,
  stale reloads are cancelled when you click through folders quickly, and the
  icon cache is larger so scrolling back feels snappier.

---

## 1.2 — Drag files out + Finder-style grouping

- **Drag files out of FinderFlow** — grab any file or folder from List, Icons, or
  Column view and drop it on the Desktop, another Finder window, an upload dialog,
  a browser, Slack, Mail, etc. Multi-select drags the whole selection (Finder
  behaviour). Cut / Copy / Paste still work as before.
- **Finder-style date groups** — Group by Date Modified / Date Created now uses
  Today, Yesterday, Previous 7 Days, Previous 30 Days, **Previous 90 Days**, and
  Earlier — matching modern Finder.
- **Richer Group By menu** — None, Date Modified, Date Created, Kind, Extension,
  Size, or Name (A–Z). Works in **List, Icons, and Columns**.
- **Folders first / Files first / Mixed** — independent of the sort field, so you
  can keep Name sort while floating folders above (or below) files, or mix them.
- Sort-by picker and ascending/descending are unchanged; grouping sits on top.

---

## 1.1 — Markdown reader in its own window

- **Draggable & resizable Markdown reader** — the Markdown reader/editor now
  opens in a real macOS window (drag by the titlebar, resize, zoom, minimise)
  instead of a fixed modal sheet, matching the built-in code editor. The window
  is reused for subsequent Markdown files and remembers its size/position.
- **"Open in editor" now uses FinderFlow's own editor** — the reader's toolbar
  link button previously launched an external app (Obsidian / TextEdit / etc.);
  it now opens the file in FinderFlow's built-in code editor. Unsaved Markdown
  edits are auto-saved first so the editor shows the latest content.
- **Consistent Markdown handling** — opening a `.md` file *with* FinderFlow
  (from Finder or the command line) now shows the rendered reader, matching what
  double-clicking a `.md` inside the app already did.

---

## 1.0 — First public release

The first shippable build: a fast, native macOS file manager and Finder
alternative, distributed free as a Universal app (Apple Silicon + Intel).

### Core file browsing
- **Three view modes**
  - **List view** — sortable columns (Name, Date Modified, Date Created, Size,
    Kind, Extension), inline rename, optional **Group by Date** sections
    (Today / Yesterday / Previous 7 Days / Previous 30 Days / Earlier).
  - **Icon view** — resizable icon grid (32–128 pt slider).
  - **Column view** — macOS-style miller columns with an inline preview pane,
    optional full ancestor "tree" mode, and resizable column dividers.
- **Sidebar** — system locations (Home, Desktop, Documents, Downloads),
  user-pinned folders, recent folders, and a Tags section.
- **Path bar** — clickable breadcrumbs, double-click to edit the path directly,
  and a one-click **Copy Path** button.
- **Status bar** — item count, selection size, and free disk space.
- **Native Quick Look** (Space bar) and a built-in **preview panel**
  (QLPreviewView, the same engine Finder uses).

### Search
- **Scopes**: This Folder, This Folder & Subfolders (recursive), Desktop,
  Documents, Downloads, Home, and **Entire Mac** (Spotlight-powered).
- Name search and **extension search** (e.g. type `.pdf`).
- Live result count, background execution (never blocks the UI).

### Finder-compatible color tags
- Add/remove the 7 standard macOS colors (Red, Orange, Yellow, Green, Blue,
  Purple, Gray) from any view's right-click **Tags** menu — toggles exactly like
  Finder, multiple colors per file preserved.
- Tags written in macOS's real format so they appear in Finder too.
- Tag dots render in list/icon/column/preview, and tapping a tag in the sidebar
  filters **Mac-wide** via Spotlight (unioned with local color-label matches).

### File operations (with Undo/Redo)
- Copy / Cut / Paste, Duplicate, inline Rename, Make Alias (symlink).
- Move to Trash and **Delete Permanently** (with confirmation).
- **Compress** to `.zip`; **Extract** `.zip / .tar / .gz / .tgz / .bz2 / .xz`
  (uses The Unarchiver if installed, else macOS's built-in tools).
- Share / AirDrop, Show in Finder, Get Info, Copy Path.
- Multi-select aware; partial-failure-safe paste/move with correct undo.

### Built-in code editor (Ace, bundled & offline)
- Double-click a text/code file to open it in FinderFlow's editor.
- Syntax highlighting for dozens of languages; **multiple files as tabs**.
- **Fuzzy command palette** (⌘⇧P), Ace settings menu, Sublime keybindings.
- **Open** (⌘O) / **Close tab** (⌘W).
- **Sublime-style minimap** (theme-aware, click/drag to scroll).
- Runs in a **real, standalone macOS window** — drag, minimize, resize,
  fit — and does **not** block the main browser window.
- Setting to open unknown file types in the editor when they look like text.

### Markdown reader / editor
- Rendered preview (GitHub/Obsidian-style, dark + light) with internal `.md`
  link navigation, plus an **Edit** mode with ⌘S save and auto-save on close.

### Developer integrations (shown only if installed)
- One-click **Open in Terminal**, **VS Code**, **Cursor**, **Claude Code**,
  **Codex** for the current/selected folder. Detection is cached for speed.

### System integration
- **Finder Sync extension** — right-click menu in Finder: New Folder Here,
  Copy Path, Open in Terminal, **Open in FinderFlow**.
- **Set FinderFlow as the default folder handler** (Settings) — routes the
  `open` command, "Open With", and other apps' folder-opens to FinderFlow.
  (Finder itself can't be fully replaced by macOS design — clearly explained
  in-app.)
- `finderflow://` URL scheme and "Open With" handling for folders & text files.
- **Launch at Login** toggle.
- In-app toast notifications for actions (copied, moved, tagged, etc.).

---

## Development history (how 1.0 came together)

1. **Foundation** — list/icon/column views, sidebar, search, file operations,
   path/status bars, Quick Look, Markdown reader, Finder Sync extension, and the
   developer-tool toolbar.
2. **Cursor polish** — fixed the resize/I-beam cursor "sticking" after using the
   sidebar divider, search field, table column dividers, and column handles
   (geometry-based `NSTrackingArea` enter/exit resets + a rewritten resize
   handle).
3. **Tags overhaul** — rewrote tagging to use macOS's real color-tag encoding so
   tags show correctly across all views and are searchable via Spotlight;
   fixed the crash and the "empty results" bug.
4. **Copy-path toast** — wired the path-bar copy button into the toast system.
5. **Default folder handler** — added the Settings option to route folder opens
   to FinderFlow (via LaunchServices), with honest in-app caveats.
6. **Code editor, Phase 1** — extended the text viewer into a full Ace editor;
   double-click to edit.
7. **Code editor, Phase 2** — tabs, command palette (⌘⇧P), settings menu,
   Open/Close shortcuts, unknown-file-type sniffing toggle.
8. **Code editor, Phase 3** — moved the editor into a real, draggable,
   resizable, non-blocking macOS window.
9. **Minimap** — added a theme-aware, Sublime-style minimap.
10. **Senior-QA & security pass** — fixed an **AppleScript-injection**
    vulnerability via crafted filenames (Get Info / Open-in-Terminal), wired up
    the dead **Toggle Hidden Files** (⌘⇧.) command, fixed **unsaved-Markdown
    data loss** on close, and made **paste/move partial failures** undo-safe.
11. **Release engineering** — Universal (Intel + Apple Silicon) build, a
    one-command DMG packager (`release.sh`), README + in-DMG install/permission
    guide, a modern flat app icon, and removal of a deprecated API call.

---

## Known limitations (by design)

- **Not notarized** (free distribution, no paid Apple Developer account) — a
  one-time Gatekeeper "Open Anyway" is required on first launch. See the README.
- **Finder cannot be fully replaced** — the Desktop, drive mounting, Open/Save
  dialogs, and the Dock's Finder icon always remain Finder (a macOS limitation).
- **Requires macOS 14 (Sonoma) or newer.**
