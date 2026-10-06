-- Scratch-buffer diff display for agent-proposed changes (opencode nvim
-- driver). Renders a unified-diff TEXT into a read-only named buffer shown
-- in a below-split, reusing the previous propose window so consecutive
-- proposals replace each other instead of stacking splits.

local M = {}

local win = nil -- tracked propose window id
local buf = nil -- tracked propose buffer id (deleted on replace)

local function is_propose_buffer(b)
  return b
    and vim.api.nvim_buf_is_valid(b)
    and vim.b[b].unified_propose == true
end

--- Find the tracked propose window, or any window currently showing one.
local function find_propose_window()
  if win and vim.api.nvim_win_is_valid(win) and is_propose_buffer(vim.api.nvim_win_get_buf(win)) then
    return win
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_propose_buffer(vim.api.nvim_win_get_buf(w)) then
      return w
    end
  end
  return nil
end

function M.show_diff_text(text, title)
  if type(text) ~= "string" or text == "" then
    error("unified.propose: text must be a non-empty string")
  end

  -- New scratch buffer replaces the previous one; any old buffer is only
  -- deleted after the reused window has been switched away from it, since
  -- force-deleting a displayed buffer closes its windows.
  local ok, name = pcall(function()
    return "unified://propose/" .. (title or "diff"):gsub("[^%w%-%_%.]", "_")
  end)
  name = ok and name or "unified://propose/diff"

  local old_buf = buf
  buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].unified_propose = true

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "diff"

  local content = vim.split(text, "\n", { plain = true })
  -- Drop one trailing empty element from a text ending in \n; buffers always
  -- keep at least one line.
  if #content > 1 and content[#content] == "" then
    content[#content] = nil
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  local lines = #content
  local height = math.min(20, math.max(5, lines + 1))

  local existing = find_propose_window()
  if existing then
    win = existing
    vim.api.nvim_win_set_buf(win, buf)
  else
    win = vim.api.nvim_open_win(buf, false, {
      split = "below",
      height = height,
    })
  end
  vim.wo[win].wrap = false
  vim.wo[win].number = true

  -- Free the name before taking it: leftover buffers with the same title
  -- (e.g. abandoned runs) would trip E95 in nvim_buf_set_name.
  local stale = vim.fn.bufnr(name)
  if stale ~= -1 and stale ~= buf then
    pcall(vim.api.nvim_buf_delete, stale, { force = true })
  end
  vim.api.nvim_buf_set_name(buf, name)

  if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
    pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
  end

  return buf, win
end

return M
