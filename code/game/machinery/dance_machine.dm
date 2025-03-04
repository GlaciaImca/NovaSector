/// Helper macro to check if the passed mob has jukebox sound preference enabled
#define HAS_JUKEBOX_PREF(mob) (!QDELETED(mob) && !isnull(mob.client) && mob.client.prefs.read_preference(/datum/preference/toggle/sound_jukebox))

/obj/machinery/jukebox
	name = "jukebox"
	desc = "A classic music player."
	icon = 'icons/obj/machines/music.dmi'
	icon_state = "jukebox"
	verb_say = "states"
	density = TRUE
	req_access = list(ACCESS_BAR)
	/// Whether we're actively playing music
	var/active = FALSE
	/// List of weakrefs to mobs listening to the current song
	var/list/datum/weakref/rangers = list()
	/// World.time when the current song will stop playing, but also a cooldown between activations
	var/stop = 0
	/// List of /datum/tracks we can play
	/// Inited from config every time a jukebox is instantiated
	var/list/songs = list()
	/// Current song selected
	var/datum/track/selection = null
	/// Volume of the songs played
	var/volume = 50
	/// Cooldown between "Error" sound effects being played
	COOLDOWN_DECLARE(jukebox_error_cd)

/obj/machinery/jukebox/disco
	name = "radiant dance machine mark IV"
	desc = "The first three prototypes were discontinued after mass casualty incidents."
	icon_state = "disco"
	req_access = list(ACCESS_ENGINEERING)
	anchored = FALSE
	var/list/spotlights = list()
	var/list/sparkles = list()

/obj/machinery/jukebox/disco/indestructible
	name = "radiant dance machine mark V"
	desc = "Now redesigned with data gathered from the extensive disco and plasma research."
	req_access = null
	anchored = TRUE
	resistance_flags = INDESTRUCTIBLE | LAVA_PROOF | FIRE_PROOF | UNACIDABLE | ACID_PROOF
	obj_flags = /obj::obj_flags | NO_DECONSTRUCTION

/datum/track
	var/song_name = "generic"
	var/song_path = null
	var/song_length = 0
	var/song_beat = 0

/datum/track/default
	song_path = 'sound/ambience/title3.ogg'
	song_name = "Tintin on the Moon"
	song_length = 3 MINUTES + 52 SECONDS
	song_beat = 1 SECONDS

/obj/machinery/jukebox/Initialize(mapload)
	. = ..()
	songs = SSjukeboxes.songs // NOVA EDIT CHANGE - ORIGINAL: songs = load_songs_from_config()
	if(length(songs))
		selection = pick(songs)

/// Loads the config sounds once, and returns a copy of them.
/obj/machinery/jukebox/proc/load_songs_from_config()
	var/static/list/config_songs
	if(isnull(config_songs))
		config_songs = list()
		var/list/tracks = flist("[global.config.directory]/jukebox_music/sounds/")
		for(var/track_file in tracks)
			var/datum/track/new_track = new()
			new_track.song_path = file("[global.config.directory]/jukebox_music/sounds/[track_file]")
			var/list/track_data = splittext(track_file, "+")
			if(length(track_data) != 3)
				continue
			new_track.song_name = track_data[1]
			new_track.song_length = text2num(track_data[2])
			new_track.song_beat = text2num(track_data[3])
			config_songs += new_track

		if(!length(config_songs))
			// Includes title3 as a default for testing / "no config" support, also because it's a banger
			config_songs += new /datum/track/default()

	// returns a copy so it can mutate if desired.
	return config_songs.Copy()

/obj/machinery/jukebox/Destroy()
	dance_over()
	selection = null
	songs.Cut()
	return ..()

/obj/machinery/jukebox/attackby(obj/item/O, mob/user, params)
	if(!active && !(obj_flags & NO_DECONSTRUCTION))
		if(O.tool_behaviour == TOOL_WRENCH)
			if(!anchored && !isinspace())
				to_chat(user,span_notice("You secure [src] to the floor."))
				set_anchored(TRUE)
			else if(anchored)
				to_chat(user,span_notice("You unsecure and disconnect [src]."))
				set_anchored(FALSE)
			playsound(src, 'sound/items/deconstruct.ogg', 50, TRUE)
			return
	return ..()

