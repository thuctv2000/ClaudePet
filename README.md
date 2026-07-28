# ClaudePet — a desktop pet for Claude Code on macOS

A transparent pet that lives on your screen, stays above other windows, and follows you across Spaces and full-screen apps. It is a second screen for [Claude Code](https://claude.com/claude-code): it shows what Claude is thinking, running or asking — and lets you **approve permissions and reply to Claude right from the pet**, without switching back to the terminal.

## Install

1. Download **ClaudePet-x.y.z.dmg** from [Releases](https://github.com/thuctv2000/ClaudePet/releases)
2. Open the DMG and drag **ClaudePet** into **Applications**
3. Open the app — a short guide appears; press **Connect Claude Code**
4. Run something in Claude Code and watch the pet react 🐾

Signed with a Developer ID and notarized by Apple, so it opens without Gatekeeper warnings. Requires **macOS 14+**. No Claude Code yet? The guide points you at it and lets you re-check.

Updates install themselves — the app checks for new releases and updates in place.

## Features

- **Moods that follow Claude Code** — thinking, working, talking, asking, sleeping, error, and a small celebration when a job finishes.
- **A card per conversation** — run several Claude Code sessions at once and each gets its own card with its real name, its project, what it is running right now, its subagents and background tasks, and a counting timer. Cards show where the conversation lives: Terminal, Claude, or VS Code.
- **Approve permissions on the pet** — when Claude Code would ask, the pet asks instead. Press Allow or Deny and the terminal moves on. If the pet is closed or you ignore it, Claude Code asks in the terminal as usual — nothing gets stuck.
- **Reply from the pet** — type into a card and the message reaches that conversation, even one that has already gone idle (see below).
- **"Claude is waiting for you" cards** — when a turn ends in a question rather than a result, the card says so instead of claiming the job is done.
- **Menu bar panel** — click the paw for connection status, every live conversation, your 5-hour and weekly Claude usage, and the Show pet / Click-through switches. The icon shows a count while work is running and turns orange the moment something is blocked on you.
- **Click-through** — the pet only catches the mouse on its own pixels; clicks anywhere else go to the app behind it.

## Replying from the pet

Type a message on a card and press send. If the conversation is mid-turn, the message rides the hooks and arrives at Claude's next step. If it has already gone idle, ClaudePet delivers it to wherever that session actually lives:

| Where Claude Code runs | How the message gets there |
|---|---|
| Terminal.app, iTerm2 | straight into the right tab, no window comes forward |
| VS Code integrated terminal | through a bridge extension ClaudePet installs into VS Code, Cursor and Windsurf — works even when the window is hidden |
| VS Code panel | delivered without raising the window when it is only covered |
| Claude app | typed into the conversation; a minimised window is opened, used, and put back |

**Settings → About → Message delivery log** shows which route carried each message, or why it did not go out, with a Copy button for bug reports. Message text is never recorded, only its length.

Replying into the Claude app or the VS Code panel needs macOS Accessibility permission; terminal sessions never do. **Settings → Permissions** shows the current status and grants it in one click.

## Pets

- **Pet library** — keep as many pets as you like, each with a name and avatar, and switch from the pet's own right-click menu. A Dino ships with the app.
- **Browse OpenPets** — Settings → Pet → *Browse OpenPets…* installs animated pets from [openpets.dev](https://openpets.dev) with one click. Only pets drawn by OpenPets themselves are listed, and artwork is downloaded when you pick a pet rather than bundled into the app.
- **Bring your own** — drop a GIF or a few images onto the Pet tab. A GIF animates as-is, several images become the frames, and a single image gets a gentle idle bob. Fill in the other moods whenever you like.

Each mood is a folder of PNG frames under `~/.petmacos/pets/<pet>/<mood>/`, played like a flipbook, with an optional `clip.json` (`{"fps": 12, "loop": true}`) per folder. Moods: `idle`, `click`, `thinking`, `working`, `talking`, `asking`, `sleep`, `error`, `happy`. A mood with no frames falls back to `idle`.

> Character art you don't own is fine for personal use — think twice before publishing a pet made from it.

## How it works

The app runs an HTTP server bound to `127.0.0.1` only (the OS picks the port each launch) and writes the port and a token to `~/.petmacos/config.json`. **Connect Claude Code**:

- writes `~/.petmacos/pet-hook.sh`
- adds its hook entries to `~/.claude/settings.json`, leaving your other settings untouched (a backup is written first)

From then on every Claude Code session calls `pet-hook.sh`, which posts events to the pet. **Disconnect Claude Code** removes exactly those entries again, and **Settings → About → Clean uninstall** removes them and optionally your pet data.

The pet holds no permission policy of its own. It shows a dialog exactly when Claude Code would have asked you — to be asked more or less often, change the permission mode inside Claude Code and the pet follows.

## When something is wrong

**Settings → General** shows whether the hooks are installed, which port the server is on, and offers Connect / Check again / the guide. **Settings → About → Message delivery log** covers messages sent from a card. The full log is at `~/.petmacos/events.log`.

## Development

```sh
# Run
swift run

# Or open in Xcode (the repo uses XcodeGen)
xcodegen generate
open PetMacOS.xcodeproj   # scheme PetMacOS, ⌘R
```

It is a menu-bar app (`LSUIElement`) — look for the paw in the menu bar, there is no Dock icon.

```sh
# End-to-end tests (need the app running)
tests/e2e_pet_state.sh

# Distribution build: Developer ID signing + DMG (+ notarization with --notarize)
scripts/build-release.sh --notarize
```

Building from source needs no Apple Developer account (Xcode signs locally). To publish your own fork, override the signing identity:

```sh
PET_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
PET_TEAM_ID=TEAMID PET_NOTARY_PROFILE=YourProfile \
scripts/build-release.sh --notarize
```

## License

MIT — see [LICENSE](LICENSE).
