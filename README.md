# Quill-IDE for Godot

<img width="1280" height="720" alt="s1" src="https://github.com/user-attachments/assets/03a0adfb-3f50-4186-a89b-b4eaef1e9f30" />

## Tested on:
	Godot 4.7.1 Stable
	Godot 4.8 (new script editor layout supported)

A modern, feature-rich script editor for the **Godot Engine (4.4+)**.  
Quill IDE is a heavily modified fork of the original **Script-IDE plugin** by **Marius Hanl**, rebuilt for style, usability, and modularity.  

Think of it as **Godot's Script Editor — but sleeker and way more customizable.**

**IMPORTANT**: This was made with PassiveStar's [Minimal Theme](https://github.com/passivestar/godot-minimal-theme) in mind, this might not look good on Godot's Default theme. But with a bit of tinkering you can make it look good with default theme.

**MY PREFERRED THEME** (This might look different from the Cover Image):

>> Note: As of Godot 4.6 You don't need to add Minimal theme as this was integerated inside godot itself.
> Editor Settings > Interface > Theme (Advanced Settings Toggle turned on)"
- Base Color: `#1d222a`
- Accent Color: `#fd9700`
- Icon Saturation: `1.5`
- Corner Radius: `5`
- Base Spacing: `3`
- Custom Theme: [Minimal Theme](https://github.com/passivestar/godot-minimal-theme)


> Editor Settings > Text Editor > Theme"
- Color Theme: `One Dark` from [this Repository](https://github.com/godotengine/godot-syntax-themes)
- Background Color: `#181a20`
---

## 🚀 Features

### Tabs
- 🖊️ **Enhanced Script Tabs**  
  Tabs Layout at the top of the IDE instead of on Side, You can always turn it off and bring the old one back.  
- 📌 **Pinned tabs**  
  Pin a tab (`Alt+P` or the **Tabs ▾** menu) and auto-close, "close others", middle-click and the close button all leave it alone. Click the pin on the tab to unpin.
- 🗃️ **Tab groups**  
  The **Tabs ▾** menu (arrow at the right end of the tab bar) can show just one folder's scripts, or a named group you build yourself.
- 💾 **Sessions**  
  Save the set of open scripts under a name and load it back later. Optionally keep one session per git branch, switched automatically when you check out another branch.
- ↔️ **Better right-click menu on tabs**  
  "Close Tabs to the Left / Right" and "Move Tab Left / Right", depending on where the tab sits.
- 🪟 **Split view**  
  `Alt+S` opens a second pane next to the editor. Same script: a live read-only mirror, so you can look at two parts of one file. Another script: fully editable with its own Save.

### Navigation
- 🗂️ **Script Outline Panel**  
  Quickly navigate through functions, signals, properties, and constants — with customizable position (left/right). It highlights the member your caret is in, and lists which nodes in the open scene are connected to each signal.
- 🧭 **Breadcrumbs**  
  A bar under the code showing `file › class › func` for the caret. Click a part to jump to one of its siblings.
- ⏪ **Back / Forward history**  
  `Alt+←` / `Alt+→` or your mouse's back/forward buttons jump between places you've been, across scripts.
- 🔎 **Quick open, upgraded**  
  Recently opened files come first. Start the search with `@` to search functions, signals and classes across every script instead of file names.
- 🔗 **Find Usages**  
  `Shift+F12` (or right-click a member in the outline) lists every use across the project, including signal connections saved in `.tscn` files, which Godot's own search doesn't count.
- 🔖 **Bookmark Functions/Variables**
  - Ability to bookmark any function or variable from any script
  - Quick access and navigate to that specific function in the project
  - Toggle with `Alt+B`, cycle with `Alt+N` / `Alt+Shift+N`, rename and reorder from the right-click menu
- ✅ **TODO panel**  
  Every `TODO`, `FIXME`, `BUG`, `HACK`, `XXX` and `NOTE` comment in the project, under the bookmarks. Click to jump.

### Editing
- 🛠️ **Code generators** (right-click a member in the outline)  
  Generate a getter/setter, add an `@export_group` above an export, or add a doc comment stub with `[param]` lines.
- 🔀 **Sort Script Members**  
  Reorders the whole script to match your outline order (callbacks in lifecycle order). One Ctrl+Z undoes it, and it refuses rather than guesses when something can't be moved safely.
- ✨ **Smooth caret**  
  VS Code style caret: glide, trail or ease-out motion, fading blink, and smooth scrolling when the caret jumps the view. Stays glued to the text while you type.
- 📏 **Indent guides**  
  Colour by keyword or by nesting depth, and the block your caret is in is drawn thicker. Godot's tab markers are hidden while guides are on (optional).

### General
- 🎨 **Custom Styling**  
  Modern tab design with rounded corners, hover/focus effects, and editor-theme-aware colors.  
- ⚡ **Better Workflow Integration**  
  - Auto-syncs with FileSystem dock.  
  - Restores state when disabling the plugin.  
  - Clean separation into modular scripts.  
  - Disabling and re-enabling the plugin (or a script reload) never leaves duplicate or missing panels.
  - If a Godot update moves part of the script editor, only the affected feature turns off and you get one notice, instead of a wall of errors.

---

## ⌨️ Shortcuts

All of these can be changed in **Editor Settings → Quill**.

| Action | Default |
|---|---|
| Quick open | Double-tap `Shift` |
| Quick open: scenes / scripts / resources | `Ctrl+Shift+F` / `Ctrl+Shift+O` / `Ctrl+Shift+R` |
| Back / Forward | `Alt+←` / `Alt+→` (and mouse back/forward) |
| Toggle bookmark on the member under the caret | `Alt+B` |
| Next / previous bookmark | `Alt+N` / `Alt+Shift+N` |
| Find usages of the word under the caret | `Shift+F12` |
| Pin / unpin current tab | `Alt+P` |
| Toggle split view | `Alt+S` |

---

## 🛠️ Installation

1. Clone or download this repo into your Godot project under: res://addons/quill-ide/
2. In Godot, open **Project → Project Settings → Plugins**.  
3. Enable **Quill-IDE**.  

<img width="205" height="64" alt="image" src="https://github.com/user-attachments/assets/2db1e2fe-676c-414b-bd64-0334e1195cb2" />

<img width="1186" height="135" alt="image" src="https://github.com/user-attachments/assets/2f5ac6a0-0843-46c7-9dcc-cbfccde113c4" />

That’s it — your script editor now levels up! ⚡

---

## 🆕 What's new

### Added
- Godot 4.8 support: the new outline panel (`DocumentOutline`) is detected alongside the old layout.
- Breadcrumb bar, outline follows the caret.
- Back/forward navigation history and recently opened files in quick open.
- Bookmark shortcuts (toggle / next / previous), bookmark rename and reorder.
- Project-wide symbol search in quick open (`@`).
- Find Usages popup, including `.tscn` signal connections.
- Signal connections from the open scene shown under each signal in the outline.
- Outline right-click: getter/setter, `@export_group`, doc comment generators, and Sort Script Members.
- TODO / FIXME panel.
- Indent guides coloured by depth, thicker guide for the caret's block, optional tab markers alongside the guides.
- Smooth caret (glide / trail / ease out, fading blink, smooth scrolling) with an on/off switch.
- Pinned tabs, tab groups (by folder or named), saved sessions, sessions per git branch.
- Split view.
- "Close Tabs to the Left / Right" and "Move Tab Left / Right" in the tab right-click menu.
- One startup notice listing anything that couldn't hook into the editor, instead of error spam.

### Updated
- Outline on the right keeps a fixed width instead of stretching across the editor.
- Tab names are read from the script each tab really edits (no more names swapping after closing a tab).
- Tab and outline refresh, and stale-bookmark cleanup, now happen on save. The cleanup compares against the script's source, so hidden private members or a parse error can't delete valid bookmarks.
- Bookmark changes are always saved to disk.
- Closing several tabs at once never closes an unsaved one (avoids Godot's "save changes?" prompt applying to the wrong script).
- Default outline order: Classes, Properties, Exported Properties, Constants, Signals, Engine Callbacks, Functions (only for new installs; your saved order is kept).
- Rainbow indent guides setting is now a mode (Off / By keyword / By depth); an existing "on" carries over as "By keyword".
- Comments throughout the code.

### Removed
- `Quill/IndentGuidelines/rainbow/enabled` (replaced by `rainbow/mode`, migrated automatically).
- Godot's "Close Tabs Below" and "Move Document Up / Down" wording in the tab menu (replaced by left/right versions).
- The per-node error messages when an editor part couldn't be found (replaced by a single notice).

---

## 🚀 Known Bugs
1. Changing theme color bugs the Tab themeing so after changing, Disable and then Re-enable the plugin.

[Please let me know if you find any other bug]

### Limitations (by design)
- **Split view** is a plain code editor: syntax highlighting, but no autocomplete or error checking. Godot doesn't let plugins create a second real script editor.
- **Tab right-click menu** rewording only recognises the English editor labels; in other languages the menu stays as Godot builds it.
- **Smooth caret** steps aside for the block caret style and overtype (Insert) mode and shows Godot's own caret there.
- **Signal connections in the outline** only show connections made in the editor; ones made with `.connect()` in code exist only while the game runs (Find Usages covers those).
- **Sort Script Members** won't sort a script that uses `#region` at the top level, or where moving a variable would change what it's initialised to.

## ⚙️ Settings

Quill IDE integrates with **Editor Settings** so you can tweak behavior:
All changes apply instantly without restarting the editor.

<img width="885" height="692" alt="image" src="https://github.com/user-attachments/assets/9054506e-280b-481c-b071-b452e22261b2" />

| Section | What's there |
|---|---|
| `Quill/General` | Script list, tabs, minimalism, breadcrumbs, `scan_addons` (include `res://addons` in the TODO scan) |
| `Quill/Outline` | Position, order, categories, `follow_cursor`, `show_todos` |
| `Quill/Navigation` | Back/forward, bookmarks, find usages, pin tab, split view shortcuts |
| `Quill/QuickOpen` | Quick open shortcuts |
| `Quill/IndentGuidelines` | Guides, rainbow mode, active width, `general/show_tab_markers`, fold marks |
| `Quill/SmoothCaret` | `enabled`, mode, motion, durations, speed, blink style, smooth scroll |
| `Quill/Sessions` | `per_branch`, `close_others_on_load` |

Pins, groups, sessions and recent files are stored per project on your machine (editor project metadata), never in the repository.

---

## 🤝 Contributing

Pull requests and issue reports are welcome!  
If you’d like to propose features or improvements, open an Issue.  

---

## 📜 License

This project is licensed under the MIT License.