/obj/machinery/jukebox/update_icon_state()
	icon_state = "[initial(icon_state)][active ? "-active" : null]"
	return ..()

/obj/machinery/jukebox/ui_status(mob/user)
	if(!anchored)
		to_chat(user,span_warning("This device must be anchored by a wrench!"))
		return UI_CLOSE
	if(!allowed(user) && !isobserver(user))
		to_chat(user,span_warning("Error: Access Denied."))
		user.playsound_local(src, 'sound/misc/compiler-failure.ogg', 25, TRUE)
		return UI_CLOSE
	if(!SSjukeboxes.songs.len && !isobserver(user)) // NOVA EDIT CHANGE - ORIGINAL: if(!songs.len && !isobserver(user))
		to_chat(user,span_warning("Error: No music tracks have been authorized for your station. Petition Central Command to resolve this issue."))
		user.playsound_local(src, 'sound/misc/compiler-failure.ogg', 25, TRUE)
		return UI_CLOSE
	return ..()

/obj/machinery/jukebox/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "Jukebox", name)
		ui.open()

/obj/machinery/jukebox/ui_data(mob/user)
	var/list/data = list()
	data["active"] = active
	data["songs"] = list()
	for(var/datum/track/S in SSjukeboxes.songs) // NOVA EDIT CHANGE - ORIGINAL: for(var/datum/track/S in songs)
		var/list/track_data = list(
			name = S.song_name
		)
		data["songs"] += list(track_data)
	data["track_selected"] = null
	data["track_length"] = null
	data["track_beat"] = null
	if(selection)
		data["track_selected"] = selection.song_name
		data["track_length"] = DisplayTimeText(selection.song_length)
		data["track_beat"] = selection.song_beat
	data["volume"] = volume
	return data

/obj/machinery/jukebox/ui_act(action, list/params)
	. = ..()
	if(.)
		return

	switch(action)
		if("toggle")
			if(QDELETED(src))
				return
			if(!active)
				if(stop > world.time)
					to_chat(usr, span_warning("Error: The device is still resetting from the last activation, it will be ready again in [DisplayTimeText(stop-world.time)]."))
					if(!COOLDOWN_FINISHED(src, jukebox_error_cd))
						return
					playsound(src, 'sound/misc/compiler-failure.ogg', 50, TRUE)
					COOLDOWN_START(src, jukebox_error_cd, 15 SECONDS)
					return
				activate_music()
				START_PROCESSING(SSobj, src)
				return TRUE
			else
				stop = 0
				return TRUE
		if("select_track")
			if(active)
				to_chat(usr, span_warning("Error: You cannot change the song until the current one is over."))
				return
			var/list/available = list()
			for(var/datum/track/S in SSjukeboxes.songs) // NOVA EDIT CHANGE - ORIGINAL: for(var/datum/track/S in songs)
				available[S.song_name] = S
			var/selected = params["track"]
			if(QDELETED(src) || !selected || !istype(available[selected], /datum/track))
				return
			selection = available[selected]
			return TRUE
		if("set_volume")
			var/new_volume = params["volume"]
			if(new_volume == "reset")
				volume = initial(volume)
				return TRUE
			else if(new_volume == "min")
				volume = 0
				return TRUE
			else if(new_volume == "max")
				volume = initial(volume)
				return TRUE
			else if(text2num(new_volume) != null)
				volume = text2num(new_volume)
				return TRUE

/obj/machinery/jukebox/proc/activate_music()
	// NOVA EDIT ADDITION START
	var/jukeboxslottotake = SSjukeboxes.addjukebox(src, selection, 2)
	if(isnull(jukeboxslottotake))
		return
	// NOVA EDIT ADDITION END
	active = TRUE
	update_use_power(ACTIVE_POWER_USE)
	update_appearance(UPDATE_ICON_STATE)
	START_PROCESSING(SSobj, src)
	stop = world.time + selection.song_length

