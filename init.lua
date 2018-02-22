
stamina = {}

STAMINA_TICK = 800		-- time in seconds after that 1 stamina point is taken
STAMINA_TICK_MIN = 4		-- stamina ticks won't reduce stamina below this level
STAMINA_HEALTH_TICK = 4		-- time in seconds after player gets healed/damaged
STAMINA_MOVE_TICK = 0.5		-- time in seconds after the movement is checked

STAMINA_EXHAUST_DIG = 3		-- exhaustion increased this value after digged node
STAMINA_EXHAUST_PLACE = 1	-- .. after digging node
STAMINA_EXHAUST_MOVE = 1.5	-- .. if player movement detected
STAMINA_EXHAUST_JUMP = 5	-- .. if jumping
STAMINA_EXHAUST_CRAFT = 20	-- .. if player crafts
STAMINA_EXHAUST_PUNCH = 40	-- .. if player punches another player
STAMINA_EXHAUST_LVL = 160	-- at what exhaustion player saturation gets lowered

STAMINA_HEAL = 1		-- number of HP player gets healed after STAMINA_HEALTH_TICK
STAMINA_HEAL_LVL = 5		-- lower level of saturation needed to get healed
STAMINA_STARVE = 1		-- number of HP player gets damaged by stamina after STAMINA_HEALTH_TICK
STAMINA_STARVE_LVL = 3		-- level of staturation that causes starving

STAMINA_VISUAL_MAX = 20		-- hud bar extends only to 20

SPRINT_SPEED = 0.8		-- how much faster player can run if satiated
SPRINT_JUMP = 0.1		-- how much higher player can jump if satiated
SPRINT_DRAIN = 0.35		-- how fast to drain satation while sprinting (0-1)

local function get_int_attribute(player, key)
	local level = player:get_attribute(key)
	if level then
		return tonumber(level)
	else
		return nil
	end
end

local function stamina_update_level(player, level)
	local old = get_int_attribute(player, "stamina:level")

	if level == old then  -- To suppress HUD update
		return
	end

	player:set_attribute("stamina:level", level)

	player:hud_change(player:get_attribute("stamina:hud_id"), "number", math.min(STAMINA_VISUAL_MAX, level))
end

local function stamina_is_poisoned(player)
	return player:get_attribute("stamina:poisoned") == "yes"
end

local function stamina_set_poisoned(player, poisoned)
	if poisoned then
		player:set_attribute("stamina:poisoned", "yes")
	else
		player:set_attribute("stamina:poisoned", "no")
	end
end

local function stamina_get_exhaustion(player)
	return get_int_attribute(player, "stamina:exhaustion")
end

-- global function for mods to amend stamina level
stamina.change = function(player, change)
	local name = player:get_player_name()
	if not name or not change or change == 0 then
		return false
	end
	local level = get_int_attribute(player, "stamina:level") + change
	if level < 0 then level = 0 end
	if level > STAMINA_VISUAL_MAX then level = STAMINA_VISUAL_MAX end
	stamina_update_level(player, level)
	return true
end

local function exhaust_player(player, v)
	if not player or not player.is_player or not player:is_player() or not player.set_attribute then
		return
	end

	local name = player:get_player_name()
	if not name then
		return
	end

	local exhaustion = stamina_get_exhaustion(player) or 0

	exhaustion = exhaustion + v

	if exhaustion > STAMINA_EXHAUST_LVL then
		exhaustion = 0
		local h = get_int_attribute(player, "stamina:level")
		if h > 0 then
			stamina_update_level(player, h - 1)
		end
	end

	player:set_attribute("stamina:exhaustion", exhaustion)
end

-- Sprint settings and function
local enable_sprint = minetest.setting_getbool("sprint") ~= false
local enable_sprint_particles = minetest.setting_getbool("sprint_particles") ~= false
local armor_mod = minetest.get_modpath("3d_armor")

function set_sprinting(name, sprinting)
	local player = minetest.get_player_by_name(name)
	local def = {}
	-- Get player physics from 3d_armor mod
	if armor_mod and armor and armor.def then
		def.speed = armor.def[name].speed
		def.jump = armor.def[name].jump
		def.gravity = armor.def[name].gravity
	end

	def.speed = def.speed or 1
	def.jump = def.jump or 1
	def.gravity = def.gravity or 1

	if sprinting == true then

		def.speed = def.speed + SPRINT_SPEED
		def.jump = def.jump + SPRINT_JUMP
	end

	player:set_physics_override({
		speed = def.speed,
		jump = def.jump,
		gravity = def.gravity
	})
end

-- Time based stamina functions
local stamina_timer = 0
local health_timer = 0
local action_timer = 0

