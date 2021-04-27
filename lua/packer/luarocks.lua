-- Add support for installing and cleaning Luarocks dependencies
-- Based off of plenary/neorocks/init.lua in https://github.com/nvim-lua/plenary.nvim
local a = require('packer.async')
local jobs = require('packer.jobs')
local log = require('packer.log')
local result = require('packer.result')
local util = require('packer.util')

local fmt = string.format
local async = a.sync
local await = a.wait

local config = nil
local function cfg(_config) config = _config.luarocks end
local function warn_need_luajit() log.error('LuaJIT is required for Luarocks functionality!') end

local lua_version = nil
if jit then
  local jit_version = string.gsub(jit.version, 'LuaJIT ', '')
  lua_version = {lua = string.gsub(_VERSION, 'Lua ', ''), jit = jit_version, dir = jit_version}
else
  return {
    handle_command = warn_need_luajit,
    install_commands = warn_need_luajit,
    list = warn_need_luajit,
    install_hererocks = warn_need_luajit,
    setup_paths = warn_need_luajit,
    uninstall = warn_need_luajit,
    clean = warn_need_luajit,
    install = warn_need_luajit,
    ensure = warn_need_luajit,
    generate_path_setup = function() return '' end,
    cfg = cfg
  }
end

local cache_path = vim.fn.stdpath('cache')
local rocks_path = util.join_paths(cache_path, 'packer_hererocks')
local hererocks_file = util.join_paths(rocks_path, 'hererocks.py')
local hererocks_install_dir = util.join_paths(rocks_path, lua_version.dir)
local _hererocks_setup_done = false
local function hererocks_is_setup()
  if _hererocks_setup_done then return true end
  local path_info = vim.loop.fs_stat(util.join_paths(hererocks_install_dir, 'lib'))
  _hererocks_setup_done = (path_info ~= nil) and (path_info['type'] == 'directory')
  return _hererocks_setup_done
end

local function hererocks_installer(disp)
  return async(function()
    local hererocks_url = 'https://raw.githubusercontent.com/luarocks/hererocks/latest/hererocks.py'
    local hererocks_cmd
    await(a.main)
    vim.fn.mkdir(rocks_path, 'p')
    if vim.fn.executable('curl') > 0 then
      hererocks_cmd = 'curl ' .. hererocks_url .. ' -o ' .. hererocks_file
    elseif vim.fn.executable('wget') > 0 then
      hererocks_cmd = 'wget ' .. hererocks_url .. ' -O ' .. hererocks_file .. ' --verbose'
    else
      return result.err('"curl" or "wget" is required to install hererocks')
    end

    if disp ~= nil then disp:task_start('luarocks', 'installing hererocks...') end

    local output = jobs.output_table()
    local callbacks = {
      stdout = jobs.logging_callback(output.err.stdout, output.data.stdout, nil, disp, 'luarocks'),
      stderr = jobs.logging_callback(output.err.stderr, output.data.stderr)
    }

    local opts = {capture_output = callbacks}
    local r = await(jobs.run(hererocks_cmd, opts)):map_err(
                function(err)
        return {msg = 'Error installing hererocks', data = err, output = output}
      end)

    local luarocks_cmd = config.python_cmd .. ' ' .. hererocks_file .. ' --verbose -j '
                           .. lua_version.jit .. ' -r latest ' .. hererocks_install_dir
    r = r:and_then(await, jobs.run(luarocks_cmd, opts)):map_err(
          function(err) return {msg = 'Error installing luarocks', data = err, output = output} end)
    return r
  end)
end

local function package_patterns(dir)
  local sep = util.get_separator()
  return fmt('%s%s?.lua;%s%s?%sinit.lua', dir, sep, dir, sep, sep)
end

local package_paths = (function()
  local install_path = util.join_paths(hererocks_install_dir, 'lib', 'luarocks',
                                       fmt('rocks-%s', lua_version.lua))
  local share_path = util.join_paths(hererocks_install_dir, 'share', 'lua', lua_version.lua)
  return package_patterns(share_path) .. ';' .. package_patterns(install_path)
end)()

