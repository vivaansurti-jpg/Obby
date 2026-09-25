# Obby Features

Obby is a native macOS app for Markdown notes, with an AI assistant that can safely read and organise the notes in one chosen folder. This document lists everything Obby can do.

## Notes

- Works on an ordinary folder of Markdown (`.md`) files. The folder on disk is the source of truth; there is no database and no proprietary format.
- Sidebar with folders and notes; single selection; drag a note or folder onto another folder (or onto Root Folder) to move it.
- Create notes (Cmd+N) and folders (Cmd+Shift+N) in the selected folder.
- Drag Markdown files from Finder onto the sidebar, the empty note area, or the AI panel to add them. They are copied (never moved) into the selected folder, renamed with -2, -3 if the name is taken, and opened. Dropped on the AI panel, they are also named in the message box so you can say what to do with them.
- Rename a note by clicking its title above the editor; invalid names are rejected and existing notes are never overwritten.
- Right-click to rename, move, or move to the Trash (always confirmed; nothing is deleted permanently).
- Search (Cmd+F) across note names and contents.
- Autosave after 600 ms of inactivity, immediately when switching notes or closing, and with Cmd+S. Saves are atomic, so a failed save never damages the previous version.
- External changes are detected; conflicting edits offer to overwrite or reload, never lose text silently.
- **Linked from**: below the editor, a list of the notes that link to the open note. Click one to open it.

## Editor

- Supported Markdown is shown as formatting instead of raw syntax: bold, italic, underline, large text, headings 1 to 3, bullets, numbered lists and checkboxes. The file is still saved as plain Markdown.
- Toolbar buttons are true toggles: applying Bold to bold text removes it; the same applies to italic, underline, headings, lists and checklists.
- Typing Markdown converts as you type (`# `, `- `, `1. `, `- [ ] `, `**word**`). Return continues a list; Return on an empty item ends it.
- Click a checkbox to tick it.
- Copying from the editor copies Markdown; pasted Markdown appears formatted.
- Editor text size: View → Bigger (Cmd +), Smaller (Cmd −), Actual Size (Cmd 0), or Settings → Notes (11–28 pt, default 14). Headings scale with it. Display only.
- Tables: Insert Table… (choose columns and rows) inserts a plain Markdown pipe table; Add Row and Add Column work when the cursor is in a table. Each is one undo step.
- Links, images, code and tables stay visible as written. Click a link title to open it (notes in Obby, other files in their default app).

## Attachments

- Drag files into a note, paste them, or use Insert Image / Attach Document. Files are copied into an `Attachments` folder beside the note and linked with normal Markdown.
- The AI can read attached PDF, TXT, MD and CSV files and images (text in images and scanned pages is recognised on the Mac).

## AI assistant

- Tell Obby what to do with your notes in plain language: find, read, summarise, create, edit, reorganise, move, rename, or request deletion.
- Example requests are shown in an empty chat; clicking one fills the message box so it can be edited before sending.
- Works with a local model through Ollama (default) or with OpenAI-compatible services, Anthropic and Google Gemini.
- **Saved providers**: add any number of OpenAI-compatible services (DeepSeek, OpenRouter, Groq, Mistral, Together AI, LM Studio, or your own server). Each keeps its own address, model and API key.
- Replies stream as they are written (Ollama) and are shown as formatted Markdown, with a copy button.
- Quick actions: summarise, flashcards, quiz, outline and revision notes (`/summarise`, `/flashcards`, and so on; add `save` to save the result as a note).
- In-app dictation, on-device only.
- Short follow-ups such as "yes" or "try again" continue the previous task.

## Safety and trust

- The AI can only work inside the chosen notes folder. Absolute paths, `..`, and symlinks out of the folder are rejected. There is no shell access.
- Text inside notes and attachments is treated as data, never as instructions to the AI.
- **Preview before large changes**: before the AI moves, renames or deletes anything, or changes more than one note in a request, Obby shows the planned changes and asks once. Cancel and nothing is changed.
- **Undo**: every AI change has its own Undo button. A request that made several changes also offers **Undo task**, which puts back every note it edited, created or moved in one step.
- Deleting always asks for confirmation and moves items to the Trash; the AI has no permanent-delete tool.
- The AI must read a note before rewriting it, and replacing a substantial note with a much shorter version asks first.
- Obby never claims an action happened unless it did; if a change request produces no action, the model is reminded once to act or say it cannot.
- Repeated failing actions are stopped, with a summary of what was and was not done.
- API keys are stored only in the macOS Keychain.
- Cloud providers receive only what a request needs; the whole folder is never sent by default.

## AI memory

- Each chat keeps a compact task memory (goal, decisions, completed actions, files), carried over when switching models or providers.
- Pin facts to memory, set a standing note for a folder (Folder Context), and let Obby learn short facts about you (About me). Everything can be viewed, edited or removed in Settings.
- Chat history can be saved between launches (optional).
- Related notes: short excerpts from the most relevant notes can be added to a request (on by default for local models).

## Local models (Ollama)

- Starts Ollama when needed (optional); unloads the previous model when switching and the active model when quitting (optional); keep-alive setting.
- Model status (Loading, Loaded, Unloaded) follows Obby's own events with a light read-only check, and never loads a model by itself. Offline is always shown.

## Settings and display

- Settings open as a sheet on the main window (gear button or Cmd+,).
- **Show technical details** (off by default, Settings → Advanced): model memory status, context size, and each action's raw request and result. With it off, the AI panel shows only the provider, the model and the chat.
- The AI panel can be hidden (Shift+Cmd+A).

## Not included, on purpose

- No sync: put the notes folder in iCloud Drive, Dropbox or a Git repository.
- No plugins, themes, graph view, visual table editor, or mobile/Windows versions.
