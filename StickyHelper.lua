---@diagnostic disable: undefined-global

-- [[ Whether to enable auto detonation ]]
local AUTO_DETONATE = true

-- [[ Auto detonate key. Set to -1 to disable ]]
local AUTO_DETONATE_KEY = -1

-- [[ Auto detonate visible only ]]
local AUTO_DETONATE_VISIBLE_ONLY = false

-- [[ Set to the percentage of health the estimated damage must reach before detonating. 1 = wait for lethal damage ]]
local AUTO_DETONATE_HEALTH_MULTIPLIER = .3

-- [[ The number of seconds to wait until forcefully detonating stickies. Set to 0 disable ]]
local AUTO_DETONATE_TIMEOUT = .4

-- [[ Whether to draw status]]
local DRAW_STATUS = true

-- [[ Whether to draw arm time circle ]]
local DRAW_ARM_TIME = true

-- [[ Whether to enable auto detonation chat prints ]]
local AUTO_DETONATE_PRINT_CHAT = true

-- [[ Whether to ignore pipes ]]
local IGNORE_PIPES = true

-- [[ Whether to ignore vaccinator ubers ]]
local IGNORE_VACCINATOR = true

-- [[ Whether to sample multiple points to dermine sticky LOS to players ]]
local TRACE_MULTIPOINT = false

-- [[ Whether to ignore players on the same team for sticky calculations when mp_friendlyfire is 1 ]]
local IGNORE_TEAM_FRIENDLYFIRE = false

-- [[ How close a player has to be to a sticky for it to be considered dangerous ]]
local STICKY_RADIUS = 175

-- [[ How often sticky calculations should run in ticks. Lower = more accurate at the cost of performance ]]
local CALC_EVERY = 6
local TRACE_EVERY = CALC_EVERY / 2

local STICKY_TRACE_OFFSET = Vector3(0, 0, 1)
local TRACE_POINTS = { Vector3(0, 0, 25), Vector3(0, 0, 75), Vector3(0, 0, 50) }
local SINGLE_TRACE_OFFSET = Vector3(0, 0, 50)

local COURIER_NEW = draw.CreateFont("Courier New", 22, 22)

local BOMB_TYPE_PIPE = 0
local BOMB_TYPE_STICKY = 1
local BOMB_TYPE_STICKYJUMP = 2

local CLASS_DEMOMAN = 4

local WEP_STICKYBOMB_LAUNCHER = 20
local WEP_AUSSIE_STICKYBOMB_LAUNCHER = 207
local WEP_SCOTTISH_RESISTANCE = 130
local WEP_QUICKIEBOMB_LAUNCHER = 1150

-- Change 'false' to 'true' if you experience stuttering
if false then
    collectgarbage("incremental", 120)
    collectgarbage("collect")
    collectgarbage("restart")
end

local function IsEntValid(ent)
    return ent ~= nil and ent:IsValid() and not ent:IsDormant()
end

local function IsValidStickyTarget(ignore_cloaked, player)
    return not (
        player:InCond(E_TFCOND.TFCond_Ubercharged) or
        player:InCond(E_TFCOND.TFCond_Bonked) or
        (ignore_cloaked == 1 and player:InCond(E_TFCOND.TFCond_Cloaked)) or
        (IGNORE_VACCINATOR and player:InCond(E_TFCOND.TFCond_SmallBlastResist))
    )
end

local function TraceStickyLine(sticky_pos, player, offset)
    local function ShouldHitEntity(ent, contentsMask)
        local class = ent:GetClass()
        return class == "CTFPlayer" or class == "CBaseDoor"
    end

    local trace_result = engine.TraceLine(sticky_pos + STICKY_TRACE_OFFSET, player:GetAbsOrigin() + offset,
        E_TraceLine.MASK_SHOT_HULL, ShouldHitEntity)

    return trace_result.entity ~= nil and trace_result.entity:GetIndex() == player:GetIndex()
end

local function CanStickySeePlayer(sticky_pos, player)
    if TRACE_MULTIPOINT then
        for _, offset in pairs(TRACE_POINTS) do
            if TraceStickyLine(sticky_pos, player, offset) then
                return true
            end
        end
    else
        return TraceStickyLine(sticky_pos, player, SINGLE_TRACE_OFFSET)
    end
end

