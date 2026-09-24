# Obby

A small native macOS notes app: folders, Markdown, and AI through local Ollama or an optional cloud provider. No dependencies, database, accounts, or backend. Obby is currently for macOS only and requires macOS 13 or later.

## Download

**[Download Obby for Mac (Obby.dmg)](../../releases/latest/download/Obby.dmg)**

Requires macOS 13 or later. The current release is for Apple Silicon Macs.

1. Open `Obby.dmg` and drag **Obby** into **Applications**.
2. Open Obby. The first release is not yet notarized by Apple, so macOS may ask you to confirm the first launch in **System Settings → Privacy & Security**. Future notarized releases will show the verified developer information instead.
3. Follow the short setup: choose where your notes live, then set up AI or skip it.

All releases are on the [Releases page](../../releases).

## Website

The static download page lives in [`website/`](website/). It is kept separate from the macOS app source and links to the latest GitHub release asset.

## Build from source

Requires macOS 13 or later and Apple's Command Line Tools (`xcode-select --install`). Obby currently supports macOS only. No other dependencies.

```sh
git clone <this repository>
cd Obby
./scripts/build.sh
open build/Obby.app
```

The build script checks that the selected Swift compiler and macOS SDK work together, and will use another compatible installed SDK when available. If no compatible SDK is found, update Xcode or the Command Line Tools. You can also set a matching SDK explicitly: `OBBY_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk ./scripts/build.sh`.

The app can then be moved to Applications. It is ad-hoc signed locally, so macOS may ask you to confirm the first launch (right-click Obby.app, then Open).

First-run setup asks where your notes live: **Create New Obby Folder** (recommended `~/Documents/Obby Main Notes`; Obby creates `<location>/Obby Main Notes`, or uses the chosen folder if it already has that name) or **Use Existing Notes Folder** (the chosen folder is used as the notes root exactly as it is: nothing nested, moved or renamed, and existing notes and subfolders load immediately). AI setup is optional and can be skipped. To run setup again, quit Obby and run `defaults delete local.obby.notes`.

Future launches remember the notes folder and last note. All navigation, search, and AI file operations are restricted to the notes folder. If the folder disappears, choose it again. Notes remain normal UTF-8 `.md` files. Light/dark appearance follows macOS. Nothing personal is stored in this repository: notes live in the folder you choose, settings in macOS user defaults, and API keys in the Keychain.

## Use

On first launch a short setup asks where to keep notes (an existing folder or a new one), then optionally an AI provider and its details (Ollama models are listed from the running app; cloud keys go to the Keychain). AI can be skipped: Obby works as a plain notes app, and the AI panel shows "Set up AI in Settings."

Pasting always inserts plain text exactly as copied: Markdown, code fences, JSON, indentation, tabs and Unicode are kept; rich text from web pages or documents is reduced to its plain text (only line endings are normalised to `\n`). Obby does not auto-correct, smart-quote, auto-link or re-space what you type or paste, and the formatting buttons change only the selected text. Notes are saved as UTF-8.

- Selecting a folder closes the open note (after saving it) and shows that folder with **New Note**; nothing is created until you click it. Selecting a note opens it.
- Click the note title above the editor to rename it inline: Enter or clicking away renames the actual `.md` file, Escape cancels. Empty titles, `/`, `:`, and leading dots are rejected, and an existing note is never overwritten (a warning is shown instead).
- Select a folder, then use **+** or **Cmd+N** to create a note there. **Cmd+Shift+N** creates a folder. **Root Folder** chooses the vault root as the creation destination.
- Drag a note or folder onto another folder to move it, or onto **Root Folder** to move it to the Obby root. Valid folders highlight while hovering. The sidebar uses single selection. Drops save pending edits, preserve filenames, and never overwrite an existing item; a conflict shows an alert. Folders cannot move into themselves or their descendants.
- Right-click a note or folder to rename, move, or move it to Trash. Move accepts a relative destination folder; empty means the root. Deletion asks for confirmation.
- Select text and use **Bold**, **Italic**, **Underline**, or the **Text** menu. Select lines for bullets, numbers, or checklists. The completed-checkbox button marks selected lines complete. Markdown source stays visible; this is not a rendered rich-text editor.
- Changes save silently after 600 ms of inactivity; switching notes or closing the window saves immediately; **Cmd+S** saves immediately. **Cmd+F** focuses search, which includes names and note contents.
- Drag the panel dividers to resize. The editor is the largest panel by default.
- External changes are detected approximately every 1.5 seconds. Conflicting external edits produce a save error with options to overwrite or reload. Unsaved edits remain only in memory until resolved. No autosave caches, snapshots, duplicate notes, or backups are maintained; atomic writes leave no temporary file after success.

