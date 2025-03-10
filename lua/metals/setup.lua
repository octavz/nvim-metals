local api = vim.api
local lsp = vim.lsp

local commands_table = require("metals.commands").commands_table
local conf = require("metals.config")
local log = require("metals.log")
local util = require("metals.util")

local lsps = {}

-- So by default metals starts automatically, however, if a user wants it not
-- to, then this needs to be set to true in order for Metals to continually
-- attach in a workspace that MetalsStartServer was called on.
local explicity_enabled = false

local function in_disabled_mode(config)
  if conf.in_disabled_mode(config) and not explicity_enabled then
    return true
  else
    return false
  end
end

local function explicitly_enable()
  explicity_enabled = true
end

--- Clear out the lsps table. This is used when we are restarting the server
--- and aren't - planning on closing nvim, but rather just re-connecting.
local function reset_lsps()
  lsps = {}
end

-- A bare config to use to be passed into initialize_or_attach.
-- This is meant only to be used when a user is editing anything in the config
-- just to ensure they don' thave to do a couple manual initialization of tables
local function bare_config()
  return { handlers = {}, init_options = { compilerOptions = {} }, settings = {}, tvp = {} }
end

local function add_commands()
  for _, cmd in pairs(commands_table) do
    local vim_cmd = util.camel_to_pascal(cmd.id)
    vim.cmd(string.format([[command! Metals%s lua require'metals'.%s()]], vim_cmd, cmd.id))
  end
end

-- Checks to ensure that you're not in a buffer that a plugin opens up. There
-- are situations like `:GdiffSplit` which will open up a buffer that still has
-- a scala filetype and ends in `.scala`, however we don't want Metals to
-- attatch to that buffer. For now, we just have a hard list here and will add
-- as we come across them.
local function invalid_scala_file()
  local name = vim.api.nvim_buf_get_name(0)
  if not vim.loop.fs_stat(name) then
    return true
  else
    return false
  end
end

local function initialize_or_attach(config)
  -- If config is nil we try to retrieve the config cache. This is useful for
  -- when you restart the server, which then instead of pulling from your
  -- config, just pulls from the cached config
  config = config or conf.get_config_cache()

  if invalid_scala_file() then
    return
  end

  -- Make sure to add the commands _before_ we check for diabled mode, if not
  -- the user can't then use the mapping to turn on the server if they are in
  -- disabled mode.
  add_commands()

  if in_disabled_mode(config) then
    conf.set_config_cache(config)
    return
  end

  local current_buf = api.nvim_get_current_buf()

  -- Check to see if Metals is already attatched, and if so attatch
  for _, buf in pairs(vim.fn.getbufinfo({ bufloaded = true })) do
    if vim.tbl_contains(conf.scala_file_types, api.nvim_buf_get_option(buf.bufnr, "filetype")) then
      local clients = lsp.buf_get_clients(buf.bufnr)
      for _, client in ipairs(clients) do
        if client.config.name == config.name then
          lsp.buf_attach_client(current_buf, client.id)
          return true
        end
      end
    end
  end

  local valid_config = conf.validate_config(config, current_buf)

  if valid_config then
    local client_id = lsps[config.root_dir]
    if not client_id then
      client_id = lsp.start_client(valid_config)
      lsps[config.root_dir] = client_id
    end
    lsp.buf_attach_client(current_buf, client_id)
  end
end

--- Setup function used to ensure that when using nvim-dap the
--- metals.debug-adapter-start is called and the host correctly returned.
local function setup_dap(execute_command)
  local status, dap = pcall(require, "dap")
  if not status then
    log.error_and_show("Unable to find nvim-dap. Please make sure mfussenegger/nvim-dap is installed.")
    return
  end

  dap.adapters.scala = function(callback, config)
    local uri = vim.uri_from_bufnr(0)
    local metals_dap_settings = config.metals or {}
    execute_command({
      command = "metals.debug-adapter-start",
      arguments = {
        path = uri,
        runType = metals_dap_settings.runType or "run",
        args = metals_dap_settings.args,
        jvmOptions = metals_dap_settings.jvmOptions,
        env = metals_dap_settings.env,
        envFile = metals_dap_settings.envFile,
      },
    }, function(_, _, res)
      -- In metals we throw various exceptions when handling
      -- debug-adapter-start but they are all handled and status messages are
      -- given to the client, so they aren't errors here. That's why we don't
      -- really capture or care about the err and instead just make sure res is
      -- there and not null.
      if res then
        local port = util.split_on(res.uri, ":")[3]

        callback({
          type = "server",
          host = "127.0.0.1",
          port = port,
          options = {
            -- The default in nvim-dap is 4, which is too short for Metals.
            initialize_timeout_sec = 10,
          },
          enrich_config = function(_config, on_config)
            local final_config = vim.deepcopy(_config)
            -- Just in case strip this out since it's metals-specific
            final_config.metals = nil
            on_config(final_config)
          end,
        })
      end
    end)
  end
end

return {
  bare_config = bare_config,
  explicitly_enable = explicitly_enable,
  initialize_or_attach = initialize_or_attach,
  reset_lsps = reset_lsps,
  setup_dap = setup_dap,
}