local function DrawOutlinedLine(pos, pos2)
    draw.Line(pos[1], pos[2], pos2[1], pos2[2])
    draw.Color(0, 0, 0, 200)
    draw.Line(pos[1] + 1, pos[2] + 1, pos2[1] + 1, pos2[2] + 1)
    draw.Line(pos[1] - 1, pos[2] - 1, pos2[1] - 1, pos2[2] - 1)
end

local function GetCurrentWeaponDefIndex(local_player)
    local wep = local_player:GetPropEntity("m_hActiveWeapon")
    if wep == nil then
        return -1
    end

    local item = wep:ToInventoryItem()
    if item == nil then
        return -1
    end

    return item:GetDefIndex()
end

local function GetCurrentWeaponArmTime(local_player)
    local index = GetCurrentWeaponDefIndex(local_player)

    if index == WEP_STICKYBOMB_LAUNCHER or index == WEP_AUSSIE_STICKYBOMB_LAUNCHER then
        return 0.7
    elseif index == WEP_QUICKIEBOMB_LAUNCHER then
        return 0.5
    elseif index == WEP_SCOTTISH_RESISTANCE then
        return 0.7 + 0.8
    end

    return -1
end

local function CanAutoDetonateWithCurrentWeapon(local_player)
    local index = GetCurrentWeaponDefIndex(local_player)
    return index == WEP_STICKYBOMB_LAUNCHER or index == WEP_AUSSIE_STICKYBOMB_LAUNCHER or
        index == WEP_QUICKIEBOMB_LAUNCHER
end

local function CanAutoDetonate()
    return AUTO_DETONATE and (AUTO_DETONATE_KEY == -1 or input.IsButtonDown(AUTO_DETONATE_KEY))
end

local function GetPlayerEffectiveHealth(local_player, player)
    local health = player:GetHealth()

    if player:InCond(E_TFCOND.TFCond_MarkedForDeath) or local_player:InCond(E_TFCOND.TFCond_Buffed) then
        health = health * .75
    end

    return health
end

local function ColorDangerousSticky()
    draw.Color(255, 50, 50, 255)
end

local function ColorActiveSticky()
    draw.Color(255, 255, 255, 200)
end

local function ColorWhite()
    draw.Color(255, 255, 255, 255)
end

local function ShouldBeActive()
    local local_player = entities.GetLocalPlayer()
    return local_player ~= nil and
        local_player:IsValid() and
        local_player:IsAlive() and
        local_player:GetPropInt("m_PlayerClass", "m_iClass") == CLASS_DEMOMAN
end

local last_chat_print_time = 0
local active_stickies = {}
local auto_detonation_info = {}

