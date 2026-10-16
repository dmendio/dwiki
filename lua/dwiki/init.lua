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

    -- Key for link creation / following. False disables
    link_key = '<CR>',

    -- Keys for renaming and deleting
    rename_key = '<leader>wr',
    delete_key = '<leader>wd',

    -- Link update behavior
    link_updates = {
        on_rename = true
    },

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

local uv = vim.uv or vim.loop
local wiki_root

local function absolute(path)
    return vim.fn.simplify(vim.fn.fnamemodify(path, ':p'))
end

local function remember_root(buf)
    if wiki_root or vim.bo[buf].buftype ~= '' then return end
    local path = api.nvim_buf_get_name(buf)
    local stat = path ~= '' and uv.fs_stat(path) or nil
    if path ~= '' and (not stat or stat.type == 'file') then
        wiki_root = vim.fn.fnamemodify(absolute(path), ':h')
    end
end

local function problem(message)
    vim.notify('dwiki: ' .. tostring(message), vim.log.levels.ERROR)
end

local function rewrite_links(text, source, old, new)
    local count = 0
    local function target(raw, style)
        local leading, value, trailing = raw:match('^(%s*)(.-)(%s*)$')
        local wrapped = style == 'markdown' and value:match('^<.*>$')
        if wrapped then value = value:sub(2, -2) end
        local path, fragment = value:match('^([^#]*)(#.*)$')
        path, fragment = path or value, fragment or ''
        if style == 'markdown' then
            path = path:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
        end
        if path == '' or path:match('^[%a][%w+.-]*:') then return raw end
        local implicit = style == 'wiki' and not vim.fn.fnamemodify(path, ':t'):match('%.[^%.]+$')
        local resolved = path
        if implicit then resolved = resolved .. '.md' end
        if resolved:sub(1, 2) == '~/' then
            resolved = vim.fn.expand('~') .. resolved:sub(2)
        elseif resolved:sub(1, 1) ~= '/' then
            resolved = vim.fn.fnamemodify(source, ':h') .. '/' .. resolved
        end
        if absolute(resolved) ~= old then return raw end
        local name = vim.fn.fnamemodify(new, ':t')
        if implicit and name:sub(-3) == '.md' then name = name:sub(1, -4) end
        path = (path:match('^(.*[/])') or '') .. name
        if style == 'markdown' then
            path = path:gsub('[%%%(%)%[%]%s#?<>]', function(char)
                return string.format('%%%02X', char:byte())
            end)
        end
        value = path .. fragment
        if wrapped then value = '<' .. value .. '>' end
        count = count + 1
        return leading .. value .. trailing
    end
    local out, offset = {}, 1
    while offset <= #text do
        local wf, wl, contents = text:find('%[%[([^%[%]\n]-)%]%]', offset)
        local mf, ml, label, destination = text:find('(%b[])(%b())', offset)
        if wf and (not mf or wf <= mf) then
            out[#out + 1] = text:sub(offset, wf - 1)
            local path, alias = contents:match('^([^|]*)|(.*)$')
            out[#out + 1] = '[[' .. target(path or contents, 'wiki') .. (alias and '|' .. alias or '') .. ']]'
            offset = wl + 1
        elseif mf then
            out[#out + 1] = text:sub(offset, mf - 1)
            out[#out + 1] = label .. '(' .. target(destination:sub(2, -2), 'markdown') .. ')'
            offset = ml + 1
        else
            out[#out + 1] = text:sub(offset)
            break
        end
    end
    return table.concat(out), count
end

local function read_bytes(path)
    local file, err = io.open(path, 'rb')
    if not file then error(err) end
    local bytes = file:read('*a')
    file:close()
    return bytes
end

local function write_bytes(path, bytes)
    local file, err = io.open(path, 'wb')
    if not file then error(err) end
    local ok, why = file:write(bytes)
    local closed, close_err = file:close()
    if not ok or not closed then error(why or close_err) end
end

local function rename_page(buf, old, new)
    if not api.nvim_buf_is_valid(buf) or api.nvim_buf_get_name(buf) ~= old then
        error('page changed while the rename prompt was open')
    end
    if uv.fs_lstat(new) or vim.fn.bufnr(new) ~= -1 then error('destination already exists') end
    local stat = uv.fs_lstat(old)
    if not stat or stat.type ~= 'file' then error('save the page to a regular file before renaming') end

    local disk, buffers, total = {}, {}, 0
    if config.link_updates.on_rename ~= false then
        local loaded = {}
        for _, b in ipairs(api.nvim_list_bufs()) do
            if api.nvim_buf_is_loaded(b) and vim.bo[b].buftype == '' then
                loaded[absolute(api.nvim_buf_get_name(b))] = b
            end
        end
        local function inside(path)
            return path:sub(1, #wiki_root + (wiki_root == '/' and 0 or 1)) ==
                wiki_root .. (wiki_root == '/' and '' or '/')
        end
        local function visit(path)
            local bytes = read_bytes(path)
            if bytes:find('\0', 1, true) then return end
            local changed, n = rewrite_links(bytes, path, old, new)
            if n > 0 then disk[#disk + 1] = { path = path, before = bytes, after = changed } end
            if not loaded[path] then total = total + n end
        end
        local function crawl(dir)
            local scan, err = uv.fs_scandir(dir)
            if not scan then error(err) end
            while true do
                local name, kind = uv.fs_scandir_next(scan)
                if not name then break end
                local path = dir .. (dir == '/' and '' or '/') .. name
                if kind == 'directory' then crawl(path)
                elseif kind == 'file' then visit(path) end
            end
        end
        crawl(wiki_root)
        for path, b in pairs(loaded) do
            local st = uv.fs_lstat(path)
            if inside(path) and (not st or st.type == 'file') then
                local lines = api.nvim_buf_get_lines(b, 0, -1, false)
                local changed, n = rewrite_links(table.concat(lines, '\n'), path, old, new)
                total = total + n
                if n > 0 then
                    if not vim.bo[b].modifiable then error('buffer is not modifiable: ' .. path) end
                    buffers[#buffers + 1] = {
                        buf = b,
                        before = lines,
                        after = vim.split(changed, '\n', { plain = true }),
                        modified = vim.bo[b].modified,
                    }
                end
            end
        end
    end

    local renamed, err = uv.fs_rename(old, new)
    if not renamed then error(err) end
    local written, edited = {}, {}
    local ok, failure = pcall(function()
        api.nvim_buf_set_name(buf, new)
        for _, entry in ipairs(disk) do
            entry.actual = entry.path == old and new or entry.path
            written[#written + 1] = entry
            write_bytes(entry.actual, entry.after)
        end
        for _, entry in ipairs(buffers) do
            edited[#edited + 1] = entry
            api.nvim_buf_set_lines(entry.buf, 0, -1, false, entry.after)
            vim.bo[entry.buf].modified = entry.modified
        end
    end)
    if not ok then
        local errors = {}
        local function rollback(fn)
            local success, why = pcall(fn)
            if not success then errors[#errors + 1] = tostring(why) end
        end
        for _, entry in ipairs(written) do
            rollback(function() write_bytes(entry.actual, entry.before) end)
        end
        for _, entry in ipairs(edited) do
            rollback(function()
                api.nvim_buf_set_lines(entry.buf, 0, -1, false, entry.before)
                vim.bo[entry.buf].modified = entry.modified
            end)
        end
        rollback(function() assert(uv.fs_rename(new, old)) end)
        rollback(function() api.nvim_buf_set_name(buf, old) end)
        error(tostring(failure) .. (#errors > 0 and
            '\nRollback errors: ' .. table.concat(errors, '; ') or ' (rolled back)'))
    end
    for _, stack in pairs(history) do
        for _, origin in ipairs(stack) do
            if origin.path == old then origin.path = new end
        end
    end
    if config.update_links_on_rename ~= false then
        vim.notify(('Updated %d links in folder %s'):format(total, wiki_root))
    else
        vim.notify(('Renamed page to %s'):format(new))
    end
end

function dwiki.rename()
    local buf = api.nvim_get_current_buf()
    if not enabled(buf) then return end
    remember_root(buf)
    local old = api.nvim_buf_get_name(buf)
    if old == '' or vim.bo[buf].buftype ~= '' then return problem('page has no filename') end

    local stem = vim.fn.fnamemodify(old, ':t:r')
    vim.ui.input({ prompt = 'New page name: ', default = stem }, function(name)
        if name == nil then return end
        name = vim.trim(name)
        if name == '' or name == stem then return end
        if name == '.' or name == '..' or name:find('[/\\%[%]|#?<>:"%c]') then
            return problem('enter a filename, not a path; unsupported filename characters')
        end
        if config.lowercase then name = name:lower() end
        if config.whitespace ~= false then
            name = name:gsub('%s+', function() return config.whitespace end)
        end
        if not name:match('%.[^%.]+$') then
            local ext = vim.fn.fnamemodify(old, ':e')
            if ext ~= '' then name = name .. '.' .. ext end
        end
        local new = vim.fn.fnamemodify(old, ':h') .. '/' .. name
        if new == old then return end
        local ok, err = pcall(rename_page, buf, old, new)
        if not ok then problem(err) end
    end)
end

function dwiki.delete()
    local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    if not enabled(buf) then return end
    local path = api.nvim_buf_get_name(buf)
    if path == '' or vim.bo[buf].buftype ~= '' then return problem('page has no filename') end
    local tick = api.nvim_buf_get_changedtick(buf)
    local prompt = 'Delete ' .. path .. '?' .. (vim.bo[buf].modified and ' Unsaved changes will be discarded.' or '')
    vim.ui.input({ prompt = prompt .. ' (y/N): ' }, function(answer)
        if not answer then return end
        answer = vim.trim(answer):lower()
        if answer ~= 'y' and answer ~= 'yes' then return end
        if not api.nvim_buf_is_valid(buf) or api.nvim_buf_get_name(buf) ~= path or
            api.nvim_buf_get_changedtick(buf) ~= tick then return problem('page changed; please retry deletion') end
        if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
            local navigated, why = pcall(api.nvim_win_call, win, function()
                local stack = history[win] or {}
                while #stack > 0 do
                    local origin = stack[#stack]
                    local loaded = api.nvim_buf_is_valid(origin.buf) and api.nvim_buf_is_loaded(origin.buf)
                    if origin.buf == buf or origin.path == path or
                        (not loaded and (origin.path == '' or not uv.fs_stat(origin.path))) then
                        table.remove(stack)
                    else
                        dwiki.back()
                        break
                    end
                end
                if api.nvim_get_current_buf() == buf then
                    local blank = api.nvim_create_buf(true, false)
                    vim.cmd('hide buffer ' .. blank)
                end
            end)
            if not navigated then return problem(why) end
        end
        local ok, err = uv.fs_unlink(path)
        if not ok then
            if api.nvim_win_is_valid(win) then
                pcall(api.nvim_win_call, win, function() vim.cmd('hide buffer ' .. buf) end)
            end
            return problem(err)
        end
        for _, stack in pairs(history) do
            for i = #stack, 1, -1 do
                if stack[i].buf == buf or stack[i].path == path then table.remove(stack, i) end
            end
        end
        local removed, why = pcall(api.nvim_buf_delete, buf, { force = true })
        if not removed then return problem('file deleted, but buffer could not be closed: ' .. tostring(why)) end
        vim.notify('dwiki: Deleted ' .. path)
    end)
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
    if config.rename_key then map('n', config.rename_key, dwiki.rename, 'dwiki: Rename page') end
    if config.delete_key then map('n', config.delete_key, dwiki.delete, 'dwiki: Delete page') end
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
    local keys = { [api.nvim_replace_termcodes('<BS>', true, false, true)] = true }
    for _, option in ipairs({ 'link_key', 'rename_key', 'delete_key' }) do
        local key = next_config[option]
        assert(key == false or (type(key) == 'string' and key ~= ''),
            'dwiki: ' .. option .. ' must be a nonempty string or false')
        if key then
            local expanded = key:gsub('<[Ll][Ee][Aa][Dd][Ee][Rr]>', function() return vim.g.mapleader or '\\' end)
            expanded = api.nvim_replace_termcodes(expanded, true, false, true)
            assert(not keys[expanded], 'dwiki: page/link keys must be distinct and cannot use Backspace')
            keys[expanded] = true
        end
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
    api.nvim_create_user_command('DwikiRename', dwiki.rename, { desc = 'Rename wiki page and update links' })
    api.nvim_create_user_command('DwikiDelete', dwiki.delete, { desc = 'Delete wiki page' })
    api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile', 'BufEnter' }, {
        group = group, callback = function(ev) remember_root(ev.buf) end,
    })
    -- Buffer IDs preserve creation order when setup is lazy-loaded.
    local initial_buffers = api.nvim_list_bufs()
    table.sort(initial_buffers)
    for _, buf in ipairs(initial_buffers) do remember_root(buf) end

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
