local os = require("os")
local component = require("component")
local sides = require("sides")

-- 定义组件和方向
local trans = component.transposer
local sideCacheBuffer = sides.west      -- 转运器对应的大型原料缓存仓
local sideAEInfusion = sides.south      -- 转运器对应的AE的物质聚合器
local sideInterface = sides.down        -- 转运器对应的主网也是唯一的AE接口，用于设置流体的输出
local fluidInterface = component.fluid_interface  -- ME流体接口/二合一接口，用于设置流体配置
local mei = component.fluid_interface      -- 流体接口，用于网络查询
local gtm = component.gt_machine        -- GT机器适配器，用于检查Heliofusion Exoticizer机器状态

-- 状态持久化机制 - 用于抗重启
local STATE_FILE = "/tmp/heliofusion_state.dat"
local state = {}

-- 从文件加载状态
local function loadState()
    local file = io.open(STATE_FILE, "r")
    if file then
        local content = file:read("*a")
        file:close()
        if content then
            local success, loadedState = pcall(load(content))
            if success and loadedState then
                state = loadedState
                print("状态已从文件加载")
            else
                print("状态文件损坏，使用默认状态")
                state = {lastProcessed = 0, processingQueue = {}}
            end
        end
    else
        print("状态文件不存在，初始化默认状态")
        state = {lastProcessed = 0, processingQueue = {}}
    end
end

-- 保存状态到文件
local function saveState()
    local file = io.open(STATE_FILE, "w")
    if file then
        -- 手动序列化状态表
        local function serializeTable(tbl, indent)
            indent = indent or 0
            local serialized = "{\n"
            local spacing = string.rep("  ", indent + 1)
            
            for k, v in pairs(tbl) do
                serialized = serialized .. spacing
                
                -- 键的处理
                if type(k) == "string" then
                    serialized = serialized .. "[\"" .. k .. "\"] = "
                else
                    serialized = serialized .. "[" .. tostring(k) .. "] = "
                end
                
                -- 值的处理
                if type(v) == "string" then
                    serialized = serialized .. "\"" .. v .. "\""
                elseif type(v) == "number" or type(v) == "boolean" then
                    serialized = serialized .. tostring(v)
                elseif type(v) == "table" then
                    serialized = serialized .. serializeTable(v, indent + 1)
                else
                    serialized = serialized .. "\"" .. tostring(v) .. "\""  -- 不支持的类型用字符串表示
                end
                
                serialized = serialized .. ",\n"
            end
            
            local endSpacing = string.rep("  ", indent)
            serialized = serialized .. endSpacing .. "}"
            return serialized
        end
        
        local serialized = serializeTable(state)
        file:write("return " .. serialized)
        file:close()
        print("状态已保存到文件")
    else
        print("无法保存状态到文件")
    end
end

-- 初始化状态
loadState()

