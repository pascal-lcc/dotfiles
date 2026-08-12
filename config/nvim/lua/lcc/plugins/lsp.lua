local ptool = require("lcc.tools")
local log = ptool.log("~/nvim.log")

_G.log = log

vim.pack.add({
    { src = "https://github.com/saghen/blink.cmp", version = vim.version.range("1.*") },
}, {
    load = function(plug_data)
        vim.api.nvim_create_autocmd("InsertEnter", {
            once = true,
            callback = function()
                vim.cmd.packadd(plug_data.spec.name)
                require("blink.cmp").setup({
                    keymap = { preset = "super-tab" },
                    sources = {
                        default = { "lsp", "path", "snippets", "buffer" },
                    },
                })
            end,
        })
    end,
})

vim.lsp.log.set_level(vim.lsp.log.levels.ERROR)
-- vim.lsp.log.set_level(vim.lsp.log.levels.OFF)

local is_windows = vim.fn.has("win32") == 1
local path_sep = is_windows and "\\" or "/"
local path_concat = is_windows and ";" or ":"
local nvim_data_path = vim.fn.stdpath("data") -- Linux: ~/.local/share/nvim  |  Windows: ~/AppData/Local/nvim-data
local mason_bin = table.concat({ nvim_data_path, "mason", "bin" }, path_sep)
vim.env.PATH = mason_bin .. path_concat .. vim.env.PATH
-- vim.env.PATH = mason_bin .. ":" .. vim.env.PATH

