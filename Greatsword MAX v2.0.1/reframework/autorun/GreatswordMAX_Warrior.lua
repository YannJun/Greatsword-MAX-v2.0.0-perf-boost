-- Greatsword MAX - Dullahan-Free Warrior Runtime v1.3.3 + EX Affix Monitor v2 (read-only)
-- Purpose: replace the Warrior-side Dullahan dependency used by Greatsword MAX.
-- Requires: REFramework. Designed to coexist with Skill Maker TU3.2.
-- Scope: Warrior animation speed, charge timing, stamina cost, Tidal Wrath behavior.
-- v0.4 STABILITY BASELINE: restored the last known-good v0.2 action-hook behavior.
-- The experimental v0.3 change is intentionally removed because it caused a Skill Maker TU3.2 ImGui max_ids error.
-- Includes the validated native Indomitable Lash 1301 -> 1302 charge-complete repair.

local TAG = "[GreatswordMAX Warrior] "
local function info(s) log.info(TAG .. s) end
local function warn(s)
    -- REFramework exposes log.warn; some builds do not expose log.warning.
    if log.warn then
        log.warn(TAG .. s)
    else
        log.error(TAG .. "[WARN] " .. s)
    end
end

local cfg = {
    -- Greatsword MAX / former Dullahan Warrior values
    attack_speed       = true,
    faster_uncharged   = true,
    charged_attacks    = true,
    arc_of_might       = true,
    arc_obliteration_hit_buff = true,
    arc_obliteration_multiplier = 1.20,
    arc_obliteration_duration = 2.0,
    horizontal_slash_full_hit_buff = true,
    horizontal_slash_full_multiplier = 1.20,
    horizontal_slash_full_duration = 2.4,
    heavenward_sunder  = true,
    indomitable_lash   = true,
    landslide          = true,
    windstorm_slash    = true,
    tidal_wrath        = true,

    -- This was another Warrior animation-speed block in the supplied Warrior.lua.
    -- Leave true if Greatsword MAX expects those GroundDrill/Diluvian speed edits.
    diluvian_strike    = true,

    -- v1.1: MAX ArcRoarVFX2 / ArcRoarBuff damage bonus
    arcroar_damage_buff = true,
    arcroar_multiplier  = 1.30,
    arcroar_duration    = 9.0,
    arcroar_runtime_vfx = true,
    light_attack_chain = true,
    light_chain_max_stacks = 6,
    light_chain_timeout = 1.8,

    -- In-game UI master switches for damage bonuses only.
    -- These do not disable chain stack/stamina recovery or HolyBrust VFX/sound.
    -- Master switch: chain bonus/recovery + HolyBrust bonus/VFX/sound.
    chain_holybrust_bonus = true,

    -- Warrior exclusive debuff:
    -- stamina loss ratio = final incoming damage / MaxHP.
    damage_stamina_debuff = true,
    damage_stamina_cooldown = 10.0,
}

-- Forward declaration: damage hook reads the equipment monitor defined below.
local gsmax_ex

local state = {
    player = nil,
    human = nil,
    motion = nil,
    fullLayer = nil,
    input = nil,
    action = nil,
    fullNode = nil,
    skillState = nil,
    weaponJob = nil,
    isBoss = nil,
    params_set = false,
    -- Indomitable Lash native charge-complete repair
    il1302_seen_1300 = false,
    il1302_repaired = false,

    arcroar_buff_remaining = 0.0,
    arcroar_buff_active = false,
    arcroar_damage_pending = false,
    arcroar_vfx_req_id = nil,
    arcroar_vfx_shell = nil,
    arcroar_vfx_xform = nil,
    arcroar_vfx_efx2 = nil,
    arcroar_vfx_seen = {},
    arcroar_vfx_watch_remaining = 0.0,
    arcroar_vfx2_trigger_latched = false,

    -- Arc of Obliteration: first real hit (frame < 60) grants a short damage buff.
    arc_obliteration_buff_remaining = 0.0,
    arc_obliteration_trigger_latched = false,
    arc_obliteration_holybrust_latched = false,
    arc_gold_first_latched = false,
    arc_gold_second_latched = false,

    -- Horizontal Slash Full: first real hit at frame < 60 grants +20% for 2.4 game seconds.
    horizontal_slash_full_buff_remaining = 0.0,
    horizontal_slash_full_trigger_latched = false,
    horizontal_slash_ex_combo_entered = false,
    horizontal_slash_full_effect_latched = false,
    horizontal_slash_ex_third_effect_latched = false,
    thrust_ex_holybrust_latched = false,
    thrust_ex_impact_b_latched = false,
    thrust_ex_sound75_latched = false,
    thrust_ex_impact_b_armed = false,
    thrust_ex_impact_b_last_frame = nil,
    gsmax_sm_b_seen = {},
    damage_stamina_cooldown_remaining = 0.0,
}

-- ArcRoar node5 runtime takeover.
-- Node5 must be disabled in Skill Maker to avoid duplicate VFX.
local app_native = sdk.get_native_singleton("via.Application")
local app_type = sdk.find_type_definition("via.Application")
local shell_mgr = sdk.get_managed_singleton("app.ShellManager")
local component_type_cache = {}

local ARCROAR_VFX = {
    udata = "AppSystem/shell/userdata/humanshellparamdata_jobmagic.user",
    shell_id = 45,
    joint = "Spine_1",
    scale = Vector3f.new(1.399999976158142, 1.399999976158142, 1.399999976158142),
    r = 0.5,
    g = 0.4000000059604645,
    b = 0.0,
    a = 0.20000000298023224,
}

local function safe_call(obj, method, ...)
    if not obj then return nil end
    local ok, result = pcall(obj.call, obj, method, ...)
    if ok then return result end
    return nil
end

local function safe_get(obj, field)
    if not obj then return nil end
    local ok, result = pcall(function() return obj[field] end)
    if ok then return result end
    return nil
end


-- Standalone HolyBrust EFX.
-- Minimal port of _NickCore 2.5.2 Utils/FX.lua:play_efx for this one effect.
-- No SkillCreator / NickCore runtime dependency.
local function gsmax_get_component(obj, type_name)
    if not obj then return nil end
    local valid = false
    pcall(function() valid = obj:get_Valid() end)
    if not valid then return nil end
    local go = obj
    if obj.get_GameObject then
        local ok, v = pcall(function() return obj:get_GameObject() end)
        if not ok or not v then return nil end
        go = v
    end
    local ok, comp = pcall(function()
        return go:call("getComponent(System.Type)", sdk.typeof(type_name))
    end)
    return ok and comp or nil
end

-- Standalone port of Weaponlord/helpers.lua TrigSound.
-- No Weaponlord/helpers runtime dependency.
local function gsmax_trig_sound(trig_id)
    local ok, err = pcall(function()
        local cm = sdk.get_managed_singleton("app.CharacterManager")
        local manual_player = cm and cm:get_ManualPlayer() or nil
        local body_gameobj = manual_player and manual_player:get_GameObject() or nil
        if not body_gameobj then return end

        local sound_comp = body_gameobj:call(
            "getComponent(System.Type)",
            sdk.typeof("soundlib.SoundContainer")
        )
        if not sound_comp or not sound_comp._TriggerInfoList
            or not sound_comp._TriggerInfoList._items then return end

        for _, trig in pairs(sound_comp._TriggerInfoList._items) do
            if trig and trig._TriggerId == trig_id then
                local snd_req = sound_comp:call(
                    "createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, System.UInt32, System.Boolean, System.Boolean, System.UInt32, via.simplewwise.CallbackType, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)",
                    trig, body_gameobj, body_gameobj, trig._OffsetJointHash,
                    false, false, 0, 0, nil, nil, nil, nil
                )
                if snd_req then
                    snd_req:add_ref()
                    snd_req["<Container>k__BackingField"] = sound_comp
                    sound_comp:call("trigger(soundlib.SoundManager.RequestInfo)", snd_req)
                end
            end
        end
    end)
    if not ok then warn("HolyBrust sound failed: " .. tostring(err)) end
end

-- GSMAX HolyBrust EPV element absolute scale x1.15.
-- Original HolyBrust EPVStandardData.Element.Scale was confirmed as (1.0, 1.0, 1.0).
-- Use an absolute value to prevent repeated casts from compounding the scale.
local function gsmax_hb_set_epv_scale_1_5(created_container, absolute_scale)
    if not created_container then return end

    local ok, err = pcall(function()
        local dict = created_container.CreatedEffects
        if not dict then return end

        local entries = dict._entries
        if not entries then return end

        for i = 0, 31 do
            local entry = entries[i]
            if entry then
                local element = entry.key or entry._key
                if element then
                    local td = element:get_type_definition()
                    local full_name = td and td:get_full_name() or ""
                    if full_name == "via.effect.script.EPVStandardData.Element" then
                        local scale = absolute_scale or 1.15
                        element.Scale = Vector3f.new(scale, scale, scale)
                    end
                end
            end
        end
    end)

    if not ok then
        warn("HolyBrust: EPV Element absolute Scale x1.15 failed: " .. tostring(err))
    end
end

