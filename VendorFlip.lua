local name, addon = ...
local data, db -- data: account-wide (VendorFlipData) · db: per-character UI settings (VendorFlipDB)
local scan, panel, ahOpen, merchant
local refresh, queueRefresh
local neutral = false   -- which market the window shows
local ahNeutral = false -- which market the open auctioneer belongs to
local page, sortMode = 1, 1
local pageSize = 12
local liveLifetime = 20 * 60      -- live scan prices beat addon data for this long
local scanCooldown = 15 * 60      -- client-wide full-scan cooldown
local staleAfter = 24 * 3600      -- cheapest listing sitting this long = not selling at that price
local historyWindow = 7 * 86400   -- sales estimate looks back this far
local saleGap = 4 * 3600          -- only scans this close together are compared for sales
local marketMultiple = 3          -- live price above this × TSM market value is an outlier
local defaults = { minMargin = 25, minProfit = 100, maxMarkup = 10, hideOutliers = true }
local itemDataPending = {}
local categories = { { "all", "All items" }, { "trade", "Trade Goods" }, { "recipe", "Recipes" },
    { "consumable", "Consumables" }, { "other", "Other" } }
local floor = math.floor

local function say(text) print("|cffd4af37VendorFlip|r " .. text) end

local function priceCall(func, ...)
    if not func then return end
    local ok, value = pcall(func, ...)
    if ok and type(value) == "number" and value >= 0 then return value end
end

local function tsmPrice(itemID, source)
    return priceCall(TSM_API and TSM_API.GetCustomPriceValue, source, "i:" .. itemID)
end

local function ageText(seconds)
    seconds = math.max(0, seconds)
    if seconds < 3600 then return floor(seconds / 60) .. "m" end
    if seconds < 86400 then return floor(seconds / 3600) .. "h" end
    return floor(seconds / 86400) .. "d"
end

-- One bucket per auction house: faction AH per realm+faction, neutral AH per realm.
local function bucket(isNeutral)
    local key = (GetRealmName() or "?") .. "-" .. (isNeutral and "Neutral" or (UnitFactionGroup("player") or "?"))
    local b = data.ah[key]
    if not b then
        b = {}
        data.ah[key] = b
    end
    b.prices, b.listings, b.sales, b.windows = b.prices or {}, b.listings or {}, b.sales or {}, b.windows or {}
    return b
end

local function soldPerDay(b, id, now)
    local observed = 0
    for _, window in ipairs(b.windows) do
        if now - window[1] < historyWindow then observed = observed + window[2] end
    end
    if observed < 3600 then return end
    local units = 0
    for _, sale in ipairs(b.sales[id] or {}) do
        if now - sale[1] < historyWindow then units = units + sale[2] end
    end
    return units * 86400 / observed
end

-- fresh: 1 = live scan, 2 = recent addon data, 3 = old data
local function lookupPrice(itemID, now, snapshot)
    if snapshot and now - snapshot.time < liveLifetime then
        return { price = snapshot.price, listed = snapshot.quantity, supply = snapshot.supply, since = snapshot.since,
            source = snapshot.price and ("Live · " .. ageText(now - snapshot.time)) or "No live buyout",
            confidence = 1, fresh = 1, live = true }
    end
    local old = snapshot and snapshot.price and { price = snapshot.price, listed = snapshot.quantity,
        supply = snapshot.supply, source = "Scan · " .. ageText(now - snapshot.time), confidence = 0.5, fresh = 3 }
    if neutral then return old or { source = "Scan at neutral AH" } end

    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    local price = priceCall(api and api.GetAuctionPriceByItemID, name, itemID)
    local age = price and priceCall(api.GetAuctionAgeByItemID, name, itemID)
    local label = "Auctionator · " .. (age and (age == 0 and "today" or age .. "d") or "age unknown")
    if price and price > 0 and age == 0 then return { price = price, source = label, confidence = 0.9, fresh = 2 } end

    local buyout = tsmPrice(itemID, "DBMinBuyout")
    if buyout and buyout > 0 then return { price = buyout, source = "TSM min buyout", confidence = 0.8, fresh = 2 } end
    local recent = tsmPrice(itemID, "DBRecent")
    if recent and recent > 0 then return { price = recent, source = "TSM recent", confidence = 0.65, fresh = 3 } end
    if price and price > 0 then return { price = price, source = label, confidence = 0.5, fresh = 3 } end
    return old or { source = "No price" }
end

local function auctionPrice(itemID, now)
    local snapshot = bucket(neutral).prices[itemID]
    local info = lookupPrice(itemID, now, snapshot)
    info.snapshot = snapshot
    return info
end

local cityCache = {}
local function inCity(map, city)
    if not map or not city then return false end
    local key = map .. ":" .. city
    local cached = cityCache[key]
    if cached ~= nil then return cached end
    local result, current = false, map
    while current and current > 0 do
        if current == city then
            result = true
            break
        end
        local info = C_Map.GetMapInfo(current)
        local parent = info and info.parentMapID
        if not parent or parent == current then break end
        current = parent
    end
    cityCache[key] = result
    return result
end