-- GT5U Heliofusion Exoticizer材料映射表 - 支持磁物质和夸克胶子
local exoticizerMaterials = {
    -- 磁物质相关材料
    [2129] = {name = "neutronium", type = "magnetic", plasmaRatio = 1296},      -- 中子ium
    [0] = {name = "draconium", type = "magnetic", plasmaRatio = 1296},          -- 龙
    [2976] = {name = "draconiumawakened", type = "magnetic", plasmaRatio = 1296}, -- 觉醒龙
    [2978] = {name = "ichorium", type = "magnetic", plasmaRatio = 1296},        -- 灵宝
    [2982] = {name = "cosmicneutronium", type = "magnetic", plasmaRatio = 1296}, -- 黑中子
    [2397] = {name = "infinity", type = "magnetic", plasmaRatio = 1296},        -- 无尽
    [2329] = {name = "tritanium", type = "magnetic", plasmaRatio = 1296},       -- 三钛
    [2395] = {name = "bedrockium", type = "magnetic", plasmaRatio = 1296},      -- 基岩
    
    -- 夸克胶子相关材料
    [3] = {name = "zirconium", type = "quark_gluon", plasmaRatio = 1296},       -- 锆
    [30] = {name = "thorium232", type = "quark_gluon", plasmaRatio = 1296},     -- 钍-232
    [64] = {name = "ruthenium", type = "quark_gluon", plasmaRatio = 1296},      -- 钌
    [78] = {name = "rhodium", type = "quark_gluon", plasmaRatio = 1296},        -- 铑
    [11000] = {name = "hafnium", type = "quark_gluon", plasmaRatio = 1296},     -- 铪
    [11012] = {name = "iodine", type = "quark_gluon", plasmaRatio = 1296},      -- 碘
    [2984] = {name = "flerovium_gt5u", type = "quark_gluon", plasmaRatio = 1296}, -- 夫(金字旁的)
    [382] = {name = "ardite", type = "quark_gluon", plasmaRatio = 1296},        -- 阿迪特
    
    -- 常见GT金属粉末 - 用于生成对应的等离子体
    [2032] = {name = "iron", type = "generic", plasmaRatio = 1296},              -- Iron Dust
    [2054] = {name = "silver", type = "generic", plasmaRatio = 1296},            -- Silver Dust
    [2058] = {name = "antimony", type = "generic", plasmaRatio = 1296},          -- Antimony Dust
    [2078] = {name = "lutetium", type = "generic", plasmaRatio = 1296},          -- Lutetium Dust
    [2080] = {name = "tantalum", type = "generic", plasmaRatio = 1296},          -- Tantalum Dust
    [2074] = {name = "holmium", type = "generic", plasmaRatio = 1296},           -- Holmium Dust
    [2382] = {name = "ardite", type = "generic", plasmaRatio = 1296},            -- Ardite Dust (different from 382)
    [2000] = {name = "carbon", type = "generic", plasmaRatio = 1296},            -- Carbon Dust
    [2001] = {name = "sulfur", type = "generic", plasmaRatio = 1296},            -- Sulfur Dust
    [2003] = {name = "saltpeter", type = "generic", plasmaRatio = 1296},         -- Saltpeter Dust
    [2004] = {name = "phosphorus", type = "generic", plasmaRatio = 1296},        -- Phosphorus Dust
    [2017] = {name = "tin", type = "generic", plasmaRatio = 1296},               -- Tin Dust
    [2018] = {name = "lead", type = "generic", plasmaRatio = 1296},              -- Lead Dust
    [2019] = {name = "bismuth", type = "generic", plasmaRatio = 1296},           -- Bismuth Dust
    [2020] = {name = "zinc", type = "generic", plasmaRatio = 1296},              -- Zinc Dust
    [2021] = {name = "germanium", type = "generic", plasmaRatio = 1296},         -- Germanium Dust
    [2022] = {name = "silicon", type = "generic", plasmaRatio = 1296},           -- Silicon Dust
    [2023] = {name = "rubber", type = "generic", plasmaRatio = 1296},            -- Rubber Dust
    [2024] = {name = "nickel", type = "generic", plasmaRatio = 1296},            -- Nickel Dust
    [2025] = {name = "platinum", type = "generic", plasmaRatio = 1296},          -- Platinum Dust
    [2026] = {name = "tungsten", type = "generic", plasmaRatio = 1296},          -- Tungsten Dust
    [2027] = {name = "molybdenum", type = "generic", plasmaRatio = 1296},        -- Molybdenum Dust
    [2028] = {name = "titanium", type = "generic", plasmaRatio = 1296},          -- Titanium Dust
    [2029] = {name = "chromium", type = "generic", plasmaRatio = 1296},          -- Chromium Dust
    [2030] = {name = "vanadium", type = "generic", plasmaRatio = 1296},          -- Vanadium Dust
    [2031] = {name = "manganese", type = "generic", plasmaRatio = 1296},         -- Manganese Dust
    [2033] = {name = "gold", type = "generic", plasmaRatio = 1296},              -- Gold Dust
    [2034] = {name = "copper", type = "generic", plasmaRatio = 1296},            -- Copper Dust
    [2035] = {name = "aluminium", type = "generic", plasmaRatio = 1296},         -- Aluminium Dust
    [2036] = {name = "cobalt", type = "generic", plasmaRatio = 1296},            -- Cobalt Dust
    [2037] = {name = "arsenic", type = "generic", plasmaRatio = 1296},           -- Arsenic Dust
    [2038] = {name = "gallium", type = "generic", plasmaRatio = 1296},           -- Gallium Dust
    [2039] = {name = "indium", type = "generic", plasmaRatio = 1296},            -- Indium Dust
    [2040] = {name = "niobium", type = "generic", plasmaRatio = 1296},           -- Niobium Dust
    [2041] = {name = "yttrium", type = "generic", plasmaRatio = 1296},           -- Yttrium Dust
    [2042] = {name = "rareearth", type = "generic", plasmaRatio = 1296},         -- Rare Earth Dust
    [2043] = {name = "magnesium", type = "generic", plasmaRatio = 1296},         -- Magnesium Dust
    [2044] = {name = "calcium", type = "generic", plasmaRatio = 1296},           -- Calcium Dust
    [2045] = {name = "barium", type = "generic", plasmaRatio = 1296},            -- Barium Dust
    [2046] = {name = "strontium", type = "generic", plasmaRatio = 1296},         -- Strontium Dust
    [2047] = {name = "boron", type = "generic", plasmaRatio = 1296},             -- Boron Dust
    [2048] = {name = "sodium", type = "generic", plasmaRatio = 1296},            -- Sodium Dust
    [2049] = {name = "lithium", type = "generic", plasmaRatio = 1296},           -- Lithium Dust
    [2050] = {name = "antimony", type = "generic", plasmaRatio = 1296},          -- Antimony Dust
    [2051] = {name = "mercury", type = "generic", plasmaRatio = 1296},           -- Mercury Dust (though mercury is liquid)
    [2052] = {name = "solderingalloy", type = "generic", plasmaRatio = 1296},     -- Soldering Alloy Dust
    [2053] = {name = "electrum", type = "generic", plasmaRatio = 1296},          -- Electrum Dust
    [2055] = {name = "cupronickel", type = "generic", plasmaRatio = 1296},       -- Cupronickel Dust
    [2056] = {name = "kanthal", type = "generic", plasmaRatio = 1296},           -- Kanthal Dust
    [2057] = {name = "nichrome", type = "generic", plasmaRatio = 1296},          -- Nichrome Dust
    [2059] = {name = "solder", type = "generic", plasmaRatio = 1296},            -- Solder Dust
    [2060] = {name = "cobaltbrass", type = "generic", plasmaRatio = 1296},       -- Cobalt Brass Dust
    [2061] = {name = "ultimet", type = "generic", plasmaRatio = 1296},           -- Ultimet Dust
    [2062] = {name = "tungstencarbide", type = "generic", plasmaRatio = 1296},   -- Tungsten Carbide Dust
    [2063] = {name = "magnalium", type = "generic", plasmaRatio = 1296},         -- Magnalium Dust
    [2064] = {name = "vanadiumsteel", type = "generic", plasmaRatio = 1296},     -- Vanadium Steel Dust
    [2065] = {name = "blackbronze", type = "generic", plasmaRatio = 1296},       -- Black Bronze Dust
    [2066] = {name = "bismuthbronze", type = "generic", plasmaRatio = 1296},     -- Bismuth Bronze Dust
    [2067] = {name = "blacksteel", type = "generic", plasmaRatio = 1296},        -- Black Steel Dust
    [2068] = {name = "redalloy", type = "generic", plasmaRatio = 1296},          -- Red Alloy Dust
    [2069] = {name = "bluealloy", type = "generic", plasmaRatio = 1296},         -- Blue Alloy Dust (probably Electrotine)
    [2070] = {name = "bluesteel", type = "generic", plasmaRatio = 1296},         -- Blue Steel Dust
    [2071] = {name = "redsteel", type = "generic", plasmaRatio = 1296},          -- Red Steel Dust
    [2072] = {name = "titaniumaluminide", type = "generic", plasmaRatio = 1296}, -- Titanium Aluminide Dust
    [2073] = {name = "titaniumtungsten", type = "generic", plasmaRatio = 1296},  -- Titanium Tungsten Carbide Dust
    [2075] = {name = "naquadah", type = "generic", plasmaRatio = 1296},          -- Naquadah Dust
    [2076] = {name = "naquadahalloy", type = "generic", plasmaRatio = 1296},     -- Naquadah Alloy Dust
    [2077] = {name = "tritanium", type = "generic", plasmaRatio = 1296},         -- Tritanium Dust
    [2079] = {name = "seaborgium", type = "generic", plasmaRatio = 1296},        -- Seaborgium Dust
    [2081] = {name = "bohrium", type = "generic", plasmaRatio = 1296},           -- Bohrium Dust
    [2082] = {name = "nihonium", type = "generic", plasmaRatio = 1296},          -- Nihonium Dust
    [2083] = {name = "feynmanium", type = "generic", plasmaRatio = 1296},        -- Feynmanium Dust
    [2084] = {name = "adamantium", type = "generic", plasmaRatio = 1296},        -- Adamantium Dust
    [2085] = {name = "vibranium", type = "generic", plasmaRatio = 1296},         -- Vibranium Dust
    [2086] = {name = "europium", type = "generic", plasmaRatio = 1296},          -- Europium Dust
    [2087] = {name = "terbium", type = "generic", plasmaRatio = 1296},           -- Terbium Dust
    [2088] = {name = "gadolinium", type = "generic", plasmaRatio = 1296},        -- Gadolinium Dust
    [2089] = {name = "samarium", type = "generic", plasmaRatio = 1296},          -- Samarium Dust
    [2090] = {name = "praseodymium", type = "generic", plasmaRatio = 1296},      -- Praseodymium Dust
    [2091] = {name = "neodymium", type = "generic", plasmaRatio = 1296},         -- Neodymium Dust
    [2092] = {name = "cerium", type = "generic", plasmaRatio = 1296},            -- Cerium Dust
    [2093] = {name = "lanthanum", type = "generic", plasmaRatio = 1296},         -- Lanthanum Dust
    [2094] = {name = "astatine", type = "generic", plasmaRatio = 1296},          -- Astatine Dust
    [2095] = {name = "polonium", type = "generic", plasmaRatio = 1296},          -- Polonium Dust
    [2096] = {name = "tellurium", type = "generic", plasmaRatio = 1296},         -- Tellurium Dust
    [2097] = {name = "antimony", type = "generic", plasmaRatio = 1296},          -- Antimony Dust
    [2098] = {name = "tin", type = "generic", plasmaRatio = 1296},               -- Tin Dust
    [2099] = {name = "indium", type = "generic", plasmaRatio = 1296},            -- Indium Dust
}