-- Arc of Might / Arc of Obliteration gold VFX: edit timings and offsets here.
local ARC_GOLD1_FRAME = 39.48
local ARC_GOLD2_FRAME = 80.72
-- Gold2 uses the same PLAYER-FORWARD offset as Thrust EX ground impact.
-- Origin: weapon Rot joint; direction: player's horizontal forward (+Z rotated by player quaternion).
-- This is NOT a fixed world-space XYZ offset, nor weapon-facing offset.
local ARC_GOLD2_FORWARD_OFFSET = 1.25
local ARC_GOLD1_SCALE = 1.52 -- only gold {10,6,20}; HolyBurst keeps 1.15
local ARC_GOLD2_SCALE = 2.48 -- only gold {10,6,21}; HolyBurst keeps 1.15
local function play_holybrust_standalone(force_ex, arc_gold_element)
    if not arc_gold_element and not force_ex and not cfg.chain_holybrust_bonus then return nil end
    local source = state.player
    if not source then return nil end

    -- SkillCreator "PlayerWeapon" semantics:
    -- p.player:get_RightWeapon() or p.player:get_LeftWeapon()
    local target = safe_call(source, "get_RightWeapon()")
        or safe_call(source, "get_RightWeapon")
        or safe_call(source, "get_LeftWeapon()")
        or safe_call(source, "get_LeftWeapon")
    if not target then
        warn("HolyBrust: player weapon not found")
        return nil
    end

    local source_efx_mgr = gsmax_get_component(source, "via.effect.script.ObjectEffectManager2")
    if not source_efx_mgr then
        warn("HolyBrust: ObjectEffectManager2 not found")
        return nil
    end

    local target_go = target
    if target.get_GameObject then
        local ok, go = pcall(function() return target:get_GameObject() end)
        if not ok or not go then
            warn("HolyBrust: weapon GameObject not found")
            return nil
        end
        target_go = go
    end

    local transform = safe_call(target_go, "get_Transform()") or safe_call(target_go, "get_Transform")
    if not transform then
        warn("HolyBrust: weapon Transform not found")
        return nil
    end

    local joint_obj = safe_call(transform, "getJointByName(System.String)", "Rot")
        or safe_call(transform, "getJointByName", "Rot")
    if not joint_obj then
        warn("HolyBrust: weapon joint Rot not found")
        return nil
    end

    -- Weaponlord HolyBrust IDs: {16,12,0}
    local effect_id = sdk.create_instance("via.effect.script.EffectID")
    if not effect_id then
        warn("HolyBrust: EffectID creation failed")
        return nil
    end
    -- Arc gold is a motion-timed visual, independent of damage bonus.
    -- Standard HolyBrust stays {16,12,0} for bonus-hit effects.
    effect_id.ContainerID = arc_gold_element and 6 or 12
    effect_id.ElementID = arc_gold_element or 0
    effect_id.DataContainerIndex = arc_gold_element and 10 or 16
    effect_id.IsContainerIDOnly = false
    effect_id.IsElementIDOnly = false

    -- Restore the original HolyBrust-style spawn orientation for Arc Gold2:
    -- weapon Rot joint POSITION + weapon Transform ROTATION, snapshot at spawn.
    -- Gold1 remains unchanged, using Rot joint rotation.
    local position = safe_call(joint_obj, "get_Position()") or safe_call(joint_obj, "get_Position")
    local rotation
    if arc_gold_element == 21 then
        rotation = safe_call(transform, "get_Rotation()") or safe_call(transform, "get_Rotation")
    else
        rotation = safe_call(joint_obj, "get_Rotation()") or safe_call(joint_obj, "get_Rotation")
            or safe_call(transform, "get_Rotation()") or safe_call(transform, "get_Rotation")
    end
    if not position or not rotation then
        warn("HolyBrust: position/rotation unavailable")
        return nil
    end
    if arc_gold_element == 21 then
        -- Identical forward-vector calculation to gsmax_play_thrust_ex_impact_b().
        local player_go = safe_call(source, "get_GameObject()") or safe_call(source, "get_GameObject")
        local player_xf = player_go and (safe_call(player_go, "get_Transform()")
            or safe_call(player_go, "get_Transform"))
        local player_rot = player_xf and (safe_call(player_xf, "get_Rotation()")
            or safe_call(player_xf, "get_Rotation"))
        if not player_rot then
            warn("Arc Gold2: player rotation unavailable")
            return nil
        end
        local qx, qy, qz, qw = player_rot.x, player_rot.y, player_rot.z, player_rot.w
        if type(qx) ~= "number" or type(qy) ~= "number"
            or type(qz) ~= "number" or type(qw) ~= "number" then
            warn("Arc Gold2: invalid player quaternion")
            return nil
        end
        local fx = 2.0 * (qx * qz + qw * qy)
        local fz = 1.0 - 2.0 * (qx * qx + qy * qy)
        position = Vector3f.new(
            position.x + ARC_GOLD2_FORWARD_OFFSET * fx,
            position.y,
            position.z + ARC_GOLD2_FORWARD_OFFSET * fz
        )
    end

    local ok, result = pcall(function()
        return source_efx_mgr:call(
            "requestEffect(via.effect.script.EffectID, via.vec3, via.Quaternion, via.GameObject, System.String, via.effect.script.EffectManager.WwiseTriggerInfo)",
            effect_id,
            position,
            rotation,
            nil,       -- followTarget is nil/false in Weaponlord HolyBrust
            "Rot",
            nil
        )
    end)
    if not ok then
        warn("HolyBrust: requestEffect failed")
        return nil
    end
	
	if arc_gold_element == 20 then
        gsmax_hb_set_epv_scale_1_5(result, ARC_GOLD1_SCALE)
	elseif arc_gold_element == 21 then
		gsmax_hb_set_epv_scale_1_5(result, ARC_GOLD2_SCALE)
	else
		gsmax_hb_set_epv_scale_1_5(result)
	end
    return result
end


-- Thrust EX: GroundDrill native ground-impact VFX B {10,5,0} only.
-- Uses the exact ObjectEffectManager2 request path validated by the VFX Tester.
local function gsmax_play_thrust_ex_impact_b()
    local source = state.player
    if not source then return false end
    local mgr = gsmax_get_component(source, "via.effect.script.ObjectEffectManager2")
    -- Match the existing HolyBrust weapon Rot placement exactly.
    local weapon = safe_call(source, "get_RightWeapon()")
        or safe_call(source, "get_RightWeapon")
        or safe_call(source, "get_LeftWeapon()")
        or safe_call(source, "get_LeftWeapon")
    if not weapon or not mgr then
        warn("Thrust EX impact B: weapon or effect manager unavailable")
        return false
    end
    local weapon_go = weapon
    if weapon.get_GameObject then
        weapon_go = safe_call(weapon, "get_GameObject()")
            or safe_call(weapon, "get_GameObject")
    end
    local xf = weapon_go and (safe_call(weapon_go, "get_Transform()")
        or safe_call(weapon_go, "get_Transform"))
    local joint = xf and (safe_call(xf, "getJointByName(System.String)", "Rot")
        or safe_call(xf, "getJointByName", "Rot"))
    local pos = joint and (safe_call(joint, "get_Position()")
        or safe_call(joint, "get_Position"))
    local rot = xf and (safe_call(xf, "get_Rotation()")
        or safe_call(xf, "get_Rotation"))
    if not pos or not rot then
        warn("Thrust EX impact B: weapon Rot joint position/rotation unavailable")
        return false
    end
    local id = sdk.create_instance("via.effect.script.EffectID")
    if not id then return false end
    id.DataContainerIndex = 10
    id.ContainerID = 5
    id.ElementID = 0
    id.IsContainerIDOnly = false
    id.IsElementIDOnly = false
    -- Diagnostic: offset the weapon Rot joint 2.0 units in the PLAYER'S
    -- horizontal forward direction, independent of world axes and weapon tilt.
    local player_go = safe_call(source, "get_GameObject()") or safe_call(source, "get_GameObject")
    local player_xf = player_go and (safe_call(player_go, "get_Transform()")
        or safe_call(player_go, "get_Transform"))
    local player_rot = player_xf and (safe_call(player_xf, "get_Rotation()")
        or safe_call(player_xf, "get_Rotation"))
    if not player_rot then
        warn("Thrust EX impact B: player rotation unavailable")
        return false
    end
    local qx, qy, qz, qw = player_rot.x, player_rot.y, player_rot.z, player_rot.w
    if type(qx) ~= "number" or type(qy) ~= "number"
        or type(qz) ~= "number" or type(qw) ~= "number" then
        warn("Thrust EX impact B: invalid player quaternion")
        return false
    end
    -- Rotate local +Z by player quaternion; discard vertical component.
    local fx = 2.0 * (qx * qz + qw * qy)
    local fz = 1.0 - 2.0 * (qx * qx + qy * qy)
    -- User-validated final position: 1.5x player-forward X/Z, no normalization.
    pos = Vector3f.new(pos.x + 1.5 * fx, pos.y, pos.z + 1.5 * fz)
    local ok, err = pcall(function()
        mgr:call(
            "requestEffect(via.effect.script.EffectID, via.vec3, via.Quaternion, via.GameObject, System.String, via.effect.script.EffectManager.WwiseTriggerInfo)",
            id, pos, rot, nil, "Rot", nil)
    end)
    if not ok then warn("Thrust EX impact B request failed: " .. tostring(err)) end
    return ok
end

-- Indomitable Lash charge-complete repair.
-- Successful full charges use native bank 150 / motion 1302.
-- This never calls Skill Maker and never plays its animation by name.
local function request_native_1302()
    if not state.fullLayer then return false end

    local attempts = {
        function() state.fullLayer:call("changeMotion(System.UInt32, System.UInt32, System.Single)", 150, 1302, 0.0) end,
        function() state.fullLayer:call("changeMotion(System.UInt32, System.UInt32)", 150, 1302) end,
        function() state.fullLayer:call("set_MotionID(System.UInt32)", 1302) end,
    }
    for _, f in ipairs(attempts) do
        local ok = pcall(f)
        if ok then return true end
    end
    return false
end


local function get_game_delta()
    if not app_native or not app_type then return 0.0 end
    local ok_ft, frame_ms = pcall(function()
        return sdk.call_native_func(app_native, app_type, "get_FrameTimeMillisecond")
    end)
    if not ok_ft or type(frame_ms) ~= "number" or frame_ms <= 0.0 or frame_ms > 500.0 then
        return 0.0
    end

    local global_speed = 1.0
    local ok_gs, gs = pcall(function()
        return sdk.call_native_func(app_native, app_type, "get_GlobalSpeed")
    end)
    if ok_gs and type(gs) == "number" then global_speed = math.max(0.0, gs) end
    return (frame_ms * 0.001) * global_speed
end

local function get_component_fast(go, type_name)
    if not go then return nil end
    local t = component_type_cache[type_name]
    if t == nil then
        local ok, v = pcall(function() return sdk.typeof(type_name) end)
        t = (ok and v) or false
        component_type_cache[type_name] = t
    end
    if not t or t == false then return nil end
    local ok, comp = pcall(function() return go:call("getComponent(System.Type)", t) end)
    return ok and comp or nil
end

local function make_tu32_color(r,g,b,a)
    local td=sdk.find_type_definition("via.Color")
    if not td or not ValueType or not ValueType.new then return nil end
    local ok,c=pcall(function() return ValueType.new(td) end)
    if not ok or not c then return nil end
    local v=Vector4f.new(r,g,b,a)
    pcall(function() c.rgba=0 end)
    local landed=false
    if pcall(function() c:call(".ctor(via.vec4)",v) end) then
        pcall(function() landed=(c.rgba~=0) end)
    end
    if landed then return c end
    local function byte(x)
        x=math.floor((tonumber(x) or 0)*255+0.5)
        if x<0 then x=0 elseif x>255 then x=255 end
        return x
    end
    pcall(function() c.rgba=byte(v.x)+byte(v.y)*256+byte(v.z)*65536+byte(v.w)*16777216 end)
    return c
end

local function color_arcroar_vfx()
    local efx2 = state.arcroar_vfx_efx2
    if not efx2 then return end
    local color = make_tu32_color(ARCROAR_VFX.r, ARCROAR_VFX.g, ARCROAR_VFX.b, ARCROAR_VFX.a)
    if not color then return end

    pcall(function()
        local list = efx2.CreatedEffectDataList
        local items = list and list._items or nil
        if not items then return end
        for di=0,63 do
            local data = nil; pcall(function() data = items[di] end)
            local effects = data and data.list and data.list._items or nil
            if effects then
                for ci=0,63 do
                    local ce = nil; pcall(function() ce = effects[ci] end)
                    if ce and ce.IsFinished ~= true then
                        local key = tostring(ce)
                        if not state.arcroar_vfx_seen[key] then
                            state.arcroar_vfx_seen[key] = true
                            local dict = nil; pcall(function() dict = ce.CreatedEffects end)
                            local entries = dict and dict._entries or nil
                            if entries then
                                for ei=0,63 do
                                    local entry=nil; pcall(function() entry=entries[ei] end)
                                    if entry then
                                        local value=nil
                                        pcall(function() value=entry.value end)
                                        if not value then pcall(function() value=entry._value end) end
                                        local arr=value and value._items or nil
                                        if arr then
                                            for pi=0,31 do
                                                local ep=nil; pcall(function() ep=arr[pi] end)
                                                if ep then
                                                    local okc=pcall(function() ep:set_Color(color) end)
                                                    if not okc then pcall(function() ep:call("set_Color(via.Color)", color) end) end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            local okr=pcall(function() ce:setRootColor(color) end)
                            if not okr then pcall(function() ce:call("setRootColor(via.Color)", color) end) end
                        end
                    end
                end
            end
        end
    end)
