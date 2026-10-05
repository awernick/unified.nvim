-- Tests for lua/unified/hunk_view.lua: structured hunk state kept for
-- out-of-process integrations (opencode_acp "explain hunk"), including
-- cursor resolution with unified's inline-view semantics.

local M = {}

local utils = require("test.test_utils")
local hunk_view = require("unified.hunk_view")
local git = require("unified.git")

-- Show the HEAD diff for `buffer` and wait for structured hunks to appear.
-- The diff jobs are async, so poll like the extmark-based tests do.
local function show_diff_and_wait(buffer)
  git.show_git_diff_against_commit("HEAD", buffer)
  local deadline = vim.loop.now() + 5000
  while vim.loop.now() < deadline do
    local hunks = hunk_view.get(buffer)
    if hunks and #hunks > 0 then
      return hunks
    end
    vim.wait(50)
  end
  return nil
end

function M.test_modified_hunk_resolves_and_serializes()
  local repo = utils.create_git_repo()
  if not repo then
    return true
  end
  utils.create_and_commit_file(repo, "test.txt", { "keep 1", "old middle", "keep 3" }, "Initial")
  vim.cmd("edit " .. repo.repo_dir .. "/test.txt")
  local buf = vim.api.nvim_get_current_buf()
  assert(hunk_view.get(buf) == nil, "no hunks expected before the diff is shown")

  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "new middle" })
  local hunks = show_diff_and_wait(buf)
  assert(hunks ~= nil, "structured hunks should appear after display")

  -- cursor on the new middle line (buffer line 2) resolves the hunk
  local hunk = hunk_view.hunk_at_cursor(buf, 2)
  assert(hunk ~= nil, "hunk at cursor line 2")
  assert(hunk.lines[1] == " keep 1", "context line kept verbatim, got " .. vim.inspect(hunk.lines[1]))
  assert(hunk.lines[2] == "-old middle", "old line prefixed, got " .. vim.inspect(hunk.lines[2]))
  assert(hunk.lines[3] == "+new middle", "new line prefixed, got " .. vim.inspect(hunk.lines[3]))

  local text = hunk_view.hunk_text(hunk, "test.txt")
  assert(text:find("--- a/test.txt", 1, true) == 1, "diff fragment starts with file headers")
  assert(text:find("+++ b/test.txt", 1, true) ~= nil, "fragment has the +++ header")
  assert(text:find("@@", 1, true) ~= nil, "fragment has a hunk header")
  assert(text:find("-old middle", 1, true) ~= nil and text:find("+new middle", 1, true) ~= nil)

  -- the hunk's new-side range covers its context lines too (1..3 for a
  -- 3-line file with a middle change); only lines beyond the buffer fail
  assert(hunk_view.hunk_at_cursor(buf, 1) ~= nil, "context line 1 belongs to the hunk range")
  assert(hunk_view.hunk_at_cursor(buf, 3) ~= nil, "context line 3 belongs to the hunk range")
  assert(hunk_view.hunk_at_cursor(buf, 99) == nil, "line beyond the buffer resolves to nothing")
  assert(hunk_view.hunk_at_cursor(buf, 0) == nil)
  utils.cleanup_git_repo(repo)
  return true
end

function M.test_added_hunk_clears_on_rediff()
  local repo = utils.create_git_repo()
  if not repo then
    return true
  end
  utils.create_and_commit_file(repo, "test.txt", { "one", "two" }, "Initial")
  vim.cmd("edit " .. repo.repo_dir .. "/test.txt")
  local buf = vim.api.nvim_get_current_buf()

  vim.api.nvim_buf_set_lines(buf, 1, 1, false, { "inserted" })
  local hunks = show_diff_and_wait(buf)
  assert(hunks ~= nil, "structured hunks should appear")
  local hunk = hunk_view.hunk_at_cursor(buf, 2)
  assert(hunk ~= nil, "added line at buffer line 2 resolves")
  local found_added = false
  for _, line in ipairs(hunk.lines) do
    if line == "+inserted" then
      found_added = true
    end
  end
  assert(found_added, "added line present in the hunk: " .. vim.inspect(hunk.lines))

  -- revert the edit and re-diff: the stored hunks must reflect the new display
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, {})
  show_diff_and_wait(buf)
  assert(hunk_view.hunk_at_cursor(buf, 2) == nil, "stale hunk must not survive a re-diff")
  utils.cleanup_git_repo(repo)
  return true
end

function M.test_deleted_file_synthesizes_single_hunk()
  local repo = utils.create_git_repo()
  if not repo then
    return true
  end
  utils.create_and_commit_file(repo, "departed.txt", { "line one", "line two" }, "Initial")
  local buf = vim.api.nvim_create_buf(false, true)
  require("unified.diff").display_deleted_file(buf, "line one\nline two\n")
  local hunks = hunk_view.get(buf)
  assert(hunks ~= nil and #hunks == 1, "deleted file keeps one synthetic hunk")
  local hunk = hunk_view.hunk_at_cursor(buf, 1)
  assert(hunk ~= nil and hunk.new_count == 0, "deleted file hunk is deletion-only")
  assert(hunk.lines[1] == "-line one" and hunk.lines[2] == "-line two", vim.inspect(hunk.lines))
  local text = hunk_view.hunk_text(hunk, "departed.txt")
  assert(text:find("-line one", 1, true) ~= nil)
  utils.cleanup_git_repo(repo)
  return true
end

return M