vim.pack.add({
    { src = "https://github.com/mason-org/mason.nvim" },
    { src = "https://github.com/neovim/nvim-lspconfig" },
}, {
    load = function(plug_data)
        local original_notify = vim.notify
        -- 🌟 加上這行註解，直接讓下一行的 LSP 警告消音
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.notify = function(msg, log_level, opts)
            if msg then
                --  精準攔截：只有當訊息完全符合 "volar is deprecated" 時才消音
                if msg:match("volar is deprecated") then
                    return
                end
            end
            --  安全網：其他任何套件的升級建議、錯誤提示，100% 正常彈出，絕不漏接！
            original_notify(msg, log_level, opts)
        end
        -- =========================================================================
        local lang_config = {
            -- filetype  = { lsp_pkg = "Mason套件名", lsp_name = "LSP服務名", formatter = "格式化工具" }
            lua = { lsp_pkg = "lua-language-server", lsp_name = "lua_ls", formatter = "stylua" },
            python = { lsp_pkg = "pyright", lsp_name = "pyright", formatter = "black" },
            c = { lsp_pkg = "clangd", lsp_name = "clangd" },
            cpp = { lsp_pkg = "clangd", lsp_name = "clangd" },
            php = { lsp_pkg = "intelephense", lsp_name = "intelephense" },
            javascript = { lsp_pkg = "typescript-language-server", lsp_name = "ts_ls", formatter = "prettierd" },
            typescript = { lsp_pkg = "typescript-language-server", lsp_name = "ts_ls", formatter = "prettierd" },
            vue = { lsp_pkg = "vue-language-server", lsp_name = "vue_ls", formatter = "prettierd" },

            -- 🚀 新增 Bash / Shell
            sh = { lsp_pkg = "bash-language-server", lsp_name = "bashls", formatter = "shfmt" },

            -- 🚀 新增 Java
            java = {
                lsp_pkg = "jdtls",
                lsp_name = "jdtls",
                formatter = "google-java-format",
            },
        }

        -- 自動解析出所有的 FileType 監聽與 Mason 下載清單
        local filetypes = {}
        local expected_lsps = {}
        local enable_lsp_names = {}

        for ft, cfg in pairs(lang_config) do
            table.insert(filetypes, ft)
            if cfg.lsp_pkg then
                table.insert(expected_lsps, cfg.lsp_pkg)
            end
            if cfg.formatter then
                table.insert(expected_lsps, cfg.formatter)
            end
            if cfg.lsp_name then
                enable_lsp_names[cfg.lsp_name] = true
            end
        end

        vim.api.nvim_create_autocmd("FileType", {
            pattern = filetypes,
            once = true,
            callback = function(args)
                -- 讓兩個套件在第一次觸發時，一口氣把彼此都動態載入
                vim.cmd.packadd("mason.nvim")
                vim.cmd.packadd("nvim-lspconfig")

                require("mason").setup()
                local registry = require("mason-registry")

                registry.refresh(function()
                    for _, lsp_name in ipairs(expected_lsps) do
                        if not registry.is_installed(lsp_name) then
                            local p = registry.get_package(lsp_name)
                            if not p:is_installing() then
                                vim.notify(
                                    "[Mason] 偵測到未安裝的工具: "
                                        .. lsp_name
                                        .. "，正在背景自動下載...",
                                    vim.log.levels.WARN
                                )
                                p:install():once("closed", function()
                                    vim.notify(
                                        "[Mason] 🌟 " .. lsp_name .. " 下載並自動安裝成功！",
                                        vim.log.levels.INFO
                                    )
                                end)
                            end
                        end
                    end
                end)

                pcall(vim.cmd.packadd, "blink.cmp")
                local blink_ok, blink = pcall(require, "blink.cmp")
                local my_capabilities = blink_ok and blink.get_lsp_capabilities() or nil

                vim.wo.signcolumn = "yes" -- 保持圖示列開啟

                -- 🌟 最新版設定圖示的標準寫法：直接塞進 vim.diagnostic.config
                vim.diagnostic.config({
                    virtual_text = {
                        prefix = "●", -- 在程式碼行尾顯示一個小圓點提示
                        source = "if_many", -- 顯示是哪個 LSP 報錯的 (例如 intelephense)
                        -- source = "always", -- 🌟 修正：改成 always，強迫顯示是哪個 LSP 報錯
                    },
                    signs = {
                        text = {
                            [vim.diagnostic.severity.ERROR] = "󰅚", -- 把內建的 "E" 換成漂亮驚嘆號/叉叉
                            [vim.diagnostic.severity.WARN] = "󰀪",
                            [vim.diagnostic.severity.HINT] = "󰌶",
                            [vim.diagnostic.severity.INFO] = "󱀕",
                        },
                    },
                    update_in_insert = false,
                    -- update_in_insert = true,
                    underline = true,
                    severity_sort = true,
                })

                -- 加碼超能力：當你把游標停在有 "E" 的那一行時，自動彈出漂亮的漂浮視窗顯示 "Syntax error"
                vim.api.nvim_create_autocmd("CursorHold", {
                    callback = function()
                        vim.diagnostic.open_float(nil, { focusable = false, scope = "cursor" })
                    end,
                })
                -- ==========================================================

                for lsp_name, _ in pairs(enable_lsp_names) do
                    vim.lsp.config(lsp_name, { capabilities = my_capabilities })
                end

                vim.lsp.config("lua_ls", {
                    capabilities = my_capabilities, -- 注入在這裡！
                    settings = {
                        Lua = {
                            runtime = { version = "LuaJIT", path = vim.split(package.path, ";") },
                            diagnostics = { globals = { "vim" } },
                            workspace = {
                                library = vim.api.nvim_get_runtime_file("", true),
                                checkThirdParty = false,
                            },
                            format = { enable = true },
                        },
                    },
                })
                -- PHP 設定
                vim.lsp.config("intelephense", {
                    capabilities = my_capabilities, -- 讓 PHP 也能享受 blink.cmp 的極速補全
                    settings = { php = { suggest = { basic = true } } },
                })
                -- C/C++ 設定（完美歸隊！）
                vim.lsp.config("clangd", {
                    capabilities = my_capabilities, -- 讓 C/C++ 也能享受 blink.cmp 的極速補全
                })

                -- local home = vim.env.HOME or vim.fn.expand("~")
                -- local mason_packages_path = table.concat({ home, ".local", "share", "nvim", "mason", "packages" }, path_sep)
                local mason_packages_path = table.concat({ nvim_data_path, "mason", "packages" }, path_sep)
                local global_ts_lib = table.concat(
                    { mason_packages_path, "typescript-language-server", "node_modules", "typescript", "lib" },
                    path_sep
                )

                -- 修正：最新版 Vue 3 核心提供給 ts_ls 的插件路徑與名稱改變了
                local vue_plugin_path = table.concat(
                    { mason_packages_path, "vue-language-server", "node_modules", "@vue", "language-server" },
                    path_sep
                )

                -- =========================================================================
                -- 1. ts_ls 配置：這次用現代 Vue 3 插件對接，讓它自己看懂 .vue 檔案
                -- =========================================================================
                vim.lsp.config("ts_ls", {
                    capabilities = my_capabilities,
                    filetypes = { "javascript", "typescript", "javascriptreact", "typescriptreact", "vue" },
                    init_options = {
                        plugins = {
                            {
                                name = "@vue/typescript-plugin",
                                location = vue_plugin_path,
                                languages = { "vue" },
                            },
                        },
                    },
                    -- 拿掉剛才誤殺一律攔截的 handlers，讓正確的錯誤可以放行！
                })

                -- =========================================================================
                -- 2. vue_ls 配置：維持正名與官方混合模式
                -- =========================================================================
                if vim.fn.executable("vue-language-server") == 1 then
                    -- if true then
                    vim.lsp.config("vue_ls", {
                        capabilities = my_capabilities,
                        -- filetypes = { "vue" },
                        filetypes = { "javascript", "typescript", "javascriptreact", "typescriptreact", "vue" },
                        -- root_dir = vim.fs.root(0, { "package.json", "tsconfig.json", ".git" }),
                        root_dir = function(bufnr)
                            local root =
                                vim.fs.root(bufnr or 0, { "package.json", "tsconfig.json", "jsconfig.json", ".git" })
                            if root and root ~= vim.fn.getcwd() then
                                vim.fn.chdir(root) -- 🚀 偷懶單開檔案時，自動把 terminal 工作目錄校正回根目錄
                            end
                            return root
                        end,
                        init_options = {
                            vue = { hybridMode = true },
                            typescript = { tsdk = global_ts_lib },
                        },
                    })
                else
                    vim.notify("vue-language-server 未就緒或正在由 Mason 安裝中...", vim.log.levels.WARN)
                end

                local lsp_enable_list = {}
                for lsp_name, _ in pairs(enable_lsp_names) do
                    table.insert(lsp_enable_list, lsp_name)
                end
                vim.lsp.enable(lsp_enable_list)
            end,
        })
    end,
})