end

local function finish_arcroar_vfx()
    -- No hard kill here: native shell termination must be allowed to create its
    -- original end effect. Keep the TU3.2 colour watcher alive for delayed effects.
    state.arcroar_vfx_watch_remaining = 10.0
end

local function spawn_arcroar_vfx()
    if not cfg.arcroar_runtime_vfx or not shell_mgr or not state.player then return false end
    local xf = state.player:get_Transform()
    local joint = xf and (xf:getJointByName(ARCROAR_VFX.joint) or xf:getJointByName("Spine_2"))
    if not joint then return false end

    local ok, req_id = pcall(function()
        local udata = sdk.create_userdata("app.ShellParamData", ARCROAR_VFX.udata)
        local sparam = udata and udata.ShellParams and udata.ShellParams._items[ARCROAR_VFX.shell_id]
        if not sparam then error("ArcRoar shell45 missing") end

        local base = sparam._ShellParameterBase and sparam._ShellParameterBase.ShellBaseParam
        if base then
            -- Match Skill Maker node5: native shell owns the 8-second lifetime.
            -- Its normal checkFinish path can therefore create the terminal flash.
            base.Scale = ARCROAR_VFX.scale
            base.UseLifeTime = true
            base.LifeTime = cfg.arcroar_duration
        end

        local req = sdk.create_instance("app.ShellRequest.ShellCreateInfo"):add_ref()
        req.ShellParamIdHash = sparam._ShellParamIdHash
        local id = shell_mgr:call(
            "requestCreateShell(via.GameObject, via.vec3, via.Quaternion, app.ShellRequest.ShellCreateInfo, app.ShellParamData, app.ShellRequest.EventCreateShellSuccess, app.ShellRequest.EventBeforeShellInstantiate)",
            state.player:get_GameObject(), joint:get_Position(), joint:get_Rotation(), req, udata, nil, nil
        )
        return id
    end)

    if ok and req_id then
        state.arcroar_vfx_req_id = req_id
        state.arcroar_vfx_shell = nil
        state.arcroar_vfx_xform = nil
        state.arcroar_vfx_efx2 = nil
        state.arcroar_vfx_seen = {}
        state.arcroar_vfx_watch_remaining = 0.0
        return true
    end
    log.error("[GSMAX-BUFF] ArcRoar runtime VFX spawn FAILED")
    return false
end

local function resolve_arcroar_vfx()
    if state.arcroar_vfx_shell or not state.arcroar_vfx_req_id or not shell_mgr then return end
    pcall(function()
        local dict = shell_mgr["<InstantiatedShellDict>k__BackingField"]
        if not dict or not dict:ContainsKey(state.arcroar_vfx_req_id) then return end
        local holder = dict[state.arcroar_vfx_req_id]
        local shell = holder and holder["<Shell>k__BackingField"] or nil
        if not shell then return end
        local go = shell:get_GameObject()
        state.arcroar_vfx_shell = shell
        state.arcroar_vfx_xform = go and go:get_Transform() or nil
        state.arcroar_vfx_efx2 = go and get_component_fast(go, "via.effect.script.ObjectEffectManager2") or nil

        -- MAX ArcRoarVFX2 node5: scale [1.4, 1.4, 1.4].
        -- Apply once when the runtime shell resolves; position/rotation follow remains unchanged.
        if state.arcroar_vfx_xform then
            local scale = Vector3f.new(1.4, 1.4, 1.4)
            local ok_scale = pcall(function()
                state.arcroar_vfx_xform:call("set_LocalScale(via.vec3)", scale)
            end)
            if not ok_scale then
                pcall(function() state.arcroar_vfx_xform:set_LocalScale(scale) end)
            end
        end

        -- Decorative parity: no hitbox / no damage.
        shell["<ColliderStep>k__BackingField"] = 99999
        local hit = shell["<HitCtrl>k__BackingField"] or shell:call("get_HitCtrl")
        if hit then
            pcall(function() hit["<AttackRate>k__BackingField"] = 0.0 end)
            local cached=nil; pcall(function() cached=hit:get_CachedRequestSetCollider() end)
            if cached then pcall(function() cached:set_Enabled(false) end) end
        end
    end)
end

local function update_arcroar_vfx_follow()
    resolve_arcroar_vfx()
    if state.arcroar_vfx_xform and state.player then
        pcall(function()
            local pxf=state.player:get_Transform()
            local joint=pxf:getJointByName(ARCROAR_VFX.joint) or pxf:getJointByName("Spine_2")
            if joint then
                state.arcroar_vfx_xform:set_Position(joint:get_Position())
                state.arcroar_vfx_xform:set_EulerAngle(joint:get_EulerAngle())
            end
        end)
    end
    color_arcroar_vfx()
end

local function refresh_arcroar_vfx_lifetime()
    -- Recast refresh: keep the existing native shell/VFX, but restart the shell's
    -- native lifetime from zero. This keeps VFX lifetime locked to the refreshed
    -- 8-second Warrior buff without spawning overlapping duplicate shells.
    resolve_arcroar_vfx()
    if not state.arcroar_vfx_shell then return false end

    local ok = pcall(function()
        local timer = state.arcroar_vfx_shell["<LiveTimer>k__BackingField"]
        if not timer then error("ArcRoar LiveTimer missing") end
        timer._ElapsedFrame = 0.0
    end)
    if ok then
        state.arcroar_vfx_watch_remaining = 0.0
        return true
    end
    return false
end

local function start_arcroar_buff()
    local was_active = state.arcroar_buff_active
    state.arcroar_buff_active = true
    state.arcroar_buff_remaining = cfg.arcroar_duration

    if was_active and state.arcroar_vfx_req_id then
        -- No artificial 8-second recast cooldown: refresh the SAME native shell.
        -- Its terminal effect will now occur 8 game-seconds after the latest cast.
        if not refresh_arcroar_vfx_lifetime() then
            -- Very early recast before the request resolves: do not create a duplicate.
            -- The Warrior buff still refreshes; normal resolve continues next frame.
            log.warning("[GSMAX-BUFF] ArcRoar VFX lifetime refresh pending (shell not resolved yet)")
        end
    else
        spawn_arcroar_vfx()
    end

    log.error(string.format("[GSMAX-BUFF] ArcRoarBuff %s game-time=%.1fs multiplier=%.2f",
        was_active and "REFRESH" or "ON", cfg.arcroar_duration, cfg.arcroar_multiplier))
end

local function get_player()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    if not cm then return nil end
    return safe_call(cm, "get_ManualPlayer()") or safe_call(cm, "get_ManualPlayer")
end

local function same_game_object(a, b)
    if not a or not b then return false end
    local ago = safe_call(a, "get_GameObject()") or safe_call(a, "get_GameObject")
    local bgo = safe_call(b, "get_GameObject()") or safe_call(b, "get_GameObject")
    if not ago or not bgo then return false end
    return ago:get_address() == bgo:get_address()
end

local function is_player_owned(obj)
    local pl = state.player or get_player()
    if not pl or not obj then return false end
    if obj:get_address() == pl:get_address() then return true end
    return same_game_object(obj, pl)
end

local function refresh_player()
    local pl = get_player()
    if not pl then
        state.player, state.human, state.motion, state.fullLayer, state.input = nil, nil, nil, nil, nil
        return false
    end

    state.player = pl
    state.human = safe_call(pl, "get_Human()") or safe_call(pl, "get_Human") or safe_get(pl, "<Human>k__BackingField")
    state.motion = safe_call(pl, "get_Motion()") or safe_call(pl, "get_Motion")
    if state.motion then
        state.fullLayer = safe_call(state.motion, "getLayer(System.UInt32)", 0)
            or safe_call(state.motion, "getLayer", 0)
            or safe_call(state.motion, "get_Layer", 0)
    end

    -- Dullahan's PlayerProperties exposes p.input:isButtonOn(mask).
    -- Try the common DD2 ownership chains without taking a dependency on Dullahan.
    state.input = safe_call(pl, "get_Input()") or safe_call(pl, "get_Input")
    if not state.input and state.human then
        state.input = safe_call(state.human, "get_Input()") or safe_call(state.human, "get_Input")
            or safe_get(state.human, "<Input>k__BackingField")
            or safe_get(state.human, "Input")
    end

    state.weaponJob = safe_call(pl, "getWeaponJob()") or safe_call(pl, "getWeaponJob")
    if state.human then
        state.skillState = safe_get(state.human, "<CustomSkillState>k__BackingField")
    end
    return true
end

local function is_warrior()
    return state.weaponJob == 5
end

local function button_on(mask)
    if not state.input then return false end
    local v = safe_call(state.input, "isButtonOn(System.UInt64)", mask)
        or safe_call(state.input, "isButtonOn", mask)
    return v == true
end

local function get_job_params()
    if not state.human then return nil end
    local parameter = safe_get(state.human, "Parameter") or safe_call(state.human, "get_Parameter()")
    local jobparam = parameter and (safe_get(parameter, "JobParam") or safe_call(parameter, "get_JobParam()"))
    return jobparam and safe_get(jobparam, "Job05Parameter") or nil
end

local function set_params()
    local params = get_job_params()
    if not params then return false end

    if cfg.arc_of_might then params.ArcOfObliterationParam.SecPrepare = 1.55 end

    if cfg.tidal_wrath then
        params.CounterAttackParam.ContinueTime = 40
        params.CounterAttackParam.JustTime = 2
        params.CounterAttackParam.Lv2JustTime = 4
		params.CounterAttackParam.LvExJustTime = 6
        params.CounterAttackParam.GuardAngle.x = -135
        params.CounterAttackParam.GuardAngle.y = 135
    end

    if cfg.heavenward_sunder then params.CrescentSlashParam.SecPrepare = 2.0 end
    if cfg.indomitable_lash then params.IndomitableLashParam.SecPrepare = 1.55 end
    if cfg.landslide then params.LandSlideParam.SecPrepare = 1.6 end

    if cfg.windstorm_slash then
        local s = params.CycloneSlashParam.SpeedList
        s[0], s[1], s[2], s[3], s[4] = 1.4, 1.6, 1.8, 2.0, 2.2
        s[5], s[6], s[7], s[8] = 2.3, 2.4, 2.5, 2.6
    end

    state.params_set = true
    info("Warrior parameters applied")
    return true