-- 从物品获取等离子体信息
function getPlasmaInfoFromItem(item)
    if item == nil then return nil end
    
    local materialInfo = nil
    local materialType = nil
    
    -- 检查不同类型的材料
    if item.name == "bartworks:gt.bwMetaGenerateddust" then
        -- Bartworks材料
        materialInfo = exoticizerMaterials[item.damage]
        materialType = "bartworks"
    elseif item.name:match("^miscutils:itemDust") then
        -- GT++材料
        local materialName = string.lower(string.match(item.name, "miscutils:itemDust" .. "(%w+)$"))
        -- 查找映射表中对应名称的材料
        for k, v in pairs(exoticizerMaterials) do
            if v.name == materialName then
                materialInfo = v
                materialType = "gtpp"
                break
            end
        end
    elseif item.name == "gregtech:gt.metaitem.01" then
        -- GT基础材料 - 包含各种金属粉末
        materialInfo = exoticizerMaterials[item.damage]
        if materialInfo then
            materialType = "gt"
        end
    else
        -- 尝试直接按damage查找
        materialInfo = exoticizerMaterials[item.damage]
        if materialInfo then
            materialType = "direct"
        end
    end
    
    if materialInfo ~= nil then
        return {
            name = "plasma." .. materialInfo.name,
            type = materialInfo.type,
            ratio = materialInfo.plasmaRatio,
            materialType = materialType
        }
    end
    return nil