/obj/machinery/jukebox/disco/activate_music()
	..()
	dance_setup()
	lights_spin()

/obj/machinery/jukebox/disco/proc/dance_setup()
	var/turf/cen = get_turf(src)
	FOR_DVIEW(var/turf/t, 3, get_turf(src),INVISIBILITY_LIGHTING)
		if(t.x == cen.x && t.y > cen.y)
			spotlights += new /obj/item/flashlight/spotlight(t, 1 + get_dist(src, t), 30 - (get_dist(src, t) * 8), COLOR_SOFT_RED)
			continue
		if(t.x == cen.x && t.y < cen.y)
			spotlights += new /obj/item/flashlight/spotlight(t, 1 + get_dist(src, t), 30 - (get_dist(src, t) * 8), LIGHT_COLOR_PURPLE)
			continue
		if(t.x > cen.x && t.y == cen.y)
			spotlights += new /obj/item/flashlight/spotlight(t, 1 + get_dist(src, t), 30 - (get_dist(src, t) * 8), LIGHT_COLOR_DIM_YELLOW)
			continue
		if(t.x < cen.x && t.y == cen.y)
			spotlights += new /obj/item/flashlight/spotlight(t, 1 + get_dist(src, t), 30 - (get_dist(src, t) * 8), LIGHT_COLOR_GREEN)
			continue
		if((t.x+1 == cen.x && t.y+1 == cen.y) || (t.x+2 == cen.x && t.y+2 == cen.y))
			spotlights += new /obj/item/flashlight/spotlight(t, 1.4 + get_dist(src, t), 30 - (get_dist(src, t) * 8), LIGHT_COLOR_ORANGE)
			continue
		if((t.x-1 == cen.x && t.y-1 == cen.y) || (t.x-2 == cen.x && t.y-2 == cen.y))
			spotlights += new /obj/item/flashlight/spotlight(t, 1.4 + get_dist(src, t), 30 - (get_dist(src, t) * 8), LIGHT_COLOR_CYAN)
			continue
		if((t.x-1 == cen.x && t.y+1 == cen.y) || (t.x-2 == cen.x && t.y+2 == cen.y))
			spotlights += new /obj/item/flashlight/spotlight(t, 1.4 + get_dist(src, t), 30 - (get_dist(src, t) * 8), LIGHT_COLOR_BLUEGREEN)
			continue
		if((t.x+1 == cen.x && t.y-1 == cen.y) || (t.x+2 == cen.x && t.y-2 == cen.y))
			spotlights += new /obj/item/flashlight/spotlight(t, 1.4 + get_dist(src, t), 30 - (get_dist(src, t) * 8), LIGHT_COLOR_BLUE)
			continue
		continue
	FOR_DVIEW_END

/obj/machinery/jukebox/disco/proc/hierofunk()
	for(var/i in 1 to 10)
		spawn_atom_to_turf(/obj/effect/temp_visual/hierophant/telegraph/edge, src, 1, FALSE)
		sleep(0.5 SECONDS)

#define DISCO_INFENO_RANGE (rand(85, 115)*0.01)

