# Shops, items and status effects

A merchant is an NPC with stock. Buying is a dialogue choice. An item is a
row in a catalogue, and what drinking it does is another row in another
catalogue. No part of that is code you have to write to add the second shop.

```
data/items/items.json           what exists, what it costs, what using it does
data/items/status_effects.json  the timed states an item can cause
data/shops/<id>.json            one merchant's stock and prices
data/npcs/<id>.json  "shop"     which merchant that is
dialogue/<id>.json   "buy"      the choice that spends the marks
```

The purse, the pack and the running effects live in `GameState`, next to the
quest flags and saved with them. There is no new autoload and no inventory
scene: an item you are carrying is an entry in a dictionary.

## The currency

The code calls it `gold`; Port Azure calls it marks. Prices are integers, and
`GameState.spend_gold()` is the only place one is charged — it refuses rather
than going negative, so a caller branches on the result instead of checking
the purse first.

## Adding an item

```json
"beer_bottle": {
  "display_name": "Bottle of Harbour Ale",
  "description": "Brown glass, no label.",
  "price": 5,
  "use": { "consumed": true, "effect": "tipsy", "text": "You drink the ale." }
}
```

`use` is optional — an item without one is cargo. `effect` must name an entry
in `status_effects.json`, `text` is what the player is told, and `consumed`
defaults to true because most usables are spent.

## Adding a status effect

```json
"tipsy": {
  "display_name": "Tipsy",
  "duration": 30.0,
  "modifiers": { "speed_scale": 0.85 },
  "start_text": "The room tilts a little.",
  "end_text": "The room levels out."
}
```

**A modifier is a number gameplay asks for, never a state gameplay checks.**
`Player` multiplies its speed by `GameState.modifier("speed_scale")` and has
no idea what ale is. That is what makes a second drink a JSON entry.

The vocabulary is `StatusEffects.MODIFIERS`, which is also the range check: a
key nothing reads, or a value outside its range, fails CI rather than quietly
doing nothing. Adding a modifier means adding it there *and* reading it
somewhere — one without the other is not a feature.

Re-applying a running effect refreshes its clock rather than stacking it. Two
ales are a longer evening, not a stronger one.

## Adding a merchant

1. `data/shops/<id>.json` — a `display_name` and a `stock` array. An entry is
   `{"item": "<id>"}`, plus `"price"` only where this merchant disagrees with
   the catalogue.
2. `"shop": "<id>"` on the NPC definition. That is what makes them a merchant;
   `Npc.interact()` hands the id to `Dialogue.start()`.
3. A `buy` choice in their conversation:

```json
{ "text": "One bottle. (5 marks)", "buy": "beer_bottle",
  "next": "poured", "else": "short" }
```

`buy` spends against **the shop the conversation was started with**, so the
same script read anywhere else sells nothing. A refused sale takes `else` and
applies none of the choice's `set` flags: the flags describe what happened,
and on that branch it did not happen.

Two other one-way effects exist on any node or choice: `give_gold` (a payout)
and `give_item` (a gift). Unlike a purchase they cannot fail, so nothing
branches on them.

## Reading the purse in dialogue

`requires` understands three keys beyond flags:

```json
{ "requires": { "gold_at_least": 5 } }
{ "requires": { "has_item": "beer_bottle" } }
{ "requires": { "effect_active": "tipsy" } }
```

Gating the offer on `gold_at_least` is a matter of taste — Mira offers it
either way and turns you down out loud, which is more in character than an
option that silently is not there.

## Using an item

`use_item` (Q) drinks the first usable thing in the pack and shows the item's
`text`. One key, no menu: with one bottle on you that is the whole
interaction. `GameState.use_item()` is what a menu would call the day there
is one.

## What CI already checks

- Every item has a name, a description and a price above zero; every usable
  one names an effect that exists and says something when used.
- Every effect lasts longer than nothing and moves at least one modifier the
  code actually reads, within range.
- Every shop sells at least one real item at a real price.
- Every shop is kept by an NPC, and every NPC's shop exists — a price list
  nobody stands behind can never be seen.
- Every `buy` choice names a real item, is offered by a merchant's own
  conversation, and that merchant stocks it. Its `else` lands on a real node.
- The purse, the pack and running effects survive a save.
- Drinking the ale in the running game slows the walk
  (`tests/test_runtime.gd::test_drinking_the_ale_slows_the_walk`) — the test
  that fails if a modifier stops reaching movement.
