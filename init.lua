stamina = {}
local modname = minetest.get_current_modname()

function stamina.log(level, message, ...)
	return minetest.log(level, ('[%s] %s'):format(modname, message:format(...)))
end

local function get_setting(key, default)
	local setting = minetest.settings:get('stamina.' .. key)
	if setting and not tonumber(setting) then
		stamina.log('warning', 'invalid value for setting %s: %q. Using default %q.', key, setting, default)
	end
	return tonumber(setting) or default
end

stamina.settings = {
	enabled = minetest.settings:get_bool('stamina.enabled', true),
	sprint = minetest.settings:get_bool('stamina.sprint', true),
	sprint_particles = minetest.settings:get_bool('stamina.sprint_particles', true),
	tick = get_setting('tick', 800), -- time in seconds after that 1 saturation point is taken
	tick_min = get_setting('tick_min', 4), -- stamina ticks won't reduce saturation below this level
	health_tick = get_setting('health_tick', 4), -- time in seconds after player gets healed/damaged
	move_tick = get_setting('move_tick', 0.5), -- time in seconds after the movement is checked
	exhaust_dig = get_setting('exhaust_dig', 3), -- exhaustion for digging a node
	exhaust_place = get_setting('exhaust_place', 1), -- exhaustion for placing a node
	exhaust_move = get_setting('exhaust_move', 1.5), -- exhaustion for moving
	exhaust_jump = get_setting('exhaust_jump', 5), -- exhaustion for jumping
	exhaust_craft = get_setting('exhaust_craft', 20), -- exhaustion for crafting
	exhaust_punch = get_setting('exhaust_punch', 40), -- exhaustion for punching
	exhaust_lvl = get_setting('exhaust_lvl', 160), -- exhaustion level at which saturation gets lowered
	heal = get_setting('heal', 1), -- amount of HP a player gains per stamina.health_tick
	heal_lvl = get_setting('heal_lvl', 5), -- minimum saturation needed for healing
	starve = get_setting('starve', 1), -- amount of HP a player loses per stamina.health_tick
	starve_lvl = get_setting('starve_lvl', 3), -- maximum stamina needed for starving
	visual_max = get_setting('visual_max', 20), -- hud bar only extends to 20
	sprint_speed = get_setting('sprint_speed', 0.8), -- how much faster a player can run if satiated
	sprint_jump = get_setting('sprint_jump', 0.1), -- how much faster a player can jump if satiated
	sprint_drain = get_setting('sprint_drain', 0.35), -- how fast to drain saturation while sprinting
}
local settings = stamina.settings
local enable_damage = minetest.settings:get_bool("enable_damage")
local armor_mod = minetest.get_modpath("3d_armor") and minetest.global_exists("armor") and armor.def
local player_monoids_mod = minetest.get_modpath("player_monoids") and minetest.global_exists("player_monoids")

local function is_player(player)
	return (
		player and
		not player.is_fake_player and
		player.is_player and
		player:is_player() and
		player.set_attribute and
		player.get_player_name and
		player:get_player_name()
	)
end

local function get_int_attribute(player, key)
	local level = player:get_attribute(key)
	if level then
		return tonumber(level)
	else
		return nil
	end
end

function stamina.get_level(player)
	return get_int_attribute(player, "stamina:level")
end

function stamina.set_level(player, level)
	player:set_attribute("stamina:level", level)
	player:hud_change(
		player:get_attribute("stamina:hud_id"),
		"number",
		math.min(settings.visual_max, level)
	)
end

stamina.registered_on_update_levels = {}
function stamina.register_on_update_level(fun)
	table.insert(stamina.registered_on_update_levels, fun)
end

function stamina.update_level(player, level)
	for _, callback in ipairs(stamina.registered_on_update_levels) do
		local result = callback(player, level)
		if result then
			return result
		end
	end

	local old = stamina.get_level(player)

	if level == old then  -- To suppress HUD update
		return
	end

	-- players without interact priv cannot eat
	if old < settings.heal_lvl and not minetest.check_player_privs(player, {interact=true}) then
		return
	end

	stamina.set_level(player, level)
end

function stamina.change(player, change)
	if not is_player(player) or not change or change == 0 then
		return false
	end
	local level = stamina.get_level(player) + change
	level = math.max(level, 0)
	level = math.min(level, settings.visual_max)
	stamina.update_level(player, level)
	return true
end

function stamina.is_poisoned(player)
	return player:get_attribute("stamina:poisoned") == "yes"
end

function stamina.set_poisoned(player, poisoned)
	if poisoned then
		player:set_attribute("stamina:poisoned", "yes")
	else
		player:set_attribute("stamina:poisoned", "no")
	end
end

local function poison_tick(player, ticks, interval, elapsed)
	if not stamina.is_poisoned(player) then
		return
	elseif elapsed > ticks then
		player:hud_change(player:get_attribute("stamina:hud_id"), "text", "stamina_hud_fg.png")
		stamina.set_poisoned(player, false)
	else
		local hp = player:get_hp() - 1
		if hp > 0 then
			player:set_hp(hp)
		end
		minetest.after(interval, poison_tick, player, ticks, interval, elapsed + 1)
	end