/obj/machinery/jukebox/disco/proc/lights_spin()
	for(var/i in 1 to 25)
		if(QDELETED(src) || !active)
			return
		var/obj/effect/overlay/sparkles/S = new /obj/effect/overlay/sparkles(src)
		S.alpha = 0
		sparkles += S
		switch(i)
			if(1 to 8)
				S.orbit(src, 30, TRUE, 60, 36, TRUE)
			if(9 to 16)
				S.orbit(src, 62, TRUE, 60, 36, TRUE)
			if(17 to 24)
				S.orbit(src, 95, TRUE, 60, 36, TRUE)
			if(25)
				S.pixel_y = 7
				S.forceMove(get_turf(src))
		sleep(0.7 SECONDS)
	for(var/s in sparkles)
		var/obj/effect/overlay/sparkles/reveal = s
		reveal.alpha = 255
	while(active)
		for(var/g in spotlights) // The multiples reflects custom adjustments to each colors after dozens of tests
			var/obj/item/flashlight/spotlight/glow = g
			if(QDELETED(glow))
				stack_trace("[glow?.gc_destroyed ? "Qdeleting glow" : "null entry"] found in [src].[gc_destroyed ? " Source qdeleting at the time." : ""]")
				return
			switch(glow.light_color)
				if(COLOR_SOFT_RED)
					if(glow.even_cycle)
						glow.set_light_on(FALSE)
						glow.set_light_color(LIGHT_COLOR_BLUE)
					else
						glow.set_light_range_power_color(glow.base_light_range * DISCO_INFENO_RANGE, glow.light_power * 1.48, LIGHT_COLOR_BLUE)
						glow.set_light_on(TRUE)
				if(LIGHT_COLOR_BLUE)
					if(glow.even_cycle)
						glow.set_light_range_power_color(glow.base_light_range * DISCO_INFENO_RANGE, glow.light_power * 2, LIGHT_COLOR_GREEN)
						glow.set_light_on(TRUE)
					else
						glow.set_light_on(FALSE)
						glow.set_light_color(LIGHT_COLOR_GREEN)
				if(LIGHT_COLOR_GREEN)
					if(glow.even_cycle)
						glow.set_light_on(FALSE)
						glow.set_light_color(LIGHT_COLOR_ORANGE)
					else
						glow.set_light_range_power_color(glow.base_light_range * DISCO_INFENO_RANGE, glow.light_power * 0.5, LIGHT_COLOR_ORANGE)
						glow.set_light_on(TRUE)
				if(LIGHT_COLOR_ORANGE)
					if(glow.even_cycle)
						glow.set_light_range_power_color(glow.base_light_range * DISCO_INFENO_RANGE, glow.light_power * 2.27, LIGHT_COLOR_PURPLE)
						glow.set_light_on(TRUE)
					else
						glow.set_light_on(FALSE)
						glow.set_light_color(LIGHT_COLOR_PURPLE)
				if(LIGHT_COLOR_PURPLE)
					if(glow.even_cycle)
						glow.set_light_on(FALSE)
						glow.set_light_color(LIGHT_COLOR_BLUEGREEN)
					else
						glow.set_light_range_power_color(glow.base_light_range * DISCO_INFENO_RANGE, glow.light_power * 0.44, LIGHT_COLOR_BLUEGREEN)
						glow.set_light_on(TRUE)
				if(LIGHT_COLOR_BLUEGREEN)
					if(glow.even_cycle)
						glow.set_light_range(glow.base_light_range * DISCO_INFENO_RANGE)
						glow.set_light_color(LIGHT_COLOR_DIM_YELLOW)
						glow.set_light_on(TRUE)
					else
						glow.set_light_on(FALSE)
						glow.set_light_color(LIGHT_COLOR_DIM_YELLOW)
				if(LIGHT_COLOR_DIM_YELLOW)
					if(glow.even_cycle)
						glow.set_light_on(FALSE)
						glow.set_light_color(LIGHT_COLOR_CYAN)
					else
						glow.set_light_range(glow.base_light_range * DISCO_INFENO_RANGE)
						glow.set_light_color(LIGHT_COLOR_CYAN)
						glow.set_light_on(TRUE)
				if(LIGHT_COLOR_CYAN)
					if(glow.even_cycle)
						glow.set_light_range_power_color(glow.base_light_range * DISCO_INFENO_RANGE, glow.light_power * 0.68, COLOR_SOFT_RED)
						glow.set_light_on(TRUE)
					else
						glow.set_light_on(FALSE)
						glow.set_light_color(COLOR_SOFT_RED)
					glow.even_cycle = !glow.even_cycle
		if(prob(2))  // Unique effects for the dance floor that show up randomly to mix things up
			INVOKE_ASYNC(src, PROC_REF(hierofunk))
		sleep(selection.song_beat)
		if(QDELETED(src))
			return

