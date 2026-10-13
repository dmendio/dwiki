local dwiki = {}
local api = vim.api
local history = {}

local defaults = {
    -- string: replace whitespace
    -- false: don't replace whitespace
    whitespace = '-',

    -- false: preserve capitalization in filenames
    lowercase = true,

    -- 'wiki': [[wiki]] style links
    link_style = 'markdown',

    -- filetypes enabled for link creation and following
    -- :lua print(vim.bo.filetype)
    filetypes = { 'markdown', 'text' },

    -- Filetype -> lines, multiline string, or function(ctx)
    templates = {},

    -- key for link creation / following. False disables
    link_key = '<CR>',

    -- true: :wq saves and quits every unsaved file in the history stack
    wqall = false
}

local config = vim.deepcopy(defaults)
local aliases = { md = 'markdown', txt = 'text' }
local attached = {}
local pending_templates = {}
local opening_link

local function filetype(ft)
    return aliases[ft] or ft
end

local function enabled(buf)
    local ft = vim.bo[buf].filetype
    for _, value in ipairs(config.filetypes) do
        if ft == filetype(value) then return true end
    end
    return false
end

local function navigate(command)
    local win = api.nvim_get_current_win()
    local origin = {
        buf = api.nvim_get_current_buf(),
        path = api.nvim_buf_get_name(0),
        cursor = api.nvim_win_get_cursor(0),
    }
    vim.cmd(command)
    local destination = api.nvim_get_current_buf()
    if destination ~= origin.buf then
        history[win] = history[win] or {}
        table.insert(history[win], origin)
    end
end

function dwiki._wq_command()
    local stack = history[api.nvim_get_current_win()]
    return stack and #stack > 0 and 'DwikiWq' or 'wq'
end

