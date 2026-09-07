## Buying things, carrying them, and drinking them.
##
## The data pass proves the catalogues agree with each other -- an item priced
## at nothing, an effect nobody reads, a shop selling something that does not
## exist. The play pass then walks Mira's counter the way a player does:
## choose, pay, carry, drink, sober up.
extends TestCase


func after_each() -> void:
	Dialogue.stop()
	GameState.reset()


# --------------------------------------------------------------------------
# the catalogues
# --------------------------------------------------------------------------

func test_item_and_effect_catalogues_are_sound() -> void:
	expect_no_errors(StatusEffects.validate(), "data/items/status_effects.json")
	expect_no_errors(ItemRegistry.validate(), "data/items/items.json")
	ok(ItemRegistry.names().size() > 0, "there are no items in data/items/items.json")


func test_every_shop_is_sound() -> void:
	var ids := Shop.all_ids()
	ok(ids.size() > 0, "there are no shops in data/shops/")
	for shop_id: String in ids:
		expect_no_errors(Shop.validate(shop_id), "data/shops/%s.json" % shop_id)


## A shop file nobody stands behind is a price list the player can never see.
func test_every_shop_is_kept_by_an_npc() -> void:
	var kept: Dictionary = {}
	for npc_id: String in Npc.all_ids():
		var shop_id := String(Npc.load_def(npc_id).get("shop", ""))
		if shop_id.is_empty():
			continue
		ok(Shop.exists(shop_id),
			"npc '%s' keeps shop '%s', but data/shops/%s.json does not exist"
				% [npc_id, shop_id, shop_id])
		kept[shop_id] = npc_id
	for shop_id: String in Shop.all_ids():
		ok(kept.has(shop_id),
			"shop '%s' is defined but no npc keeps it; nobody can ever buy from it" % shop_id)


## A `buy` choice only works across a counter, so the dialogue that offers one
## has to belong to a merchant who actually stocks the item.
func test_every_purchase_offered_is_stocked_by_the_merchant_offering_it() -> void:
	var shop_of_dialogue: Dictionary = {}
	for npc_id: String in Npc.all_ids():
		var def := Npc.load_def(npc_id)
		var shop_id := String(def.get("shop", ""))
		if not shop_id.is_empty():
			shop_of_dialogue[String(def.get("dialogue", npc_id))] = shop_id

	var offered := 0
	for dialogue_id: String in Dialogue.all_ids():
		var nodes: Dictionary = Dialogue.load_graph(dialogue_id).get("nodes", {})
		for node_id: String in nodes:
			for choice: Variant in nodes[node_id].get("choices", []):
				if not (choice is Dictionary):
					continue
				var item_id := String((choice as Dictionary).get("buy", ""))
				if item_id.is_empty():
					continue
				offered += 1
				if not ok(shop_of_dialogue.has(dialogue_id),
						"dialogue '%s' sells '%s' but no merchant uses that conversation"
							% [dialogue_id, item_id]):
					continue
				var shop_id: String = shop_of_dialogue[dialogue_id]
				ok(Shop.sells(shop_id, item_id),
					"dialogue '%s' sells '%s', which shop '%s' does not stock"
						% [dialogue_id, item_id, shop_id])
	ok(offered > 0, "no conversation in dialogue/ ever offers anything for sale")


# --------------------------------------------------------------------------
# the purse and the pack
# --------------------------------------------------------------------------

func test_buying_moves_marks_into_goods() -> void:
	GameState.gold = 10
	var price := Shop.price_of("salt_and_sextant", "beer_bottle")
	equal(GameState.buy("salt_and_sextant", "beer_bottle"), "", "the sale was refused")
	equal(GameState.gold, 10 - price, "the price was not taken out of the purse")
	equal(GameState.item_count("beer_bottle"), 1, "the bottle did not reach the pack")


func test_an_empty_purse_buys_nothing() -> void:
	GameState.gold = 1
	not_empty(GameState.buy("salt_and_sextant", "beer_bottle"), "a broke player was still sold to")
	equal(GameState.gold, 1, "marks moved on a refused sale")
	ok(not GameState.has_item("beer_bottle"), "a refused sale still handed over the goods")


func test_a_merchant_only_sells_what_they_stock() -> void:
	GameState.gold = 999
	not_empty(GameState.buy("salt_and_sextant", "not_an_item"),
		"the shop sold something that does not exist")
	equal(GameState.gold, 999, "a refused sale still charged the player")


# --------------------------------------------------------------------------
# drinking it
# --------------------------------------------------------------------------

func test_using_the_ale_applies_its_effect_and_spends_the_bottle() -> void:
	GameState.add_item("beer_bottle")
	ok(GameState.use_item("beer_bottle"), "the bottle would not be used")
	ok(not GameState.has_item("beer_bottle"), "a consumed item stayed in the pack")
	ok(GameState.effect_active("tipsy"), "drinking the ale left the player unaffected")
	equal(GameState.modifier("speed_scale"),
		float(StatusEffects.modifiers("tipsy")["speed_scale"]),
		"the effect's modifier is not being read")


func test_an_item_you_do_not_have_cannot_be_used() -> void:
	ok(not GameState.use_item("beer_bottle"), "an empty pack still produced a drink")
	ok(not GameState.effect_active("tipsy"), "an effect started without an item")


