![dwiki logo](./img/logo.png)

A light, file-agnostic wiki plugin for Neovim. No dedicated wiki directory or imposed structure.

Inspired by [wiki.vim](https://github.com/lervag/wiki.vim)!

## ✨️ Features

- **No wiki setup required:** link to files of any type.
- **Quick link creation:** turn a word or selected text into a Markdown or `[[wiki]]` link.
- **Simple navigation:** follow local links, open web links, and jump back to your previous file and cursor position.
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
| Create a link from the word under your cursor | `Enter` in normal mode |
| Create a link from selected text\* | Select with `v` or `V`, then `Enter` |
| Follow a link | Place your cursor on it and press `Enter` in normal mode |
| Return to the previous file and cursor position | `Backspace` in normal mode |

> \*Note: selected text must be on one line.

For example, visually select `Project Notes` and press `Enter` to create `[Project Notes](project-notes.md)`. Press `Enter` on the link to open its target; if the file doesn't exist, dwiki opens a new buffer for it. **Save with `:w` to create the file on disk.** Unsaved changes are preserved while navigating.

Both `[My Note](note.md)` and `[[note.md|My Note]]` can be followed, regardless of your chosen `link_style`. Local paths are resolved relative to the current file. Heading fragments, link titles, and reference-style Markdown links are not supported.

With `wqall = true`, `:wq` also saves modified files in the current window's navigation history before quitting.

## ⚙️ Configuration

Here are all the options, set to their defaults. `link_key = false` disables link creation/following; `Backspace` remains mapped for back navigation.

```lua
require("dwiki").setup({
    -- Filetypes in which link creation / following are enabled
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
