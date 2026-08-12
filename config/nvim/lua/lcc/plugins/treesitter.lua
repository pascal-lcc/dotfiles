-- 1. 載入 Treesitter
-- :TSInstall vue typescript javascript html css lua c cpp php python bash
vim.pack.add({
    { src = "https://github.com/nvim-treesitter/nvim-treesitter" },
})

local ok, ts = pcall(require, "nvim-treesitter.configs")
if ok then
    ts.setup({
        ensure_installed = { "vue", "typescript", "javascript", "html", "css", "lua", "vim", "vimdoc" },

        sync_install = false,
        auto_install = true,

        highlight = {
            enable = true,
            additional_vim_regex_highlighting = false,
        },
        indent = {
            enable = true,
        },
    })
end

local ts_fold_group = vim.api.nvim_create_augroup("TSFoldGroup", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
    group = ts_fold_group,
    callback = function()
        local buf = vim.api.nvim_get_current_buf()
        local has_parser = pcall(vim.treesitter.get_parser, buf)

        if has_parser then
            vim.wo.foldmethod = "expr"
            vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
            vim.wo.foldlevel = 99
            vim.opt.foldcolumn = "1"
            -- 設定折疊顯示的特殊符號（例如用漂亮的箭頭代替預設的加減號）
            vim.opt.fillchars = {
                foldopen = "", -- 展開時的符號（需要 Nerd Font 字型支援）
                foldclose = "", -- 折疊時的符號
                fold = " ", -- 折疊後後面留白的填充字元
                foldsep = " ",
            }
        end
    end,
})

-- 【Visual 模式下的一鍵 Zoom 術】
-- 選取範圍後按 `f`：自動切換成手動折疊模式並建立折疊
vim.keymap.set("v", "zf", function()
    local current_method = vim.wo.foldmethod
    if current_method == "expr" then
        vim.wo.foldmethod = "manual"
        -- 貼心地在下方狀態列提醒你目前變成手動控制了
        print("已切換至手動折疊模式 (Manual)")
    end
    vim.cmd("normal! zf")
end, { desc = "Visual 模式下手動折疊選取區域" })

-- 【一鍵還原 Treesitter 自動折疊】
-- 在 Normal 模式下按 `<leader>t` 瞬間切回 Treesitter 控制
vim.keymap.set("n", "<leader>fz", function()
    vim.opt.foldmethod = "expr"
    vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
    print("已切回 Treesitter 自動折疊模式")
end, { desc = "重設為 Treesitter 自動折疊" })
