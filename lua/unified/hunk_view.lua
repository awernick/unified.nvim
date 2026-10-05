-- Structured hunk state for consumers outside the display pipeline.
-- display_inline_diff parses full hunk objects (old/new ranges + prefixed
-- lines) but previously discarded them, keeping only hunk start lines in
-- hunk_store. This module keeps the structured form so integrations (e.g. the
-- opencode ACP "explain hunk" flow) can resolve the hunk under the cursor
-- without scraping diff text out of buffers.

local M = {}

local state = {} -- bufnr -> { hunk, ... } with old_start/old_count/new_start/new_count/lines

function M.set(bufnr, hunks)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  state[bufnr] = hunks
end

function M.clear(bufnr)
  state[bufnr] = nil
end

function M.get(bufnr)
  local hunks = state[bufnr]
  if hunks == nil then
    return nil
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    state[bufnr] = nil
    return nil
  end
  return hunks
end

--- Resolve the hunk the cursor is on, using unified's inline-view semantics:
--- the buffer shows the new side exactly (deleted lines are virtual and do not
--- consume buffer lines), so the cursor maps to new-file line numbers. Pure
--- deletion hunks (new_count == 0) resolve via the deleted-new-file anchor or
--- the line above, matching hunk_actions' stage/unstage/revert behavior.
---
---@param bufnr integer
---@param cursor_line integer 1-based buffer line
---@return table|nil hunk nil when no hunk is displayed or the cursor is outside all of them
function M.hunk_at_cursor(bufnr, cursor_line)
  local hunks = M.get(bufnr)
  if not hunks or cursor_line == 0 then
    return nil
  end
  for _, h in ipairs(hunks) do
    if h.new_count and h.new_count > 0 then
      if cursor_line >= h.new_start and cursor_line < h.new_start + h.new_count then
        return h
      end
    else
      if cursor_line == h.new_start or cursor_line == math.max(1, h.new_start - 1) then
        return h
      end
    end
  end
  return nil
end

--- Serialize a hunk as a unified diff fragment. `rel_path` fills the ---/+++
--- headers; headers are omitted when nil (callers may embed their own).
---
---@param hunk table hunk from M.get()/M.hunk_at_cursor()
---@param rel_path string|nil
---@return string text
function M.hunk_text(hunk, rel_path)
  if not hunk then
    return ""
  end
  local buff = {}
  if rel_path then
    table.insert(buff, "--- a/" .. rel_path)
    table.insert(buff, "+++ b/" .. rel_path)
  end
  table.insert(buff, ("@@ -%s,%s +%s,%s @@"):format(
    hunk.old_start or 0, hunk.old_count or 0, hunk.new_start or 0, hunk.new_count or 0))
  for _, line in ipairs(hunk.lines or {}) do
    table.insert(buff, line)
  end
  return table.concat(buff, "\n")
end

return M
