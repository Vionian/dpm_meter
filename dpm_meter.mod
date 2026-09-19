return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`dpm_meter` mod must be lower than DMF in your launcher's load order.")

		new_mod("dpm_meter", {
			mod_script       = "dpm_meter/scripts/mods/dpm_meter/dpm_meter",
			mod_data         = "dpm_meter/scripts/mods/dpm_meter/dpm_meter_data",
			mod_localization = "dpm_meter/scripts/mods/dpm_meter/dpm_meter_localization",
		})
	end,
	packages = {},
}