end

local uncharged_nodes = {
    Job05_CrescentSlashNormal = true,
    Job05_LandSlideNormal = true,
    Job05_IndomitableLashNormal = true,
    Job05_HorizonalSlashNormal = true,
}

local speed_lookup = {
    Job05_ShortRangeAttack = {0.96, "attack_speed"},
    Job05_LongRangeAttack  = {0.96, "attack_speed"},
	Job05_ShortRangeHeavyAttack = {1.30, "attack_speed"},
    Job05_LongRangeHeavyAttack  = {1.35, "attack_speed"},
    Job05_DashHeavyAttack       = {1.40, "attack_speed"},
    Job05_HeavyAttackLargeBelow = {1.30, "attack_speed"},
    Job05_FinishingMoveLargeBelow = {1.30, "attack_speed"},
    Job05_AttackAir             = {1.30, "attack_speed"},
    Job05_HeavyAttackAir        = {1.20, "attack_speed"},
    Job05_DashAttack            = {1.30, "attack_speed"},

    Job05_GroundDrill           = {1.50, "diluvian_strike"},
    Job05_GroundDrillLanding    = {1.50, "diluvian_strike"},
    Job05_GroundDrillEnd        = {1.30, "diluvian_strike"},
    Job05_GroundDrillAirLanding = {1.50, "diluvian_strike"},
    Job05_GroundDrillAdditionalLarge = {1.30, "diluvian_strike"},

    Job05_CrescentSlashNormal       = {1.20, "faster_uncharged"},
    Job05_CrescentSlashFull         = {1.20, "faster_uncharged"},
    Job05_CrescentSlashFullLanding  = {1.30, "faster_uncharged"},
    Job05_LandSlide                 = {1.20, "faster_uncharged"},
    Job05_LandSlideNormal           = {1.30, "faster_uncharged"},
    Job05_IndomitableLash           = {1.10, "faster_uncharged"},
    Job05_IndomitableLashNormal     = {1.30, "faster_uncharged"},
    Job05_HorizonalSlashNormal      = {1.20, "faster_uncharged"},
    Job05_WarCry                    = {1.25, "faster_uncharged"},
    Job05_WarCryCombo               = {1.60, "faster_uncharged"},
    Job05_Guts                      = {1.20, "faster_uncharged"},
    Job05_ClimbingAttack            = {1.50, "faster_uncharged"},
	Job05_DashSlashUp               = {1.30, "faster_uncharged"},
	Job05_DashSlashUpFinish         = {1.30, "faster_uncharged"},
	Job05_DashSlashUpCancel         = {1.30, "faster_uncharged"},
}

-- Weaponlord General Light Attack / Cyclone Slash chain.
-- Stack gains come from successful speed-combo effects, NOT each damage hit.
local general_nodes = {
    Job05_CycloneSlash = true,
    Job05_CycloneSlashFinish = true,
    Job05_ShortRangeAttack = true,
    Job05_LongRangeAttack = true,
    Job05_DashAttack = true,
    Job05_DashHeavyAttack = true,
    Job05_HorizonalSlashNormal = true,
    Job05_Tackle = true,
}
local light_chain_stacks = 0
local light_chain_last_success = -math.huge

local counter_nodes = {
    Job05_CounterAttack = true,
    Job05_CounterAttackRepellS = true,
    Job05_CounterAttackRepellL = true,
    Job05_CounterAttackEnd = true,
}

local function request_node(node)
    if not state.action then return false end
    local ok = pcall(function()
        state.action:call("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)", 0, node, 0)
    end)
    if not ok then
        ok = pcall(function() state.action:call("requestActionCore", 0, node, 0) end)
    end
    return ok
end

-- Warrior exclusive damage -> stamina debuff.
-- Formula: stamina loss = MaxStamina * (final incoming Damage / MaxHP).
-- Uses the native post-calc DamageInfo.Damage so defense/reduction has already been applied.
local gsmax_damage_stamina_diag_once = false

local function gsmax_first_number(obj, method_names, field_names)
    if not obj then return nil end
    for _, name in ipairs(method_names or {}) do
        local v = safe_call(obj, name)
        if type(v) == "number" then return v end
    end
    for _, name in ipairs(field_names or {}) do
        local v = safe_get(obj, name)
        if type(v) == "number" then return v end
    end
    return nil
end

local function gsmax_get_max_hp(player)
    if not player then return nil end
    -- Proven on DD2 TU3.2 by runtime reflection:
    -- app.Character:get_ReducedMaxHp() is the player's effective current MaxHP.
    local v = safe_call(player, "get_ReducedMaxHp()")
        or safe_call(player, "get_ReducedMaxHp")
    return (type(v) == "number" and v > 0.0) and v or nil
end

local function gsmax_get_max_stamina(stamina_manager)
    if not stamina_manager then return nil end
    -- Proven on DD2 TU3.2 by runtime reflection:
    -- app.StaminaManager:get_ReducedMaxValue() is effective current MaxStamina.
    local v = safe_call(stamina_manager, "get_ReducedMaxValue()")
        or safe_call(stamina_manager, "get_ReducedMaxValue")
    return (type(v) == "number" and v > 0.0) and v or nil
end

local function gsmax_apply_damage_stamina_debuff(di)
    if not cfg.damage_stamina_debuff or not di then return end
    if state.damage_stamina_cooldown_remaining > 0.0 then return end
    -- ArcRoarBuff grants immunity to this damage-to-stamina debuff for its full 9s.
    -- Incoming HP damage is unchanged; other stamina costs are unchanged.
    if state.arcroar_buff_active and state.arcroar_buff_remaining > 0.0 then return end
    refresh_player()
    if not is_warrior() or not state.player then return end

    local damage = safe_get(di, "Damage")
    if type(damage) ~= "number" or damage <= 0.0 then return end

    local max_hp = gsmax_get_max_hp(state.player)
    local stamina_manager = safe_call(state.player, "get_StaminaManager()")
        or safe_call(state.player, "get_StaminaManager")
    local max_stamina = gsmax_get_max_stamina(stamina_manager)

    if type(max_hp) ~= "number" or max_hp <= 0.0
        or type(max_stamina) ~= "number" or max_stamina <= 0.0
        or not stamina_manager then
        if not gsmax_damage_stamina_diag_once then
            gsmax_damage_stamina_diag_once = true
            warn(string.format(
                "Damage-stamina debuff unavailable: MaxHP=%s MaxStamina=%s StaminaManager=%s",
                tostring(max_hp), tostring(max_stamina), tostring(stamina_manager)))
        end
        return
    end

    local hp_loss_ratio = math.min(1.0, math.max(0.0, damage / max_hp))
    local stamina_loss_ratio = hp_loss_ratio
    local stamina_loss = max_stamina * stamina_loss_ratio
    if stamina_loss <= 0.0 then return end

    if not state.gsmax_damage_stamina_success_logged then
        state.gsmax_damage_stamina_success_logged = true
        log.error(string.format(
            "[GSMAX-DEBUFF] DIRECT Damage=%.3f MaxHP=%.3f Ratio=%.4f MaxStamina=%.3f StaminaLoss=%.3f",
            damage, max_hp, stamina_loss_ratio, max_stamina, stamina_loss))
    end

    local resulting_stamina = nil
    local minimum_stamina = 0.0
    local ok = pcall(function()
        -- Directly write current stamina. This avoids charge-state stamina conversion/
        -- suppression that can neutralize StaminaManager:add() during charge actions.
        local current_stamina = safe_call(stamina_manager, "get_RemainingAmount()")
            or safe_call(stamina_manager, "get_RemainingAmount")
        if type(current_stamina) ~= "number" then
            error("RemainingAmount unavailable")
        end

        local min_stamina = safe_get(stamina_manager, "MinValue")
        if type(min_stamina) ~= "number" then min_stamina = 0.0 end
        minimum_stamina = min_stamina

        local new_stamina = math.max(min_stamina, current_stamina - stamina_loss)
        stamina_manager:call("set_RemainingAmount(System.Single)", new_stamina)
        resulting_stamina = safe_call(stamina_manager, "get_RemainingAmount()")
            or safe_call(stamina_manager, "get_RemainingAmount")
    end)
    if not ok then
        ok = pcall(function()
            stamina_manager:call("add(System.Single, System.Boolean)", -stamina_loss, false)
            resulting_stamina = safe_call(stamina_manager, "get_RemainingAmount()")
                or safe_call(stamina_manager, "get_RemainingAmount")
        end)
    end
    if not ok then
        warn("Damage-stamina debuff: stamina add() failed")
    elseif type(resulting_stamina) == "number" and resulting_stamina <= math.max(0.0, minimum_stamina) + 0.001 then
        state.damage_stamina_cooldown_remaining = cfg.damage_stamina_cooldown
        info(string.format("[GSMAX-DEBUFF] Stamina depleted; debuff cooldown %.1fs", cfg.damage_stamina_cooldown))
    end
end

-- Stamina: only the Warrior edits present in the supplied Greatsword MAX Warrior.lua.
local stamina_method = sdk.find_type_definition("app.HumanStaminaController")
    :get_method("Chara_OnConsumeStaminaHandler(System.Single, app.StaminaParameterBase.Parameter)")
if stamina_method then
    sdk.hook(stamina_method, function(args)
        local this = sdk.to_managed_object(args[2])
        local owner = this and safe_get(this, "Chara")
        if not owner or not is_player_owned(owner) then return end
        refresh_player()
        if not is_warrior() then return end

        local human = safe_get(owner, "<Human>k__BackingField") or state.human
        local skill = human and safe_get(human, "<CustomSkillState>k__BackingField") or state.skillState
        state.skillState = skill
        local cost = sdk.to_float(args[3])

        -- Arc of Might: Greatsword MAX's supplied Dullahan override resolves this to zero cost.
        if cfg.arc_of_might and skill == 61 then
            args[3] = sdk.float_to_ptr(0.0)
            return
        end

        -- Landslide states were also explicitly zeroed by Dullahan.lua.
        if cfg.landslide and (skill == 57 or skill == 58) then
            args[3] = sdk.float_to_ptr(-200.0)
            return
        end

        if cfg.faster_uncharged and uncharged_nodes[state.fullNode] then
            args[3] = sdk.float_to_ptr(0.7 * cost)
        elseif cfg.heavenward_sunder and skill == 52 then
            args[3] = sdk.float_to_ptr(1.5 * cost)
        end
    end)
else
    warn("Stamina hook method not found")
end

-- ArcRoarBuff: action-level poise against the five Weaponlord reactions.
-- No weapon-ID dependency; uses the existing eight-second game-time buff.
local arcroar_immune_actions = {
    RepelledJumpHalfJustGuard = true,
    RepelledS = true,
    RepelledM = true,
    RepelledL = true,
    DmgUnbalanceL = true,
}

-- Action requests: cache current node, reset speed, then apply Greatsword MAX Warrior speed edits.
local action_method = sdk.find_type_definition("app.ActionManager")
    :get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)")
