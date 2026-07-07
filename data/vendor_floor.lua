-- vendor_floor.lua
-- Infinite-stock ("regular") NPC vendor prices, best-case fame tier, keyed by itemId.
-- This is the comparison table for the "cheaper elsewhere" check -- it is NOT the same
-- data as shop_data.lua (which is depleting-stock guild shop items on the buy curve).
--
-- STUB: not populated yet. Source this from the FFXI Synth Finder vendor-flip tab /
-- auction_audit.db (the fixed-price general vendors, not Tenshodo/guild shops).
-- Shape once populated:
--   [itemId] = { price = 45, npc = 'Some_Vendor' },
return {}