local function CalcStickies(cmd)
    local tick_count = globals.TickCount()

    if not ShouldBeActive() or tick_count % CALC_EVERY ~= 0 then
        return
    end

    local cur_time = globals.CurTime()
    local local_player = entities.GetLocalPlayer()
    local local_index = local_player:GetIndex()

    local has_stickies = false
    for _, sticky in pairs(entities.FindByClass("CTFGrenadePipebombProjectile")) do
        if not IsEntValid(sticky) then
            goto continue
        end

        local type = sticky:GetPropInt("m_iType")
        if (IGNORE_PIPES and type == BOMB_TYPE_PIPE) or type == BOMB_TYPE_STICKYJUMP then
            goto continue
        end

        local owner = sticky:GetPropEntity("m_hThrower")
        if owner == nil or owner:GetIndex() ~= local_index then
            goto continue
        end

        local sticky_index = sticky:GetIndex()

        local sticky_data = active_stickies[sticky_index] or {
            arm_time = cur_time + GetCurrentWeaponArmTime(local_player),
            arm_progress_color_fn = ColorDangerousSticky,
            arm_progress = 0,
        }

        sticky_data.sticky = sticky
        sticky_data.sticky_pos = sticky:GetAbsOrigin()
        sticky_data.nearby_players = {}
        sticky_data.est_damage = 0
        sticky_data.draw_inner_circle = false
        sticky_data.is_critical = sticky:GetPropBool("m_bCritical")
        sticky_data.arm_progress = math.floor(16 - math.max((sticky_data.arm_time - cur_time) * 16, 0))

        active_stickies[sticky_index] = sticky_data

        has_stickies = true
        ::continue::
    end

    if not has_stickies then
        active_stickies = {}
        return
    end

    local ignore_cloaked = gui.GetValue("ignore cloaked")
    local local_team = local_player:GetTeamNumber()
    local mp_friendlyfire = client.GetConVar("mp_friendlyfire")

    for _, player in pairs(entities.FindByClass("CTFPlayer")) do
        if not IsEntValid(player) then
            goto continue
        end

        if player:GetIndex() == local_index then
            goto continue
        end

        if not player:IsAlive() then
            goto continue
        end

        if player:GetTeamNumber() == local_team then
            if mp_friendlyfire == 0 and not IGNORE_TEAM_FRIENDLYFIRE then
                goto continue
            end
        end

        if not IsValidStickyTarget(ignore_cloaked, player) then
            goto continue
        end

        local player_index = player:GetIndex()
        for _, entry in pairs(active_stickies) do
            if not entry.nearby_players[player_index] then
                entry.nearby_players[player_index] = { player = player, in_danger = false }
            end
        end

        ::continue::
    end

    if tick_count % TRACE_EVERY ~= 0 then
        return
    end

    local weapon_index = GetCurrentWeaponDefIndex(local_player)

    for _, sticky_data in pairs(active_stickies) do
        local are_any_in_danger = false
        local sticky_pos = sticky_data.sticky_pos
        local sticky_index = sticky_data.sticky:GetIndex()

        local est_sticky_damage = 0
        for _, player_data in pairs(sticky_data.nearby_players) do
            local player = player_data.player
            local dist = (sticky_pos - player:GetAbsOrigin()):Length()

            -- Player is outside of the sticky's radius, they're not in danger
            if dist > STICKY_RADIUS then
                player_data.in_danger = false
                goto continue
            end

            -- Sticky can't "see" the player. Skip.
            if not CanStickySeePlayer(sticky_pos, player) then
                goto continue
            end

            player_data.in_danger = true
            are_any_in_danger = true

            local damage = math.min(math.max((STICKY_RADIUS - dist), 0), 115)
            if sticky_data.is_critical then
                damage = damage * 3
            end

            -- Account for 15% damage penalty on quickiebomb launcher
            if weapon_index == WEP_QUICKIEBOMB_LAUNCHER then
                damage = damage * .85
            end

            est_sticky_damage = est_sticky_damage + damage

            if not AUTO_DETONATE then
                goto continue
            end

            if not CanAutoDetonateWithCurrentWeapon(local_player) then
                goto continue
            end

            local player_index = player:GetIndex()
            if cur_time >= sticky_data.arm_time then
                local dmg_entry = auto_detonation_info[player_index] or {
                    damage = {},
                    player = player,
                    start_wait_time = 0,
                }
                dmg_entry.damage[sticky_index] = damage
                auto_detonation_info[player_index] = dmg_entry
            end
            ::continue::
        end

        sticky_data.est_damage = est_sticky_damage
        -- At least one player is in danger, we'll consider this sticky dangerous
        sticky_data.dangerous = are_any_in_danger
    end
end

local function AutoDetonate(cmd)
    if not ShouldBeActive() or not CanAutoDetonate() then
        return
    end

    local local_player = entities.GetLocalPlayer()
    local cur_time = globals.CurTime()

    if CanAutoDetonateWithCurrentWeapon(local_player) and cmd.buttons & E_UserCmd.IN_ATTACK2 ~= 0 then
        auto_detonation_info = {}
        return
    end

    local function SetColorForStickies(sticky_datas, fn)
        for _, sticky_data in pairs(sticky_datas) do
            sticky_data.arm_progress_color_fn = fn
        end
    end

    local weapon_arm_time = GetCurrentWeaponArmTime(local_player)

    local auto_detonate_timeout = AUTO_DETONATE_TIMEOUT > 0 and AUTO_DETONATE_TIMEOUT or weapon_arm_time

    for _, info in pairs(auto_detonation_info) do
        local player = info.player
        local sticky_datas = {}
        local total_accumulated_damage = 0

        for sticky_index, damage in pairs(info.damage) do
            total_accumulated_damage = total_accumulated_damage + damage
            sticky_datas[sticky_index] = active_stickies[sticky_index]
        end

        -- Ideally you'd want to trace after you take all the easy paths but we want the arm time circle to change colors even if we can't detonate for other reasons
        if AUTO_DETONATE_VISIBLE_ONLY then
            local trace = engine.TraceLine(local_player:GetAbsOrigin() + SINGLE_TRACE_OFFSET,
                player:GetAbsOrigin() + SINGLE_TRACE_OFFSET, E_TraceLine.MASK_BLOCKLOS)
            if not trace.entity or trace.entity:GetIndex() ~= player:GetIndex() then
                SetColorForStickies(sticky_datas, ColorActiveSticky)
                goto continue
            end
            SetColorForStickies(sticky_datas, ColorDangerousSticky)
        end

        local effective_health = GetPlayerEffectiveHealth(local_player, player) * AUTO_DETONATE_HEALTH_MULTIPLIER
        local timed_out = (auto_detonate_timeout > 0 and info.start_wait_time > 0) and
            cur_time - info.start_wait_time > auto_detonate_timeout

        if total_accumulated_damage < effective_health and not timed_out then
            if info.start_wait_time == 0 then
                info.start_wait_time = cur_time
            end
            goto continue
        end

        if timed_out then
            info.start_wait_time = 0
        end

        if AUTO_DETONATE_PRINT_CHAT and cur_time - last_chat_print_time > 1 then
            local why = timed_out and "(forced) " or ""
            local dmg_format = timed_out and " w/ %.0f dmg" or " w/ %.0f dmg (>= %.0f)"
            client.ChatPrintf(string.format(
                "\x0725FF25[AutoDetonate]\x01 Detonating %s\x07FF0000%s\x01%s\n",
                why,
                player:GetName(),
                string.format(dmg_format, total_accumulated_damage, effective_health)
            ))
            last_chat_print_time = cur_time
        end

        cmd:SetButtons(cmd.buttons | E_UserCmd.IN_ATTACK2)
        auto_detonation_info = {}
        break
        ::continue::
    end
