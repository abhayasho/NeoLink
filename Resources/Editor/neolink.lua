-- A small, isolated editor configuration. No plugin manager or user startup files.
vim.opt.runtimepath = {vim.env.VIMRUNTIME, vim.fs.normalize(vim.env.VIMRUNTIME..'/../../../lib/nvim')}
vim.opt.packpath = {}
vim.o.termguicolors = true
vim.o.background = 'dark'
vim.o.number = true
vim.o.mouse = 'a'
vim.o.hidden = true
vim.o.showmode = false
vim.o.showtabline = 0
vim.o.laststatus = 2
vim.o.signcolumn = 'yes:1'
vim.o.updatetime = 300
vim.o.timeoutlen = 400
vim.o.expandtab = true
vim.o.shiftwidth = 4
vim.o.softtabstop = 4
vim.o.smartindent = true
vim.o.ignorecase = true
vim.o.smartcase = true
vim.o.wrap = false
vim.o.undofile = false
vim.o.swapfile = false
vim.o.backup = false
vim.o.writebackup = true
vim.o.modeline = false
vim.o.exrc = false
vim.o.autoread = false
vim.o.clipboard = 'unnamedplus'
vim.o.completeopt = 'menu,menuone,noselect,popup'
vim.o.statusline = '  %f %m%r %= %y  %l:%c  %p%% '
vim.g.loaded_netrwPlugin = 1
vim.g.loaded_remote_plugins = 1
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_node_provider = 0
vim.cmd('filetype plugin indent on')
vim.cmd('syntax enable')
for group, colors in pairs({
  Normal={fg='#d8d8d8',bg='#171717'}, NormalNC={fg='#d8d8d8',bg='#171717'},
  NormalFloat={fg='#d8d8d8',bg='#202020'}, FloatBorder={fg='#484848',bg='#202020'},
  LineNr={fg='#787878',bg='#171717'}, CursorLineNr={fg='#c4c4c4',bold=true},
  CursorLine={bg='#1e1e1e'}, Cursor={fg='#171717',bg='#d8d8d8'},
  SignColumn={bg='#171717'}, EndOfBuffer={fg='#383838',bg='#171717'},
  StatusLine={fg='#a0a0a0',bg='#1c1c1c'}, StatusLineNC={fg='#787878',bg='#1c1c1c'},
  WinSeparator={fg='#303030',bg='#171717'}, VertSplit={fg='#303030',bg='#171717'},
  Visual={bg='#343434'}, Comment={fg='#858585',italic=true}, String={fg='#b6bfa7'},
  Statement={fg='#b1bfc4'}, Type={fg='#c4b49c'}, Function={fg='#d2d2d2'},
  Constant={fg='#c4ad96'}, Identifier={fg='#d8d8d8'}, Special={fg='#bbaabc'},
  PreProc={fg='#b1bfc4'}, Delimiter={fg='#b0b0b0'}, Operator={fg='#c4c4c4'},
  NonText={fg='#646464'}, Whitespace={fg='#383838'}, SpecialKey={fg='#787878'},
  Pmenu={fg='#d8d8d8',bg='#242424'}, PmenuSel={fg='#eeeeee',bg='#3b3b3b'},
  PmenuSbar={bg='#242424'}, PmenuThumb={bg='#535353'},
  Search={fg='#e2dac6',bg='#494332'}, IncSearch={fg='#171717',bg='#c6b28e'},
  CurSearch={fg='#171717',bg='#c6b28e'}, MatchParen={bg='#3b3b3b',bold=true},
  DiagnosticError={fg='#cc9595'}, DiagnosticWarn={fg='#c6b28e'},
  DiagnosticInfo={fg='#a4b8c5'}, DiagnosticHint={fg='#a0a0a0'},
  DiagnosticUnderlineError={sp='#cc9595',undercurl=true},
  DiagnosticUnderlineWarn={sp='#c6b28e',undercurl=true},
  DiagnosticUnderlineInfo={sp='#a4b8c5',undercurl=true},
  DiagnosticUnderlineHint={sp='#a0a0a0',undercurl=true},
  Error={fg='#e1b4b4',bg='#382626'}, ErrorMsg={fg='#cc9595'}, WarningMsg={fg='#c6b28e'},
  Todo={fg='#c6b28e',bold=true}, Title={fg='#d8d8d8',bold=true},
  Directory={fg='#c4c4c4'}, MoreMsg={fg='#a4b29b'}, Question={fg='#c4c4c4'},
  DiffAdd={bg='#283128'}, DiffDelete={fg='#cc9595',bg='#382626'},
  DiffChange={bg='#2d3033'}, DiffText={bg='#41454a'},
}) do vim.api.nvim_set_hl(0,group,colors) end