end

-- 检查AE网络中是否有足够的流体
function checkFluidInNetwork(plasmaName, requiredAmount)
    local meInterface = component.fluid_interface
    if not meInterface then
        print("未找到ME接口")
        return false
    end
    
    -- 查询网络中的所有流体
    local allFluids = meInterface.getFluidsInNetwork()
    if allFluids then
        for _, fluid in pairs(allFluids) do
            if fluid.name == plasmaName then
                if fluid.amount >= requiredAmount then
                    return true, fluid.amount
                else
                    return false, fluid.amount
                end
            end
        end
    end
    return false, 0
end

-- 清除缓存仓中的所有材料和流体
function clearCacheBuffer()
    print("清空中介缓冲区...")
    
    -- 先清除流体
    for i = 1, 6 do  -- 缓冲仓有6个流体槽位 (AE2FC接口有6个槽位，索引0-5)
        local success, fluid = pcall(trans.getFluidInTank, sideCacheBuffer, i - 1)  -- 转运器索引从0开始，添加错误处理
        if success and fluid and fluid.amount > 0 then
            print("转移流体: " .. fluid.name .. ", 数量: " .. fluid.amount)
            local transferSuccess = pcall(trans.transferFluid, sideCacheBuffer, sideAEInfusion, fluid.amount, i - 1)
            if not transferSuccess then
                print("转移流体失败，详细信息:")
                print("  - 源位置: 大型原料缓存仓 (sideCacheBuffer)")
                print("  - 目标位置: AE注入器 (sideAEInfusion)")
                print("  - 槽位: " .. (i - 1))
                print("  - 流体名称: " .. fluid.name)
                print("  - 流体数量: " .. fluid.amount)
            end
        end
    end
    
    -- 再清除物品
    for i = 1, 16 do  -- 缓冲仓暂定16个物品槽位
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        if item and item.size > 0 then
            print("转移物品: " .. item.name .. ", 数量: " .. item.size)
            trans.transferItem(sideCacheBuffer, sideAEInfusion, item.size, i)
        end
    end
    
    print("中介缓冲区清理完成")