local nvim_paths_are_setup = false
local function setup_nvim_paths()
  if not hererocks_is_setup() then
    log.warn('Tried to setup Neovim Lua paths before hererocks was setup!')
    return
  end

  if nvim_paths_are_setup then
    log.warn('Tried to setup Neovim Lua paths redundantly!')
    return
  end

  if not string.find(package.path, package_paths, 1, true) then
    package.path = package.path .. ';' .. package_paths
  end

  local install_cpath = util.join_paths(hererocks_install_dir, 'lib', 'lua', lua_version.lua)
  local install_cpath_pattern = fmt('%s%s?.so', install_cpath, util.get_separator())
  if not string.find(package.cpath, install_cpath_pattern, 1, true) then
    package.cpath = package.cpath .. ';' .. install_cpath_pattern
  end

  nvim_paths_are_setup = true
end

local function generate_path_setup_code()
  local package_path_str = vim.inspect(package_paths)
  local install_cpath = util.join_paths(hererocks_install_dir, 'lib', 'lua', lua_version.lua)
  local install_cpath_pattern = fmt('"%s%s?.so"', install_cpath, util.get_separator())
  install_cpath_pattern = vim.fn.escape(install_cpath_pattern, [[\]])
  return [[
local package_path_str = ]] .. package_path_str .. [[

local install_cpath_pattern = ]] .. install_cpath_pattern .. [[

if not string.find(package.path, package_path_str, 1, true) then
  package.path = package.path .. ';' .. package_path_str
end

if not string.find(package.cpath, install_cpath_pattern, 1, true) then
  package.cpath = package.cpath .. ';' .. install_cpath_pattern
end
]]
end

local function activate_hererocks_cmd(install_path)
  local activate_file = 'activate'
  local user_shell = os.getenv('SHELL')
  local shell = user_shell:gmatch('([^/]*)$')()
  if shell == 'fish' then
    activate_file = 'activate.fish'
  elseif shell == 'csh' then
    activate_file = 'activate.csh'
  end

  return fmt('source %s', util.join_paths(install_path, 'bin', activate_file))
end

local function run_luarocks(args, disp)
  local cmd = {
    os.getenv('SHELL'), '-c',
    fmt('%s && luarocks %s', activate_hererocks_cmd(hererocks_install_dir), args)
  }
  return async(function()
    local output = jobs.output_table()
    local callbacks = {
      stdout = jobs.logging_callback(output.err.stdout, output.data.stdout, nil, disp, 'luarocks'),
      stderr = jobs.logging_callback(output.err.stderr, output.data.stderr)
    }

    local opts = {capture_output = callbacks}
    return await(jobs.run(cmd, opts)):map_err(function(err)
      return {msg = fmt('Error running luarocks %s', args), data = err, output = output}
    end):map_ok(function(data) return {data = data, output = output} end)
  end)
end

local function luarocks_install(package, results, disp)
  return async(function()
    if disp then disp:task_update('luarocks', 'installing ' .. package) end
    local install_result = await(run_luarocks('install ' .. package, disp))
    if results then results.luarocks.installs[package] = install_result end
    return install_result
  end)
end

local function install_packages(packages, results, disp)
  return async(function()
    local r = result.ok()
    if not hererocks_is_setup() then r = r:and_then(await, hererocks_installer(disp)) end
    if disp then disp:task_start('luarocks', 'installing rocks...') end
    if results then results.luarocks.installs = {} end
    for _, name in ipairs(packages) do
      r = r:and_then(await, luarocks_install(name, results, disp))
    end

    r:map_ok(function() if disp then disp:task_succeeded('luarocks', 'rocks installed!') end end)
      :map_err(function()
        if disp then disp:task_failed('luarocks', 'installing rocks failed!') end
      end)
    return r
  end)