end

stamina.registered_on_poisons = {}
function stamina.register_on_poison(fun)
	table.insert(stamina.registered_on_poisons, fun)
end

function stamina.poison(player, ticks, interval)
	for _, fun in ipairs(stamina.registered_on_poisons) do
		local rv = fun(player, ticks, interval)
		if rv == true then
			return
		end
	end
	if not is_player(player) then
		return
	end
	stamina.set_poisoned(player, true)
	player:hud_change(player:get_attribute("stamina:hud_id"), "text", "stamina_hud_poison.png")
	poison_tick(player, ticks, interval, 0)
end

function stamina.get_exhaustion(player)
	return get_int_attribute(player, "stamina:exhaustion")
end

function stamina.set_exhaustion(player, exhaustion)
	player:set_attribute("stamina:exhaustion", exhaustion)
end

stamina.registered_on_exhaust_players = {}
function stamina.register_on_exhaust_player(fun)
	table.insert(stamina.registered_on_exhaust_players, fun)
end

function stamina.exhaust_player(player, change, cause)
	for _, fun in ipairs(stamina.registered_on_exhaust_players) do
		local rv = fun(player, change, cause)
		if rv == true then
			return
		end
	end

	if not is_player(player) then
		return
	end

	local exhaustion = stamina.get_exhaustion(player) or 0

	exhaustion = exhaustion + change

	if exhaustion > settings.exhaust_lvl then
		exhaustion = 0
		stamina.change(player, -1)
	end

	stamina.set_exhaustion(player, exhaustion)
end

-- Sprint settings and function
stamina.registered_on_sprintings = {}
function stamina.register_on_sprinting(fun)
	table.insert(stamina.registered_on_sprintings, fun)
end

function stamina.set_sprinting(player, sprinting)
	for _, fun in ipairs(stamina.registered_on_sprintings) do
		local rv = fun(player, sprinting)
		if rv == true then
			return
		end
	end

	if player_monoids_mod then
		if sprinting then
			player_monoids.speed:add_change(player, 1 + settings.sprint_speed, "stamina:physics")
			player_monoids.jump:add_change(player, 1 + settings.sprint_jump, "stamina:physics")
		else
			player_monoids.speed:del_change(player, "stamina:physics")
			player_monoids.jump:del_change(player, "stamina:physics")
		end
	else
		local def
		if armor_mod then
			-- Get player physics from 3d_armor mod
			local name = player:get_player_name()
			def = {
				speed=armor.def[name].speed,
				jump=armor.def[name].jump,
				gravity=armor.def[name].gravity
			}
		else
			def = {
				speed=1,
				jump=1,
				gravity=1
			}
		end

		if sprinting then
			def.speed = def.speed + settings.sprint_speed
			def.jump = def.jump + settings.sprint_jump
		end

		player:set_physics_override(def)
	end
end

-- Time based stamina functions
local stamina_timer = 0
local health_timer = 0
local action_timer = 0

local function stamina_globaltimer(dtime)
	stamina_timer = stamina_timer + dtime
	health_timer = health_timer + dtime
	action_timer = action_timer + dtime

	if action_timer > settings.move_tick then
		for _,player in ipairs(minetest.get_connected_players()) do
			local controls = player:get_player_control()
			-- Determine if the player is walking
			if controls.jump then
				stamina.exhaust_player(player, settings.exhaust_jump, 'jump')
			elseif controls.up or controls.down or controls.left or controls.right then
				stamina.exhaust_player(player, settings.exhaust_move, 'move')
			end

			--- START sprint
			if settings.sprint then
				-- check if player can sprint (stamina must be over 6 points)
				if controls.aux1 and controls.up
				and not minetest.check_player_privs(player, {fast = true})
				and stamina.get_level(player) > 6 then

					stamina.set_sprinting(player, true)

					-- create particles behind player when sprinting
					if settings.sprint_particles then

						local pos = player:getpos()
						local node = minetest.get_node({
							x = pos.x, y = pos.y - 1, z = pos.z})

						if node.name ~= "air" then

						minetest.add_particlespawner({
							amount = 5,
							time = 0.01,
							minpos = {x = pos.x - 0.25, y = pos.y + 0.1, z = pos.z - 0.25},
							maxpos = {x = pos.x + 0.25, y = pos.y + 0.1, z = pos.z + 0.25},
							minvel = {x = -0.5, y = 1, z = -0.5},
							maxvel = {x = 0.5, y = 2, z = 0.5},
							minacc = {x = 0, y = -5, z = 0},
							maxacc = {x = 0, y = -12, z = 0},
							minexptime = 0.25,
							maxexptime = 0.5,
							minsize = 0.5,
							maxsize = 1.0,
							vertical = false,
							collisiondetection = false,
							texture = "default_dirt.png",
						})

						end
					end

					-- Lower the player's stamina when sprinting
					local level = stamina.get_level(player)
					stamina.update_level(player, level - (settings.sprint_drain * settings.move_tick))
				else
					stamina.set_sprinting(player, false)
				end
			end
			-- END sprint

		end
		action_timer = 0
	end

	-- lower saturation by 1 point after settings.tick second(s)
	if stamina_timer > settings.tick then
		for _,player in ipairs(minetest.get_connected_players()) do
			local h = stamina.get_level(player)
			if h > settings.tick_min then
				stamina.update_level(player, h - 1)
			end
		end
		stamina_timer = 0
	end

	-- heal or damage player, depending on saturation
	if health_timer > settings.health_tick then
		for _,player in ipairs(minetest.get_connected_players()) do
			local air = player:get_breath() or 0
			local hp = player:get_hp()

			-- don't heal if drowning or dead
			-- TODO: don't heal if poisoned?
			local h = stamina.get_level(player)
			if h >= settings.heal_lvl and h >= hp and hp > 0 and air > 0
					and not stamina.is_poisoned(player) then
				player:set_hp(hp + settings.heal)
				stamina.update_level(player, h - 1)
			end

			-- or damage player by 1 hp if saturation is < 2 (of 30)
			if stamina.get_level(player) < settings.starve_lvl and hp > 0 then
				player:set_hp(hp - settings.starve)
			end
		end

		health_timer = 0
	end
