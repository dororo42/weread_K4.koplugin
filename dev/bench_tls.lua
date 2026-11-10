-- TLS backend bench: libk4tls (Rust/rustls, C ABI) vs LuaSec, on-device.
-- Each sample = full connection (DNS + TCP + TLS handshake + GET response)
-- to the target URL with redirect off. 1 warmup + N timed samples per
-- backend, 0.3s spacing. Read-only; does not touch plugin settings.
--
-- Usage (device, KOReader tree):  luajit dev/bench_tls.lua [N]
-- 2026-11-10 first run (K5, n=10): k4tls MEAN 0.837s vs LuaSec 0.866s —
-- R4 PASS, see ~/reports/2026-11-10-K4weread-R4-bench报告-*.md.
package.path = "/mnt/us/koreader/common/?.lua;/mnt/us/koreader/plugins/weread_K4.koplugin/?.lua;" .. package.path
package.cpath = "/mnt/us/koreader/common/?.so;/mnt/us/koreader/common/socket/?.so;" .. package.cpath

local socket = require("socket")
local ltn12 = require("ltn12")
local https = require("ssl.https")

local URL = "https://weread.qq.com/"
local N = tonumber(arg and arg[1]) or 10

local function run_one_luasec()
    local t = {}
    local ok, code = https.request{
        url = URL,
        sink = ltn12.sink.table(t),
        redirect = false,
    }
    return ok, code
end

local k4 = require("weread.lib.k4tls")
local function run_one_k4tls()
    local t = {}
    local ok, status = k4.request{
        url = URL,
        method = "GET",
        headers = { ["User-Agent"] = "K4weread-bench/1.0", ["Accept"] = "*/*" },
        sink = function(chunk, err)
            if err then return nil, err end
            if chunk then table.insert(t, chunk) end
            return 1
        end,
        block_timeout = 8,
        total_timeout = 16,
    }
    return ok, status
end

local function bench(name, fn)
    local okw, codew = fn()
    print(string.format("%s warmup: ok=%s code=%s", name, tostring(okw), tostring(codew)))
    local samples = {}
    for i = 1, N do
        local t0 = socket.gettime()
        local ok, code = fn()
        local dt = socket.gettime() - t0
        samples[#samples + 1] = dt
        print(string.format("%s #%02d: %6.3fs  ok=%s code=%s", name, i, dt, tostring(ok), tostring(code)))
        socket.sleep(0.3)
    end
    local sum, mx = 0, 0
    for _, d in ipairs(samples) do sum = sum + d; if d > mx then mx = d end end
    print(string.format("%s MEAN: %.3fs  MAX: %.3fs  (n=%d)", name, sum / #samples, mx, #samples))
end

print("== R4 bench: " .. URL .. " ==")
print("luajit:", jit and jit.version or _VERSION)
print("k4tls version:", tostring(k4.version()))
bench("luasec", run_one_luasec)
socket.sleep(1)
bench("k4tls  ", run_one_k4tls)
print("== done ==")