end

--- Install the packages specified with `packages` synchronously
local function install_sync(packages)
  return async(function() return await(install_packages(packages)) end)()
end

local function chunk_output(output)
  -- Merge the output to a single line, then split again. Helps to deal with inconsistent
  -- chunking in the output collection
  local result = table.concat(output, '\n')
  return vim.split(result, '\n')
end

local function luarocks_list(disp)
  return async(function()
    local r = result.ok()
    if not hererocks_is_setup() then r = r:and_then(await, hererocks_installer(disp)) end
    r = r:and_then(await, run_luarocks('list --porcelain'))
    return r:map_ok(function(data)
      local results = {}
      local output = chunk_output(data.output.data.stdout)
      for _, line in ipairs(output) do
        for l_package, version, status, install_path in
          string.gmatch(line, "([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)") do
          table.insert(results, {
            name = l_package,
            version = version,
            status = status,
            install_path = install_path
          })
        end
      end

      return results
    end)
  end)
end

local function luarocks_show(package, disp)
  return async(function()
    local r = result.ok()
    if not hererocks_is_setup() then r = r:and_then(await, hererocks_installer(disp)) end
    r = r:and_then(await, run_luarocks('show --porcelain ' .. package))
    return r:map_ok(function(data)
      local output = chunk_output(data.output.data.stdout)
      local dependencies = {}
      for _, line in ipairs(output) do
        local components = {}
        for component in string.gmatch(line, '([^%s]+)') do
          components[#components + 1] = component
        end

        if (components[1] == 'dependency' or components[1] == 'indirect_dependency')
          and (components[2] ~= 'lua') then dependencies[components[2]] = components[2] end
      end

      return dependencies
    end)
  end)
end

local function luarocks_remove(package, results, disp)
  return async(function()
    if disp then disp:task_update('luarocks', 'removing ' .. package) end
    local remove_result = await(run_luarocks('remove ' .. package, disp))
    if results then results.luarocks.removals[package] = remove_result end
    return remove_result
  end)
end

local function uninstall_packages(packages, results, disp)
  return async(function()
    local r = result.ok()
    if not hererocks_is_setup() then r = r:and_then(await, hererocks_installer(disp)) end
    if disp then disp:task_start('luarocks', 'uninstalling rocks...') end
    if results then results.luarocks.removals = {} end
    for _, name in ipairs(packages) do
      r = r:and_then(await, luarocks_remove(name, results, disp))
    end

    r:map_ok(function() if disp then disp:task_succeeded('luarocks', 'rocks cleaned!') end end)
      :map_err(function()
        if disp then disp:task_failed('luarocks', 'cleaning rocks failed!') end
      end)
    return r
  end)
end

--- Uninstall the packages specified with `packages` synchronously
local function uninstall_sync(packages)
  return async(function() return await(uninstall_packages(packages)) end)()
end

local function clean_packages(rocks, results, disp)
  return async(function()
    local r = result.ok()
    if not hererocks_is_setup() then return r end
    r = r:and_then(await, luarocks_list(disp))
    local installed_packages
    if r.ok then
      installed_packages = r.ok
    else
      return r
    end

    local dependency_info = {}
    for _, package in ipairs(installed_packages) do
      r = r:and_then(await, luarocks_show(package.name, disp))
      if r.ok then dependency_info[package.name] = r.ok end
    end

    r = r:map_ok(function()
      local to_remove = {}
      for _, package in ipairs(installed_packages) do to_remove[package.name] = package end
      for _, rock in pairs(rocks) do
        if type(rock) == 'table' then
          if to_remove[rock[1]] and to_remove[rock[1]].version == rock[2] then
            to_remove[rock[1]] = nil
          end
        else
          to_remove[rock] = nil
        end
      end

      for rock, dependencies in pairs(dependency_info) do
        if rocks[rock] ~= nil then
          for _, dependency in pairs(dependencies) do to_remove[dependency] = nil end
        end
      end

      -- Toposort to ensure that we remove packages before their dependencies
      local removal_order = {}
      local frontier = {}
      for rock, _ in pairs(to_remove) do
        if next(dependency_info[rock]) == nil then
          frontier[#frontier + 1] = rock
          dependency_info[rock] = nil
        end
      end

      local inverse_dependencies = {}
      for rock, depends in pairs(dependency_info) do
        for d, _ in pairs(depends) do
          inverse_dependencies[d] = inverse_dependencies[d] or {}
          inverse_dependencies[d][rock] = true
        end
      end

      while #frontier > 0 do
        local rock = table.remove(frontier)
        removal_order[#removal_order + 1] = rock
        local inv_depends = inverse_dependencies[rock]
        if inv_depends ~= nil then
          for depends, _ in pairs(inverse_dependencies[rock]) do
            table.remove(dependency_info[depends])
            if #dependency_info[depends] == 0 then frontier[#frontier + 1] = depends end
          end
        end
      end

      local reverse_order = {}
      for i = #removal_order, 1, -1 do reverse_order[#reverse_order + 1] = removal_order[i] end
      return reverse_order
    end)

    if results ~= nil then results.luarocks = results.luarocks or {} end
    return r:and_then(await, uninstall_packages(r.ok, results, disp))
  end)
end

local function ensure_packages(rocks, results, disp)
  return async(function()
    local to_install = {}
    for _, rock in pairs(rocks) do
      if type(rock) == 'table' then
        to_install[rock[1]] = rock
      else
        to_install[rock] = true
      end
    end

    local r = result.ok()
    if next(to_install) == nil then return r end
    if not hererocks_is_setup() then r = r:and_then(await, hererocks_installer(disp)) end
    r = r:and_then(await, luarocks_list(disp))
    r = r:map_ok(function(installed_packages)
      for _, package in ipairs(installed_packages) do
        local spec = to_install[package.name]
        if spec then
          if type(spec) == 'table' then
            if spec[2] == package.version then to_install[package.name] = nil end
          else
            to_install[package.name] = nil
          end
        end
      end

      local package_names = {}
      for name, data in pairs(to_install) do
        if type(data) == 'table' then
          table.insert(package_names, fmt('%s %s', name, data[2]))
        else
          table.insert(package_names, name)
        end
      end

      return package_names
    end)

    results.luarocks = results.luarocks or {}
    return r:and_then(await, install_packages(r.ok, results, disp))
  end)
end

local function handle_command(cmd, ...)
  local task
  local packages = {...}
  if cmd == 'install' then
    task = install_packages(packages)
  elseif cmd == 'remove' then
    task = uninstall_packages(packages)
  else
    log.warn('Unrecognized command!')
    return result.err('Unrecognized command')
  end

  return async(function()
    local r = await(task)
    await(a.main)
    local package_names = vim.fn.escape(vim.inspect(packages), '"')
    return r:map_ok(function(data)
      local operation_name = cmd:sub(1, 1):upper() .. cmd:sub(2)
      log.info(fmt('%sed packages %s', operation_name, package_names))
      return data
    end):map_err(function(err)
      log.error(fmt('Failed to %s packages %s: %s', cmd, package_names,
                    vim.fn.escape(vim.inspect(err), '"\n')))
      return err
    end)
  end)()
end

local function make_commands()
  vim.cmd [[ command! -nargs=+ PackerRocks lua require('packer.luarocks').handle_command(<f-args>) ]]
end

return {
  handle_command = handle_command,
  install_commands = make_commands,
  list = luarocks_list,
  install_hererocks = hererocks_installer,
  setup_paths = setup_nvim_paths,
  uninstall = uninstall_sync,
  clean = clean_packages,
  install = install_sync,
  ensure = ensure_packages,
  generate_path_setup = generate_path_setup_code,
  cfg = cfg
}
