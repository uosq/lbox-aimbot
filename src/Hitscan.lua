---@type table<integer, integer>
local valid_targets, previous_valid_targets = {}, {}

-------------------------------------
-- define variables here

local gui = gui
local engine = engine
local math = math

local TraceLine = engine.TraceLine

local pi = math.pi
local pidivided = 180 / pi
local atan = math.atan
local deg = math.deg
local acos = math.acos
local EulerAngles = EulerAngles

local HitboxBoneIndex = { Head = 1, Neck = 2, Pelvis = 4, Body = 5, Chest = 7, Feet = 11 }

local SpecialWeaponIndexes = {
   SYDNEY_SLEEPER = 230, AMBASSADOR = 61, FESTIVE_AMBASSADOR = 1006
}

local current_weapon = nil

-------------------------------------
-- functions go here

---@param name string
local function bGetGUIValue(name)
   return gui.GetValue(name) == 1
end

--- Calculates the angle from source to dest
---@param source Vector3
---@param dest Vector3
---@return EulerAngles
local function CalculateAngle(source, dest)
   local angles = EulerAngles()
   local delta = source - dest

   angles.pitch = atan(delta.z / delta:Length2D()) * pidivided
   angles.yaw = atan(delta.y, delta.x) * pidivided

   if delta.x > 0 then
      angles.yaw = angles.yaw + 180
   elseif delta.x < 0 then
      angles.yaw = angles.yaw - 180
   end

   return angles
end

---@param source EulerAngles
---@param dest EulerAngles
local function CalculateFOV(source, dest)
   local v_source = source:Forward()
   local v_dest = dest:Forward()
   local result = deg(acos(v_dest:Dot(v_source) / v_dest:LengthSqr()))
   if result == "inf" or result ~= result then
      result = 0
   end
   return result
end