local function stamina_globaltimer(dtime)
	stamina_timer = stamina_timer + dtime
	health_timer = health_timer + dtime
	action_timer = action_timer + dtime

	if action_timer > STAMINA_MOVE_TICK then
		for _,player in ipairs(minetest.get_connected_players()) do
			local controls = player:get_player_control()
			-- Determine if the player is walking
			if controls.jump then
				exhaust_player(player, STAMINA_EXHAUST_JUMP)
			elseif controls.up or controls.down or controls.left or controls.right then
				exhaust_player(player, STAMINA_EXHAUST_MOVE)
			end

			--- START sprint
			if enable_sprint then

				local name = player:get_player_name()

				-- check if player can sprint (stamina must be over 6 points)
				if controls.aux1 and controls.up
				and not minetest.check_player_privs(player, {fast = true})
				and get_int_attribute(player, "stamina:level") > 6 then

					set_sprinting(name, true)

					-- create particles behind player when sprinting
					if enable_sprint_particles then

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
					local level = get_int_attribute(player, "stamina:level")
					stamina_update_level(player, level - (SPRINT_DRAIN * STAMINA_MOVE_TICK))
				else
					set_sprinting(name, false)
				end
			end
			-- END sprint

		end
		action_timer = 0
	end

	-- lower saturation by 1 point after STAMINA_TICK second(s)
	if stamina_timer > STAMINA_TICK then
		for _,player in ipairs(minetest.get_connected_players()) do
			local h = get_int_attribute(player, "stamina:level")
			if h > STAMINA_TICK_MIN then
				stamina_update_level(player, h - 1)
			end
		end
		stamina_timer = 0
	end

	-- heal or damage player, depending on saturation
	if health_timer > STAMINA_HEALTH_TICK then
		for _,player in ipairs(minetest.get_connected_players()) do
			local air = player:get_breath() or 0
			local hp = player:get_hp()

			-- don't heal if drowning or dead
			-- TODO: don't heal if poisoned?
			local h = get_int_attribute(player, "stamina:level")
			if h >= STAMINA_HEAL_LVL and h >= hp and hp > 0 and air > 0
					and not stamina_is_poisoned(player) then
				player:set_hp(hp + STAMINA_HEAL)
				stamina_update_level(player, h - 1)
			end

			-- or damage player by 1 hp if saturation is < 2 (of 30)
			if get_int_attribute(player, "stamina:level") < STAMINA_STARVE_LVL then
				player:set_hp(hp - STAMINA_STARVE)
			end
		end

		health_timer = 0
	end
end

local function poison_player(ticks, time, elapsed, user)
	if elapsed <= ticks then
		minetest.after(time, poison_player, ticks, time, elapsed + 1, user)
		stamina_set_poisoned(user,true)
	else
		user:hud_change(user:get_attribute("stamina:hud_id"), "text", "stamina_hud_fg.png")
		stamina_set_poisoned(user,false)
	end
	local hp = user:get_hp() -1 or 0
	if hp > 0 then
		user:set_hp(hp)
	end
end

-- override core.do_item_eat() so we can redirect hp_change to stamina
core.do_item_eat = function(hp_change, replace_with_item, itemstack, user, pointed_thing)
	local old_itemstack = itemstack
	itemstack = stamina.eat(hp_change, replace_with_item, itemstack, user, pointed_thing)
	for _, callback in pairs(core.registered_on_item_eats) do
		local result = callback(hp_change, replace_with_item, itemstack, user, pointed_thing, old_itemstack)
		if result then
			return result
		end
	end
	return itemstack
end

-- not local since it's called from within core context
function stamina.eat(hp_change, replace_with_item, itemstack, user, pointed_thing)
	if not itemstack then
		return itemstack
	end

	if not user then
		return itemstack
	end

	local level = get_int_attribute(user, "stamina:level") or 0
	if level >= STAMINA_VISUAL_MAX then
		return itemstack
	end

	if hp_change > 0 then
		level = level + hp_change
		stamina_update_level(user, level)
	else
		-- assume hp_change < 0.
		user:hud_change(user:get_attribute("stamina:hud_id"), "text", "stamina_hud_poison.png")
		poison_player(2.0, -hp_change, 0, user)
	end

	minetest.sound_play("stamina_eat", {to_player = user:get_player_name(), gain = 0.7})

	-- particle effect when eating
	local pos = user:getpos()
	pos.y = pos.y + 1.5 -- mouth level
	local itemname = itemstack:get_name()
	local texture  = minetest.registered_items[itemname].inventory_image
	local dir = user:get_look_dir()

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
			local inv = user:get_inventory()
			if inv:room_for_item("main", {name=replace_with_item}) then
				inv:add_item("main", replace_with_item)
			else
				pos.y = math.floor(pos.y - 1.0)
				core.add_item(pos, replace_with_item)
			end
		end
	end

	return itemstack
end

-- stamina is disabled if damage is disabled
if minetest.setting_getbool("enable_damage") and minetest.is_yes(minetest.setting_get("enable_stamina") or "1") then
	minetest.register_on_joinplayer(function(player)
		local level = STAMINA_VISUAL_MAX -- TODO
		if get_int_attribute(player, "stamina:level") then
			level = math.min(get_int_attribute(player, "stamina:level"), STAMINA_VISUAL_MAX)
		else
			player:set_attribute("stamina:level", level)
		end
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
		player:set_attribute("stamina:hud_id", id)
		-- reset poisoned
		player:set_attribute("stamina:poisoned", "no")
	end)

	minetest.register_globalstep(stamina_globaltimer)

	minetest.register_on_placenode(function(pos, oldnode, player, ext)
		exhaust_player(player, STAMINA_EXHAUST_PLACE)
	end)
	minetest.register_on_dignode(function(pos, oldnode, player, ext)
		exhaust_player(player, STAMINA_EXHAUST_DIG)
	end)
	minetest.register_on_craft(function(itemstack, player, old_craft_grid, craft_inv)
		exhaust_player(player, STAMINA_EXHAUST_CRAFT)
	end)
	minetest.register_on_punchplayer(function(player, hitter, time_from_last_punch, tool_capabilities, dir, damage)
		exhaust_player(hitter, STAMINA_EXHAUST_PUNCH)
	end)

	minetest.register_on_respawnplayer(function(player)
		stamina_update_level(player, STAMINA_VISUAL_MAX)
	end)
end