function dwiki.back()
    local stack = history[api.nvim_get_current_win()]
    if not stack or #stack == 0 then return end
    local origin = stack[#stack]
    if api.nvim_buf_is_valid(origin.buf) then
        vim.cmd('hide buffer ' .. origin.buf)
    elseif origin.path ~= '' then
        vim.cmd('hide edit ' .. vim.fn.fnameescape(origin.path))
    else
        table.remove(stack)
        return
    end
    table.remove(stack)
    local row = math.min(origin.cursor[1], api.nvim_buf_line_count(0))
    local line = api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
    api.nvim_win_set_cursor(0, { row, math.min(origin.cursor[2], #line) })
end

local function template(buf)
    if not pending_templates[buf] or not enabled(buf) then return end

    local context = pending_templates[buf]
    pending_templates[buf] = nil
    local value = config.templates[vim.bo[buf].filetype]

    if not value then return end

    local lines = api.nvim_buf_get_lines(buf, 0, -1, false)

    if #lines ~= 1 or lines[1] ~= '' or vim.bo[buf].modified then return end
    if type(value) == 'function' then
        value = value({
            buf = buf, path = api.nvim_buf_get_name(buf), filetype = vim.bo[buf].filetype,
            link_text = context.link_text,
            link_filename = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ':t'),
        })
    end

    if value == nil then return end

    if type(value) == 'string' then
        value = vim.split(value, '\n', { plain = true })
    end

    vim.validate('template', value, 'table')

    if #value > 0 then api.nvim_buf_set_lines(buf, 0, -1, false, value) end
end

local function link_at(line, col)
    local offset = 1

    -- allow, e.g. [Notes](notes(2).txt).
    while true do
        local first, last, contents = line:find('%[%[([^%[%]]-)%]%]', offset)
        if not first then break end
        if col >= first and col <= last then
            local target, label = contents:match('^([^|]*)|(.*)$')
            return target or contents, 'wiki', label or contents
        end
        offset = last + 1
    end

    offset = 1

    while true do
        local first, last, label, target = line:find('(%b[])(%b())', offset)
        if not first then return end
        if col >= first and col <= last then
            -- undo punctuation escapes in the display label, including those create() emits.
            local text = label:sub(2, -2):gsub('\\(%p)', '%1')
            return target:sub(2, -2), 'markdown', text
        end
        offset = last + 1
    end
end

function dwiki.follow()
    if not enabled(api.nvim_get_current_buf()) then return end

    local cursor = api.nvim_win_get_cursor(0)
    local target, style, text = link_at(api.nvim_get_current_line(), cursor[2] + 1)
    if not target then
        dwiki.create_word()
        return
    end
    target = vim.trim(target)
    if target:match('^https?://') or target:match('^mailto:') then
        vim.ui.open(target)
        return
    end
    if target:find('#', 1, true) or target:match('%s+["\']') then
        vim.notify('dwiki: heading fragments are not yet supported', vim.log.levels.WARN)
        return
    end
    if style == 'markdown' then
        target = target:gsub('^<(.*)>$', '%1')
        target = target:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
    end
    if target == '' then return end
    if target:match('^[%a][%w+.-]*:') then
        vim.notify('dwiki: unsupported URI scheme', vim.log.levels.WARN)
        return
    end
    if style == 'wiki' and not vim.fn.fnamemodify(target, ':t'):match('%.[^%.]+$') then
        target = target .. '.md'
    end

    local source = api.nvim_buf_get_name(0)
    local path
    if target:sub(1, 1) == '/' then
        path = target
    elseif target:sub(1, 2) == '~/' then
        path = vim.fn.expand('~') .. target:sub(2)
    else
        path = vim.fn.fnamemodify(source, ':p:h') .. '/' .. target
    end

    path = vim.fn.simplify(path)
    local previous = opening_link
    opening_link = { path = vim.fn.fnamemodify(path, ':p'), link_text = text }
    local ok, err = pcall(navigate, 'hide edit ' .. vim.fn.fnameescape(path))
    opening_link = previous
    if not ok then error(err, 0) end
end

local function create_range(row, start_col, end_col)
    local line = api.nvim_buf_get_lines(0, row, row + 1, false)[1]
    local text = line:sub(start_col + 1, end_col)
    local slug = vim.trim(text)
    if config.lowercase then slug = slug:lower() end
    slug = slug:gsub('[^%w_.%-%s]', '')
    if config.whitespace ~= false then
        slug = slug:gsub('%s+', function() return config.whitespace end)
    end
    if slug == '' then
        vim.notify('dwiki: selection has no filename characters', vim.log.levels.WARN)
        return
    end

    -- an explicitly selected name such as file.txt keeps its extension.
    if not slug:match('%.[%w_%-]+$') then slug = slug .. '.md' end

    local link
    if config.link_style == 'wiki' then
        local label = text:gsub('[%[%]|]', '')
        link = '[[' .. slug .. '|' .. label .. ']]'
    else
        local label = text:gsub('([\\%[%]])', '\\%1')
        local target = slug:gsub('[%%%(%)%[%]%s#?<>]', function(char)
            return string.format('%%%02X', char:byte())
        end)
        link = '[' .. label .. '](' .. target .. ')'
    end
    api.nvim_buf_set_text(0, row, start_col, row, end_col, { link })
end

function dwiki.create()
    if not enabled(api.nvim_get_current_buf()) then return end
    if vim.fn.visualmode() == '\22' then
        vim.notify('dwiki: select text with v or V, not a visual block', vim.log.levels.WARN)
        return
    end

    local first = api.nvim_buf_get_mark(0, '<')
    local last = api.nvim_buf_get_mark(0, '>')
    if first[1] ~= last[1] or first[1] == 0 then
        vim.notify('dwiki: select text on one line', vim.log.levels.WARN)
        return
    end

    local row = first[1] - 1
    local line = api.nvim_buf_get_lines(0, row, row + 1, false)[1]
    local start_col, end_col = first[2], last[2]

    if vim.fn.visualmode() == 'V' then
        start_col, end_col = 0, #line
    elseif vim.o.selection == 'exclusive' then
        end_col = math.min(end_col, #line)
    else
        local char = vim.fn.strcharpart(line:sub(end_col + 1), 0, 1)
        end_col = math.min(end_col + #char, #line)
    end
    create_range(row, start_col, end_col)
end

function dwiki.create_word()
    if not enabled(api.nvim_get_current_buf()) then return end
    local cursor = api.nvim_win_get_cursor(0)
    local line = api.nvim_get_current_line()
    local offset = 0
    while true do
        -- \k respects the buffer's 'iskeyword'.
        local match = vim.fn.matchstrpos(line, [[\k\+]], offset)
        if match[2] < 0 or match[2] > cursor[2] then return end
        if cursor[2] < match[3] then
            create_range(cursor[1] - 1, match[2], match[3])
            return
        end
        offset = match[3]
    end
end

local function detach(buf)
    if not attached[buf] or not api.nvim_buf_is_valid(buf) then return end
    api.nvim_buf_call(buf, function()
        for _, mapping in ipairs(attached[buf]) do
            local map = vim.fn.maparg(mapping.key, mapping.mode, false, true)
            if map.buffer == 1 and map.desc == mapping.desc then
                vim.keymap.del(mapping.mode, mapping.key, { buffer = buf })
            end
        end
    end)
    attached[buf] = nil
end

local function attach(buf)
    detach(buf)
    if not enabled(buf) then return end
    attached[buf] = {}
    local function map(mode, key, action, desc)
        vim.keymap.set(mode, key, action, { buffer = buf, desc = desc })
        table.insert(attached[buf], { mode = mode, key = key, desc = desc })
    end
    map('n', '<BS>', dwiki.back, 'dwiki: Previous linked file')
    if config.link_key == false then return end
    map('n', config.link_key, dwiki.follow, 'dwiki: Follow link or create word link')
    map('x', config.link_key, '<Esc><Cmd>lua require("dwiki").create()<CR>', 'dwiki: Create link')
end

function dwiki.setup(opts)
    local next_config = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})

    if opts and opts.filetypes then next_config.filetypes = vim.deepcopy(opts.filetypes) end

    -- asserts
    assert(
        next_config.whitespace == false or type(next_config.whitespace) == 'string',
        'dwiki: whitespace must be a string or false'
    )
    assert(
        type(next_config.lowercase) == 'boolean',
        'dwiki: lowercase must be a boolean'
    )
    if type(next_config.whitespace) == 'string' then
        assert(not next_config.whitespace:find('[/%\\%[%]|#?<>:"%c]'),
        'dwiki: whitespace replacement contains unsafe filename/link characters')
    end
    assert(next_config.link_style == 'markdown' or next_config.link_style == 'wiki',
    'dwiki: link_style must be markdown or wiki')
    assert(vim.islist(next_config.filetypes), 'dwiki: filetypes must be a list')
    assert(type(next_config.templates) == 'table', 'dwiki: templates must be a table')
    assert(next_config.link_key == false or
    (type(next_config.link_key) == 'string' and next_config.link_key ~= ''),
    'dwiki: link_key must be a nonempty string or false')
    if next_config.link_key then
        assert(api.nvim_replace_termcodes(next_config.link_key, true, false, true) ~=
        api.nvim_replace_termcodes('<BS>', true, false, true),
        'dwiki: link_key cannot use Backspace (reserved for back navigation)')
    end
    for _, ft in ipairs(next_config.filetypes) do
        assert(type(ft) == 'string', 'dwiki: filetypes must contain strings')
    end
    local templates = {}
    for ft, value in pairs(next_config.templates) do
        assert(type(value) == 'string' or type(value) == 'table' or type(value) == 'function',
        'dwiki: templates must contain strings, line lists, or functions')
        templates[filetype(ft)] = value
    end

    next_config.templates = templates
    config = next_config

    local group = api.nvim_create_augroup('Dwiki', { clear = true })

    if config.wqall then
        api.nvim_create_user_command('DwikiWq', function(opts)
            local saved = {}
            for _, origin in ipairs(history[api.nvim_get_current_win()] or {}) do
                local buf = origin.buf
                if not saved[buf] and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
                    api.nvim_buf_call(buf, function()
                        vim.cmd('update' .. (opts.bang and '!' or ''))
                    end)
                    saved[buf] = true
                end
            end
            vim.cmd('wq' .. (opts.bang and '!' or '') .. ' ' .. opts.args)
        end, { bang = true, nargs = '*', complete = 'file' })
        vim.cmd([[cnoreabbrev <expr> wq getcmdtype() == ':' && getcmdline() == 'wq' ? luaeval('require("dwiki")._wq_command()') : 'wq']])
    end

    api.nvim_create_autocmd('FileType', {
        group = group, callback = function(ev) attach(ev.buf); template(ev.buf) end,
    })

    api.nvim_create_autocmd('BufNewFile', {
        group = group, callback = function(ev)
            local path = api.nvim_buf_get_name(ev.buf)
            pending_templates[ev.buf] = {
                link_text = opening_link and opening_link.path == path and opening_link.link_text or nil,
            }
            template(ev.buf)
        end,
    })

    api.nvim_create_autocmd('BufWipeout', {
        group = group, callback = function(ev) attached[ev.buf] = nil; pending_templates[ev.buf] = nil end,
    })

    api.nvim_create_autocmd('WinClosed', {
        group = group, callback = function(ev) history[tonumber(ev.match)] = nil end,
    })

    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) then attach(buf) end
    end
end

return dwiki