--- Populates(? idk if its the right word) the valid_targets table
---@param cmd UserCmd
local function CreateMove_ValidTargets(cmd)
   --- make it aim at sentries, dispensers, teleporters, merasmus, that flying eye thing and tank later, i didnt even make it aim at players yet lol
   --local aim_at_sentries = GetValue("aim sentry")
   --local aim_at_other_buildings = GetValue("aim other buildings")

   --- we will only run stuff when lbox aimbot is turned off
   if bGetGUIValue("aim bot") then return end

   --- clear the table
   previous_valid_targets = {}

   local localplayer = entities:GetLocalPlayer()
   if not localplayer then return end

   --- loop the players
   for _, player in pairs(entities.FindByClass("CTFPlayer")) do
      if player:GetTeamNumber() == localplayer:GetTeamNumber() then goto loopend1 end
      if player:IsDormant() or not player:IsAlive() then goto loopend1 end
      if player:InCond(E_TFCOND.TFCond_Cloaked) and bGetGUIValue("ignore cloaked") then goto loopend1 end
      if player:InCond(E_TFCOND.TFCond_Taunting) and bGetGUIValue("ignore taunting") then goto loopend1 end
      if player:InCond(E_TFCOND.TFCond_Disguised) and bGetGUIValue("ignore disguised") then goto loopend1 end
      if player:InCond(E_TFCOND.TFCond_DeadRingered) and bGetGUIValue("ignore deadringer") then goto loopend1 end
      if player:InCond(E_TFCOND.TFCond_Bonked) and bGetGUIValue("ignore bonked") then goto loopend1 end
      previous_valid_targets[#previous_valid_targets + 1] = player:GetIndex()
      ::loopend1::
   end

   --- just swap them instead of making a new table every tick
   valid_targets, previous_valid_targets = previous_valid_targets, valid_targets
end

--- Gets the shooting position of the player with the view offset added
---@param player Entity
local function GetShootPos(player)
   return (player:GetAbsOrigin() + player:GetPropVector("m_vecViewOffset[0]"))
end

--- Returns the hitbox bone index that should be used
---@param localplayer Entity
---@param weapon Entity
local function GetAimPosition(localplayer, weapon)
   local class = localplayer:GetPropInt("m_PlayerClass", "m_iClass")
   local item_def_idx = weapon:GetPropInt("m_iItemDefinitionIndex")

   if class == TF2_Sniper then
      if SpecialWeaponIndexes[item_def_idx] then return HitboxBoneIndex.Body end
      return localplayer:InCond(E_TFCOND.TFCond_Zoomed) and HitboxBoneIndex.Head or HitboxBoneIndex.Body
   elseif class == TF2_Spy then
      if SpecialWeaponIndexes[item_def_idx] then
         return weapon:GetWeaponSpread() > 0 and HitboxBoneIndex.Body or HitboxBoneIndex.Head
      end
   end

   return HitboxBoneIndex.Pelvis
end

--- Gets the hitbox bone index position on the player
---@param player Entity
local function GetHitboxPos(player, hitbox)
   local model = player:GetModel()
   local studioHdr = models.GetStudioModel(model)

   local pHitBoxSet = player:GetPropInt("m_nHitboxSet")
   local hitboxSet = studioHdr:GetHitboxSet(pHitBoxSet)
   local hitboxes = hitboxSet:GetHitboxes()

   local hitbox = hitboxes[hitbox]
   local bone = hitbox:GetBone()

   local boneMatrices = player:SetupBones()
   local boneMatrix = boneMatrices[bone]
   if boneMatrix then
      local bonePos = Vector3(boneMatrix[1][4], boneMatrix[2][4], boneMatrix[3][4])
      return bonePos
   end
   return nil
end

--- https://www.unknowncheats.me/forum/team-fortress-2-a/273821-canshoot-function.html
local lastFire = 0
local nextAttack = 0
local old_weapon = nil
---@param local_player Entity
local function CanShoot(local_player, weapon)
   local lastfiretime = weapon:GetPropFloat("LocalActiveTFWeaponData", "m_flLastFireTime")

   if lastFire ~= lastfiretime or weapon ~= old_weapon then
      lastFire = lastfiretime
      nextAttack = weapon:GetPropFloat("LocalActiveWeaponData", "m_flNextPrimaryAttack")
   end

   if weapon:GetPropInt("LocalWeaponData", "m_iClip1") == 0 then
      return false
   end

   old_weapon = weapon

   return nextAttack <= (local_player:GetPropInt("m_nTickBase") * globals.TickInterval())
end


---@param usercmd UserCmd
local function RunBullet(usercmd, localplayer, weapon)
   --- we will only run stuff when lbox aimbot is turned off
   local shootPos = GetShootPos(localplayer)
   local aimPos = GetAimPosition(localplayer, weapon)

   local closestFov = math.huge
   local chosen_angle = nil
   for _, targetindex in ipairs(valid_targets) do
      local target = entities.GetByIndex(targetindex)
      if not target then return end
      local targetPos = GetHitboxPos(target, aimPos)
      if not targetPos then return end

      local trace = TraceLine(shootPos, targetPos, (MASK_SHOT | CONTENTS_GRATE))
      --- if not visible from where we shoot, dont calculate angle and fov
      if trace.entity ~= target then return end

      local angle = CalculateAngle(shootPos, targetPos)
      local fov = CalculateFOV(engine:GetViewAngles(), angle)
      if fov > gui.GetValue("aim fov") or fov > closestFov then return end
      closestFov = fov
      chosen_angle = angle
   end

   if not chosen_angle then return end

   if gui.GetValue("norecoil") then
      local punchangle = localplayer:GetPropVector("m_vecPunchAngle")
      chosen_angle = chosen_angle - punchangle
   end

   local method = gui.GetValue("aim method")
   if method == "plain" then
      engine.SetViewAngles(EulerAngles(chosen_angle:Unpack()))
   elseif method == "smooth" then
      local viewangles = engine:GetViewAngles()
      local delta = chosen_angle - Vector3(viewangles:Unpack())
      usercmd.viewangles = usercmd.viewangles + (delta / gui.GetValue("smooth value"))
      engine.SetViewAngles(EulerAngles(usercmd.viewangles.x, usercmd.viewangles.y, 0))
   end

   if bGetGUIValue("auto shoot") then
      usercmd.buttons = usercmd.buttons | IN_ATTACK
   end

   if usercmd.buttons & IN_ATTACK == 1 then
      usercmd:SetViewAngles(chosen_angle:Unpack())
   end
end

---@param usercmd UserCmd
---@param localplayer Entity
---@param weapon Entity
local function RunMelee(usercmd, localplayer, weapon)
   local shootPos = GetShootPos(localplayer)
   local aimPos = GetAimPosition(localplayer, weapon)

   local closestFov = math.huge
   local chosen_angle = nil

   local vis_check = true
   local demoknight = false

   local method = gui.GetValue("melee aimbot")
   if method == "rage" then
      vis_check = false
   end

   for _, targetindex in ipairs(valid_targets) do
      local target = entities.GetByIndex(targetindex)
      if not target then return end
      local targetPos = GetHitboxPos(target, aimPos)
      if not targetPos then return end

      if vis_check then
         local trace = weapon:DoSwingTrace()
         --- if not visible from where we hit, dont calculate angle and fov
         if trace.entity ~= target then return end
      end

      local angle = CalculateAngle(shootPos, targetPos)
      local fov = CalculateFOV(engine:GetViewAngles(), angle)
      if fov > gui.GetValue("aim fov") or fov > closestFov then return end
      closestFov = fov
      chosen_angle = angle
   end

   if not chosen_angle then return end

   if gui.GetValue("norecoil") then
      local punchangle = localplayer:GetPropVector("m_vecPunchAngle")
      chosen_angle = chosen_angle - punchangle
   end

   if bGetGUIValue("auto shoot") then
      usercmd.buttons = usercmd.buttons | IN_ATTACK
   end

   if usercmd.buttons & IN_ATTACK == 1 then
      usercmd:SetViewAngles(chosen_angle:Unpack())

      if method == "legit" then
         usercmd.sendpacket = false
      end
   end
end

local function CreateMove_WeaponManager(usercmd)
   if bGetGUIValue("aim bot") then return end
   if warp.IsWarping() then return end
   if not input.IsButtonDown(gui.GetValue("aim key")) then return end

   local localplayer = entities:GetLocalPlayer()
   if not localplayer then return end

   local weapon = localplayer:GetPropEntity("m_hActiveWeapon")
   if not weapon then return end

   if not CanShoot(localplayer, weapon) then return end

   if weapon:IsMeleeWeapon() then
      RunMelee(usercmd, localplayer, weapon)
   elseif weapon:GetWeaponProjectileType() == E_ProjectileType.TF_PROJECTILE_BULLET then
      RunBullet(usercmd, localplayer, weapon)
   end
end

--local calls = {
--CM_validtargets = CreateMove_ValidTargets,
--CM_weaponmanager = CreateMove_WeaponManager,
--}

--return calls
-------------------------------------
-- callbacks go here

callbacks.Register("CreateMove", CreateMove_ValidTargets)
callbacks.Register("CreateMove", CreateMove_WeaponManager)