func test_an_effect_wears_off() -> void:
	GameState.add_item("beer_bottle")
	GameState.use_item("beer_bottle")
	var ended: Array = []
	GameState.effect_ended.connect(func(id: String) -> void: ended.append(id))
	# Time is data too: run the clock past whatever the JSON says it lasts.
	GameState._process(StatusEffects.duration("tipsy") + 1.0)
	ok(not GameState.effect_active("tipsy"), "the effect never expired")
	ok(ended.has("tipsy"), "nothing was told the effect ended")
	equal(GameState.modifier("speed_scale"), 1.0, "the modifier outlived the effect")


func test_drinking_twice_refreshes_rather_than_stacks() -> void:
	GameState.add_item("beer_bottle", 2)
	GameState.use_item("beer_bottle")
	GameState._process(StatusEffects.duration("tipsy") * 0.5)
	GameState.use_item("beer_bottle")
	equal(GameState.effect_remaining("tipsy"), StatusEffects.duration("tipsy"),
		"the second bottle did not refresh the clock")
	equal(GameState.modifier("speed_scale"),
		float(StatusEffects.modifiers("tipsy")["speed_scale"]),
		"two bottles stacked into a stronger effect")


# --------------------------------------------------------------------------
# across the counter
# --------------------------------------------------------------------------

## The path a player actually takes: talk to Mira, pick the drink, pay, and
## end up holding a bottle. This is the test that fails if the `buy` choice
## stops being wired to the shop.
func test_buying_through_maras_conversation() -> void:
	GameState.gold = 10
	ok(Dialogue.start("bartender", "salt_and_sextant"), "Mira's conversation would not start")
	ok(_walk_to("drink"), "no route through the conversation reaches the drinks")
	var bought := _choose_by_text("One bottle")
	ok(bought, "the drinks menu offers nothing to buy")
	equal(Dialogue.current_node_id(), "poured", "paying up did not pour the drink")
	equal(GameState.item_count("beer_bottle"), 1, "the bottle never reached the pack")
	equal(GameState.gold, 10 - Shop.price_of("salt_and_sextant", "beer_bottle"),
		"the wrong number of marks left the purse")


func test_a_broke_player_is_turned_down_rather_than_given_credit() -> void:
	GameState.gold = 0
	ok(Dialogue.start("bartender", "salt_and_sextant"), "Mira's conversation would not start")
	ok(_walk_to("drink"), "no route through the conversation reaches the drinks")
	ok(_choose_by_text("One bottle"), "the drinks menu offers nothing to buy")
	equal(Dialogue.current_node_id(), "short", "a broke player was not turned down")
	ok(not GameState.has_item("beer_bottle"), "the bottle was handed over unpaid for")


## The same conversation read away from the counter cannot sell: the shop is
## the merchant's, not the script's.
func test_the_same_conversation_sells_nothing_without_a_shop() -> void:
	GameState.gold = 10
	ok(Dialogue.start("bartender"), "Mira's conversation would not start")
	ok(_walk_to("drink"), "no route through the conversation reaches the drinks")
	ok(_choose_by_text("One bottle"), "the drinks menu offers nothing to buy")
	equal(GameState.gold, 10, "marks were spent with no merchant to spend them at")
	ok(not GameState.has_item("beer_bottle"), "goods appeared out of no shop")


## Kesk's payout is what funds a second round, so it has to reach the purse.
func test_the_errand_pays_in_marks() -> void:
	GameState.set_flag("ledger_signed", true)
	var before := GameState.gold
	ok(Dialogue.start("harbormaster"), "Kesk's conversation would not start")
	while Dialogue.is_active() and Dialogue.current_choices().is_empty():
		Dialogue.advance()
	ok(GameState.gold > before, "the ledger errand paid nothing")


# --------------------------------------------------------------------------
# saving
# --------------------------------------------------------------------------

func test_marks_bottles_and_effects_survive_a_save() -> void:
	GameState.gold = 42
	GameState.add_item("beer_bottle", 2)
	GameState.apply_effect("tipsy")
	var saved := GameState.to_dict()
	GameState.reset()
	ok(GameState.from_dict(saved), "the save would not load back")
	equal(GameState.gold, 42, "marks did not survive the save")
	equal(GameState.item_count("beer_bottle"), 2, "the pack did not survive the save")
	ok(GameState.effect_active("tipsy"), "the effect did not survive the save")


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

## Advance and pick options until the named node is on screen. Written as a
## search rather than a fixed script so re-ordering Mira's menu does not
## rewrite the test.
func _walk_to(node_id: String, limit: int = 40) -> bool:
	for step: int in limit:
		if Dialogue.current_node_id() == node_id:
			return true
		if not Dialogue.is_active():
			return false
		var choices := Dialogue.current_choices()
		if choices.is_empty():
			Dialogue.advance()
		else:
			var picked := false
			for i: int in choices.size():
				if String(choices[i].get("next", "")) == node_id:
					Dialogue.choose(i)
					picked = true
					break
			if not picked:
				Dialogue.choose(0)
	return Dialogue.current_node_id() == node_id


func _choose_by_text(fragment: String) -> bool:
	var choices := Dialogue.current_choices()
	for i: int in choices.size():
		if String(choices[i].get("text", "")).contains(fragment):
			Dialogue.choose(i)
			return true
	return false
