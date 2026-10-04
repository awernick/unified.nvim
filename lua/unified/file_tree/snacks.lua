local M = {}
local global_state = require("unified.state")
local tree_state = require("unified.file_tree.state")
local git = require("unified.git")

-- Focus contract for the snacks-backed tree: whenever one of the tree picker's
-- own windows (input/list) gains focus, the floating diff preview must be on
-- screen. Snacks can have hidden it during a confirm jump (auto_close = false
-- keeps the picker alive while the preview pane drops out), and refocusing
-- without this hook would leave the user looking at the raw buffer instead of
-- the patch. Registered once; cheap because a git_diff picker is rare.
local hooks_registered = false

-- A window usable as the preview float's anchor: valid, non-float, ordinary
-- buffer (buftype "" and not one of snacks' own UI buffers). Picker layout
-- parts (box/list/input) are buftype nofile/prompt, but snacks can auto-heal
-- picker.main to its layout box when the content window dies, so a plain
-- validity check is NOT enough here.
local function valid_anchor(win)
  return win
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_config(win).relative == ""
    and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
    and not vim.bo[vim.api.nvim_win_get_buf(win)].filetype:match("^snacks")
end

-- snacks caches the preview float's anchor in preview.win_opts.main.win and
-- only recomputes it in preview:update(); force that after moving the anchor.
local function reanchor_preview(picker, main_win)
  if picker.preview and picker.preview.win and picker.preview.win.opts then
    picker.preview.win_opts.main.win = main_win
    picker.preview.main = main_win
    pcall(function()
      picker.preview.win:update()
    end)
  end
end

-- The preview float anchors on the content window (snacks uses relative =
-- "win" with win = picker.main). Closing the file-buffer window (e.g. :q)
-- with the tree still open leaves that anchor dead, and every preview re-show
-- then throws "Invalid window id". Re-point the anchor: reuse the tracked
-- content window when it is valid, or create a fresh split so the tree keeps
-- working and the next preview has somewhere to live.
-- Ensure the preview float has a live anchor (returns the win id or nil).
-- fires inside close events, so the split recreation never happens in the
-- event context itself (E242): callers defer the repair when possible.
local function ensure_main_anchor(picker)
  if valid_anchor(picker.main) then
    return picker.main
  end
  if not global_state.is_active() then
    return nil
  end
  local main_win = global_state.get_main_window()
  if not valid_anchor(main_win) then
    local ok = pcall(vim.cmd, "rightbelow vsplit")
    if not ok then
      return nil
    end
    main_win = vim.api.nvim_get_current_win()
    global_state.main_win = main_win
  end
  picker.main = main_win
  reanchor_preview(picker, main_win)
  return main_win
end

-- When a split is not allowed right now (E242 inside window-close events),
-- point the preview at the editor surface instead of leaving the dead window
-- id cached: any re-show snacks schedules in the close event then stays
-- valid. The deferred anchor repair restores the win-relative anchoring.
local function detach_preview_anchor(preview)
  if not (preview and preview.win and preview.win.opts) then
    return
  end
  preview.main = nil
  preview.win_opts = preview.win_opts or {}
  preview.win_opts.main = { relative = "editor", backdrop = false, zindex = 40 }
  preview.win.opts.relative = nil
  pcall(function()
    preview.win:update()
  end)
end

local function setup_preview_hooks()
  if hooks_registered then
    return
  end
  hooks_registered = true

  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
    group = vim.api.nvim_create_augroup("unified_tree_snacks_preview", { clear = true }),
    callback = function()
      local pickers = Snacks.picker.get({ source = "git_diff", tab = false })
      local picker = pickers[1]
      if not picker then
        return
      end
      local window = vim.api.nvim_get_current_win()
      local input_win = picker.input and picker.input.win and picker.input.win.win
      local list_win = picker.list and picker.list.win and picker.list.win.win
      if window == input_win or window == list_win then
        -- The content window can die while the tree stays up (e.g. :q on the
        -- file buffer). Any preview re-show would then build its float on a
        -- dead anchor ("Invalid window id"), and window-close events forbid
        -- splitting (E242), so: drop the patch pane now (no fanfare) and run
        -- the anchor repair + re-show from a deferred context where splits
        -- are legal again.
        if not valid_anchor(picker.main) then
          if not picker.layout:is_hidden("preview") then
            pcall(function()
              picker:toggle("preview", { enable = false })
            end)
          end
          pcall(function()
            detach_preview_anchor(picker.preview)
          end)
        end
        vim.schedule(function()
          if picker.closed then
            return
          end
          local anchor = ensure_main_anchor(picker)
          if not anchor then
            return
          end
          picker:toggle("preview", { enable = true })
          vim.schedule(function()
            if not picker.closed and picker.preview then
              pcall(function()
                picker:show_preview()
              end)
            end
          end)
        end)
      end
    end,
  })
end

