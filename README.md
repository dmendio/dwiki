![dwiki logo](./img/logo.png)

A minimal, filetype-agnostic wiki plugin for Neovim. No dedicated wiki directory or imposed structure.

Inspired by [wiki.vim](https://github.com/lervag/wiki.vim)!

## ✨️ Features

- **No wiki setup required:** link to files of any type.
- **Quick link creation:** turn a word or selected text into a Markdown or `[[wiki]]` link.
- **Simple navigation:** follow local links, open web links, and jump back to your previous file and cursor position.
- **Page rename**: use `:DwikiRename` or a shortcut (default `<leader>wr`) to rename a saved page
    - This also updates links to the renamed page, with some limitations. See [🔗 Page Rename](#page-rename)
- **Page deletion**: use `<leader>wd` or `:DwikiDelete` to confirm deletion and return to the previous page, or an empty buffer if there is no previous page.
- **Flexible filenames and templates:** customize generated filenames and populate new files with per-filetype templates.
- **Optional `:wq` integration:** save modified files in your navigation history when quitting.

## ⬇️ Installation

> ℹ️ dwiki requires Neovim v0.10.0 or later. It is configured in Lua.

Install with your favorite plugin manager.

For example, with [lazy.nvim](https://github.com/folke/lazy.nvim):
```lua
{
    "dmendio/dwiki",
    config = function()
        require("dwiki").setup()
    end
}
```

## 💡 Usage

By default, dwiki works in Markdown (`.md`) and text (`.txt`) buffers:

| Action | Key |
| --- | --- |
| Create a link from the word under your cursor | `Enter`|
| Create a link from selected text\* | Select with `v` or `V`, then `Enter` |
| Follow a link | `Enter` (with cursor on the link)|
| Return to the previous file and cursor position | `Backspace`|
| Rename the current page and update links | `<leader>wr`|
| Delete the current file | `<leader>wd`|

> \*Note: selected text must be on one line.

For example, visually select `Project Notes` and press `Enter` to create `[Project Notes](project-notes.md)`. Press `Enter` on the link to open its target; if the file doesn't exist, dwiki opens a new buffer for it. **Save with `:w` to create the file on disk.** Unsaved changes are preserved while navigating.

Both `[My Note](note.md)` and `[[note.md|My Note]]` can be followed, regardless of your chosen `link_style`. Local paths are resolved relative to the current file. Heading fragments, link titles, and reference-style Markdown links are not supported.

With `wqall = true`, `:wq` also saves modified files in the current window's navigation history before quitting.

## ⚙️ Configuration

Here are all the options, set to their defaults. `link_key = false` disables link creation/following; `Backspace` remains mapped for back navigation.

```lua
require("dwiki").setup({
    -- Filetypes in which dwiki is enabled
    -- Use :lua print(vim.bo.filetype) to check a buffer's filetype
    --
    -- Any filetype can be enabled, but human-readable formats (markdown,
    -- text, asciidoc, etc.) are recommended
    filetypes = { 'markdown', 'text' },

    -- Convert filenames to lowercase
    -- false: preserve capitalization
    lowercase = true,

    -- Separator to replace spaces in file names
    -- false: keep whitespace
    whitespace = '-',

    -- Generated link style. Must be 'markdown' or 'wiki'
    -- 'markdown': [Standard markdown](markdown.md) style
    -- 'wiki': [[wiki|Obsidian]] style
    link_style = 'markdown',
    
    -- Key for creating links and following them
    -- Default is Enter
    link_key = "<CR>",

    -- Keys for renaming and deleting
    rename_key = '<leader>wr',
    delete_key = '<leader>wd',

    -- Link update behavior
    link_updates = {
        -- false: don't update links when you rename a file
        on_rename = true
    }

    
    -- Define templates for new files here
    -- See Templates section below
    templates = {},

    -- true: save modified linked files in the current window's history on :wq
    wqall = false,
})
```

### Filename Creation

dwiki generates the file name based on the text of the new link. You can customize how it handles whitespace and capitalization, with the `whitespace` and `lowercase` options:

| Setting | Selection | `lowercase = true` | `lowercase = false` | 
| --- | --- | --- | --- |
| `whitespace = '-'` | `My Link` | `my-link.md` | `My-Link.md` |
| `whitespace = '_'` | `My Link` | `my_link.md` | `My_Link.md` |
| `whitespace = ''` | `My Link` | `mylink.md` | `MyLink.md` |
| `whitespace = false` | `My Link` | `my link.md` | `My Link.md` |

### Page Rename
The `rename_key` (default `<leader>wr`) and `:DwikiRename` prompt for a new filename.
- The current file must already exist (`:w` at least once)
- The new name must not already exist

#### Page Rename: Updating Links
By default, renaming a file also updates links to that file.

> If you want to disable this feature, set `update_links = { on_rename = false }`

⚠️ **The link update functionality comes with some limitations to keep in mind:**
- Links are only discovered within the **current wiki.**
    - The containing directory of the first file opened int eh session becomes the "wiki root" and stays fixed as you navigate throughout the session.
    - Symlinks are ignored.
- **Text matching, without Markdown parsing.** Matching link syntax is changed inside code blocks, comments, or other literal text.
- **Runs synchronously.** Very large directory trees may take some time.

For example, open `notes/index.md`, follow a link to `notes/topics/file4.md`, then rename it to `hello`. dwiki renames it to `notes/topics/hello.md` and updates links throughout `notes/`, including sibling and nested pages. A link in `other-wiki/file6.md` is outside the root and remains unchanged. The completion message reports link occurrences, not files: Updated 4 links in folder `/path/to/notes`.

### Page Deletion
The `delete_key` (default `<leader>wd`) and `:DwikiDelete` allow you to delete the current file. After confirmation, dwiki deletes the file, discards that page's unsaved edits, and removes it from navigation history. It returns to the most recent available page in the current window's history, or opens an empty buffer when no previous page is available.
- Incoming links are not removed or rewritten. 

### Templates

Templates populate newly created files based on filetype.

The `templates` option is a table whose keys are filetypes (`:set filetype?`) and whose values are **template definitions**.

Templates are defined like so:
```lua
require("dwiki").setup({
    templates = {
        ["markdown"] = "# New page",
        ["text"] = { "New note", "" },
    },
})
```

A **template definition** can be a list of lines, a string (including Lua multiline strings), or a `function(ctx)` returning either. Templates are applied only to new, empty files of an enabled filetype.

For dynamic templates, `ctx.link_text` is the label of the link used to open the file (or `nil` if it wasn't opened through a link). `ctx.link_filename` is the new file's basename. Other available fields are `ctx.path`, `ctx.filetype`, and `ctx.buf`.

#### Template example
```lua
templates = {
    -- For a wiki that expects an "index.md" as an entry point
    markdown = function(ctx)
        if ctx.link_filename == 'index.md' then
            return {
                "# New Wiki"
            }
        else
            return {
                "[index](index.md)",
                "# " .. (ctx.link_text and ctx.link_text or ""),
                ""
            }
        end
    end,

    -- A simple .txt template
    text = function(ctx)
        return { ctx.link_text or "", "" }
    end
}
```


## 🛠️ Planned(?) Features
- Option to rewrite/remove links that point to a deleted file.
- Configurable behavior for how dwiki decides where to look for links to update, after a rename (or delete, if above feature added)
- Configurable fallback page after delete, and/or a configurable callback that returns a fallback file path

### 🏗️ Contributing

Contributions are welcome! Send in a PR, and I'll look at it when I get the chance.
