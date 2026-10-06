-- Tests for lua/unified/propose.lua: scratch-buffer diff display for
-- agent-proposed changes (below split, window reuse, read-only rendering).

local M = {}

local propose = require("unified.propose")

local function buf_lines(b)
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

function M.test_renders_diff_text_in_named_scratch_buffer()
  local text = table.concat({
    "diff --git a/test.txt b/test.txt",
    "--- a/test.txt",
    "+++ b/test.txt",
    "@@ -1,2 +1,2 @@",
    " keep",
    "-old",
    "+new",
  }, "\n")
  local b, w = propose.show_diff_text(text, "opencode: proposal 1")

  assert(vim.api.nvim_buf_is_valid(b), "propose buffer valid")
  assert(vim.bo[b].filetype == "diff", "filetype is diff")
  assert(vim.bo[b].modifiable == false, "buffer is read-only")
  assert(vim.bo[b].buftype == "nofile", "scratch buffer")
  assert(vim.api.nvim_buf_get_name(b):find("unified://propose/", 1, true) ~= nil, "named scratch buffer")
  assert(vim.api.nvim_win_get_buf(w) == b, "window shows the propose buffer")

  local lines = buf_lines(b)
  assert(#lines == 7, "all 7 diff lines rendered, got " .. #lines)
  assert(lines[6] == "-old" and lines[7] == "+new", "content verbatim including +/- prefixes")
  return true
end

function M.test_title_chars_are_sanitized()
  local b = propose.show_diff_text("context\n+added\n", "src/app.ts:42 (fix)")
  assert(vim.api.nvim_buf_is_valid(b), "buffer valid")
  local name = vim.api.nvim_buf_get_name(b)
  assert(name:find(" ", 1, true) == nil and name:find("%(", 1) == nil, "specials replaced: " .. name)
  assert(name:find("src_app", 1, true) ~= nil and name:find("42", 1, true) ~= nil, "readable sanitized title")
  return true
end

function M.test_second_call_reuses_window_and_replaces_buffer()
  local b1, w1 = propose.show_diff_text("+first\n", "first")
  local b2, w2 = propose.show_diff_text("+second\n+more\n", "second")

  assert(w2 == w1, "propose window is reused, got " .. tostring(w2) .. " vs " .. tostring(w1))
  assert(not vim.api.nvim_buf_is_valid(b1), "old propose buffer wiped on replace")
  assert(vim.api.nvim_win_get_buf(w2) == b2, "window displays the new buffer")

  local lines = buf_lines(b2)
  assert(#lines == 2 and lines[1] == "+second" and lines[2] == "+more", "new content shown")
  return true
end

function M.test_recovers_after_manual_window_close()
  local b1, w1 = propose.show_diff_text("+one\n", "one")
  -- Simulate the user closing the propose window (bufhidden=wipe kills b1).
  vim.api.nvim_win_close(w1, true)
  assert(not vim.api.nvim_buf_is_valid(b1), "buffer wiped when its window closed")

  local b2, w2 = propose.show_diff_text("+two\n", "two")
  assert(vim.api.nvim_buf_is_valid(b2), "new buffer after close/reopen")
  assert(w2 ~= w1, "a fresh window is opened")
  assert(vim.api.nvim_win_get_buf(w2) == b2, "fresh window shows the fresh buffer")
  vim.api.nvim_win_close(w2, true)
  return true
end

function M.test_rejects_empty_text()
  local ok, err = pcall(propose.show_diff_text, "", "empty")
  assert(not ok, "empty text must error")
  assert(tostring(err):find("non%-empty", 1) ~= nil, "error mentions non-empty, got " .. tostring(err))
  local ok2 = pcall(propose.show_diff_text, nil, "nil")
  assert(not ok2, "nil text must error")
  return true
end

return M