end

-- 等待并转运指定数量的流体
function waitForAndTransferFluid(plasmaName, requiredAmount, slotIndex)
    print("请求流体: " .. plasmaName .. ", 数量: " .. requiredAmount)
    
    ::retryIfEmpty::
    
    -- 设置流体接口配置，请求特定流体
    -- 注意：在AE2FC中，流体接口配置需要传入一个包含流体信息的表
    -- 并且槽位索引应在有效范围内（0-5）
    local configSlotIndex = slotIndex % 6  -- 确保槽位索引在0-5范围内
    local fluidConfig = {
        name = plasmaName,
        label = plasmaName,
        amount = 1000  -- 设置最小单位，让接口尝试提取这种流体
    }
    local success, err = pcall(function()
        fluidInterface.setFluidInterfaceConfiguration(configSlotIndex, fluidConfig)
    end)
    
    if not success then
        print("设置流体接口配置失败: " .. tostring(err))
        return false
    end
    
    -- 给系统一点时间来响应配置更改
    os.sleep(0.5)
    
    os.sleep(0.25)
    
    -- 等待流体到达接口
    local interfaceFluid = nil
    local maxTries = 10  -- 尝试10次不同的槽位
    local foundFluid = false
    
    -- 尝试不同的槽位索引，因为接口可能有不同的槽位布局
    for tankIndex = 0, maxTries - 1 do
        local success, fluid = pcall(trans.getFluidInTank, sideInterface, tankIndex)
        if success and fluid and fluid.amount > 0 then
            interfaceFluid = fluid
            print("流体已到达槽位 " .. tankIndex .. ": " .. interfaceFluid.name .. ", 数量: " .. interfaceFluid.amount)
            foundFluid = true
            break
        end
    end
    
    if not foundFluid then
        print("等待流体合成: " .. plasmaName)
        local waitTime = 0
        local maxWaitTime = 60  -- 增加最大等待时间到60秒
        
        while waitTime < maxWaitTime do
            os.sleep(2)
            waitTime = waitTime + 2
            
            -- 再次尝试不同的槽位
            for tankIndex = 0, maxTries - 1 do
                local success, fluid = pcall(trans.getFluidInTank, sideInterface, tankIndex)
                if success and fluid and fluid.amount > 0 then
                    interfaceFluid = fluid
                    print("流体已到达槽位 " .. tankIndex .. ": " .. interfaceFluid.name .. ", 数量: " .. interfaceFluid.amount)
                    foundFluid = true
                    break
                end
            end
            
            if foundFluid then
                break
            end
            
            -- 检查机器状态，如果机器停止则中断
            if not gtm.isWorkAllowed() then
                print("机器已关机，中断流体请求")
                return false
            end
        end
        
        if not foundFluid then
            print("流体合成超时或缺失样板: " .. plasmaName)
            -- 清空配置避免持续请求
            -- 确保使用正确的槽位索引，AE2FC接口有6个槽位（索引0-5）
            local configSlotIndex = slotIndex % 6
            fluidInterface.setFluidInterfaceConfiguration(configSlotIndex)
            return false
        end
    end
    
    -- 转运所需数量的流体到缓冲仓
    local remainingAmount = requiredAmount
    while remainingAmount > 0 do
        -- 寻找有效的流体槽位
        local sourceTankIndex = nil
        for tankIndex = 0, 9 do  -- 尝试前10个槽位
            local success, fluid = pcall(trans.getFluidInTank, sideInterface, tankIndex)
            if success and fluid and fluid.amount > 0 then
                sourceTankIndex = tankIndex
                interfaceFluid = fluid
                break
            end
        end
        
        if not sourceTankIndex or interfaceFluid == nil or interfaceFluid.amount == 0 then
            print("接口流体耗尽，等待补充...")
            os.sleep(1)
            -- 再次寻找流体槽位
            for tankIndex = 0, 9 do
                local success, fluid = pcall(trans.getFluidInTank, sideInterface, tankIndex)
                if success and fluid and fluid.amount > 0 then
                    sourceTankIndex = tankIndex
                    interfaceFluid = fluid
                    break
                end
            end
            
            if not sourceTankIndex or interfaceFluid == nil or interfaceFluid.amount == 0 then
                print("重新尝试获取流体...")
                goto retryIfEmpty
            end
        end
        
        local transferAmount = math.min(remainingAmount, interfaceFluid.amount)
        -- 尝试从接口传输到缓冲仓，使用找到的源槽位
        -- 目标槽位应为缓冲仓的流体槽位，索引为0-5 (AE2FC的接口有6个槽位，索引0-5)
        local targetTankIndex = slotIndex % 6  -- 将物品槽位映射到流体槽位范围(0-5)
        local success, transferred = pcall(trans.transferFluid, sideInterface, sideCacheBuffer, transferAmount, sourceTankIndex, targetTankIndex)
        if not success or transferred == nil or transferred == false then
            print("流体转移失败，跳过当前流体，详细信息:")
            print("  - 源位置: AE接口 (sideInterface)")
            print("  - 目标位置: 大型原料缓存仓 (sideCacheBuffer)")
            print("  - 源槽位索引: " .. tostring(sourceTankIndex))
            print("  - 目标槽位索引: " .. tostring(targetTankIndex))
            print("  - 请求传输量: " .. tostring(transferAmount))
            print("  - 实际传输量: " .. tostring(transferred))
            print("  - 错误详情: " .. tostring(transferred))
            -- 清空配置避免持续请求
            fluidInterface.setFluidInterfaceConfiguration(targetTankIndex)
            return false
        end
        
        -- 检查是否传输成功
        if transferred == 0 then
            print("流体传输量为0，可能存在连接问题")
            -- 清空配置避免持续请求
            fluidInterface.setFluidInterfaceConfiguration(targetTankIndex)
            return false
        end
        
        -- 检查实际传输的数量是否符合预期
        if transferred < transferAmount and transferred < interfaceFluid.amount then
            print("传输量小于请求量: " .. transferred .. " < " .. transferAmount)
        end
        
        remainingAmount = remainingAmount - transferred
        print("已转移: " .. transferred .. ", 剩余: " .. remainingAmount)
        
        -- 如果接口处的流体已经传输完了，寻找下一个有流体的槽位
        if interfaceFluid.amount - transferred <= 0 then
            -- 寻找新的流体源
            sourceTankIndex = nil
            for tankIndex = 0, 9 do
                local success, fluid = pcall(trans.getFluidInTank, sideInterface, tankIndex)
                if success and fluid and fluid.amount > 0 then
                    sourceTankIndex = tankIndex
                    interfaceFluid = fluid
                    break
                end
            end
            
            if not sourceTankIndex then
                print("没有更多流体可用，等待补充...")
                goto retryIfEmpty
            end
        end
        
        os.sleep(0.25)
    end
    
    print("流体请求完成: " .. plasmaName)
    return true
