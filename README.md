# edge-cdp-remote-debugging-default-user-data

A Windows PowerShell tool that enables **Edge DevTools remote debugging (CDP)** on the **default user data directory**, working around the Chromium 136+ security restriction that blocks remote debugging on the default profile.

## The Problem

Starting with Chromium 136 (Chrome and Edge), the browser refuses to open a remote debugging port when using the default user data directory. The error is:

```text
DevTools remote debugging requires a non-default data directory. Specify this using --user-data-dir.
```

This means you cannot use CDP-based tools (AI agents, automation frameworks, debuggers) on your everyday browser profile — the one that already has your logins, bookmarks, extensions, and history.

## How This Tool Solves It

Instead of fighting the restriction, the tool changes what Edge considers its "official" data directory:

1. Renames `User Data` → `My User Data` (renaming preserves file timestamps).
2. Copies `My User Data` back to `User Data` as a backup snapshot.
3. Sets the registry policy `HKLM\SOFTWARE\Policies\Microsoft\Edge\UserDataDir` to point at `My User Data`.

Edge now treats `My User Data` as its legitimate data directory. Because it is no longer the default path, the Chromium 136 restriction does not apply, and remote debugging works normally.

All your logins, bookmarks, passwords, extensions, history, and cached site data are preserved.

## Requirements

- Windows 10 or Windows 11
- Microsoft Edge installed at the default location
- Administrator privileges (the script writes to `HKLM`)

## Usage

### Configure

1. Download the latest release from the [Releases page](../../releases).
2. Extract the zip.
3. Double-click the `.bat` file.
4. Choose option `1` (Configure).
5. Enter a port, or press Enter to use the default `9222`.
6. When the UAC prompt appears, click **Yes**.

After configuration, two shortcuts named `Edge remote debugging` are created (Desktop and Start Menu).

### Daily Use

| Scenario | Action |
|---|---|
| Normal browsing | Launch Edge any way you like. |
| AI agent takeover | Fully exit Edge (including tray), then double-click `Edge remote debugging`. |
| Switch back | Fully exit Edge, then launch Edge normally. |

**Why fully exit?** Edge is a single-instance application. If an instance is already running, new command-line flags are forwarded to the existing process and the debugging port will not open.

### Rollback

Run the same `.bat`, choose option `2` (Rollback). This:

1. Closes Edge and related processes.
2. Lists extensions that disappeared since configuration (informational only).
3. Deletes the `User Data` backup.
4. Renames `My User Data` back to `User Data`.
5. Removes the registry policy and the two shortcuts.

## Important Limitations

- **This tool cannot restore extensions deleted by Edge.** Whether an extension is recognized depends on Edge's internal records (`Secure Preferences`), not the files on disk. Copying extension folders back is not enough.
- **This is not an official Microsoft tool.** It is a community workaround. Use at your own risk.
- The rollback process will delete the `User Data` backup snapshot. If you want to keep it, copy it elsewhere before rolling back.

## How It Works (Technical Details)

Chromium 136 introduced a security check: remote debugging is disabled when the data directory matches the default path. The check uses path normalization, so trailing backslashes, `..` variants, and directory junctions do not bypass it.

The registry policy `UserDataDir` changes Edge's notion of the default directory itself. Once set, Edge uses the specified path unconditionally, ignoring any `--user-data-dir` command-line flag. Because the new path is not the built-in default, the security check passes.

This approach does **not** use directory junctions. Junctions are detected as "external/redirected directories" and trigger a cleanup routine that deletes extensions. The registry policy avoids this entirely.

## License

MIT