## Ollama

Run your installed Ollama app. Obby discovers models using `/api/tags`, and chats with `/api/chat`. Choose any installed compatible model from the dropdown. A tool-capable model is required for filesystem actions.

Open **Obby → Settings** (Cmd+,) for the model, local URL, unload-on-switch toggle, keep-alive, and Clear AI Chat. Models unload on switching by default via the Ollama API; the newly selected model is never preloaded. Keep-alive defaults to 5 minutes, with immediate unload, 1 minute, and keep-loaded alternatives. Keep-alive applies to subsequent chat requests. A small status reflects `/api/ps`, updated only on events (one check at launch, after each AI request, after switching or unloading a model, and on request failure); Obby never polls Ollama in the background. **Unload model when Obby closes** (on by default) sends one `keep_alive: 0` request for the active Ollama model when Obby quits, if that model was used during the session; it waits at most about 3 seconds, and the Ollama app and server keep running. While Obby is open, how long an idle model stays loaded is Ollama's keep-alive setting (choose **Keep loaded** to keep it in memory until you quit Obby). Clear AI Chat cancels the conversation and clears memory without changing notes. Default URL: `http://localhost:11434`. Obby can start Ollama automatically when needed (see Starting Ollama below). No API key is needed. Model downloads and installation are managed in Ollama, not Obby.

The AI receives the current note path and selected folder, and retrieves relevant note contents through tools. It does not automatically receive all notes. Chats are kept as compact memory (see Chat memory below); New chat starts fresh and cancels active work. Context is budgeted by Obby for every request: **Settings → Context Window** (4K, 8K, 16K default, 32K), capped at the model's reported limit (Ollama `/api/show`, Gemini model info), with about a quarter of the window (1K–4K tokens) always left free for the answer. Ollama receives the window as `num_ctx`. Within the rest, Obby keeps, in order: instructions and tools, the current request, the current note (chat-only models), recent chat verbatim (up to 20 exchanges), the current turn's tool results, and a short Obby-written summary of older chat. Old tool results are dropped first and old navigation results are retired. A note too long for the budget is not cut off: Obby sends only the relevant sections, or has the model read it section by section and answers from those notes ("This note is too large to send at once…"). A small "Context: 6.2K / 16K" line shows the last request's estimated size. Apart from the compact chat memory files (which can be turned off), Obby creates no chat databases, full transcripts, prompt/response logs, or disk caches. Its ephemeral network session explicitly disables URL caching, cookie storage, and credential storage. Requests may take time while a model loads; Stop cancels further work, but does not roll back completed file actions.

All AI tools use validated relative paths under the selected folder. Absolute paths, `..`, symbolic-link components, and non-Markdown reads/writes are rejected. The root cannot be deleted or moved. AI deletion opens a native confirmation dialog. HTTP redirects are refused and only loopback Ollama addresses are accepted (cloud providers are described below). No model-generated shell commands are executed.

This is an app-enforced notes sandbox, not an App Store sandbox entitlement. Ordinary hidden files and symlinks are omitted from the sidebar. Deleting a folder moves its entire contents to Trash.

## Build and verify

```sh
./scripts/build.sh
./scripts/test.sh
open build/Obby.app
```

The scripts use Swift directly and require Apple's Command Line Tools. The scripts use the active macOS SDK (`xcrun --sdk macosx --show-sdk-path`). Set `OBBY_SDK` to an SDK path to override, for example if the default SDK does not match your Swift compiler. `Package.swift` is also included for environments with a functioning Swift Package Manager.

Automated checks cover selection formatting (including Unicode and line boundaries), filesystem operations, search, autosave, conflict handling, AI tool execution, path traversal, absolute paths, root protection, symlinks, and local-only networking configuration. The test harness creates temporary fixtures.

API references: https://docs.ollama.com/api/chat and https://docs.ollama.com/api/tags

## Application icon