end

-- 处理单个项目
function processItem(item, slotIndex)
    if not item or item.size == 0 then
        return false
    end
    
    print("处理项目: " .. (item.label or item.name) .. ", 类型: " .. item.name .. ", 损伤值: " .. (item.damage or 0))
    
    -- 获取等离子信息
    local plasmaInfo = getPlasmaInfoFromItem(item)
    if not plasmaInfo then
        print("未知材料类型，跳过: " .. item.name .. " damage=" .. (item.damage or 0))
        return false
    end
    
    print("识别为: " .. plasmaInfo.type .. " 材料，等离子体: " .. plasmaInfo.name)
    
    -- 计算所需等离子体数量
    local requiredAmount = item.size * plasmaInfo.ratio
    
    -- 检查AE网络中是否已有足够流体
    local hasEnough, availableAmount = checkFluidInNetwork(plasmaInfo.name, requiredAmount)
    if hasEnough then
        print("网络中有足够流体: " .. availableAmount .. "/" .. requiredAmount)
        -- 直接从网络提取流体
        -- 使用流体槽位索引而不是物品槽位索引
        local fluidSlotIndex = slotIndex % 6  -- 将槽位映射到流体槽位范围(0-5)，AE2FC接口有6个槽位
        local success = waitForAndTransferFluid(plasmaInfo.name, requiredAmount, fluidSlotIndex)
        if success then
            print("成功处理项目: " .. plasmaInfo.name)
            return true
        else
            print("提取流体失败")
            return false
        end
    else
        print("网络中流体不足: " .. availableAmount .. "/" .. requiredAmount)
        -- 请求合成流体
        -- 使用流体槽位索引而不是物品槽位索引
        local fluidSlotIndex = slotIndex % 6  -- 将槽位映射到流体槽位范围(0-5)，AE2FC接口有6个槽位
        local success = waitForAndTransferFluid(plasmaInfo.name, requiredAmount, fluidSlotIndex)
        if success then
            print("成功处理项目: " .. plasmaInfo.name)
            return true
        else
            print("合成流体失败")
            return false
        end
    end