-- vim.lsp.enable({ "lua_ls", "pyright", "clangd", "intelephense", "ts_ls", "volar" })
-- vim.lsp.enable({ "lua_ls", "pyright", "clangd", "intelephense", "ts_ls", "vue_ls" })

vim.o.mouse = "a"
-- vim.o.updatetime = 500

vim.api.nvim_create_autocmd("LspAttach", {
    callback = function(args)
        local opts = { buffer = args.buf }
        vim.keymap.set("n", "gd", vim.lsp.buf.definition, opts)
        vim.keymap.set("n", "gr", vim.lsp.buf.references, opts)

        vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
            buffer = args.buf,
            callback = function()
                local cur_win = vim.api.nvim_get_current_win()
                local cfg = vim.api.nvim_win_get_config(cur_win)
                if not (cfg.relative and cfg.relative ~= "") then
                    local mouse_pos = vim.fn.getmousepos()
                    vim.lsp.buf.hover({ focusable = true, focus = false, border = "rounded" })
                end
            end,
        })
    end,
})

vim.pack.add({
    -- { src = "https://github.com/nvim-mini/mini.nvim" }
    { src = "https://github.com/nvim-mini/mini.pick" },
})

local ok, mini_pick = pcall(require, "mini.pick")
if ok then
    mini_pick.setup({
        options = { use_cache = true },
        window = { config = { border = "double" } },
        -- source = { choose = function(item) return item end, },
        -- mappings = {
        --     choose            = '<CR>',  -- Enter 直接打開
        --     choose_in_tab     = '<C-t>', -- Ctrl+t 分頁打開
        --     choose_in_split   = '<C-x>', -- Ctrl+x 水平分開
        --     choose_in_vsplit  = '<C-v>', -- Ctrl+v 垂直開
        --     move_down         = '<C-n>', -- Ctrl+n 往下選
        --     move_up           = '<C-p>', -- Ctrl+p 往上選
        -- },
    })

    local stdpath = vim.fn.stdpath("cache") -- 放在 Neovim 的快取目錄下
    local rg_app_only = stdpath .. "/rg_app_onlyrc"
    local rg_everything = stdpath .. "/rg_everythingrc"
    -- 寫入「日常乾淨版」控制中心（排除 node_modules 和 .git）
    local f1 = io.open(rg_app_only, "w")
    if f1 then
        f1:write("--glob=!node_modules\n--glob=!.git\n")
        f1:close()
    end

    -- 寫入「全域深挖版」控制中心（什麼都不排除，連隱藏檔都吃）
    local f2 = io.open(rg_everything, "w")
    if f2 then
        f2:write("--no-ignore\n--hidden\n")
        f2:close()
    end

    vim.keymap.set("n", "<leader>ff", function()
        vim.env.RIPGREP_CONFIG_PATH = rg_app_only
        mini_pick.builtin.files()
    end, { desc = "Find Files (App Only)" })

    vim.keymap.set("n", "<leader>fg", function()
        -- 內文搜尋也一樣聽控制中心的話
        vim.env.RIPGREP_CONFIG_PATH = rg_app_only
        mini_pick.builtin.grep_live()
    end, { desc = "Find Text (App Only)" })

    vim.keymap.set("n", "<leader>fF", function()
        -- 切換到全域版控制中心，解除封印！
        vim.env.RIPGREP_CONFIG_PATH = rg_everything
        mini_pick.builtin.files()
    end, { desc = "Find Files (EVERYTHING)" })

    vim.keymap.set("n", "<leader>fG", function()
        vim.env.RIPGREP_CONFIG_PATH = rg_everything
        mini_pick.builtin.grep_live()
    end, { desc = "Find Text (EVERYTHING)" })

    vim.keymap.set("n", "<leader>fb", function()
        mini_pick.builtin.buffers()
    end, { desc = "Pick Open Buffers" })

    vim.keymap.set("n", "<leader>fr", function()
        local success, err = pcall(function()
            require("mini.pick").builtin.resume()
        end)
        if not success then
            vim.notify("目前沒有上一次的搜尋紀錄可供回復！", vim.log.levels.INFO)
        end
    end, { desc = "Resume Last Pick" })

    vim.keymap.set("n", "<leader>tc", "<cmd>tabclose<cr>", { desc = "Close Current Tab" })
    vim.keymap.set("n", "H", "<cmd>bprevious<cr>", { desc = "Buffer (左)" })
    vim.keymap.set("n", "L", "<cmd>bnext<cr>", { desc = "Buffer (右)" })
    vim.keymap.set("n", "[t", "<cmd>tabprevious<cr>", { desc = "上一個 Tab" })
    vim.keymap.set("n", "]t", "<cmd>tabnext<cr>", { desc = "下一個 Tab" })
    vim.keymap.set("n", "<leader>bd", "<cmd>bdelete<cr>", { desc = "Delete Buffer" })
    -- vim.keymap.set('n', 'H', '<cmd>tabprevious<cr>', { desc = '上一個分頁' })
    -- vim.keymap.set('n', 'L', '<cmd>tabnext<cr>', { desc = '下一個分頁' })
