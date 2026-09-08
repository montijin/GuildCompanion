# GuildCompanion

A read-only Ashita v4 addon for era FFXI guild shops.

- Full price range for every item (min/max across the whole stock curve)
- Estimated current stock, derived from the price the shop is currently showing you
- Days until each item reaches its best price
- How many units you can sell before hitting the shop's cap, and how many can be sold *always* even if the cap was reached on the previous day
- Search and filtering (hide non-restocking items, show only items in your inventory)

GuildCompanion never reads game state to act on your behalf; it doesn't inject packets, doesn't interact with the shop menu, and doesn't automate buying or selling. It only reads the same data your client already receives and does the math for you. GuildCompanion cannot see what the actual stock of items are. The stock is entirely derived from reverse calculating the price the items opened with on day change.

## Requirements



- [Ashita v4](https://ashitaxi.com/)

## Installation

1. Download the latest release.
2. Rename the folder to `guildcompanion` (all lowercase) if it isn't already.
3. Place it in `Ashita/addons/`, so you end up with:
   ```
   Ashita/addons/guildcompanion/guildcompanion.lua
   Ashita/addons/guildcompanion/data/shop_data.lua
   ```
4. In-game: `/addon load guildcompanion`

To load it automatically every session if you want, add that same line to your `Ashita/scripts/default.txt` (or whichever startup script your boot config uses).

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
- **Auto-switch between buy/sell windows** — Automatically switched between the sell window and the buy window instead of cluttering the UI with both open at the same time. 
- **Item order** — match the native in-game shop list order, or sort alphabetically
- **Show debug messages** — surfaces internal diagnostic prints (e.g. when an NPC has no matching data)



## Credits

Thanks to Sruon for pointing me in the right direction for memory and packet info as well as creating a very readable guild shop function for LSB. 
