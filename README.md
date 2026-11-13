# VendorFlip

A World of Warcraft addon for the **WoW Forever** client that finds items you can buy from a vendor and resell on the Auction House for a profit, ranked by what's worth doing right now.

## Features

- **Ranks vendor → AH flips** by estimated profit after the Auction House cut, weighted by price freshness, how fast the item sells, and whether the vendor is nearby.
- **Price sources, freshest first:** its own live Auction House scans, then Auctionator, then TradeSkillMaster. Neutral AHs (Booty Bay, Gadgetzan, Everlook) use their own scans and a 15% cut.
- **Learns from merchants you visit:** actual prices, bundle sizes, limited stock and locations. Data is shared across all your characters, split by faction.
- **Filters:** vendor city tabs, item type tabs (Trade Goods, Recipes, Consumables, Other), minimum margin, minimum profit per item, and a maximum markup.
- **Outlier detection:** hides "troll" listings (for example a 4g recipe posted at 400g). It flags prices far above vendor cost, more than 3× TSM market value, or where the cheapest listing has sat unsold for a day.
- **Sales estimates from your own scans:** compares consecutive scans to estimate how many units actually sell per day, for servers without TSM region data.
- **Picks up other addons' full scans** (Auctionator, TSM) automatically.
- **Shopping list:** prints the top flips to chat, grouped by vendor with coordinates and total cost.

## Install

Copy the `VendorFlip` folder into `World of Warcraft/_forever_/Interface/AddOns/`, then `/reload` or restart the game.

## Usage

Click the gold coin on the minimap or type `/vflip`. At an auctioneer, click **Live scan** (the full-scan cooldown is 15 minutes). Scanning a few times, 15+ minutes apart, improves the sales estimates.

| Command | What it does |
|---|---|
| `/vflip` | Open or close the window |
| `/vflip list` | Print a shopping list of the top flips |
| `/vflip vendors` | List recorded vendors |
| `/vflip forget <name>` | Remove a vendor's recorded stock |
| `/vflip purge [days]` | Remove vendor entries not seen in that many days (default 30) |
| `/vflip resetprices` | Clear scan prices and sales history |

**Margin** is profit ÷ payout after the AH cut. **ROI** is profit ÷ vendor cost. Deposits lost on expired auctions are not included in profit.

## Status

Tested against mocked WoW APIs; live-client testing is ongoing. Horde capital vendor seeds are minimal. The addon learns them as you open merchants.

## License

MIT. See [LICENSE](LICENSE).

## Credits

Recipe vendor data in `RecipeVendors.lua` is derived from WhatsTraining's WoW Forever data, used under the MIT License (see `WhatsTraining-LICENSE.txt`).