if action_method then
    sdk.hook(action_method, function(args)
        local this = sdk.to_managed_object(args[2])
        if not this or not is_player_owned(this) then return end
        refresh_player()

        local layer = sdk.to_int64(args[5]) & 0xffffffff
        if layer ~= 0 then return end
        local requested_node = sdk.to_managed_object(args[4]):ToString()
        -- v1.3.3: suppress the Warrior player's Job02_MeleeAttackHit action request.
        -- Do not overwrite state.fullNode or alter animation speed for a skipped action.
        if is_warrior() and requested_node == "Job02_MeleeAttackHit" then
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        -- Block only while the existing Warrior ArcRoarBuff is active.
        -- Do this before updating fullNode or changing animation speed.
        if state.arcroar_buff_active and state.arcroar_buff_remaining > 0.0
            and is_warrior() and arcroar_immune_actions[requested_node] then
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
        state.action = this
        state.fullNode = requested_node
        -- A fresh finish action may fire B once when its animation crosses frame 80.
        if requested_node == "Job05_HeavyRunningThrustFinishEx" then
            state.thrust_ex_impact_b_latched = false
            state.thrust_ex_sound75_latched = false
            state.thrust_ex_impact_b_armed = false
            state.thrust_ex_impact_b_last_frame = nil
        end

        -- v0.2: do not reset the currently playing charge layer on the exact
        -- Indomitable Lash -> Full request.  v0.1 reset it to 1.0 before the
        -- native action transition had actually completed; with the shortened
        -- SecPrepare this could intermittently suppress the charge-complete
        -- transition animation.  All other requests retain v0.1 behavior.
        local preserve_indomitable_full_transition =
            state.fullNode == "Job05_IndomitableLashFull"
        if state.fullLayer and not preserve_indomitable_full_transition then
            state.fullLayer:set_Speed(1.0)
        end
        if not is_warrior() then return end

        local params = get_job_params()
        if params and cfg.charged_attacks then
            params.ChargeNormalAttackParam.SecPrepare = 1.125
        end

        local si = speed_lookup[state.fullNode]
        if si and cfg[si[2]] and state.fullLayer then
            state.fullLayer:set_Speed(si[1])
        end

        -- Tidal Wrath Lv2 opening acceleration from the supplied Dullahan Warrior.lua.
        if cfg.tidal_wrath and state.fullNode == "Job05_CounterAttack" and state.fullLayer then
            local skillctx = state.human and safe_get(state.human, "<SkillContext>k__BackingField")
            local enabled = skillctx and safe_get(skillctx, "EnabledCustomSkills")
            local lv2 = false
            if enabled then
                local ok, entry = pcall(function() return enabled[55] end)
                lv2 = ok and entry and safe_get(entry, "Level") == 2
            end
            if lv2 then state.fullLayer:set_Speed(2.0) end
        end

        if cfg.windstorm_slash and state.fullNode == "Job05_CycloneSlash" and state.fullLayer then
            local bank = safe_call(state.fullLayer, "get_MotionBankID()")
            local motion = safe_call(state.fullLayer, "get_MotionID()")
            if (bank == 150 and (motion == 1710 or motion < 1700 or motion > 1707)) or bank ~= 150 then
                state.fullLayer:set_Speed(1.4)
            end
        end

        if cfg.windstorm_slash and state.fullNode == "Job05_CycloneSlashFinish" and button_on(49152) then
            return sdk.PreHookResult.SKIP_ORIGINAL
        end
    end)
else
    warn("Action hook method not found")
end

-- Normal charged-attack successful timing.
local combo_method = sdk.find_type_definition("app.Job05ActionController"):get_method("requestSpeedComboSuccessEffect()")
if combo_method then
    sdk.hook(combo_method, function(args)
        if not cfg.charged_attacks then return end
        refresh_player()
        if not is_warrior() then return end
        local params = get_job_params()
        if params then params.ChargeNormalAttackParam.SecPrepare = 0.975 end

        -- Original Weaponlord stack trigger; exclude other characters' combos.
        if cfg.light_attack_chain then
            local controller = sdk.to_managed_object(args[2])
            local owner = controller and safe_get(controller, "Chara")
            if owner and is_player_owned(owner) then
                local now = os.clock()
                if now - light_chain_last_success > cfg.light_chain_timeout then
                    light_chain_stacks = 0
                end
                light_chain_stacks = math.min(cfg.light_chain_max_stacks, light_chain_stacks + 1)
                light_chain_last_success = now

                -- Weaponlord parity: restore 20 stamina on each successful
                -- player-owned speed-combo trigger (including at max stacks).
                local stamina_manager = safe_call(owner, "get_StaminaManager()")
                    or safe_call(owner, "get_StaminaManager")
                if stamina_manager and cfg.chain_holybrust_bonus then
                    local ok = pcall(function() stamina_manager:add(20.0, false) end)
                    if not ok then
                        warn("Light-chain stamina recovery failed")
                    end
                end
            end
        end
    end)
end

