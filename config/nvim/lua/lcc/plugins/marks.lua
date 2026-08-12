-- 1. 宣告加入套件
vim.pack.add({
  { src = 'https://github.com/chentoast/marks.nvim' },
})

-- 2. 初始化
local ok_marks, marks = pcall(require, 'marks')
if ok_marks then
  marks.setup({
    default_mappings = true, -- 使用標準按鍵 (ma 建立, dm 刪除, ]' / [' 上下跳)
    cyclic = true,           -- 到了最後一個 mark 自動循環回第一個
    refresh_interval = 250,
  })
end
