# GuildCompanion

A read-only Ashita v4 addon for FFXI guild shops on **PhoenixXI** (LandSandBoat). It pops up an info window whenever you're browsing a guild NPC's buy or sell list, showing you things the native shop UI doesn't:

- Full price range for every item (min/max across the whole stock curve)
- Estimated current stock, derived from the price the shop is currently showing you
- Days until the item reaches its best price
- How many units you can sell before hitting the shop's cap, and how many you can *always* sell even on a "full" day
- Search and filtering (hide non-restocking items, show only items in your inventory)

GuildCompanion never reads game state to act on your behalf — it doesn't inject packets, doesn't interact with the shop menu, and doesn't automate buying or selling. It only reads the same data your client already receives and does the math for you.

## Requirements

This addon is built specifically for **PhoenixXI**'s LandSandBoat fork. The guild shop price curve formulas, packet IDs, and per-NPC stock data (`data/shop_data.lua`) are all derived from this server's specific `guild_shops.lua`/`era_guild_shops.lua` source and validated against its own test suite. It is very unlikely to produce correct numbers on a different LSB server or on retail-accurate emulators without regenerating `shop_data.lua` from that server's own data.

- [Ashita v4](https://ashitaxi.com/)
- A PhoenixXI client

## Installation

1. Download or clone this repository.
2. Rename the folder to `guildcompanion` (all lowercase) if it isn't already.
3. Place it in `Ashita/addons/`, so you end up with:
   ```
   Ashita/addons/guildcompanion/guildcompanion.lua
   Ashita/addons/guildcompanion/data/shop_data.lua
   Ashita/addons/guildcompanion/data/vendor_floor.lua
   ```
4. In-game: `/addon load guildcompanion`

To load it automatically every session, add that same line to your `Ashita/scripts/default.txt` (or whichever startup script your boot config uses).

## Commands

| Command | Effect |
|---|---|
| `/gc toggle` | Show/hide the buy window |
| `/gc buy` | Switch to the buy window |
| `/gc sell` | Switch to the sell window |
| `/gc autohide` | Toggle auto-hiding when the shop closes |
| `/gc settings` | Open the settings window |
| `/gc help` | Show help text and open settings |
| `/gc debug` | Print current internal state (for troubleshooting) |
| `/gc unload` | Unload the addon |

## Settings

Accessible via `/gc settings`, persisted to `config/addons/GuildCompanion/settings.lua`:

- **UI Scale** — resizes the windows and search boxes for different resolutions
- **Auto-hide when shop closes** — automatically hides both windows when you leave the shop
- **Auto-switch between buy/sell windows** — best-effort: when a fresh buy or sell packet arrives, shows that window and hides the other. Only fires when the client actually sends a new packet, so it won't catch every single tab switch — the in-window "Switch to Buy"/"Switch to Sell" buttons and the `/gc buy`/`/gc sell` commands are the reliable fallback.
- **Item order** — match the native in-game shop list order, or sort alphabetically
- **Show debug messages** — surfaces internal diagnostic prints (e.g. when an NPC has no matching data)

## Known limitations

- **A handful of items are flagged `-- REVIEW` in `data/shop_data.lua`.** These resolved to an itemID via a fallback name-matching heuristic (mostly fish/variant items sharing a base name) rather than an exact match, and haven't been individually verified.
- **A few items have no data at all** (`FLASH_OF_VITRIOL`, `SARUTABARUTA_ORANGE`, `SAN_DORIAN_GRAPE`) — no matching entry was found in the source item database.
- **Shops with more than 30 sellable items** only reveal their full catalog as you naturally browse — the game only ever sends a 30-item window per packet, so GuildCompanion merges what it sees across multiple packets rather than replacing the list each time.
- **The auto-switch between buy/sell windows is a heuristic**, not a true "tab changed" detection — see the settings note above.
- Data reflects this server's guild shop tables at the time `shop_data.lua` was generated. If `era_guild_shops.lua` changes (new item corrections, price floor overrides, etc.), the data file needs to be regenerated to stay accurate.

## Credits

Built by Monti for PhoenixXI. Guild shop price curve formulas and per-NPC stock data sourced from and validated against PhoenixXI's own `guild_shops.lua`, `era_guild_shops.lua`, and LSB test suite (`price_curves.lua`, `daily_roll.lua`, `selling.lua`, `buying.lua`).
