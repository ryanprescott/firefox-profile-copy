# Copy-FirefoxProfile

A PowerShell script for Windows that copies your data (bookmarks, history,
passwords, cookies, settings, open tabs and extensions) from one Firefox
profile folder into another.

I wrote it to move **legacy profiles** (made with `about:profiles` / the old
profile manager) into Firefox's **new profile switcher**. The switcher only
shows profiles it created itself and can't import old ones. You can also use
it to copy between any two profiles.

## Usage

1. Optional: in the profile switcher, create the profile you want to copy into.
2. Close Firefox completely.
3. Run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\Copy-FirefoxProfile.ps1
   ```

4. Pick the source profile, then the destination. Read the plan, then type
   `YES` to go ahead.

```
Copy FROM which profile?
  1) default-release          legacy  last used 2026-10-25 09:12  abcd1234.default-release
  2) Profile 1                new     last used 2026-10-24 18:40  Xy7kQ2mN.Profile 1
  3) Work                     legacy  last used 2026-10-20 11:03  efgh5678.Work
Number (Q to quit):
```

If Firefox isn't in the default location (for example ESR or a portable
install), point the script at its profiles folder:

```powershell
.\Copy-FirefoxProfile.ps1 -ProfilesRoot 'D:\PortableFirefox\Data\profile\Profiles'
```

## What gets copied

| Item | Contents |
| --- | --- |
| `places.sqlite`, `favicons.sqlite` | Bookmarks, history |
| `logins.json` + `key4.db` | Saved passwords (only work together) |
| `cert9.db` | Certificate exceptions |
| `cookies.sqlite` | Site sign-ins |
| `formhistory.sqlite` | Form autofill |
| `permissions.sqlite`, `content-prefs.sqlite` | Per-site permissions and zoom |
| `handlers.json` | What to do with each file type |
| `sessionstore.jsonlz4`, `sessionstore-backups` | Open tabs and windows |
| `prefs.js` | Settings (the destination keeps its own profile-switcher settings) |
| `extensions`, `extensions.json`, `extension-*.json`, `storage` | Extensions and their data |

Each database's `-wal`/`-shm` side files are copied along with it, and stale
ones in the destination are removed. The script also deletes
`addonStartup.json.lz4`, so Firefox rescans extensions on next launch.

To change what gets copied, edit the `$Items` list at the top of the script.

## Safety

- **Nothing is deleted.** Everything the script replaces in the destination is
  moved to `%APPDATA%\Mozilla\Firefox\profile-copy-backups\<folder>-<timestamp>`.
  To undo, close Firefox, delete the copied items, and move the backup's
  contents back.
- You must type `YES` exactly. Anything else cancels without changing anything.
- It won't copy while Firefox is running.

## How it works

### Telling legacy and new profiles apart

Legacy profiles are listed in `%APPDATA%\Mozilla\Firefox\profiles.ini`.
Profiles made with the new switcher aren't; Firefox tracks them in a database
under `%APPDATA%\Mozilla\Firefox\Profile Groups\`. The script lists every
profile folder that has a `prefs.js`, labels those found in `profiles.ini` as
`legacy`, and labels the rest `new`. These labels only appear in the picker:
the copy itself works on folder paths.

### Keeping the destination in its profile group

Copying the source's `prefs.js` as-is would break the destination. Three
settings in `prefs.js` tie a profile to the new profile system, so the script
saves the destination's own values and writes them back after the copy:

| Setting | Role |
| --- | --- |
| `toolkit.profiles.storeID` | Which group database (`Profile Groups\<storeID>.sqlite`) the profile belongs to |
| `browser.profiles.created` | Without it, the profile service stops before opening the group database |
| `browser.profiles.enabled` | Turns on the profile menu |

What the Firefox source shows
([`mozilla-firefox/firefox`](https://github.com/mozilla-firefox/firefox) at
`efd2d1e6f775`):

- `toolkit/profile/ProfilesDatastoreService.sys.mjs`: after startup,
  `#init()` reads the store ID from the `toolkit.profiles.storeID` setting, and
  `getSharedProfilesStorePath(storeID)` maps it to
  `Profile Groups/<storeID>.sqlite`.
- `browser/components/profiles/SelectableProfileService.sys.mjs`:
  `addSelectableProfilePrefs()` writes exactly these three settings into every
  new profile's `prefs.js`. `toolkit.profiles.storeID` is also listed in
  `ignoredSharedPrefs`, meaning it is never shared between profiles.
- In the same file, `#initialize()` returns early unless
  `browser.profiles.created` is true. It then looks up the current profile's
  folder in the group database. If the profile isn't there, Firefox records
  `currentMissing` and adds the profile to whatever group its `storeID` points
  at. A profile carrying the source's `storeID` would therefore silently move
  into the **source's** group.

All `toolkit.profiles.*` and `browser.profiles.*` settings are kept, so any
added in future Firefox versions are covered too.

## Limitations

- Windows only. On Linux or macOS, the same steps apply in the matching
  profile folders, but this script doesn't handle them.
- Names for `new` profiles come from the folder name. If you renamed a profile
  in the switcher, the picker shows its original name.
- A legacy profile that you used to turn on the switcher still shows as
  `legacy`.
- Tested with Firefox 158.0.1 on Windows 11. Firefox's profile system is still
  changing, so check the backup folder is there before you delete anything.

## License

[MIT](LICENSE)
