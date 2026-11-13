local _, addon = ...

-- Starter estimates for common old-world goods. Visiting a merchant replaces
-- the estimate with the character's actual bundle cost and current stock.
local trade = "Trade supplies"
local tailor = "Tailoring or trade supplies"
local smith = "Blacksmithing or trade supplies"
local cooking = "Cooking supplies"
local fishing = "Fishing supplies"

-- Item ID, estimated copper per unit, vendor type, estimated purchase bundle.
addon.catalog = {
    [159] = { 5, "Innkeeper or drink vendor", 5 }, -- Refreshing Spring Water
    [2320] = { 10, tailor }, -- Coarse Thread
    [2321] = { 100, tailor }, -- Fine Thread
    [2324] = { 25, tailor }, -- Bleach
    [2604] = { 50, tailor }, -- Red Dye
    [2605] = { 100, tailor }, -- Green Dye
    [2678] = { 2, cooking, 5 }, -- Mild Spices
    [2880] = { 100, smith }, -- Weak Flux
    [3371] = { 4, "Alchemy supplies", 5 }, -- Empty Vial
    [3466] = { 2000, smith }, -- Strong Flux
    [3857] = { 500, smith }, -- Coal
    [4289] = { 50, trade }, -- Salt
    [4291] = { 500, tailor }, -- Silken Thread
    [4340] = { 350, tailor }, -- Gray Dye
    [4341] = { 500, tailor }, -- Yellow Dye
    [4399] = { 200, "Engineering supplies" }, -- Wooden Stock
    [4400] = { 2000, "Engineering supplies" }, -- Heavy Stock
    [5642] = { 1800, "Capital city alchemy supplies" }, -- Recipe: Free Action Potion
    [6217] = { 124, trade }, -- Copper Rod
    [6260] = { 50, tailor }, -- Blue Dye
    [6325] = { 40, fishing }, -- Recipe: Brilliant Smallfish
    [6328] = { 400, fishing }, -- Recipe: Longjaw Mud Snapper
    [6529] = { 50, fishing }, -- Shiny Bauble
    [6530] = { 100, fishing }, -- Nightcrawlers
    [6532] = { 250, fishing }, -- Bright Baubles
    [21099] = { 500, cooking }, -- Recipe: Smoked Sagefish
    [21219] = { 5000, cooking }, -- Recipe: Sagefish Delight
}

addon.capitals = {
    Alliance = { { 1453, "Stormwind" }, { 1455, "Ironforge" }, { 1457, "Darnassus" } },
    Horde = { { 1454, "Orgrimmar" }, { 1456, "Thunder Bluff" }, { 1458, "Undercity" } },
}

-- Starter goods with known capital vendors. The merchant window supplies live costs and stock.
-- Edna, Borya, Bombus, Mahu and Joseph: bindonforever.com and foreverdb.app vendor sightings.
-- Elynna: forevermastery.com/en/npcs/4168, Classic stock with Forever prices.
addon.capitalGoods = {
    [1453] = { { 1286, "Edna Mullby", .647, .713, { 2320, 2321, 2324, 2604, 2678, 2880, 4289, 4291, 4341, 6217 } } },
    [1454] = { { 3364, "Borya", .631, .511, { 2320, 2321 } } },
    [1455] = { { 5128, "Bombus Finespindle", .393, .337, { 2320, 2321 } } },
    [1456] = { { 3005, "Mahu", .437, .446, { 2320, 2321 } } },
    [1457] = { { 4168, "Elynna", .434, .214, { 2320, 2321, 2324, 2604, 2605, 4291, 4340, 4341, 6260 } },
        { 4223, "Fyldan", .488, .215, { 2678 } } },
    [1458] = { { 4589, "Joseph Moore", .703, .582, { 2320, 2321 } } },
}
