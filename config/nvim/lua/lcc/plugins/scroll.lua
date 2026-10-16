--------------------------------------------------
-- nvim-scrollbar version
--------------------------------------------------
local install_path = vim.fn.stdpath("data") .. "/pack/plugins/opt/nvim-scrollbar"

local scrollbar_ref = "refactor/v2"
local scrollbar_api = "v2"
local handle_color = "#565f89"

if vim.fn.empty(vim.fn.glob(install_path)) > 0 then
    vim.fn.system({
        "git",
        "clone",
        "--depth",
        "1",
        "--branch",
        scrollbar_ref,
        "https://github.com/petertriho/nvim-scrollbar",
        install_path,
    })

    if vim.v.shell_error ~= 0 then
        vim.notify("nvim-scrollbar 下載失敗", vim.log.levels.ERROR)
        return
    end
end

vim.opt.rtp:append(install_path)


local configs = {
    v1 = function()
        vim.api.nvim_set_hl(0, "ScrollBarHandle", { bg = "#565f89", ctermbg = "DarkGray" })
        require("scrollbar").setup({
            show = true,
            set_winblend = 0,

            -- 🎯 大絕招 1：把 folds 設定成一個極大的數字，等同於直接停用折疊計算
            folds = 99999,

            handle = {
                text = " ",
                color = nil,
                blend = 0,
            },

            -- 🎯 大絕招 2：把所有可能出現的內建 Marks 文字全塞進去，通通強制換成空格 " "
            marks = {
                Search = { text = { " ", " " }, priority = 1, color = "#ff9e64" },
                Error = { text = { " ", " " }, priority = 2, color = "#db4b4b" },
                Warning = { text = { " ", " " }, priority = 3, color = "#e0af68" },
                Info = { text = { " ", " " }, priority = 4, color = "#0db9d7" },
                Hint = { text = { " ", " " }, priority = 5, color = "#1abc9c" },
                Misc = { text = { " ", " " }, priority = 6, color = "#7aa2f7" },
                Cursor = { text = " ", priority = 0 }, -- 游標點也換成空，不吃文字
            },

            -- 🎯 大絕招 3：徹底關掉所有自動搜集資訊的後台 handlers
            handlers = {
                cursor = false,
                diagnostics = false,
                gitsigns = false,
                search = false,
                ale = false,
            },
            excluded_buftypes = { "terminal", "nofile" },
            excluded_filetypes = { "cmp_menu", "noice", "prompt" },
        })
    end,

    v2 = function()
        require("scrollbar").setup({
            set_highlights = true,

            -- v2：排除指定的 buffer 類型與檔案類型
            exclude = {
                buftypes = {
                    terminal = true,
                    nofile = true,
                },
                filetypes = {
                    cmp_menu = true,
                    noice = true,
                    prompt = true,
                },
            },

            -- 不收集任何標記
            providers = {
                cursor = false,
                diagnostic = false,
                gitsigns = false,
                search = false,
                ale = false,
            },

            -- 各類標記全部改成空白
            marks = {
                Cursor = {
                    text = " ",
                    priority = 0,
                },
                Search = {
                    text = { " ", " " },
                    priority = 1,
                    highlight = { fg = "#ff9e64" },
                },
                Error = {
                    text = { " ", " " },
                    priority = 2,
                    highlight = { fg = "#db4b4b" },
                },
                Warn = {
                    text = { " ", " " },
                    priority = 3,
                    highlight = { fg = "#e0af68" },
                },
                Info = {
                    text = { " ", " " },
                    priority = 4,
                    highlight = { fg = "#0db9d7" },
                },
                Hint = {
                    text = { " ", " " },
                    priority = 5,
                    highlight = { fg = "#1abc9c" },
                },
                Misc = {
                    text = { " ", " " },
                    priority = 6,
                    highlight = { fg = "#7aa2f7" },
                },
            },

            -- v2 的滑塊設定
            scrollbar = {
                unit = "line",
                show = true,
                thumb = {
                    text = " ",
                    blend = 0,
                    highlight = {
                        bg = handle_color,
                        ctermbg = "DarkGray",
                    },
                },
            },
        })
    end,
}

local setup = configs[scrollbar_api]

if not setup then
    error("不支援的 nvim-scrollbar API: " .. scrollbar_api)
end

setup()

