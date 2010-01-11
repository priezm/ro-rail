-- A few persistent-state options used
RAIL.Validate.TempFriendRange = {"number",0,0,5}
RAIL.Validate.DefendFriends = {"boolean",false}
RAIL.Validate.ActorOptions = {is_subtable=true}
RAIL.Validate.ActorOptions.Default = {is_subtable=true,
	Friend = {"boolean",false},
	Priority = {"number",0},
	AttackAllowed = {"boolean",true},
	DefendOnly = {"boolean",false},
	SkillsAllowed = {"boolean",false},
	MinSkillLevel = {"number",1,1,10},
	MaxSkillLevel = {"number",5,1,10},
	TicksBetweenSkills = {"number",0,0},
	MaxCastsAgainst = {"number",0,0},
}
RAIL.Validate.ActorOptions.ByType = {is_subtable=true}
RAIL.Validate.ActorOptions.ByID = {is_subtable=true}

-- Actor Battle Options
do
	-- TODO: Optimize Actor Options...
	--
	--	Actor[id].BattleOpts (metatable; checks ByID, ByType, Default)
	--	ByID checks ByTypes
	--	ByTypes checks Defaults
	--	Defaults/ByID/ByTypes all trigger validation of tables
	--		RAIL.State.ActorOptions
	--		RAIL.State.ActorOptions.[Defaults/ByID/ByType]
	--
	--	Called almost every cycle...
	--

	-- Defaults
	do
		BattleOptsDefaults = { }
		setmetatable(BattleOptsDefaults,{
			__index = function(t,key)
				return RAIL.State.ActorOptions.Default[key]
			end
		})
	end

	-- By Type
	do
		-- Private key to access each type
		local type_key = {}

		-- Auto-generated subtables will use this metatable
		local mt = {
			__index = function(t,key)
				-- Check the RAIL.State.ActorOptions.ByType table
				local ByType = RAIL.State.ActorOptions.ByType
				local type_num = t[type_key]
				if type(ByType[type_num]) ~= "table" then
					ByType[type_num] = { }
				end

				-- Use value from ByType table if non-nil
				if ByType[type_num][key] ~= nil then
					-- TODO: Validation
					return ByType[type_num][key]
				end

				-- Otherwise, use default
				return BattleOptsDefaults[key]
			end
		}

		BattleOptsByType = {
			-- Mercenaries will use default options against actors of unknown type
			[-2] = BattleOptsDefaults
		}

		-- Generate subtables for each type requested
		setmetatable(BattleOptsByType,{
			__index = function(t,key)
				-- Make sure there are options for it
				if RAIL.State.ActorOptions.ByType[key] == nil then
					return nil
				end

				local ret = {
					[type_key] = key,
				}

				setmetatable(ret,mt)
				t[key] = ret

				return ret
			end
		})
	end

	-- By ID
	do
		-- Private key to access each ID
		local id_key = {}

		local mt = {
			__index = function(t,key)
				-- Check the RAIL.State.ActorOptions.ByID table
				local ByID = RAIL.State.ActorOptions.ByID
				local id_num = t[id_key]
				if type(ByID[id_num]) ~= "table" then
					ByID[id_num] = { }
				end

				-- Use value from ByID table if non-nil
				if ByID[id_num][key] ~= nil then
					-- TODO: Validation
					return ByID[id_num][key]
				end

				-- Otherwise, use ByType table
				local t = BattleOptsByType[Actors[id_num].Type]
					or BattleOptsDefaults
				return t[key]
			end
		}

		BattleOptsByID = { }
		setmetatable(BattleOptsByID,{
			__index = function(t,key)
				-- Make sure there are options for it
				if RAIL.State.ActorOptions.ByID[key] == nil then
					return nil
				end

				local ret = {
					[id_key] = key,
				}

				setmetatable(ret,mt)
				t[key] = ret

				return ret
			end
		})
	end

end