else
    vim.notify("mini.pick 尚未下載完成或路徑未就緒...", vim.log.levels.WARN)
end

-- vim.keymap.set('n', '<Esc>', function()
--     local current_win = vim.api.nvim_get_current_win()
--     local win_config = vim.api.nvim_win_get_config(current_win)
--     if win_config.relative and win_config.relative ~= "" then
--         vim.api.nvim_win_close(current_win, true)
--         return
--     end
--     local esc_key = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)
--     vim.api.nvim_feedkeys(esc_key, 'n', false)
-- end, { silent = true })

-- =========================================================================
-- 🥇 終極滑鼠神裝：右側隨點隨換 + 左側狀態定錨不位移（完美完成版）
-- =========================================================================

local function handle_mouse_jump(mouse, is_insert, do_vsplit)
    -- 📸 一點擊的瞬間，在最乾淨的當下，立刻拍下左邊主視窗與游標位置快照
    local origin_win = vim.api.nvim_get_current_win()
    local origin_buf = vim.api.nvim_get_current_buf()
    local saved_cursor = vim.api.nvim_win_get_cursor(origin_win)
    local saved_view = vim.fn.winsaveview()

    vim.schedule(function()
        -- 1. 關閉點擊的那個浮動提示窗（如果真的有開浮動窗的話）
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local config = vim.api.nvim_win_get_config(win)
            if config.relative and config.relative ~= "" then
                pcall(vim.api.nvim_win_close, win, true)
            end
        end

        -- 2. 處理 Insert 模式恢復
        if is_insert then
            vim.cmd("stopinsert")
            vim.api.nvim_create_autocmd("BufEnter", {
                once = true,
                callback = function()
                    vim.cmd("startinsert")
                end,
            })
        end

        -- 3. 智慧分屏與目標視窗鎖定
        local target_win = origin_win

        if do_vsplit then
            local wins = vim.api.nvim_tabpage_list_wins(0)
            local code_wins = {}
            for _, w in ipairs(wins) do
                local config = vim.api.nvim_win_get_config(w)
                if not config.relative or config.relative == "" then
                    table.insert(code_wins, w)
                end
            end

            -- 🌟 情況 A：如果右邊已經有現成分屏了
            if #code_wins > 1 then
                for _, w in ipairs(code_wins) do
                    if w ~= origin_win then
                        target_win = w
                        break
                    end
                end
            else
                -- 🌟 情況 B：如果只有單一畫面，強制向右劈開
                local old_splitright = vim.o.splitright
                vim.o.splitright = true
                vim.cmd("vsplit")
                target_win = vim.api.nvim_get_current_win()
                vim.o.splitright = old_splitright
            end
        end

        -- 4. 關鍵防錯：不管有沒有開 vsplit，我們都在發動 LSP 前確保座標精準定錨
        if target_win and vim.api.nvim_win_is_valid(target_win) then
            vim.api.nvim_set_current_win(target_win)
            -- 如果是要倒進右邊的分屏，強行把右邊填上當前 Buffer 與精準游標，保證 LSP 絕不迷路
            if target_win ~= origin_win then
                vim.api.nvim_win_set_buf(target_win, origin_buf)
                vim.api.nvim_win_set_cursor(target_win, saved_cursor)
            else
                -- 普通單擊（原地跳轉），也確保游標死死定在點擊的位置
                vim.api.nvim_win_set_cursor(origin_win, saved_cursor)
            end
        end

        -- 5. 落地後狀態強制回溯還原（徹底封死左邊跳頂 Bug）
        vim.api.nvim_create_autocmd("BufEnter", {
            once = true,
            callback = function()
                if vim.api.nvim_win_is_valid(origin_win) then
                    vim.api.nvim_win_set_buf(origin_win, origin_buf)
                    vim.api.nvim_win_set_cursor(origin_win, saved_cursor)
                    local cur = vim.api.nvim_get_current_win()
                    vim.api.nvim_set_current_win(origin_win)
                    vim.fn.winrestview(saved_view)
                    vim.api.nvim_set_current_win(cur)
                end
            end,
        })

        -- 6. 正式發動 LSP 跳轉
        vim.lsp.buf.definition()
    end)