end

-- 处理所有项目
function processAllItems()
    print("开始处理所有项目...")
    local processedCount = 0
    
    -- 处理物品槽位
    for i = 1, 16 do  -- 假设有16个槽位
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        if item and item.size > 0 then
            print("发现物品槽位 " .. i .. ": " .. (item.label or item.name) .. " 数量: " .. item.size)
            if processItem(item, i - 1) then  -- 槽位索引从0开始
                processedCount = processedCount + 1
                -- 移动物品到AE注入器
                trans.transferItem(sideCacheBuffer, sideAEInfusion, item.size, i)
            end
        end
    end
    
    -- 处理流体槽位
    for i = 1, 6 do  -- 流体槽位索引，按照example.lua使用1-6的索引
        local success, fluid = pcall(trans.getFluidInTank, sideCacheBuffer, i - 1)
        if success and fluid and fluid.amount > 0 then
            print("发现流体槽位 " .. i .. ": " .. fluid.name .. " 数量: " .. fluid.amount)
            -- 如果是等离子体，直接发送到AE注入器
            if fluid.name:match("^plasma%." ) then
                local transferSuccess = pcall(trans.transferFluid, sideCacheBuffer, sideAEInfusion, fluid.amount, i - 1)
                if transferSuccess then
                    print("等离子体 " .. fluid.name .. " 已转移至AE注入器")
                    processedCount = processedCount + 1
                else
                    print("转移等离子体失败，详细信息:")
                    print("  - 源位置: 大型原料缓存仓 (sideCacheBuffer)")
                    print("  - 目标位置: AE注入器 (sideAEInfusion)")
                    print("  - 槽位: " .. i)
                    print("  - 流体名称: " .. fluid.name)
                    print("  - 流体数量: " .. fluid.amount)
                end
            end
        end
    end
    
    print("处理完成，共处理: " .. processedCount .. " 个项目")
    return processedCount