#undef DISCO_INFENO_RANGE

/obj/machinery/jukebox/disco/proc/dance(mob/living/dancer, dance_num) //Show your moves
	ADD_TRAIT(dancer, TRAIT_DISCO_DANCER, REF(src))
	switch(dance_num)
		if(1)
			dance1(dancer)
		if(2)
			dance2(dancer)
		if(3)
			start_dance3(dancer)
		if(4)
			dance4(dancer)

/mob/proc/dance_flip()
	if(dir == WEST)
		emote("flip")

/obj/machinery/jukebox/disco/proc/dance1(mob/living/dancer)
	addtimer(TRAIT_CALLBACK_REMOVE(dancer, TRAIT_DISCO_DANCER, REF(src)), 6.5 SECONDS, TIMER_CLIENT_TIME)
	for(var/i in 0 to (6 SECONDS) step (1.5 SECONDS))
		addtimer(CALLBACK(GLOBAL_PROC, GLOBAL_PROC_REF(dance_rotate), dancer, CALLBACK(dancer, TYPE_PROC_REF(/mob, dance_flip))), i, TIMER_CLIENT_TIME)

/obj/machinery/jukebox/disco/proc/dance2(mob/living/dancer, dance_length = 2.5 SECONDS)
	var/matrix/initial_matrix = matrix(dancer.transform)
	var/list/transforms = list(
		"[NORTH]" = matrix(dancer.transform).Translate(0, 3),
		"[EAST]" = matrix(dancer.transform).Translate(3, 0),
		"[SOUTH]" = matrix(dancer.transform).Translate(0, -3),
		"[WEST]" = matrix(dancer.transform).Translate(-1, -1),
	)
	addtimer(VARSET_CALLBACK(dancer, transform, initial_matrix), dance_length + 0.5 SECONDS, TIMER_CLIENT_TIME)
	addtimer(TRAIT_CALLBACK_REMOVE(dancer, TRAIT_DISCO_DANCER, REF(src)), dance_length + 0.5 SECONDS)
	for (var/i in 1 to dance_length)
		addtimer(CALLBACK(src, PROC_REF(animate_dance2), dancer, transforms, initial_matrix), i, TIMER_CLIENT_TIME)

/obj/machinery/jukebox/disco/proc/animate_dance2(mob/living/dancer, list/transforms, matrix/initial_matrix)
	dancer.setDir(turn(dancer.dir, 90))
	animate(dancer, transform = transforms[num2text(dancer.dir)], time = 1, loop = 0)
	animate(transform = initial_matrix, time = 2, loop = 0)

/obj/machinery/jukebox/disco/proc/start_dance3(mob/living/dancer, dance_length = 3 SECONDS)
	var/initially_resting = dancer.resting
	var/direction_index = 1 //this should allow everyone to dance in the same direction
	addtimer(TRAIT_CALLBACK_REMOVE(dancer, TRAIT_DISCO_DANCER, REF(src)), dance_length + 0.2 SECONDS)
	addtimer(CALLBACK(dancer, TYPE_PROC_REF(/mob/living, set_resting), initially_resting, TRUE, TRUE), dance_length + 0.2 SECONDS, TIMER_CLIENT_TIME)
	for (var/i in 1 to dance_length step 2) // 1 = 0.1 seconds
		addtimer(CALLBACK(src, PROC_REF(dance3), dancer, GLOB.cardinals[direction_index]), i, TIMER_CLIENT_TIME)
		direction_index++
		if(direction_index > GLOB.cardinals.len)
			direction_index = 1

/obj/machinery/jukebox/disco/proc/dance3(mob/living/dancer, dir)
	dancer.setDir(dir)
	dancer.set_resting(!dancer.resting, silent = TRUE, instant = TRUE)

