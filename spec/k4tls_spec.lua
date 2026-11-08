-- k4tls_spec.lua — weread/lib/k4tls.lua 的 busted spec（放 weread_K4.koplugin/spec/）。
-- 无 ffi/设备依赖：纯函数注入测试（stub 模式按 spec/client_redirect_spec.lua 头注约定，
-- 本文件不 require 设备模块，可在 CI lua5.1 直跑）。

local function fresh()
    package.loaded["weread.lib.k4tls"] = nil
    return require("weread.lib.k4tls")
end

describe("weread.lib.k4tls 纯函数层", function()
    it("headers_table_to_list 剔除传输专属键且排序稳定", function()
        local k4tls = fresh()
        local list, n = k4tls.headers_table_to_list({
            Cookie = "a=1", ["Content-Length"] = "5", Host = "x",
            Connection = "close", ["Transfer-Encoding"] = "chunked", Accept = "*/*",
        })
        assert.equals(2, n)
        for _, h in ipairs(list) do
            assert.is_nil(h:lower():match("host"))
            assert.is_nil(h:lower():match("content%-length"))
            assert.is_nil(h:lower():match("transfer%-encoding"))
        end
    end)

    it("headers_blob_to_table 保留原名键、同名后者胜", function()
        local k4tls = fresh()
        local t = k4tls.headers_blob_to_table("Location: https://x/Y\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n")
        assert.equals("https://x/Y", t.Location)
        assert.equals("b=2", t["Set-Cookie"])
    end)

    it("error_text 映射到 client.lua 重试分类词表", function()
        local k4tls = fresh()
        assert.truthy(k4tls.error_text(-13):find("timeout", 1, true))
        assert.truthy(k4tls.error_text(-11):find("connection refused", 1, true))
        -- resolution 类（ipv4_dns.is_resolution_error 词表命中）
        assert.truthy(k4tls.error_text(-10):find("host or service not provided", 1, true))
        assert.truthy(k4tls.error_text(-15):find("closed", 1, true))
        assert.truthy(k4tls.error_text(-17):find("certificate", 1, true))
    end)

    it("select 强制 luasec 恒回退", function()
        local k4tls = fresh()
        local backend, reason = k4tls.select("luasec")
        assert.is_nil(backend)
        assert.truthy(tostring(reason):find("luasec"))
    end)
end)