end

-- 检查是否有待处理的项目
function hasPendingItems()
    for i = 1, 16 do
        local item = trans.getStackInSlot(sideCacheBuffer, i)
        if item and item.size > 0 then
            return true
        end
    end
    
    for i = 1, 6 do  -- 流体槽位索引，按照example.lua使用1-6的索引
        local success, fluid = pcall(trans.getFluidInTank, sideCacheBuffer, i - 1)
        if success and fluid and fluid.amount > 0 then
            return true
        end
    end
    
    return false
end

-- 主循环
function main()
    print("Heliofusion Exoticizer 自动化脚本启动")
    print("支持磁物质和简并态夸克胶子生产")
    
    -- 清屏
    local success = os.execute("cls")
    if not success then
        -- 如果cls命令失败，尝试clear（Linux/Mac）
        os.execute("clear")
    end
    
    -- 检查必要的组件
    if not trans then
        print("错误: 未找到转运器")
        return
    end
    
    if not fluidInterface then
        print("错误: 未找到流体接口")
        return
    end
    
    if not gtm then
        print("错误: 未找到GT机器适配器")
        return
    end
    
    print("所有必要组件已找到，开始监控...")
    
    while true do
        -- 检查机器状态
        if not gtm.isWorkAllowed() then
            print("机器已关机，进入待机模式...")
            while not gtm.isWorkAllowed() do
                os.sleep(10)
            end
            print("机器已开机，恢复运行...")
        end
        
        -- 检查是否有待处理的项目
        if hasPendingItems() then
            print("检测到待处理项目，开始处理...")
            
            -- 处理所有项目
            local processedCount = processAllItems()
            
            if processedCount > 0 then
                print("成功处理 " .. processedCount .. " 个项目")
                
                -- 清空中介缓冲区
                clearCacheBuffer()
            else
                print("没有需要处理的项目")
            end
        else
            print("无待处理项目，等待中...")
        end
        
        -- 保存状态
        state.lastProcessed = os.time()
        saveState()
        
        -- 等待下一次检查
        os.sleep(5)
    end
end

-- 错误处理包装器
local success, errorMessage = pcall(main)
if not success then
    print("脚本执行出错: " .. tostring(errorMessage))
    -- 尝试保存状态
    state.errorTime = os.time()
    state.errorMessage = tostring(errorMessage)
    saveState()
end