/obj/machinery/jukebox/disco/proc/dance4(mob/living/dancer, dance_length = 1.5 SECONDS)
	var/matrix/initial_matrix = matrix(dancer.transform)
	animate(dancer, transform = matrix(dancer.transform).Turn(180), time = 2, loop = 0)
	dancer.emote("spin")
	addtimer(CALLBACK(src, PROC_REF(dance4_revert), dancer, initial_matrix), dance_length, TIMER_CLIENT_TIME)

/obj/machinery/jukebox/disco/proc/dance4_revert(mob/living/dancer, matrix/starting_matrix)
	animate(dancer, transform = starting_matrix, time = 5, loop = 0)
	REMOVE_TRAIT(dancer, TRAIT_DISCO_DANCER, REF(src))

/obj/machinery/jukebox/proc/dance_over()
	// NOVA EDIT ADDITION START
	var/position = SSjukeboxes.findjukeboxindex(src)
	var/channel_playing
	if(position)
		SSjukeboxes.removejukebox(position)
		channel_playing = SSjukeboxes.findjukeboxchannel(src)
	// NOVA EDIT ADDITION END
	for(var/datum/weakref/weak_to_hide_from as anything in rangers)
		var/mob/to_hide_from = weak_to_hide_from?.resolve()
		to_hide_from?.stop_sound_channel(channel_playing ? channel_playing : CHANNEL_JUKEBOX) // NOVA EDIT CHANGE - ORIGINAL: to_hide_from?.stop_sound_channel(CHANNEL_JUKEBOX)

	rangers.Cut()

/obj/machinery/jukebox/disco/dance_over()
	..()
	QDEL_LIST(spotlights)
	QDEL_LIST(sparkles)

// NOVA EDIT COMMENT - Overridden in modular
/obj/machinery/jukebox/process()
	if(world.time < stop && active)
		var/sound/song_played = sound(selection.song_path)

		// Goes through existing mobs in rangers to determine if they should not be played to
		for(var/datum/weakref/weak_to_hide_from as anything in rangers)
			var/mob/to_hide_from = weak_to_hide_from?.resolve()
			if(!HAS_JUKEBOX_PREF(to_hide_from) || get_dist(src, get_turf(to_hide_from)) > 10)
				rangers -= weak_to_hide_from
				to_hide_from?.stop_sound_channel(CHANNEL_JUKEBOX)

		// Collect mobs to play the song to, stores weakrefs of them in rangers
		for(var/mob/to_play_to in range(world.view, src))
			if(!HAS_JUKEBOX_PREF(to_play_to))
				continue
			var/datum/weakref/weak_playing_to = WEAKREF(to_play_to)
			if(rangers[weak_playing_to])
				continue
			rangers[weak_playing_to] = TRUE
			// This plays the sound directly underneath the mob because otherwise it'd get stuck in their left ear or whatever
			// Would be neat if it sourced from the box itself though
			to_play_to.playsound_local(get_turf(to_play_to), null, volume, channel = CHANNEL_JUKEBOX, sound_to_use = song_played, use_reverb = FALSE)

	else if(active)
		active = FALSE
		update_use_power(IDLE_POWER_USE)
		STOP_PROCESSING(SSobj, src)
		dance_over()
		playsound(src,'sound/machines/terminal_off.ogg',50,TRUE)
		update_appearance(UPDATE_ICON_STATE)
		stop = world.time + 100

/obj/machinery/jukebox/disco/process()
	. = ..()
	if(!active)
		return

	var/dance_num = rand(1,4) //all will do the same dance
	for(var/datum/weakref/weak_dancer as anything in rangers)
		var/mob/living/to_dance = weak_dancer.resolve()
		if(!istype(to_dance) || !(to_dance.mobility_flags & MOBILITY_MOVE))
			continue
		if(!HAS_TRAIT(to_dance, TRAIT_DISCO_DANCER))
			dance(to_dance, dance_num)

#undef HAS_JUKEBOX_PREF