local function candidates(city)
    local items = {}
    local faction = UnitFactionGroup("player")
    local playerMap = C_Map.GetBestMapForUnit("player")
    if city then
        local cityInfo = C_Map.GetMapInfo(city)
        for _, vendor in ipairs(addon.capitalGoods[city] or {}) do
            for _, id in ipairs(vendor[5]) do
                local entry = addon.catalog[id]
                if entry then
                    local bundle = entry[3] or 1
                    items[id] = { price = entry[1] * bundle, bundle = bundle, stock = -1, npcID = vendor[1],
                        vendor = vendor[2] .. (cityInfo and cityInfo.name and (" · " .. cityInfo.name) or ""),
                        map = city, x = vendor[3], y = vendor[4] }
                end
            end
        end
    else
        for id, entry in pairs(addon.catalog) do
            local bundle = entry[3] or 1
            items[id] = { price = entry[1] * bundle, bundle = bundle, vendor = entry[2], stock = -1 }
        end
    end
    for id, vendors in pairs(addon.vendorRecipes) do
        local factionVendors = vendors[faction] or {}
        local npc = not city and (factionVendors[1] or vendors[1]) or nil
        for _, list in ipairs({ factionVendors, vendors }) do
            for _, vendorID in ipairs(list) do
                local map = addon.recipeVendors[vendorID] and addon.recipeVendors[vendorID][3]
                local observed = data.vendors[id] and map and data.vendors[id][vendorID .. ":" .. map]
                if (not observed or observed.stock ~= 0) and (city and inCity(map, city) or (not city and map and map == playerMap)) then
                    npc = vendorID
                    break
                end
            end
            if npc and (city or (addon.recipeVendors[npc] and addon.recipeVendors[npc][3] == playerMap)) then break end
        end
        if npc and addon.recipeVendors[npc] then
            local info = addon.recipeVendors[npc]
            local entry = addon.catalog[id]
            local offer = { price = entry and entry[1], bundle = 1, stock = -1, npcID = npc }
            offer.vendor = info[2] and (info[1] .. " · " .. info[2]) or info[1]
            offer.map, offer.x, offer.y = info[3], info[4], info[5]
            offer.recipe = true
            items[id] = offer
        elseif not city then
            items[id] = nil
        end
    end
    for id, offers in pairs(data.vendors) do
        local best, observedHere
        for key, offer in pairs(offers) do
            if (not offer.faction or offer.faction == faction) and (not city or inCity(offer.map, city)) then
                local seed = items[id]
                if seed and seed.npcID and key:match("^[^:]+") == tostring(seed.npcID) then observedHere = true end
                if offer.stock ~= 0 then
                    local cheaper = not best or offer.price / offer.bundle < best.price / best.bundle
                    local sameCost = best and offer.price / offer.bundle == best.price / best.bundle
                    if cheaper or (sameCost and offer.seen > best.seen) then best = offer end
                end
            end
        end
        if best then
            items[id] = best
        elseif city then
            if observedHere then items[id] = nil end
        elseif not items[id] or not items[id].recipe then
            items[id] = nil
        else
            -- Other catalog vendors may have stock, but do not suggest the
            -- specific vendor where a character last saw zero stock.
            local offer = items[id]
            offer.vendor, offer.map, offer.x, offer.y = "Check recipe vendors", nil, nil, nil
        end
    end
    return items
end

local function vendorCount(city)
    local seen, count = {}, 0
    local faction = UnitFactionGroup("player")
    for _, offers in pairs(data.vendors) do
        for key, offer in pairs(offers) do
            if not seen[key] and (not offer.faction or offer.faction == faction) and (not city or inCity(offer.map, city)) then
                seen[key] = true
                count = count + 1
            end
        end
    end
    return count
end

local function itemCategory(id, offer)
    if offer.recipe or addon.vendorRecipes[id] then return "recipe" end
    local _, _, _, _, _, class = C_Item.GetItemInfoInstant(id)
    if not class then
        if id == 159 then return "consumable" end
        return addon.catalog[id] and "trade" or "other"
    end
    if class == Enum.ItemClass.Recipe then return "recipe" end
    if class == Enum.ItemClass.Tradegoods or class == Enum.ItemClass.Reagent or class == Enum.ItemClass.ItemEnhancement then
        return "trade"
    end
    if class == Enum.ItemClass.Consumable then return "consumable" end
    return "other"
end

local function requestItem(id)
    if itemDataPending[id] == nil then
        itemDataPending[id] = true
        C_Item.RequestLoadItemDataByID(id)
    end
end

local function vendorCost(id, offer, loadData)
    if offer.price then return offer.price / offer.bundle end
    local itemName, _, _, _, _, _, _, _, _, _, sell, _, _, bind = C_Item.GetItemInfo(id)
    if not itemName then
        if loadData then requestItem(id) end
        return
    end
    if bind ~= Enum.ItemBind.None and bind ~= Enum.ItemBind.OnUse then return end
    local vendorBuy = tsmPrice(id, "VendorBuy")
    if vendorBuy and vendorBuy > 0 then return vendorBuy end
    -- Standard undiscounted recipe estimate. Live merchant prices override it.
    if sell and sell > 0 then return sell * 4 end
end

