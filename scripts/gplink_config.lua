-- GP-Link settings. Changes apply on the next sync.
return {
  -- MIDI channel (1-16) for all non-drum tracks
  channel = 1,
  -- MIDI channel for drum tracks (GM standard = 10; many drum VSTs are omni)
  drum_channel = 10,
  -- true = use the channels from Guitar Pro instead of 'channel'
  use_gp_channels = false,

  -- Velocity adjustments (base value comes from the GP dynamics ppp..fff)
  ghost_factor = 0.6,        -- ghost notes: velocity * factor
  accent_add = 15,           -- accent
  heavy_accent_add = 25,     -- heavy accent
  dead_note_velocity = nil,  -- e.g. 30 = dead notes (x) with a fixed velocity

  -- Auto-sync: polling interval in seconds
  poll_interval = 1.0,

  -- Create regions for GP sections
  create_regions = true,

  -- Keyswitches per GP track name (or GP instrument name).
  -- Written as a short note before the actual note whenever the technique changes.
  -- Adjust the note numbers to your VST (C0 = 12 / C-1 = 0 depending on how the VST counts).
  keyswitches = {
    -- ["Distortion Guitar"] = { Normal = 24, PalmMuted = 25, Muted = 26, Harmonic = 27, lead_qn = 1/32 },
  },
}