-- Actor data-collection
do
	-- This unique table ID will be used as a key to identify Actor tables
	local actor_key = {}

	RAIL.IsActor = function(actor)
		if type(actor) ~= "table" then return false end
		if actor[actor_key] == nil then return false end
		return true
	end

	-- The Actor "class" is private, because they're generated by referencing Actors
	local Actor = { }

	-- Metatables
	local Actor_mt = {
		__eq = function(self,other)
			if not RAIL.IsActor(other) then return false end

			return self.ID == other.ID
		end,

		__index = Actor,
	}

	if not RAIL.Mercenary then
		-- Homunculi will log the type of actor generated
		Actor_mt.__tostring = function(self)
			return string.format("%s #%d [Loc:(%d,%d), Type:%d]",
				self.ActorType, self.ID, self.X[0], self.Y[0], self.Type)
		end
	else
		-- Mercenaries are unable to distinguish type; don't log type
		Actor_mt.__tostring = function(self)
			return string.format("%s #%d [Loc:(%d,%d)]",
				self.ActorType, self.ID, self.X[0], self.Y[0])
		end
	end


	-- Private key for keeping closures
	local closures = {}

	-- Initialize a new Actor
	Actor.New = function(self,ID)
		local ret = { }
		setmetatable(ret,Actor_mt)

		ret.ActorType = "Actor"
		ret.ID = ID
		ret.Type = -1			-- "fixed" type (homus don't overlap players)
		ret.Hide = false		-- hidden?
		ret.LastUpdate = -1		-- GetTick() of last :Update() call
		ret.FullUpdate = false		-- Track position, motion, target, etc?
		ret.TargetOf = { }		-- Other Actors that are targeting this one
		ret.IgnoreTime = -1		-- Actor isn't currently ignored
		ret.BattleOpts = { }		-- Battle options

		-- Set defaults for battle options
		setmetatable(ret.BattleOpts,{
			__index = function(self,key)
				local t =
					BattleOptsByID[ret.ID] or
					BattleOptsByType[ret.Type] or
					BattleOptsDefaults or
					{
						Friend = false,
						Priority = 0,
						AttackAllowed = true,
						DefendOnly = false,
						SkillsAllowed = false,
						MinSkillLevel = 1,
						MaxSkillLevel = 5,
						TicksBetweenSkills = 0,
						MaxCastsAgainst = 0,
					}

				return t[key]
			end,
		})

		-- The following have their histories tracked
		ret.Target = History.New(-1,false)
		ret.Motion = History.New(MOTION_STAND,false)

		-- Position tracking uses a specialty "diff" function
		local pos_diff = function(a,b)
			if math.abs(a[1]-b[1]) > 1 then return true end
			if math.abs(a[2]-b[2]) > 500 then return true end
			return false
		end

		-- And they'll also predict sub-history positions
		ret.X = History.New(-1,true,pos_diff)
		ret.Y = History.New(-1,true,pos_diff)

		-- Set initial position
		local x,y = GetV(V_POSITION,ret.ID)
		if x ~= -1 then
			-- Hiding?
			if x == 0 and y == 0 then
				ret.Hide = true
			else
				History.Update(ret.X,x)
				History.Update(ret.Y,y)
			end
		end

		-- Set up the expiration timeout for 2.5 seconds...
		--	(it will be updated in Actor.Update)
		ret.ExpireTimeout = RAIL.Timeouts:New(2500,false,Actor.Expire,ret)

		ret[closures] = {
			DistanceTo = {},
			DistancePlot = {},
			BlocksTo = {},
			AngleTo = {},
			AngleFrom = {},
			AnglePlot = {},
		}

		-- Initialize the type
		Actor[actor_key](ret)

		-- Log
		if ID ~= -1 then
			RAIL.Log(10,"Actor class generated for %s.",tostring(ret))
			-- Extra data displayed for mercenary AIs
			if true and RAIL.Mercenary then
				-- Mercenaries should log extra information for Actors and NPCs
				if ret.ActorType == "Actor" or ret.ActorType == "NPC" then
					RAIL.Log(10,"   --> %s",StringBuffer.New()
						--:Append("V_TYPE="):Append(GetV(V_TYPE,ret.ID)):Append("; ")
						--:Append("V_HOMUNTYPE="):Append(GetV(V_HOMUNTYPE,ret.ID)):Append("; ")
						--:Append("V_MERTYPE="):Append(GetV(V_MERTYPE,ret.ID)):Append("; ")
						:Append("V_MOTION="):Append(GetV(V_MOTION,ret.ID)):Append("; ")
						:Append("V_TARGET="):Append(GetV(V_TARGET,ret.ID)):Append("; ")
						:Append("IsMonster="):Append(IsMonster(ret.ID)):Append("; ")
						:Get()
					)
				end
			end
		end

		return ret
	end

	-- A temporary "false" return for IsEnemy, as long as an actor is a specific type
	local ret_false = function() return false end

	-- A "private" function to initialize new actor types
	do
		local setActorType = function(actor,ActorType,PossibleEnemy,FullUpdate)
			-- Set Actor Type
			actor.ActorType = ActorType

			-- If not a possible enemy, replace IsEnemy with a false-return function
			if not PossibleEnemy then
				actor.IsEnemy = ret_false
			else
				if rawget(actor,"IsEnemy") == ret_false then
					rawset(actor,"IsEnemy",nil)
				end
			end

			-- Track position, motion, etc...
			actor.FullUpdate = FullUpdate
		end

		if not RAIL.Mercenary then
			-- Homunculi are able to determine monster type based on V_HOMUNTYPE
			Actor[actor_key] = function(self)
				-- Set the new type
				self[actor_key] = GetV(V_HOMUNTYPE,self.ID)
				self.Type = self[actor_key]

				-- Check the type for sanity
				if (self.ID < 100000 or self.ID > 110000000) and
					LIF <= self.Type and self.Type <= VANILMIRTH_H2
				then
					self.Type = self.Type + 6000
				end

				-- Initialize differently based upon type
				if self.Type == -1 then
					-- Unknowns are never enemies, but track data
					setActorType(self,"Unknown",false,true)

				-- Portals
				elseif self.Type == 45 then
					-- Portals are never enemies and shouldn't be tracked
					setActorType(self,"Portal",false,false)

				-- Player Jobs
				elseif (0 <= self.Type and self.Type <= 25) or
					(161 <= self.Type and self.Type <= 181) or
					(4001 <= self.Type and self.Type <= 4049)
				then
					-- Players are potential enemies and should be tracked
					setActorType(self,"Player",true,true)

				-- NPCs (non-player jobs that are below 1000)
				elseif self.Type < 1000 then
					-- NPCs are never enemies and shouldn't be tracked
					setActorType(self,"NPC",false,false)

				-- All other types
				else
					-- All other actors are probably monsters or homunculi
					setActorType(self,"Actor",true,true)
				end
			end
		else
			-- Specialized type determination for Mercenaries
			Actor[actor_key] = function(self,notnpc)
				-- Unable to distinguish types, so use other methods to detemine type
				self[actor_key] = -2
				self.Type = -2

				-- Find players based on ID
				if self.ID >= 100000 and self.ID <= 110000000 then
					-- Likely a player
					setActorType(self,"Player",true,true)

				-- NPCs and Portals stand still and are never monsters
				elseif not notnpc and
					IsMonster(self.ID) == 0 and
					GetV(V_MOTION,self.ID) == MOTION_STAND and
					GetV(V_TARGET,self.ID) == 0
				then
					-- Likely an NPC
					setActorType(self,"NPC",false,false)

				-- All other types
				else
					setActorType(self,"Actor",true,true)
				end
			end
		end
	end

	-- Update information about the actor
	Actor.Update = function(self)
		-- Check for a type change
		if not RAIL.Mercenary and GetV(V_HOMUNTYPE,self.ID) ~= self[actor_key] then
			-- Pre-log
			local str = tostring(self)

			-- Call the private type changing function
			Actor[actor_key](self)

			-- Log
			RAIL.Log(10,"%s changed type to %s.",str,tostring(self))
		elseif self.ActorType == "NPC" and GetV(V_MOTION,self.ID) ~= MOTION_STAND then
			-- Call the private type changing function
			Actor[actor_key](self,true)

			-- Log
			RAIL.Log(10,"Incorrectly identified %s as an NPC; fixed.",tostring(self))
		end

		-- Update the expiration timeout
		self.ExpireTimeout[2] = GetTick()
		if not self.ExpireTimeout[1] then
			self.ExpireTimeout[1] = true
			RAIL.Timeouts:Insert(self.ExpireTimeout)
		end

		-- Update ignore time
		if self.IgnoreTime > 0 then
			self.IgnoreTime = self.IgnoreTime - (GetTick() - self.LastUpdate)
		end

		-- Update the LastUpdate field
		self.LastUpdate = GetTick()

		-- Some actors don't require everything tracked
		if not self.FullUpdate then
			return self
		end

		-- Update the motion
		History.Update(self.Motion,GetV(V_MOTION,self.ID))

		-- Update the actor location
		local x,y = GetV(V_POSITION,self.ID)
		if x ~= -1 then
			-- Check for hidden
			if x == 0 and y == 0 then
				if not self.Hide then
					-- Log it
					self.Hide = true
				end
			else
				if self.Hide then
					-- Log it
					self.Hide = false
				end
				History.Update(self.X,x)
				History.Update(self.Y,y)
			end
		end

		-- Check if the actor is able to have a target
		if self.Motion[0] ~= MOTION_DEAD and self.Motion[0] ~= MOTION_SIT then
			-- Get the current target
			local targ = GetV(V_TARGET,self.ID)

			-- Normalize it...
			if targ == 0 then
				targ = -1
			end

			-- Keep a history of it
			History.Update(self.Target,targ)

			-- Tell the other actor that it's being targeted
			if targ ~= -1 then
				Actors[targ]:TargetedBy(self)
			end
		else
			-- Can't target, so it should be targeting nothing
			History.Update(self.Target,-1)
		end

		return self
	end

	-- Track when other actors target this one
	local targeted_time = {}
	Actor.TargetedBy = function(self,actor)
		-- If something targets an NPC, it isn't an NPC
		if RAIL.Mercenary and self.ActorType == "NPC" then
			-- Call the private type changing function
			Actor[actor_key](self,true)

			-- Log
			RAIL.Log(10,"Incorrectly identified %s as an NPC; fixed.",tostring(self))
		end

		-- Use a table to make looping through and counting it faster
		--	* to determine if an actor is targeting this one, use Actors[id].Target[0] == self.ID
		if math.abs((self.TargetOf[targeted_time] or 0) - GetTick()) > 50 then
			self.TargetOf = Table:New()
			self.TargetOf[targeted_time] = GetTick()
		end

		self.TargetOf:Insert(actor)
		return self
	end

	-- Clear out memory
	Actor.Expire = function(self)
		-- Log
		RAIL.Log(10,"Clearing history for %s due to timeout.",tostring(self))

		-- Unset any per-actor battle options
		local k,v
		for k,v in pairs(self.BattleOpts) do
			self.BattleOpts[k] = nil
		end

		-- Unset any closures used
		local t
		for k,t in pairs(self[closures]) do
			for k,v in pairs(t) do
				t[k] = nil
			end
		end

		-- Clear the histories
		History.Clear(self.Motion)
		History.Clear(self.Target)
		History.Clear(self.X)
		History.Clear(self.Y)
	end

	-------------
	-- Support --
	-------------
	-- The following functions support other parts of the script

	-- Check if the actor is an enemy (monster/pvp-player)
	Actor.IsEnemy = function(self)
		return IsMonster(self.ID) == 1
	end

	-- Check if the actor is a friend
	Actor.IsFriend = function(self)
		-- Make sure only players are counted as friends
		if self.ActorType ~= "Player" then
			return false
		end

		-- Check for temporary friends (players within <opt> range of owner)
		if RAIL.Owner:DistanceTo(self) <= RAIL.State.TempFriendRange then
			return true
		end

		-- Check if actor is on the friend list
		return self.BattleOpts.Friend
	end

	-- Set actor as a friend
	Actor.SetFriend = function(self,bool)
		-- Make sure only players are allowed on friend list
		if self.ActorType ~= "Player" then
			return
		end

		-- TODO: Set RAIL.State.ActorOptions.ByID[self.ID].Friend = true/false
	end

	-- Check if the actor is ignored
	Actor.IsIgnored = function(self)
		return self.IgnoreTime > 0
	end

	-- Ignore the actor for a specific amount of time
	Actor.Ignore = function(self,ticks)
		-- If it's already ignored, do nothing
		if self:IsIgnored() then
			-- TODO: Update the time? Max(ticks,self.IgnoreTime)?
			return self
		end

		-- Use default ticks if needed
		if type(ticks) ~= "number" then
			-- TODO: This
			ticks = 1000
		end

		-- TODO: Log
		RAIL.Log(2,"%s ignored for %d milliseconds.",tostring(self),ticks)

		self.IgnoreTime = ticks
	end

	-- Estimate Movement Speed (in milliseconds per cell) and Direction
	local find_non_move = function(v) return v ~= MOTION_MOVE end
	local find_move = function(v) return v == MOTION_MOVE end
	Actor.EstimateMove = function(self)
		-- Don't estimate too often
		if self.EstimatedMove ~= nil and GetTick() - self.EstimatedMove[3] < 250 then
			return unpack(self.EstimatedMove)
		end

		local move = -1
		local non_move = 0
		local time_delta
		local tile_delta
		local tile_angle

		repeat

			-- Find the most recent non-move
			non_move = History.FindMostRecent(self.Motion,find_non_move,move) or 0

			-- Find the most recent move that follows this non-move
			move = History.FindMostRecent(self.Motion,find_move,non_move)

			-- If there was never motion, use default move-speed of 150
			if move == nil or non_move <= move then
				-- Default move-speed to regular walk
				--	according to http://forums.roempire.com/archive/index.php/t-137959.html:
				--		0.15 sec per cell at regular speed
				--		0.11 sec per cell w/ agi up
				--		0.06 sec per cell w/ Lif's emergency avoid
				--
				--	Those values seem wrong, or are calculated differently...
				--		~0.21 sec per cell at regular speed
				--		~0.11 sec per cell with emergency avoid
				--
				time_delta = 150
				tile_delta = 1
				tile_angle = 0
				break
			end

			-- Determine the time passed
			time_delta = non_move - move

			local nmX,nmY = self.X[non_move],self.Y[non_move]
			local mX,mY = self.X[move],self.Y[move]

			-- Determine the direction/distance moved
			tile_angle,tile_delta = GetAngle(mX,mY,nmX,nmY)

		until time_delta > 50 and tile_delta > 0

		-- Return our estimated movement speed
		self.EstimatedMove = { time_delta / tile_delta, tile_angle, GetTick() }
		return unpack(self.EstimatedMove)
	end

	--------------------
	-- Battle Options --
	--------------------

	-- RAIL allowed to kill monster?
	Actor.IsAllowed = function(self)
		-- Determine if the monster is allowed at all
		return self.BattleOpts.AttackAllowed or self.BattleOpts.SkillsAllowed
	end

	-- Determine if attacking this actor would be kill-stealing
	Actor.WouldKillSteal = function(self)
		-- Free-for-all monsters are never kill-stealed
		if self.BattleOpts.FreeForAll then
			return false
		end

		-- Check if it's an enemy
		if not self:IsEnemy() then
			return false
		end

		-- Check if this actor is targeting anything
		local targ = self.Target[0]
		if targ ~= -1 then
			-- Owner and self don't count
			if targ == RAIL.Self.ID or targ == RAIL.Owner.ID then
				return false
			end

			local targ = Actors[targ]

			-- Determine if we're supposed to defend friends
			if RAIL.State.DefendFriends and targ:IsFriend() then
				return false
			end

			-- Determine if it's not targeting another enemy
			if not targ:IsEnemey() then

				-- Determine if the target has been updated recently
				if math.abs(targ.LastUpdate - GetTick()) < 50 then
					-- It would be kill stealing
					return true
				end

			end
		end

		-- Check if this actor is the target of anything
		local i
		for i=1,self.TargetOf:Size(),1 do
			targ = self.TargetOf[i]

			-- Determine if the targeter is...
			if
				targ ~= RAIL.Owner and				-- not the owner
				targ ~= RAIL.Self and				-- not ourself
				not targ:IsEnemy() and				-- not an enemy
				not targ:IsFriend() and				-- not a friend
				math.abs(GetTick() - targ.LastUpdate) < 50	-- updated recently
			then
				-- Likely kill-stealing
				return true
			end
		end

		-- TODO: Moving

		-- Default is not kill-steal
		return false
	end



	-- Kite / Attack**
	--	**- based partially on shared table, based partially on homu's current HP?

	--------------------
	-- Utils Wrappers --
	--------------------

	-- The following wrappers are fairly complex, so here are some examples:
	--
	--	RAIL.Owner:DistanceTo(x,y)
	--		Returns the pythagorean distance between owner and (x,y)
	--
	--	RAIL.Owner:DistanceTo(-500)(x,y)
	--		Returns the pythagorean distance between (x,y) and the owner's
	--		estimated position at 500 milliseconds into the future
	--
	--	RAIL.Owner:DistanceTo(RAIL.Self)
	--		Returns the pythagorean distance between owner and homu/merc
	--
	--	RAIL.Owner:DistanceTo(500)(RAIL.Self)
	--		Returns the pythagorean distance between owner's position
	--		500 milliseconds ago, and the homu/merc's position 500 milliseconds ago
	--
	--	RAIL.Owner:DistanceTo(RAIL.Self.X[500],RAIL.Self.Y[500])
	--		Returns the pythagorean distance between owner's current position
	--		and the homu/merc's position 500 milliseconds ago
	--
	--	RAIL.Owner:DistanceTo(-500)(RAIL.Self.X[0],RAIL.Self.Y[0])
	--		Returns the pythagorean distance between owner's estimated position
	--		(500ms into future), and homu/merc's current position.
	--
	-- Remember:
	--	- negative values represent future (estimated)
	--	- positive values represent past (recorded)
	--
	-- NOTE:
	--	Because of the nature of closures, a new function is generated for each
	--	originating actor and for each millisecond value. In effort to reduce
	--	memory bloat, keep arbitrary actors/numbers to a minimum.
	--		

	-- Pythagorean Distance
	Actor.DistanceTo = function(self,a,b)
		-- Check if a specific closure is requested
		if type(a) == "number" and b == nil then

			-- Check if a closure already exists
			if not self[closures].DistanceTo[a] then

				-- Create closure
				self[closures].DistanceTo[a] = function(x,y)				
					-- Main function logic follows

					-- Check if "x" is an actor table
					if RAIL.IsActor(x) then
						y = x.Y[a]
						x = x.X[a]
					end

					return PythagDistance(self.X(a),self.Y(a),x,y)

				end -- function(x,y)

			end -- not self[closures].DistanceTo[a]

			-- Return the requested closure
			return self[closures].DistanceTo[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.DistanceTo(self,0)(a,b)
	end

	-- Point along line of self and (x,y)
	Actor.DistancePlot = function(self,a,b,c)
		-- Check if a specific closure is requested
		if type(a) == "number" and c == nil then

			-- Check if a closure already exists
			if not self[closures].DistancePlot[a] then

				-- Create closure
				self[closures].DistancePlot[a] = function(x,y,dist_delta)
					-- Main function logic follows

					-- Check if "x" is an actor table
					if RAIL.IsActor(x) then
						dist = y
						y = x.Y[a]
						x = x.X[a]
					end

					-- TODO: finish
					return 0,0

				end -- function(x,y,dist)

			end -- not self[closures].DistancePlot[a]

			-- Return the requested closure
			return self[closures].DistancePlot[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.DistancePlot(self,0)(a,b,c)
	end

	-- Straight-line Block Distance
	Actor.BlocksTo = function(self,a,b)
		-- Check if a specific closure is requested
		if type(a) == "number" and b == nil then

			-- Check if a closure already exists
			if not self[closures].BlocksTo[a] then

				-- Create closure
				self[closures].BlocksTo[a] = function(x,y)
					-- Main function logic follows

					-- Check if "x" is an actor table
					if RAIL.IsActor(x) then
						y = x.Y[a]
						x = x.X[a]
					end

					return BlockDistance(self.X[a],self.Y[a],x,y)

				end -- function(x,y)

			end -- not self[closures].BlocksTo[a]

			-- Return the requested closure
			return self[closures].BlocksTo[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.BlocksTo(self,0)(a,b)
	end

	-- Angle from actor to point
	Actor.AngleTo = function(self,a,b)
		-- Check if a specific closure is requested
		if type(a) == "number" and b == nil then

			-- Check if a closure already exists
			if not self[closures].AngleTo[a] then

				-- Create closure
				self[closures].AngleTo[a] = function(x,y)
					-- Main function logic follows

					-- Check if "x" is an actor table
					if RAIL.IsActor(x) then
						y = x.Y[a]
						x = x.X[a]
					end

					return GetAngle(self.X[a],self.Y[a],x,y)
				end -- function(x,y)

			end -- not self[closures].AngleTo[a]

			-- Return the requested closure
			return self[closures].AngleTo[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.AngleTo(self,0)(a,b)
	end

	-- Angle from point to actor
	Actor.AngleFrom = function(self,a,b)
		-- Check if a specific closure is requested
		if type(a) == "number" and b == nil then

			-- Check if a closure already exists
			if not self[closures].AngleFrom[a] then

				-- Create closure
				self[closures].AngleFrom[a] = function(x,y)
					-- Main function logic follows

					-- Check if "x" is an actor table
					if RAIL.IsActor(x) then
						y = x.Y[a]
						x = x.X[a]
					end

					return GetAngle(x,y,self.X[a],self.Y[a])
				end -- function(x,y)

			end -- not self[closures].AngleFrom[a]

			-- Return the requested closure
			return self[closures].AngleFrom[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.AngleFrom(self,0)(a,b)
	end

	-- Plot a point on a circle around this actor
	Actor.AnglePlot = function(self,a,b)
		-- Check if a specific closure is requested
		if type(a) == "number" and b == nil then

			-- Check if a closure already exists
			if not self[closures].AnglePlot[a] then

				-- Create closure
				self[closures].AnglePlot[a] = function(angle,radius)
					-- Main function logic follows

					return PlotCircle(self.X[a],self.Y[a],angle,radius)
				end -- function(angle,radius)

			end -- not self[closures].AnglePlot[a]

			-- Return the requested closure
			return self[closures].AnglePlot[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.AnglePlot(self,0)(a,b)
	end

	------------------
	-- API Wrappers --
	------------------

	-- These are mainly to allow attacks/skills vs. specific monsters to be
	--	hooked in a more efficient manner than hooking Attack() base API

	Actor.Attack = function(self)
		-- Send the attack
		Attack(RAIL.Self.ID,self.ID)

		-- After sending an attack, this actor can never be kill-stealed (until Actor.Expire)
		self.BattleOpts.FreeForAll = true
	end
	Actor.SkillObject = function(self,level,skill_id)
		-- Send the skill
		SkillObject(RAIL.Self.ID,level,skill_id,self.ID)

		-- Increment skill counter
		self.BattleOpts.SkillsAgainst = (self.BattleOpts.SkillsAgainst or 0) + 1

		-- And never see it as kill-stealing
		self.BattleOpts.FreeForAll = true
	end

	-----------------------
	-- Actors Collection --
	-----------------------

	Actors = {}
	setmetatable(Actors,{
		__index = function(self,idx)
			if type(idx) ~= "number" then
				return self[-1]
			end
			-- Make sure the actor ID is positive
			--	(but -1 is a special value)
			if idx < -1 then
				idx = -idx
				-- Check if actor is already in the table
				local actor = rawget(self,idx)
				if actor ~= nil then
					return actor
				end
			end

			-- Generate a new actor class
			rawset(self,idx,Actor:New(idx))
			return self[idx]
		end
	})

	-- Create Actors[-1], and disable certain features
	Actors[-1].ExpireTimeout[1] = false

	Actors[-1].Update    = function(self) return self end
	Actors[-1].IsEnemy   = function() return false end
	Actors[-1].IsFriend  = function() return false end
	Actors[-1].IsIgnored = function() return true end
	Actors[-1].IsAllowed = function() return false end

	-- After setting up the Actor class and Actors table,
	--	rework the API to allow Actor inputs
	--local
	-- TODO? Don't think I even want this...
end