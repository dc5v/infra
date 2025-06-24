local now = os.time()

local blocked = require "s2s_intelli_blacklist_blocked"

local active = {}

for domain, expiry in pairs(blocked) do
  if expiry > now then
    active[domain] = true
  end
end

return active
