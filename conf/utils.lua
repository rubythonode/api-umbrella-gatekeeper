local _M = {}

local cjson = require "cjson"
local cmsgpack = require "cmsgpack"
local inspect = require "inspect"
local plutils = require "pl.utils"
local stringx = require "pl.stringx"
local types = require "pl.types"

local escape = plutils.escape
local is_empty = types.is_empty
local json_null = cjson.null
local pack = cmsgpack.pack
local split = plutils.split
local strip = stringx.strip
local unpack = cmsgpack.unpack

-- Determine if the table is an array.
--
-- In benchmarks, appears faster than moses.isArray implementation.
function _M.is_array(obj)
  if type(obj) ~= "table" then return false end

  local count = 1
  for key, _ in pairs(obj) do
    if key ~= count then
      return false
    end
    count = count + 1
  end

  return true
end

-- Append an array to the end of the destination array.
--
-- In benchmarks, appears faster than moses.append and pl.tablex.move
-- implementations.
function _M.append_array(dest, src)
  if type(dest) ~= "table" or type(src) ~= "table" then return end

  dest_length = #dest
  src_length = #src
  for i=1, src_length do
    dest[dest_length + i] = src[i]
  end

  return dest
end

function _M.base_url()
  local protocol = ngx.ctx.protocol
  local host = ngx.ctx.host
  local port = ngx.ctx.port

  local base = protocol .. "://" .. host
  if (protocol == "http" and port ~= "80") or (protocol == "https" and port ~= "443") then
    if not host:find(":" .. port .. "$") then
      base = base .. ":" .. port
    end
  end

  return base
end

function _M.get_packed(dict, key)
  local packed = dict:get(key)
  if packed then
    return unpack(packed)
  end
end

function _M.set_packed(dict, key, value)
  return dict:set(key, pack(value))
end

function _M.pick_where_present(dict, keys)
  local selected = {}

  if type(dict) == "table" and type(keys) == "table" then
    for _, key in ipairs(keys) do
      if dict[key] and dict[key] ~= false and dict[key] ~= json_null then
        selected[key] = dict[key]
      end
    end
  end

  return selected
end

function _M.deep_merge_overwrite_arrays(dest, src)
  if not src then return dest end

  for key, value in pairs(src) do
    if type(value) == "table" and type(dest[key]) == "table" then
      if _M.is_array(value) then
        dest[key] = value
      else
        _M.deep_merge_overwrite_arrays(dest[key], src[key])
      end
    else
      dest[key] = value
    end
  end

  return dest
end

function _M.merge_settings(dest, src)
  if not src then return dest end

  -- Specially handle merging the query args to append. This attribute should
  -- actually overwrite any previous values, but since the cached value is
  -- parsed as a table, we have to explicitly overwrite it, rather than relying
  -- on our deep merge.
  if not is_empty(src["_append_query_args"]) then
    dest["_append_query_args"] = src["_append_query_args"]
  end

  return _M.deep_merge_overwrite_arrays(dest, src)
end

local function lowercase_settings_header_keys(settings, headers_key)
  local computed_headers_key = "_" .. headers_key
  if not is_empty(settings[headers_key]) then
    settings[computed_headers_key] = {}
    for _, header in ipairs(settings[headers_key]) do
      if header["key"] then
        header["key"] = string.lower(header["key"])
      end

      table.insert(settings[computed_headers_key], header)
    end
  end
  settings[headers_key] = nil
end

function _M.cache_computed_settings(settings)
  if not settings then return end

  -- Parse and cache the allowed IPs as CIDR ranges.
  if not is_empty(settings["allowed_ips"]) then
    settings["_allowed_ips"] = settings["allowed_ips"]
  end
  settings["allowed_ips"] = nil

  -- Parse and cache the allowed referers as matchers
  if not is_empty(settings["allowed_referers"]) then
    settings["_allowed_referer_matchers"] = {}
    for _, referer in ipairs(settings["allowed_referers"]) do
      local matcher = escape(referer)
      matcher = string.gsub(matcher, "%%%*", ".*")
      matcher = "^" .. matcher .. "$"
      table.insert(settings["_allowed_referer_matchers"], matcher)
    end
  end
  settings["allowed_referers"] = nil

  -- Lowercase header keys to match ngx.resp.getHeaders() output.
  lowercase_settings_header_keys(settings, "default_response_headers")
  lowercase_settings_header_keys(settings, "override_response_headers")

  if settings["append_query_string"] then
    settings["_append_query_args"] = ngx.decode_args(settings["append_query_string"])
    settings["append_query_string"] = nil
  end

  if settings["http_basic_auth"] then
    settings["_http_basic_auth_header"] = "Basic " .. ngx.encode_base64(settings["http_basic_auth"])
    settings["http_basic_auth"] = nil
  end

  if settings["api_key_verification_transition_start_at"] and settings["api_key_verification_transition_start_at"]["$date"] then
    settings["api_key_verification_transition_start_at"] = settings["api_key_verification_transition_start_at"]["$date"]
  end
end

function _M.parse_accept(header, supported_media_types)
  if not header then
    return nil
  end

  local accepts = {}
  local accept_header = split(header, ",", true)
  for _, accept_string in ipairs(accept_header) do
    local parts = split(accept_string, ";", true, 2)
    local media = parts[1]
    local params = parts[2]
    if params then
      params = split(params, ";", true)
    end

    local media_parts = split(media, "/", true)
    local media_type = strip(media_parts[1] or "")
    local media_subtype = strip(media_parts[2] or "")

    local q = 1
    if params then
      for _, param in ipairs(params) do
        local param_parts = split(param, "=", true)
        local param_key = strip(param_parts[1] or "")
        local param_value = strip(param_parts[2] or "")
        if param_key == "q" then
          q = tonumber(param_value)
        end
      end
    end

    if q == 0 then
      break
    end

    local accept = {
      media_type = media_type,
      media_subtype = media_subtype,
      q = q,
    }

    table.insert(accepts, accept)
  end

  if accepts then
    table.sort(accepts, function(a, b)
      if a.q < b.q then
        return false
      elseif a.q > b.q then
        return true
      elseif (a.media_type == "*" and b.media_type ~= "*") or (a.media_subtype == "*" and b.media_subtype ~= "*") then
        return false
      elseif (a.media_type ~= "*" and b.media_type == "*") or (a.media_subtype ~= "*" and b.media_subtype == "*") then
        return true
      else
        return true
      end
    end)
  end

  for _, supported in ipairs(supported_media_types) do
    for _, accept in ipairs(accepts) do
      if accept.media_type == supported.media_type and accept.media_subtype == supported.media_subtype then
        return supported.format
      elseif accept.media_type == supported.media_type and accept.media_subtype == "*" then
        return supported.format
      elseif accept.media_type == "*" and accept.media_subtype == "*" then
        return supported.format
      else
        return nil
      end
    end
  end
end

return _M