-- Damage hook:
-- 1) preserve Tidal Wrath boss detection
-- 2) apply ArcRoar outgoing-player damage multiplier in the post-hook
local damage_method = sdk.find_type_definition("app.HitController"):get_method("calcDamageValue(app.HitController.DamageInfo)")
if damage_method then
    sdk.hook(damage_method,
        function(args)
            state.arcroar_damage_pending = false
            thread.get_hook_storage()["GSMAX_ArcRoar_DamageInfo"] = nil
            thread.get_hook_storage()["GSMAX_LightChain_DamageInfo"] = nil
            thread.get_hook_storage()["GSMAX_ArcObliteration_TriggerDI"] = nil
            thread.get_hook_storage()["GSMAX_ArcObliteration_BuffDI"] = nil
            thread.get_hook_storage()["GSMAX_ArcObliteration_HolyBrustDI"] = nil
            thread.get_hook_storage()["GSMAX_HorizontalSlashFull_TriggerDI"] = nil
            thread.get_hook_storage()["GSMAX_HorizontalSlashFull_BuffDI"] = nil
            thread.get_hook_storage()["GSMAX_HorizontalSlashFull_EffectDI"] = nil
            thread.get_hook_storage()["GSMAX_HorizontalSlashEX_ThirdDI"] = nil
            thread.get_hook_storage()["GSMAX_Warrior_IncomingDamageDI"] = nil
            thread.get_hook_storage()["GSMAX_ThrustEX_FinishDI"] = nil

            local di = sdk.to_managed_object(args[3])
            if not di then return end

            local ahc = safe_get(di, "<AttackHitController>k__BackingField")
            if ahc then
                local shell = safe_get(ahc, "<CachedShell>k__BackingField")
                local attacker = shell and safe_get(shell, "<OwnerCharacter>k__BackingField")
                    or safe_get(ahc, "<CachedCharacter>k__BackingField")

                -- Arc of Obliteration: the first real player-owned hit in the opening
                -- strike (native bank 150 / motion 2015, frame < 60) starts one 2-second buff.
                if cfg.arc_obliteration_hit_buff and is_warrior() and attacker
                    and is_player_owned(attacker) then
    if state.arc_obliteration_buff_remaining > 0.0 then
                        thread.get_hook_storage()["GSMAX_ArcObliteration_BuffDI"] = di

                        -- HolyBrust: only the second native Arc of Obliteration hit.
                        -- Observed native second hit is ~frame 82-84; later native hit is ~95-96.
                        if state.fullNode == "Job05_ArcOfObliterationEnd" and state.fullLayer
                            and not state.arc_obliteration_holybrust_latched then
                            local bank = safe_call(state.fullLayer, "get_MotionBankID()")
                            local motion = safe_call(state.fullLayer, "get_MotionID()")
                            local frame = safe_call(state.fullLayer, "get_Frame()") or safe_call(state.fullLayer, "get_Frame")
                            if bank == 150 and motion == 2015 and type(frame) == "number"
                                and frame > 60.0 and frame < 90.0 then
                                thread.get_hook_storage()["GSMAX_ArcObliteration_HolyBrustDI"] = di
                            end
                        end
                    elseif state.fullNode == "Job05_ArcOfObliterationEnd" and state.fullLayer
                        and not state.arc_obliteration_trigger_latched then
                        local bank = safe_call(state.fullLayer, "get_MotionBankID()")
                        local motion = safe_call(state.fullLayer, "get_MotionID()")
                        local frame = safe_call(state.fullLayer, "get_Frame()") or safe_call(state.fullLayer, "get_Frame")
                        if bank == 150 and motion == 2015 and type(frame) == "number" and frame < 60.0 then
                            thread.get_hook_storage()["GSMAX_ArcObliteration_TriggerDI"] = di
                        end
                    end
                end

                -- Horizontal Slash Full: first real native hit while frame < 60 starts
                -- a 2.4-second +20% outgoing-player damage buff. The triggering hit itself
                -- is not boosted by this buff; subsequent native player-owned hits are.
                if cfg.horizontal_slash_full_hit_buff and is_warrior() and attacker
                    and is_player_owned(attacker) then
                    if state.horizontal_slash_full_buff_remaining > 0.0 then
                        -- Diagnostic: capture actual native action on each hit while buff is live.
                        -- No effects or damage logic are changed by this instrumentation.
                        thread.get_hook_storage()["GSMAX_HorizontalSlashFull_BuffDI"] = di

                        -- First hit (<60) starts the buff; HolyBrust EFX/sound belong to
                        -- the second native hit, i.e. the later phase at frame >= 60.
                        if state.fullNode == "Job05_HorizonalSlashFull" and state.fullLayer
                            and not state.horizontal_slash_full_effect_latched then
                            local frame = safe_call(state.fullLayer, "get_Frame()") or safe_call(state.fullLayer, "get_Frame")
                            if type(frame) == "number" and frame >= 60.0 then
                                thread.get_hook_storage()["GSMAX_HorizontalSlashFull_EffectDI"] = di
                            end
                        end
                        -- DLC EX uses one native motion (150/1205) for both follow-up hits.
                        -- Second strike occurs around frame 22; third spin around frame 68.
                        if state.fullNode == "Job05_HorizonalSlashExComboFull" and state.fullLayer then
                            local bank = safe_call(state.fullLayer, "get_MotionBankID()")
                            local motion = safe_call(state.fullLayer, "get_MotionID()")
                            local frame = safe_call(state.fullLayer, "get_Frame()")
                            if bank == 150 and motion == 1205 and type(frame) == "number" then
                                if frame < 45.0 and not state.horizontal_slash_full_effect_latched then
                                    thread.get_hook_storage()["GSMAX_HorizontalSlashFull_EffectDI"] = di
                                elseif frame >= 45.0 and not state.horizontal_slash_ex_third_effect_latched then
                                    thread.get_hook_storage()["GSMAX_HorizontalSlashEX_ThirdDI"] = di
                                end
                            end
                        end
                    elseif state.fullNode == "Job05_HorizonalSlashFull" and state.fullLayer
                        and not state.horizontal_slash_full_trigger_latched then
                        local frame = safe_call(state.fullLayer, "get_Frame()") or safe_call(state.fullLayer, "get_Frame")
                        if type(frame) == "number" and frame < 60.0 then
                            thread.get_hook_storage()["GSMAX_HorizontalSlashFull_TriggerDI"] = di
                        end
                    end
                end

                -- DLC: God of War Thrust EX / HeavyRunningThrustFinishEx.
                -- The player's confirmed weapon ability 21 is required.
                -- Capture the native body animation frame at hit calculation time.
                if gsmax_ex and gsmax_ex.heavy_running_thrust_ex
                    and is_warrior() and attacker and is_player_owned(attacker)
                    and state.fullNode == "Job05_HeavyRunningThrustFinishEx"
                    and state.fullLayer then
                    local frame = safe_call(state.fullLayer, "get_Frame()")
                    if type(frame) == "number" and frame >= 60.0 and frame <= 90.0 then
                        thread.get_hook_storage()["GSMAX_ThrustEX_FinishDI"] = di
                    end
                end

                -- Only player-owned outgoing hits can receive the chain multiplier.
                if cfg.light_attack_chain and is_warrior() and attacker
                    and is_player_owned(attacker) and general_nodes[state.fullNode] then
                    thread.get_hook_storage()["GSMAX_LightChain_DamageInfo"] = di
                end

                if cfg.arcroar_damage_buff
                    and state.arcroar_buff_active
                    and state.arcroar_buff_remaining > 0.0
                    and attacker
                    and is_player_owned(attacker) then
                    state.arcroar_damage_pending = true
                    thread.get_hook_storage()["GSMAX_ArcRoar_DamageInfo"] = di

                end
            end

            -- Warrior exclusive incoming-damage tag.
            -- This is independent of Tidal Wrath: every real incoming player hit can
            -- apply the stamina penalty after native damage calculation.
            local dhc = safe_get(di, "<DamageHitController>k__BackingField")
            local receiver = dhc and safe_get(dhc, "<CachedCharacter>k__BackingField")
            if cfg.damage_stamina_debuff and receiver and is_player_owned(receiver) then
                refresh_player()
                if is_warrior() then
                    thread.get_hook_storage()["GSMAX_Warrior_IncomingDamageDI"] = di
                end
            end

            -- Existing Tidal Wrath receiver/attacker inspection.
            if not cfg.tidal_wrath or not counter_nodes[state.fullNode] then return end
            if not receiver or not is_player_owned(receiver) then return end
            if not ahc then return end

            local shell = safe_get(ahc, "<CachedShell>k__BackingField")
            local attacker = shell and safe_get(shell, "<OwnerCharacter>k__BackingField")
                or safe_get(ahc, "<CachedCharacter>k__BackingField")
            if attacker then
                local boss = safe_call(attacker, "get_IsBoss()")
                local go = safe_call(attacker, "get_GameObject()")
                local name = go and safe_call(go, "get_Name()") or ""
                name = name and string.sub(name, 1, 8) or ""
                state.isBoss = boss == true or name == "ch260000" or name == "ch260001"
            else
                state.isBoss = nil
            end
        end,
        function(retval)
            -- Weaponlord-style: native calcDamageValue has populated DamageInfo.Damage.
            if state.arcroar_damage_pending then
                state.arcroar_damage_pending = false
                local di = thread.get_hook_storage()["GSMAX_ArcRoar_DamageInfo"]
                if di then
                    local damage = safe_get(di, "Damage")
                    if type(damage) == "number" and damage > 0.0 then
                        local boosted = damage * cfg.arcroar_multiplier
                        local ok = pcall(function() di["Damage"] = boosted end)
                        if not ok then
                            log.error("[GSMAX-BUFF] DamageInfo.Damage write FAILED")
                        end
                    end
                end
            end
            -- Arc of Obliteration first-hit trigger. Native damage must already be positive,
            -- so zero/non-damaging collision checks cannot start the buff. The triggering hit
            -- itself is not boosted; the 1.20 multiplier applies to subsequent outgoing hits.

            local arcobl_trigger_di = thread.get_hook_storage()["GSMAX_ArcObliteration_TriggerDI"]
            thread.get_hook_storage()["GSMAX_ArcObliteration_TriggerDI"] = nil
            if arcobl_trigger_di and not state.arc_obliteration_trigger_latched then
                local damage = safe_get(arcobl_trigger_di, "Damage")
                if type(damage) == "number" and damage > 0.0 then
                    state.arc_obliteration_trigger_latched = true
                    state.arc_obliteration_buff_remaining = cfg.arc_obliteration_duration
                end
            end

            -- Horizontal Slash Full first-hit trigger. Require actual positive native damage.
            -- This hit starts the buff only; EFX/sound are reserved for the second hit.
            local hslash_trigger_di = thread.get_hook_storage()["GSMAX_HorizontalSlashFull_TriggerDI"]
            thread.get_hook_storage()["GSMAX_HorizontalSlashFull_TriggerDI"] = nil
            if hslash_trigger_di and not state.horizontal_slash_full_trigger_latched then
                local damage = safe_get(hslash_trigger_di, "Damage")
                if type(damage) == "number" and damage > 0.0 then
                    state.horizontal_slash_full_trigger_latched = true
                    state.horizontal_slash_full_buff_remaining = cfg.horizontal_slash_full_duration
                    state.horizontal_slash_ex_combo_entered = false
                end
            end

            -- Capture all remaining hook-storage values before spawning EFX. requestEffect can
            -- synchronously re-enter game code/hooks, so hook storage must not be queried again
            -- after play_holybrust_standalone() returns.
            local post_storage = thread.get_hook_storage()
            local holybrust_di = post_storage and post_storage["GSMAX_ArcObliteration_HolyBrustDI"] or nil
            local arcobl_buff_di = post_storage and post_storage["GSMAX_ArcObliteration_BuffDI"] or nil
            local chain_di = post_storage and post_storage["GSMAX_LightChain_DamageInfo"] or nil
            local hslash_buff_di = post_storage and post_storage["GSMAX_HorizontalSlashFull_BuffDI"] or nil
            local hslash_effect_di = post_storage and post_storage["GSMAX_HorizontalSlashFull_EffectDI"] or nil
            local hslash_third_di = post_storage and post_storage["GSMAX_HorizontalSlashEX_ThirdDI"] or nil
            local warrior_incoming_di = post_storage and post_storage["GSMAX_Warrior_IncomingDamageDI"] or nil
            local thrust_ex_di = post_storage and post_storage["GSMAX_ThrustEX_FinishDI"] or nil

            if post_storage then
                post_storage["GSMAX_ArcObliteration_HolyBrustDI"] = nil
                post_storage["GSMAX_ArcObliteration_BuffDI"] = nil
                post_storage["GSMAX_LightChain_DamageInfo"] = nil
                post_storage["GSMAX_HorizontalSlashFull_BuffDI"] = nil
                post_storage["GSMAX_HorizontalSlashFull_EffectDI"] = nil
                post_storage["GSMAX_HorizontalSlashEX_ThirdDI"] = nil
                post_storage["GSMAX_Warrior_IncomingDamageDI"] = nil
                post_storage["GSMAX_ThrustEX_FinishDI"] = nil
            end

            -- Warrior exclusive debuff: final incoming damage ratio drains the same
            -- percentage of MaxStamina. Do this before any requestEffect re-entry.
            if warrior_incoming_di then
                gsmax_apply_damage_stamina_debuff(warrior_incoming_di)
            end

            -- Thrust EX: +30% on every qualifying real hit, HolyBrust once per finish action.
            -- Clear hook storage before EFX because requestEffect may re-enter this hook.
            if thrust_ex_di then
                local damage = safe_get(thrust_ex_di, "Damage")
                if type(damage) == "number" and damage > 0.0 then
                    local wrote = pcall(function()
                        thrust_ex_di["Damage"] = damage * 1.30
                    end)
                    if not wrote then
                        log.error("[GSMAX-THRUST-EX] DamageInfo.Damage write FAILED")
                    end
                    if not state.thrust_ex_holybrust_latched then
                        state.thrust_ex_holybrust_latched = true
                        play_holybrust_standalone(true)
                        gsmax_trig_sound(1436869779)
                        log.error(string.format("[GSMAX-THRUST-EX] HIT frame 60-90 damage x1.30 applied=%s HolyBrust triggered", tostring(wrote)))
                    end
                end
            end

            -- Horizontal Slash Full: EFX + sound only on the second real native hit.
            if hslash_effect_di and not state.horizontal_slash_full_effect_latched then
                local damage = safe_get(hslash_effect_di, "Damage")
                if type(damage) == "number" and damage > 0.0 then
                    state.horizontal_slash_full_effect_latched = true
                    play_holybrust_standalone()
                    if cfg.chain_holybrust_bonus then gsmax_trig_sound(1436869779) end
                    -- Keep the timed buff alive for the DLC third spin and all other
                    -- eligible hits until the full 2.0 game seconds expire.
                end
            end


            -- DLC third spin: independent HolyBrust + sound, once per action.
            if hslash_third_di and not state.horizontal_slash_ex_third_effect_latched then
                local damage = safe_get(hslash_third_di, "Damage")
                if type(damage) == "number" and damage > 0.0 then
                    state.horizontal_slash_ex_third_effect_latched = true
                    play_holybrust_standalone()
                    if cfg.chain_holybrust_bonus then gsmax_trig_sound(1436869779) end
                end
            end

            if holybrust_di and not state.arc_obliteration_holybrust_latched then
                local damage = safe_get(holybrust_di, "Damage")
                if type(damage) == "number" and damage > 0.0 then
                    state.arc_obliteration_holybrust_latched = true
                    play_holybrust_standalone(true) -- Restore original hit-gated HolyBrust {16,12,0}
                    if cfg.chain_holybrust_bonus then gsmax_trig_sound(1436869779) end
                end
            end

            if cfg.chain_holybrust_bonus
                and arcobl_buff_di and state.arc_obliteration_buff_remaining > 0.0 then
                local damage = safe_get(arcobl_buff_di, "Damage")
                if type(damage) == "number" and damage > 0.0 then
                    local ok = pcall(function()
                        arcobl_buff_di["Damage"] = damage * cfg.arc_obliteration_multiplier
                    end)
                    if not ok then warn("Arc of Obliteration buff damage write FAILED") end
                end
            end

            if cfg.chain_holybrust_bonus and hslash_buff_di then
                local damage = safe_get(hslash_buff_di, "Damage")
                if type(damage) == "number" and damage > 0.0 then
                    local ok = pcall(function()
                        hslash_buff_di["Damage"] = damage * cfg.horizontal_slash_full_multiplier
                    end)
                    if not ok then warn("Horizontal Slash Full buff damage write FAILED") end
                end
            end

            -- Apply the original (1 + 0.1 * stacks) multiplier after native damage
            -- calculation; preserve ArcRoar's existing post-hook damage bonus.
            -- chain_di was captured before HolyBrust requestEffect(), because that call
            -- can synchronously re-enter hooks and invalidate/change the current hook storage.
            if chain_di and cfg.chain_holybrust_bonus then
                if os.clock() - light_chain_last_success > cfg.light_chain_timeout then
                    light_chain_stacks = 0
                end
                if light_chain_stacks > 0 then
                    local damage = safe_get(chain_di, "Damage")
                    if type(damage) == "number" and damage > 0.0 then
                        local ok = pcall(function()
                            chain_di["Damage"] = damage * (1.0 + 0.1 * light_chain_stacks)
                        end)
                        if not ok then warn("Light attack chain damage write FAILED") end
                    end
                end
            end
            return retval
        end
    )