end

local LeftRelease_handlers = {

    -- ---------------------------------------------------------------------
    -- 2. 浮動視窗跳轉 Handler (你原本的核心邏輯 A)
    -- ---------------------------------------------------------------------
    function(mouse, info)
        local is_click_float = false
        if mouse.winid > 0 and vim.api.nvim_win_is_valid(mouse.winid) then
            local win_config = vim.api.nvim_win_get_config(mouse.winid)
            if win_config.relative and win_config.relative ~= "" then
                is_click_float = true
            end
        end

        if is_click_float then
            handle_mouse_jump(mouse, info.is_insert, false)
            return true -- 🎯 已處理，中斷鏈條
        end
        return false -- 🔄 未命中，放行給下一個 handler
    end,

    -- ---------------------------------------------------------------------
    -- 3. 普通文字視窗定位 Handler (你原本的核心邏輯 B)
    -- ---------------------------------------------------------------------
    function(mouse, info)
        if mouse.winid == info.main_win and mouse.line > 0 then
            vim.api.nvim_win_set_cursor(info.main_win, { mouse.line, mouse.column - 1 })
            if info.is_insert then
                vim.cmd("startinsert")
            end
            return true
        end
        return false
    end,
}

for _, handler in ipairs(LeftRelease_handlers) do
    table.insert(ptool.LeftRelease_handlers, #ptool.LeftRelease_handlers + 1, handler)
end

vim.keymap.set({ "n", "i" }, "<C-LeftRelease>", function()
    local mouse = vim.fn.getmousepos()
    local current_mode = vim.api.nvim_get_mode().mode
    local is_insert = (current_mode:sub(1, 1) == "i")

    local is_click_float = false
    if mouse.winid > 0 and vim.api.nvim_win_is_valid(mouse.winid) then
        local win_config = vim.api.nvim_win_get_config(mouse.winid)
        if win_config.relative and win_config.relative ~= "" then
            is_click_float = true
        end
    end

    if is_click_float then
        handle_mouse_jump(mouse, is_insert, true) -- 🚀 限制數量的分屏跳轉
    else
        if mouse.winid == vim.api.nvim_get_current_win() and mouse.line > 0 then
            vim.api.nvim_win_set_cursor(0, { mouse.line, mouse.column - 1 })
            if is_insert then
                vim.cmd("startinsert")
            end
        end
    end
end)

vim.api.nvim_create_autocmd("ModeChanged", {
    pattern = "n:i", -- 偵測從 Normal (n) 切換到 Insert (i) 的瞬間
    callback = function()
        -- 撈出目前所有的視窗，只要是浮動窗就立刻關閉，還主視窗一個乾淨的輸入環境
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local config = vim.api.nvim_win_get_config(win)
            if config.relative and config.relative ~= "" then
                pcall(vim.api.nvim_win_close, win, true)
            end
        end
    end,
})

vim.keymap.set("n", "gD", function()
    -- 呼叫我們上一輪寫好的大圓滿版 handle_mouse_jump
    -- 模擬滑鼠傳入的 argument：mouse.winid = 當前視窗, is_insert = false, do_vsplit = true
    handle_mouse_jump({ winid = vim.api.nvim_get_current_win() }, false, true)
end, { desc = "LSP vsplit definition (Keyboard)" })
