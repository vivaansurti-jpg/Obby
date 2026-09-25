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
- Select text and use **Bold**, **Italic**, **Underline**, or the **Text** menu. Select lines for bullets, numbers, or checklists. The completed-checkbox button marks selected lines complete. The editor shows supported Markdown as formatting: **bold**, *italic*, <u>underline</u>, large text, headings 1–3, bullets, numbered lists and checkboxes appear formatted, without visible `**`, `#` or `<u>`. Each button is a toggle: applying Bold to bold text removes it. Typing Markdown (for example `# `, `- `, `1. `, `- [ ] ` or `**word**`) converts it as you type, Return continues a list, and clicking a checkbox ticks it. Notes are still saved as plain Markdown files; copying from the editor copies Markdown. Links, images, code and other Markdown stay visible as written. Headings scale with the editor text size, which can be changed with View → Bigger (Cmd +), Smaller (Cmd −) and Actual Size (Cmd 0), or in Settings → Notes (11 to 28 points, default 14); this affects only the editor's display. The Text menu includes **Insert Table…**, which inserts a standard Markdown pipe table of the chosen size, and **Add Row** and **Add Column**, which are available when the cursor is inside a table. Tables remain plain Markdown text.
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

Choose the provider in **Settings → AI Provider**: Ollama (default, local), OpenAI-compatible (base URL, optional API key, model — works with OpenAI and many hosted or local servers), Anthropic, or Google Gemini. Switching takes effect immediately; Ollama-only controls (keep-alive, unload, loaded status) appear only for Ollama, and leaving Ollama honours the unload setting. The AI panel's provider menu shows the active provider with its connection status (for example, `Ollama ● Connected`), and the model menu sits inside the message box; for Ollama, a dot beside the model shows whether it is loaded.

**Saved Providers** (Settings → AI) adds any number of OpenAI-compatible services, such as DeepSeek, OpenRouter, Groq, Mistral, Together AI, LM Studio, or a server of your own. Each saved provider has its own name, base URL, tool-calling setting, selected model, and API key (stored in the macOS Keychain under its own entry). Presets fill in the base URL for common services. Saved providers appear by name in the AI panel's provider menu. Remote servers must use https://; plain http:// is allowed only for a server on this Mac.

All providers sit behind a small `AIProvider` protocol (`Sources/Obby/AIProvider.swift`) using URLSession directly. Providers only choose tool calls; Obby's own Swift tools perform every file operation with the same sandbox as before. Models without native tool calling (Ollama models whose `/api/show` capabilities lack `tools`, Gemma models on Gemini, or an OpenAI-compatible model with **Model supports tool calling** off) are offered no tools and are shown as “Chat only”: Obby includes the currently open note (with unsaved edits, up to 30,000 characters) in each request, so these models can summarize, explain, rewrite, analyze, and answer questions about that note, but they cannot search the vault, read other notes, or create, edit, move, rename, or delete files. Ollama replies stream by default: the Obby chat line updates about ten times per second while the model writes. Text that might be a tool call is held back and never shown, and a streamed tool call is executed like any other. If the stream fails before any text arrives, Obby retries once without streaming. **Stop** keeps the partial reply and marks it “(stopped)”. Turn this off with **Stream replies** in the Ollama settings. Other providers, and Ollama requests that use the structured JSON action format, stay request/response.

API keys are stored only in the macOS Keychain (`local.obby.notes.ai-provider`), never in notes, files, or UserDefaults; keys are sent in request headers, never URLs. Cloud requests use https (plain http only for a localhost server) and refuse redirects. With a cloud provider, your messages, recent chat, and only the notes or search results the tools read for that request leave your Mac; the vault is never sent wholesale. After rebuilding the ad-hoc-signed app, macOS may ask once to allow Obby to read its saved key.

## AI action display

