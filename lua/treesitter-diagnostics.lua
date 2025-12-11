-- SPDX-License-Identifier: MIT
-- Copyright 2025 Jorenar
-- Copyright 2025 robertogrows

local M = {}

local NS = vim.api.nvim_create_namespace('editor.treesitter.diagnostics')

--- language-independent query for syntax errors and missing elements
local ERR_N_MISS = vim.treesitter.query.parse('query', '[(ERROR)(MISSING)] @_')

--- query for no errors or missing
local NONE = vim.treesitter.query.parse('query', '')

local config = {
  parsers = { -- parsers that are just problematic for this use-case
    c = NONE, -- preprocessor causes tons of errors
    cpp = NONE, -- preprocessor causes tons of errors
    dockerfile = NONE, -- outdated, can't parse COPY --link or other modern syntax
    nginx = NONE, -- doesn't handle 'upstream' and other issues
    rust = NONE, -- many errors/missing nodes
    groovy = NONE, -- many error/missing nodes
    sql = NONE, -- doesn't know specific dialects
    helm = NONE, -- many error nodes
    vim = NONE, -- many error nodes
  },
}

--- @param parser vim.treesitter.LanguageTree
--- @param query vim.treesitter.Query
--- @param diagnostics vim.Diagnostic[]
--- @param buffer integer
local diagnose_syntax = function(parser, query, diagnostics, buffer)
  local root = parser:trees()[1]:root()
  if not root:has_error() or query == NONE then
    return
  end
  for _, match in query:iter_matches(root, buffer) do
    for _, nodes in pairs(match) do
      for _, node in ipairs(nodes) do
        local lnum, col, end_lnum, end_col = node:range()

        -- collapse nested syntax errors that occur at the exact same position
        local parent = node:parent()
        if parent and parent:type() == 'ERROR' and parent:range() == node:range() then
          goto continue
        end

        -- clamp large syntax error ranges to just the line to reduce noise
        if end_lnum > lnum then
          end_lnum = lnum + 1
          end_col = 0
        end

        --- @type vim.Diagnostic
        local diagnostic = {
          severity = vim.diagnostic.severity.ERROR,
          source = 'treesitter',
          lnum = lnum,
          end_lnum = end_lnum,
          col = col,
          end_col = end_col,
          message = '',
          bufnr = buffer,
          namespace = NS,
        }

        if node:missing() then
          diagnostic.severity = vim.diagnostic.severity.WARN
          diagnostic.code = string.format('%s-missing', parser:lang())
          diagnostic.message = string.format('missing `%s`', node:type())
        else
          diagnostic.severity = vim.diagnostic.severity.ERROR
          diagnostic.code = string.format('%s-syntax', parser:lang())
          diagnostic.message = 'error'
        end

        -- add context to the error using sibling and parent nodes
        local previous = node:prev_sibling()
        if previous and previous:type() ~= 'ERROR' then
          local previous_type = previous:named() and previous:type()
              or string.format('`%s`', previous:type())
          diagnostic.message = diagnostic.message .. ' after ' .. previous_type
        end

        if parent and parent:type() ~= 'ERROR'
            and (previous == nil or previous:type() ~= parent:type())
        then
          diagnostic.message = diagnostic.message .. ' in ' .. parent:type()
        end

        table.insert(diagnostics, diagnostic)
        ::continue::
      end
    end
  end
end

--- @param buffer integer
local diagnose_buffer = function(buffer)
  if not vim.diagnostic.is_enabled({ bufnr = buffer }) then
    return
  end

  local parser = vim.treesitter.get_parser(buffer, nil, { error = false })
  if not parser then return end

  local query = vim.tbl_get(config, 'parsers', parser:lang()) or ERR_N_MISS
  if not (query and query ~= NONE) then return end

  --- @type vim.Diagnostic[]
  local diagnostics = {}
  parser:parse(false, function()
    diagnose_syntax(parser, query, diagnostics, buffer)
  end)

  -- avoid updating in common case of no problems found and no
  -- problems found before (diagnostic updates can be expensive)
  if #diagnostics > 0
      or next(vim.diagnostic.count(buffer, { namespace = NS }))
  then
    vim.diagnostic.set(NS, buffer, diagnostics)
  end
end

--- @param buffer integer?
M.enable = function(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buffer) then return end

  -- don't diagnose strange stuff
  if vim.bo[buffer].buftype ~= '' then
    return
  end

  local timer = assert(vim.uv.new_timer())
  local name = string.format('editor.syntax_%d', buffer)
  local autocmd_group = vim.api.nvim_create_augroup(name, { clear = true })

  local run = vim.schedule_wrap(function()
    diagnose_buffer(buffer)
  end)

  run()

  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    desc = '[treesitter-diagnostics] lint on text modifications',
    buffer = buffer,
    group = autocmd_group,
    callback = function()
      timer:stop()
      timer:start(200, 0, run)
    end,
  })

  vim.api.nvim_create_autocmd({ 'BufUnload' }, {
    desc = '[treesitter-diagnostics] destroy linter',
    buffer = buffer,
    group = autocmd_group,
    callback = function()
      vim.api.nvim_del_augroup_by_id(autocmd_group)
      timer:close()
    end,
  })
end

return M