-- C_MerchantFrame.GetItemInfo only exists on newer clients; fall back to the classic global.
local function merchantItemInfo(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then return C_MerchantFrame.GetItemInfo(index) end
    local itemName, _, price, stackCount, numAvailable, isPurchasable, _, hasExtendedCost, currencyID = GetMerchantItemInfo(index)
    if not itemName then return end
    return { price = price or 0, stackCount = stackCount or 0, numAvailable = numAvailable or -1,
        isPurchasable = isPurchasable ~= false, hasExtendedCost = hasExtendedCost, currencyID = currencyID }
end

local function captureMerchant()
    if not merchant then return end
    local now = GetServerTime()
    for index = 1, GetMerchantNumItems() do
        local info = merchantItemInfo(index)
        local link = GetMerchantItemLink(index)
        if info and link and info.price > 0 and info.stackCount > 0 and not info.hasExtendedCost and not info.currencyID
            and (info.isPurchasable or info.numAvailable == 0) then
            local id = tonumber(link:match("|Hitem:(%d+)"))
            if id then
                local itemName, _, _, _, _, _, _, _, _, _, _, class, _, bind = C_Item.GetItemInfo(link)
                if not itemName and not merchant.requested[id] then
                    merchant.requested[id] = true
                    C_Item.RequestLoadItemDataByID(id)
                elseif itemName and (bind == Enum.ItemBind.None or bind == Enum.ItemBind.OnEquip or bind == Enum.ItemBind.OnUse)
                    and class ~= Enum.ItemClass.Quest and class ~= Enum.ItemClass.Weapon and class ~= Enum.ItemClass.Armor
                    and class ~= Enum.ItemClass.Battlepet then
                    data.vendors[id] = data.vendors[id] or {}
                    data.vendors[id][merchant.key] = {
                        price = info.price, bundle = info.stackCount, stock = info.numAvailable,
                        vendor = merchant.label, map = merchant.map, x = merchant.x, y = merchant.y, seen = now,
                        faction = UnitFactionGroup("player"),
                    }
                end
            end
        end
    end
    queueRefresh()
end

local captureQueued
local function queueCapture()
    if captureQueued then return end
    captureQueued = true
    C_Timer.After(0.3, function()
        captureQueued = false
        captureMerchant()
    end)
end

local function openMerchant()
    local guid = UnitGUID("npc") or UnitGUID("target")
    local npc = UnitName("npc") or UnitName("target")
    local map = C_Map.GetBestMapForUnit("player")
    local mapInfo = map and C_Map.GetMapInfo(map)
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    local zone = mapInfo and mapInfo.name or GetRealZoneText()
    if not npc then return end
    local npcID = guid and guid:match("^[^-]+%-%d+%-%d+%-%d+%-%d+%-(%d+)")
    merchant = { key = (npcID or npc) .. ":" .. (map or zone), label = npc .. " · " .. zone, map = map,
        x = pos and pos.x, y = pos and pos.y, requested = {} }
    captureMerchant()
end

local function stopScan(message)
    scan = nil
    if panel then
        panel.scanStatus = message
        refresh()
    end
end

-- Store the snapshot, compare listings with the previous scan to estimate sales,
-- and remember how long the cheapest listing has been sitting there.
local function finishSnapshot(active, results, now)
    local b = active.bucket
    local countSales = b.lastSnapshot and now - b.lastSnapshot <= saleGap
    if countSales then table.insert(b.windows, { now, now - b.lastSnapshot }) end
    local checked, listed = 0, 0
    for id in pairs(active.items) do
        checked = checked + 1
        local result = results[id]
        local previous = b.listings[id]
        local current, since = {}, nil
        if result then
            listed = listed + 1
            for fingerprint, count in pairs(result.listings) do
                local first = previous and previous[fingerprint] and previous[fingerprint][2] or now
                current[fingerprint] = { count, first }
                if tonumber(fingerprint:match("|(%d+)|")) == result.price then since = math.max(since or 0, first) end
            end
        end
        local previousPrice = b.prices[id] and b.prices[id].price
        if countSales and previous and previousPrice then
            -- Buyers take the cheapest listings, so only listings near the old floor count, and
            -- only when the seller has nothing up now (otherwise it was likely a cancel/repost).
            local sellersNow = {}
            for fingerprint in pairs(current) do sellersNow[fingerprint:match("^(.-)|")] = true end
            local units = 0
            for fingerprint, old in pairs(previous) do
                local seller, price, quantity = fingerprint:match("^(.-)|(%d+)|(%d+)$")
                local gone = old[1] - (current[fingerprint] and current[fingerprint][1] or 0)
                if gone > 0 and tonumber(price) <= previousPrice * 1.1 and (seller == "?" or not sellersNow[seller]) then
                    units = units + gone * tonumber(quantity)
                end
            end
            if units > 0 then
                b.sales[id] = b.sales[id] or {}
                table.insert(b.sales[id], { now, units })
            end
        end
        b.listings[id] = next(current) and current or nil
        b.prices[id] = result and { price = result.price, quantity = result.quantity, supply = result.supply,
            since = since, time = now } or { time = now, quantity = 0, supply = 0 }
    end
    for i = #b.windows, 1, -1 do
        if now - b.windows[i][1] >= historyWindow then table.remove(b.windows, i) end
    end
    for id, sales in pairs(b.sales) do
        for i = #sales, 1, -1 do
            if now - sales[i][1] >= historyWindow then table.remove(sales, i) end
        end
        if #sales == 0 then b.sales[id] = nil end
    end
    b.lastSnapshot = now
    data.lastScan = now
    return checked, listed
end

local function receiveSnapshot()
    if not ahOpen then return end
    local active = scan
    if active and active.processing then return end
    if not active then
        -- Another addon (Auctionator, TSM) ran a full scan: use it for free.
        if GetServerTime() - (data.lastScan or 0) < 60 then return end
        active = { items = candidates(), bucket = bucket(ahNeutral), passive = true }
    end
    local count = C_AuctionHouse.GetNumReplicateItems()
    if not count or count == 0 then
        if not active.passive then stopScan("No auction data received · previous prices kept") end
        return
    end

    scan = active
    active.processing = true
    neutral = ahNeutral
    local player, realm = UnitFullName("player")
    local playerFullName = player and realm and (player .. "-" .. realm)
    local results = {}
    local now = GetServerTime()
    local function readBatch(first)
        if scan ~= active then return end
        local last = math.min(first + 999, count - 1)
        for index = first, last do
            local _, _, quantity, _, _, _, _, _, _, buyout, _, _, _, owner, ownerFullName, _, id =
                C_AuctionHouse.GetReplicateItemInfo(index)
            local ownAuction = player and (ownerFullName == player or owner == player or (playerFullName and ownerFullName == playerFullName))
            if active.items[id] and not ownAuction and buyout and buyout > 0 and quantity and quantity > 0 then
                local price = floor(buyout / quantity)
                local result = results[id]
                if not result then
                    result = { price = price, quantity = 0, supply = 0, listings = {} }
                    results[id] = result
                end
                if price < result.price then
                    result.price, result.quantity = price, quantity
                elseif price == result.price then
                    result.quantity = result.quantity + quantity
                end
                result.supply = result.supply + quantity
                local fingerprint = (owner or ownerFullName or "?") .. "|" .. price .. "|" .. quantity
                result.listings[fingerprint] = (result.listings[fingerprint] or 0) + 1
            end
        end
        if last < count - 1 then
            if panel then panel.status:SetText(("Reading auction snapshot · %d%%"):format(floor((last + 1) / count * 100))) end
            C_Timer.After(0, function() readBatch(last + 1) end)
            return
        end
        local checked, listed = finishSnapshot(active, results, now)
        stopScan(("%s · %d checked · %d with buyouts"):format(
            active.passive and "Captured another addon's full scan" or "Scan complete", checked, listed))
    end
    readBatch(0)
end

local function startScan()
    if scan then
        stopScan("Scan stopped · previous prices kept")
        return
    end
    if not ahOpen then return end
    local remaining = (data.lastScan or 0) + scanCooldown - GetServerTime()
    if remaining > 0 then
        stopScan(("Full scan cooldown · try again in %dm %02ds"):format(floor(remaining / 60), remaining % 60))
        return
    end
    neutral = ahNeutral -- show the market being scanned
    local active = { items = candidates(), bucket = bucket(ahNeutral) }
    scan = active
    panel.scanStatus = "Requesting live auction snapshot…"
    refresh()
    C_AuctionHouse.ReplicateItems()
    C_Timer.After(25, function()
        if scan == active and not active.processing then
            stopScan("No snapshot received · another addon may have used the full-scan cooldown")
        end
    end)
end

local function money(copper)
    if copper == nil then return "–" end
    local sign = copper < 0 and "−" or ""
    copper = floor(math.abs(copper) + 0.5)
    if copper >= 10000 then return ("%s%dg %02ds %02dc"):format(sign, floor(copper / 10000), floor(copper / 100) % 100, copper % 100) end
    if copper >= 100 then return ("%s%ds %02dc"):format(sign, floor(copper / 100), copper % 100) end
    return sign .. copper .. "c"
end

-- Compact form for the input box: 10s, 1g50s, 0
local function moneyInput(copper)
    local text = ""
    if copper >= 10000 then text = text .. floor(copper / 10000) .. "g" end
    if floor(copper / 100) % 100 > 0 then text = text .. floor(copper / 100) % 100 .. "s" end
    if copper % 100 > 0 then text = text .. copper % 100 .. "c" end
    return text == "" and "0" or text
end

-- Accepts 1g50s, 50s, 75c, or a plain number of gold.
local function parseMoney(text)
    text = text:lower():gsub("%s", "")
    if text == "" then return end
    if text:match("^%d+%.?%d*$") then return floor(tonumber(text) * 10000 + 0.5) end
    local total = 0
    local rest, matches = text:gsub("(%d+%.?%d*)([gsc])", function(amount, unit)
        total = total + tonumber(amount) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
        return ""
    end)
    if rest ~= "" or matches == 0 then return end
    return floor(total + 0.5)
end

local function buildRows()
    local rows, total, hidden = {}, 0, 0
    local now = GetServerTime()
    local playerMap = C_Map.GetBestMapForUnit("player")
    local cut = neutral and 15 or 5
    local city = db.city and db.city ~= 0 and db.city or nil
    local b = bucket(neutral)
    for id, offer in pairs(candidates(city)) do
        if db.category == "all" or itemCategory(id, offer) == db.category then
            total = total + 1
            local info = auctionPrice(id, now)
            local price = info.price
            local cost = vendorCost(id, offer, price ~= nil)
            local payout = price and floor(price * (100 - cut) / 100)
            local profit = payout and cost and payout - cost
            local margin = profit and payout > 0 and profit / payout or nil
            if margin and margin * 100 > db.minMargin and profit >= db.minProfit then
                local flag
                if cost > 0 and price / cost > db.maxMarkup then
                    flag = ("%.0f× vendor"):format(price / cost)
                end
                local market = not neutral and tsmPrice(id, "DBMarket") or nil
                if not flag and market and market > 0 and price > marketMultiple * market then
                    flag = ("%.1f× market"):format(price / market)
                end
                -- The cheapest listing at the last scan had sat for a day and this price
                -- is no lower than it, whichever source the price came from.
                local snap = info.snapshot
                local stuck = snap and snap.price and snap.since and (snap.time or 0) - snap.since
                if not flag and stuck and stuck >= staleAfter and price >= snap.price then
                    flag = "Unsold " .. ageText(stuck)
                end
                if flag and db.hideOutliers then
                    hidden = hidden + 1
                else
                    local nameText = C_Item.GetItemNameByID(id)
                    if not nameText then requestItem(id) end
                    local volume = not neutral and tsmPrice(id, "DBRegionSoldPerDay * 100") or nil
                    local volumeSource = volume and "TSM region"
                    volume = volume and volume / 100
                    if not volume then
                        volume = soldPerDay(b, id, now)
                        volumeSource = volume and "your scans"
                    end
                    local desired = volume and math.max(1, math.min(20, floor(volume))) or 1
                    local quantity = math.ceil(desired / offer.bundle) * offer.bundle
                    if offer.stock > 0 then quantity = math.min(quantity, offer.stock) end
                    local score = profit * quantity
                    local supply = info.supply or info.listed
                    if score > 0 then
                        score = score * info.confidence
                        if offer.stock > 0 then score = score * 0.75 end
                        if offer.map and offer.map == playerMap then score = score * 1.25 end
                        if supply and supply > 0 and volume and supply > volume then
                            score = score * math.max(0.25, volume / supply)
                        end
                        if flag then score = score * 0.1 end
                    end
                    rows[#rows + 1] = { id = id, name = nameText or ("Item #" .. id), offer = offer, cost = cost,
                        price = price, profit = profit, info = info, volume = volume, volumeSource = volumeSource,
                        score = score, quantity = quantity, supply = supply, margin = margin,
                        roi = cost > 0 and profit / cost or nil, flag = flag }
                end
            end
        end
    end
    table.sort(rows, function(a, b2)
        local left = sortMode == 2 and a.profit or a.score
        local right = sortMode == 2 and b2.profit or b2.score
        if left == right then return a.id < b2.id end
        return left > right
    end)
    return rows, total, hidden
end

local function shoppingList()
    local rows = buildRows()
    if #rows == 0 then
        say("Nothing to buy with the current filters.")
        return
    end
    local groups, order = {}, {}
    local spend, gain = 0, 0
    for i = 1, math.min(10, #rows) do
        local row = rows[i]
        local key = row.offer.vendor
        if not groups[key] then
            groups[key] = { offer = row.offer, rows = {} }
            order[#order + 1] = key
        end
        table.insert(groups[key].rows, row)
    end
    say("Shopping list · top " .. math.min(10, #rows) .. " flips")
    for _, key in ipairs(order) do
        local group = groups[key]
        local where = group.offer.x and (" (%.1f, %.1f)"):format(group.offer.x * 100, group.offer.y * 100) or ""
        print("|cffffd200" .. key .. where .. "|r")
        for _, row in ipairs(group.rows) do
            local _, link = C_Item.GetItemInfo(row.id)
            local cost = row.cost * row.quantity
            spend, gain = spend + cost, gain + row.profit * row.quantity
            print(("   %d× %s · %s%s"):format(row.quantity, link or row.name, money(cost),
                row.flag and (" |cffff6655(" .. row.flag .. ")|r") or ""))
        end
    end
    print(("Total %s · estimated profit %s"):format(money(spend), money(gain)))
end

local function setColor(cell, level)
    if level == "bad" then cell:SetTextColor(1, 0.4, 0.33)
    elseif level == 1 then cell:SetTextColor(0.45, 0.9, 0.5)
    elseif level == 3 then cell:SetTextColor(1, 0.82, 0.3)
    else cell:SetTextColor(1, 1, 1) end
end

refresh = function()
    if not panel or not panel:IsShown() then return end
    local rows, total, hidden = buildRows()
    local pages = math.max(1, math.ceil(#rows / pageSize))
    page = math.min(page, pages)
    for i, row in ipairs(panel.rows) do
        local entry = rows[(page - 1) * pageSize + i]
        row.row = entry
        row:SetShown(entry ~= nil)
        if entry then
            local vendor = entry.offer.vendor .. (entry.offer.seen and "" or " (est.)")
            local source = entry.info.source .. (entry.flag and (" · " .. entry.flag) or "")
            local values = { entry.name, vendor, money(entry.cost), money(entry.price), money(entry.profit),
                ("%.0f%%"):format(entry.margin * 100), entry.roi and ("%.0f%%"):format(entry.roi * 100) or "–", source }
            for column, value in ipairs(values) do row.cells[column]:SetText(value) end
            row.cells[5]:SetTextColor(0.45, 0.9, 0.5)
            setColor(row.cells[8], entry.flag and "bad" or entry.info.fresh)
        end
    end
    panel.count:SetText(("%d of %d items%s   ·   Page %d / %d"):format(#rows, total,
        hidden > 0 and (" · %d outliers hidden"):format(hidden) or "", page, pages))
    panel.prev:SetEnabled(page > 1)
    panel.next:SetEnabled(page < pages)
    panel.scanButton:SetText(scan and "Stop scan" or "Live scan")
    panel.scanButton:SetEnabled(ahOpen == true)
    panel.market:SetText(neutral and "Neutral AH" or "Faction AH")
    panel.market:SetEnabled(not scan)
    panel.sort:SetText(sortMode == 1 and "Sort: Best flips" or "Sort: Profit each")
    panel.status:SetText(panel.scanStatus or (ahOpen and "Ready to scan" or "Open the Auction House to scan"))
    panel.empty:SetShown(#rows == 0)
    local city = db.city ~= 0 and db.city or nil
    local emptyText = total == 0 and "No known vendors for these filters. Visit merchants to add their stock."
        or ("No flips above %g%% margin and %s profit."):format(db.minMargin, money(db.minProfit))
    if hidden > 0 then emptyText = emptyText .. (" %d outliers hidden."):format(hidden) end
    if city then
        emptyText = emptyText .. ("\n%d vendors recorded in this city. Open more merchants here to learn their stock."):format(vendorCount(city))
    end
    panel.empty:SetText(emptyText)
    for id, tab in pairs(panel.cityTabs) do tab:SetEnabled(id ~= db.city) end
    for id, tab in pairs(panel.categoryTabs) do tab:SetEnabled(id ~= db.category) end
end

local refreshQueued
queueRefresh = function()
    if refreshQueued or not panel or not panel:IsShown() then return end
    refreshQueued = true
    C_Timer.After(0.25, function()
        refreshQueued = false
        refresh()
    end)
end

local function label(parent, template, x, y)
    local text = parent:CreateFontString(nil, "OVERLAY", template)
    text:SetPoint("TOPLEFT", x, y)
    return text
end

local function button(parent, title, width, x, y, click)
    local control = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    control:SetSize(width, 24)
    control:SetPoint("TOPLEFT", x, y)
    control:SetText(title)
    control:SetScript("OnClick", click)
    return control
end

local function inputBox(parent, x, y, width)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetPoint("TOPLEFT", x, y)
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    box:SetMaxLetters(10)
    return box
end

local function createPanel()
    local f = CreateFrame("Frame", "VendorFlipPanel", UIParent, "BackdropTemplate")
    f:SetSize(940, 580)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14 })
    f:SetBackdropColor(0.06, 0.08, 0.10, 0.98)
    f:SetBackdropBorderColor(0.53, 0.47, 0.32, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnShow", function() refresh() end)
    f:Hide()
    table.insert(UISpecialFrames, f:GetName())
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -3, -3)
    label(f, "GameFontNormalLarge", 18, -16):SetText("VendorFlip")
    f.scanButton = button(f, "Live scan", 92, 17, -46, startScan)
    button(f, "Refresh prices", 107, 116, -46, function() refresh() end)
    f.market = button(f, "Faction AH", 104, 230, -46, function()
        neutral = not neutral
        page, f.scanStatus = 1, nil
        refresh()
    end)
    f.sort = button(f, "Sort: Best flips", 123, 341, -46, function() sortMode = 3 - sortMode; page = 1; refresh() end)
    button(f, "Shopping list", 110, 471, -46, shoppingList)

    -- Filters: margin, minimum profit, maximum markup, hide outliers
    label(f, "GameFontNormalSmall", 18, -149):SetText("Margin above")
    local marginBox = inputBox(f, 100, -143, 40)
    label(f, "GameFontHighlightSmall", 144, -149):SetText("%")
    label(f, "GameFontNormalSmall", 168, -149):SetText("Min profit")
    local profitBox = inputBox(f, 234, -143, 62)
    label(f, "GameFontNormalSmall", 310, -149):SetText("Max markup")
    local markupBox = inputBox(f, 388, -143, 40)
    label(f, "GameFontHighlightSmall", 432, -149):SetText("×")
    local filterError = label(f, "GameFontHighlightSmall", 660, -149)
    filterError:SetTextColor(1, 0.55, 0.45)
    local boxes = { marginBox, profitBox, markupBox }
    local function showFilters()
        marginBox:SetText(tostring(db.minMargin))
        profitBox:SetText(moneyInput(db.minProfit))
        markupBox:SetText(tostring(db.maxMarkup))
    end
    local function applyFilters()
        local marginText = marginBox:GetText():match("^%s*(.-)%s*$")
        local margin = marginText:match("^%d+%.?%d*%%?$") and tonumber((marginText:gsub("%%$", "")))
        if not margin or margin > 100 then
            filterError:SetText("Margin: enter 0–100%")
            return
        end
        local minProfit = parseMoney(profitBox:GetText())
        if not minProfit then
            filterError:SetText("Min profit: e.g. 50s or 1g20s")
            return
        end
        local markupText = markupBox:GetText():match("^%s*(.-)%s*$"):gsub("[xX]$", ""):gsub("×$", "")
        local markup = markupText:match("^%d+%.?%d*$") and tonumber(markupText)
        if not markup or markup < 1 then
            filterError:SetText("Max markup: 1 or more")
            return
        end
        db.minMargin, db.minProfit, db.maxMarkup, page = margin, minProfit, markup, 1
        showFilters()
        for _, box in ipairs(boxes) do box:ClearFocus() end
        filterError:SetText("")
        refresh()
    end
    for _, box in ipairs(boxes) do
        box:SetScript("OnEnterPressed", applyFilters)
        box:SetScript("OnEscapePressed", function(self)
            showFilters()
            self:ClearFocus()
            filterError:SetText("")
        end)
        box:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if self == marginBox then
                GameTooltip:SetText("Profit ÷ payout after the AH cut")
            elseif self == profitBox then
                GameTooltip:SetText("Minimum profit per item, e.g. 50s or 1g20s")
            else
                GameTooltip:SetText("AH price above this many times the vendor cost counts as an outlier")
            end
            GameTooltip:Show()
        end)
        box:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    showFilters()
    button(f, "Apply", 59, 450, -142, applyFilters)
    local hide = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    hide:SetSize(24, 24)
    hide:SetPoint("TOPLEFT", 518, -141)
    hide:SetChecked(db.hideOutliers)
    hide:SetScript("OnClick", function(self)
        db.hideOutliers, page = self:GetChecked() and true or false, 1
        refresh()
    end)
    hide:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Hide outliers")
        GameTooltip:AddLine("Price far above vendor cost (max markup), above 3× TSM market value, or the cheapest listing has sat unsold for a day.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    hide:SetScript("OnLeave", function() GameTooltip:Hide() end)
    label(f, "GameFontHighlightSmall", 544, -149):SetText("Hide outliers")

    label(f, "GameFontNormalSmall", 18, -85):SetText("Vendor city")
    f.cityTabs = {}
    local function cityTab(id, title, x)
        f.cityTabs[id] = button(f, title, 108, x, -78, function()
            db.city, page = id, 1
            refresh()
        end)
    end
    cityTab(0, "Anywhere", 100)
    local faction = UnitFactionGroup("player")
    local currentMap = C_Map.GetBestMapForUnit("player")
    for i, city in ipairs(addon.capitals[faction] or {}) do
        cityTab(city[1], city[2], 100 + 115 * i)
        if db.city == nil and inCity(currentMap, city[1]) then db.city = city[1] end
    end
    if not db.city or not f.cityTabs[db.city] then db.city = 0 end

    label(f, "GameFontNormalSmall", 18, -117):SetText("Item type")
    f.categoryTabs = {}
    for i, category in ipairs(categories) do
        local id = category[1]
        f.categoryTabs[id] = button(f, category[2], 108, 100 + 115 * (i - 1), -110, function()
            db.category, page = id, 1
            refresh()
        end)
    end
    if not f.categoryTabs[db.category] then db.category = "all" end
    f.status = label(f, "GameFontHighlightSmall", 18, -178)

    local columns = {
        { "Item", 5, 165 }, { "Vendor", 174, 170 }, { "Cost / ea", 348, 72 }, { "AH / ea", 424, 72 },
        { "Profit / ea", 500, 72 }, { "Margin", 576, 52 }, { "ROI", 632, 56 }, { "Price source", 692, 210 },
    }
    for _, column in ipairs(columns) do label(f, "GameFontNormalSmall", 17 + column[2], -200):SetText(column[1]) end
    f.rows = {}
    for i = 1, pageSize do
        local row = CreateFrame("Button", nil, f)
        row:SetSize(906, 24)
        row:SetPoint("TOPLEFT", 17, -217 - (i - 1) * 24)
        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.055 or 0.025)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.cells = {}
        for j, column in ipairs(columns) do
            local cell = label(row, "GameFontHighlightSmall", column[2], -6)
            cell:SetWidth(column[3])
            cell:SetJustifyH("LEFT")
            cell:SetWordWrap(false)
            row.cells[j] = cell
        end
        row:SetScript("OnEnter", function(self)
            local d = self.row
            if not d then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(d.name)
            GameTooltip:AddLine(d.offer.vendor, 1, 1, 1, true)
            if d.offer.x then GameTooltip:AddLine(("Vendor near %.1f, %.1f"):format(d.offer.x * 100, d.offer.y * 100)) end
            GameTooltip:AddLine(("%d per vendor purchase · %s"):format(d.offer.bundle, money(d.cost * d.offer.bundle)))
            if d.offer.stock > 0 then GameTooltip:AddLine("Last seen stock: " .. d.offer.stock) end
            if d.flag then GameTooltip:AddLine("Outlier: " .. d.flag, 1, 0.4, 0.33) end
            if d.info.listed and d.info.listed > 0 then GameTooltip:AddLine("Units at the lowest price: " .. d.info.listed) end
            if d.supply and d.supply > 0 then GameTooltip:AddLine("Total units listed: " .. d.supply) end
            local snap = d.info.snapshot
            if snap and snap.since and snap.time then
                GameTooltip:AddLine("Cheapest listing had been up " .. ageText(snap.time - snap.since) .. " at the last scan")
            end
            if d.volume then
                GameTooltip:AddLine(("Est. sold per day: %.1f (%s)"):format(d.volume, d.volumeSource))
            else
                GameTooltip:AddLine("Est. sold per day: unknown · scan a few times, 15m+ apart", 0.75, 0.75, 0.75)
            end
            GameTooltip:AddLine(("Quantity used for ranking: %d"):format(d.quantity))
            GameTooltip:AddLine("Estimated profit for that quantity: " .. money(d.profit * d.quantity))
            local sell = select(11, C_Item.GetItemInfo(d.id))
            if sell and sell > 0 then
                GameTooltip:AddLine("Vendor sell price " .. money(sell) .. " · AH deposits scale with this and are lost if the auction expires", 0.75, 0.75, 0.75, true)
            end
            if d.offer.map and d.offer.x and C_Map.CanSetUserWaypoint and C_Map.CanSetUserWaypoint(d.offer.map) then
                GameTooltip:AddLine("Click to mark the vendor on the map", 0.75, 0.75, 0.75)
            end
            GameTooltip:AddLine("Shift-click to link item in chat", 0.75, 0.75, 0.75)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            if not self.row then return end
            local d = self.row
            if IsShiftKeyDown() then
                local _, link = C_Item.GetItemInfo(d.id)
                if link then ChatEdit_InsertLink(link) end
            elseif d.offer.map and d.offer.x and C_Map.CanSetUserWaypoint and C_Map.CanSetUserWaypoint(d.offer.map) then
                C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(d.offer.map, d.offer.x, d.offer.y))
            end
        end)
        f.rows[i] = row
    end
    f.empty = label(f, "GameFontHighlight", 24, -241)
    f.empty:SetJustifyH("LEFT")
    f.count = label(f, "GameFontHighlightSmall", 18, -523)
    f.prev = button(f, "Previous", 80, 750, -512, function() page = page - 1; refresh() end)
    f.next = button(f, "Next", 80, 837, -512, function() page = page + 1; refresh() end)
    label(f, "GameFontDisableSmall", 18, -553):SetText(
        "Margin = profit ÷ payout after the AH cut. ROI = profit ÷ vendor cost. Deposits lost on expired auctions are not included.")
    return f
end

local function togglePanel()
    panel = panel or createPanel()
    panel:SetShown(not panel:IsShown())
end

local function createMinimapButton()
    local control = CreateFrame("Button", "VendorFlipMinimapButton", Minimap)
    control:SetSize(32, 32)
    control:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    control:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = control:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER", 0, 0)
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    local border = control:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", 0, 0)

    local function position()
        local angle = db.minimapAngle or math.rad(205)
        control:ClearAllPoints()
        control:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * Minimap:GetWidth() / 2,
            math.sin(angle) * Minimap:GetHeight() / 2)
    end
    position()
    Minimap:HookScript("OnSizeChanged", position)
    control:RegisterForDrag("LeftButton")
    control:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local x, y = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            local centerX, centerY = Minimap:GetCenter()
            db.minimapAngle = math.atan2(y / scale - centerY, x / scale - centerX)
            position()
        end)
    end)
    control:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    control:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("VendorFlip")
        GameTooltip:AddLine("Click to open · Drag to move", 1, 1, 1)
        GameTooltip:Show()
    end)
    control:SetScript("OnLeave", function() GameTooltip:Hide() end)
    control:SetScript("OnClick", togglePanel)