end

local function is_skillmaker_arcroar_buff_active()
    -- Exact Skill Maker state, not inferred from an action or a timer.
    -- Uses Skill Maker's generic public API; read-only from this runtime.
    local api = rawget(_G, "SkillMaker_API")
    local active = type(api) == "table" and api.ActiveSkills or nil
    if type(active) ~= "table" then return false end

    if active["GS_MAX\\MAX ArcRoarBuff"] or active["MAX ArcRoarBuff"] then
        return true
    end

    -- Keep parity with Skill Maker's *ArcRoarBuff substring search.
    for key, tbl in pairs(active) do
        local name = nil
        if type(key) == "string" then name = key end
        if type(tbl) == "table" and type(tbl.name) == "string" then name = tbl.name end
        if type(name) == "string" and name:find("ArcRoarBuff", 1, true) then
            return true
        end
    end
    return false
end

local function update_arcroar_vfx2_trigger()
    if not cfg.arcroar_damage_buff or not is_warrior() or not state.fullLayer then
        state.arcroar_vfx2_trigger_latched=false
        return
    end
    local frame=safe_call(state.fullLayer,"get_Frame()") or safe_call(state.fullLayer,"get_Frame")
    local mot=safe_call(state.fullLayer,"get_HighestWeightMotionNode()") or safe_call(state.fullLayer,"get_HighestWeightMotionNode")
    local anim=mot and (safe_call(mot,"get_MotionName()") or safe_call(mot,"get_MotionName")) or ""
    local arcroar_skill_active = is_skillmaker_arcroar_buff_active()
    local ready=arcroar_skill_active
        and type(anim)=="string"
        and anim:find("atk_custom_warcry_for_selfbuff",1,true)~=nil
        and type(frame)=="number" and frame>=170.0 and frame<=175.0
    if ready and not state.arcroar_vfx2_trigger_latched then
        state.arcroar_vfx2_trigger_latched=true
        start_arcroar_buff()
    elseif not ready then
        state.arcroar_vfx2_trigger_latched=false
    end
end


-- DLC EX AFFixes: READ-ONLY monitoring, using the v1.5 in-game verified equipment path.
-- Confirmed by player: HeavyRunningThrust EX = ability slot ID 21.
-- Confirmed by player: Tidal Wrath EX = 24; Gangliu Slash EX = 25.
-- Does not change any skill, equipment, parameter, or hook.
gsmax_ex = { ticks=0, last=nil, heavy_running_thrust_ex=false, tidal_wrath_ex=false, gangliu_slash_ex=false, slots=nil }
local function get(o,f)
    if not o then return nil end
    local ok,v=pcall(o.get_field,o,f)
    return ok and v or nil
end
local function call(o,s,...)
    if not o then return nil end
    local ok,v=pcall(o.call,o,s,...)
    return ok and v or nil
end
local function static(t,f)
    local td=sdk.find_type_definition(t)
    if not td then return nil end
    local ok,v=pcall(sdk.get_native_field,nil,td,f)
    return ok and v or nil
end
local function gsmax_ex_scan()
    local im=sdk.get_managed_singleton('app.ItemManager')
    if not im then return 'WAIT: ItemManager unavailable' end
    local dict=get(im,'StorageDict')
    if not dict then return 'WAIT: StorageDict unavailable' end
    local arisen=static('app.ItemDefine','ArisenCharaId')
    if arisen==nil then return 'WAIT: ArisenCharaId unavailable' end
    local it=call(dict,'System.Collections.IEnumerable.GetEnumerator()')
    if not it then return 'WAIT: StorageDict enumerator unavailable' end
    local total,arisen_found,equipped,weapons=0,false,0,0
    local found=nil
    local ok,err=pcall(function()
        while total<500 and it:MoveNext() do
            total=total+1
            local cur=it._current -- Editor uses direct property access, not get_field
            if cur and cur.key==arisen and cur.value then
                arisen_found=true
                local list=cur.value
                local count=call(list,'get_Count()') or 0
                for i=0,math.min(count-1,999) do
                    local m=call(list,'get_Item(System.Int32)',i)
                    if m and call(m,'get_IsEquipped()')==true then
                        equipped=equipped+1
                        local item=call(m,'get_ItemData()')
                        if get(item,'<DataType>k__BackingField')==2 then
                            weapons=weapons+1
                            local ability=call(m,'get_Ability()')
                            if ability then
                                local slots={}
                                for k=1,4 do slots[k]=tostring(get(ability,'Slot'..k)) end
                                found={id=tostring(call(m,'get_ItemId()')), storage=tostring(call(m,'get_StorageId()')), slots=slots}
                            else
                                found='WAIT: equipped weapon get_Ability() unavailable'
                            end
                        end
                    end
                end
                break
            end
        end
    end)
    if not ok then return 'WAIT: enumerating equipment raised '..tostring(err) end
    if found then return found end
    return 'WAIT: DictEntries='..total..' ArisenFound='..tostring(arisen_found)..' Equipped='..equipped..' Weapons='..weapons
end
local function gsmax_ex_update()
    gsmax_ex.ticks=gsmax_ex.ticks+1
    if gsmax_ex.ticks%120~=0 then return end
    local ok,result=pcall(gsmax_ex_scan)
    if not ok then result='WAIT: scan exception '..tostring(result) end
    if type(result)=='table' then
        local slots=result.slots
        local heavy,tidal,gangliu=false,false,false
        for i=1,4 do
            local id=tonumber(slots[i])
            if id==21 then heavy=true end
            if id==24 then tidal=true end
            if id==25 then gangliu=true end
        end
        gsmax_ex.heavy_running_thrust_ex=heavy
        gsmax_ex.tidal_wrath_ex=tidal
        gsmax_ex.gangliu_slash_ex=gangliu
        gsmax_ex.slots=slots
        local msg='WEAPON: ItemId='..result.id..' StorageId='..result.storage..' Slots='..table.concat(slots,',')..' HeavyRunningThrustEX='..tostring(heavy)..' TidalWrathEX='..tostring(tidal)..' GangliuSlashEX='..tostring(gangliu)
        if msg~=gsmax_ex.last then
            gsmax_ex.last=msg
            log.error('[GSMAX-EX-AFFIX] '..msg)
        end
    else
        gsmax_ex.heavy_running_thrust_ex=false
        gsmax_ex.tidal_wrath_ex=false
        gsmax_ex.gangliu_slash_ex=false
        gsmax_ex.slots=nil
        local msg=tostring(result)
        if msg~=gsmax_ex.last then
            gsmax_ex.last=msg
            log.error('[GSMAX-EX-AFFIX] '..msg)
        end
    end
end