local api, uv = vim.api, vim.uv
local M = {baseline={}, previous={}, closed={}, pending=false}
_G.NeoLink = M
local status_path = vim.env.NEOLINK_STATUS_FILE
local function signature(path)
  local s = uv.fs_stat(path)
  return s and table.concat({s.dev,s.ino,s.size,s.mtime.sec,s.mtime.nsec}, ':') or 'missing'
end
function M.snapshot()
  M.revision=(M.revision or 0)+1
  local buffers, unnamed = {}, false
  for _,buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].buflisted then
      local path = api.nvim_buf_get_name(buf)
      if path == '' then unnamed = unnamed or vim.bo[buf].modified
      else
        local clients = vim.lsp.get_clients({bufnr=buf})
        local names = {}
        for _,c in ipairs(clients) do table.insert(names,c.name) end
        table.insert(buffers,{path=path,modified=vim.bo[buf].modified,filetype=vim.bo[buf].filetype,
          servers=table.concat(names,', '),diagnostics=#vim.diagnostic.get(buf),buf=buf})
      end
    end
  end
  return {revision=M.revision,buffers=buffers,active=api.nvim_buf_get_name(0),mode=api.nvim_get_mode().mode,unnamedModified=unnamed}
end
function M.publish()
  if not status_path or M.pending then return end
  M.pending = true
  vim.defer_fn(function()
    M.pending=false
    local temporary=status_path..'.tmp'
    local f=io.open(temporary,'w')
    if f then f:write(vim.json.encode(M.snapshot())); f:close(); os.rename(temporary,status_path) end
  end,80)
end
local function canonical(path)
  return uv.fs_realpath(path) or ((uv.fs_realpath(vim.fs.dirname(path)) or vim.fs.dirname(path))..'/'..vim.fs.basename(path))
end
local function buffer(path)
  -- bufnr(string) also accepts a pattern; filenames must be matched literally.
  local target=canonical(path)
  for _,b in ipairs(api.nvim_list_bufs()) do
    local name=api.nvim_buf_get_name(b)
    if name~='' and canonical(name)==target then return b end
  end
end
function M.open(path, line, activate)
  local b=vim.fn.bufadd(path)
  vim.fn.bufload(b)
  vim.bo[b].buflisted=true
  if not M.baseline[b] then M.baseline[b]=signature(path) end
  if activate~=false then
    api.nvim_set_current_buf(b)
    if line and line>0 then api.nvim_win_set_cursor(0,{math.min(line,api.nvim_buf_line_count(b)),0}) end
    vim.cmd('startinsert')
  end
  M.publish()
end
function M.save(path)
  local b=buffer(path)
  if not b then error('The file is no longer open in the editor.') end
  if M.baseline[b] and signature(path) ~= M.baseline[b] then
    error('File changed outside NeoLink. Use :saveas another-name to preserve your edits.')
  end
  api.nvim_buf_call(b,function() vim.cmd('silent write') end)
  M.baseline[b]=signature(path)
  M.publish()
end
function M.close(path)
  local b=buffer(path)
  if b then api.nvim_buf_delete(b,{force=true}); M.baseline[b]=nil end
  for _,client in ipairs(vim.lsp.get_clients()) do
    if vim.tbl_isempty(client.attached_buffers) then client:stop() end
  end
  M.publish()
end
function M.action(action)
  local actions={
    definition=vim.lsp.buf.definition,references=vim.lsp.buf.references,hover=vim.lsp.buf.hover,
    rename=vim.lsp.buf.rename,codeAction=vim.lsp.buf.code_action,
    format=function() vim.lsp.buf.format({async=true,timeout_ms=2000}) end,
    diagnostics=function() vim.diagnostic.setloclist({open=true}) end,
    undo=function() vim.cmd('undo'); vim.cmd('startinsert') end,
    redo=function() vim.cmd('redo'); vim.cmd('startinsert') end,
    selectAll=function() vim.cmd('stopinsert'); vim.cmd('normal! ggVG') end,
    copy=function()
      local mode=api.nvim_get_mode().mode
      vim.cmd('normal! "+'..((mode=='v' or mode=='V' or mode=='\22') and 'y' or 'yy'))
    end,
    cut=function()
      local mode=api.nvim_get_mode().mode
      vim.cmd('normal! "+'..((mode=='v' or mode=='V' or mode=='\22') and 'd' or 'dd'))
      vim.cmd('startinsert')
    end,
    find=function() vim.cmd('stopinsert'); api.nvim_feedkeys('/', 'n', false) end,
    complete=function() vim.lsp.completion.get() end,
  }
  if actions[action] then actions[action]() end
  M.publish()
end
function M.dispatch(json)
  local ok,err=pcall(function()
    local request=vim.json.decode(json)
    if request.method=='open' then M.open(request.path,request.line,request.activate)
    elseif request.method=='save' then M.save(request.path)
    elseif request.method=='close' then M.close(request.path)
    elseif request.method=='action' then M.action(request.action) end
  end)
  return vim.json.encode({ok=ok,error=ok and '' or tostring(err),state=M.snapshot()})
end
api.nvim_create_autocmd({'BufEnter','BufModifiedSet','BufWritePost','ModeChanged','LspAttach','LspDetach','DiagnosticChanged'}, {callback=M.publish})
api.nvim_create_autocmd('BufReadPost',{callback=function(ev) M.baseline[ev.buf]=signature(api.nvim_buf_get_name(ev.buf)) end})
api.nvim_create_autocmd('BufWritePost',{callback=function(ev) M.baseline[ev.buf]=signature(api.nvim_buf_get_name(ev.buf)) end})
api.nvim_create_autocmd('FileType',{callback=function(ev)
  local path=api.nvim_buf_get_name(ev.buf)
  local size=(uv.fs_stat(path) or {}).size or 0
  if size > 2*1024*1024 then
    vim.bo[ev.buf].syntax='OFF'; vim.bo[ev.buf].undolevels=100; return
  end
  local lang=vim.treesitter.language.get_lang(vim.bo[ev.buf].filetype)
  if lang then pcall(vim.treesitter.start,ev.buf,lang) end
end})
vim.diagnostic.config({virtual_text=false,signs=true,underline=true,update_in_insert=false,severity_sort=true})
api.nvim_create_autocmd('LspAttach',{callback=function(ev)
  local client=vim.lsp.get_client_by_id(ev.data.client_id)
  if client and client:supports_method('textDocument/completion') then
    vim.lsp.completion.enable(true,client.id,ev.buf,{autotrigger=true})
  end
end})
local servers={
  {name='sourcekit',cmd={'sourcekit-lsp'},types={'swift'},markers={'Package.swift','.git'}},
  {name='clangd',cmd={'clangd','--background-index=false','--clang-tidy=false','-j=2'},types={'c','cpp','objc','objcpp'},markers={'compile_commands.json','CMakeLists.txt','.git'}},
  {name='pyright',cmd={'pyright-langserver','--stdio'},types={'python'},markers={'pyproject.toml','setup.py','.git'},settings={python={analysis={diagnosticMode='openFilesOnly',autoSearchPaths=true,typeCheckingMode='basic'}}}},
  {name='typescript',cmd={'typescript-language-server','--stdio'},types={'javascript','javascriptreact','typescript','typescriptreact'},markers={'tsconfig.json','jsconfig.json','package.json','.git'}},
  {name='rust-analyzer',cmd={'rust-analyzer'},types={'rust'},markers={'Cargo.toml','.git'}},
  {name='gopls',cmd={'gopls'},types={'go'},markers={'go.mod','.git'}},
}
for _,server in ipairs(servers) do
  if vim.fn.executable(server.cmd[1])==1 then
    api.nvim_create_autocmd('FileType',{pattern=server.types,callback=function(ev)
      local path=api.nvim_buf_get_name(ev.buf)
      if ((uv.fs_stat(path) or {}).size or 0)>2*1024*1024 then return end
      local root=vim.fs.root(path,server.markers) or vim.fs.dirname(path)
      vim.lsp.start({name=server.name,cmd=server.cmd,root_dir=root,settings=server.settings,
        flags={debounce_text_changes=300},capabilities={workspace={didChangeWatchedFiles={dynamicRegistration=false}}}}, {bufnr=ev.buf})
    end})
  end
end
vim.keymap.set({'i','n'},'<C-s>',function() local ok,err=pcall(M.save,api.nvim_buf_get_name(0)); if not ok then vim.notify(err,vim.log.levels.ERROR) end end)
vim.keymap.set('n','gd',vim.lsp.buf.definition)
vim.keymap.set('n','gr',vim.lsp.buf.references)
vim.keymap.set('n','K',vim.lsp.buf.hover)
vim.keymap.set('n','<F2>',vim.lsp.buf.rename)
vim.keymap.set('i','<C-Space>',function() if #vim.lsp.get_clients({bufnr=0})>0 then vim.lsp.completion.get() else api.nvim_feedkeys(api.nvim_replace_termcodes('<C-n>',true,false,true),'n',false) end end)
api.nvim_create_autocmd('VimEnter',{callback=M.publish})