end

-- Merge the old per-character data into the account-wide store (one time, per character).
local function migrate()
    if db.vendors then
        for id, offers in pairs(db.vendors) do
            data.vendors[id] = data.vendors[id] or {}
            for key, offer in pairs(offers) do
                local existing = data.vendors[id][key]
                if not existing or (offer.seen or 0) > (existing.seen or 0) then data.vendors[id][key] = offer end
            end
        end
        db.vendors = nil
    end
    for field, isNeutral in pairs({ faction = false, neutral = true }) do
        if db[field] then
            local prices = bucket(isNeutral).prices
            for id, snapshot in pairs(db[field]) do
                if not prices[id] or (snapshot.time or 0) > (prices[id].time or 0) then prices[id] = snapshot end
            end
            db[field] = nil
        end
    end
    if db.lastScan then
        data.lastScan = math.max(data.lastScan or 0, db.lastScan)
        db.lastScan = nil
    end
end

local function slash(input)
    local command, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = command:lower()
    if command == "" then
        togglePanel()
    elseif command == "list" or command == "shop" then
        shoppingList()
    elseif command == "vendors" then
        local vendors, count = {}, 0
        for _, offers in pairs(data.vendors) do
            for key, offer in pairs(offers) do
                local entry = vendors[key]
                if not entry then
                    entry = { label = offer.vendor, items = 0, seen = 0 }
                    vendors[key] = entry
                    count = count + 1
                end
                entry.items = entry.items + 1
                entry.seen = math.max(entry.seen, offer.seen or 0)
            end
        end
        local sorted = {}
        for _, entry in pairs(vendors) do sorted[#sorted + 1] = entry end
        table.sort(sorted, function(a, b) return a.label < b.label end)
        say(count .. " vendors recorded:")
        local now = GetServerTime()
        for _, entry in ipairs(sorted) do
            print(("   %s · %d items · seen %s ago"):format(entry.label, entry.items, ageText(now - entry.seen)))
        end
    elseif command == "forget" and rest ~= "" then
        local needle, removed = rest:lower(), 0
        for id, offers in pairs(data.vendors) do
            for key, offer in pairs(offers) do
                if (offer.vendor or ""):lower():find(needle, 1, true) then
                    offers[key] = nil
                    removed = removed + 1
                end
            end
            if not next(offers) then data.vendors[id] = nil end
        end
        say(("Forgot %d vendor entries matching \"%s\"."):format(removed, rest))
        if panel then refresh() end
    elseif command == "purge" then
        local days = tonumber(rest) or 30
        local cutoff, removed = GetServerTime() - days * 86400, 0
        for id, offers in pairs(data.vendors) do
            for key, offer in pairs(offers) do
                if (offer.seen or 0) < cutoff then
                    offers[key] = nil
                    removed = removed + 1
                end
            end
            if not next(offers) then data.vendors[id] = nil end
        end
        say(("Removed %d vendor entries not seen in %d days."):format(removed, days))
        if panel then refresh() end
    elseif command == "resetprices" then
        if scan then stopScan("Scan stopped · prices cleared") end
        data.ah = {}
        say("Cleared all auction scan data and sales history.")
        if panel then refresh() end
    else
        say("/vflip · open the window")
        say("/vflip list · print a shopping list of the top flips")
        say("/vflip vendors · list recorded vendors")
        say("/vflip forget <name> · remove a vendor's recorded stock")
        say("/vflip purge [days] · remove vendor entries older than this (default 30)")
        say("/vflip resetprices · clear scan prices and sales history")
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, event, arg)
    if event == "ADDON_LOADED" then
        if arg ~= name then return end
        self:UnregisterEvent(event)
        VendorFlipDB = VendorFlipDB or {}
        VendorFlipData = VendorFlipData or {}
        db, data = VendorFlipDB, VendorFlipData
        data.vendors, data.ah = data.vendors or {}, data.ah or {}
        if type(db.minMargin) ~= "number" or not (db.minMargin >= 0 and db.minMargin <= 100) then
            db.minMargin = defaults.minMargin
        end
        if type(db.minProfit) ~= "number" or db.minProfit < 0 then db.minProfit = defaults.minProfit end
        if type(db.maxMarkup) ~= "number" or db.maxMarkup < 1 then db.maxMarkup = defaults.maxMarkup end
        if type(db.hideOutliers) ~= "boolean" then db.hideOutliers = defaults.hideOutliers end
        if type(db.category) ~= "string" then db.category = "all" end
        SLASH_VENDORFLIP1, SLASH_VENDORFLIP2 = "/vflip", "/vendorflip"
        SlashCmdList.VENDORFLIP = slash
        for _, eventName in ipairs({ "MERCHANT_SHOW", "MERCHANT_UPDATE", "MERCHANT_CLOSED", "ITEM_DATA_LOAD_RESULT",
            "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE", "PLAYER_LOGIN" }) do
            self:RegisterEvent(eventName)
        end
    elseif event == "PLAYER_LOGIN" then
        migrate()
        createMinimapButton()
    elseif event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        local map = C_Map.GetBestMapForUnit("player")
        local info = map and C_Map.GetMapInfo(map)
        local neutralMap = map == 1434 or map == 1446 or map == 1452
        local parent = info and info.parentMapID
        ahNeutral = neutralMap or parent == 1434 or parent == 1446 or parent == 1452 or false
        neutral = ahNeutral
        if panel then panel.scanStatus = nil; refresh() end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false
        if scan then stopScan("Auction House closed · previous prices kept")
        elseif panel then panel.scanStatus = nil; refresh() end
    elseif event == "MERCHANT_SHOW" then
        openMerchant()
    elseif event == "MERCHANT_UPDATE" then
        queueCapture()
    elseif event == "MERCHANT_CLOSED" then
        merchant = nil
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        local requested = itemDataPending[arg]
        if requested then itemDataPending[arg] = false end
        if merchant then queueCapture()
        elseif requested then queueRefresh() end
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        receiveSnapshot()
    end
end)