re.on_application_entry("LateUpdateBehavior", function()
    if state.damage_stamina_cooldown_remaining > 0.0 then
        state.damage_stamina_cooldown_remaining = math.max(0.0,
            state.damage_stamina_cooldown_remaining - get_game_delta())
    end
    if not refresh_player() or not is_warrior() then return end
    gsmax_ex_update()
    -- Skill Maker public bridge: fire the validated B VFX + sound once at
    -- activation (skill time 0.0), independently for each named skill.
    -- ActiveSkills is refreshed by Skill Maker each frame; storage identity
    -- distinguishes successive casts even when the skill name is unchanged.
    local sm_api = rawget(_G, "SkillMaker_API")
    local sm_active = sm_api and sm_api.ActiveSkills
    local sm_targets = {
        "GS_MAX\\MAX AirSlamLanding",
        "GS_MAX\\MAX HeavySlamVFX",
    }
    for _, skill_name in ipairs(sm_targets) do
        local active = type(sm_active) == "table" and sm_active[skill_name] or nil
        local cast_storage = active and active.storage or nil
        if cast_storage then
            if state.gsmax_sm_b_seen[skill_name] ~= cast_storage then
                state.gsmax_sm_b_seen[skill_name] = cast_storage
                local b_ok = gsmax_play_thrust_ex_impact_b()
                gsmax_trig_sound(1536488334)
                info("Skill Maker B+sound at 0.0s: " .. skill_name
                    .. " B=" .. tostring(b_ok))
            end
        else
            state.gsmax_sm_b_seen[skill_name] = nil
        end
    end
    -- Thrust EX B: require a verified low-frame observation BEFORE crossing 80.
    -- The action request can precede the motion-layer transition, so its first
    -- sampled frame may belong to the previous action. Never fire on that sample.
    -- Never re-arm on a frame rewind: a finish action gets at most one B.
    if state.fullNode == "Job05_HeavyRunningThrustFinishEx" and state.fullLayer then
        local frame = safe_call(state.fullLayer, "get_Frame()")
        if type(frame) == "number" then
            local prev = state.thrust_ex_impact_b_last_frame
            -- Frame <=30 is used only to establish that the new finish motion
            -- has started; it cannot itself trigger the effect.
            if frame >= 0.0 and frame <= 30.0 and not state.thrust_ex_impact_b_latched then
                state.thrust_ex_impact_b_armed = true
            end
            -- Sound 1536488334 plays once as the animation crosses frame 75.
            if gsmax_ex and gsmax_ex.heavy_running_thrust_ex
                and state.thrust_ex_impact_b_armed
                and not state.thrust_ex_sound75_latched
                and prev ~= nil and prev < 72.0 and frame >= 72.0 then
                state.thrust_ex_sound75_latched = true
                gsmax_trig_sound(1536488334)
            end
            if gsmax_ex and gsmax_ex.heavy_running_thrust_ex
                and state.thrust_ex_impact_b_armed
                and not state.thrust_ex_impact_b_latched
                and prev ~= nil and prev < 72.0 and frame >= 72.0 then
                state.thrust_ex_impact_b_latched = true
                state.thrust_ex_impact_b_armed = false
                local b_ok = gsmax_play_thrust_ex_impact_b()
                info("Thrust EX B verified frame80: prev=" .. tostring(prev)
                    .. " frame=" .. tostring(frame) .. " B=" .. tostring(b_ok))
            end
            state.thrust_ex_impact_b_last_frame = frame
        end
    end
    if state.fullNode ~= "Job05_HeavyRunningThrustFinishEx" then
        state.thrust_ex_impact_b_latched = false
        state.thrust_ex_sound75_latched = false
        state.thrust_ex_impact_b_armed = false
        state.thrust_ex_impact_b_last_frame = nil
    end
    -- Re-arm the one-shot HolyBrust when the native finish action ends.
    if state.fullNode ~= "Job05_HeavyRunningThrustFinishEx" then
        state.thrust_ex_holybrust_latched = false
    end
    if not state.params_set then set_params() end
    update_arcroar_vfx2_trigger()

    if state.arcroar_buff_active then
        update_arcroar_vfx_follow()
        state.arcroar_buff_remaining = state.arcroar_buff_remaining - get_game_delta()
        if state.arcroar_buff_remaining <= 0.0 then
            state.arcroar_buff_remaining = 0.0
            state.arcroar_buff_active = false
            finish_arcroar_vfx()
            log.error("[GSMAX-BUFF] ArcRoarBuff OFF (game-time; native VFX termination)")
        end
    elseif state.arcroar_vfx_watch_remaining > 0.0 then
        -- Keep following the original shell transform during native termination.
        -- The terminal CreatedEffect is spawned from that shell, so keeping the
        -- shell on Spine_1 fixes the end flash at its source instead of only
        -- trying to move EffectPlayer GameObjects after creation.
        update_arcroar_vfx_follow()
        state.arcroar_vfx_watch_remaining=math.max(0.0,state.arcroar_vfx_watch_remaining-get_game_delta())
        if state.arcroar_vfx_watch_remaining<=0.0 then
            state.arcroar_vfx_req_id=nil
            state.arcroar_vfx_shell=nil
            state.arcroar_vfx_xform=nil
            state.arcroar_vfx_efx2=nil
            state.arcroar_vfx_seen={}
        end
    end

    local frame = state.fullLayer and (safe_call(state.fullLayer, "get_Frame()") or safe_call(state.fullLayer, "get_Frame")) or nil

    -- Full skill plays both gold hits; OneHit skill plays ONLY the second gold hit.
    -- Same public ActiveSkills bridge used for other GS_MAX skills above.
    -- A missing SkillMaker_API or inactive skill must fail closed (no gold).
    local arc_sm_active = sm_api and sm_api.ActiveSkills
    local arc_full_active = type(arc_sm_active) == "table" and (
        arc_sm_active["GS_MAX\\MAX UltiMaxJust1"]
        or arc_sm_active["MAX UltiMaxJust1"]
        or arc_sm_active["Skill: MAX UltiMaxJust1"]
    ) or nil
    local arc_onehit_active = type(arc_sm_active) == "table" and (
        arc_sm_active["GS_MAX\\MAX UltiJust1OneHit"]
        or arc_sm_active["MAX UltiJust1OneHit"]
        or arc_sm_active["Skill: MAX UltiJust1OneHit"]
    ) or nil
    local arc_full_enabled = arc_full_active ~= nil and arc_full_active ~= false
    local arc_onehit_enabled = arc_onehit_active ~= nil and arc_onehit_active ~= false
    local arc_ultimax_enabled = arc_full_enabled or arc_onehit_enabled

    -- Preserve native motion/frame triggers and miss-independent behavior,
    -- with first gold gated to full skill only and second gold to either skill.
    if arc_ultimax_enabled and state.fullNode == "Job05_ArcOfObliterationEnd" and state.fullLayer then
        local arc_bank = safe_call(state.fullLayer, "get_MotionBankID()")
        local arc_motion = safe_call(state.fullLayer, "get_MotionID()")
        if arc_bank == 150 and arc_motion == 2015 and type(frame) == "number" then
            if arc_full_enabled and frame >= ARC_GOLD1_FRAME and frame < 60.0 and not state.arc_gold_first_latched then
                state.arc_gold_first_latched = true
                play_holybrust_standalone(true, 20) -- gold first strike {10,6,20}
                info("[GSMAX-ARC-GOLD] first {10,6,20} frame=" .. tostring(frame))
            end
            if frame >= ARC_GOLD2_FRAME and not state.arc_gold_second_latched then
                state.arc_gold_second_latched = true
                play_holybrust_standalone(true, 21) -- gold second strike {10,6,21}, hit-independent
                info("[GSMAX-ARC-GOLD] second {10,6,21} frame=" .. tostring(frame))
            end

        end
    else
        state.arc_gold_first_latched = false
        state.arc_gold_second_latched = false
    end

    if state.arc_obliteration_buff_remaining > 0.0 then
        state.arc_obliteration_buff_remaining = math.max(0.0,
            state.arc_obliteration_buff_remaining - get_game_delta())
    end

    if state.horizontal_slash_full_buff_remaining > 0.0 then
        -- Do not end the buff during the transition from the initial slash to EX combo.
        -- Once EX combo has actually been entered, leaving it ends the buff early.
        local in_ex_combo = state.fullNode == "Job05_HorizonalSlashExComboFull"
            or state.fullNode == "HorizonalSlashExComboFull"
        if in_ex_combo then
            state.horizontal_slash_ex_combo_entered = true
        elseif state.horizontal_slash_ex_combo_entered then
            state.horizontal_slash_full_buff_remaining = 0.0
            state.horizontal_slash_ex_combo_entered = false
        end
        if state.horizontal_slash_full_buff_remaining > 0.0 then
            state.horizontal_slash_full_buff_remaining = math.max(0.0,
                state.horizontal_slash_full_buff_remaining - get_game_delta())
        end
    else
        state.horizontal_slash_ex_combo_entered = false
    end

    -- Re-arm Horizontal Slash Full only after leaving that action.
    if state.horizontal_slash_full_trigger_latched
        and state.fullNode ~= "Job05_HorizonalSlashFull"
        and state.fullNode ~= "HorizonalSlashExComboFull"
        and state.fullNode ~= "Job05_HorizonalSlashExComboFull" then
        state.horizontal_slash_full_trigger_latched = false
        state.horizontal_slash_full_effect_latched = false
        if state.fullNode ~= "HorizonalSlashExComboFull"
            and state.fullNode ~= "Job05_HorizonalSlashExComboFull" then
            state.horizontal_slash_ex_third_effect_latched = false
        end
    end

    -- Re-arm gold if native motion exits (including same-node transitions).
    if state.fullNode == "Job05_ArcOfObliterationEnd" and state.fullLayer then
        local ab = safe_call(state.fullLayer, "get_MotionBankID()")
        local am = safe_call(state.fullLayer, "get_MotionID()")
        if ab ~= 150 or am ~= 2015 then
            state.arc_gold_first_latched = false
            state.arc_gold_second_latched = false
        end
    end

    -- Re-arm only after leaving the native Arc of Obliteration end motion.
    if state.arc_obliteration_trigger_latched then
        local bank = state.fullLayer and safe_call(state.fullLayer, "get_MotionBankID()") or nil
        local motion = state.fullLayer and safe_call(state.fullLayer, "get_MotionID()") or nil
        if state.fullNode ~= "Job05_ArcOfObliterationEnd" or bank ~= 150 or motion ~= 2015 then
            state.arc_obliteration_trigger_latched = false
            state.arc_obliteration_holybrust_latched = false
        end
    elseif state.arc_obliteration_holybrust_latched then
        local bank = state.fullLayer and safe_call(state.fullLayer, "get_MotionBankID()") or nil
        local motion = state.fullLayer and safe_call(state.fullLayer, "get_MotionID()") or nil
        if state.fullNode ~= "Job05_ArcOfObliterationEnd" or bank ~= 150 or motion ~= 2015 then
            state.arc_obliteration_holybrust_latched = false
        end
    end

    -- Reliable native completion for shortened Indomitable Lash.
    -- Natural transitions get first priority. Only repair a 1301 state that
    -- persists beyond frame 3 after this charge has passed through 1300.
    if cfg.indomitable_lash and state.fullLayer and state.skillState == 58 then
        local bank = safe_call(state.fullLayer, "get_MotionBankID()")
        local motion = safe_call(state.fullLayer, "get_MotionID()")

        if bank == 150 and motion == 1300 then
            state.il1302_seen_1300 = true
            state.il1302_repaired = false
        elseif bank == 150 and motion == 1302 then
            state.il1302_repaired = true
        elseif bank == 150 and motion == 1301
            and state.il1302_seen_1300
            and not state.il1302_repaired
            and frame and frame > 3.0 then

            state.il1302_repaired = true
            request_native_1302()
        end
    else
        state.il1302_seen_1300 = false
        state.il1302_repaired = false
    end

    -- Dullahan only accelerates the opening of Tidal Wrath; restore speed after frame 20.
    if state.fullNode == "Job05_CounterAttack" and frame and frame > 20 and state.fullLayer then
        state.fullLayer:set_Speed(1.0)
    end
end)



-- Greatsword MAX Warrior in-game settings
-- Runtime-only switch: can be changed at any time from REFramework > Script Generated UI.
re.on_draw_ui(function()
    if imgui.tree_node("Greatsword MAX - Warrior") then
        local changed, enabled = imgui.checkbox(
            "Damage -> Stamina Debuff",
            cfg.damage_stamina_debuff
        )
        if imgui.is_item_hovered() then
            imgui.set_tooltip(
                "When the Warrior takes damage, Stamina is reduced according to the HP loss."
            )
        end
        if changed then
            cfg.damage_stamina_debuff = enabled
            info("Damage -> Stamina Debuff " .. (enabled and "ON" or "OFF"))
        end

        local bonus_changed, bonus_enabled = imgui.checkbox(
            "Combo Bonus",
            cfg.chain_holybrust_bonus
        )
        if imgui.is_item_hovered() then
            imgui.set_tooltip(
                "Enables Light Attack / Windstorm Slash chain and PowerBrust-related damage bonuses"
            )
        end
        if bonus_changed then
            cfg.chain_holybrust_bonus = bonus_enabled
            info("Combo Bonus "
                .. (bonus_enabled and "ON" or "OFF"))
        end

        imgui.tree_pop()
    end
end)

re.on_script_reset(function()
    state.params_set=false
    state.damage_stamina_cooldown_remaining=0.0
    state.il1302_seen_1300=false
    state.il1302_repaired=false
    state.arcroar_buff_remaining=0.0
    state.arcroar_buff_active=false
    state.arcroar_damage_pending=false
    light_chain_stacks=0
    light_chain_last_success=-math.huge
    state.arcroar_vfx2_trigger_latched=false
    state.arc_obliteration_buff_remaining=0.0
    state.arc_obliteration_trigger_latched=false
    state.arc_obliteration_holybrust_latched=false
    state.arc_gold_first_latched=false
    state.arc_gold_second_latched=false
    state.horizontal_slash_full_buff_remaining=0.0
    state.horizontal_slash_full_trigger_latched=false
    state.horizontal_slash_ex_combo_entered=false
    state.horizontal_slash_full_effect_latched=false
    state.horizontal_slash_ex_third_effect_latched=false
    state.thrust_ex_holybrust_latched=false
    state.thrust_ex_impact_b_latched=false
    state.thrust_ex_impact_b_armed=false
    state.thrust_ex_impact_b_last_frame=nil
    state.arcroar_vfx_req_id=nil
    state.arcroar_vfx_shell=nil
    state.arcroar_vfx_xform=nil
    state.arcroar_vfx_efx2=nil
    state.arcroar_vfx_seen={}
    state.arcroar_vfx_watch_remaining=0.0
end)

info("loaded - v1.3.1 ArcRoar Poise + Light Attack Chain")