end

-- override minetest.do_item_eat() so we can redirect hp_change to stamina
stamina.core_item_eat = minetest.do_item_eat
function minetest.do_item_eat(hp_change, replace_with_item, itemstack, player, pointed_thing)
	for _, callback in ipairs(minetest.registered_on_item_eats) do
		local result = callback(hp_change, replace_with_item, itemstack, player, pointed_thing)
		if result then
			return result
		end
	end

	if not is_player(player) or not itemstack then
		return itemstack
	end

	local level = stamina.get_level(player) or 0
	if level >= settings.visual_max then
		return itemstack
	end

	if hp_change > 0 then
		level = level + hp_change
		stamina.update_level(player, level)
	else
		-- assume hp_change < 0.
		stamina.poison(player, 2.0, -hp_change)
	end

	minetest.sound_play("stamina_eat", {to_player = player:get_player_name(), gain = 0.7})

	-- particle effect when eating
	local pos = player:getpos()
	pos.y = pos.y + 1.5 -- mouth level
	local itemname = itemstack:get_name()
	local texture  = minetest.registered_items[itemname].inventory_image
	local dir = player:get_look_dir()

	minetest.add_particlespawner({
		amount = 5,
		time = 0.1,
		minpos = pos,
		maxpos = pos,
		minvel = {x = dir.x - 1, y = dir.y, z = dir.z - 1},
		maxvel = {x = dir.x + 1, y = dir.y, z = dir.z + 1},
		minacc = {x = 0, y = -5, z = 0},
		maxacc = {x = 0, y = -9, z = 0},
		minexptime = 1,
		maxexptime = 1,
		minsize = 1,
		maxsize = 2,
		texture = texture,
	})

	itemstack:take_item()

	if replace_with_item then
		if itemstack:is_empty() then
			itemstack:add_item(replace_with_item)
		else
			local inv = player:get_inventory()
			if inv:room_for_item("main", {name=replace_with_item}) then
				inv:add_item("main", replace_with_item)
			else
				pos.y = math.floor(pos.y - 1.0)
				minetest.add_item(pos, replace_with_item)
			end
		end
	end

	return itemstack
end

-- stamina is disabled if damage is disabled
if enable_damage and settings.enabled then
	minetest.register_on_joinplayer(function(player)
		local level = stamina.get_level(player) or settings.visual_max
		local id = player:hud_add({
			name = "stamina",
			hud_elem_type = "statbar",
			position = {x = 0.5, y = 1},
			size = {x = 24, y = 24},
			text = "stamina_hud_fg.png",
			number = level,
			alignment = {x = -1, y = -1},
			offset = {x = -266, y = -110},
			max = 0,
		})
		stamina.set_level(player, level)
		player:set_attribute("stamina:hud_id", id)
		-- reset poisoned
		stamina.set_poisoned(player, false)
	end)

	minetest.register_globalstep(stamina_globaltimer)

	minetest.register_on_placenode(function(pos, oldnode, player, ext)
		stamina.exhaust_player(player, settings.exhaust_place, 'place')
	end)
	minetest.register_on_dignode(function(pos, oldnode, player, ext)
		stamina.exhaust_player(player, settings.exhaust_dig, 'dig')
	end)
	minetest.register_on_craft(function(itemstack, player, old_craft_grid, craft_inv)
		stamina.exhaust_player(player, settings.exhaust_craft, 'craft')
	end)
	minetest.register_on_punchplayer(function(player, hitter, time_from_last_punch, tool_capabilities, dir, damage)
		stamina.exhaust_player(hitter, settings.exhaust_punch, 'punch')
	end)
	minetest.register_on_respawnplayer(function(player)
		stamina.update_level(player, settings.visual_max)
	end)
end
