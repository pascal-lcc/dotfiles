vim.pack.add({
    { src = "https://github.com/stevearc/conform.nvim" },
})

local ft_indent_map = {
    javascript = 2,
    typescript = 2,
    javascriptreact = 2,
    typescriptreact = 2,
    vue = 2,
    html = 2,
    css = 2,
    json = 2,
    lua = 2,

    python = 4,
    php = 4,
    c = 4,
    cpp = 4,
}

local DEFAULT_INDENT_WIDTH = 4

vim.api.nvim_create_autocmd("FileType", {
    pattern = vim.tbl_keys(ft_indent_map),
    callback = function(args)
        local width = ft_indent_map[args.match] or DEFAULT_INDENT_WIDTH
        vim.bo.tabstop = width
        vim.bo.shiftwidth = width
        vim.bo.expandtab = true
    end,
})

-- ============================================================================
-- conform.nvim (自動格式化)
-- ============================================================================
local ok_conform, conform = pcall(require, "conform")
if ok_conform then
    conform.setup({
        -- 1. 指定不同語言要用什麼排版工具
        formatters_by_ft = {
            lua = { "stylua" },
            python = { "black" },
            javascript = { "prettierd" },
            typescript = { "prettierd" },
            javascriptreact = { "prettierd" },
            typescriptreact = { "prettierd" },
            vue = { "prettierd" },
            json = { "prettierd" },
            html = { "prettierd" },
            css = { "prettierd" },
            markdown = { "prettierd" },
        },
        -- 2. 設定「存檔時自動格式化」
        -- format_on_save = {
        --     timeout_ms = 500, -- 超過 0.5 秒沒排好就先放棄，絕對不卡住存檔動作
        --     lsp_fallback = true, -- 如果沒裝對應的 Formatter，就自動退回用 LSP 內建的排版
        -- },
        formatters = {
            stylua = {
                prepend_args = {
                    "--indent-type",
                    "Spaces", -- 強制改成空格
                    "--indent-width",
                    "4", -- 縮排長度設為 2 (也可改 "4")
                },
            },
        },
        prettierd = {
            prepend_args = function(self, ctx)
                local ft = vim.bo[ctx.buf].filetype
                -- 直接去頂層的 ft_indent_map 查值！有對應就用，沒有就用預設 4
                local width = ft_indent_map[ft] or DEFAULT_INDENT_WIDTH
                return { "--tab-width", tostring(width) }
            end,
        },
    })

    -- 3. （可選）加一個手動排版的快捷鍵
    vim.keymap.set({ "n", "v" }, "<leader>mp", function()
        conform.format({ async = true, lsp_fallback = true })
    end, { desc = "Format file or range" })

    vim.keymap.set("n", "<leader>mf", function()
        vim.g.disable_autoformat = not vim.g.disable_autoformat
        if vim.g.disable_autoformat then
            print("Autoformat-on-save: DISABLED")
        else
            print("Autoformat-on-save: ENABLED")
        end
    end, { desc = "Toggle Autoformat on Save" })
end
