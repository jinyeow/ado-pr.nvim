std = "luajit"
globals = { "vim" }

-- Match .stylua.toml's column_width so luacheck doesn't flag lines stylua
-- itself considers fine.
max_line_length = 160

exclude_files = {
  "prototypes/",
}

-- 212: unused argument -- common and intentional in this codebase's callback
-- signatures (autocmd callbacks, vim.system() completion handlers) where the
-- full signature is kept for readability even when a given arg is unused.
-- 213: unused loop variable -- same rationale, e.g. `for i, line in ipairs(...)`
-- where only one of the two is used in a given branch.
ignore = { "212", "213" }