The AI panel renders the model's Markdown replies natively (bold, italic, headings, bullet and numbered lists, inline code, code blocks, quotes, line breaks, pipe tables); images are shown only from inside the Obby folder (`![alt](folder/image.png)`, through the same path sandbox as notes, click to open), remote images are never fetched, and only http/https links are clickable (they open in your default browser). Model prose is shown as written; paths are shortened only in Obby's own action summaries. Each reply has a small copy button (copies the reply's original Markdown only, no action lines or tool data), and code blocks have their own. The stored reply stays raw Markdown and is never sent back to the model for formatting. Tool activity appears as a compact, subdued checklist (✓ Read Enzymes.md) of short action summaries generated by Obby, not by the model. The small code-symbol toggle **Show raw actions** is off by default and remembers its preference. Turn it on to inspect structured tool calls and exact response content. Summaries never enter model context. Raw details stay in memory only, with a 128 KB total budget; older details are discarded whole rather than silently truncated. New Chat and app close clear them with the rest of the conversation. No transcript files or logs are created.

AI navigation is search-first: content/name searches return root-relative paths at any folder depth, optionally scoped to a folder. Directory listing only returns direct children. Navigation results are paged (50 entries, approximately 6 KB), unchanged listings are reused within the current request, and all navigation payloads except the latest two are retired from active context. No vault tree is automatically sent to Ollama. Search scans files locally as needed without building a tree for the model. A full recursive inventory is reserved for explicit user requests.

## Starting Ollama

Normal use never needs Terminal. When Ollama is the provider and an AI request is made (or you press Refresh, Check Again, or Apply), Obby checks the local API once. If it isn't answering and **Start Ollama automatically when needed** (Settings, on by default) is on, Obby opens the installed `Ollama.app` in the background with `NSWorkspace` (no shell commands) and waits up to 20 seconds for the API before continuing the request. Starting the server loads no model; the model loads only for a real request. Launching Obby itself never starts Ollama. With the setting off, Obby shows “Ollama isn’t running. Open Ollama to use local AI.”; if Ollama isn't installed, it shows “Ollama isn’t installed.” with a Get Ollama link. The model status beside the model menu (`Loading`, `Loaded`, `Unloaded`, `Offline`) follows Obby's own events: `Loading` when a request starts, `Loaded` as soon as the model answers, `Unloaded` right after Obby unloads it. Obby also checks Ollama's read-only `/api/ps` once when it becomes active, when the provider or model menu opens, after switches, and once when the loaded model's keep-alive is due to expire. As a fallback it checks every 25 seconds, only while Obby is in front and the AI panel is open. Status checks never load or unload a model, and every timer stops when Obby goes to the background or quits. Quitting Obby still only unloads the model (when that setting is on) and never quits Ollama. OpenAI-compatible servers are never started automatically; if one can't be reached, Obby says the server is unavailable.

## Attachments

Drag files into a note, paste them, or use the toolbar buttons (**Insert image**, **Attach document**; both are disabled with no note open). Every attachment goes through one import path: the file is copied (never linked or referenced in place) into `Attachments/` next to the note, and a normal Markdown link is inserted at the cursor or drop point: `![name](Attachments/name.png)` for images, `[Biology Paper](Attachments/Biology Paper.pdf)` for documents. Name collisions get `-2`, `-3`, …; nothing is ever overwritten. Paths stay inside the notes folder; absolute paths and symlinks are blocked. Parent-relative attachment links are accepted only when they remain inside the notes folder. Folders and packages (such as `.pages`) are not attached. Document names keep their spaces; characters that would break a Markdown link are removed.

In the editor, link titles are shown in the link colour. Click a title to open it: notes open in Obby, other files in their default macOS app. Hold Option while clicking to place the cursor inside a link instead. The `.md` file stays plain Markdown.

Any file can be attached and opened. The AI can read PDF (selectable text via PDFKit), TXT, MD, CSV and image attachments. Text in images (PNG, JPG, HEIC, …) and on scanned PDF pages is recognised on this Mac with Apple's Vision framework (printed and handwritten text; up to 50 scanned pages per PDF; nothing is uploaded for recognition, and diagrams are not described): tool-capable models use a `read_attachment` tool, and for chat-only models Obby includes the text of the note's attachments when a request is about them (for example "Summarize the attached PDF"). Extracted text goes through the same context budget as notes: only relevant sections are sent when possible, otherwise the document is processed in sections and combined. Very large documents are read up to about 400,000 characters. Word, PowerPoint, Excel, ZIP and other formats are attached and opened but not read.

## Publishing a release (maintainer)

1. Set the version in `Info.plist` (`CFBundleShortVersionString`, and raise `CFBundleVersion`).
2. Install full Xcode and create a **Developer ID Application** certificate in the Apple Developer account. The release certificate must be present in the Mac Keychain.
3. Create a `notarytool` Keychain profile for the Apple Developer team. Keep the profile name private and do not place Apple credentials in this repository.
4. Run `OBBY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/make_dmg.sh` (add `OBBY_SDK=…` if needed). It builds a universal, Developer ID-signed app and creates `build/Obby.dmg`.
5. Run `OBBY_NOTARY_PROFILE="your-notary-profile" ./scripts/notarize.sh`. This submits the DMG to Apple, waits for approval, staples the ticket, and verifies the finished artifact.
6. On GitHub, open **Releases → Draft a new release**, create a tag such as `v1.0`, attach the notarized `build/Obby.dmg` (keep the name `Obby.dmg` so the download button always points to the latest release), and publish.

## AI memory

Memory belongs to Obby, not to the model, so switching model or provider continues the same task. Each chat (task) has its own compact memory: the current goal, a short summary, relevant files (by path only), decisions, completed actions, open next steps, preferences for that task, and the most recent messages. A small global memory holds only preferences you state as lasting ("from now on…", "always…", "I prefer…"); other details never move into it.

Everything is stored as small JSON files in `~/Library/Application Support/Obby/` (`Chats/` for tasks, `Memory.json` for global preferences). Memory never contains API keys, note contents, PDFs or raw tool output: files are remembered by path and read from disk again when needed, so the notes stay the source of truth.

Obby updates a task's memory after meaningful work (files created, changed or moved, a document read or summarised), when you state a lasting preference, and when the kept messages approach the context budget, in which case older messages are folded into the summary and only the last few stay verbatim. That update is one request to the current model; compaction falls back to a plain summary if it fails. Each AI request includes the global preferences and the current task's memory, within the Context Window budget; the store itself is never uploaded.

**Settings → Memory**: **Remember AI tasks between launches** (on by default) restores the latest task for the notes folder when Obby opens; **Chat History** in the AI panel's **…** menu lists earlier tasks (the same menu holds **Memory** and **New Chat**; the model picker sits above the prompt). **Clear current task memory** and **Clear all AI memory** (which also clears global preferences) delete only memory files, never notes or attachments. Global preferences are listed there and can be removed one by one. **New chat** starts with fresh task memory; global preferences still apply. The AI panel shows a small "Memory · N items" line (hover to see what is included).

## Hiding the AI panel

The sidebar button at the top right of the window (or **View → Hide AI / Show AI**, **Shift+Cmd+A**) hides or shows the AI panel; the editor takes the freed width and the folders sidebar is unchanged. Hiding only removes the panel from view: the chat, its memory, an unsent draft, the provider and model stay as they are, a running request finishes normally, and nothing is unloaded. The hidden panel does no rendering or refresh work. When shown again it returns to the latest message of the same chat. The choice is remembered between launches.

## License

Obby is available under the [Apache License 2.0](LICENSE).

## Your files

Obby does not own your content; it is an interface over a normal folder you choose. Every note, folder, image, PDF and attachment lives in that folder as an ordinary file, so it stays fully usable from Finder if Obby is deleted, and it can be backed up with Time Machine, iCloud Drive, Dropbox, an external drive or Git. There is no proprietary backup system and no hidden copy of any note, photo, PDF or attachment. `~/Library/Application Support/Obby/` holds only compact AI memory (paths and short summaries, never file contents); app settings live in macOS preferences and API keys in the Keychain.

- **Settings → Storage** shows the current notes location with **Show in Finder** and **Change Folder…**. Changing the folder only switches which folder Obby opens; nothing is moved or deleted.
- **Saves** write a temporary file beside the note, check it, then atomically replace the note. A failed save leaves the previous version intact; leftover temporary files from an interrupted save are removed the next time the folder opens.
- **Imports** copy the original (which is never changed or removed) to a temporary file in `Attachments/`, check that it arrived complete, then move it to a free, collision-safe name. The Markdown link is inserted only after that succeeds; existing attachments are never overwritten.
- **Deleting** a note or folder moves it to the macOS Trash. The AI can only request a deletion, which always asks for your confirmation, and it has no permanent-delete tool. All AI file access goes through Obby's own sandboxed file layer inside the notes folder.
- **Settings → AI Provider** shows whether requests are **Local · Ollama** ("Your AI requests stay on this Mac.") or **Cloud · provider** ("Relevant note or attachment content may be sent to this provider when you ask Obby to work with it.").

## How AI actions are handled

If the model wants to do something, Obby does it; if it wants to say something, Obby renders it. Native tool calls are executed through Obby's sandboxed file layer. Some smaller local models write a tool call as text instead (for example `write_file{"path":"TOK.md","content":"…"}` or `{"tool":"write_file",…}`); Obby recognises this only when the reply is (or ends in) a call to a known Obby tool with all required arguments, and runs it through the same checks. Ordinary JSON, code, prose and unknown tool names are never executed. A call Obby can't read is reported as "Couldn't run the requested action" and the model is asked once or twice to retry; it is never shown as text.

With **Show raw actions** off, the chat shows only compact summaries (✓ Updated TOK.md, ✓ Created the Test folder) and failures such as "Couldn't update TOK.md." with a short reason; raw calls, IDs, JSON and payloads appear only when it is on. Tool payloads never reach the Markdown renderer. `append_to_file` adds to the end of a note while keeping its existing content, so "add this to TOK.md" doesn't require rewriting the note. Before any tool runs, pending editor changes are saved; after an AI edit to the open note, the editor reloads the new text straight away, so autosave can't overwrite the AI's change.

## Safer AI edits

- **Undo**: every AI change to a note (edit, append, section change, rewrite, or a note it created) gets an **Undo** button on its action line. Undo puts the note back exactly as it was, or moves an AI-created note to the Trash. If the note changed after the AI edit, Obby asks first. Undo history is kept in memory for the session only.
- **Rewrite checks**: during an AI request, the model may replace a whole note only after reading it, and replacing a substantial note (over about 400 characters) with something much shorter (under 60%) asks for confirmation.
- **Section tools**: `read_section`, `replace_section`, `append_to_section` and `replace_text` let the model change one part of a note (by heading, or one exact passage) without rewriting the rest. Headings inside code blocks are ignored.
- **Tool routing**: each request is offered only the tools its wording needs (for example editing tools for "add this to…", folder tools for "move…"), which makes small models far more reliable. Tools that change or delete notes are offered only when the wording asks for them; other requests get read-only tools. Create tools are offered whenever a create verb (create, make, add, new, write, start, draft, save, generate) appears with a note, file or folder word, and multi-step requests ("…, and then…", "also…") get the tools for every step; if a step is unclear, create and edit tools are included rather than dropped. The model is told to finish every step before its final reply and list what it did. Short conversational messages ("hi there", "thanks!", "ok") get a one-line prompt with only your lasting preferences: no tools, no task memory, no related notes and no action format. Questions about the task itself ("what did we decide?", "remind me", "where were we") get the task memory and pins but no tools, and a text tool call for a tool the request wasn't offered is never run.
- **Related notes** are only searched for requests of at least four meaningful words, and weak matches are left out.
- **Action format for local models without tool support**: when such an Ollama model is asked to change notes, Obby uses Ollama structured outputs so the reply must be either one valid action or a plain answer, which Obby then runs through the same checks.

## Memory tools

- **Memory viewer**: click "Memory · N items" in the AI panel to see what the current task remembers (goal, pinned facts, summary, decisions, next steps, preferences, completed actions, files, lasting preferences), edit the goal and remove any item.
- **Pinning**: right-click any message and choose **Pin to Memory**, or start a request with "Remember that…". Pinned facts are never condensed away (up to 20 per task).
- **Folder context**: right-click a folder (or a note, for its folder) and choose **Folder Context…** to give the AI a short standing note about that folder, used whenever it works on notes there. Stored in Obby's memory file, not in your notes.
- **Accurate file references**: when notes or folders are moved, renamed or deleted in Obby, every task memory and folder context follows the change. Files moved or deleted outside Obby are marked as no longer existing rather than silently misleading the model.
- **Continue**: opening a note that an earlier task worked on shows "Continue: <task>" in an empty chat.
- **Related notes**: Obby can add short excerpts from your most relevant notes to each request, found with an in-memory keyword index that is never written to disk (on by default for local models, off for cloud providers; Settings → AI Provider). A "Using:" line shows which notes were included.
- **Quick actions**: the wand menu next to Send, or typing `/summarise`, `/flashcards`, `/quiz`, `/outline` or `/revision` (add `save` to save the result as a new note beside the current one).

## About me

Obby keeps a short "About me" list (up to 15 lines of at most 120 characters) in `Memory.json`, and includes it as "About the user" in every request, small talk included (roughly 50 to 100 tokens).

- **Learning without extra requests**: when you state something about yourself ("I'm doing Biology HL", "my exam is in May", "I study…", "I prefer…"), the existing memory update also picks out facts you stated about yourself. Obby keeps a fact only if you actually said it (its words must appear in your own message), never guesses or note contents, and never anything sensitive (health, money, passwords, ID numbers).
- **Merging**: near-duplicates are merged, a newer fact replaces an older one on the same subject ("my exam is in June" replaces "my exam is in May"), and when the list is full the oldest fact is dropped.
- **"Remember that I…"** or **"Remember I…"** goes straight to About me; other "Remember that…" requests stay pinned to the current task.
- **Settings → Memory**: "Obby knows N things about you · View" opens a viewer for About me, lasting preferences, folder contexts and saved tasks. Every item can be edited or removed, and About me and preferences have an Add field. **Learn about me from chats** (on by default) turns learning off; explicit "Remember that I…" still works. **Clear all AI memory** also clears About me.

## Keeping memory small

Each task's memory stays around 150 to 250 tokens over time:

- A completed action that matches an open next step (same note name or distinctive word, for example "Created Synapses Flashcards.md" and "Generate flashcards for Synapses") removes that next step.
- Only the last 8 completed actions are kept word for word; older ones become a count ("12 earlier actions").
- Decisions are capped at 8, pins at 20; the oldest non-pinned items go first.
- Files that no longer exist are marked as such, and drop out of the task after 7 days.
- Pins and About me are never cleaned up automatically.

The instructions sent to tool-capable models were also shortened (about 310 to about 150 tokens) without dropping any rule: use tools to actually do things, never claim an action that didn't succeed, read before editing, don't invent contents, find notes with search, only use tools when asked.

## Dictation

The microphone button in the AI prompt field turns your speech into text using Apple's Speech framework, on this Mac when on-device recognition is available. Text appears in the prompt as you speak. While listening, the button turns red and pulses with your voice and a “Listening…” label is shown; there is no system chime. Listening stops when you click the button again, send the prompt, or pause for about 2.5 seconds. The first use asks for Microphone and Speech Recognition permission; audio is used only while the button is on. If either permission is denied, the button falls back to macOS Dictation (also **Edit → Start Dictation**). Signed builds include the `com.apple.security.device.audio-input` entitlement (`Obby.entitlements`) so the microphone works under the hardened runtime.

## Task titles

A task's title and starting goal come from its first real request (the first line, up to 60 characters), never from small talk or a question about memory. After real work, the memory update may replace the title with a better one of up to six words. Chats that contain only small talk are not saved to the chat history. Older tasks whose title was a greeting ("hi there", "how are you") have that title and goal cleared when loaded, so the next real request sets them.

### Reliability safeguards

- If the notes folder disconnects or moves while there are unsaved edits, the editor retains them and blocks closing until they are saved. Reconnect the folder or choose **File → Save Recovery Copy…**.
- Native and text-based AI tool calls are checked against the actions permitted for that request. Whole-note AI rewrites are rejected if the note changed after the model read it. Attachment reads remain tied to the originating note when you navigate elsewhere.
- Moving or renaming a note/folder updates ordinary Markdown links throughout the vault. Attachments stay in place; relative links are rewritten to keep pointing at the same files. Parent-relative links are allowed only inside the vault, with symlink and outside-folder access still blocked. AI tool file paths still reject `..`.
- Undo records follow moves, including the relative links in their saved versions. The editor, section tools, table tools, search index and chat renderer share code-fence rules for backticks and tildes.
- Folder scans and debounced searches run off the main thread. Temporary-file cleanup removes only recognized files older than 24 hours and skips active writes/imports. Memory save and deletion failures are reported instead of silently ignored.
- `scripts/test.sh` includes the targeted reliability regression checks in `scripts/RegressionChecks.swift`.
