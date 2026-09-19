-- Verification-page flow for gateway-minted device codes (protocol
-- "anthropic"). Upstream offers no device endpoint, so the gateway hosts
-- the human step itself: this page starts the upstream browser PKCE
-- authorization, collects the pasted CODE#STATE, completes the exchange,
-- stores the session, and marks the pending device record approved. The
-- polling client then receives the session bearer from the device poll.
-- Protocol specifics live in the oauth_device engine; storage is passed
-- in (oauth_store API); no other dependencies.
local M = {}

local function page(conf)
    return ([==[<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Gateway device login</title>
<style>
body{font-family:system-ui,sans-serif;max-width:36rem;margin:4rem auto;padding:0 1rem}
code{background:#f2f2f2;padding:.1rem .4rem;border-radius:4px;word-break:break-all}
input{width:100%;padding:.5rem;margin:.5rem 0;box-sizing:border-box}
button{padding:.5rem 1.5rem}
#status{margin-top:1rem;font-weight:600}
</style></head>
<body>
<h1>Device login</h1>
<p>Step 1: open the authorization link and sign in with the account that
owns this gateway session.</p>
<p><a id="authlink" href="#">Open the login page</a></p>
<p>Step 2: the login page shows a code shaped like
<code>XXXX#YYYY</code>. Paste the whole string here:</p>
<input id="codestate" title="CODE#STATE" aria-label="Paste the CODE#STATE value here" autocomplete="off">
<button id="submit">Complete login</button>
<p id="status"></p>
<script>
var base = "{{AUTH_BASE}}";
var state = null;
fetch(base + "/verify/start?user_code=" +
    encodeURIComponent(new URLSearchParams(location.search).get("user_code") || ""),
    { method: "POST", headers: { "Content-Type": "application/json" },
      body: "{}" })
  .then(function (r) { return r.json(); })
  .then(function (j) {
    if (!j.authorization_url) { throw new Error(j.error || "login start failed"); }
    state = j.state;
    document.getElementById("authlink").href = j.authorization_url;
    document.getElementById("authlink").textContent = j.authorization_url;
  })
  .catch(function (e) {
    document.getElementById("status").textContent = String(e.message || e);
  });
document.getElementById("submit").onclick = function () {
  fetch(base + "/verify/complete", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ state: state, code_state: document.getElementById("codestate").value.trim() })
    })
    .then(function (r) { return r.json(); })
    .then(function (j) {
      document.getElementById("status").textContent =
        j.status === "approved"
          ? "Approved. Return to your terminal; the login will complete there."
          : (j.error || "completion failed");
    })
    .catch(function (e) {
      document.getElementById("status").textContent = String(e.message || e);
    });
};
</script>
</body>
</html>
]==]):gsub("{{AUTH_BASE}}", conf.auth_base)
end

function M.serve(conf)
    return 200, page(conf)
end

function M.start(conf, tokens, device, json_body)
    local input = json_body()
    --The page POSTs "{}" and carries user_code as a query argument.
    local user_code = input.user_code or ngx.var.arg_user_code or ""
    if user_code == "" then
        return 400, { error = "missing user_code" }
    end
    local index = tokens.load_device(conf, "uc-" .. user_code)
    if not index or not index.device_code then
        return 400, { error = "unknown or expired user_code" }
    end
    local pending = tokens.load_device(conf, index.device_code)
    if not pending or (tonumber(pending.expires_at) and ngx.time() > tonumber(pending.expires_at)) then
        return 400, { error = "unknown or expired user_code" }
    end
    local engine = device.engine(conf)
    local verifier, challenge = device.generate_pkce()
    --Record key is a fresh random state; the upstream authorize URL
    --carries state == verifier (Anthropic quirk, enforced by the engine).
    --session_id carries over from the device record so the issued session
    --stays bound to the CLI's original ?session= value.
    local state = device.generate_state()
    local redirect_uri = conf.browser_redirect_uri
    local _, store_err = tokens.store_device(conf, state, {
        flow = "verify",
        user_code = user_code,
        code_verifier = verifier,
        redirect_uri = redirect_uri,
        session_id = pending.session_id,
        expires_at = ngx.time() + 600,
        created_at = ngx.http_time(ngx.time()),
    })
    if store_err then
        return 503, { error = "cannot reach token store" }
    end
    return 200, {
        authorization_url = engine.build_authorize_url(conf, redirect_uri, verifier, challenge),
        state = state,
        expires_in = 600,
    }
end

function M.complete(conf, tokens, device, json_body, build_record)
    local input = json_body()
    if not input.state or input.state == "" then
        return 400, { error = "missing state" }
    end
    if not input.code_state or input.code_state == "" then
        return 400, { error = "missing CODE#STATE value" }
    end
    local code, state_half = input.code_state:match("^(.+)#(.+)$")
    if not code or not state_half then
        return 400, { error = "the login page value must look like CODE#STATE" }
    end
    --Single-use claim of the verify record (same contract as the browser
    --flow): a replayed or concurrent completion observes "not found".
    local pending, consume_err = tokens.consume_device(conf, input.state)
    if not pending then
        if consume_err and consume_err:find("not found") then
            return 400, { error = "login session expired, invalid, or already used" }
        end
        return 503, { error = "cannot reach token store" }
    end
    if pending.flow ~= "verify" then
        return 400, { error = "login session expired or invalid" }
    end
    if not tonumber(pending.expires_at) or ngx.time() > tonumber(pending.expires_at) then
        return 400, { error = "login session expired" }
    end
    if state_half ~= pending.code_verifier then
        return 400, { error = "STATE part does not match this login session" }
    end
    local result, err = device.engine(conf).exchange_code(
        conf, code, state_half, pending.redirect_uri, pending.code_verifier)
    if not result then
        return 502, { error = "token exchange failed: " .. (err or "unknown") }
    end
    local bearer = result.access_token
    local _, store_err = tokens.store_session(conf, bearer,
        build_record(bearer, result, pending.session_id))
    if store_err then
        return 503, { error = "cannot reach token store" }
    end
    local index = tokens.load_device(conf, "uc-" .. pending.user_code)
    local device_code = index and index.device_code
    if device_code then
        local record = tokens.load_device(conf, device_code)
        if record then
            record.approved = true
            record.session_bearer = bearer
            record.session_expires_in = result.expires_in
            tokens.store_device(conf, device_code, record)
        end
        tokens.delete_device(conf, "uc-" .. pending.user_code)
    end
    return 200, { status = "approved" }
end

return M
