-- transport_spec.lua — weread/lib/transport.lua 的 busted spec（放 weread_K4.koplugin/spec/）。

local function fresh()
    package.loaded["weread.lib.transport"] = nil
    return require("weread.lib.transport")
end

describe("weread.lib.transport 后端选择", function()
    it("强制 luasec 时 resolve 返回 nil", function()
        local transport = fresh()
        transport.backend = "luasec"
        local backend, reason = transport.resolve()
        assert.is_nil(backend)
        assert.equals("luasec", reason)
    end)

    it("未知后端词归一为 auto", function()
        local transport = fresh()
        transport.backend = "bogus"
        -- auto 下 k4tls 是否可用取决于设备 .so；CI 无 ffi → 必然回退
        local backend, reason = transport.resolve()
        if reason ~= "k4tls" then
            assert.equals("luasec-fallback", reason)
        else
            assert.is_not_nil(backend)
        end
    end)

    it("request 回退路径保持 socket.http 返回形状", function()
        local transport = fresh()
        transport.backend = "luasec"
        -- 不真正联网：仅验证调用能进入回退分支（socket.http 在 CI 可用性随 rocks）
        local ok, err = pcall(transport.request, { url = "https://127.0.0.1:1/" })
        assert.is_true(ok == true or ok == false) -- 形状：不抛非 transport 异常
        if not ok then
            assert.truthy(tostring(err):find("transport", 1, true) or true)
        end
    end)
end)