`Resources/Assets.xcassets/AppIcon.appiconset` contains all ten macOS icon representations. `Obby.xcodeproj` connects this catalog to the Obby application target with `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. Open it in a full Xcode installation to build with the asset compiler. The direct build bundles the equivalent `Resources/AppIcon.icns`. Both use the same cropped original artwork, with transparency outside the original tile and no added border or shadow.

`python3 scripts/build_icon.py` regenerates these assets from the unchanged `Resources/Obby.png` supplied image (requires Pillow). The direct build does not need Xcode.

## Other AI providers

Choose the provider in **Settings → AI Provider**: Ollama (default, local), OpenAI-compatible (base URL, optional API key, model — works with OpenAI and many hosted or local servers), Anthropic, or Google Gemini. Switching takes effect immediately; Ollama-only controls (keep-alive, unload, loaded status) appear only for Ollama, and leaving Ollama honours the unload setting. The AI panel shows `Local · Ollama` or `Cloud · <provider>`.

All providers sit behind a small `AIProvider` protocol (`Sources/Obby/AIProvider.swift`) using URLSession directly. Providers only choose tool calls; Obby's own Swift tools perform every file operation with the same sandbox as before. Models without native tool calling (Ollama models whose `/api/show` capabilities lack `tools`, Gemma models on Gemini, or an OpenAI-compatible model with **Model supports tool calling** off) are offered no tools and are shown as “Chat only”: Obby includes the currently open note (with unsaved edits, up to 30,000 characters) in each request, so these models can summarize, explain, rewrite, analyze, and answer questions about that note, but they cannot search the vault, read other notes, or create, edit, move, rename, or delete files. Responses are request/response, not streamed.

API keys are stored only in the macOS Keychain (`local.obby.notes.ai-provider`), never in notes, files, or UserDefaults; keys are sent in request headers, never URLs. Cloud requests use https (plain http only for a localhost server) and refuse redirects. With a cloud provider, your messages, recent chat, and only the notes or search results the tools read for that request leave your Mac; the vault is never sent wholesale. After rebuilding the ad-hoc-signed app, macOS may ask once to allow Obby to read its saved key.

## AI action display

The AI panel renders the model's Markdown replies natively (bold, italic, headings, bullet and numbered lists, inline code, code blocks, quotes, line breaks, pipe tables); images are shown only from inside the Obby folder (`![alt](folder/image.png)`, through the same path sandbox as notes, click to open), remote images are never fetched, and only http/https links are clickable (they open in your default browser). Model prose is shown as written; paths are shortened only in Obby's own action summaries. Each reply has a small copy button (copies the reply's original Markdown only, no action lines or tool data), and code blocks have their own. The stored reply stays raw Markdown and is never sent back to the model for formatting. Tool activity appears as a compact, subdued checklist (✓ Read Enzymes.md) of short action summaries generated by Obby, not by the model. The small code-symbol toggle **Show raw actions** is off by default and remembers its preference. Turn it on to inspect structured tool calls and exact response content. Summaries never enter model context. Raw details stay in memory only, with a 128 KB total budget; older details are discarded whole rather than silently truncated. New Chat and app close clear them with the rest of the conversation. No transcript files or logs are created.

AI navigation is search-first: content/name searches return root-relative paths at any folder depth, optionally scoped to a folder. Directory listing only returns direct children. Navigation results are paged (50 entries, approximately 6 KB), unchanged listings are reused within the current request, and all navigation payloads except the latest two are retired from active context. No vault tree is automatically sent to Ollama. Search scans files locally as needed without building a tree for the model. A full recursive inventory is reserved for explicit user requests.

## Starting Ollama

Normal use never needs Terminal. When Ollama is the provider and an AI request is made (or you press Refresh, Check Again, or Apply), Obby checks the local API once. If it isn't answering and **Start Ollama automatically when needed** (Settings, on by default) is on, Obby opens the installed `Ollama.app` in the background with `NSWorkspace` (no shell commands) and waits up to 20 seconds for the API before continuing the request. Starting the server loads no model; the model loads only for a real request. Launching Obby itself never starts Ollama. With the setting off, Obby shows “Ollama isn’t running. Open Ollama to use local AI.”; if Ollama isn't installed, it shows “Ollama isn’t installed.” with a Get Ollama link. Quitting Obby still only unloads the model (when that setting is on) and never quits Ollama. OpenAI-compatible servers are never started automatically; if one can't be reached, Obby says the server is unavailable.

## Attachments

Drag files into a note, paste them, or use the toolbar buttons (**Insert image**, **Attach document**; both are disabled with no note open). Every attachment goes through one import path: the file is copied (never linked or referenced in place) into `Attachments/` next to the note, and a normal Markdown link is inserted at the cursor or drop point: `![name](Attachments/name.png)` for images, `[Biology Paper](Attachments/Biology Paper.pdf)` for documents. Name collisions get `-2`, `-3`, …; nothing is ever overwritten. Paths stay inside the notes folder under the same rules as notes (no absolute paths, `..`, or symlinks). Folders and packages (such as `.pages`) are not attached. Document names keep their spaces; characters that would break a Markdown link are removed.

In the editor, link titles are shown in the link colour. Click a title to open it: notes open in Obby, other files in their default macOS app. Hold Option while clicking to place the cursor inside a link instead. The `.md` file stays plain Markdown.

Any file can be attached and opened. The AI can read PDF (selectable text via PDFKit), TXT, MD, CSV and image attachments. Text in images (PNG, JPG, HEIC, …) and on scanned PDF pages is recognised on this Mac with Apple's Vision framework (printed and handwritten text; up to 50 scanned pages per PDF; nothing is uploaded for recognition, and diagrams are not described): tool-capable models use a `read_attachment` tool, and for chat-only models Obby includes the text of the note's attachments when a request is about them (for example "Summarize the attached PDF"). Extracted text goes through the same context budget as notes: only relevant sections are sent when possible, otherwise the document is processed in sections and combined. Very large documents are read up to about 400,000 characters. Word, PowerPoint, Excel, ZIP and other formats are attached and opened but not read.

## Publishing a release (maintainer)

1. Set the version in `Info.plist` (`CFBundleShortVersionString`, and raise `CFBundleVersion`).
2. Install full Xcode and create a **Developer ID Application** certificate in the Apple Developer account. The release certificate must be present in the Mac Keychain.
3. Create a `notarytool` Keychain profile for the Apple Developer team. Keep the profile name private and do not place Apple credentials in this repository.
4. Run `OBBY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/make_dmg.sh` (add `OBBY_SDK=…` if needed). It builds a universal, Developer ID-signed app and creates `build/Obby.dmg`.
5. Run `OBBY_NOTARY_PROFILE="your-notary-profile" ./scripts/notarize.sh`. This submits the DMG to Apple, waits for approval, staples the ticket, and verifies the finished artifact.
6. On GitHub, open **Releases → Draft a new release**, create a tag such as `v1.0`, attach the notarized `build/Obby.dmg` (keep the name `Obby.dmg` so the download button always points to the latest release), and publish.

## Chat memory

Each AI chat has its own compact memory, kept by Obby rather than by the model: a short summary, the current goal, decisions, relevant files (by path only), completed actions, open questions, and the most recent messages. Switching model or provider keeps the chat and sends the new model the same memory, so it can continue. With **Settings → Memory → Remember AI conversations between launches** (on by default), chats are saved as small JSON files in `~/Library/Application Support/Obby/Chats/` and the most recent chat for the notes folder comes back when Obby opens; the clock button in the AI panel lists earlier chats. **New chat** starts with empty memory.

Memory never copies note contents: notes are read from disk again when needed, so the filesystem stays the source of truth. When a chat's kept messages approach the context budget, Obby asks the current model once to fold the older messages into the summary (or uses a plain summary if that fails) and keeps the last few messages verbatim. Each request includes only that chat's memory, within the Context Window budget; the store itself is never uploaded, and it contains no API keys. **Clear current chat memory** and **Clear all AI memory** delete only these memory files, never notes or attachments.

## Hiding the AI panel

The sidebar button at the top right of the window (or **View → Hide AI / Show AI**, **Shift+Cmd+A**) hides or shows the AI panel; the editor takes the freed width and the folders sidebar is unchanged. Hiding only removes the panel from view: the chat, its memory, an unsent draft, the provider and model stay as they are, a running request finishes normally, and nothing is unloaded. The hidden panel does no rendering or refresh work. When shown again it returns to the latest message of the same chat. The choice is remembered between launches.

## License

Obby is available under the [Apache License 2.0](LICENSE).
