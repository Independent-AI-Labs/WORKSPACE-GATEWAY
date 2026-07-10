--sync-opencode-models.lua
--Lua replacement for the Python block in sync-opencode-models.sh.
--Runs inside apache/apisix:3.17.0-debian container (has cjson.safe + lyaml).
--
--Args: config_path gateway_url gateway_api_key gateway_models_file
--models_dev_file llamafile_models_file context_limit_pct context_limit_ceiling
--
--Reads the opencode JSONC config, strips comments + trailing commas,
--merges enriched model data from models.dev, writes THREE provider entries
--(workspace-gw-private, workspace-gw-own, workspace-gw-llamafile), outputs
--compact JSON to stdout. Status messages go to stderr.

local cjson = require("cjson.safe")

local config_path = arg[1]
local gateway_url = arg[2]
local gateway_api_key = arg[3]
local gateway_models_file = arg[4]
local models_dev_file = arg[5]
local llamafile_models_file = arg[6]
local context_limit_pct = tonumber(arg[7])
local context_limit_ceiling = tonumber(arg[8])

if not config_path or not gateway_url then
  io.stderr:write("Usage: config_path gateway_url gateway_api_key "
    .. "gateway_models_file models_dev_file llamafile_models_file "
    .. "pct ceiling\n")
  os.exit(1)
end