--- Shows the file tree using Snacks git_diff picker
--- @param commit_hash string|nil The commit hash to compare against
function M.show(commit_hash)
  local ok, snacks = pcall(require, "snacks")
  if not ok then
    vim.notify(
      "Snacks.nvim is not installed. Install folke/snacks.nvim, or use the default file tree by omitting the -s flag.",
      vim.log.levels.ERROR
    )
    return false
  end

  setup_preview_hooks()

  local file_path = vim.fn.getcwd()
  local root_dir = file_path

  -- Find git root
  local is_git_repo = git.is_git_repo(file_path)
  if is_git_repo then
    local git_root_cmd =
      string.format("cd %s && git rev-parse --show-toplevel 2>/dev/null", vim.fn.shellescape(file_path))
    local git_root = vim.trim(vim.fn.system(git_root_cmd))
    local git_entry = git_root .. "/.git"
    if
      vim.v.shell_error == 0
      and git_root ~= ""
      and (vim.fn.isdirectory(git_entry) == 1 or vim.fn.filereadable(git_entry) == 1)
    then
      root_dir = git_root
    end
  end

  if not is_git_repo then
    vim.notify("Not in a git repository", vim.log.levels.WARN)
    return false
  end

  -- Store commit reference
  tree_state.commit_ref = commit_hash
  tree_state.root_path = root_dir
  tree_state.diff_only = true
  local base = commit_hash or "HEAD"

  -- Refresh a live git_diff picker instead of replacing it: Snacks.picker.pick()
  -- closes an existing same-source instance and returns early (toggle
  -- semantics), so a blind snacks.picker(opts) call would only kill the open
  -- tree -- this is what used to wipe the tree when selecting a file or
  -- re-running :Unified with a new ref. A live instance whose windows are gone
  -- (e.g. reported after a refresh) is torn down synchronously below so the
  -- fresh instance created further down does not lose the same race. Fresh
  -- create covers the closed-tree reopen path.
  local live = snacks.picker.get({ source = "git_diff", tab = false })[1]
  if live then
    local live_win = live and live.layout and live.layout.win and live.layout.win.win
    if live_win and vim.api.nvim_win_is_valid(live_win) then
      live.opts.base = base
      live.opts.cwd = root_dir
      live:find()
      tree_state.window = live_win
      global_state.file_tree_win = live_win
      -- Preview mode belongs to being in the tree: re-enable the patch pane
      -- only when the user is exploring it (":Unified <new-ref>" from the
      -- content window must NOT drop an overlay over their buffer).
      if live:is_focused() and not live.layout:is_hidden("preview") then
        ensure_main_anchor(live)
        live:toggle("preview", { enable = true })
        vim.schedule(function()
          if not live.closed then
            live:show_preview()
          end
        end)
      end
      return true
    end
    live:close()
  end

  -- Close a stale tracked window if it is still around
  if tree_state.window and vim.api.nvim_win_is_valid(tree_state.window) then
    vim.api.nvim_win_close(tree_state.window, true)
  end

  local config = require("unified.config")
  local width = config.values.file_tree.width
  local filename_first = config.values.file_tree.filename_first

  -- Use Snacks git_diff picker with the specified base commit
  local picker_opts = {
    source = "git_diff",
    base = commit_hash or "HEAD",
    cwd = root_dir,
    group = true, -- Group changes by file (not individual hunks)
    layout = {
      preset = "sidebar",
      layout = {
        position = "left",
        width = width,
      },
    },
    formatters = {
      file = {
        filename_first = filename_first,
      },
    },
    -- Custom confirm action to show unified diff when file is selected
    -- The tree must survive selecting a file: snacks' auto_close would kill
    -- the picker the moment confirm focuses the main window, and jump.close
    -- is the default confirm's close path -- so both are disabled here.
    auto_close = false,
    jump = { close = false },
    confirm = function(picker, item)
      if not item or not item.file then
        return
      end

      -- Get or create the main window
      local main_win = global_state.get_main_window()
      if not main_win or not vim.api.nvim_win_is_valid(main_win) then
        vim.cmd("rightbelow vsplit")
        main_win = vim.api.nvim_get_current_win()
        global_state.main_win = main_win
      end

      -- Open the file in the main window
      vim.api.nvim_set_current_win(main_win)
      vim.cmd("edit " .. vim.fn.fnameescape(item.file))

      -- Show the unified diff for the current buffer
      local diff = require("unified.diff")
      diff.show_current(commit_hash)

      -- Setup auto-refresh
      local auto_refresh = require("unified.auto_refresh")
      auto_refresh.setup(vim.api.nvim_get_current_buf())

      -- Reading mode: drop the floating patch so the buffer with the inline
      -- diff highlights is visible, and keep focus there. Redirecting focus
      -- back into the picker root is what previously fought snacks' focus
      -- handling; when the user returns to the tree (mouse keyboard or
      -- ":Unified tree"), the preview comes back via the focus hook above.
      local preview_win = picker and picker.preview and picker.preview.win and picker.preview.win.win
      if preview_win and vim.api.nvim_win_is_valid(preview_win) and not picker.layout:is_hidden("preview") then
        picker:toggle("preview", { enable = false })
      end

      if config.values.file_tree.close_after_select then
        picker:close()
      end
      vim.api.nvim_set_current_win(main_win)
    end,
  }

  -- Open the git_diff picker
  local picker = snacks.picker(picker_opts)

  if picker and picker.layout and picker.layout.win then
    tree_state.window = picker.layout.win.win
    global_state.file_tree_win = picker.layout.win.win
  end

  return true
end

--- Close the Snacks file tree
function M.close()
  if tree_state.window and vim.api.nvim_win_is_valid(tree_state.window) then
    vim.api.nvim_win_close(tree_state.window, true)
  end
  tree_state.window = nil
  global_state.file_tree_win = nil
end

return M