end

local function DrawStickies()
    if not ShouldBeActive() then
        return
    end

    local total_est_damage = 0
    local local_player = entities.GetLocalPlayer()

    for sticky_index, sticky_data in pairs(active_stickies) do
        local sticky = sticky_data.sticky

        -- Sticky has become invalid, remove it
        if not IsEntValid(sticky) then
            active_stickies[sticky_index] = nil
            goto continue
        end

        total_est_damage = total_est_damage + sticky_data.est_damage

        local sticky_screen_pos = client.WorldToScreen(sticky:GetAbsOrigin())
        if sticky_screen_pos == nil then
            goto continue
        end

        if sticky_data.dangerous then ColorDangerousSticky() else ColorActiveSticky() end
        draw.OutlinedCircle(sticky_screen_pos[1], sticky_screen_pos[2], 8, 8)

        if DRAW_ARM_TIME and sticky_data.arm_progress > 0 then
            if sticky_data.arm_progress_color_fn then
                sticky_data.arm_progress_color_fn()
            else
                ColorActiveSticky()
            end
            draw.OutlinedCircle(sticky_screen_pos[1], sticky_screen_pos[2], sticky_data.arm_progress, 12)
        end

        local nearby_count = 0
        for _, player_data in pairs(sticky_data.nearby_players) do
            if not player_data.in_danger then
                goto continue
            end

            nearby_count = nearby_count + 1

            local player_screen_pos = client.WorldToScreen(player_data.player:GetAbsOrigin())
            if player_screen_pos == nil then
                goto continue
            end

            ColorDangerousSticky()
            DrawOutlinedLine(sticky_screen_pos, player_screen_pos)
            ::continue::
        end

        if nearby_count > 0 then
            ColorWhite()
            draw.SetFont(COURIER_NEW)
            draw.TextShadow(sticky_screen_pos[1] - 5, sticky_screen_pos[2] - 10, nearby_count)
        end

        ::continue::
    end

    if DRAW_STATUS then
        local y = 10
        if total_est_damage > 0 then
            ColorWhite()
            draw.SetFont(COURIER_NEW)
            draw.TextShadow(10, y, string.format("Total damage: %.0f", total_est_damage))
            y = y + 20
        end
        if CanAutoDetonate() and CanAutoDetonateWithCurrentWeapon(local_player) then
            ColorWhite()
            draw.SetFont(COURIER_NEW)
            draw.TextShadow(10, y, "AutoDetonate enabled")
        end
    end

    if false then
        local count = collectgarbage("count")
        if count > _last_gc_count then
            ColorWhite()
        else
            ColorDangerousSticky()
        end
        draw.SetFont(COURIER_NEW)
        draw.TextShadow(10, 50, string.format("mem: %.2f", count))
        _last_gc_count = count
    end
end

callbacks.Register("CreateMove", "calc_stickies", CalcStickies)
callbacks.Register("CreateMove", "auto_detonate", AutoDetonate)
callbacks.Register("Draw", "draw_stickies", DrawStickies)