--Strip JSONC comments (// and /* */) while respecting string literals.
local function strip_jsonc_comments(text)
  local result = {}
  local i = 1
  local len = #text
  while i <= len do
    local ch = text:sub(i, i)
    if ch == '"' then
      --Copy string literal verbatim (including escapes)
      result[#result + 1] = ch
      i = i + 1
      while i <= len do
        local s = text:sub(i, i)
        result[#result + 1] = s
        if s == "\\" and i < len then
          --Copy escaped char
          i = i + 1
          result[#result + 1] = text:sub(i, i)
          i = i + 1
        elseif s == '"' then
          i = i + 1
          break
        else
          i = i + 1
        end
      end
    elseif ch == "/" and i < len then
      local next_ch = text:sub(i + 1, i + 1)
      if next_ch == "/" then
        --Line comment: skip to end of line
        while i <= len and text:sub(i, i) ~= "\n" do
          i = i + 1
        end
      elseif next_ch == "*" then
        --Block comment: skip to */
        i = i + 2
        while i + 1 <= len and not (text:sub(i, i) == "*" and text:sub(i + 1, i + 1) == "/") do
          i = i + 1
        end
        i = i + 2
      else
        result[#result + 1] = ch
        i = i + 1
      end
    else
      result[#result + 1] = ch
      i = i + 1
    end
  end
  return table.concat(result)
end

--Scale a context/input limit by pct, clamp to ceiling.
local function scale_limit(val)
  if val == nil then return nil end
  local scaled = math.floor(val * context_limit_pct / 100)
  if context_limit_ceiling > 0 and scaled > context_limit_ceiling then
    scaled = context_limit_ceiling
  end
  return scaled
end

--Shallow copy of a table (one level deep).
local function shallow_copy(t)
  local copy = {}
  for k, v in pairs(t) do
    copy[k] = v
  end
  return copy
end

--Build a model entry from models.dev metadata.
local function build_model_entry(model_id, md)
  local entry = {}
  if md then
    for _, key in ipairs({"name", "family", "release_date", "attachment",
        "reasoning", "temperature", "tool_call", "interleaved", "status"}) do
      if md[key] ~= nil then
        entry[key] = md[key]
      end
    end

    local cost = md.cost
    if cost then
      local cost_entry = {
        input = cost.input or 0,
        output = cost.output or 0,
      }
      if cost.cache_read ~= nil then cost_entry.cache_read = cost.cache_read end
      if cost.cache_write ~= nil then cost_entry.cache_write = cost.cache_write end
      entry.cost = cost_entry
    end

    local limit = md.limit
    if limit then
      local limit_entry = {}
      if limit.context ~= nil then limit_entry.context = scale_limit(limit.context) end
      if limit.input ~= nil then limit_entry.input = scale_limit(limit.input) end
      if limit.output ~= nil then limit_entry.output = limit.output end
      entry.limit = limit_entry
    end

    local modalities = md.modalities
    if modalities then
      local mod_entry = {}
      if modalities.input ~= nil then mod_entry.input = modalities.input end
      if modalities.output ~= nil then mod_entry.output = modalities.output end
      entry.modalities = mod_entry
    end
  else
    entry.name = model_id
    entry.limit = {context = 0, output = 0}
  end
  return entry
end

--Build a model entry for the local llamafile upstream.
--The raw model id (e.g. /zip/MiniCPM5-1B-Q8_0.gguf) is used as the key
--because opencode sends it in the request body and the relay-llamafile
--route does NOT rewrite the body model field (only the URI prefix).
--The display name is a friendly label for the UI.
local function build_llamafile_model_entry(model_id)
  local ctx = scale_limit(131072)
  return {
    name = "MiniCPM5",
    limit = {
      context = ctx,
      output = ctx,
    },
    cost = {
      input = 0,
      output = 0,
    },
    temperature = true,
    reasoning = false,
    tool_call = true,
    attachment = false,
  }
end

--Load gateway model IDs
local f = io.open(gateway_models_file, "r")
if not f then
  io.stderr:write("ERROR: cannot read " .. gateway_models_file .. "\n")
  os.exit(1)
end
local gateway_model_ids = cjson.decode(f:read("*a"))
f:close()

--Load models.dev data
f = io.open(models_dev_file, "r")
if not f then
  io.stderr:write("ERROR: cannot read " .. models_dev_file .. "\n")
  os.exit(1)
end
local models_dev_raw = cjson.decode(f:read("*a"))
f:close()

local opencode_provider = (models_dev_raw and models_dev_raw.opencode) or {}
local md_models = (opencode_provider and opencode_provider.models) or {}

--Build sorted model list
local sorted_ids = {}
for _, mid in ipairs(gateway_model_ids) do
  sorted_ids[#sorted_ids + 1] = mid
end
table.sort(sorted_ids)

local enriched_count = 0
local bare_count = 0
local models_dict = {}
for _, mid in ipairs(sorted_ids) do
  local md = md_models[mid]
  if md then
    enriched_count = enriched_count + 1
  else
    bare_count = bare_count + 1
  end
  models_dict[mid] = build_model_entry(mid, md)
end

--Load llamafile model IDs
local lf_f = io.open(llamafile_models_file, "r")
if not lf_f then
  io.stderr:write("ERROR: cannot read " .. llamafile_models_file .. "\n")
  os.exit(1)
end
local llamafile_model_ids = cjson.decode(lf_f:read("*a"))
lf_f:close()

if not llamafile_model_ids or #llamafile_model_ids == 0 then
  io.stderr:write("ERROR: llamafile model list is empty\n")
  os.exit(1)
end

local llamafile_models_dict = {}
for _, mid in ipairs(llamafile_model_ids) do
  llamafile_models_dict[mid] = build_llamafile_model_entry(mid)
end

--Load existing opencode config (JSONC)
local config = {}
f = io.open(config_path, "r")
if f then
  local raw = f:read("*a")
  f:close()
  local stripped = strip_jsonc_comments(raw)
  --Remove trailing commas before } or ]
  stripped = stripped:gsub(",%s*([}%]])", "%1")
  config = cjson.decode(stripped) or {}
end

--Ensure provider table exists
if type(config.provider) ~= "table" then
  config.provider = {}
end

--Remove stale provider entries
for _, stale in ipairs({"zen_federated", "zen", "workspace-gateway",
    "opencode_federated", "opencode"}) do
  config.provider[stale] = nil
end

--Write workspace-gw-private (virtual key)
config.provider["workspace-gw-private"] = {
  name = "Workspace GW (Virtual Key)",
  api = gateway_url .. "/opencode_federated/v1",
  npm = "@ai-sdk/openai-compatible",
  options = {
    baseURL = gateway_url .. "/opencode_federated/v1",
    apiKey = gateway_api_key,
    headers = {
      ["X-Tenant-ID"] = "default",
      ["X-User-ID"] = "agent",
    },
  },
  models = models_dict,
}

--Write workspace-gw-own (own key, no apiKey)
--Deep-copy models to avoid shared reference
local own_models = {}
for k, v in pairs(models_dict) do
  own_models[k] = shallow_copy(v)
end
config.provider["workspace-gw-own"] = {
  name = "Workspace GW (Own Key)",
  api = gateway_url .. "/opencode/v1",
  npm = "@ai-sdk/openai-compatible",
  options = {
    baseURL = gateway_url .. "/opencode/v1",
    headers = {
      ["X-Tenant-ID"] = "default",
      ["X-User-ID"] = "agent",
    },
  },
  models = own_models,
}

--Write workspace-gw-llamafile (no-auth local LLM, no apiKey)
config.provider["workspace-gw-llamafile"] = {
  name = "Workspace GW (llamafile)",
  api = gateway_url .. "/llamafile/v1",
  npm = "@ai-sdk/openai-compatible",
  options = {
    baseURL = gateway_url .. "/llamafile/v1",
    headers = {
      ["X-Tenant-ID"] = "default",
      ["X-User-ID"] = "agent",
    },
  },
  models = llamafile_models_dict,
}

--Output compact JSON to stdout (shell wrapper pipes through jq for pretty-print)
local json_out = cjson.encode(config)
if not json_out then
  io.stderr:write("ERROR: failed to encode config JSON\n")
  os.exit(1)
end
io.write(json_out)
io.write("\n")

--Status to stderr
local total = #sorted_ids
local lf_total = #llamafile_model_ids
io.stderr:write("  Wrote " .. total .. " models to " .. config_path .. "\n")
io.stderr:write("    Enriched from models.dev: " .. enriched_count .. "\n")
io.stderr:write("    Bare (no models.dev match): " .. bare_count .. "\n")
io.stderr:write("    Context limit: " .. context_limit_pct
  .. "% (ceiling: " .. context_limit_ceiling .. ")\n")
io.stderr:write("    workspace-gw-private:   " .. total .. " models (virtual key)\n")
io.stderr:write("    workspace-gw-own:       " .. total .. " models (own key)\n")
io.stderr:write("    workspace-gw-llamafile:  " .. lf_total .. " models (no-auth local)\n")
